import 'package:sqflite_common/sqlite_api.dart';

import 'migration_support.dart';

class Migration003 {
  static const int version = 3;

  static const Map<String, String> _identityColumns = <String, String>{
    'identity_key': 'TEXT',
    'provider_data': 'TEXT',
  };

  static Future<void> run(Database db) async {
    final currentVersion = await MigrationSupport.currentVersion(db);
    if (currentVersion >= version) {
      return;
    }

    await db.transaction((txn) async {
      await MigrationSupport.addMissingColumns(
        txn,
        table: 'connections',
        columns: _identityColumns,
      );
      await MigrationSupport.stampVersion(txn, version);
    });
  }
}
