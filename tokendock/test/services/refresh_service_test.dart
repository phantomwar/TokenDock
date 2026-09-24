import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/services/credential_events.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/services/refreshable_credential.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';
import 'package:tokendock/models/test_result.dart';

import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/secret_store.dart';

import '../support/controlled_provider.dart';
import '../support/memory_secret_store.dart';

class _FakeConnectionRepository implements ConnectionRepository {
  _FakeConnectionRepository(List<Connection> initial)
    : _connections = List<Connection>.from(initial);

  final List<Connection> _connections;

  @override
  Future<List<Connection>> getAll() async => List.unmodifiable(_connections);

  @override
  Future<void> save(Connection connection) async {
    _connections.removeWhere((c) => c.id == connection.id);
    _connections.add(connection);
  }

  @override
  Future<void> delete(String id) async {
    _connections.removeWhere((c) => c.id == id);
  }
}

class _FakeQuotaCacheRepository implements QuotaCacheRepository {
  final Map<String, List<Quota>> _cache = {};

  @override
  Future<List<Quota>> getAll(String connectionId) async =>
      List.unmodifiable(_cache[connectionId] ?? const <Quota>[]);

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    _cache[connectionId] = List.unmodifiable(quotas);
  }

  @override
  Future<void> deleteForConnection(String connectionId) async {
    _cache.remove(connectionId);
  }
}

class _FailingQuotaCacheRepository implements QuotaCacheRepository {
  @override
  Future<List<Quota>> getAll(String connectionId) async => const [];

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    throw StateError('cache unavailable');
  }

  @override
  Future<void> deleteForConnection(String connectionId) async {}
}

class _FakeConnectionHealthRepository implements ConnectionHealthRepository {
  _FakeConnectionHealthRepository([Map<String, ConnectionHealth>? initial])
    : _records = Map<String, ConnectionHealth>.from(initial ?? const {});

  final Map<String, ConnectionHealth> _records;

  @override
  Future<ConnectionHealth?> get(String connectionId) async =>
      _records[connectionId];

  @override
  Future<void> save(ConnectionHealth health) async {
    _records[health.connectionId] = health;
  }
}

class _FailingConnectionHealthRepository implements ConnectionHealthRepository {
  @override
  Future<ConnectionHealth?> get(String connectionId) async => null;

  @override
  Future<void> save(ConnectionHealth health) async {
    throw StateError('database unavailable');
  }
}

class _ThrowingSecretStore implements SecretStore {
  @override
  Future<void> delete(String key) async {}

  @override
  Future<String?> read(String key) async {
    throw StateError('platform vault unavailable');
  }

  @override
  Future<void> write(String key, String value) async {}
}

class _RefreshableAntigravityProvider implements ProviderAdapter {
  _RefreshableAntigravityProvider({
    this.expiresAt,
    this.unauthorizedFirst = false,
    this.refreshError,
    this.snapshotError,
    this.failureCause,
  });

  final DateTime? expiresAt;
  final bool unauthorizedFirst;
  final Object? refreshError;
  String? snapshotError;
  ProviderFailureCause? failureCause;
  DateTime? cooldownUntil;
  int fetchCalls = 0;
  int refreshCalls = 0;
  final fetchedSecrets = <String>[];
  Future<void> Function()? beforeRefresh;
  Future<ProviderSnapshot> Function(Connection connection, String secret)?
  onFetch;

  @override
  String get id => 'antigravity';

  @override
  String get name => 'Fake Antigravity';

  @override
  AuthKind get authKind => AuthKind.oauth;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };

  @override
  RefreshableCredential refreshableCredential(String secret) =>
      _RefreshableCredential(this);

  @override
  Future<TestResult> test(Connection connection, String secret) async =>
      TestResult.success();

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    fetchCalls++;
    fetchedSecrets.add(secret);
    if (onFetch != null) return onFetch!(connection, secret);
    if (unauthorizedFirst && fetchCalls == 1) {
      return ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.authError,
        quotas: const [],
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: '401',
        failureCause: ProviderFailureCause.invalidCredential,
      );
    }
    if (snapshotError != null) {
      return ProviderSnapshot(
        connectionId: connection.id,
        status: failureCause == ProviderFailureCause.transient
            ? ConnectionStatus.warning
            : ConnectionStatus.error,
        quotas: const [],
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: snapshotError,
        cooldownUntil: cooldownUntil,
        failureCause: failureCause,
      );
    }
    return ProviderSnapshot(
      connectionId: connection.id,
      status: ConnectionStatus.ok,
      quotas: const [],
      balance: null,
      fetchedAt: DateTime.now().toUtc(),
      error: null,
    );
  }
}

