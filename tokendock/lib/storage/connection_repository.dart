import 'package:sqflite_common/sqlite_api.dart';
import 'package:tokendock/models/connection.dart';

abstract interface class ConnectionRepository {
  Future<List<Connection>> getAll();
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
    return rows.map((row) {
      return Connection(
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
    }).toList();
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
        'provider_data': connection.providerData,
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
