import 'package:sqflite_common/sqlite_api.dart';
import 'package:tokendock/models/quota.dart';

/// Parses an ISO-8601 UTC timestamp written by [saveAll].
///
/// A value this version did not write (manual edit, a future writer, a
/// partially applied migration) degrades to `null` instead of throwing. A
/// throwing read here would take down every connection's cached quota, not
/// just the corrupted row.
DateTime? _parseUtc(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value)?.toUtc();
}

Quota _toQuota(Map<String, Object?> row) => Quota(
      id: row['quota_key'] as String,
      label: row['label'] as String,
      percent: (row['percent'] as num?)?.toDouble(),
      remaining: (row['remaining'] as num?)?.toDouble(),
      limit: (row['limit_value'] as num?)?.toDouble(),
      unit: row['unit'] as String?,
      resetAt: _parseUtc(row['reset_at'] as String?),
    );

abstract interface class QuotaCacheRepository {
  Future<List<Quota>> getAll(String connectionId);

  /// Cached quotas for several connections in one query.
  ///
  /// Loading the widget read one connection at a time, which is a query per
  /// account on the startup path (audit C-17). Returns a map keyed by
  /// connection id, with an empty list for any id that has no cached row.
  Future<Map<String, List<Quota>>> getAllForAll(List<String> connectionIds);

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
    return rows.map(_toQuota).toList();
  }

  @override
  Future<Map<String, List<Quota>>> getAllForAll(
    List<String> connectionIds,
  ) async {
    if (connectionIds.isEmpty) return const {};
    final placeholders = List.filled(connectionIds.length, '?').join(', ');
    final rows = await _db.query(
      'quota_cache',
      where: 'connection_id IN ($placeholders)',
      whereArgs: connectionIds,
    );
    final grouped = <String, List<Quota>>{
      for (final id in connectionIds) id: <Quota>[],
    };
    for (final row in rows) {
      final id = row['connection_id'] as String;
      grouped.putIfAbsent(id, () => <Quota>[]).add(_toQuota(row));
    }
    return grouped;
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
        await txn.insert('quota_cache', {
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
        });
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
