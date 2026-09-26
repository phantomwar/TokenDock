import 'package:sqflite_common/sqlite_api.dart';

import '../models/connection_health.dart';
import '../models/connection_status.dart';

/// Parses an ISO-8601 UTC timestamp written by [save].
///
/// A malformed value degrades to `null` rather than throwing, so one
/// corrupted row cannot break the health read for every connection.
DateTime? _parseUtc(String? value) {
  if (value == null) return null;
  return DateTime.tryParse(value)?.toUtc();
}

abstract interface class ConnectionHealthRepository {
  Future<ConnectionHealth?> get(String connectionId);
  Future<void> save(ConnectionHealth health);
}

class SqliteConnectionHealthRepository implements ConnectionHealthRepository {
  SqliteConnectionHealthRepository(this._db);

  final Database _db;

  @override
  Future<ConnectionHealth?> get(String connectionId) async {
    final rows = await _db.query(
      'connections',
      columns: [
        'last_status',
        'last_checked_at',
        'cooldown_until',
        'last_error',
      ],
      where: 'id = ?',
      whereArgs: [connectionId],
      limit: 1,
    );
    if (rows.isEmpty) return null;

    final row = rows.first;
    final statusName = row['last_status'] as String?;
    final checkedAt = row['last_checked_at'] as String?;
    if (statusName == null || checkedAt == null) return null;

    final status = ConnectionStatus.values.firstWhere(
      (value) => value.name == statusName,
      orElse: () => ConnectionStatus.error,
    );
    final cooldown = row['cooldown_until'] as String?;
    final lastChecked = _parseUtc(checkedAt);
    if (lastChecked == null) return null;
    return ConnectionHealth(
      connectionId: connectionId,
      status: status,
      lastCheckedAt: lastChecked,
      cooldownUntil: _parseUtc(cooldown),
      error: row['last_error'] as String?,
    );
  }

  @override
  Future<void> save(ConnectionHealth health) async {
    await _db.update(
      'connections',
      {
        'last_status': health.status.name,
        'last_checked_at': health.lastCheckedAt.toUtc().toIso8601String(),
        'cooldown_until': health.cooldownUntil?.toUtc().toIso8601String(),
        'last_error': health.error,
      },
      where: 'id = ?',
      whereArgs: [health.connectionId],
    );
  }
}
