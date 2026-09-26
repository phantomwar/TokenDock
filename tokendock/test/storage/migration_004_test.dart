import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/storage/database.dart';
import 'package:tokendock/storage/migration_001.dart';
import 'package:tokendock/storage/migration_002.dart';
import 'package:tokendock/storage/migration_003.dart';

/// C-23: schema integrity.
///
/// The project owns `user_version` by hand, so these tests drive a real
/// on-disk database up to v3, then let `AppDatabase.open` perform the upgrade.
/// An in-memory handle cannot be reopened, and the interesting cases (a
/// half-applied migration, a row whose parent no longer exists) only exist
/// across a restart.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
  });

  late Directory tempDir;
  late String dbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('tokendock-m004');
    dbPath = '${tempDir.path}${Platform.pathSeparator}tokendock.db';
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// Brings a database to the v3 schema without running Migration004, which is
  /// what a machine that launched before this change would have on disk.
  Future<void> seedAtV3() async {
    final db = await databaseFactoryFfi.openDatabase(dbPath);
    addTearDown(() => db.close());
    await Migration001.run(db);
    await Migration002.run(db);
    await Migration003.run(db);
  }

  Future<void> insertConnection(Database db, String id) =>
      db.insert('connections', {
        'id': id,
        'provider': 'openrouter',
        'display_name': id,
        'secret_ref': 'ref-$id',
        'created_at': '2026-01-01T00:00:00.000Z',
        'updated_at': '2026-01-01T00:00:00.000Z',
      });

  Future<void> insertQuota(Database db, String connectionId, String key) =>
      db.insert('quota_cache', {
        'connection_id': connectionId,
        'quota_key': key,
        'label': 'Label $key',
        'percent': 42.0,
        'remaining': 3.0,
        'limit_value': 10.0,
        'unit': 'USD',
        'reset_at': '2026-02-01T00:00:00.000Z',
        'status': null,
        'updated_at': '2026-01-01T00:00:00.000Z',
      });

  group('Migration004 · schema integrity (C-23)', () {
    test(
      'AppDatabase.open upgrades a v3 database and stamps version 4',
      () async {
        await seedAtV3();

        final app = await AppDatabase.open(path: dbPath);
        addTearDown(app.close);

        final version = await app.database.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 4);
      },
    );

    test('quota_cache declares the cascade to connections', () async {
      await seedAtV3();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      final keys = await app.database.rawQuery(
        'PRAGMA foreign_key_list(quota_cache)',
      );
      expect(keys, hasLength(1));
      expect(keys.single['table'], 'connections');
      expect(keys.single['from'], 'connection_id');
      expect(keys.single['to'], 'id');
      expect(keys.single['on_delete'], 'CASCADE');
    });

    test('foreign key enforcement is on once open returns', () async {
      await seedAtV3();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      final pragma = await app.database.rawQuery('PRAGMA foreign_keys');
      expect((pragma.first.values.first as num).toInt(), 1);
    });

    test(
      'a quota row for a connection that does not exist is rejected',
      () async {
        await seedAtV3();

        final app = await AppDatabase.open(path: dbPath);
        addTearDown(app.close);

        await expectLater(
          insertQuota(app.database, 'ghost', 'q'),
          throwsA(isA<DatabaseException>()),
        );
      },
    );

    test('deleting a connection removes its cached quota rows', () async {
      await seedAtV3();
      final seed = await databaseFactoryFfi.openDatabase(dbPath);
      await insertConnection(seed, 'c1');
      await insertQuota(seed, 'c1', 'q1');
      await seed.close();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      await app.database.delete(
        'connections',
        where: 'id = ?',
        whereArgs: ['c1'],
      );

      expect(
        await app.database.query(
          'quota_cache',
          where: 'connection_id = ?',
          whereArgs: ['c1'],
        ),
        isEmpty,
      );
    });

    test('the rebuild keeps every quota column that is still read', () async {
      await seedAtV3();
      final seed = await databaseFactoryFfi.openDatabase(dbPath);
      await insertConnection(seed, 'c1');
      await insertQuota(seed, 'c1', 'q1');
      await seed.close();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      final columns = await app.database.rawQuery(
        'PRAGMA table_info(quota_cache)',
      );
      final names = columns.map((row) => row['name'] as String).toSet();
      expect(
        names,
        containsAll({
          'connection_id',
          'quota_key',
          'label',
          'percent',
          'remaining',
          'limit_value',
          'unit',
          'reset_at',
          'updated_at',
        }),
      );

      final row = await app.database.query(
        'quota_cache',
        where: 'connection_id = ?',
        whereArgs: ['c1'],
      );
      expect(row, hasLength(1));
      expect(row.single['label'], 'Label q1');
      expect(row.single['percent'], 42.0);
      expect(row.single['remaining'], 3.0);
      expect(row.single['limit_value'], 10.0);
      expect(row.single['unit'], 'USD');
      expect(row.single['reset_at'], '2026-02-01T00:00:00.000Z');
    });

    test('the dead status column is gone', () async {
      await seedAtV3();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      final columns = await app.database.rawQuery(
        'PRAGMA table_info(quota_cache)',
      );
      final names = columns.map((row) => row['name'] as String).toSet();
      expect(names, isNot(contains('status')));
    });

    test('the index duplicated by the composite primary key is gone', () async {
      await seedAtV3();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      final indexes = await app.database.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_quota_cache_connection'",
      );
      expect(indexes, isEmpty);
    });

    test(
      'connections is indexed on the order the widget reads it by',
      () async {
        await seedAtV3();

        final app = await AppDatabase.open(path: dbPath);
        addTearDown(app.close);

        final indexes = await app.database.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='index' AND name='idx_connections_sort_order'",
        );
        expect(indexes, hasLength(1));

        final info = await app.database.rawQuery(
          'PRAGMA index_info(idx_connections_sort_order)',
        );
        final columns = info.map((row) => row['name'] as String).toList();
        expect(columns, ['sort_order', 'created_at']);
      },
    );

    test('an orphaned quota row is dropped rather than carried forward', () async {
      await seedAtV3();
      final seed = await databaseFactoryFfi.openDatabase(dbPath);
      await insertConnection(seed, 'c1');
      await insertQuota(seed, 'c1', 'kept');
      // No such connection. Only reachable through a partial manual cascade or
      // an interrupted write, which is exactly why the rebuild cannot assume
      // the table is clean.
      await insertQuota(seed, 'vanished', 'orphan');
      await seed.close();

      final app = await AppDatabase.open(path: dbPath);
      addTearDown(app.close);

      final rows = await app.database.query('quota_cache');
      expect(rows.map((row) => row['quota_key']), ['kept']);
    });

    test(
      'a v3 database that lost its quota_cache rows still upgrades',
      () async {
        await seedAtV3();

        final app = await AppDatabase.open(path: dbPath);
        addTearDown(app.close);

        final version = await app.database.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 4);
      },
    );

    test(
      'recovers when the rebuild committed but user_version is stale',
      () async {
        await seedAtV3();
        final seed = await databaseFactoryFfi.openDatabase(dbPath);
        await insertConnection(seed, 'c1');
        await insertQuota(seed, 'c1', 'q1');
        await seed.close();

        final first = await AppDatabase.open(path: dbPath);
        // The crash window MigrationSupport exists for: DDL committed, the
        // version marker never written. The rebuild must be recognisable as
        // already done, or the next launch re-runs it against a table that no
        // longer has the columns it selects.
        await first.database.execute('PRAGMA user_version = 3');
        await first.close();

        final second = await AppDatabase.open(path: dbPath);
        addTearDown(second.close);

        final version = await second.database.rawQuery('PRAGMA user_version');
        expect((version.first.values.first as num).toInt(), 4);
        final rows = await second.database.query('quota_cache');
        expect(rows, hasLength(1));
        expect(rows.single['quota_key'], 'q1');
      },
    );

    test('reopening after the upgrade is a no-op and keeps the data', () async {
      await seedAtV3();
      final seed = await databaseFactoryFfi.openDatabase(dbPath);
      await insertConnection(seed, 'c1');
      await insertQuota(seed, 'c1', 'q1');
      await seed.close();

      final first = await AppDatabase.open(path: dbPath);
      await first.close();

      final second = await AppDatabase.open(path: dbPath);
      addTearDown(second.close);

      final version = await second.database.rawQuery('PRAGMA user_version');
      expect((version.first.values.first as num).toInt(), 4);
      final rows = await second.database.query('quota_cache');
      expect(rows, hasLength(1));
      final pragma = await second.database.rawQuery('PRAGMA foreign_keys');
      expect((pragma.first.values.first as num).toInt(), 1);
    });
  });
}
