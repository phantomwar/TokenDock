import 'dart:async';
import 'dart:convert';

import '../models/connection.dart';
import '../models/connection_health.dart';
import '../models/connection_status.dart';
import '../models/provider_snapshot.dart';
import '../models/test_result.dart';
import '../models/quota.dart';
import '../providers/provider_adapter.dart';
import '../providers/provider_registry.dart';
import '../storage/connection_health_repository.dart';
import '../storage/connection_repository.dart';
import '../storage/quota_cache_repository.dart';
import '../storage/secret_store.dart';
import '../storage/settings_repository.dart';
import 'credential_events.dart';
import 'log_redaction.dart';

/// Service orchestrating quota refreshing with request coalescing,
/// bounded concurrency, and cache-first resilience.
class RefreshService {
  RefreshService({
    required ConnectionRepository connectionRepository,
    required QuotaCacheRepository quotaCacheRepository,
    required SecretStore secretStore,
    required ProviderRegistry providerRegistry,
    ConnectionHealthRepository? connectionHealthRepository,
    SettingsRepository? settingsRepository,
    void Function(ProviderSnapshot snapshot)? onSnapshotUpdated,
    int maximumConcurrent = 4,
    int defaultIntervalMinutes = 3,
    bool autoStartTimer = true,
    Duration? timerInterval,
    Duration secretCleanupInterval = const Duration(minutes: 1),
  }) : _connectionRepository = connectionRepository,
       _connectionHealthRepository =
           connectionHealthRepository ?? _InMemoryConnectionHealthRepository(),
       _quotaCacheRepository = quotaCacheRepository,
       _secretStore = secretStore,
       _providerRegistry = providerRegistry,
       _settingsRepository = settingsRepository,
       _maximumConcurrent = maximumConcurrent,
       _secretCleanupInterval = secretCleanupInterval {
    if (onSnapshotUpdated != null) {
      _snapshotListeners.add(onSnapshotUpdated);
    }
    if (autoStartTimer) {
      if (timerInterval != null) {
        startTimer(interval: timerInterval);
      } else if (settingsRepository != null) {
        syncIntervalFromSettings(fallbackMinutes: defaultIntervalMinutes);
      } else {
        updateIntervalMinutes(defaultIntervalMinutes);
      }
    }
  }

  /// Creates a testable instance of [RefreshService] with in-memory fallbacks
  /// and disabled timers by default.
  factory RefreshService.forTest({
    required ProviderAdapter provider,
    ConnectionRepository? connectionRepository,
    ConnectionHealthRepository? connectionHealthRepository,
    QuotaCacheRepository? quotaCacheRepository,
    SecretStore? secretStore,
    ProviderRegistry? providerRegistry,
    SettingsRepository? settingsRepository,
    void Function(ProviderSnapshot snapshot)? onSnapshotUpdated,
    int maximumConcurrent = 4,
    bool autoStartTimer = false,
    Duration? timerInterval,
    int defaultIntervalMinutes = 3,
    Duration secretCleanupInterval = const Duration(minutes: 1),
  }) {
    final registry =
        providerRegistry ?? ProviderRegistry(registerDefaults: false);
    registry.register(provider);
    return RefreshService(
      connectionRepository:
          connectionRepository ?? _InMemoryConnectionRepository(),
      connectionHealthRepository: connectionHealthRepository,
      quotaCacheRepository:
          quotaCacheRepository ?? _InMemoryQuotaCacheRepository(),
      secretStore: secretStore ?? _InMemorySecretStore(),
      providerRegistry: registry,
      settingsRepository: settingsRepository,
      onSnapshotUpdated: onSnapshotUpdated,
      maximumConcurrent: maximumConcurrent,
      defaultIntervalMinutes: defaultIntervalMinutes,
      autoStartTimer: autoStartTimer,
      timerInterval: timerInterval,
      secretCleanupInterval: secretCleanupInterval,
    );
  }

