import 'package:sqflite_common/sqlite_api.dart';

class Migration003 {
  static const int version = 3;

  static Future<void> run(Database db) async {
    final result = await db.rawQuery('PRAGMA user_version');
    final currentVersion = (result.first.values.first as num?)?.toInt() ?? 0;
    if (currentVersion >= version) {
      return;
    }

    await db.transaction((txn) async {
      await txn.execute(
        'ALTER TABLE connections ADD COLUMN identity_key TEXT',
      );
      await txn.execute(
        'ALTER TABLE connections ADD COLUMN provider_data TEXT',
      );
    });

    await db.execute('PRAGMA user_version = $version');
  }
}
