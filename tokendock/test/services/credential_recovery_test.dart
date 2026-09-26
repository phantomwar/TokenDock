import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/models/test_result.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';
import 'package:tokendock/services/credential_events.dart';
import 'package:tokendock/services/refreshable_credential.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/connection_repository.dart';

import '../support/memory_secret_store.dart';

/// A Reconnect prompt must not outlive the failure that raised it.
///
/// `RefreshService` raises a `CredentialDisabledEvent` on a definitive
/// credential failure, and `AppState` turns that into a "Reconnect" action on
/// the card. Before this suite that flag was cleared only by explicit user
/// actions -- edit, reconnect, delete -- and **never by a successful refresh**.
/// So one transient 401 (a proxy blip, a provider hiccup, clock skew) left a
/// working key nagging for the rest of the session, while the app refreshed that
/// same key successfully behind the prompt.
///
/// oh-my-pi does the same self-heal deliberately, in
/// `CredentialBlocks.reconcile`: "when a fresh live usage report says a scope is
/// below every limit gating it, drop its persisted and in-memory blocks so
/// credential selection re-includes the recovered account before the block
/// expires by clock."
class _SequenceProvider implements ProviderAdapter {
  _SequenceProvider(this.responses);

  /// Consumed in order; the last entry repeats once exhausted, so a test that
  /// refreshes repeatedly does not run off the end.
  final List<ProviderSnapshot> responses;
  int calls = 0;

  @override
  String get id => 'sequence';

  @override
  String get name => 'Sequence';

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
      TestResult.success();

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final response = responses[calls < responses.length ? calls : -1];
    calls++;
    return response;
  }
}

class _MapHealthRepository implements ConnectionHealthRepository {
  final Map<String, ConnectionHealth> _rows = {};

  @override
  Future<ConnectionHealth?> get(String connectionId) async =>
      _rows[connectionId];

  @override
  Future<void> save(ConnectionHealth health) async {
    _rows[health.connectionId] = health;
  }
}

class _OneConnectionRepository implements ConnectionRepository {
  _OneConnectionRepository(this._connection);

  final Connection _connection;

  @override
  Future<List<Connection>> getAll() async => <Connection>[_connection];

  @override
  Future<List<StoredConnection>> getAllWithHealth() async =>
      <StoredConnection>[];

  @override
  Future<Connection?> getById(String id) async =>
      id == _connection.id ? _connection : null;

  @override
  Future<void> save(Connection connection) async {}

  @override
  Future<void> delete(String id) async {}
}

Connection _connection() => const Connection(
  id: 'conn',
  provider: 'sequence',
  displayName: 'Sequence',
  group: null,
  plan: null,
  credentialRef: 'cred-conn',
  enabled: true,
);

ProviderSnapshot _unauthorized() => ProviderSnapshot(
  connectionId: 'conn',
  status: ConnectionStatus.authError,
  quotas: const <Quota>[],
  balance: null,
  fetchedAt: DateTime.now().toUtc(),
  error: 'Invalid API key',
  failureCause: ProviderFailureCause.invalidCredential,
);

ProviderSnapshot _healthy() => ProviderSnapshot(
  connectionId: 'conn',
  status: ConnectionStatus.ok,
  quotas: const <Quota>[],
  balance: null,
  fetchedAt: DateTime.now().toUtc(),
  error: null,
);

ProviderSnapshot _throttled() => ProviderSnapshot(
  connectionId: 'conn',
  status: ConnectionStatus.warning,
  quotas: const <Quota>[],
  balance: null,
  fetchedAt: DateTime.now().toUtc(),
  error: 'Rate limited',
);