  final ConnectionRepository _connectionRepository;
  final ConnectionHealthRepository _connectionHealthRepository;
  final QuotaCacheRepository _quotaCacheRepository;
  final SecretStore _secretStore;
  final ProviderRegistry _providerRegistry;
  final SettingsRepository? _settingsRepository;
  final int _maximumConcurrent;
  final Duration _secretCleanupInterval;
  final Map<String, ConnectionHealth> _healthFallback = {};

  final List<void Function(ProviderSnapshot snapshot)> _snapshotListeners = [];
  final List<void Function(CredentialDisabledEvent)> _disabledListeners = [];
  final Map<String, _InFlightConnectionOperation> _inFlight = {};
  final List<String> _credentialCleanupWarnings = [];
  final Set<String> _pendingSecretCleanup = <String>{};
  Timer? _periodicTimer;
  Timer? _secretCleanupTimer;
  int? _currentIntervalMinutes;
  bool _isDisposed = false;

  /// True if periodic background refresh timer is active.
  bool get isTimerActive => _periodicTimer != null && _periodicTimer!.isActive;

  /// Currently configured refresh interval in minutes.
  int? get currentIntervalMinutes => _currentIntervalMinutes;

  /// Adds a listener notified whenever a [ProviderSnapshot] is updated.
  void addSnapshotListener(void Function(ProviderSnapshot snapshot) listener) {
    _snapshotListeners.add(listener);
  }

  /// Removes an active snapshot update listener.
  void removeSnapshotListener(
    void Function(ProviderSnapshot snapshot) listener,
  ) {
    _snapshotListeners.remove(listener);
  }

  /// Adds a listener notified when a credential is definitively rejected.
  void addDisabledListener(
    void Function(CredentialDisabledEvent event) listener,
  ) {
    _disabledListeners.add(listener);
  }

  /// Removes an active credential-disabled listener.
  void removeDisabledListener(
    void Function(CredentialDisabledEvent event) listener,
  ) {
    _disabledListeners.remove(listener);
  }

  void _publishCredentialDisabled(Connection connection, String cause) {
    if (_isDisposed) return;
    final event = CredentialDisabledEvent(
      connectionId: connection.id,
      cause: cause,
      identityKey: connection.identityKey,
    );
    for (final listener in List.of(_disabledListeners)) {
      listener(event);
    }
  }

  void _publishSnapshot(ProviderSnapshot snapshot) {
    if (_isDisposed) return;
    for (final listener in List.of(_snapshotListeners)) {
      listener(snapshot);
    }
  }

  /// Refreshes quotas for a single connection.
  ///
  /// Coalesces concurrent calls for the same [connectionId] into a single in-flight operation.
  /// Maintains existing cached quotas in presentation state while fetching.
  /// On failure, preserves previously cached quotas and publishes an error snapshot.
  Future<void> refreshOne(String connectionId) {
    if (_isDisposed) return Future.value();
    final existing = _inFlight[connectionId];
    if (existing != null) {
      if (existing.refreshResult != null) return existing.refreshResult!;
      return existing.completion.then((_) => refreshOne(connectionId));
    }

    final future = _performRefreshOne(connectionId);
    final entry = _InFlightConnectionOperation(
      future.then<void>((_) {}, onError: (_, _) {}),
      refreshResult: future,
    );
    _inFlight[connectionId] = entry;
    return future.whenComplete(() {
      if (identical(_inFlight[connectionId], entry)) {
        _inFlight.remove(connectionId);
      }
    });
  }

