import 'package:sqflite_common/sqlite_api.dart';

import 'migration_support.dart';

class Migration001 {
  static const int version = 1;

  static Future<void> run(Database db) async {
    final currentVersion = await MigrationSupport.currentVersion(db);
    if (currentVersion >= version) {
      return;
    }

    await db.transaction((txn) async {
      await txn.execute('''
        CREATE TABLE IF NOT EXISTS connections (
          id TEXT PRIMARY KEY,
          provider TEXT NOT NULL,
          display_name TEXT NOT NULL,
          group_name TEXT,
          plan TEXT,
          auth_type TEXT,
          secret_ref TEXT NOT NULL,
          enabled INTEGER NOT NULL DEFAULT 1,
          sort_order INTEGER NOT NULL DEFAULT 0,
          created_at TEXT NOT NULL,
          updated_at TEXT NOT NULL
        )
      ''');

      await txn.execute('''
        CREATE TABLE IF NOT EXISTS quota_cache (
          connection_id TEXT NOT NULL,
          quota_key TEXT NOT NULL,
          label TEXT NOT NULL,
          percent REAL,
          remaining REAL,
          limit_value REAL,
          unit TEXT,
          reset_at TEXT,
          status TEXT,
          updated_at TEXT NOT NULL,
          PRIMARY KEY (connection_id, quota_key)
        )
      ''');

      await txn.execute('''
        CREATE TABLE IF NOT EXISTS settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');

      await txn.execute('''
        CREATE INDEX IF NOT EXISTS idx_quota_cache_connection ON quota_cache(connection_id)
      ''');

      // The schema and the version marker now commit together, so a crash can
      // no longer leave the DDL applied with a stale `user_version`.
      await MigrationSupport.stampVersion(txn, version);
    });
  }
}
