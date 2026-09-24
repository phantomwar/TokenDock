import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/providers/antigravity/antigravity_local.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/models/test_result.dart';
import 'package:tokendock/services/refreshable_credential.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';
import 'package:tokendock/storage/settings_repository.dart';

import '../support/controlled_provider.dart';
import '../support/memory_secret_store.dart';

import 'package:tokendock/storage/connection_repository.dart';

import '../support/test_database.dart';

import 'package:tokendock/storage/secret_store.dart';

class _GatedSecretStore implements SecretStore {
  _GatedSecretStore(this.delegate, this.writeStarted, this.writeGate);
  final SecretStore delegate;
  final Completer<void> writeStarted;
  final Completer<void> writeGate;
  @override
  Future<void> write(String key, String value) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await writeGate.future;
    await delegate.write(key, value);
  }

  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> delete(String key) => delegate.delete(key);
}

class _GatedDeleteSecretStore implements SecretStore {
  _GatedDeleteSecretStore(
    this.delegate,
    this.deleteStarted,
    this.deleteGate,
    this.deleteCompleted,
    this.postDeleteGate,
  );

  final SecretStore delegate;
  final Completer<void> deleteStarted;
  final Completer<void> deleteGate;
  final Completer<void> deleteCompleted;
  final Completer<void> postDeleteGate;

  @override
  Future<void> write(String key, String value) => delegate.write(key, value);

  @override
  Future<String?> read(String key) => delegate.read(key);

  @override
  Future<void> delete(String key) async {
    if (!deleteStarted.isCompleted) deleteStarted.complete();
    await deleteGate.future;
    await delegate.delete(key);
    if (!deleteCompleted.isCompleted) deleteCompleted.complete();
    await postDeleteGate.future;
  }
}

class _DeleteFailingSecretStore implements SecretStore {
  _DeleteFailingSecretStore(this.delegate, this.failingKey);
  final SecretStore delegate;
  final String failingKey;
  @override
  Future<void> write(String key, String value) => delegate.write(key, value);
  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> delete(String key) async {
    if (key == failingKey) throw StateError('delete failed');
    await delegate.delete(key);
  }
}

class _RetryDeleteStore implements SecretStore {
  _RetryDeleteStore(this.delegate, this.retryAttempted);
  final SecretStore delegate;
  final Completer<void> retryAttempted;
  int attempts = 0;
  @override
  Future<void> write(String key, String value) => delegate.write(key, value);
  @override
  Future<String?> read(String key) => delegate.read(key);
  @override
  Future<void> delete(String key) async {
    attempts++;
    if (attempts == 1) throw StateError('temporary delete failure');
    if (!retryAttempted.isCompleted) retryAttempted.complete();
    await delegate.delete(key);
  }
}

class _QueuedSettingsRepository implements SettingsRepository {
  final Map<String, String> values = {};
  final List<int> startedWrites = [];
  final List<Completer<void>> writeGates = [];

  @override
  Future<String?> get(String key) async => values[key];

  @override
  Future<void> set(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<int> getRefreshIntervalMinutes() async => 3;

  @override
  Future<void> setRefreshIntervalMinutes(int minutes) async {
    startedWrites.add(minutes);
    final gate = Completer<void>();
    writeGates.add(gate);
    await gate.future;
    await set('refresh_interval_minutes', '$minutes');
  }

  void completeWrite(int index) => writeGates[index].complete();
}

class _LoadFailingRepository implements ConnectionRepository {
  _LoadFailingRepository(this.delegate);
  final ConnectionRepository delegate;
  int reads = 0;
  @override
  Future<List<Connection>> getAll() async {
    reads++;
    if (reads == 2) throw StateError('load failed');
    return delegate.getAll();
  }

  @override
  Future<void> save(Connection connection) => delegate.save(connection);
  @override
  Future<void> delete(String id) => delegate.delete(id);
}

class _RestoreFailingRepository implements ConnectionRepository {
  _RestoreFailingRepository(this.delegate);
  final ConnectionRepository delegate;
  bool replacementSaved = false;
  int reads = 0;
  @override
  Future<List<Connection>> getAll() async {
    reads++;
    if (reads == 2) throw StateError('load failed');
    return delegate.getAll();
  }

  @override
  Future<void> save(Connection connection) async {
    if (connection.credentialRef == 'old-restore-secret' && replacementSaved) {
      throw StateError('restore failed');
    }
    if (connection.credentialRef != 'old-restore-secret')
      replacementSaved = true;
    await delegate.save(connection);
  }

