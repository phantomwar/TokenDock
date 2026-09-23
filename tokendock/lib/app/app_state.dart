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
import '../providers/antigravity/antigravity_oauth.dart';
import '../storage/connection_health_repository.dart';
import '../storage/connection_repository.dart';
import '../storage/quota_cache_repository.dart';
import '../storage/secret_store.dart';
import '../storage/settings_repository.dart';

/// One account pairing a [Connection] with its latest [ProviderSnapshot].
///
/// Immutable value holder for the widget surface. Never performs persistence
/// or network work; later tasks hydrate it from the database and providers.
class AccountItem {
  const AccountItem({required this.connection, required this.snapshot});

  final Connection connection;
  final ProviderSnapshot snapshot;
}

class _StateNotifier extends ChangeNotifier {
  _StateNotifier(this.isLoading, this.accounts);

  bool isLoading;
  List<AccountItem> accounts;

  void notify() => notifyListeners();
}

/// Widget-surface state for [TokenDockWidget] and application-level connection
/// management.
///
/// Implements [ChangeNotifier] for reactive updates while retaining const
/// constructors for testing and loading shells.
class AppState implements ChangeNotifier {
  AppState({
    bool isLoading = false,
    List<AccountItem> accounts = const [],
    this.connectionRepository,
    this.connectionHealthRepository,
    this.quotaCacheRepository,
    this.secretStore,
    this.providerRegistry,
    this.settingsRepository,
    RefreshService? refreshService,
    bool autoStartRefreshTimer = false,
  }) : _staticLoading = false,
       _staticAccounts = const [],
       _notifier = _StateNotifier(isLoading, accounts),
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
                   autoStartTimer: autoStartRefreshTimer,
                 )
               : null) {
    _refreshService?.addSnapshotListener(_handleSnapshotUpdate);
  }

  const AppState.loading()
    : _staticLoading = true,
      _staticAccounts = const [],
      _notifier = null,
      connectionRepository = null,
      connectionHealthRepository = null,
      quotaCacheRepository = null,
      secretStore = null,
      providerRegistry = null,
      settingsRepository = null,
      _refreshService = null;

  const AppState.empty()
    : _staticLoading = false,
      _staticAccounts = const [],
      _notifier = null,
      connectionRepository = null,
      connectionHealthRepository = null,
      quotaCacheRepository = null,
      secretStore = null,
      providerRegistry = null,
      settingsRepository = null,
      _refreshService = null;

  const AppState.pure({
    bool isLoading = false,
    List<AccountItem> accounts = const [],
  }) : _staticLoading = isLoading,
       _staticAccounts = accounts,
       _notifier = null,
       connectionRepository = null,
       connectionHealthRepository = null,
       quotaCacheRepository = null,
       secretStore = null,
       providerRegistry = null,
       settingsRepository = null,
       _refreshService = null;

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
    );
  }
  final bool _staticLoading;
  final List<AccountItem> _staticAccounts;
  final _StateNotifier? _notifier;

  static final Expando<_StateNotifier> _fallbackNotifiers =
      Expando<_StateNotifier>();

  _StateNotifier get _effectiveNotifier {
    if (_notifier != null) return _notifier;
    return _fallbackNotifiers[this] ??= _StateNotifier(
      _staticLoading,
      _staticAccounts,
    );
  }

  final ConnectionRepository? connectionRepository;
  final ConnectionHealthRepository? connectionHealthRepository;
  final QuotaCacheRepository? quotaCacheRepository;
  final SecretStore? secretStore;
  final ProviderRegistry? providerRegistry;
  final SettingsRepository? settingsRepository;
  final RefreshService? _refreshService;

  RefreshService? get refreshService => _refreshService;

  /// True while initial loading or database operations are in flight.
  bool get isLoading => _effectiveNotifier.isLoading;

  /// Alias kept for call sites that read the open phase as [isOpening].
  bool get isOpening => isLoading;

  /// Currently loaded accounts.
  List<AccountItem> get accounts => _effectiveNotifier.accounts;

  @override
  void addListener(VoidCallback listener) {
    _effectiveNotifier.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _effectiveNotifier.removeListener(listener);
  }

  @override
  void notifyListeners() {
    _effectiveNotifier.notify();
  }

  @override
  bool get hasListeners => _effectiveNotifier.hasListeners;

  @override
  void dispose() {
    _refreshService?.removeSnapshotListener(_handleSnapshotUpdate);
    _refreshService?.dispose();
    _effectiveNotifier.dispose();
  }

  void _handleSnapshotUpdate(ProviderSnapshot snapshot) {
    final currentAccounts = _effectiveNotifier.accounts;
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
      _effectiveNotifier.accounts = updatedList;
      _effectiveNotifier.notify();
    }
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
    _effectiveNotifier.isLoading = true;

    try {
      final repo = connectionRepository;
      if (repo == null) {
        _effectiveNotifier.accounts = const [];
        return;
      }
      final connections = await repo.getAll();
      final items = <AccountItem>[];

      for (final conn in connections) {
        final cachedQuotas =
            await quotaCacheRepository?.getAll(conn.id) ?? const <Quota>[];
        final health = await connectionHealthRepository?.get(conn.id);
        final snapshot = ProviderSnapshot(
          connectionId: conn.id,
          status: conn.enabled
              ? health?.status ?? ConnectionStatus.ok
              : ConnectionStatus.warning,
          quotas: cachedQuotas,
          balance: null,
          fetchedAt: health?.lastCheckedAt ?? DateTime.now().toUtc(),
          error: health?.error,
          cooldownUntil: health?.cooldownUntil,
        );
        items.add(AccountItem(connection: conn, snapshot: snapshot));
      }
      _effectiveNotifier.accounts = items;
    } finally {
      _effectiveNotifier.isLoading = false;
      _effectiveNotifier.notify();
    }
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
  /// Runs the Antigravity loopback login and persists the returned account
  /// metadata together with the connection row. Credentials remain in the
  /// supplied SecretStore under the connection's secret ref.
  Future<Connection> addAntigravityConnection({
    required String displayName,
    String? group,
    AntigravityOAuthProvider? provider,
  }) async {
    final store = secretStore;
    final repo = connectionRepository;
    if (store == null || repo == null) {
      throw StateError('secretStore and connectionRepository are required.');
    }
    final id = generateSecretRef();
    final ref = generateSecretRef();
    final provisional = Connection(
      id: id,
      provider: 'antigravity',
      displayName: displayName.trim(),
      group: group,
      plan: null,
      credentialRef: ref,
      enabled: true,
      authType: 'oauth',
    );
    try {
      final selectedProvider = provider ?? (providerRegistry?.get('antigravity') as AntigravityOAuthProvider?);
      if (selectedProvider == null) throw StateError('Antigravity OAuth provider is not registered');
      AntigravityOAuthLoginResult? loginResult;
      final secretValue = await (_refreshService?.runTokenOperation(
        connectionId: provisional.id,
        operation: () async {
          loginResult = await selectedProvider.loginWithLoopback(provisional);
          return loginResult!.secret;
        },
      ) ?? selectedProvider.loginWithLoopback(provisional).then((value) {
        loginResult = value;
        return value.secret;
      }));
      final result = loginResult!;
      await store.write(ref, secretValue);
      final connection = Connection(
        id: id,
        provider: 'antigravity',
        displayName: provisional.displayName,
        group: group,
        plan: result.tier,
        credentialRef: ref,
        enabled: true,
        authType: 'oauth',
        identityKey: result.identityKey,
        providerData: jsonEncode({'projectId': result.projectId, 'tier': result.tier}),
      );
      await repo.save(connection);
      await load();
      return connection;
    } catch (error) {
      try { await repo.delete(id); } finally { await store.delete(ref); }
      rethrow;
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
      providerData: existing.providerData,
    );

    try {
      await repo.save(updatedConnection);
      if (newQuotas != null && quotaCacheRepository != null) {
        await quotaCacheRepository!.saveAll(existing.id, newQuotas);
      }
    } catch (e) {
      if (secretChanged && newSecretRef != null) {
        await store.delete(newSecretRef);
      }
      rethrow;
    }

    if (secretChanged && newSecretRef != null) {
      try {
        await store.delete(existing.credentialRef);
      } catch (_) {
        // Recoverable cleanup error
      }
    }

    await load();
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

    final connections = await repo.getAll();
    final target = connections.where((c) => c.id == id).firstOrNull;

    // 1: Delete in database first
    await repo.delete(id);

    // 2: Delete secret
    String? warning;
    if (target != null && store != null) {
      try {
        await store.delete(target.credentialRef);
      } catch (e) {
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
    final connections = await repo.getAll();
    final target = connections.where((c) => c.id == id).firstOrNull;
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
    final connection = Connection(
      id: id ?? 'temp-test-connection',
      provider: normalizedProvider,
      displayName: displayName,
      group: group,
      plan: null,
      credentialRef: '',
      enabled: true,
    );
    return adapter.test(connection, secret);
  }
}
