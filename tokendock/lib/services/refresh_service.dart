import 'dart:async';

import '../models/connection.dart';
import '../models/connection_status.dart';
import '../models/provider_snapshot.dart';
import '../models/quota.dart';
import '../providers/provider_adapter.dart';
import '../providers/provider_registry.dart';
import '../storage/connection_repository.dart';
import '../storage/quota_cache_repository.dart';
import '../storage/secret_store.dart';
import '../storage/settings_repository.dart';

export '../storage/connection_repository.dart';
export '../storage/quota_cache_repository.dart';
export '../storage/secret_store.dart';
export '../storage/settings_repository.dart';

/// Service orchestrating quota refreshing with request coalescing,
/// bounded concurrency, and cache-first resilience.
class RefreshService {
  RefreshService({
    required ConnectionRepository connectionRepository,
    required QuotaCacheRepository quotaCacheRepository,
    required SecretStore secretStore,
    required ProviderRegistry providerRegistry,
    SettingsRepository? settingsRepository,
    void Function(ProviderSnapshot snapshot)? onSnapshotUpdated,
    int maximumConcurrent = 4,
    int defaultIntervalMinutes = 3,
    bool autoStartTimer = true,
    Duration? timerInterval,
  })  : _connectionRepository = connectionRepository,
        _quotaCacheRepository = quotaCacheRepository,
        _secretStore = secretStore,
        _providerRegistry = providerRegistry,
        _settingsRepository = settingsRepository,
        _maximumConcurrent = maximumConcurrent {
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
    QuotaCacheRepository? quotaCacheRepository,
    SecretStore? secretStore,
    ProviderRegistry? providerRegistry,
    SettingsRepository? settingsRepository,
    void Function(ProviderSnapshot snapshot)? onSnapshotUpdated,
    int maximumConcurrent = 4,
    bool autoStartTimer = false,
    Duration? timerInterval,
    int defaultIntervalMinutes = 3,
  }) {
    final registry =
        providerRegistry ?? ProviderRegistry(registerDefaults: false);
    registry.register(provider);
    return RefreshService(
      connectionRepository:
          connectionRepository ?? _InMemoryConnectionRepository(),
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
    );
  }

  final ConnectionRepository _connectionRepository;
  final QuotaCacheRepository _quotaCacheRepository;
  final SecretStore _secretStore;
  final ProviderRegistry _providerRegistry;
  final SettingsRepository? _settingsRepository;
  final int _maximumConcurrent;

  final List<void Function(ProviderSnapshot snapshot)> _snapshotListeners = [];
  final Map<String, Future<void>> _inFlight = {};

  Timer? _periodicTimer;
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
      void Function(ProviderSnapshot snapshot) listener) {
    _snapshotListeners.remove(listener);
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
      return existing;
    }

    final future = _performRefreshOne(connectionId);
    _inFlight[connectionId] = future;
    return future.whenComplete(() {
      _inFlight.remove(connectionId);
    });
  }

  Future<void> _performRefreshOne(String connectionId) async {
    if (_isDisposed) return;

    // 1. Read existing cached quotas to maintain display continuity
    final cachedQuotas = await _quotaCacheRepository.getAll(connectionId);

    // 2. Publish transient updating presentation state without clearing cached quotas
    _publishSnapshot(ProviderSnapshot(
      connectionId: connectionId,
      status: ConnectionStatus.updating,
      quotas: cachedQuotas,
      balance: null,
      fetchedAt: DateTime.now().toUtc(),
      error: null,
    ));

    // 3. Find connection metadata
    final connections = await _connectionRepository.getAll();
    final connection =
        connections.where((c) => c.id == connectionId).firstOrNull;
    if (connection == null) {
      _publishSnapshot(ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.error,
        quotas: cachedQuotas,
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: 'Connection not found: $connectionId',
      ));
      return;
    }

    // 4. Read secret from secret store
    final secret = await _secretStore.read(connection.credentialRef);
    if (secret == null || secret.isEmpty) {
      _publishSnapshot(ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.authError,
        quotas: cachedQuotas,
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: 'Credential not found for connection',
      ));
      return;
    }

    // 5. Look up matching provider adapter
    final adapter = _providerRegistry.get(connection.provider);
    if (adapter == null) {
      _publishSnapshot(ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.error,
        quotas: cachedQuotas,
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: 'Unknown provider "${connection.provider}"',
      ));
      return;
    }

    // 6. Fetch fresh snapshot from provider
    try {
      final snapshot = await adapter.fetch(connection, secret);
      // On success: save new quotas to cache and publish fresh snapshot
      await _quotaCacheRepository.saveAll(connectionId, snapshot.quotas);
      _publishSnapshot(snapshot);
    } catch (e) {
      // On failure: preserve previous cached quotas, do NOT wipe cache, and publish error snapshot
      final preservedQuotas = await _quotaCacheRepository.getAll(connectionId);
      final errorSnapshot = ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.error,
        quotas: preservedQuotas,
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: e.toString(),
      );
      _publishSnapshot(errorSnapshot);
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
    final workerCount =
        queue.length < _maximumConcurrent ? queue.length : _maximumConcurrent;

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
    _inFlight.clear();
    _snapshotListeners.clear();
  }
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

class _InMemorySecretStore implements SecretStore {
  final Map<String, String> _store = {};

  @override
  Future<void> write(String key, String value) async => _store[key] = value;

  @override
  Future<String?> read(String key) async => _store[key];

  @override
  Future<void> delete(String key) async => _store.remove(key);
}
