import 'package:sqflite_common/sqlite_api.dart';

abstract interface class SettingsRepository {
  Future<String?> get(String key);
  Future<void> set(String key, String value);
  Future<int> getRefreshIntervalMinutes();
  Future<void> setRefreshIntervalMinutes(int minutes);
}

const int defaultRefreshIntervalMinutes = 3;
const Set<int> supportedRefreshIntervalsMinutes = <int>{0, 1, 3, 5, 10};

int normalizeRefreshIntervalMinutes(int minutes) =>
    supportedRefreshIntervalsMinutes.contains(minutes)
    ? minutes
    : defaultRefreshIntervalMinutes;

void validateRefreshIntervalMinutes(int minutes) {
  if (!supportedRefreshIntervalsMinutes.contains(minutes)) {
    throw ArgumentError.value(
      minutes,
      'minutes',
      'Use 0 (manual), 1, 3, 5, or 10.',
    );
  }
}

class SqliteSettingsRepository implements SettingsRepository {
  SqliteSettingsRepository(this._db);

  final Database _db;

  static const String refreshIntervalKey = 'refresh_interval_minutes';

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
    await _db.insert('settings', {
      'key': key,
      'value': value,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  @override
  Future<int> getRefreshIntervalMinutes() async {
    final raw = await get(refreshIntervalKey);
    if (raw == null) {
      return defaultRefreshIntervalMinutes;
    }
    return normalizeRefreshIntervalMinutes(
      int.tryParse(raw) ?? defaultRefreshIntervalMinutes,
    );
  }

  @override
  Future<void> setRefreshIntervalMinutes(int minutes) async {
    validateRefreshIntervalMinutes(minutes);
    await set(refreshIntervalKey, minutes.toString());
  }
}
