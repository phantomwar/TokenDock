import 'package:sqflite_common/sqlite_api.dart';

import 'migration_support.dart';

/// C-23: schema integrity.
///
/// SQLite cannot add a foreign key to an existing table, so declaring the
/// cascade from `quota_cache` to `connections` means rebuilding the table.
/// The same rebuild is the only way to retire the dead `status` column, so the
/// copy has to be written to survive whatever the old table happens to hold.
///
/// Two properties matter more than the DDL itself:
///
/// 1. **Orphans are purged, not copied.** `ON DELETE CASCADE` only helps
///    going forward. A row whose parent is already gone survives a delete of
///    nothing, and the copy is the last moment it can be dropped. Copying
///    blindly would also abort the migration outright: once the pragma is on,
///    inserting an orphan raises `FOREIGN KEY constraint failed` (error 787).
/// 2. **The rebuild is recognisable as done.** `PRAGMA foreign_keys` is a
///    no-op inside a transaction, so this migration cannot defensively turn
///    enforcement off around its own DDL. That is also why
///    `AppDatabase.open` applies the pragma *after* the migrations rather than
///    through sqflite's `onConfigure`, which would fire before this runs.
class Migration004 {
  static const int version = 4;

  /// The rebuilt table, named so a half-finished run is recognisable.
  static const String _staging = 'quota_cache_v4';

  static Future<void> run(Database db) async {
    final currentVersion = await MigrationSupport.currentVersion(db);
    if (currentVersion >= version) {
      return;
    }

    await db.transaction((txn) async {
      if (!await _declaresCascade(txn)) {
        await _rebuildQuotaCache(txn);
      }

      // Duplicates the leftmost column of the `(connection_id, quota_key)`
      // primary key, so the planner gains nothing from it. Dropped separately
      // because `DROP TABLE` only clears it when the rebuild actually ran.
      await txn.execute('DROP INDEX IF EXISTS idx_quota_cache_connection');

      // C.1 stopped the N+1 but left the query it still issues uncovered. The
      // widget orders by `sort_order, created_at` on every load.
      await txn.execute(
        'CREATE INDEX IF NOT EXISTS idx_connections_sort_order '
        'ON connections(sort_order, created_at)',
      );

      await MigrationSupport.stampVersion(txn, version);
    });
  }

  /// True once [table] declares at least one foreign key, which is how a
  /// re-run recognises a rebuild that already committed.
  static Future<bool> _declaresCascade(DatabaseExecutor db) async {
    final rows = await db.rawQuery('PRAGMA foreign_key_list(quota_cache)');
    return rows.isNotEmpty;
  }

  static Future<void> _rebuildQuotaCache(DatabaseExecutor db) async {
    await db.execute('DROP TABLE IF EXISTS $_staging');

    // `status` is absent by design: it was always written as null and is never
    // read, so there is nothing to preserve.
    await db.execute('''
      CREATE TABLE $_staging (
        connection_id TEXT NOT NULL,
        quota_key TEXT NOT NULL,
        label TEXT NOT NULL,
        percent REAL,
        remaining REAL,
        limit_value REAL,
        unit TEXT,
        reset_at TEXT,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (connection_id, quota_key),
        FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE
      )
    ''');

    // The `WHERE EXISTS` is the orphan purge. It has to be a filter rather
    // than a post-copy delete, because a row that fails the constraint takes
    // the whole transaction down with it.
    await db.execute('''
      INSERT INTO $_staging (
        connection_id, quota_key, label, percent, remaining,
        limit_value, unit, reset_at, updated_at
      )
      SELECT
        q.connection_id, q.quota_key, q.label, q.percent, q.remaining,
        q.limit_value, q.unit, q.reset_at, q.updated_at
      FROM quota_cache q
      WHERE EXISTS (SELECT 1 FROM connections c WHERE c.id = q.connection_id)
    ''');

    await db.execute('DROP TABLE quota_cache');
    await db.execute('ALTER TABLE $_staging RENAME TO quota_cache');
  }
}
