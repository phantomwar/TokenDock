import 'package:sqflite_common/sqlite_api.dart';

/// Shared helpers for the hand-rolled, forward-only schema migrations.
///
/// The project deliberately owns `PRAGMA user_version` itself instead of
/// passing `version:` to `openDatabase`, so these helpers centralise the two
/// rules every migration must obey:
///
/// 1. Apply DDL and stamp `user_version` inside the **same** transaction.
///    A crash between the two used to leave the DDL applied with a stale
///    version, and the next launch re-ran the `ALTER TABLE` and died on
///    `duplicate column name` before `runApp`.
/// 2. Never assume a statement is safe to repeat. `Migration001` can rely on
///    `CREATE TABLE IF NOT EXISTS`; `ALTER TABLE ADD COLUMN` has no
///    `IF NOT EXISTS` form in SQLite, so column additions are gated on
///    `PRAGMA table_info`.
abstract final class MigrationSupport {
  /// Reads the current schema version, defaulting to `0` for a fresh file.
  static Future<int> currentVersion(DatabaseExecutor db) async {
    final result = await db.rawQuery('PRAGMA user_version');
    final value = result.first.values.first as num?;
    return value?.toInt() ?? 0;
  }

  /// Column names currently present on [table].
  static Future<Set<String>> columnNames(
    DatabaseExecutor db,
    String table,
  ) async {
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return rows.map((row) => row['name'] as String).toSet();
  }

  /// Adds each column in [columns] that [table] does not already have.
  ///
  /// Returns the names actually added. Skipping existing columns is what makes
  /// a partially applied migration resumable.
  static Future<List<String>> addMissingColumns(
    DatabaseExecutor db, {
    required String table,
    required Map<String, String> columns,
  }) async {
    final existing = await columnNames(db, table);
    final added = <String>[];
    for (final entry in columns.entries) {
      if (existing.contains(entry.key)) continue;
      await db.execute(
        'ALTER TABLE $table ADD COLUMN ${entry.key} ${entry.value}',
      );
      added.add(entry.key);
    }
    return added;
  }

  /// Stamps [version] inside the caller's transaction so the DDL above it and
  /// the version marker commit or roll back together.
  static Future<void> stampVersion(DatabaseExecutor db, int version) =>
      db.execute('PRAGMA user_version = $version');
}
