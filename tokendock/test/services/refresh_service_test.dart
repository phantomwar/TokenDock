import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';

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

void main() {
  Connection createConnection({
    required String id,
    String provider = 'openrouter',
    bool enabled = true,
  }) {
    return Connection(
      id: id,
      provider: provider,
      displayName: 'Connection $id',
      group: null,
      plan: null,
      credentialRef: 'cred-$id',
      enabled: enabled,
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