  @override
  Future<void> delete(String id) => delegate.delete(id);
}

class _LoadGateRepository implements ConnectionRepository {
  _LoadGateRepository(this.delegate, this.loadStarted, this.loadGate);
  final ConnectionRepository delegate;
  final Completer<void> loadStarted;
  final Completer<void> loadGate;
  int reads = 0;
  @override
  Future<List<Connection>> getAll() async {
    reads++;
    if (reads == 1) {
      loadStarted.complete();
      await loadGate.future;
    }
    return delegate.getAll();
  }

  @override
  Future<void> save(Connection connection) => delegate.save(connection);
  @override
  Future<void> delete(String id) => delegate.delete(id);
}

class _SequencedOAuthProvider extends AntigravityOAuthProvider {
  _SequencedOAuthProvider(this.gates, this.results)
    : super(launchExternalBrowser: (_) async {});
  final List<Completer<AntigravityOAuthLoginResult>> gates;
  final List<AntigravityOAuthLoginResult> results;
  final Completer<void> firstCallStarted = Completer<void>();
  int calls = 0;
  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) {
    final index = calls++;
    if (!firstCallStarted.isCompleted) firstCallStarted.complete();
    if (index < gates.length) return gates[index].future;
    return Future.value(results[index]);
  }
}
class _ProvisionalWritingProvider extends AntigravityOAuthProvider {
  _ProvisionalWritingProvider(this.store, this.gate)
      : super(launchExternalBrowser: (_) async {});
  final SecretStore store;
  final Completer<void> gate;
  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {Future<void>? cancellation}) async {
    await store.write(connection.credentialRef, 'provider-owned');
    await gate.future;
    return const AntigravityOAuthLoginResult(
      secret: 'provider-owned', identityKey: 'a@b|c', projectId: 'p', tier: 'free',
    );
  }
}

class _FailingQuotaCacheRepository implements QuotaCacheRepository {
  @override
  Future<List<Quota>> getAll(String connectionId) async => const [];

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    throw StateError('cache unavailable');
  }

  @override
  Future<void> deleteForConnection(String connectionId) async {}
}

class _RotatingProvider implements ProviderAdapter {
  @override
  String get id => 'antigravity';

  @override
  String get name => 'Rotating';

  @override
  AuthKind get authKind => AuthKind.oauth;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };

  @override
  RefreshableCredential? refreshableCredential(String secret) =>
      _RotatingCredential();

  @override
  Future<TestResult> test(Connection connection, String secret) async =>
      TestResult.success();

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async =>
      ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.ok,
        quotas: const [],
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: null,
      );
}

class _RotatingCredential implements RefreshableCredential {
  @override
  DateTime? get expiresAt =>
      DateTime.now().toUtc().subtract(const Duration(minutes: 2));

  @override
  Duration get refreshLead => const Duration(minutes: 1);

  @override
  Future<String> refresh(String currentSecret) async => 'rotated-secret';
}

class _ControlledAntigravityOAuthProvider extends AntigravityOAuthProvider {
  _ControlledAntigravityOAuthProvider(this.result)
    : super(launchExternalBrowser: (_) async {});

  AntigravityOAuthLoginResult result;

  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) async {
    return result;
  }
}