  /// Runs [operation] once for [connectionId] while refresh or token work is in flight.
  Future<T> runConnectionOperation<T>({
    required String connectionId,
    required Future<T> Function() operation,
  }) {
    if (_isDisposed) {
      return Future<T>.error(StateError('RefreshService is disposed'));
    }
    final existing = _inFlight[connectionId];
    if (existing != null) {
      return existing.completion.then(
        (_) => runConnectionOperation(
          connectionId: connectionId,
          operation: operation,
        ),
      );
    }

    final future = operation();
    final entry = _InFlightConnectionOperation(
      future.then<void>((_) {}, onError: (_, _) {}),
      sharedResult: future,
    );
    _inFlight[connectionId] = entry;
    return future.whenComplete(() {
      if (identical(_inFlight[connectionId], entry)) {
        _inFlight.remove(connectionId);
      }
    });
  }

  Future<String> runTokenOperation({
    required String connectionId,
    required Future<String> Function() operation,
  }) {
    final existing = _inFlight[connectionId];
    final shared = existing?.sharedResult;
    if (shared is Future<String>) return shared;
    return runConnectionOperation(
      connectionId: connectionId,
      operation: operation,
    ).whenComplete(() {});
  }

  Future<TestResult> testAdapter({
    required ProviderAdapter adapter,
    required Connection connection,
    required String secret,
    bool preferStoredSecret = false,
  }) => runConnectionOperation(
    connectionId: connection.id,
    operation: () async {
      var effectiveConnection = connection;
      var effectiveSecret = secret;
      if (preferStoredSecret) {
        final connections = await _connectionRepository.getAll();
        final stored = connections
            .where((value) => value.id == connection.id)
            .firstOrNull;
        if (stored != null) {
          effectiveConnection = stored;
          effectiveSecret =
              await _secretStore.read(stored.credentialRef) ?? secret;
        }
      }
      final result = await adapter.test(effectiveConnection, effectiveSecret);
      if (result.isSuccess &&
          _isAntigravitySchemaQuarantined(effectiveConnection)) {
        return TestResult.success(
          plan: result.plan,
          quotas: result.quotas,
          replacementSecret: result.replacementSecret,
          schemaRevalidated: true,
        );
      }
      return result;
    },
  );

  Future<void> _performRefreshOne(String connectionId) async {
    if (_isDisposed) return;
    final cachedQuotas = await _quotaCacheRepository.getAll(connectionId);

    final storedHealth = await _connectionHealthRepository.get(connectionId);
    final health = _healthFallback[connectionId] ?? storedHealth;
    final cooldownUntil = health?.cooldownUntil;
    if (health != null &&
        cooldownUntil != null &&
        cooldownUntil.isAfter(DateTime.now().toUtc())) {
      _publishSnapshot(
        ProviderSnapshot(
          connectionId: connectionId,
          status: health.status,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: health.lastCheckedAt,
          error: health.error,
          cooldownUntil: cooldownUntil,
        ),
      );
      return;
    }

    _publishSnapshot(
      ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.updating,
        quotas: cachedQuotas,
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: null,
      ),
    );

    final connections = await _connectionRepository.getAll();
    final foundConnection = connections
        .where((c) => c.id == connectionId)
        .firstOrNull;
    if (foundConnection == null) {
      _publishSnapshot(
        ProviderSnapshot(
          connectionId: connectionId,
          status: ConnectionStatus.error,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: 'Connection not found: $connectionId',
        ),
      );
      return;
    }
    var connection = foundConnection;
    if (_isAntigravitySchemaQuarantined(connection)) {
      await _persistHealthAndPublish(
        ProviderSnapshot(
          connectionId: connectionId,
          status: ConnectionStatus.error,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: 'quota_source_changed',
          connection: connection,
        ),
      );
      return;
    }

    final adapter = _providerRegistry.get(connection.provider);
    if (adapter == null) {
      await _persistHealthAndPublish(
        ProviderSnapshot(
          connectionId: connectionId,
          status: ConnectionStatus.error,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: 'Unknown provider "${connection.provider}"',
        ),
      );
      return;
    }

