import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/storage/migration_001.dart';
import 'package:tokendock/storage/migration_002.dart';

import '../support/test_database.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('Migration001', () {
    test('creates tables and sets user_version to 1', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(() => db.close());

      final initialVersionResult = await db.rawQuery('PRAGMA user_version');
      expect((initialVersionResult.first.values.first as num).toInt(), 0);

      await Migration001.run(db);

      final versionResult = await db.rawQuery('PRAGMA user_version');
      expect((versionResult.first.values.first as num).toInt(), 1);

      final tablesResult = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('connections', 'quota_cache', 'settings')",
      );
      final tableNames = tablesResult.map((r) => r['name'] as String).toSet();
      expect(
        tableNames,
        containsAll({'connections', 'quota_cache', 'settings'}),
      );

      final indexResult = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name = 'idx_quota_cache_connection'",
      );
      expect(indexResult, isNotEmpty);

      // Verify idempotency: running migration again keeps version at 1
      await Migration001.run(db);
      final rerunVersion = await db.rawQuery('PRAGMA user_version');
      expect((rerunVersion.first.values.first as num).toInt(), 1);
    });
  });
  group('Migration002', () {
    test(
      'adds health fields to a v1 database without losing cached quotas',
      () async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(() => db.close());
        await Migration001.run(db);
        await db.insert('connections', {
          'id': 'existing-connection',
          'provider': 'openrouter',
          'display_name': 'Existing',
          'secret_ref': 'secret-ref',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-01T00:00:00.000Z',
        });
        await db.insert('quota_cache', {
          'connection_id': 'existing-connection',
          'quota_key': 'cached-usage',
          'label': 'Cached usage',
          'remaining': 7.0,
          'updated_at': '2026-01-01T00:00:00.000Z',
        });

        await Migration002.run(db);

        final version = await db.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 2);
        final columns = await db.rawQuery('PRAGMA table_info(connections)');
        final columnNames = columns.map((row) => row['name'] as String).toSet();
        expect(
          columnNames,
          containsAll({
            'last_status',
            'last_checked_at',
            'cooldown_until',
            'last_error',
          }),
        );
        expect(
          await db.query(
            'connections',
            where: 'id = ?',
            whereArgs: ['existing-connection'],
          ),
          hasLength(1),
        );
        final cachedRows = await db.query(
          'quota_cache',
          where: 'connection_id = ?',
          whereArgs: ['existing-connection'],
        );
        expect(cachedRows.single['remaining'], 7.0);

        await Migration002.run(db);
        final rerunVersion = await db.rawQuery('PRAGMA user_version');
        expect((rerunVersion.first.values.first as num).toInt(), 2);
      },
    );
  });

  group('ConnectionRepository', () {
    late TestDatabase testDb;

    setUp(() async {
      testDb = await TestDatabase.create();
    });

    tearDown(() async {
      await testDb.close();
    });

    test(
      'connection CRUD: save, getAll (all fields preserved), and delete',
      () async {
        final repo = testDb.connectionRepository;

        expect(await repo.getAll(), isEmpty);

        const conn1 = Connection(
          id: 'conn-1',
          provider: 'openrouter',
          displayName: 'OpenRouter Primary',
          group: 'Production',
          plan: 'Pay-as-you-go',
          credentialRef: 'sec_openrouter_1',
          enabled: true,
        );
        await repo.save(conn1);

        final all = await repo.getAll();
        expect(all.length, 1);
        final fetched = all.first;
        expect(fetched.id, 'conn-1');
        expect(fetched.provider, 'openrouter');
        expect(fetched.displayName, 'OpenRouter Primary');
        expect(fetched.group, 'Production');
        expect(fetched.plan, 'Pay-as-you-go');
        expect(fetched.credentialRef, 'sec_openrouter_1');
        expect(fetched.enabled, isTrue);

        const conn2 = Connection(
          id: 'conn-2',
          provider: 'openai',
          displayName: 'OpenAI Personal',
          group: null,
          plan: null,
          credentialRef: 'sec_openai_2',
          enabled: false,
        );
        await repo.save(conn2);

        final all2 = await repo.getAll();
        expect(all2.length, 2);
        final fetchedConn2 = all2.firstWhere((c) => c.id == 'conn-2');
        expect(fetchedConn2.group, isNull);
        expect(fetchedConn2.plan, isNull);
        expect(fetchedConn2.enabled, isFalse);

        // Update conn1 displayName and enabled status
        const updatedConn1 = Connection(
          id: 'conn-1',
          provider: 'openrouter',
          displayName: 'OpenRouter Work',
          group: 'Production',
          plan: 'Pay-as-you-go',
          credentialRef: 'sec_openrouter_1',
          enabled: false,
        );
        await repo.save(updatedConn1);

        final afterUpdate = await repo.getAll();
        final fetchedUpdated = afterUpdate.firstWhere((c) => c.id == 'conn-1');
        expect(fetchedUpdated.displayName, 'OpenRouter Work');
        expect(fetchedUpdated.enabled, isFalse);

        // Delete conn-1
        await repo.delete('conn-1');
        final remaining = await repo.getAll();
        expect(remaining.length, 1);
        expect(remaining.first.id, 'conn-2');
      },
    );

    test('round-trips authentication and provider metadata', () async {
      const connection = Connection(
        id: 'conn-metadata',
        provider: 'openrouter',
        displayName: 'Metadata',
        group: null,
        plan: null,
        authType: 'api_key',
        identityKey: 'user@example.com',
        providerData: '{"workspace":"production"}',
        credentialRef: 'secret-metadata',
        enabled: true,
      );

      await testDb.connectionRepository.save(connection);

      final fetched = (await testDb.connectionRepository.getAll()).single;
      expect(fetched.authType, 'api_key');
      expect(fetched.identityKey, 'user@example.com');
      expect(fetched.providerData, '{"workspace":"production"}');

      const updatedConnection = Connection(
        id: 'conn-metadata',
        provider: 'openrouter',
        displayName: 'Metadata updated',
        group: null,
        plan: null,
        authType: 'oauth',
        identityKey: 'account-id',
        providerData: '{"workspace":"staging"}',
        credentialRef: 'secret-metadata',
        enabled: true,
      );
      await testDb.connectionRepository.save(updatedConnection);

      final updated = (await testDb.connectionRepository.getAll()).single;
      expect(updated.authType, 'oauth');
      expect(updated.identityKey, 'account-id');
      expect(updated.providerData, '{"workspace":"staging"}');
    });

    test('saving a connection update preserves health and cooldown', () async {
      const original = Connection(
        id: 'conn-health-update',
        provider: 'openrouter',
        displayName: 'Before edit',
        group: null,
        plan: null,
        credentialRef: 'secret-health-update',
        enabled: true,
      );
      await testDb.connectionRepository.save(original);
      final checkedAt = DateTime.utc(2026, 9, 23, 12);
      final cooldownUntil = DateTime.utc(2026, 9, 23, 12, 5);
      await testDb.connectionHealthRepository.save(
        ConnectionHealth(
          connectionId: original.id,
          status: ConnectionStatus.warning,
          lastCheckedAt: checkedAt,
          cooldownUntil: cooldownUntil,
          error: 'Rate limited',
        ),
      );
      const edited = Connection(
        id: 'conn-health-update',
        provider: 'openrouter',
        displayName: 'After edit',
        group: null,
        plan: null,
        credentialRef: 'secret-health-update',
        enabled: false,
      );

      await testDb.connectionRepository.save(edited);

      final health = await testDb.connectionHealthRepository.get(edited.id);
      expect(health?.status, ConnectionStatus.warning);
      expect(health?.lastCheckedAt, checkedAt);
      expect(health?.cooldownUntil, cooldownUntil);
      expect(health?.error, 'Rate limited');
    });

    test(
      'delete(id) cascades and removes associated quota_cache rows',
      () async {
        const connA = Connection(
          id: 'conn-a',
          provider: 'openrouter',
          displayName: 'Conn A',
          group: null,
          plan: null,
          credentialRef: 'sec_a',
          enabled: true,
        );
        const connB = Connection(
          id: 'conn-b',
          provider: 'openrouter',
          displayName: 'Conn B',
          group: null,
          plan: null,
          credentialRef: 'sec_b',
          enabled: true,
        );
        await testDb.connectionRepository.save(connA);
        await testDb.connectionRepository.save(connB);

        final quotasA = [
          const Quota(
            id: 'quota-a1',
            label: 'Label A1',
            percent: 50.0,
            remaining: 5.0,
            limit: 10.0,
            unit: 'USD',
            resetAt: null,
          ),
        ];
        final quotasB = [
          const Quota(
            id: 'quota-b1',
            label: 'Label B1',
            percent: 80.0,
            remaining: 2.0,
            limit: 10.0,
            unit: 'USD',
            resetAt: null,
          ),
        ];
        await testDb.quotaCacheRepository.saveAll('conn-a', quotasA);
        await testDb.quotaCacheRepository.saveAll('conn-b', quotasB);

        expect(
          await testDb.quotaCacheRepository.getAll('conn-a'),
          hasLength(1),
        );
        expect(
          await testDb.quotaCacheRepository.getAll('conn-b'),
          hasLength(1),
        );

        // Delete conn-a via connectionRepository.delete
        await testDb.connectionRepository.delete('conn-a');

        // Verify connection is gone
        final connections = await testDb.connectionRepository.getAll();
        expect(connections.any((c) => c.id == 'conn-a'), isFalse);
        expect(connections.any((c) => c.id == 'conn-b'), isTrue);

        // Verify quota cache for conn-a was cascade-deleted
        expect(await testDb.quotaCacheRepository.getAll('conn-a'), isEmpty);

        // Verify quota cache for conn-b is untouched
        final remainingQuotasB = await testDb.quotaCacheRepository.getAll(
          'conn-b',
        );
        expect(remainingQuotasB, hasLength(1));
        expect(remainingQuotasB.first.id, 'quota-b1');
      },
    );
  });

  group('QuotaCacheRepository', () {
    late TestDatabase testDb;

    setUp(() async {
      testDb = await TestDatabase.create();
    });

    tearDown(() async {
      await testDb.close();
    });

    test('saveAll replaces previous cache atomically without altering other connections', () async {
      final initialQuotasA = [
        const Quota(
          id: 'qa1',
          label: 'Q A1',
          percent: 10.0,
          remaining: 90.0,
          limit: 100.0,
          unit: 'credits',
          resetAt: null,
        ),
        const Quota(
          id: 'qa2',
          label: 'Q A2',
          percent: 20.0,
          remaining: 80.0,
          limit: 100.0,
          unit: 'credits',
          resetAt: null,
        ),
      ];
      final quotasB = [
        const Quota(
          id: 'qb1',
          label: 'Q B1',
          percent: 30.0,
          remaining: 70.0,
          limit: 100.0,
          unit: 'credits',
          resetAt: null,
        ),
      ];

      await testDb.quotaCacheRepository.saveAll('conn-a', initialQuotasA);
      await testDb.quotaCacheRepository.saveAll('conn-b', quotasB);

      // Replace conn-a quotas with a single new quota
      final updatedQuotasA = [
        const Quota(
          id: 'qa3',
          label: 'Q A3',
          percent: 50.0,
          remaining: 50.0,
          limit: 100.0,
          unit: 'credits',
          resetAt: null,
        ),
      ];
      await testDb.quotaCacheRepository.saveAll('conn-a', updatedQuotasA);

      final fetchedA = await testDb.quotaCacheRepository.getAll('conn-a');
      expect(fetchedA.length, 1);
      expect(fetchedA.first.id, 'qa3');
      expect(fetchedA.first.label, 'Q A3');

      // conn-b is unaltered
      final fetchedB = await testDb.quotaCacheRepository.getAll('conn-b');
      expect(fetchedB.length, 1);
      expect(fetchedB.first.id, 'qb1');

      // deleteForConnection removes only specified connection cache
      await testDb.quotaCacheRepository.deleteForConnection('conn-b');
      expect(await testDb.quotaCacheRepository.getAll('conn-b'), isEmpty);
      expect(await testDb.quotaCacheRepository.getAll('conn-a'), hasLength(1));
    });

    test('UTC timestamp serialization: round-trip of resetAt preserves UTC datetime accurately', () async {
      final utcDateTime = DateTime.utc(2026, 12, 31, 23, 59, 59, 123);
      final quotaWithDate = Quota(
        id: 'date-quota',
        label: 'Date Quota',
        percent: 75.5,
        remaining: 24.5,
        limit: 100.0,
        unit: 'USD',
        resetAt: utcDateTime,
      );

      await testDb.quotaCacheRepository.saveAll('conn-utc', [quotaWithDate]);

      final retrieved = await testDb.quotaCacheRepository.getAll('conn-utc');
      expect(retrieved.length, 1);
      final retrievedQuota = retrieved.first;
      expect(retrievedQuota.resetAt, isNotNull);
      expect(retrievedQuota.resetAt!.isUtc, isTrue);
      expect(retrievedQuota.resetAt, utcDateTime);

      // Test null resetAt preserves null
      const quotaWithNullDate = Quota(
        id: 'null-date-quota',
        label: 'Null Date Quota',
        percent: null,
        remaining: null,
        limit: null,
        unit: null,
        resetAt: null,
      );
      await testDb.quotaCacheRepository.saveAll('conn-null-date', [
        quotaWithNullDate,
      ]);
      final retrievedNull = await testDb.quotaCacheRepository.getAll(
        'conn-null-date',
      );
      expect(retrievedNull.first.resetAt, isNull);
    });
  });

  group('ConnectionHealthRepository', () {
    late TestDatabase testDb;

    setUp(() async {
      testDb = await TestDatabase.create();
    });

    tearDown(() async {
      await testDb.close();
    });

    test('round-trips per-connection health and UTC cooldown', () async {
      const connection = Connection(
        id: 'conn-health',
        provider: 'openrouter',
        displayName: 'Health',
        group: null,
        plan: null,
        credentialRef: 'secret-health',
        enabled: true,
      );
      await testDb.connectionRepository.save(connection);
      final checkedAt = DateTime.utc(2026, 9, 23, 12);
      final cooldownUntil = DateTime.utc(2026, 9, 23, 12, 1);
      final health = ConnectionHealth(
        connectionId: connection.id,
        status: ConnectionStatus.warning,
        lastCheckedAt: checkedAt,
        cooldownUntil: cooldownUntil,
        error: 'Rate limited',
      );

      await testDb.connectionHealthRepository.save(health);

      final restored = await testDb.connectionHealthRepository.get(
        connection.id,
      );
      expect(restored?.status, ConnectionStatus.warning);
      expect(restored?.lastCheckedAt, checkedAt);
      expect(restored?.cooldownUntil, cooldownUntil);
      expect(restored?.cooldownUntil?.isUtc, isTrue);
      expect(restored?.error, 'Rate limited');
      expect(await testDb.connectionHealthRepository.get('missing'), isNull);
    });
  });

  group('SettingsRepository', () {
    late TestDatabase testDb;

    setUp(() async {
      testDb = await TestDatabase.create();
    });

    tearDown(() async {
      await testDb.close();
    });

    test('get, set, and default refresh interval', () async {
      final settings = testDb.settingsRepository;

      // Missing key returns null
      expect(await settings.get('non_existent_key'), isNull);

      // Set and get arbitrary key-value
      await settings.set('custom_key', 'custom_value');
      expect(await settings.get('custom_key'), 'custom_value');

      // Overwrite setting
      await settings.set('custom_key', 'updated_value');
      expect(await settings.get('custom_key'), 'updated_value');

      // Default refresh interval is 3 minutes
      expect(await settings.getRefreshIntervalMinutes(), 3);

      // Set and retrieve updated refresh interval
      await settings.setRefreshIntervalMinutes(10);
      expect(await settings.getRefreshIntervalMinutes(), 10);
      expect(await settings.get('refresh_interval_minutes'), '10');
    });
  });
}
