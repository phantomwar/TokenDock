import 'dart:convert';

import 'package:sqflite_common/sqlite_api.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/secret_store.dart';

/// A connection together with the health stored on its own row.
///
/// `ConnectionHealth` lives in columns of the `connections` table, so reading a
/// connection and its health is one row, not two queries.
class StoredConnection {
  const StoredConnection({required this.connection, this.health});

  final Connection connection;

  /// Null when no refresh has been recorded for this connection yet.
  final ConnectionHealth? health;
}

abstract interface class ConnectionRepository {
  Future<List<Connection>> getAll();

  /// Every connection with the health already present on its row.
  ///
  /// Loading the widget previously issued 1 + 2N queries: one for the
  /// connections, then a keyed read for cached quotas and another for health
  /// inside the loop, even though the health columns had been selected and
  /// discarded (audit C-17).
  Future<List<StoredConnection>> getAllWithHealth();

  /// Single-connection lookup.
  ///
  /// Present so a per-connection operation does not have to load and filter the
  /// whole table. Without it, refreshing N connections issued N+1 full reads
  /// per cycle (audit C-16), which grows with the account count on a timer.
  Future<Connection?> getById(String id);

  Future<void> save(Connection connection);
  Future<void> delete(String id);
}

class SqliteConnectionRepository implements ConnectionRepository {
  SqliteConnectionRepository(this._db);

  final Database _db;

  @override
  Future<List<Connection>> getAll() async {
    final rows = await _db.query(
      'connections',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(_toConnection).toList();
  }

  @override
  Future<List<StoredConnection>> getAllWithHealth() async {
    final rows = await _db.query(
      'connections',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows
        .map(
          (row) => StoredConnection(
            connection: _toConnection(row),
            health: healthFromRow(row),
          ),
        )
        .toList();
  }

  @override
  Future<Connection?> getById(String id) async {
    final rows = await _db.query(
      'connections',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return _toConnection(rows.first);
  }

  @override
  Future<void> save(Connection connection) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _db.transaction((txn) async {
      final existing = await txn.query(
        'connections',
        columns: ['id'],
        where: 'id = ?',
        whereArgs: [connection.id],
        limit: 1,
      );
      final connectionValues = {
        'provider': connection.provider,
        'display_name': connection.displayName,
        'group_name': connection.group,
        'plan': connection.plan,
        'secret_ref': connection.credentialRef,
        'enabled': connection.enabled ? 1 : 0,
        'updated_at': now,
        'auth_type': connection.authType,
        'identity_key': connection.identityKey,
        'provider_data': _sanitizeProviderData(connection.providerData),
      };

      if (existing.isNotEmpty) {
        await txn.update(
          'connections',
          connectionValues,
          where: 'id = ?',
          whereArgs: [connection.id],
        );
        return;
      }

      await txn.insert('connections', {
        'id': connection.id,
        ...connectionValues,
        'sort_order': 0,
        'created_at': now,
      });
    });
  }

  @override
  Future<void> delete(String id) async {
    await _db.transaction((txn) async {
      await txn.delete(
        'quota_cache',
        where: 'connection_id = ?',
        whereArgs: [id],
      );
      await txn.delete('connections', where: 'id = ?', whereArgs: [id]);
    });
  }
}

Connection _toConnection(Map<String, Object?> row) => Connection(
      id: row['id'] as String,
      provider: row['provider'] as String,
      displayName: row['display_name'] as String,
      group: row['group_name'] as String?,
      plan: row['plan'] as String?,
      credentialRef: row['secret_ref'] as String,
      enabled: (row['enabled'] as int? ?? 1) == 1,
      authType: row['auth_type'] as String?,
      identityKey: row['identity_key'] as String?,
      providerData: row['provider_data'] as String?,
    );

String? _sanitizeProviderData(String? value) {  if (value == null || value.isEmpty) return value;
  try {
    final decoded = jsonDecode(value);
    if (decoded is! Map) return null;
    return jsonEncode(
      _withoutSensitiveFields(Map<String, dynamic>.from(decoded)),
    );
  } catch (_) {
    return null;
  }
}

/// Strips every credential-bearing key before the value reaches SQLite.
///
/// Uses the shared [isSensitiveKeyName] predicate rather than a CSRF-only
/// check, so `accessToken`, `refreshToken`, `idToken`, `apiKey` and friends are
/// removed alongside `csrfToken` at any nesting depth. Non-secret provider
/// metadata such as `source`, `projectId` and `tier` is preserved.
dynamic _withoutSensitiveFields(dynamic value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        if (!isSensitiveKeyName(entry.key as String))
          entry.key as String: _withoutSensitiveFields(entry.value),
    };
  }
  if (value is List) {
    return value.map(_withoutSensitiveFields).toList();
  }
  return value;
}