    final isLocalSource = _isLocalAntigravitySource(connection);
    String? secret;
    if (!isLocalSource) {
      try {
        secret = await _secretStore.read(connection.credentialRef);
      } catch (_) {
        await _persistHealthAndPublish(
          ProviderSnapshot(
            connectionId: connectionId,
            status: ConnectionStatus.error,
            quotas: cachedQuotas,
            balance: null,
            fetchedAt: DateTime.now().toUtc(),
            error: 'Credential storage unavailable',
          ),
        );
        return;
      }
      if (secret == null || secret.isEmpty) {
        await _persistHealthAndPublish(
          ProviderSnapshot(
            connectionId: connectionId,
            status: ConnectionStatus.authError,
            quotas: cachedQuotas,
            balance: null,
            fetchedAt: DateTime.now().toUtc(),
            error: 'Credential not found for connection',
          ),
        );
        return;
      }
    }
    final currentSecret = secret ?? '';
    final activeSecrets = <String>{currentSecret};

    ProviderSnapshot providerSnapshot = ProviderSnapshot(
      connectionId: connectionId,
      status: ConnectionStatus.error,
      quotas: cachedQuotas,
      balance: null,
      fetchedAt: DateTime.now().toUtc(),
      error: 'Refresh failed',
    );
    String? definitiveCause;
    final refreshable = adapter.refreshableCredential(currentSecret);
    if (refreshable != null &&
        refreshable.expiresAt != null &&
        refreshable.expiresAt!.isBefore(
          DateTime.now().toUtc().add(refreshable.refreshLead),
        )) {
      try {
        final refreshedSecret = await refreshable.refresh(currentSecret);
        connection = await _rotateCredential(connection, refreshedSecret);
        secret = refreshedSecret;
        activeSecrets.add(refreshedSecret);
      } catch (error) {
        definitiveCause = definitiveOAuthFailureCause(error);
        providerSnapshot = ProviderSnapshot(
          connectionId: connectionId,
          status: definitiveCause == null
              ? ConnectionStatus.error
              : ConnectionStatus.authError,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error:
              definitiveCause ??
              redactSecret(error.toString(), activeSecrets.toList()),
        );
        if (definitiveCause == 'invalid_grant') {
          await _deleteCredentialBestEffort(connection);
        }
      }
    }
    if (definitiveCause == null) {
      try {
        providerSnapshot = await adapter.fetch(
          connection,
          secret ?? currentSecret,
        );
        if (providerSnapshot.failureCause ==
                ProviderFailureCause.invalidCredential &&
            refreshable != null) {
          final refreshedSecret = await refreshable.refresh(
            secret ?? currentSecret,
          );
          connection = await _rotateCredential(connection, refreshedSecret);
          secret = refreshedSecret;
          activeSecrets.add(refreshedSecret);
          providerSnapshot = await adapter.fetch(connection, secret);
        }
      } catch (error) {
        definitiveCause = definitiveOAuthFailureCause(error);
        providerSnapshot = ProviderSnapshot(
          connectionId: connectionId,
          status: definitiveCause == null
              ? ConnectionStatus.error
              : ConnectionStatus.authError,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error:
              definitiveCause ??
              redactSecret(error.toString(), activeSecrets.toList()),
          failureCause: definitiveCause == 'bare_401'
              ? ProviderFailureCause.invalidCredential
              : null,
        );
        if (definitiveCause == 'invalid_grant') {
          await _deleteCredentialBestEffort(connection);
        }
      }
    }
    if (definitiveCause == null &&
        providerSnapshot.failureCause ==
            ProviderFailureCause.invalidCredential) {
      definitiveCause = 'bare_401';
      providerSnapshot = ProviderSnapshot(
        connectionId: providerSnapshot.connectionId,
        status: ConnectionStatus.authError,
        quotas: providerSnapshot.quotas,
        balance: providerSnapshot.balance,
        fetchedAt: providerSnapshot.fetchedAt,
        error: definitiveCause,
        cooldownUntil: providerSnapshot.cooldownUntil,
        failureCause: ProviderFailureCause.invalidCredential,
      );
    } else if (definitiveCause == null &&
        providerSnapshot.status == ConnectionStatus.authError &&
        providerSnapshot.failureCause == null) {
      definitiveCause = 'bare_401';
      providerSnapshot = ProviderSnapshot(
        connectionId: providerSnapshot.connectionId,
        status: ConnectionStatus.authError,
        quotas: providerSnapshot.quotas,
        balance: providerSnapshot.balance,
        fetchedAt: providerSnapshot.fetchedAt,
        error: definitiveCause,
        cooldownUntil: providerSnapshot.cooldownUntil,
        failureCause: ProviderFailureCause.invalidCredential,
      );
    }

