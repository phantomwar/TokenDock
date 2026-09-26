import 'package:sqflite_common/sqlite_api.dart';

import 'migration_support.dart';

class Migration002 {
  static const int version = 2;

  static const Map<String, String> _healthColumns = <String, String>{
    'last_status': 'TEXT',
    'last_checked_at': 'TEXT',
    'cooldown_until': 'TEXT',
    'last_error': 'TEXT',
  };

  static Future<void> run(Database db) async {
    final currentVersion = await MigrationSupport.currentVersion(db);
    if (currentVersion >= version) {
      return;
    }

    await db.transaction((txn) async {
      // SQLite has no `ADD COLUMN IF NOT EXISTS`, so a migration interrupted
      // midway would previously abort the next launch on
      // `duplicate column name`. Adding only what is missing makes this step
      // resumable.
      await MigrationSupport.addMissingColumns(
        txn,
        table: 'connections',
        columns: _healthColumns,
      );
      await MigrationSupport.stampVersion(txn, version);
    });
  }
}
