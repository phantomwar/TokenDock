import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/storage/connection_repository.dart';

import '../support/memory_secret_store.dart';
import '../support/test_database.dart';

/// Cancellation of the Antigravity login must be a deterministic decision, not
/// a race against microtask timing (audit C-05).
///
/// The previous implementation polled a `cancellationRequested` flag
/// separated by `await Future<void>.value()` no-ops. A completed future yields
/// the microtask queue exactly once, while the cancel originates from a
/// macrotask (a button tap or widget disposal), so those checks only fired
/// when the cancel happened to already be scheduled. Several of them tested the
/// same flag with no intervening operation at all.
void main() {
  AppState stateWith(
    TestDatabase db,
    MemorySecretStore store, {
    ConnectionRepository? repo,
  }) {
    final state = AppState.test(
      connectionRepository: repo ?? db.connectionRepository,
      quotaCacheRepository: db.quotaCacheRepository,
      secretStore: store,
    );
    addTearDown(state.dispose);
    return state;
  }

  group('cancellation is observed deterministically', () {
    test('a cancel delivered while the login is still pending leaves no '
        'secret and no row', () async {
      final db = await TestDatabase.create();
      addTearDown(db.close);
      final store = MemorySecretStore();
      final state = stateWith(db, store);
      final gate = Completer<void>();
      final cancellation = Completer<void>();

      final operation = state.addAntigravityConnection(
        displayName: 'Cancelled early',
        provider: _GateProvider(gate),
        cancellation: cancellation.future,
      );

      cancellation.complete();
      gate.complete();

      await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
      expect(await db.connectionRepository.getAll(), isEmpty);
      expect(store.entries, isEmpty);
    });

    test('a cancel delivered as the login resolves still leaves nothing '
        'behind', () async {
      final db = await TestDatabase.create();
      addTearDown(db.close);
      final store = MemorySecretStore();
      final state = stateWith(db, store);

      // Fires synchronously inside the login, i.e. the tightest possible race
      // against the commit sequence. This must resolve the same way every run,
      // not only when the cancel is already scheduled.
      for (var attempt = 0; attempt < 25; attempt++) {
        final cancellation = Completer<void>();
        final operation = state.addAntigravityConnection(
          displayName: 'Tight race $attempt',
          provider: _CancelAfterLoginProvider(cancellation.complete),
          cancellation: cancellation.future,
        );

        await expectLater(
          operation,
          throwsA(isA<AntigravityLoginCancelled>()),
          reason: 'attempt $attempt must cancel, not commit',
        );
        expect(await db.connectionRepository.getAll(), isEmpty);
        expect(store.entries, isEmpty);
      }
    });

    test('an uncancelled login commits the row and the secret', () async {
      final db = await TestDatabase.create();
      addTearDown(db.close);
      final store = MemorySecretStore();
      final state = stateWith(db, store);
      final provider = _CancelAfterLoginProvider(() {});

      final created = await state.addAntigravityConnection(
        displayName: 'Committed',
        provider: provider,
      );

      final rows = await db.connectionRepository.getAll();
      expect(rows, hasLength(1));
      expect(rows.single.id, created.id);
      expect(store.entries.keys, contains(created.credentialRef));
    });
  });

  group('a failing rollback still reports the cancellation', () {
    test(
      'a repository that refuses to delete does not mask the cancel',
      () async {
        final db = await TestDatabase.create();
        addTearDown(db.close);
        final store = MemorySecretStore();
        final gate = Completer<void>();
        final cancellation = Completer<void>();

        final repo = _DeleteFailingRepository(db.connectionRepository);
        final state = stateWith(db, store, repo: repo);

        final operation = state.addAntigravityConnection(
          displayName: 'Undeletable',
          provider: _GateProvider(gate),
          cancellation: cancellation.future,
        );

        await Future<void>.delayed(Duration.zero);
        cancellation.complete();
        gate.complete();

        // The caller asked to cancel; a cleanup failure must not be reported
        // instead, or the UI shows a storage error for a cancelled login.
        await expectLater(operation, throwsA(isA<AntigravityLoginCancelled>()));
      },
    );
  });
}

const _result = AntigravityOAuthLoginResult(
  secret: 'oauth-secret',
  identityKey: 'user@example.com|acct-1',
  projectId: 'proj-1',
  tier: 'free',
);

/// Completes only once the test releases it, so cancellation can be delivered
/// at an exact point in the commit sequence.
class _GateProvider extends AntigravityOAuthProvider {
  _GateProvider(this.gate) : super(launchExternalBrowser: (_) async {});

  final Completer<void> gate;

  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) async {
    await gate.future;
    return _result;
  }
}

/// Lets cancellation land at the tightest possible moment: synchronously as the
/// login future resolves, before any commit step has been reached.
class _CancelAfterLoginProvider extends AntigravityOAuthProvider {
  _CancelAfterLoginProvider(this.afterLogin)
    : super(launchExternalBrowser: (_) async {});

  final void Function() afterLogin;

  @override
  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) async {
    afterLogin();
    return _result;
  }
}

/// Wraps a repository whose [delete] always fails, so the compensating delete
/// inside the cancellation path throws.
class _DeleteFailingRepository implements ConnectionRepository {
  _DeleteFailingRepository(this._inner);

  final ConnectionRepository _inner;

  @override
  Future<void> delete(String id) async => throw StateError('delete refused');

  @override
  Future<List<Connection>> getAll() => _inner.getAll();

  @override
  Future<Connection?> getById(String id) => _inner.getById(id);

  @override
  Future<void> save(Connection connection) => _inner.save(connection);
}