    if (providerSnapshot.failureCause ==
            ProviderFailureCause.quotaSourceChanged &&
        connection.provider == 'antigravity') {
      connection = await _quarantineAntigravitySchema(connection);
    }
    if (definitiveCause != null) {
      _publishCredentialDisabled(connection, definitiveCause);
    }

    final snapshot = providerSnapshot.status == ConnectionStatus.ok
        ? providerSnapshot
        : ProviderSnapshot(
            connectionId: connectionId,
            status: providerSnapshot.status,
            quotas: cachedQuotas,
            balance: providerSnapshot.balance,
            fetchedAt: providerSnapshot.fetchedAt,
            error: providerSnapshot.error == null
                ? null
                : redactSecret(providerSnapshot.error!, activeSecrets.toList()),
            failureCause: providerSnapshot.failureCause,
            cooldownUntil: providerSnapshot.cooldownUntil,
          );

    if (snapshot.status == ConnectionStatus.ok) {
      try {
        await _quotaCacheRepository.saveAll(connectionId, snapshot.quotas);
      } catch (_) {
        await _persistHealthAndPublish(
          ProviderSnapshot(
            connectionId: connectionId,
            status: ConnectionStatus.error,
            quotas: cachedQuotas,
            balance: null,
            fetchedAt: DateTime.now().toUtc(),
            error: 'Local storage unavailable',
            connection: connection,
          ),
        );
        return;
      }
    }
    await _persistHealthAndPublish(snapshot.copyWith(connection: connection));
  }

  bool _isAntigravitySchemaQuarantined(Connection connection) {
    if (connection.providerData == null) return false;
    try {
      final data = jsonDecode(connection.providerData!);
      return data is Map &&
          data['quotaSourceDisabled'] == 'quota_source_changed';
    } catch (_) {
      return false;
    }
  }

  Future<Connection> _quarantineAntigravitySchema(Connection connection) async {
    var data = <String, dynamic>{};
    if (connection.providerData != null) {
      try {
        final decoded = jsonDecode(connection.providerData!);
        if (decoded is Map) data = Map<String, dynamic>.from(decoded);
      } catch (_) {}
    }
    data['quotaSourceDisabled'] = 'quota_source_changed';
    final quarantined = Connection(
      id: connection.id,
      provider: connection.provider,
      displayName: connection.displayName,
      group: connection.group,
      plan: connection.plan,
      credentialRef: connection.credentialRef,
      enabled: connection.enabled,
      authType: connection.authType,
      identityKey: connection.identityKey,
      providerData: jsonEncode(data),
    );
    await _connectionRepository.save(quarantined);
    return quarantined;
  }

  bool _isLocalAntigravitySource(Connection connection) {
    if (connection.provider != 'antigravity' ||
        connection.providerData == null) {
      return false;
    }
    try {
      final data = jsonDecode(connection.providerData!);
      if (data is! Map) return false;
      final source = data['source'];
      return source == 'language-server' || source == 'agy-cli';
    } catch (_) {
      return false;
    }
  }

  Future<Connection> _rotateCredential(
    Connection connection,
    String nextSecret,
  ) async {
    final nextRef = generateSecretRef();
    await _secretStore.write(nextRef, nextSecret);
    final updated = Connection(
      id: connection.id,
      provider: connection.provider,
      displayName: connection.displayName,
      group: connection.group,
      plan: connection.plan,
      credentialRef: nextRef,
      enabled: connection.enabled,
      authType: connection.authType,
      identityKey: connection.identityKey,
      providerData: connection.providerData,
    );
    try {
      await _connectionRepository.save(updated);
    } catch (_) {
      await _secretStore.delete(nextRef);
      rethrow;
    }
    await _deleteCredentialBestEffort(connection);
    return updated;
  }

  Future<void> _deleteCredentialBestEffort(Connection connection) async {
    try {
      await _secretStore.delete(connection.credentialRef);
    } catch (_) {
      _pendingSecretCleanup.add(connection.credentialRef);
      _credentialCleanupWarnings.add(
        'Old credential cleanup pending for ${connection.id}',
      );
      _scheduleSecretCleanup();
    }
  }

  List<String> get credentialCleanupWarnings =>
      List.unmodifiable(_credentialCleanupWarnings);
  void scheduleCredentialCleanup(String connectionId, String secretRef) {
    _pendingSecretCleanup.add(secretRef);
    _credentialCleanupWarnings.add(
      'Old credential cleanup pending for $connectionId',
    );
    _scheduleSecretCleanup();
  }

  void cancelCredentialCleanup(String secretRef) {
    _pendingSecretCleanup.remove(secretRef);
  }

  void _scheduleSecretCleanup() {
    _secretCleanupTimer ??= Timer(_secretCleanupInterval, () async {
      _secretCleanupTimer = null;
      for (final ref in List.of(_pendingSecretCleanup)) {
        try {
          await _secretStore.delete(ref);
          _pendingSecretCleanup.remove(ref);
        } catch (_) {}
      }
      if (!_isDisposed && _pendingSecretCleanup.isNotEmpty)
        _scheduleSecretCleanup();
    });
  }

  Future<void> _persistHealthAndPublish(ProviderSnapshot snapshot) async {
    final health = ConnectionHealth(
      connectionId: snapshot.connectionId,
      status: snapshot.status,
      lastCheckedAt: snapshot.fetchedAt,
      cooldownUntil: snapshot.cooldownUntil,
      error: snapshot.error,
    );
    try {
      await _connectionHealthRepository.save(health);
      _healthFallback.remove(snapshot.connectionId);
      _publishSnapshot(snapshot);
    } catch (_) {
      _healthFallback[snapshot.connectionId] = health;
      _publishSnapshot(
        ProviderSnapshot(
          connectionId: snapshot.connectionId,
          status: ConnectionStatus.error,
          quotas: snapshot.quotas,
          balance: snapshot.balance,
          fetchedAt: DateTime.now().toUtc(),
          error: 'Local storage unavailable',
          cooldownUntil: snapshot.cooldownUntil,
          connection: snapshot.connection,
        ),
      );
    }
  }

  /// Refreshes all enabled connections with a concurrency cap of at most
  /// [_maximumConcurrent] simultaneous requests.
  Future<void> refreshAll() async {
    if (_isDisposed) return;
    final connections = await _connectionRepository.getAll();
    final enabledConnections = connections.where((c) => c.enabled).toList();

    // Deduplicate connection IDs
    final seen = <String>{};
    final targetIds = <String>[];
    for (final conn in enabledConnections) {
      if (seen.add(conn.id)) {
        targetIds.add(conn.id);
      }
    }

    if (targetIds.isEmpty) return;

    final queue = List<String>.from(targetIds);
    final activeWorkers = <Future<void>>[];
    final workerCount = queue.length < _maximumConcurrent
        ? queue.length
        : _maximumConcurrent;

    Future<void> worker() async {
      while (queue.isNotEmpty) {
        if (_isDisposed) break;
        final id = queue.removeAt(0);
        try {
          await refreshOne(id);
        } catch (_) {
          // Handled inside refreshOne
        }
      }
    }

    for (int i = 0; i < workerCount; i++) {
      activeWorkers.add(worker());
    }

    await Future.wait(activeWorkers);
  }

  /// Updates the periodic refresh interval in minutes.
  /// Supported values: 1, 3, 5, 10 minutes, or 0/null to disable (timer cancelled).
  void updateIntervalMinutes(int? minutes) {
    if (minutes != null) validateRefreshIntervalMinutes(minutes);
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _currentIntervalMinutes = minutes;
    if (_isDisposed) return;

    if (minutes != null && minutes > 0) {
      _periodicTimer = Timer.periodic(Duration(minutes: minutes), (_) {
        refreshAll();
      });
    }
  }

  /// Starts the periodic timer with a custom [interval] or current interval.
  void startTimer({Duration? interval}) {
    _periodicTimer?.cancel();
    _periodicTimer = null;
    if (_isDisposed) return;

    final duration =
        interval ?? Duration(minutes: _currentIntervalMinutes ?? 3);
    _periodicTimer = Timer.periodic(duration, (_) {
      refreshAll();
    });
  }

  /// Cancels the active periodic refresh timer.
  void stopTimer() {
    _periodicTimer?.cancel();
    _periodicTimer = null;
  }

  /// Synchronizes refresh interval from [SettingsRepository].
  Future<void> syncIntervalFromSettings({int fallbackMinutes = 3}) async {
    if (_settingsRepository == null) return;
    try {
      final minutes = await _settingsRepository.getRefreshIntervalMinutes();
      updateIntervalMinutes(minutes);
    } catch (_) {
      updateIntervalMinutes(fallbackMinutes);
    }
  }

  /// Cancels all periodic timers, active listeners, and in-flight operations.
  void dispose() {
    _isDisposed = true;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _secretCleanupTimer?.cancel();
    _secretCleanupTimer = null;
    _inFlight.clear();
    _healthFallback.clear();
    _disabledListeners.clear();
    _snapshotListeners.clear();
  }
}

