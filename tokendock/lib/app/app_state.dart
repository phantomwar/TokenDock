import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../models/connection.dart';
import '../models/connection_status.dart';
import '../models/provider_snapshot.dart';
import '../models/quota.dart';
import '../models/test_result.dart';
import '../providers/provider_adapter.dart';
import '../providers/provider_registry.dart';
import '../services/refresh_service.dart';
import '../providers/antigravity/antigravity_local.dart';
import '../providers/antigravity/antigravity_oauth.dart';
import '../services/credential_events.dart';
import '../storage/connection_health_repository.dart';
import '../storage/connection_repository.dart';
import '../storage/quota_cache_repository.dart';
import '../storage/secret_store.dart';
import '../storage/settings_repository.dart';

/// Records a login cancellation so it can be checked at commit boundaries.
///
/// The flag is set by a microtask queued when the caller's completer resolves.
/// Checking it immediately after a real `await` is deterministic, because that
/// continuation is queued after the cancellation's and microtasks run in FIFO
/// order. Yielding on an already-completed future was not: it drains the queue
/// exactly once and cannot be relied on to observe a cancel that has not
/// happened yet.
class _CancellationWatch {
  _CancellationWatch(Future<void>? cancellation) {
    cancellation?.then((_) => _requested = true);
  }

  bool _requested = false;

  bool get isRequested => _requested;

  void throwIfCancelled() {
    if (_requested) throw const AntigravityLoginCancelled();
  }
}

/// One account pairing a [Connection] with its latest [ProviderSnapshot].
///
/// Immutable value holder for the widget surface. Never performs persistence
/// or network work; later tasks hydrate it from the database and providers.
class AccountItem {
  const AccountItem({required this.connection, required this.snapshot});

  final Connection connection;
  final ProviderSnapshot snapshot;
}

/// Widget-surface state for [TokenDockWidget] and application-level connection
/// management.
///
/// Extends [ChangeNotifier] so every instance owns its own listener list.
///
/// Audit C-24: this used to `implement ChangeNotifier` and forward each call to
/// a private `_StateNotifier` reached through a `static final Expando`, while
/// the loading and empty constructors were `const`. Dart canonicalises const
/// instances, so every loading shell in the process was one and the same
/// object, the Expando handed them all a single notifier, and disposing one
/// tore down the rest — surfacing as "A ChangeNotifier was used after being
/// disposed" from whichever surface built a loading shell second.
///
/// The constructors below are deliberately not `const`. A [ChangeNotifier]
/// carries mutable state, and a canonicalised instance cannot own any.
class AppState extends ChangeNotifier {
  AppState({
    this.isLoading = false,
    this.accounts = const [],
    this.connectionRepository,
    this.connectionHealthRepository,
    this.quotaCacheRepository,
    this.secretStore,
    this.providerRegistry,
    this.settingsRepository,
    RefreshService? refreshService,
    this.autoStartRefreshTimer = false,
    this.antigravityLocalRuntime,
  }) : _reconnectConnectionIds = <String>{},
       _antigravityLocks = <String, Future<void>>{},
       _refreshService =
           refreshService ??
           ((connectionRepository != null &&
                   quotaCacheRepository != null &&
                   secretStore != null)
               ? RefreshService(
                   connectionRepository: connectionRepository,
                   connectionHealthRepository: connectionHealthRepository,
                   quotaCacheRepository: quotaCacheRepository,
                   secretStore: secretStore,
                   providerRegistry:
                       providerRegistry ?? ProviderRegistry.instance,
                   settingsRepository: settingsRepository,
                   autoStartTimer: false,
                 )
               : null) {
    _refreshService?.addSnapshotListener(_handleSnapshotUpdate);
    _refreshService?.addDisabledListener(_handleCredentialDisabled);
  }

  AppState.loading()
    : isLoading = true,
      accounts = const [],
      autoStartRefreshTimer = false,
      connectionRepository = null,
      connectionHealthRepository = null,
      quotaCacheRepository = null,
      secretStore = null,
      providerRegistry = null,
      settingsRepository = null,
      _refreshService = null,
      _reconnectConnectionIds = null,
      _antigravityLocks = null,
      antigravityLocalRuntime = null;