void main() {
  test('load restores cached quotas and persisted cooldown health', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    const connection = Connection(
      id: 'conn-restored',
      provider: 'openrouter',
      displayName: 'Restored',
      group: null,
      plan: null,
      credentialRef: 'secret-restored',
      enabled: true,
    );
    await testDb.connectionRepository.save(connection);
    await testDb.quotaCacheRepository.saveAll('conn-restored', const [
      Quota(
        id: 'cached-usage',
        label: 'Cached usage',
        percent: 25,
        remaining: 75,
        limit: 100,
        unit: 'requests',
        resetAt: null,
      ),
    ]);
    final checkedAt = DateTime.now().toUtc();
    final cooldownUntil = checkedAt.add(const Duration(minutes: 2));
    await testDb.connectionHealthRepository.save(
      ConnectionHealth(
        connectionId: 'conn-restored',
        status: ConnectionStatus.warning,
        lastCheckedAt: checkedAt,
        cooldownUntil: cooldownUntil,
        error: 'Rate limited',
      ),
    );

    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      connectionHealthRepository: testDb.connectionHealthRepository,
      secretStore: MemorySecretStore(),
    );
    addTearDown(state.dispose);

    await state.load();

    final snapshot = state.accounts.single.snapshot;
    expect(snapshot.status, ConnectionStatus.warning);
    expect(snapshot.cooldownUntil, cooldownUntil);
    expect(snapshot.error, 'Rate limited');
    expect(snapshot.quotas.single.id, 'cached-usage');
    expect(snapshot.quotas.single.remaining, 75.0);
  });
  test(
    'load retains warning for disabled connection with healthy history',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const connection = Connection(
        id: 'conn-disabled',
        provider: 'openrouter',
        displayName: 'Disabled',
        group: null,
        plan: null,
        credentialRef: 'secret-disabled',
        enabled: false,
      );
      await testDb.connectionRepository.save(connection);
      await testDb.connectionHealthRepository.save(
        ConnectionHealth(
          connectionId: connection.id,
          status: ConnectionStatus.ok,
          lastCheckedAt: DateTime.now().toUtc(),
          cooldownUntil: null,
          error: null,
        ),
      );

      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        connectionHealthRepository: testDb.connectionHealthRepository,
      );
      addTearDown(state.dispose);

      await state.load();

      expect(state.accounts.single.snapshot.status, ConnectionStatus.warning);
    },
  );
  test(
    'more than three connections persist and restore without a count limit',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      final store = MemorySecretStore();
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);

      for (final name in const [
        'Production',
        'Personal',
        'Client',
        'Research',
      ]) {
        await state.addConnection(
          provider: 'openrouter',
          displayName: name,
          secret: 'secret-$name',
        );
      }

      final restored = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(restored.dispose);
      await restored.load();

      expect(
        restored.accounts.map((account) => account.connection.displayName),
        containsAll(const ['Production', 'Personal', 'Client', 'Research']),
      );
      expect(restored.accounts, hasLength(4));
    },
  );

  test(
    'metadata, SQLite CSRF custody, and disabled-event state remain correct',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      final connection = Connection(
        id: 'conn-metadata-preserved',
        provider: 'antigravity',
        displayName: 'Original',
        group: null,
        plan: null,
        authType: 'oauth',
        identityKey: 'account-id',
        providerData: jsonEncode({
          'workspace': 'production',
          'csrfToken': 'must-not-persist',
        }),
        credentialRef: 'secret-metadata-preserved',
        enabled: true,
      );
      await testDb.connectionRepository.save(connection);
      final runtime = AntigravityLocalRuntimeConfig();
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        secretStore: MemorySecretStore(),
        antigravityLocalRuntime: runtime,
      );
      addTearDown(state.dispose);

      await state.updateConnection(existing: connection, displayName: 'Edited');
      final edited = (await testDb.connectionRepository.getAll()).single;
      expect(edited.displayName, 'Edited');
      expect(edited.authType, 'oauth');
      expect(edited.identityKey, 'account-id');
      expect(edited.providerData, isNot(contains('must-not-persist')));
      expect(edited.providerData, isNot(contains('csrf')));

      await state.toggleConnectionEnabled(connection.id, false);
      final toggled = (await testDb.connectionRepository.getAll()).single;
      expect(toggled.enabled, isFalse);
      expect(toggled.authType, 'oauth');
      expect(toggled.identityKey, 'account-id');
      expect(toggled.providerData, isNot(contains('must-not-persist')));

      final quarantined = Connection(
        id: connection.id,
        provider: connection.provider,
        displayName: connection.displayName,
        group: connection.group,
        plan: connection.plan,
        authType: connection.authType,
        identityKey: connection.identityKey,
        providerData: jsonEncode({
          'workspace': 'production',
          'quotaSourceDisabled': 'quota_source_changed',
        }),
        credentialRef: connection.credentialRef,
        enabled: false,
      );
      await testDb.connectionRepository.save(quarantined);
      final revalidated = await state.updateConnection(
        existing: quarantined,
        displayName: 'Revalidated',
        clearSchemaQuarantine: true,
      );
      expect(revalidated.enabled, isFalse);
      expect(revalidated.providerData, isNot(contains('quotaSourceDisabled')));
      await testDb.connectionRepository.save(toggled);

      final provider = ControlledProvider(id: 'antigravity')
        ..onFetch = (_, _) async => ProviderSnapshot(
          connectionId: connection.id,
          status: ConnectionStatus.authError,
          quotas: const [],
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: '401',
          failureCause: ProviderFailureCause.invalidCredential,
        );
      const cached = Quota(
        id: 'cached',
        label: 'Cached quota',
        percent: 20,
        remaining: 80,
        limit: 100,
        unit: null,
        resetAt: null,
      );
      await testDb.quotaCacheRepository.saveAll(connection.id, const [cached]);
      final service = RefreshService.forTest(
        provider: provider,
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: MemorySecretStore({'secret-metadata-preserved': 'secret'}),
      );
      final eventState = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: MemorySecretStore({'secret-metadata-preserved': 'secret'}),
        refreshService: service,
      );
      addTearDown(eventState.dispose);
      await eventState.load();
      await eventState.refreshOne(connection.id);
      expect(eventState.requiresReconnect(connection.id), isTrue);
      expect(eventState.accounts.single.snapshot.quotas.single.id, cached.id);
      expect(
        eventState.accounts.single.snapshot.quotas.single.label,
        cached.label,
      );
      await eventState.updateConnection(
        existing: eventState.accounts.single.connection,
        displayName: 'Reconnected',
        newSecret: 'replacement-secret',
      );
      expect(eventState.requiresReconnect(connection.id), isFalse);
    },
  );

  test(
    'editing after credential rotation keeps the current credential ref',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const connection = Connection(
        id: 'conn-rotation-edit',
        provider: 'antigravity',
        displayName: 'Before rotation',
        group: null,
        plan: null,
        credentialRef: 'old-ref',
        enabled: true,
      );
      await testDb.connectionRepository.save(connection);
      final store = MemorySecretStore({'old-ref': 'old-secret'});
      final service = RefreshService.forTest(
        provider: _RotatingProvider(),
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      final state = AppState(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
        refreshService: service,
      );
      addTearDown(state.dispose);

      await state.load();
      await state.refreshOne(connection.id);
      final rotated = state.accounts.single.connection;
      expect(rotated.credentialRef, isNot('old-ref'));

      await state.updateConnection(
        existing: rotated,
        displayName: 'After rotation',
      );

      final persisted = (await testDb.connectionRepository.getAll()).single;
      expect(persisted.credentialRef, rotated.credentialRef);
      expect(await store.read(persisted.credentialRef), 'rotated-secret');
    },
  );

  test(
    'AppState adopts rotated connection on refresh error snapshots',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const connection = Connection(
        id: 'conn-rotation-error',
        provider: 'antigravity',
        displayName: 'Rotating error',
        group: null,
        plan: null,
        credentialRef: 'old-error-ref',
        enabled: true,
      );
      await testDb.connectionRepository.save(connection);
      final store = MemorySecretStore({'old-error-ref': 'old-secret'});
      final service = RefreshService.forTest(
        provider: _RotatingProvider(),
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: _FailingQuotaCacheRepository(),
        secretStore: store,
      );
      final state = AppState(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: _FailingQuotaCacheRepository(),
        secretStore: store,
        refreshService: service,
      );
      addTearDown(state.dispose);

      await state.load();
      await state.refreshOne(connection.id);

      expect(state.accounts.single.snapshot.status, ConnectionStatus.error);
      expect(
        state.accounts.single.connection.credentialRef,
        isNot('old-error-ref'),
      );
    },
  );

  test(
    'cache failure restores the old row before deleting replacement secret',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const connection = Connection(
        id: 'conn-cache-failure',
        provider: 'antigravity',
        displayName: 'Before update',
        group: null,
        plan: null,
        credentialRef: 'old-ref',
        enabled: true,
      );
      await testDb.connectionRepository.save(connection);
      final store = MemorySecretStore({'old-ref': 'old-secret'});
      final state = AppState(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: _FailingQuotaCacheRepository(),
        secretStore: store,
      );
      addTearDown(state.dispose);

      await expectLater(
        state.updateConnection(
          existing: connection,
          displayName: 'After update',
          newSecret: 'replacement-secret',
          newQuotas: const [],
        ),
        throwsA(isA<StateError>()),
      );

      final persisted = (await testDb.connectionRepository.getAll()).single;
      expect(persisted.credentialRef, 'old-ref');
      expect(await store.read('old-ref'), 'old-secret');
      expect(store.entries.length, 1);
    },
  );

  test(
    'remote onboarding persists OAuth metadata and secret only in store',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      final store = MemorySecretStore();
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);
      const remoteSecret =
          '{"accessToken":"remote-access","refreshToken":"remote-refresh"}';
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: remoteSecret,
          identityKey: 'remote@example.com|remote-account',
          projectId: 'remote-project',
          tier: 'pro',
        ),
      );

      final created = await state.addAntigravityConnection(
        displayName: 'Remote Antigravity',
        group: 'Team',
        provider: provider,
      );

      final rows = await testDb.connectionRepository.getAll();
      expect(rows, hasLength(1));
      expect(state.accounts, hasLength(1));
      final row = rows.single;
      expect(row.id, created.id);
      expect(row.provider, 'antigravity');
      expect(row.authType, 'oauth');
      expect(row.identityKey, 'remote@example.com|remote-account');
      expect(jsonDecode(row.providerData!), {
        'source': 'remote',
        'projectId': 'remote-project',
        'tier': 'pro',
      });
      expect(row.providerData, isNot(contains('remote-access')));
      expect(row.providerData, isNot(contains('remote-refresh')));
      expect(store.entries, {row.credentialRef: remoteSecret});
      expect(await testDb.quotaCacheRepository.getAll(row.id), isEmpty);
    },
  );

  test('remote reconnect replaces secret and metadata while preserving row and cache', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    const existing = Connection(
      id: 'antigravity-remote-existing',
      provider: 'antigravity',
      displayName: 'Old name',
      group: 'Old group',
      plan: 'free',
      credentialRef: 'old-antigravity-secret',
      enabled: true,
      authType: 'oauth',
      identityKey: 'old@example.com|old-account',
      providerData:
          '{"source":"remote","projectId":"old-project","tier":"free"}',
    );
    const cached = Quota(
      id: 'cached-remote-quota',
      label: 'Cached remote quota',
      percent: 25,
      remaining: 75,
      limit: 100,
      unit: 'requests',
      resetAt: null,
    );
    await testDb.connectionRepository.save(existing);
    await testDb.quotaCacheRepository.saveAll(existing.id, const [cached]);
    final store = MemorySecretStore({
      existing.credentialRef: '{"accessToken":"old-access"}',
    });
    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
    );
    addTearDown(state.dispose);
    const replacementSecret =
        '{"accessToken":"new-access","refreshToken":"new-refresh"}';
    final provider = _ControlledAntigravityOAuthProvider(
      const AntigravityOAuthLoginResult(
        secret: replacementSecret,
        identityKey: 'new@example.com|new-account',
        projectId: 'new-project',
        tier: 'enterprise',
      ),
    );

    final reconnected = await state.reconnectAntigravityConnection(
      existing,
      'New name',
      'New group',
      provider: provider,
    );

    final rows = await testDb.connectionRepository.getAll();
    expect(rows, hasLength(1));
    final row = rows.single;
    expect(row.id, existing.id);
    expect(row.displayName, 'New name');
    expect(row.group, 'New group');
    expect(row.credentialRef, isNot(existing.credentialRef));
    expect(row.identityKey, 'new@example.com|new-account');
    expect(row.plan, 'enterprise');
    expect(jsonDecode(row.providerData!), {
      'source': 'remote',
      'projectId': 'new-project',
      'tier': 'enterprise',
    });
    expect(store.entries, {row.credentialRef: replacementSecret});
    expect(await store.read(existing.credentialRef), isNull);
    final preservedQuota = (await testDb.quotaCacheRepository.getAll(
      existing.id,
    )).single;
    expect(preservedQuota.id, cached.id);
    expect(preservedQuota.label, cached.label);
    expect(preservedQuota.percent, cached.percent);
    expect(preservedQuota.remaining, cached.remaining);
    expect(preservedQuota.limit, cached.limit);
    expect(preservedQuota.unit, cached.unit);
    expect(preservedQuota.resetAt, cached.resetAt);
    expect(reconnected.credentialRef, row.credentialRef);
    expect(state.requiresReconnect(existing.id), isFalse);
  });
  test('onboarding cancellation during secret write rolls back', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    final started = Completer<void>();
    final gate = Completer<void>();
    final store = _GatedSecretStore(MemorySecretStore(), started, gate);
    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
    );
    addTearDown(state.dispose);
    final provider = _ControlledAntigravityOAuthProvider(
      const AntigravityOAuthLoginResult(
        secret: 'cancelled-secret',
        identityKey: 'cancelled@example.com|cancelled-account',
        projectId: 'cancelled-project',
        tier: 'free',
      ),
    );
    final cancellation = Completer<void>();
    final operation = state.addAntigravityConnection(
      displayName: 'Cancelled onboarding',
      provider: provider,
      cancellation: cancellation.future,
    );
    await started.future;
    cancellation.complete();
    gate.complete();
    await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
    expect(await testDb.connectionRepository.getAll(), isEmpty);
    expect(store.delegate, isA<MemorySecretStore>());
    expect((store.delegate as MemorySecretStore).entries, isEmpty);
  });
  test(
    'reconnect cancellation during secret write preserves old row and cache',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const existing = Connection(
        id: 'reconnect-cancel',
        provider: 'antigravity',
        displayName: 'Old',
        group: null,
        plan: 'free',
        credentialRef: 'old-cancel-secret',
        enabled: true,
        authType: 'oauth',
        identityKey: 'old@example.com|old-account',
        providerData:
            '{"source":"remote","projectId":"old-project","tier":"free"}',
      );
      const cached = Quota(
        id: 'cached-cancel',
        label: 'Cached',
        percent: 10,
        remaining: 90,
        limit: 100,
        unit: null,
        resetAt: null,
      );
      await testDb.connectionRepository.save(existing);
      await testDb.quotaCacheRepository.saveAll(existing.id, const [cached]);
      final started = Completer<void>();
      final gate = Completer<void>();
      final store = _GatedSecretStore(
        MemorySecretStore({existing.credentialRef: 'old-secret'}),
        started,
        gate,
      );
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: 'new-cancel-secret',
          identityKey: 'new@example.com|new-account',
          projectId: 'new-project',
          tier: 'free',
        ),
      );
      final cancellation = Completer<void>();
      final operation = state.reconnectAntigravityConnection(
        existing,
        'New',
        null,
        provider: provider,
        cancellation: cancellation.future,
      );
      await started.future;
      cancellation.complete();
      gate.complete();
      await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
      final rows = await testDb.connectionRepository.getAll();
      expect(rows.single.credentialRef, existing.credentialRef);
      expect(await store.read(existing.credentialRef), 'old-secret');
      expect(
        (await testDb.quotaCacheRepository.getAll(existing.id)).single.id,
        cached.id,
      );
    },
  );
  test(
    'late cancellation after old credential deletion keeps a valid persisted credential',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const existing = Connection(
        id: 'late-delete-cancel',
        provider: 'antigravity',
        displayName: 'Old',
        group: null,
        plan: 'free',
        credentialRef: 'old-late-delete-secret',
        enabled: true,
        authType: 'oauth',
        identityKey: 'old@example.com|old-account',
        providerData:
            '{"source":"remote","projectId":"old-project","tier":"free"}',
      );
      await testDb.connectionRepository.save(existing);
      final deleteStarted = Completer<void>();
      final deleteGate = Completer<void>();
      final deleteCompleted = Completer<void>();
      final postDeleteGate = Completer<void>();
      final store = _GatedDeleteSecretStore(
        MemorySecretStore({existing.credentialRef: 'old-secret'}),
        deleteStarted,
        deleteGate,
        deleteCompleted,
        postDeleteGate,
      );
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: 'replacement-late-delete-secret',
          identityKey: 'new@example.com|new-account',
          projectId: 'new-project',
          tier: 'free',
        ),
      );
      final cancellation = Completer<void>();
      final operation = state.reconnectAntigravityConnection(
        existing,
        'New',
        null,
        provider: provider,
        cancellation: cancellation.future,
      );

      await deleteStarted.future;
      deleteGate.complete();
      await deleteCompleted.future;
      cancellation.complete();
      postDeleteGate.complete();

      await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
      final row = (await testDb.connectionRepository.getAll()).single;
      expect(row.credentialRef, isNot(existing.credentialRef));
      expect(await store.read(row.credentialRef), 'replacement-late-delete-secret');
      expect(state.requiresReconnect(existing.id), isFalse);
    },
  );
  test(
    'reconnect retains replacement secret when old-row restore fails',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const existing = Connection(
        id: 'restore-failure-reconnect',
        provider: 'antigravity',
        displayName: 'Old',
        group: null,
        plan: 'free',
        credentialRef: 'old-restore-secret',
        enabled: true,
        authType: 'oauth',
        identityKey: 'old@example.com|old-account',
        providerData:
            '{"source":"remote","projectId":"old-project","tier":"free"}',
      );
      await testDb.connectionRepository.save(existing);
      final store = MemorySecretStore({existing.credentialRef: 'old-secret'});
      final repo = _RestoreFailingRepository(testDb.connectionRepository);
      final state = AppState.test(
        connectionRepository: repo,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: 'new-restore-secret',
          identityKey: 'new@example.com|new-account',
          projectId: 'new-project',
          tier: 'free',
        ),
      );
      await expectLater(
        state.reconnectAntigravityConnection(
          existing,
          'New',
          null,
          provider: provider,
        ),
        throwsA(isA<StateError>()),
      );
      final row = (await testDb.connectionRepository.getAll()).single;
      expect(row.credentialRef, isNot(existing.credentialRef));
      expect(await store.read(row.credentialRef), 'new-restore-secret');
    },
  );
  test('reconnect restores old row when post-commit load fails', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    const existing = Connection(
      id: 'load-failure-reconnect',
      provider: 'antigravity',
      displayName: 'Old',
      group: null,
      plan: 'free',
      credentialRef: 'old-load-secret',
      enabled: true,
      authType: 'oauth',
      identityKey: 'old@example.com|old-account',
      providerData:
          '{"source":"remote","projectId":"old-project","tier":"free"}',
    );
    await testDb.connectionRepository.save(existing);
    final store = MemorySecretStore({existing.credentialRef: 'old-secret'});
    final repo = _LoadFailingRepository(testDb.connectionRepository);
    final state = AppState.test(
      connectionRepository: repo,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
    );
    addTearDown(state.dispose);
    final provider = _ControlledAntigravityOAuthProvider(
      const AntigravityOAuthLoginResult(
        secret: 'new-load-secret',
        identityKey: 'new@example.com|new-account',
        projectId: 'new-project',
        tier: 'free',
      ),
    );
    await expectLater(
      state.reconnectAntigravityConnection(
        existing,
        'New',
        null,
        provider: provider,
      ),
      throwsA(isA<StateError>()),
    );
    final row = (await testDb.connectionRepository.getAll()).single;
    expect(row.credentialRef, existing.credentialRef);
    expect(await store.read(existing.credentialRef), 'old-secret');
  });

  test(
    'old credential deletion failure leaves valid current row and warning',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const existing = Connection(
        id: 'delete-failure-reconnect',
        provider: 'antigravity',
        displayName: 'Old',
        group: null,
        plan: 'free',
        credentialRef: 'old-load-secret',
        enabled: true,
        authType: 'oauth',
        identityKey: 'old@example.com|old-account',
        providerData:
            '{"source":"remote","projectId":"old-project","tier":"free"}',
      );
      await testDb.connectionRepository.save(existing);
      final store = _DeleteFailingSecretStore(
        MemorySecretStore({existing.credentialRef: 'old-secret'}),
        existing.credentialRef,
      );
      final refresh = RefreshService.forTest(
        provider: ControlledProvider(id: 'antigravity'),
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
        refreshService: refresh,
      );
      addTearDown(state.dispose);
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: 'new-delete-secret',
          identityKey: 'new@example.com|new-account',
          projectId: 'new-project',
          tier: 'free',
        ),
      );
      await state.reconnectAntigravityConnection(
        existing,
        'New',
        null,
        provider: provider,
      );
      final row = (await testDb.connectionRepository.getAll()).single;
      expect(await store.read(row.credentialRef), 'new-delete-secret');
      expect(refresh.credentialCleanupWarnings, isNotEmpty);
    },
  );

  test(
    'same-id reconnects serialize and final row has one current secret',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      const existing = Connection(
        id: 'same-id-reconnect',
        provider: 'antigravity',
        displayName: 'Old',
        group: null,
        plan: 'free',
        credentialRef: 'old-same-id',
        enabled: true,
        authType: 'oauth',
        identityKey: 'old@example.com|old-account',
        providerData:
            '{"source":"remote","projectId":"old-project","tier":"free"}',
      );
      await testDb.connectionRepository.save(existing);
      final store = MemorySecretStore({existing.credentialRef: 'old-secret'});
      final state = AppState.test(
        connectionRepository: testDb.connectionRepository,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);
      final firstGate = Completer<AntigravityOAuthLoginResult>();
      final provider = _SequencedOAuthProvider(
        [firstGate],
        [
          const AntigravityOAuthLoginResult(
            secret: 'first-secret',
            identityKey: 'first@example.com|first',
            projectId: 'first-project',
            tier: 'free',
          ),
          const AntigravityOAuthLoginResult(
            secret: 'second-secret',
            identityKey: 'second@example.com|second',
            projectId: 'second-project',
            tier: 'free',
          ),
        ],
      );
      final first = state.reconnectAntigravityConnection(
        existing,
        'First',
        null,
        provider: provider,
      );
      await provider.firstCallStarted.future;
      final second = state.reconnectAntigravityConnection(
        existing,
        'Second',
        null,
        provider: provider,
      );
      firstGate.complete(provider.results.first);
      await first;
      await second;
      final row = (await testDb.connectionRepository.getAll()).single;
      expect(row.displayName, 'Second');
      expect(await store.read(row.credentialRef), 'second-secret');
      expect(store.entries.length, 1);
    },
  );

  test(
    'add cancellation during load rolls back committed row and secret',
    () async {
      final testDb = await TestDatabase.create();
      addTearDown(testDb.close);
      final started = Completer<void>();
      final gate = Completer<void>();
      final repo = _LoadGateRepository(
        testDb.connectionRepository,
        started,
        gate,
      );
      final store = MemorySecretStore();
      final state = AppState.test(
        connectionRepository: repo,
        quotaCacheRepository: testDb.quotaCacheRepository,
        secretStore: store,
      );
      addTearDown(state.dispose);
      final provider = _ControlledAntigravityOAuthProvider(
        const AntigravityOAuthLoginResult(
          secret: 'load-cancel',
          identityKey: 'a@b|c',
          projectId: 'p',
          tier: 'free',
        ),
      );
      final cancellation = Completer<void>();
      final operation = state.addAntigravityConnection(
        displayName: 'Load cancelled',
        provider: provider,
        cancellation: cancellation.future,
      );
      await started.future;
      cancellation.complete();
      gate.complete();
      await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
      expect(await testDb.connectionRepository.getAll(), isEmpty);
      expect(store.entries, isEmpty);
    },
  );

  test('removeConnection retries failed secret deletion and warns', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    const existing = Connection(
      id: 'remove-cleanup',
      provider: 'antigravity',
      displayName: 'Remove',
      group: null,
      plan: null,
      credentialRef: 'remove-secret',
      enabled: true,
    );
    await testDb.connectionRepository.save(existing);
    final attempted = Completer<void>();
    final store = _RetryDeleteStore(
      MemorySecretStore({'remove-secret': 'secret'}),
      attempted,
    );
    final refresh = RefreshService.forTest(
      provider: ControlledProvider(id: 'antigravity'),
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
      secretCleanupInterval: Duration.zero,
    );
    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
      refreshService: refresh,
    );
    addTearDown(state.dispose);
    final warning = await state.removeConnection(existing.id);
    expect(warning, contains('credential'));
    expect(refresh.credentialCleanupWarnings, isNotEmpty);
    await attempted.future;
    expect(store.attempts, greaterThanOrEqualTo(2));
    expect(await testDb.connectionRepository.getAll(), isEmpty);
  });
  test('queued reconnect cancellation never enters OAuth provider', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    const existing = Connection(
      id: 'queued-cancel',
      provider: 'antigravity',
      displayName: 'Old',
      group: null,
      plan: 'free',
      credentialRef: 'old-queued',
      enabled: true,
      authType: 'oauth',
      identityKey: 'old@example.com|old',
      providerData: '{"source":"remote","projectId":"old","tier":"free"}',
    );
    await testDb.connectionRepository.save(existing);
    final store = MemorySecretStore({existing.credentialRef: 'old-secret'});
    final refresh = RefreshService.forTest(
      provider: ControlledProvider(id: 'antigravity'),
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
    );
    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
      refreshService: refresh,
    );
    addTearDown(state.dispose);
    final release = Completer<void>();
    final blocked = refresh.runConnectionOperation<void>(
      connectionId: existing.id,
      operation: () => release.future,
    );
    final provider = _SequencedOAuthProvider([], [
      const AntigravityOAuthLoginResult(
        secret: 'must-not-write',
        identityKey: 'new',
        projectId: 'new',
        tier: 'free',
      ),
    ]);
    final cancellation = Completer<void>();
    final reconnect = state.reconnectAntigravityConnection(
      existing,
      'New',
      null,
      provider: provider,
      cancellation: cancellation.future,
    );
    expect(provider.calls, 0);
    cancellation.complete();
    release.complete();
    await blocked;
    await expectLater(reconnect, throwsA(isA<AntigravityLoginCancelled>()));
    expect(provider.calls, 0);
    expect(
      (await testDb.connectionRepository.getAll()).single.credentialRef,
      existing.credentialRef,
    );
    expect(store.entries, {existing.credentialRef: 'old-secret'});
  });

  test('provider-owned provisional secret is removed on cancellation', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    final store = MemorySecretStore();
    final gate = Completer<void>();
    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      quotaCacheRepository: testDb.quotaCacheRepository,
      secretStore: store,
    );
    addTearDown(state.dispose);
    final provider = _ProvisionalWritingProvider(store, gate);
    final cancellation = Completer<void>();
    final operation = state.addAntigravityConnection(
      displayName: 'Provisional', provider: provider, cancellation: cancellation.future,
    );
    while (store.entries.isEmpty) await Future<void>.value();
    cancellation.complete();
    gate.complete();
    await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
    expect(store.entries, isEmpty);
    expect(await testDb.connectionRepository.getAll(), isEmpty);
  });

  test('newer refresh interval write waits for and supersedes older write', () async {
    final settings = _QueuedSettingsRepository();
    final state = AppState.test(settingsRepository: settings);
    addTearDown(state.dispose);

    final first = state.setRefreshIntervalMinutes(10);
    await Future<void>.delayed(Duration.zero);
    expect(settings.startedWrites, [10]);

    final second = state.setRefreshIntervalMinutes(1);
    await Future<void>.delayed(Duration.zero);
    expect(settings.startedWrites, [10]);

    settings.completeWrite(0);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(settings.startedWrites, [10, 1]);

    settings.completeWrite(1);
    await second;
    expect(state.refreshIntervalMinutes, 1);
    expect(settings.values['refresh_interval_minutes'], '1');
  });
}