class _InFlightConnectionOperation {
  _InFlightConnectionOperation(
    this.completion, {
    this.refreshResult,
    this.sharedResult,
  });

  final Future<void> completion;
  final Future<void>? refreshResult;
  final Future<Object?>? sharedResult;
}

class _InMemoryConnectionRepository implements ConnectionRepository {
  final List<Connection> _connections = [];

  @override
  Future<List<Connection>> getAll() async => List.unmodifiable(_connections);

  @override
  Future<void> save(Connection connection) async {
    _connections.removeWhere((c) => c.id == connection.id);
    _connections.add(connection);
  }

  @override
  Future<void> delete(String id) async {
    _connections.removeWhere((c) => c.id == id);
  }
}

class _InMemoryQuotaCacheRepository implements QuotaCacheRepository {
  final Map<String, List<Quota>> _cache = {};

  @override
  Future<List<Quota>> getAll(String connectionId) async =>
      List.unmodifiable(_cache[connectionId] ?? const <Quota>[]);

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    _cache[connectionId] = List.unmodifiable(quotas);
  }

  @override
  Future<void> deleteForConnection(String connectionId) async {
    _cache.remove(connectionId);
  }
}

class _InMemoryConnectionHealthRepository
    implements ConnectionHealthRepository {
  final Map<String, ConnectionHealth> _records = {};

  @override
  Future<ConnectionHealth?> get(String connectionId) async =>
      _records[connectionId];

  @override
  Future<void> save(ConnectionHealth health) async {
    _records[health.connectionId] = health;
  }
}

class _InMemorySecretStore implements SecretStore {
  final Map<String, String> _store = {};

  @override
  Future<void> write(String key, String value) async => _store[key] = value;

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> delete(String key) async => _store.remove(key);
}
