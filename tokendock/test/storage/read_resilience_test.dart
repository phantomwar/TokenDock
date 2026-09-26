import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/storage/migration_001.dart';
import 'package:tokendock/storage/migration_002.dart';
import 'package:tokendock/storage/migration_003.dart';

import '../support/test_database.dart';

/// Resilience of the read path against rows the current schema version never
/// writes, plus the durability guarantees SQLite cannot give us for free.
///
/// See `docs/audit-2026-09-25-second-pass.md` findings C-02, C-03, C-13.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  group('QuotaCacheRepository read resilience (C-03)', () {
    test('a malformed reset_at does not throw and degrades to null', () async {
      final harness = await TestDatabase.create();
      addTearDown(harness.close);

      await harness.database.insert('connections', {
        'id': 'c1',
        'provider': 'openrouter',
        'display_name': 'Broken reset',
        'secret_ref': 'ref',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      // Written directly: saveAll would never persist a malformed timestamp.
      await harness.database.insert('quota_cache', {
        'connection_id': 'c1',
        'quota_key': 'key-limit',
        'label': 'Key limit',
        'percent': 42.0,
        'remaining': 42.0,
        'limit_value': 100.0,
        'unit': 'USD',
        'reset_at': 'not-a-timestamp',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });

      final quotas = await harness.quotaCacheRepository.getAll('c1');

      expect(quotas, hasLength(1));
      expect(quotas.single.resetAt, isNull);
      // The rest of the row must still be usable.
      expect(quotas.single.percent, 42.0);
      expect(quotas.single.label, 'Key limit');
    });

    test('a malformed reset_at does not break the other connections', () async {
      final harness = await TestDatabase.create();
      addTearDown(harness.close);

      for (final id in ['broken', 'healthy']) {
        await harness.database.insert('connections', {
          'id': id,
          'provider': 'openrouter',
          'display_name': id,
          'secret_ref': 'ref-$id',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-01T00:00:00.000Z',
        });
      }
      await harness.database.insert('quota_cache', {
        'connection_id': 'broken',
        'quota_key': 'q',
        'label': 'q',
        'reset_at': 'garbage',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });
      await harness.database.insert('quota_cache', {
        'connection_id': 'healthy',
        'quota_key': 'q',
        'label': 'q',
        'reset_at': '2026-06-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });

      final healthy = await harness.quotaCacheRepository.getAll('healthy');

      expect(healthy.single.resetAt, isNotNull);
    });
  });

  group('ConnectionHealthRepository read resilience (C-03)', () {
    test(
      'a malformed last_checked_at degrades to null instead of throwing',
      () async {
        final harness = await TestDatabase.create();
        addTearDown(harness.close);

        await harness.database.insert('connections', {
          'id': 'c1',
          'provider': 'openrouter',
          'display_name': 'Broken health',
          'secret_ref': 'ref',
          'created_at': '2026-01-01T00:00:00.000Z',
          'updated_at': '2026-01-01T00:00:00.000Z',
          'last_status': 'ok',
          'last_checked_at': 'corrupted',
          'last_error': null,
        });

        final health = await harness.connectionHealthRepository.get('c1');

        expect(health, isNull);
      },
    );

    test('a malformed cooldown_until degrades the field only', () async {
      final harness = await TestDatabase.create();
      addTearDown(harness.close);

      await harness.database.insert('connections', {
        'id': 'c1',
        'provider': 'openrouter',
        'display_name': 'Bad cooldown',
        'secret_ref': 'ref',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
        'last_status': 'warning',
        'last_checked_at': '2026-01-01T00:00:00.000Z',
        'cooldown_until': 'nonsense',
        'last_error': 'Rate limited',
      });

      final health = await harness.connectionHealthRepository.get('c1');

      expect(health, isNotNull);
      expect(health!.status, ConnectionStatus.warning);
      expect(health.cooldownUntil, isNull);
      expect(health.error, 'Rate limited');
    });
  });

  group('ConnectionRepository provider_data sanitisation (C-13)', () {
    test('token-like keys are stripped before reaching SQLite', () async {
      final harness = await TestDatabase.create();
      addTearDown(harness.close);

      await harness.connectionRepository.save(
        const Connection(
          id: 'c1',
          provider: 'antigravity',
          displayName: 'Leaky',
          group: null,
          plan: null,
          credentialRef: 'ref',
          enabled: true,
          providerData:
              '{"source":"remote","accessToken":"ya29.SECRET",'
              '"refreshToken":"1//REFRESH","csrfToken":"CSRF",'
              '"projectId":"proj-1"}',
        ),
      );

      final stored =
          (await harness.connectionRepository.getAll()).single.providerData!;

      expect(stored, isNot(contains('ya29.SECRET')));
      expect(stored, isNot(contains('1//REFRESH')));
      expect(stored, isNot(contains('CSRF')));
      // Non-secret provider metadata must survive.
      expect(stored, contains('remote'));
      expect(stored, contains('proj-1'));
    });

    test('CSRF keys nested inside lists are stripped too', () async {
      final harness = await TestDatabase.create();
      addTearDown(harness.close);

      await harness.connectionRepository.save(
        const Connection(
          id: 'c1',
          provider: 'antigravity',
          displayName: 'Nested',
          group: null,
          plan: null,
          credentialRef: 'ref',
          enabled: true,
          providerData: '{"sessions":[{"csrfToken":"A"},{"safe":"B"}]}',
        ),
      );

      final stored =
          (await harness.connectionRepository.getAll()).single.providerData!;

      expect(stored, isNot(contains('A')));
      expect(stored, contains('B'));
    });
  });

  group('Migration durability (C-02)', () {
    test(
      'Migration002 recovers when its columns exist but user_version is stale',
      () async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(() => db.close());
        await Migration001.run(db);
        await Migration002.run(db);
        // Simulate the crash window: DDL committed, PRAGMA never written.
        await db.execute('PRAGMA user_version = 1');

        await Migration002.run(db);

        final version = await db.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 2);
      },
    );

    test(
      'Migration003 recovers when its columns exist but user_version is stale',
      () async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(() => db.close());
        await Migration001.run(db);
        await Migration002.run(db);
        await Migration003.run(db);
        await db.execute('PRAGMA user_version = 2');

        await Migration003.run(db);

        final version = await db.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 3);
      },
    );

    test(
      'a partially applied Migration002 finishes the remaining columns',
      () async {
        final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
        addTearDown(() => db.close());
        await Migration001.run(db);
        await Migration002.run(db);
        await db.execute('PRAGMA user_version = 1');
        // Simulate dying midway through the four ALTER TABLE statements.
        await db.execute('ALTER TABLE connections DROP COLUMN last_error');

        await Migration002.run(db);

        final columns = await db.rawQuery('PRAGMA table_info(connections)');
        final names = columns.map((row) => row['name'] as String).toSet();
        expect(names, contains('last_error'));
        expect(names, contains('last_status'));
        final version = await db.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 2);
      },
    );

    test('Migration002 and Migration003 keep existing rows intact', () async {
      final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      addTearDown(() => db.close());
      await Migration001.run(db);
      await db.insert('connections', {
        'id': 'keep-me',
        'provider': 'openrouter',
        'display_name': 'Keep me',
        'secret_ref': 'ref',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });

      await Migration002.run(db);
      await db.execute('PRAGMA user_version = 1');
      await Migration002.run(db);
      await Migration003.run(db);

      final rows = await db.query(
        'connections',
        where: 'id = ?',
        whereArgs: ['keep-me'],
      );
      expect(rows, hasLength(1));
      expect(rows.single['display_name'], 'Keep me');
    });
  });

  group('ConnectionHealth round-trip (C-17 visibility)', () {
    test('health written through the repository reads back exactly', () async {
      final harness = await TestDatabase.create();
      addTearDown(harness.close);

      await harness.connectionRepository.save(
        const Connection(
          id: 'c1',
          provider: 'openrouter',
          displayName: 'Health',
          group: null,
          plan: null,
          credentialRef: 'ref',
          enabled: true,
        ),
      );
      await harness.connectionHealthRepository.save(
        ConnectionHealth(
          connectionId: 'c1',
          status: ConnectionStatus.warning,
          lastCheckedAt: DateTime.utc(2026, 5, 4, 3, 2, 1),
          cooldownUntil: DateTime.utc(2026, 5, 4, 3, 5),
          error: 'Rate limited',
        ),
      );

      final health = await harness.connectionHealthRepository.get('c1');

      expect(health!.status, ConnectionStatus.warning);
      expect(health.lastCheckedAt, DateTime.utc(2026, 5, 4, 3, 2, 1));
      expect(health.cooldownUntil, DateTime.utc(2026, 5, 4, 3, 5));
      expect(health.error, 'Rate limited');
    });
  });
}