  AppState.empty()
    : isLoading = false,
      accounts = const [],
      autoStartRefreshTimer = false,
      connectionRepository = null,
      connectionHealthRepository = null,
      quotaCacheRepository = null,
      secretStore = null,
      providerRegistry = null,
      settingsRepository = null,
      _refreshService = null,
      _reconnectConnectionIds = null,
      _antigravityLocks = null,
      antigravityLocalRuntime = null;

  AppState.pure({
    this.isLoading = false,
    this.accounts = const [],
  }) :
       autoStartRefreshTimer = false,
       connectionRepository = null,
       connectionHealthRepository = null,
       quotaCacheRepository = null,
       secretStore = null,
       providerRegistry = null,
       settingsRepository = null,
       _refreshService = null,
       _reconnectConnectionIds = null,
       _antigravityLocks = null,
       antigravityLocalRuntime = null;

  /// Factory for creating an [AppState] configured for tests with no active timers.
  factory AppState.test({
    ConnectionRepository? connectionRepository,
    ConnectionHealthRepository? connectionHealthRepository,
    QuotaCacheRepository? quotaCacheRepository,
    SecretStore? secretStore,
    ProviderRegistry? providerRegistry,
    SettingsRepository? settingsRepository,
    RefreshService? refreshService,
    List<AccountItem> accounts = const [],
    bool isLoading = false,
    AntigravityLocalRuntimeConfig? antigravityLocalRuntime,
  }) {
    return AppState(
      isLoading: isLoading,
      accounts: accounts,
      connectionRepository: connectionRepository,
      connectionHealthRepository: connectionHealthRepository,
      quotaCacheRepository: quotaCacheRepository,
      secretStore: secretStore,
      providerRegistry: providerRegistry,
      settingsRepository: settingsRepository,
      refreshService: refreshService,
      autoStartRefreshTimer: false,
      antigravityLocalRuntime: antigravityLocalRuntime,
    );
  }
  /// True while initial loading or database operations are in flight.
  bool isLoading;

  /// Currently loaded accounts.
  List<AccountItem> accounts;

  int refreshIntervalMinutes = defaultRefreshIntervalMinutes;
  int refreshIntervalRevision = 0;
  Future<void> refreshIntervalWriteQueue = Future<void>.value();
  final bool autoStartRefreshTimer;

  final ConnectionRepository? connectionRepository;
  final ConnectionHealthRepository? connectionHealthRepository;
  final QuotaCacheRepository? quotaCacheRepository;
  final SecretStore? secretStore;
  final ProviderRegistry? providerRegistry;
  final SettingsRepository? settingsRepository;
  final RefreshService? _refreshService;
  final Set<String>? _reconnectConnectionIds;
  final Map<String, Future<void>>? _antigravityLocks;
  final AntigravityLocalRuntimeConfig? antigravityLocalRuntime;

  bool requiresReconnect(String connectionId) =>
      _reconnectConnectionIds?.contains(connectionId) ?? false;

  RefreshService? get refreshService => _refreshService;

  /// Alias kept for call sites that read the open phase as [isOpening].
  bool get isOpening => isLoading;

  @override
  void dispose() {
    _refreshService?.removeSnapshotListener(_handleSnapshotUpdate);
    _refreshService?.removeDisabledListener(_handleCredentialDisabled);
    _refreshService?.dispose();
    super.dispose();
  }

  void _handleSnapshotUpdate(ProviderSnapshot snapshot) {
    final currentAccounts = accounts;
    final index = currentAccounts.indexWhere(
      (a) => a.connection.id == snapshot.connectionId,
    );
    if (index != -1) {
      final existing = currentAccounts[index];
      final updated = AccountItem(
        connection: snapshot.connection ?? existing.connection,
        snapshot: snapshot,
      );
      final updatedList = List<AccountItem>.from(currentAccounts);
      updatedList[index] = updated;
      accounts = updatedList;
      notifyListeners();
    }
  }

  void _handleCredentialDisabled(CredentialDisabledEvent event) {
    _reconnectConnectionIds?.add(event.connectionId);
    notifyListeners();
  }

  /// Refreshes quotas for a single connection.
  Future<void> refreshOne(String id) async {
    await _refreshService?.refreshOne(id);
  }

  /// Refreshes quotas for all enabled connections with concurrency cap.
  Future<void> refreshAll() async {
    await _refreshService?.refreshAll();
  }

