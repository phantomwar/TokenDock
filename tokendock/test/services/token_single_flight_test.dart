import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/secret_store.dart';

import '../support/controlled_provider.dart';

class _MemoryConnections implements ConnectionRepository {
  final List<Connection> _rows = [];
  @override
  Future<List<Connection>> getAll() async => List.unmodifiable(_rows);
  @override
  Future<List<StoredConnection>> getAllWithHealth() async => _rows
      .map((row) => StoredConnection(connection: row))
      .toList();
  @override
  Future<Connection?> getById(String id) async {
    for (final row in _rows) {
      if (row.id == id) return row;
    }
    return null;
  }
  @override
  Future<void> save(Connection connection) async {
    _rows.removeWhere((row) => row.id == connection.id);
    _rows.add(connection);
  }

  @override
  Future<void> delete(String id) async =>
      _rows.removeWhere((row) => row.id == id);
}

class _MemorySecrets implements SecretStore {
  final Map<String, String> _values = {};
  @override
  Future<void> write(String key, String value) async => _values[key] = value;
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<void> delete(String key) async => _values.remove(key);
}

/// Per-connection single-flight for credential/token exchange.
///
/// Audit C-09: `runTokenOperation` was implemented and tested but never called
/// from `lib/`, so nothing de-duplicated a token exchange. Worse, it delegated
/// to `runConnectionOperation`, which *chains* when the connection already has
/// an in-flight operation. Since `_performRefreshOne` runs while holding that
/// slot, wiring it in naively would make a refresh wait on itself.
void main() {
  RefreshService service() =>
      RefreshService.forTest(provider: ControlledProvider());

  group('runTokenOperation single-flight', () {
    test('a token operation issued from inside a connection operation '
        'completes instead of deadlocking', () async {
      final refresh = service();
      addTearDown(refresh.dispose);
      final completed = Completer<void>();

      refresh
          .runConnectionOperation<void>(
            connectionId: 'conn-a',
            operation: () async {
              // Yield first so the service has published its in-flight entry
              // for this connection, exactly as _performRefreshOne does after
              // its cache and credential reads.
              await Future<void>.delayed(Duration.zero);
              // Mirrors _performRefreshOne: the refresh holds the connection's
              // in-flight slot and then exchanges the credential.
              final rotated = await refresh.runTokenOperation(
                connectionId: 'conn-a',
                operation: () async => 'rotated',
              );
              expect(rotated, 'rotated');
              completed.complete();
            },
          )
          .ignore();

      await completed.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail(
          'a token operation nested inside its own connection slot deadlocked',
        ),
      );
    });

    test(
      'concurrent token operations for one connection share one call',
      () async {
        final refresh = service();
        addTearDown(refresh.dispose);
        final gate = Completer<void>();
        var calls = 0;

        Future<String> run() => refresh.runTokenOperation(
          connectionId: 'conn-a',
          operation: () async {
            calls++;
            await gate.future;
            return 'rotated';
          },
        );

        final first = run();
        final second = run();
        gate.complete();

        expect(await first, 'rotated');
        expect(await second, 'rotated');
        expect(calls, 1);
      },
    );

    test(
      'token operations for different connections do not block each other',
      () async {
        final refresh = service();
        addTearDown(refresh.dispose);
        final gate = Completer<void>();
        var calls = 0;

        final a = refresh.runTokenOperation(
          connectionId: 'conn-a',
          operation: () async {
            calls++;
            await gate.future;
            return 'a';
          },
        );
        final b = refresh.runTokenOperation(
          connectionId: 'conn-b',
          operation: () async {
            calls++;
            return 'b';
          },
        );

        expect(await b, 'b');
        expect(calls, 2);
        gate.complete();
        expect(await a, 'a');
      },
    );

    test(
      'a failed token operation does not poison the connection slot',
      () async {
        final refresh = service();
        addTearDown(refresh.dispose);

        await expectLater(
          refresh.runTokenOperation(
            connectionId: 'conn-a',
            operation: () async => throw StateError('invalid_grant'),
          ),
          throwsA(isA<StateError>()),
        );

        // A later exchange must still be possible.
        expect(
          await refresh.runTokenOperation(
            connectionId: 'conn-a',
            operation: () async => 'recovered',
          ),
          'recovered',
        );
      },
    );

    test('a token operation completes even when a refresh is in flight for '
        'the same connection', () async {
      final provider = ControlledProvider();
      final connections = _MemoryConnections();
      final secrets = _MemorySecrets();
      final refresh = RefreshService.forTest(
        provider: provider,
        connectionRepository: connections,
        secretStore: secrets,
        autoStartTimer: false,
      );
      addTearDown(refresh.dispose);

      await connections.save(
        const Connection(
          id: 'conn-a',
          provider: 'openrouter',
          displayName: 'A',
          group: null,
          plan: null,
          credentialRef: 'conn-a',
          enabled: true,
        ),
      );
      await secrets.write('conn-a', 'secret');
      provider.gate = Completer<void>();

      final refreshing = refresh.refreshOne('conn-a');
      // Let the refresh reach the parked fetch.
      await Future<void>.delayed(Duration.zero);

      final rotated = await refresh
          .runTokenOperation(
            connectionId: 'conn-a',
            operation: () async => 'rotated',
          )
          .timeout(const Duration(seconds: 5));

      expect(rotated, 'rotated');

      provider.gate!.complete();
      await refreshing;
    });
  });
}
