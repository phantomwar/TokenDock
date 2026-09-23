import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/quota.dart';

import '../support/memory_secret_store.dart';

import '../support/test_database.dart';

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
}