class _RefreshableCredential implements RefreshableCredential {
  _RefreshableCredential(this.provider);

  final _RefreshableAntigravityProvider provider;

  @override
  DateTime? get expiresAt => provider.expiresAt;

  @override
  Duration get refreshLead => const Duration(minutes: 1);

  @override
  Future<String> refresh(String currentSecret) async {
    provider.refreshCalls++;
    if (provider.beforeRefresh != null) await provider.beforeRefresh!();
    if (provider.refreshError != null) throw provider.refreshError!;
    return 'rotated-${provider.refreshCalls}';
  }
}

class _TestOverlapProvider extends _RefreshableAntigravityProvider {
  _TestOverlapProvider({required super.expiresAt});

  final Completer<void> testGate = Completer<void>();

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    final credential = refreshableCredential(secret);
    var testedSecret = secret;
    final expiresAt = credential.expiresAt;
    if (secret == 'old-secret' &&
        expiresAt != null &&
        expiresAt.isBefore(
          DateTime.now().toUtc().add(credential.refreshLead),
        )) {
      testedSecret = await credential.refresh(secret);
    }
    await testGate.future;
    return TestResult.success(
      replacementSecret: testedSecret == secret ? null : testedSecret,
    );
  }
}

class _CleanupFailingSecretStore implements SecretStore {
  _CleanupFailingSecretStore(Map<String, String> initial)
    : values = Map<String, String>.from(initial);

  final Map<String, String> values;
  final deleteAttempts = <String>[];

  @override
  Future<void> delete(String key) async {
    deleteAttempts.add(key);
    throw StateError('vault busy');
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  Connection createConnection({
    required String id,
    String provider = 'openrouter',
    bool enabled = true,
    String? providerData,
    String? identityKey,
    String? credentialRef,
  }) {
    return Connection(
      id: id,
      provider: provider,
      displayName: 'Connection $id',
      group: null,
      plan: null,
      credentialRef: credentialRef ?? 'cred-$id',
      enabled: enabled,
      identityKey: identityKey,
      providerData: providerData,
    );
  }

  group('RefreshService', () {
    test('request coalescing: multiple simultaneous calls to refreshOne("a") trigger only 1 provider fetch call', () async {
      final controlled = ControlledProvider();
      final gate = Completer<void>();
      controlled.gate = gate;

      final connRepo = _FakeConnectionRepository([
        createConnection(id: 'conn-a'),
      ]);
      final quotaCacheRepo = _FakeQuotaCacheRepository();
      final secretStore = MemorySecretStore({'cred-conn-a': 'sk-test-secret'});

      final service = RefreshService.forTest(
        provider: controlled,
        connectionRepository: connRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
      );

      // Issue three simultaneous calls to refreshOne('conn-a')
      final f1 = service.refreshOne('conn-a');
      final f2 = service.refreshOne('conn-a');
      final f3 = service.refreshOne('conn-a');

      // Unblock in-flight fetch
      gate.complete();

      await Future.wait([f1, f2, f3]);

      // Exactly 1 provider fetch was executed across all 3 callers
      expect(controlled.fetchCalls, equals(1));

      // After in-flight completes, a subsequent call triggers a new fetch
      await service.refreshOne('conn-a');
      expect(controlled.fetchCalls, equals(2));

      service.dispose();
    });

    test(
      'local Antigravity source refreshes without a stored credential',
      () async {
        final provider = ControlledProvider(id: 'antigravity');
        final service = RefreshService.forTest(
          provider: provider,
          connectionRepository: _FakeConnectionRepository([
            createConnection(
              id: 'conn-local',
              provider: 'antigravity',
              providerData: '{"source":"language-server","port":1234}',
            ),
          ]),
          secretStore: MemorySecretStore(),
        );

        await service.refreshOne('conn-local');

        expect(provider.fetchCalls, 1);
        service.dispose();
      },
    );

    test(
      'token operations are single-flight and return the token value',
      () async {
        final service = RefreshService.forTest(provider: ControlledProvider());
        final gate = Completer<void>();
        var calls = 0;

        Future<String> run(String connectionId) {
          return service.runTokenOperation(
            connectionId: connectionId,
            operation: () async {
              calls++;
              await gate.future;
              return 'secret-$connectionId';
            },
          );
        }

        final first = run('conn-a');
        final duplicate = run('conn-a');
        final otherConnection = run('conn-b');
        gate.complete();

        Future<String> typedResult = first;
        expect(await Future.wait([typedResult, duplicate, otherConnection]), [
          'secret-conn-a',
          'secret-conn-a',
          'secret-conn-b',
        ]);
        expect(calls, 2);

        service.dispose();
      },
    );
    test(
      'runConnectionOperation queues same-id operations deterministically',
      () async {
        final service = RefreshService.forTest(provider: ControlledProvider());
        final gate = Completer<void>();
        final events = <String>[];
        final first = service.runConnectionOperation<void>(
          connectionId: 'shared-id',
          operation: () async {
            events.add('first-start');
            await gate.future;
            events.add('first-end');
          },
        );
        final second = service.runConnectionOperation<void>(
          connectionId: 'shared-id',
          operation: () async {
            events.add('second');
          },
        );
        expect(events, ['first-start']);
        gate.complete();
        await Future.wait([first, second]);
        expect(events, ['first-start', 'first-end', 'second']);
        service.dispose();
      },
    );

    test(
      'refreshOne and test-time OAuth refresh share one connection operation',
      () async {
        final provider = _TestOverlapProvider(
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 2),
          ),
        );
        provider.beforeRefresh = () => provider.testGate.future;
        final connection = createConnection(
          id: 'conn-a',
          provider: 'antigravity',
        );
        final connections = _FakeConnectionRepository([connection]);
        final service = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          secretStore: MemorySecretStore({'cred-conn-a': 'old-secret'}),
        );

        final refresh = service.refreshOne('conn-a');
        await Future<void>.delayed(Duration.zero);
        final test = service.testAdapter(
          adapter: provider,
          connection: connection,
          secret: 'old-secret',
          preferStoredSecret: true,
        );
        await Future<void>.delayed(Duration.zero);
        expect(provider.refreshCalls, 1);
        provider.testGate.complete();
        await refresh;

        expect((await test).isSuccess, isTrue);
        expect(provider.refreshCalls, 1);
        expect(provider.fetchCalls, 1);
        service.dispose();
      },
    );