  /// Loads all connections and their cached quotas and health.
  Future<void> load() async {
    isLoading = true;

    try {
      await _loadRefreshInterval();
      final repo = connectionRepository;
      if (repo == null) {
        accounts = const [];
        return;
      }
      // One read for connections (carrying the health already on their rows)
      // and one for every cached quota, instead of a keyed read per account
      // (audit C-17).
      final stored = await repo.getAllWithHealth();
      final ids = stored.map((entry) => entry.connection.id).toList();
      final cache = quotaCacheRepository;
      final quotasById = cache == null
          ? const <String, List<Quota>>{}
          : await cache.getAllForAll(ids);

      final items = <AccountItem>[];
      for (final entry in stored) {
        final conn = entry.connection;
        final health = entry.health;
        final snapshot = ProviderSnapshot(
          connectionId: conn.id,
          status: conn.enabled
              ? health?.status ?? ConnectionStatus.ok
              : ConnectionStatus.warning,
          quotas: quotasById[conn.id] ?? const <Quota>[],
          balance: null,
          fetchedAt: health?.lastCheckedAt ?? DateTime.now().toUtc(),
          error: health?.error,
          cooldownUntil: health?.cooldownUntil,
        );
        items.add(AccountItem(connection: conn, snapshot: snapshot));
      }
      accounts = items;
    } finally {
      isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _loadRefreshInterval() async {
    
    final revision = refreshIntervalRevision;
    try {
      final minutes = normalizeRefreshIntervalMinutes(
        await settingsRepository?.getRefreshIntervalMinutes() ??
            defaultRefreshIntervalMinutes,
      );
      if (refreshIntervalRevision != revision) return;
      refreshIntervalMinutes = minutes;
      if (autoStartRefreshTimer) {
        _refreshService?.updateIntervalMinutes(minutes == 0 ? null : minutes);
      }
    } catch (_) {
      if (refreshIntervalRevision != revision) return;
      refreshIntervalMinutes = defaultRefreshIntervalMinutes;
      if (autoStartRefreshTimer) {
        _refreshService?.updateIntervalMinutes(defaultRefreshIntervalMinutes);
      }
    }
  }

  Future<void> setRefreshIntervalMinutes(int minutes) async {
    validateRefreshIntervalMinutes(minutes);
    
    final revision = ++refreshIntervalRevision;
    final previousWrite = refreshIntervalWriteQueue;
    final writeGate = Completer<void>();
    refreshIntervalWriteQueue = writeGate.future;
    await previousWrite;
    try {
      await settingsRepository?.setRefreshIntervalMinutes(minutes);
    } finally {
      writeGate.complete();
    }
    if (refreshIntervalRevision != revision) return;
    _refreshService?.updateIntervalMinutes(minutes == 0 ? null : minutes);
    refreshIntervalMinutes = minutes;
    notifyListeners();
  }

  /// Adds a new connection using the compensation transaction:
  /// 1. Generate UUIDs for connection and secretRef.
  /// 2. Write secret to [secretStore].
  /// 3. Save connection to [connectionRepository].
  /// 4. On failure: roll back secret from [secretStore].
  Future<Connection> addConnection({
    required String provider,
    required String displayName,
    String? group,
    required String secret,
    String? plan,
    List<Quota> initialQuotas = const [],
    String? providerData,
  }) async {
    final store = secretStore;
    final repo = connectionRepository;
    if (store == null || repo == null) {
      throw StateError(
        'secretStore and connectionRepository must not be null to add a connection.',
      );
    }

    final connectionId = generateSecretRef();
    final secretRef = generateSecretRef();

    // 1 & 2: Write secret to secret store first
    await store.write(secretRef, secret);

    final connection = Connection(
      id: connectionId,
      provider: provider,
      displayName: displayName.trim(),
      group: (group != null && group.trim().isNotEmpty) ? group.trim() : null,
      plan: plan,
      credentialRef: secretRef,
      enabled: true,
      providerData: providerData,
    );

    // 3: Save connection
    try {
      await repo.save(connection);
      if (initialQuotas.isNotEmpty && quotaCacheRepository != null) {
        await quotaCacheRepository!.saveAll(connectionId, initialQuotas);
      }
    } catch (e) {
      // 4: Rollback secret on failure
      await store.delete(secretRef);
      rethrow;
    }

    await load();
    return connection;
  }

  /// Adds a local Antigravity connection without creating a secret-store
  /// entry. Only local read-only sources are accepted; remote OAuth is handled
  /// by [addAntigravityConnection].
  Future<Connection> addAntigravityLocalConnection({
    required String displayName,
    String? group,
    required String source,
    List<Quota> initialQuotas = const [],
  }) async {
    if (source != 'language-server' && source != 'agy-cli') {
      throw ArgumentError.value(source, 'source', 'Unsupported local source');
    }
    final repo = connectionRepository;
    if (repo == null) {
      throw StateError('connectionRepository is required.');
    }
    final connection = Connection(
      id: generateSecretRef(),
      provider: 'antigravity',
      displayName: displayName.trim(),
      group: (group != null && group.trim().isNotEmpty) ? group.trim() : null,
      plan: null,
      credentialRef: '',
      enabled: true,
      authType: AuthKind.none.name,
      providerData: jsonEncode({'source': source}),
    );
    try {
      await repo.save(connection);
      if (initialQuotas.isNotEmpty && quotaCacheRepository != null) {
        await quotaCacheRepository!.saveAll(connection.id, initialQuotas);
      }
    } catch (error, stackTrace) {
      try {
        await repo.delete(connection.id);
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
    await load();
    return connection;
  }

  /// Updates a local Antigravity connection without requiring or touching the
  /// SecretStore. Provider metadata is immutable in this phase and therefore
  /// preserved as-is.
  Future<Connection> updateAntigravityLocalConnection({
    required Connection existing,
    required String displayName,
    String? group,
    List<Quota>? newQuotas,
    bool clearSchemaQuarantine = false,
  }) async {
    if (existing.provider != 'antigravity' ||
        !_isLocalAntigravitySource(existing.providerData)) {
      throw ArgumentError.value(
        existing.id,
        'existing',
        'Connection must use a local Antigravity source',
      );
    }
    final repo = connectionRepository;
    if (repo == null) {
      throw StateError('connectionRepository is required.');
    }
    final updated = Connection(
      id: existing.id,
      provider: existing.provider,
      displayName: displayName.trim(),
      group: (group != null && group.trim().isNotEmpty) ? group.trim() : null,
      plan: existing.plan,
      credentialRef: existing.credentialRef,
      enabled: existing.enabled,
      authType: existing.authType,
      identityKey: existing.identityKey,
      providerData: clearSchemaQuarantine
          ? _withoutSchemaQuarantine(existing.providerData)
          : existing.providerData,
    );
    try {
      await repo.save(updated);
      if (newQuotas != null && quotaCacheRepository != null) {
        await quotaCacheRepository!.saveAll(updated.id, newQuotas);
      }
    } catch (error, stackTrace) {
      try {
        await repo.save(existing);
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
    await load();
    _reconnectConnectionIds?.remove(updated.id);
    notifyListeners();
    return updated;
  }

  /// Runs the Antigravity loopback login and persists the returned account
  /// metadata together with the connection row. Credentials remain in the
  /// supplied SecretStore under the connection's secret ref.
  Future<Connection> addAntigravityConnection({
    required String displayName,
    String? group,
    AntigravityOAuthProvider? provider,
    Future<void>? cancellation,
  }) async {
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not be empty',
      );
    }
    final store = secretStore;
    final repo = connectionRepository;
    if (store == null || repo == null) {
      throw StateError('secretStore and connectionRepository are required.');
    }
    final id = generateSecretRef();
    final ref = generateSecretRef();
    // Cancellation is observed only immediately after a genuinely asynchronous
    // step, where the completer's callback has provably already run. The
    // previous implementation interleaved `await Future<void>.value()` no-ops
    // between the checks, which yield the microtask queue exactly once and
    // therefore cannot be relied on to observe a macrotask-sourced cancel.
    final cancelWatch = _CancellationWatch(cancellation);
    final provisional = Connection(
      id: id,
      provider: 'antigravity',
      displayName: displayName.trim(),
      group: (group != null && group.trim().isNotEmpty) ? group.trim() : null,
      plan: null,
      credentialRef: ref,
      enabled: true,
      authType: AuthKind.oauth.name,
    );
    try {
      final registered = providerRegistry?.get('antigravity');
      final selectedProvider =
          provider ??
          (registered is AntigravityOAuthProvider ? registered : null);
      if (selectedProvider == null) {
        throw StateError('Antigravity OAuth provider is not registered');
      }
      final result = await selectedProvider.loginWithLoopback(
        provisional,
        cancellation: cancellation,
      );
      cancelWatch.throwIfCancelled();

      await store.write(ref, result.secret);
      cancelWatch.throwIfCancelled();

      final connection = Connection(
        id: id,
        provider: 'antigravity',
        displayName: provisional.displayName,
        group: provisional.group,
        plan: result.tier,
        credentialRef: ref,
        enabled: true,
        authType: AuthKind.oauth.name,
        identityKey: result.identityKey,
        providerData: jsonEncode({
          'source': 'remote',
          'projectId': result.projectId,
          'tier': result.tier,
        }),
      );
      await repo.save(connection);
      cancelWatch.throwIfCancelled();

      await load();
      cancelWatch.throwIfCancelled();
      return connection;
    } catch (_) {
      // Every exit path, cancellation or failure alike, unwinds through here,
      // so a partially committed connection can never survive. Cleanup is
      // best-effort and must never replace the error that triggered it.
      await _discardPartialConnection(
        repo: repo,
        store: store,
        id: id,
        ref: ref,
      );
      rethrow;
    }
  }

  /// Removes a connection row and its credential without letting a cleanup
  /// failure mask the original error.
  static Future<void> _discardPartialConnection({
    required ConnectionRepository repo,
    required SecretStore store,
    required String id,
    required String ref,
  }) async {
    try {
      await repo.delete(id);
    } catch (_) {
      // Reported through the original failure, not this one.
    }
    try {
      await store.delete(ref);
    } catch (_) {
      // Reported through the original failure, not this one.
    }
  }

  Future<Connection> reconnectAntigravityConnection(
    Connection existing,
    String displayName,
    String? group, {
    AntigravityOAuthProvider? provider,
    Future<void>? cancellation,
  }) {
    final service = _refreshService;
    var queuedCancellation = false;
    cancellation?.then((_) => queuedCancellation = true);
    final operation = () {
      if (queuedCancellation) {
        return Future<Connection>.error(const AntigravityLoginCancelled());
      }
      return _reconnectAntigravityConnectionLocked(
        existing,
        displayName,
        group,
        provider: provider,
        cancellation: cancellation,
      );
    };
    if (service != null) {
      return service.runConnectionOperation(
        connectionId: existing.id,
        operation: operation,
      );
    }
    return operation();
  }

  Future<Connection> _reconnectAntigravityConnectionLocked(
    Connection existing,
    String displayName,
    String? group, {
    AntigravityOAuthProvider? provider,
    Future<void>? cancellation,
  }) async {
    if (displayName.trim().isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not be empty',
      );
    }
    final store = secretStore;
    final repo = connectionRepository;
    if (store == null || repo == null) {
      throw StateError('secretStore and connectionRepository are required.');
    }
    final locks = _antigravityLocks;
    final previous = locks?[existing.id];
    final gate = Completer<void>();
    final cancelWatch = _CancellationWatch(cancellation);
    if (locks != null) locks[existing.id] = gate.future;
    if (previous != null) await previous;
    try {
      cancelWatch.throwIfCancelled();
      final current = await repo.getById(existing.id);
      if (current == null)
        throw StateError('Antigravity connection no longer exists');
      final registered = providerRegistry?.get('antigravity');
      final selectedProvider =
          provider ??
          (registered is AntigravityOAuthProvider ? registered : null);
      if (selectedProvider == null) {
        throw StateError('Antigravity OAuth provider is not registered');
      }
      final newRef = generateSecretRef();
      final provisional = Connection(
        id: current.id,
        provider: current.provider,
        displayName: displayName.trim(),
        group: (group != null && group.trim().isNotEmpty) ? group.trim() : null,
        plan: current.plan,
        credentialRef: newRef,
        enabled: current.enabled,
        authType: AuthKind.oauth.name,
        identityKey: current.identityKey,
        providerData: current.providerData,
      );
      var newSecretWritten = false;
      var oldSecretDeleted = false;
      var rowSaved = false;
      try {
        final result = await selectedProvider.loginWithLoopback(
          provisional,
          cancellation: cancellation,
        );
        cancelWatch.throwIfCancelled();
        await store.write(newRef, result.secret);
        newSecretWritten = true;
        cancelWatch.throwIfCancelled();
        final replacement = Connection(
          id: current.id,
          provider: current.provider,
          displayName: provisional.displayName,
          group: provisional.group,
          plan: result.tier,
          credentialRef: newRef,
          enabled: current.enabled,
          authType: AuthKind.oauth.name,
          identityKey: result.identityKey,
          providerData: jsonEncode({
            'source': 'remote',
            'projectId': result.projectId,
            'tier': result.tier,
          }),
        );
        await repo.save(replacement);
        rowSaved = true;
        cancelWatch.throwIfCancelled();
        await load();
        cancelWatch.throwIfCancelled();
        try {
          await store.delete(current.credentialRef);
          oldSecretDeleted = true;
        } catch (error) {
          _refreshService?.scheduleCredentialCleanup(
            current.id,
            current.credentialRef,
          );
          if (_refreshService == null) rethrow;
        }
        cancelWatch.throwIfCancelled();
        _reconnectConnectionIds?.remove(current.id);
        notifyListeners();
        return replacement;
      } catch (error, stackTrace) {
        if (oldSecretDeleted) {
          _reconnectConnectionIds?.remove(current.id);
          notifyListeners();
          Error.throwWithStackTrace(error, stackTrace);
        }
        if (cancelWatch.isRequested) {
          _refreshService?.cancelCredentialCleanup(current.credentialRef);
        }
        var rowRestored = !rowSaved;
        if (rowSaved) {
          try {
            await repo.save(current);
            rowRestored = true;
          } catch (_) {}
        }
        if (newSecretWritten && rowRestored) {
          try {
            await store.delete(newRef);
          } catch (cleanupError) {
            _refreshService?.scheduleCredentialCleanup(current.id, newRef);
          }
        }
        Error.throwWithStackTrace(error, stackTrace);
      }
    } finally {
      gate.complete();
      if (locks != null && identical(locks[existing.id], gate.future)) {
        locks.remove(existing.id);
      }
    }
  }

  /// Updates an existing connection using credential replacement compensation:
  /// 1. If secret was changed: write new secret under newSecretRef.
  /// 2. Save updated connection to [connectionRepository].
  /// 3. If save succeeds: delete old secret.
  /// 4. If save fails: delete newly written secret.
  Future<Connection> updateConnection({
    required Connection existing,
    required String displayName,
    String? group,
    String? newSecret,
    String? plan,
    List<Quota>? newQuotas,
    bool clearSchemaQuarantine = false,
  }) async {
    final store = secretStore;
    final repo = connectionRepository;
    if (store == null || repo == null) {
      throw StateError(
        'secretStore and connectionRepository must not be null to update a connection.',
      );
    }

    final bool secretChanged = newSecret != null && newSecret.trim().isNotEmpty;
    String targetSecretRef = existing.credentialRef;
    String? newSecretRef;

    if (secretChanged) {
      newSecretRef = generateSecretRef();
      await store.write(newSecretRef, newSecret.trim());
      targetSecretRef = newSecretRef;
    }

    final updatedConnection = Connection(
      id: existing.id,
      provider: existing.provider,
      displayName: displayName.trim(),
      group: (group != null && group.trim().isNotEmpty) ? group.trim() : null,
      plan: plan ?? existing.plan,
      credentialRef: targetSecretRef,
      enabled: existing.enabled,
      authType: existing.authType,
      identityKey: existing.identityKey,
      providerData: clearSchemaQuarantine
          ? _withoutSchemaQuarantine(existing.providerData)
          : existing.providerData,
    );

    var rowSaved = false;
    try {
      await repo.save(updatedConnection);
      rowSaved = true;
      if (newQuotas != null && quotaCacheRepository != null) {
        await quotaCacheRepository!.saveAll(existing.id, newQuotas);
      }
    } catch (error, stackTrace) {
      var restored = !rowSaved;
      if (rowSaved) {
        try {
          await repo.save(existing);
          restored = true;
        } catch (_) {
          // Keep the replacement secret if the row cannot be restored.
        }
      }
      if (secretChanged && newSecretRef != null && restored) {
        await store.delete(newSecretRef);
      }
      Error.throwWithStackTrace(error, stackTrace);
    }

    if (secretChanged && newSecretRef != null) {
      try {
        await store.delete(existing.credentialRef);
      } catch (_) {
        // Recoverable cleanup error
      }
    }

    await load();
    _reconnectConnectionIds?.remove(existing.id);
    notifyListeners();
    return updatedConnection;
  }

  /// Convenience method handling both add and update.
  Future<Connection> saveConnection({
    Connection? existing,
    required String provider,
    required String displayName,
    String? group,
    String? secret,
    String? plan,
    List<Quota>? quotas,
  }) async {
    if (existing == null) {
      return addConnection(
        provider: provider,
        displayName: displayName,
        group: group,
        secret: secret ?? '',
        plan: plan,
        initialQuotas: quotas ?? const [],
      );
    } else {
      return updateConnection(
        existing: existing,
        displayName: displayName,
        group: group,
        newSecret: secret,
        plan: plan,
        newQuotas: quotas,
      );
    }
  }

  /// Removes a connection:
  /// 1. Delete connection in database first (cascading quota cache).
  /// 2. Then delete secret from [secretStore].
  /// 3. If secret deletion fails, returns a warning message.
  Future<String?> removeConnection(String id) async {
    final repo = connectionRepository;
    final store = secretStore;
    if (repo == null) {
      throw StateError(
        'connectionRepository must not be null to remove a connection.',
      );
    }

    final target = await repo.getById(id);

    // 1: Delete in database first
    await repo.delete(id);

    // 2: Delete secret
    String? warning;
    if (target != null &&
        store != null &&
        target.credentialRef.isNotEmpty &&
        target.authType != AuthKind.none.name) {
      try {
        await store.delete(target.credentialRef);
      } catch (e) {
        _refreshService?.scheduleCredentialCleanup(
          target.id,
          target.credentialRef,
        );
        warning = 'Connection deleted, but credential could not be removed from secure storage.';
      }
    }

    await load();
    return warning;
  }

  /// Toggles connection enabled status.
  Future<void> toggleConnectionEnabled(String id, bool enabled) async {
    final repo = connectionRepository;
    if (repo == null) {
      throw StateError(
        'connectionRepository must not be null to toggle connection.',
      );
    }
    final target = await repo.getById(id);
    if (target == null) return;

    final updated = Connection(
      id: target.id,
      provider: target.provider,
      displayName: target.displayName,
      group: target.group,
      plan: target.plan,
      credentialRef: target.credentialRef,
      enabled: enabled,
      authType: target.authType,
      identityKey: target.identityKey,
      providerData: target.providerData,
    );
    await repo.save(updated);
    await load();
  }

  /// Tests a connection against its provider adapter.
  Future<TestResult> testConnection({
    required String provider,
    required String displayName,
    String? group,
    required String secret,

    String? id,
    ProviderAdapter? customAdapter,
    Connection? connection,
    bool preferStoredSecret = false,
  }) async {
    final normalizedProvider = provider.trim().toLowerCase();
    final adapter =
        customAdapter ??
        providerRegistry?.get(normalizedProvider) ??
        providerRegistry?.get(provider) ??
        ProviderRegistry.instance.get(normalizedProvider) ??
        ProviderRegistry.instance.get(provider);
    if (adapter == null) {
      return TestResult.failure(error: 'Unknown provider "$provider"');
    }
    final testConnection =
        connection ??
        Connection(
          id: id ?? 'temp-test-connection',
          provider: normalizedProvider,
          displayName: displayName,
          group: group,
          plan: null,
          credentialRef: '',
          enabled: true,
        );
    final service = _refreshService;
    if (service == null) return adapter.test(testConnection, secret);
    return service.testAdapter(
      adapter: adapter,
      connection: testConnection,
      secret: secret,
      preferStoredSecret: preferStoredSecret,
    );
  }
}

String? _withoutSchemaQuarantine(String? providerData) {
  if (providerData == null || providerData.isEmpty) return providerData;
  try {
    final decoded = jsonDecode(providerData);
    if (decoded is! Map) return providerData;
    return jsonEncode(
      Map<String, dynamic>.from(decoded)..remove('quotaSourceDisabled'),
    );
  } catch (_) {
    return providerData;
  }
}

bool _isLocalAntigravitySource(String? providerData) {
  if (providerData == null) return false;
  try {
    final decoded = jsonDecode(providerData);
    if (decoded is! Map) return false;
    final source = decoded['source']?.toString();
    return source == 'language-server' || source == 'agy-cli';
  } catch (_) {
    return false;
  }
}
