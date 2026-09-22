import 'package:sqflite_common/sqlite_api.dart';
import 'package:tokendock/models/quota.dart';

abstract interface class QuotaCacheRepository {
  Future<List<Quota>> getAll(String connectionId);
  Future<void> saveAll(String connectionId, List<Quota> quotas);
  Future<void> deleteForConnection(String connectionId);
}

class SqliteQuotaCacheRepository implements QuotaCacheRepository {
  SqliteQuotaCacheRepository(this._db);

  final Database _db;

  @override
  Future<List<Quota>> getAll(String connectionId) async {
    final rows = await _db.query(
      'quota_cache',
      where: 'connection_id = ?',
      whereArgs: [connectionId],
    );
    return rows.map((row) {
      final resetAtStr = row['reset_at'] as String?;
      final resetAt =
          resetAtStr != null ? DateTime.parse(resetAtStr).toUtc() : null;
      return Quota(
        id: row['quota_key'] as String,
        label: row['label'] as String,
        percent: (row['percent'] as num?)?.toDouble(),
        remaining: (row['remaining'] as num?)?.toDouble(),
        limit: (row['limit_value'] as num?)?.toDouble(),
        unit: row['unit'] as String?,
        resetAt: resetAt,
      );
    }).toList();
  }

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      await txn.delete(
        'quota_cache',
        where: 'connection_id = ?',
        whereArgs: [connectionId],
      );
      for (final quota in quotas) {
        await txn.insert(
          'quota_cache',
          {
            'connection_id': connectionId,
            'quota_key': quota.id,
            'label': quota.label,
            'percent': quota.percent,
            'remaining': quota.remaining,
            'limit_value': quota.limit,
            'unit': quota.unit,
            'reset_at': quota.resetAt?.toUtc().toIso8601String(),
            'status': null,
            'updated_at': now,
          },
        );
      }
    });
  }

  @override
  Future<void> deleteForConnection(String connectionId) async {
    await _db.delete(
      'quota_cache',
      where: 'connection_id = ?',
      whereArgs: [connectionId],
    );
  }
}
