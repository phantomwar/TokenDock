import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/models/test_result.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';
import 'package:tokendock/services/refreshable_credential.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';
import 'package:tokendock/storage/secret_store.dart';
import 'package:tokendock/ui/settings/connections_screen.dart';

/// Storage and provider failures must never reach the user as raw exception
/// text.
///
/// Audit C-15 and C-12: the connection dialog interpolated the exception object
/// directly into user-facing copy in three places. A `DatabaseException` renders
/// as `DatabaseException(SqliteException(1): while executing, no such table:
/// connections, SQL logic error (code 1) Causing statement: SELECT * FROM
/// connections)`, so the user saw table names, SQL and SQLite error codes. The
/// same pattern could surface a credential, because the exception may carry one
/// and `redactSecret` is imported only by `refresh_service.dart`.
void main() {
  group('storage failures are not shown as raw SQL', () {
    testWidgets('a failing save does not leak SQL into the dialog', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        repo: _SqlFailingRepository(_MemoryConnections()),
        adapter: _LeakyProvider(),
      );

      await tester.tap(find.byKey(const Key('editConnection_c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('saveConnection')));
      await tester.pumpAndSettle();

      final text = visibleText(tester).join(' | ').toLowerCase();
      for (final leak in const [
        'sqlite',
        'select',
        'insert ',
        'delete from',
        'quota_cache',
        'secret_ref',
        'causing statement',
      ]) {
        expect(
          text,
          isNot(contains(leak)),
          reason: 'the dialog must not expose "$leak"',
        );
      }
      expect(text, isNotEmpty);
    });

    testWidgets('a failing delete does not leak SQL into the snackbar', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        repo: _SqlFailingRepository(_MemoryConnections()),
        adapter: _LeakyProvider(),
      );

      await tester.tap(find.byKey(const Key('deleteConnection_c1')));
      await tester.pumpAndSettle();

      final text = visibleText(tester).join(' | ').toLowerCase();
      expect(text, isNot(contains('sqlite')));
      expect(text, isNot(contains('delete from')));
      expect(text, isNot(contains('quota_cache')));
    });
  });

  group('provider failures do not leak credential material', () {
    testWidgets('a failing test never shows the credential in its message', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        repo: _MemoryConnections(),
        adapter: _LeakyProvider(),
      );

      await tester.tap(find.byKey(const Key('editConnection_c1')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      final text = visibleText(tester).join(' | ');
      expect(
        text,
        isNot(contains('LIVEKEY0123456789')),
        reason: 'the probe exception carries a key and must not be shown',
      );
      expect(text, isNot(contains('sk-')));
    });
  });
}

const _connection = Connection(
  id: 'c1',
  provider: 'openrouter',
  displayName: 'Existing',
  group: null,
  plan: null,
  credentialRef: 'ref',
  enabled: true,
);

/// A repository whose failures carry SQL and column detail.
class _SqlFailingRepository implements ConnectionRepository {
  _SqlFailingRepository(this.inner);
  final ConnectionRepository inner;

  @override
  Future<List<Connection>> getAll() => inner.getAll();

  @override
  Future<Connection?> getById(String id) => inner.getById(id);

  @override
  Future<void> save(Connection connection) async {
    throw const _SqlException(
      'SQL logic error (code 1) no such table: connections. '
      'Causing statement: INSERT INTO connections(id, secret_ref) '
      'VALUES(?, ?)',
    );
  }

  @override
  Future<void> delete(String id) async {
    throw const _SqlException(
      'database disk image is malformed (code 11). '
      'Causing statement: DELETE FROM quota_cache WHERE connection_id = ?',
    );
  }
}

/// Stands in for a storage failure carrying SQL and column detail.
///
/// The UI's obligation is identical for any exception: never interpolate it.
/// The repository layer's own translation of a real `DatabaseException` is
/// covered separately in `storage_failure_test.dart`, against a real database.
class _SqlException implements Exception {
  const _SqlException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A provider whose failure message contains credential-shaped material.
class _LeakyProvider implements ProviderAdapter {
  @override
  String get id => 'openrouter';
  @override
  String get name => 'OpenRouter';
  @override
  AuthKind get authKind => AuthKind.apiKey;
  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };
  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  @override
  Future<TestResult> test(Connection connection, String secret) async =>
      throw StateError(
        'probe failed for key: sk-or-v1-LIVEKEY0123456789abcdef',
      );

  @override
  Future<ProviderSnapshot> fetch(Connection c, String s) =>
      throw UnimplementedError();
}

class _MemoryConnections implements ConnectionRepository {
  final List<Connection> rows = [_connection];
  @override
  Future<List<Connection>> getAll() async => List.of(rows);
  @override
  Future<Connection?> getById(String id) async {
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

class _MemorySecrets implements SecretStore {
  final Map<String, String> values = {'ref': 'sk-stored-value'};
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> delete(String key) async => values.remove(key);
}

class _MemoryQuotaCache implements QuotaCacheRepository {
  @override
  Future<List<Quota>> getAll(String connectionId) async => const [];
  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {}
  @override
  Future<void> deleteForConnection(String connectionId) async {}
}

Future<void> pumpScreen(
  WidgetTester tester, {
  required ConnectionRepository repo,
  required ProviderAdapter adapter,
}) async {
  final registry = ProviderRegistry(registerDefaults: false)..register(adapter);
  await tester.pumpWidget(
    MaterialApp(
      theme: TokenDockTheme.lightTheme(),
      home: ConnectionsScreen(
        connectionRepository: repo,
        quotaCacheRepository: _MemoryQuotaCache(),
        secretStore: _MemorySecrets(),
        providerRegistry: registry,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Every piece of text currently visible in the tree.
List<String> visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data)
    .whereType<String>()
    .toList();
