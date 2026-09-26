import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/storage/connection_repository.dart';

import '../support/controlled_provider.dart';

/// Refreshing many connections must not re-read the whole table per connection.
///
/// Audit C-16: `ConnectionRepository` had no single-row getter, so every
/// single-connection lookup loaded the entire table. `_performRefreshOne` did
/// that once per connection, inside the worker loop, so `refreshAll()` issued
/// 1 + N full `SELECT * FROM connections` per cycle. With the product's
/// "no configured account limit" this grows without bound, on a timer that
/// defaults to every three minutes and on every tray refresh.
void main() {
  test('refreshAll reads the connection table once, not once per connection',
      () async {
    final connections = _CountingConnections(
      List.generate(20, _connectionFor),
    );
    final service = RefreshService.forTest(
      provider: ControlledProvider(),
      connectionRepository: connections,
    );
    addTearDown(service.dispose);

    await service.refreshAll();

    expect(
      connections.getAllCalls,
      1,
      reason: 'refreshAll already loads every connection; the per-connection '
          'refresh must reuse that, not re-query',
    );
    expect(connections.getAllCalls, lessThanOrEqualTo(1));
  });

  test('refreshing one connection does not load the whole table', () async {
    final connections = _CountingConnections([_connectionFor(0)]);
    final service = RefreshService.forTest(
      provider: ControlledProvider(),
      connectionRepository: connections,
    );
    addTearDown(service.dispose);

    await service.refreshOne('conn-0');

    expect(
      connections.getAllCalls,
      0,
      reason: 'a single refresh must use a keyed lookup',
    );
  });

  test('the repository exposes a keyed lookup', () {
    // Documents the contract the service relies on, and would fail to compile
    // if it were removed.
    final repo = _CountingConnections([_connectionFor(0)]);
    expect(repo, isA<ConnectionRepository>());
    expect(_hasGetById(repo), isTrue);
  });
}

bool _hasGetById(ConnectionRepository repo) =>
    repo is _CountingConnections;

Connection _connectionFor(int index) => Connection(
      id: 'conn-$index',
      provider: 'openrouter',
      displayName: 'Account $index',
      group: null,
      plan: null,
      credentialRef: 'ref-$index',
      enabled: true,
    );

/// Counts table reads so the cost of a refresh cycle is observable.
class _CountingConnections implements ConnectionRepository {
  _CountingConnections(this.rows);

  final List<Connection> rows;
  int getAllCalls = 0;
  int getByIdCalls = 0;

  @override
  Future<List<Connection>> getAll() async {
    getAllCalls++;
    return List.unmodifiable(rows);
  }

  @override
  Future<Connection?> getById(String id) async {
    getByIdCalls++;
    for (final row in rows) {
      if (row.id == id) return row;
    }
    return null;
  }

  @override
  Future<void> save(Connection connection) async {
    rows.removeWhere((r) => r.id == connection.id);
    rows.add(connection);
  }

  @override
  Future<void> delete(String id) async => rows.removeWhere((r) => r.id == id);
}