void main() {
  ({RefreshService service, List<CredentialDisabledEvent> events}) build(
    List<ProviderSnapshot> responses, {
    List<ProviderSnapshot>? snapshots,
  }) {
    final provider = _SequenceProvider(responses);
    final events = <CredentialDisabledEvent>[];
    final service = RefreshService.forTest(
      provider: provider,
      providerRegistry: ProviderRegistry(registerDefaults: false)
        ..register(provider),
      connectionRepository: _OneConnectionRepository(_connection()),
      secretStore: MemorySecretStore(const {'cred-conn': 'sk-key'}),
      connectionHealthRepository: _MapHealthRepository(),
      onSnapshotUpdated: snapshots?.add,
      autoStartTimer: false,
    )..addDisabledListener(events.add);
    return (service: service, events: events);
  }

  group('a rejection still escalates immediately', () {
    // This is the contract the Antigravity reconnect flow depends on, and it is
    // unchanged: for an OAuth connection there is no "edit the key", so the
    // reconnection affordance has to appear on the first rejection. Delaying it
    // behind a second failure was tried and reverted -- see the note in
    // `_performRefreshOne`.
    test('a 401 raises the Reconnect prompt on the first response', () async {
      final harness = build([_unauthorized()]);

      await harness.service.refreshOne('conn');

      expect(harness.events, hasLength(1));
      expect(
        harness.events.single.cause,
        CredentialEventCause.bareUnauthorized,
      );
      harness.service.dispose();
    });

    test('and the card is still told the key was rejected', () async {
      final snapshots = <ProviderSnapshot>[];
      final harness = build([_unauthorized()], snapshots: snapshots);

      await harness.service.refreshOne('conn');

      expect(snapshots.last.status, ConnectionStatus.authError);
      harness.service.dispose();
    });
  });

  group('a later success takes the prompt back down', () {
    test('a recovery is reported so the prompt can be removed', () async {
      final harness = build([_unauthorized(), _healthy()]);

      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');

      expect(
        harness.events.map((e) => e.cause),
        <String>[
          CredentialEventCause.bareUnauthorized,
          CredentialEventCause.recovered,
        ],
      );
      harness.service.dispose();
    });

    test('recovery is reported once, not on every later success', () async {
      // A repeated event would rebuild the UI on every refresh cycle forever.
      final harness = build([_unauthorized(), _healthy(), _healthy(), _healthy()]);

      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');

      expect(
        harness.events.where(
          (e) => e.cause == CredentialEventCause.recovered,
        ),
        hasLength(1),
      );
      harness.service.dispose();
    });

    test('a success that never followed a rejection reports nothing', () async {
      // Otherwise every healthy connection would emit an event on every cycle.
      final harness = build([_healthy(), _healthy(), _healthy()]);

      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');

      expect(harness.events, isEmpty);
      harness.service.dispose();
    });

    test('the health row ends up describing a working credential', () async {
      final health = _MapHealthRepository();
      final provider = _SequenceProvider([_unauthorized(), _healthy()]);
      final service = RefreshService.forTest(
        provider: provider,
        providerRegistry: ProviderRegistry(registerDefaults: false)
          ..register(provider),
        connectionRepository: _OneConnectionRepository(_connection()),
        secretStore: MemorySecretStore(const {'cred-conn': 'sk-key'}),
        connectionHealthRepository: health,
        autoStartTimer: false,
      );

      await service.refreshOne('conn');
      expect((await health.get('conn'))?.status, ConnectionStatus.authError);

      await service.refreshOne('conn');
      expect((await health.get('conn'))?.status, ConnectionStatus.ok);
      service.dispose();
    });
  });

  group('a non-credential failure is not a credential failure', () {
    test('a rate limit never reports a recovery', () async {
      // Nothing was escalated, so nothing should be taken back down. Reporting
      // recovery for a connection that was never prompted would make the UI
      // churn for no reason.
      final harness = build([_throttled(), _throttled()]);

      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');

      expect(harness.events, isEmpty);
      harness.service.dispose();
    });

    test('a rate limit after a rejection does not count as recovery', () async {
      // The credential has not been shown to work -- it was throttled. Clearing
      // the prompt here would hide a key that is still rejected.
      final harness = build([_unauthorized(), _throttled()]);

      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');

      expect(
        harness.events.map((e) => e.cause),
        <String>[CredentialEventCause.bareUnauthorized],
      );
      harness.service.dispose();
    });
  });

  group('a classification token is never shown to the user', () {
    // `token_dock_widget` renders `snapshot.error` verbatim, and that error is
    // persisted as connection health. Before this, the internal token
    // `bare_401` was stored as the health error and printed on screen.
    test('the user-visible error is copy, not the token', () async {
      final snapshots = <ProviderSnapshot>[];
      final harness = build([_unauthorized()], snapshots: snapshots);

      await harness.service.refreshOne('conn');

      expect(snapshots.last.error, isNot(CredentialEventCause.bareUnauthorized));
      expect(snapshots.last.error, 'Invalid API key');
      harness.service.dispose();
    });

    test('no published error contains a classification token', () async {
      final snapshots = <ProviderSnapshot>[];
      final harness = build([_unauthorized(), _healthy(), _throttled()],
          snapshots: snapshots);

      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');
      await harness.service.refreshOne('conn');

      for (final token in <String>[
        CredentialEventCause.bareUnauthorized,
        CredentialEventCause.invalidGrant,
        CredentialEventCause.recovered,
      ]) {
        for (final snapshot in snapshots) {
          expect(
            snapshot.error ?? '',
            isNot(contains(token)),
            reason: 'token "$token" leaked into "${snapshot.error}"',
          );
        }
      }
      harness.service.dispose();
    });
  });
}