    test(
      'runTokenOperation fails after dispose without starting work',
      () async {
        final service = RefreshService.forTest(provider: ControlledProvider());
        var calls = 0;
        service.dispose();

        await expectLater(
          service.runTokenOperation(
            connectionId: 'conn-a',
            operation: () async {
              calls++;
              return 'new-secret';
            },
          ),
          throwsA(isA<StateError>()),
        );
        expect(calls, 0);
      },
    );

    test('concurrency cap: refreshAll() with multiple accounts executes at most 4 simultaneous provider requests', () async {
      final controlled = ControlledProvider();
      // Introduce an asynchronous delay to ensure concurrent overlap
      controlled.onFetch = (conn, secret) async {
        await Future<void>.delayed(const Duration(milliseconds: 25));
        return ProviderSnapshot(
          connectionId: conn.id,
          status: ConnectionStatus.ok,
          quotas: const [],
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: null,
        );
      };

      const totalConnections = 10;
      final connections = <Connection>[];
      final secretMap = <String, String>{};

      for (int i = 1; i <= totalConnections; i++) {
        final id = 'conn-$i';
        connections.add(createConnection(id: id));
        secretMap['cred-$id'] = 'sk-secret-$i';
      }

      final connRepo = _FakeConnectionRepository(connections);
      final quotaCacheRepo = _FakeQuotaCacheRepository();
      final secretStore = MemorySecretStore(secretMap);

      final service = RefreshService.forTest(
        provider: controlled,
        connectionRepository: connRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
        maximumConcurrent: 4,
      );

      await service.refreshAll();

      // All 10 connections were fetched
      expect(controlled.fetchCalls, equals(totalConnections));
      // Max simultaneous requests never exceeded 4
      expect(controlled.maxConcurrentFetches, lessThanOrEqualTo(4));
      // Concurrency was indeed exercised (> 1 simultaneous)
      expect(controlled.maxConcurrentFetches, greaterThan(1));

      service.dispose();
    });
    test(
      'cooldown suppresses only its connection and clears after success',
      () async {
        final controlled = ControlledProvider();
        final connRepo = _FakeConnectionRepository([
          createConnection(id: 'conn-a'),
          createConnection(id: 'conn-b'),
        ]);
        final quotaCacheRepo = _FakeQuotaCacheRepository();
        const cachedQuota = Quota(
          id: 'cached',
          label: 'Cached',
          percent: 25.0,
          remaining: 75.0,
          limit: 100.0,
          unit: 'requests',
          resetAt: null,
        );
        await quotaCacheRepo.saveAll('conn-a', [cachedQuota]);
        final now = DateTime.now().toUtc();
        final healthRepo = _FakeConnectionHealthRepository({
          'conn-a': ConnectionHealth(
            connectionId: 'conn-a',
            status: ConnectionStatus.warning,
            lastCheckedAt: now,
            cooldownUntil: now.add(const Duration(minutes: 2)),
            error: 'Rate limited',
          ),
        });
        final publishedSnapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: controlled,
          connectionRepository: connRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: MemorySecretStore({
            'cred-conn-a': 'sk-a',
            'cred-conn-b': 'sk-b',
          }),
          connectionHealthRepository: healthRepo,
          onSnapshotUpdated: publishedSnapshots.add,
        );

        await service.refreshOne('conn-a');

        expect(controlled.fetchCalls, 0);
        expect(publishedSnapshots.last.status, ConnectionStatus.warning);
        expect(publishedSnapshots.last.quotas, [cachedQuota]);
        expect(
          publishedSnapshots.last.cooldownUntil,
          healthRepo._records['conn-a']!.cooldownUntil,
        );

        await service.refreshOne('conn-b');
        expect(controlled.fetchCalls, 1);

        await healthRepo.save(
          ConnectionHealth(
            connectionId: 'conn-a',
            status: ConnectionStatus.warning,
            lastCheckedAt: now,
            cooldownUntil: now.subtract(const Duration(seconds: 1)),
            error: 'Rate limited',
          ),
        );
        await service.refreshOne('conn-a');

        expect(controlled.fetchCalls, 2);
        final restoredHealth = await healthRepo.get('conn-a');
        expect(restoredHealth?.status, ConnectionStatus.ok);
        expect(restoredHealth?.cooldownUntil, isNull);
        expect(restoredHealth?.error, isNull);

        service.dispose();
      },
    );

    test(
      'thrown provider errors preserve cache and redact the credential',
      () async {
        const secret = 'sk-valid-key-999';
        final controlled = ControlledProvider()
          ..errorToThrow = Exception('Authorization: Bearer $secret');

        const connectionId = 'conn-fail';
        final connRepo = _FakeConnectionRepository([
          createConnection(id: connectionId),
        ]);
        final quotaCacheRepo = _FakeQuotaCacheRepository();
        final secretStore = MemorySecretStore({'cred-$connectionId': secret});
        const initialQuota = Quota(
          id: 'credits',
          label: 'Credits',
          percent: 75.0,
          remaining: 75.0,
          limit: 100.0,
          unit: 'USD',
          resetAt: null,
        );
        await quotaCacheRepo.saveAll(connectionId, [initialQuota]);

        final publishedSnapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: controlled,
          connectionRepository: connRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: secretStore,
          onSnapshotUpdated: publishedSnapshots.add,
        );

        await service.refreshOne(connectionId);

        final cachedAfterFailure = await quotaCacheRepo.getAll(connectionId);
        expect(cachedAfterFailure, [initialQuota]);
        final latest = publishedSnapshots.last;
        expect(latest.status, ConnectionStatus.error);
        expect(latest.quotas, [initialQuota]);
        expect(latest.error, contains('Authorization: Bearer [redacted]'));
        expect(latest.error, isNot(contains(secret)));

        service.dispose();
      },
    );

    test('provider error snapshots preserve prior quota cache', () async {
      final controlled = ControlledProvider()
        ..onFetch = (connection, secret) async => ProviderSnapshot(
          connectionId: connection.id,
          status: ConnectionStatus.warning,
          quotas: const [],
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: 'Rate limited',
        );
      const connectionId = 'conn-rate-limited';
      final connRepo = _FakeConnectionRepository([
        createConnection(id: connectionId),
      ]);
      final quotaCacheRepo = _FakeQuotaCacheRepository();
      final secretStore = MemorySecretStore({
        'cred-$connectionId': 'sk-valid-key',
      });
      const cachedQuota = Quota(
        id: 'usage',
        label: 'Usage',
        percent: 40.0,
        remaining: 60.0,
        limit: 100.0,
        unit: 'requests',
        resetAt: null,
      );
      await quotaCacheRepo.saveAll(connectionId, [cachedQuota]);
      final publishedSnapshots = <ProviderSnapshot>[];
      final service = RefreshService.forTest(
        provider: controlled,
        connectionRepository: connRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
        onSnapshotUpdated: publishedSnapshots.add,
      );

      await service.refreshOne(connectionId);

      expect(await quotaCacheRepo.getAll(connectionId), [cachedQuota]);
      expect(publishedSnapshots.last.status, ConnectionStatus.warning);
      expect(publishedSnapshots.last.quotas, [cachedQuota]);
      expect(publishedSnapshots.last.error, 'Rate limited');

      service.dispose();
    });

    test(
      'secret store read failures preserve cache and publish an error',
      () async {
        const connectionId = 'conn-secret-store-error';
        final controlled = ControlledProvider();
        final quotaCacheRepo = _FakeQuotaCacheRepository();
        final healthRepo = _FakeConnectionHealthRepository();
        final connection = createConnection(id: connectionId);
        const cachedQuota = Quota(
          id: 'usage',
          label: 'Usage',
          percent: 40,
          remaining: 60,
          limit: 100,
          unit: 'requests',
          resetAt: null,
        );
        await quotaCacheRepo.saveAll(connectionId, [cachedQuota]);
        final publishedSnapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: controlled,
          connectionRepository: _FakeConnectionRepository([connection]),
          connectionHealthRepository: healthRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: _ThrowingSecretStore(),
          onSnapshotUpdated: publishedSnapshots.add,
        );

        await service.refreshOne(connectionId);

        expect(controlled.fetchCalls, 0);
        expect(await quotaCacheRepo.getAll(connectionId), [cachedQuota]);
        expect(publishedSnapshots.last.status, ConnectionStatus.error);
        expect(publishedSnapshots.last.quotas, [cachedQuota]);
        expect(publishedSnapshots.last.error, 'Credential storage unavailable');
        expect(
          (await healthRepo.get(connectionId))?.status,
          ConnectionStatus.error,
        );

        service.dispose();
      },
    );

    test(
      'health persistence failure retains the Retry-After cooldown',
      () async {
        const connectionId = 'conn-health-write-error';
        final retryAt = DateTime.now().toUtc().add(const Duration(minutes: 5));
        final controlled = ControlledProvider()
          ..onFetch = (connection, secret) async => ProviderSnapshot(
            connectionId: connection.id,
            status: ConnectionStatus.warning,
            quotas: const [],
            balance: null,
            fetchedAt: DateTime.now().toUtc(),
            error: 'Rate limited',
            cooldownUntil: retryAt,
          );
        final quotaCacheRepo = _FakeQuotaCacheRepository();
        const cachedQuota = Quota(
          id: 'usage',
          label: 'Usage',
          percent: 40,
          remaining: 60,
          limit: 100,
          unit: 'requests',
          resetAt: null,
        );
        await quotaCacheRepo.saveAll(connectionId, [cachedQuota]);
        final publishedSnapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: controlled,
          connectionRepository: _FakeConnectionRepository([
            createConnection(id: connectionId),
          ]),
          connectionHealthRepository: _FailingConnectionHealthRepository(),
          quotaCacheRepository: quotaCacheRepo,
          secretStore: MemorySecretStore({'cred-$connectionId': 'sk-key'}),
          onSnapshotUpdated: publishedSnapshots.add,
        );

        await service.refreshOne(connectionId);

        expect(publishedSnapshots.last.cooldownUntil, retryAt);
        expect(publishedSnapshots.last.quotas, [cachedQuota]);
        expect(publishedSnapshots.last.status, ConnectionStatus.error);

        await service.refreshOne(connectionId);

        expect(controlled.fetchCalls, 1);
        expect(publishedSnapshots.last.cooldownUntil, retryAt);
        expect(publishedSnapshots.last.quotas, [cachedQuota]);
        service.dispose();
      },
    );

    test(
      'proactive Antigravity rotation swaps credential before fetch',
      () async {
        final provider = _RefreshableAntigravityProvider(
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 2),
          ),
        );
        final connections = _FakeConnectionRepository([
          createConnection(id: 'conn-proactive', provider: 'antigravity'),
        ]);
        final store = MemorySecretStore({'cred-conn-proactive': 'old-secret'});
        final snapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          secretStore: store,
          onSnapshotUpdated: snapshots.add,
        );

        await service.refreshOne('conn-proactive');

        expect(provider.refreshCalls, 1);
        expect(provider.fetchCalls, 1);
        expect(provider.fetchedSecrets.single, 'rotated-1');
        final current = (await connections.getAll()).single;
        expect(current.credentialRef, isNot('cred-conn-proactive'));
        expect(await store.read(current.credentialRef), 'rotated-1');
        expect(await store.read('cred-conn-proactive'), isNull);
        expect(snapshots.last.connection?.credentialRef, current.credentialRef);

        provider.onFetch = (connection, secret) async {
          throw StateError('fetch failed old rotated-1 $secret');
        };
        await service.refreshOne('conn-proactive');
        expect(snapshots.last.error, isNot(contains('old-secret')));
        expect(snapshots.last.error, isNot(contains('rotated-1')));
        expect(snapshots.last.error, isNot(contains('rotated-2')));
        service.dispose();
      },
    );

    test(
      'cache failure after rotation publishes the rotated connection',
      () async {
        final provider = _RefreshableAntigravityProvider(
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 2),
          ),
        );
        final connections = _FakeConnectionRepository([
          createConnection(id: 'conn-cache-rotation', provider: 'antigravity'),
        ]);
        final snapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          quotaCacheRepository: _FailingQuotaCacheRepository(),
          secretStore: MemorySecretStore({
            'cred-conn-cache-rotation': 'old-secret',
          }),
          onSnapshotUpdated: snapshots.add,
        );

        await service.refreshOne('conn-cache-rotation');

        final current = (await connections.getAll()).single;
        expect(snapshots.last.status, ConnectionStatus.error);
        expect(snapshots.last.connection?.credentialRef, current.credentialRef);
        service.dispose();
      },
    );

    test(
      'health failure after rotation publishes the rotated connection',
      () async {
        final provider = _RefreshableAntigravityProvider(
          expiresAt: DateTime.now().toUtc().subtract(
            const Duration(minutes: 2),
          ),
        );
        final connections = _FakeConnectionRepository([
          createConnection(id: 'conn-health-rotation', provider: 'antigravity'),
        ]);
        final snapshots = <ProviderSnapshot>[];
        final service = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          connectionHealthRepository: _FailingConnectionHealthRepository(),
          secretStore: MemorySecretStore({
            'cred-conn-health-rotation': 'old-secret',
          }),
          onSnapshotUpdated: snapshots.add,
        );

        await service.refreshOne('conn-health-rotation');

        final current = (await connections.getAll()).single;
        expect(snapshots.last.status, ConnectionStatus.error);
        expect(snapshots.last.connection?.credentialRef, current.credentialRef);
        service.dispose();
      },
    );

    test('reactive 401 performs one refresh and retries once', () async {
      final provider = _RefreshableAntigravityProvider(unauthorizedFirst: true);
      final connections = _FakeConnectionRepository([
        createConnection(id: 'conn-reactive', provider: 'antigravity'),
      ]);
      final snapshots = <ProviderSnapshot>[];
      final service = RefreshService.forTest(
        provider: provider,
        connectionRepository: connections,
        secretStore: MemorySecretStore({'cred-conn-reactive': 'old-secret'}),
        onSnapshotUpdated: snapshots.add,
      );

      await service.refreshOne('conn-reactive');

      expect(provider.refreshCalls, 1);
      expect(provider.fetchCalls, 2);
      expect(provider.fetchedSecrets, ['old-secret', 'rotated-1']);
      expect(snapshots.last.status, ConnectionStatus.ok);
      service.dispose();
    });

    test('invalid_grant emits a tombstone event and does not fetch', () async {
      final provider = _RefreshableAntigravityProvider(
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
        refreshError: StateError('invalid_grant'),
      );
      final events = <CredentialDisabledEvent>[];
      final snapshots = <ProviderSnapshot>[];
      final service = RefreshService.forTest(
        provider: provider,
        connectionRepository: _FakeConnectionRepository([
          createConnection(id: 'conn-invalid', provider: 'antigravity'),
        ]),
        secretStore: MemorySecretStore({'cred-conn-invalid': 'revoked-secret'}),
        onSnapshotUpdated: snapshots.add,
      )..addDisabledListener(events.add);

      await service.refreshOne('conn-invalid');

      expect(provider.refreshCalls, 1);
      expect(provider.fetchCalls, 0);
      expect(events.single.cause, 'invalid_grant');
      expect(snapshots.last.status, ConnectionStatus.authError);
      expect(snapshots.last.error, 'invalid_grant');
      service.dispose();
    });

    test('invalid_grant deletes the reusable local pair', () async {
      final provider = _RefreshableAntigravityProvider(
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
        refreshError: StateError('invalid_grant'),
      );
      final store = MemorySecretStore({'cred-conn-reuse': 'reusable-secret'});
      final service = RefreshService.forTest(
        provider: provider,
        connectionRepository: _FakeConnectionRepository([
          createConnection(id: 'conn-reuse', provider: 'antigravity'),
        ]),
        secretStore: store,
      );

      await service.refreshOne('conn-reuse');

      expect(await store.read('cred-conn-reuse'), isNull);
      service.dispose();
    });

    test(
      'typed provider failures retain status and only 401 disables credentials',
      () async {
        final cases = <ProviderFailureCause, ConnectionStatus>{
          ProviderFailureCause.onboardingRequired: ConnectionStatus.error,
          ProviderFailureCause.accountMismatch: ConnectionStatus.error,
          ProviderFailureCause.quotaSourceChanged: ConnectionStatus.error,
          ProviderFailureCause.forbidden: ConnectionStatus.error,
          ProviderFailureCause.transport: ConnectionStatus.error,
          ProviderFailureCause.transient: ConnectionStatus.warning,
        };

        for (final entry in cases.entries) {
          final provider = _RefreshableAntigravityProvider(
            snapshotError: entry.key.name,
            failureCause: entry.key,
          );
          final events = <CredentialDisabledEvent>[];
          final snapshots = <ProviderSnapshot>[];
          final connectionId = 'typed-${entry.key.name}';
          final connections = _FakeConnectionRepository([
            createConnection(id: connectionId, provider: 'antigravity'),
          ]);
          final service = RefreshService.forTest(
            provider: provider,
            connectionRepository: connections,
            secretStore: MemorySecretStore({'cred-$connectionId': 'secret'}),
            onSnapshotUpdated: snapshots.add,
          )..addDisabledListener(events.add);

          await service.refreshOne(connectionId);

          expect(snapshots.last.status, entry.value, reason: entry.key.name);
          expect(events, isEmpty, reason: entry.key.name);
          if (entry.key == ProviderFailureCause.quotaSourceChanged) {
            final persisted = (await connections.getAll()).single;
            expect(persisted.enabled, isTrue);
            expect(provider.fetchCalls, 1);
          }
          service.dispose();
        }
      },
    );

    test(
      'quota schema quarantine survives service recreation without refetching',
      () async {
        final provider = _RefreshableAntigravityProvider(
          snapshotError: 'quota_source_changed',
          failureCause: ProviderFailureCause.quotaSourceChanged,
        );
        final connections = _FakeConnectionRepository([
          createConnection(id: 'conn-recreate', provider: 'antigravity'),
        ]);
        final first = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          secretStore: MemorySecretStore({'cred-conn-recreate': 'secret'}),
        );
        await first.refreshOne('conn-recreate');
        first.dispose();
        final second = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          secretStore: MemorySecretStore({'cred-conn-recreate': 'secret'}),
        );

        await second.refreshOne('conn-recreate');

        expect(provider.fetchCalls, 1);
        expect((await connections.getAll()).single.enabled, isTrue);

        provider.snapshotError = null;
        final result = await second.testAdapter(
          adapter: provider,
          connection: (await connections.getAll()).single,
          secret: 'secret',
          preferStoredSecret: true,
        );

        expect(result.isSuccess, isTrue);
        expect(result.schemaRevalidated, isTrue);
        expect((await connections.getAll()).single.enabled, isTrue);
        await second.refreshOne('conn-recreate');
        expect(provider.fetchCalls, 1);
        second.dispose();
      },
    );

    test(
      'reactive rotation deletes the current ref and leaves no orphan',
      () async {
        final provider = _RefreshableAntigravityProvider(
          unauthorizedFirst: true,
          snapshotError: null,
        );
        final connections = _FakeConnectionRepository([
          createConnection(id: 'conn-current-ref', provider: 'antigravity'),
        ]);
        final store = MemorySecretStore({
          'cred-conn-current-ref': 'old-secret',
        });
        final service = RefreshService.forTest(
          provider: provider,
          connectionRepository: connections,
          secretStore: store,
        );

        await service.refreshOne('conn-current-ref');

        final current = (await connections.getAll()).single;
        expect(current.credentialRef, isNot('cred-conn-current-ref'));
        expect(await store.read('cred-conn-current-ref'), isNull);
        expect(await store.read(current.credentialRef), 'rotated-1');
        service.dispose();
      },
    );

    test('repeated rotations retry every orphan ref and dispose stops later retries', () async {
      final provider = _RefreshableAntigravityProvider(
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 2)),
      );
      final connections = _FakeConnectionRepository([
        createConnection(id: 'conn-cleanup', provider: 'antigravity'),
      ]);
      final store = _CleanupFailingSecretStore({'cred-conn-cleanup': 'old-1'});
      final service = RefreshService.forTest(
        provider: provider,
        connectionRepository: connections,
        secretStore: store,
        secretCleanupInterval: const Duration(milliseconds: 100),
      );

      await service.refreshOne('conn-cleanup');
      final firstOrphanRef = (await connections.getAll()).single.credentialRef;
      await service.refreshOne('conn-cleanup');
      final orphanRefs = <String>{'cred-conn-cleanup', firstOrphanRef};
      expect(orphanRefs, hasLength(2));

      await Future<void>.delayed(const Duration(milliseconds: 110));
      final firstCleanupPass = store.deleteAttempts
          .take(orphanRefs.length)
          .toSet();
      expect(firstCleanupPass, hasLength(2));
      expect(firstCleanupPass, containsAll(orphanRefs));

      await Future<void>.delayed(const Duration(milliseconds: 110));
      for (final ref in orphanRefs) {
        expect(
          store.deleteAttempts.where((attempt) => attempt == ref).length,
          greaterThanOrEqualTo(2),
        );
      }
      expect(service.credentialCleanupWarnings, hasLength(2));
      expect(store.values, hasLength(3));

      service.dispose();
      final attemptsAtDispose = store.deleteAttempts.length;
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(store.deleteAttempts.length, attemptsAtDispose);
    });

    test('supported intervals drive the timer and manual cancels it', () {
      final service = RefreshService.forTest(provider: ControlledProvider());

      for (final minutes in const [1, 3, 5, 10]) {
        service.updateIntervalMinutes(minutes);
        expect(service.isTimerActive, isTrue, reason: '$minutes minutes');
      }
      service.updateIntervalMinutes(0);
      expect(service.isTimerActive, isFalse);
      expect(() => service.updateIntervalMinutes(2), throwsArgumentError);

      service.dispose();
    });

    test('periodic timer: timer fires and invokes refreshAll(), timer cancels on dispose', () async {
      final controlled = ControlledProvider();
      final connRepo = _FakeConnectionRepository([
        createConnection(id: 'conn-timer'),
      ]);
      final quotaCacheRepo = _FakeQuotaCacheRepository();
      final secretStore = MemorySecretStore({
        'cred-conn-timer': 'sk-timer-key',
      });

      final service = RefreshService.forTest(
        provider: controlled,
        connectionRepository: connRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
        timerInterval: const Duration(milliseconds: 50),
        autoStartTimer: true,
      );

      expect(service.isTimerActive, isTrue);
      expect(controlled.fetchCalls, equals(0));

      // Wait for timer to fire at least once
      await Future<void>.delayed(const Duration(milliseconds: 130));
      expect(controlled.fetchCalls, greaterThanOrEqualTo(1));

      // Dispose should cancel timer and prevent further calls
      service.dispose();
      expect(service.isTimerActive, isFalse);

      final callsAtDispose = controlled.fetchCalls;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(controlled.fetchCalls, equals(callsAtDispose));
    });
  });
}
