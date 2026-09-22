import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/services/refresh_service.dart';

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
    test(
        'request coalescing: multiple simultaneous calls to refreshOne("a") trigger only 1 provider fetch call',
        () async {
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
        'concurrency cap: refreshAll() with multiple accounts executes at most 4 simultaneous provider requests',
        () async {
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
        'cache preservation on failure: when provider fetch fails, prior cached quotas are preserved and error status is published',
        () async {
      final controlled = ControlledProvider();
      controlled.errorToThrow = Exception('503 Service Unavailable');

      const connectionId = 'conn-fail';
      final connRepo = _FakeConnectionRepository([
        createConnection(id: connectionId),
      ]);
      final quotaCacheRepo = _FakeQuotaCacheRepository();
      final secretStore =
          MemorySecretStore({'cred-$connectionId': 'sk-valid-key'});

      final initialQuotas = <Quota>[
        const Quota(
          id: 'credits',
          label: 'Credits',
          percent: 75.0,
          remaining: 75.0,
          limit: 100.0,
          unit: 'USD',
          resetAt: null,
        ),
      ];
      await quotaCacheRepo.saveAll(connectionId, initialQuotas);

      final publishedSnapshots = <ProviderSnapshot>[];
      final service = RefreshService.forTest(
        provider: controlled,
        connectionRepository: connRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
        onSnapshotUpdated: (snapshot) {
          publishedSnapshots.add(snapshot);
        },
      );

      await service.refreshOne(connectionId);

      // Quotas in cache repository are preserved and NOT wiped
      final cachedAfterFailure = await quotaCacheRepo.getAll(connectionId);
      expect(cachedAfterFailure.length, equals(1));
      expect(cachedAfterFailure.first.id, equals('credits'));
      expect(cachedAfterFailure.first.remaining, equals(75.0));

      // Published snapshot has error status and preserved cached quotas
      expect(publishedSnapshots, isNotEmpty);
      final latest = publishedSnapshots.last;
      expect(latest.status, equals(ConnectionStatus.error));
      expect(latest.quotas.length, equals(1));
      expect(latest.quotas.first.id, equals('credits'));
      expect(latest.quotas.first.remaining, equals(75.0));
      expect(latest.error, contains('503 Service Unavailable'));

      service.dispose();
    });

    test(
        'periodic timer: timer fires and invokes refreshAll(), timer cancels on dispose',
        () async {
      final controlled = ControlledProvider();
      final connRepo = _FakeConnectionRepository([
        createConnection(id: 'conn-timer'),
      ]);
      final quotaCacheRepo = _FakeQuotaCacheRepository();
      final secretStore =
          MemorySecretStore({'cred-conn-timer': 'sk-timer-key'});

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
