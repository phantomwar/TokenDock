import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
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

import '../support/memory_secret_store.dart';
import '../support/test_database.dart';

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
  Map<String, String> buildAuthHeader(String secret) =>
      {'Authorization': 'Bearer $secret'};

  @override
  RefreshableCredential? refreshableCredential(String secret) => _RotatingCredential();

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
  DateTime? get expiresAt => DateTime.now().toUtc().subtract(const Duration(minutes: 2));

  @override
  Duration get refreshLead => const Duration(minutes: 1);

  @override
  Future<String> refresh(String currentSecret) async => 'rotated-secret';
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
  test('edit and toggle preserve connection metadata', () async {
    final testDb = await TestDatabase.create();
    addTearDown(testDb.close);
    const connection = Connection(
      id: 'conn-metadata-preserved',
      provider: 'openrouter',
      displayName: 'Original',
      group: null,
      plan: null,
      authType: 'oauth',
      identityKey: 'account-id',
      providerData: '{"workspace":"production"}',
      credentialRef: 'secret-metadata-preserved',
      enabled: true,
    );
    await testDb.connectionRepository.save(connection);

    final state = AppState.test(
      connectionRepository: testDb.connectionRepository,
      secretStore: MemorySecretStore(),
    );
    addTearDown(state.dispose);

    await state.updateConnection(
      existing: connection,
      displayName: 'Edited',
    );
    final edited = (await testDb.connectionRepository.getAll()).single;
    expect(edited.displayName, 'Edited');
    expect(edited.authType, 'oauth');
    expect(edited.identityKey, 'account-id');
    expect(edited.providerData, '{"workspace":"production"}');

    await state.toggleConnectionEnabled(connection.id, false);
    final toggled = (await testDb.connectionRepository.getAll()).single;
    expect(toggled.enabled, isFalse);
    expect(toggled.authType, 'oauth');
    expect(toggled.identityKey, 'account-id');
    expect(toggled.providerData, '{"workspace":"production"}');
  });

  test('editing after credential rotation keeps the current credential ref', () async {
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
  });

  test('AppState adopts rotated connection on refresh error snapshots', () async {
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
    expect(state.accounts.single.connection.credentialRef, isNot('old-error-ref'));
  });

  test('cache failure restores the old row before deleting replacement secret', () async {
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
  });

}
