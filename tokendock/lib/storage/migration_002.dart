import 'package:sqflite_common/sqlite_api.dart';

class Migration002 {
  static const int version = 2;

  static Future<void> run(Database db) async {
    final result = await db.rawQuery('PRAGMA user_version');
    final currentVersion = (result.first.values.first as num?)?.toInt() ?? 0;
    if (currentVersion >= version) {
      return;
    }

    await db.transaction((txn) async {
      await txn.execute('ALTER TABLE connections ADD COLUMN last_status TEXT');
      await txn.execute(
        'ALTER TABLE connections ADD COLUMN last_checked_at TEXT',
      );
      await txn.execute(
        'ALTER TABLE connections ADD COLUMN cooldown_until TEXT',
      );
      await txn.execute('ALTER TABLE connections ADD COLUMN last_error TEXT');
    });

    await db.execute('PRAGMA user_version = $version');
  }
}
