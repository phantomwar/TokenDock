import 'package:sqflite_common/sqlite_api.dart';

abstract interface class SettingsRepository {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<int> getRefreshIntervalMinutes();
  Future<void> setRefreshIntervalMinutes(int minutes);
}

class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(this._db);

  final Database _db;

  static const String refreshIntervalKey = 'refresh_interval_minutes';
  static const int defaultRefreshIntervalMinutes = 3;

  @override
  Future<String?> get(String key) async {
    final rows = await _db.query(
      'settings',
      columns: ['value'],
      where: 'key = ?',
      whereArgs: [key],
      limit: 1,
    );
    if (rows.isEmpty) {
      return null;
    }
    return rows.first['value'] as String?;
  }

  @override
  Future<void> set(String key, String value) async {
    await _db.insert(
      'settings',
      {
        'key': key,
        'value': value,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  @override
  Future<int> getRefreshIntervalMinutes() async {
    final raw = await get(refreshIntervalKey);
    if (raw == null) {
      return defaultRefreshIntervalMinutes;
    }
    return int.tryParse(raw) ?? defaultRefreshIntervalMinutes;
  }

  @override
  Future<void> setRefreshIntervalMinutes(int minutes) async {
    await set(refreshIntervalKey, minutes.toString());
  }
}
