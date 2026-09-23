import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_health.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/services/credential_events.dart';
import 'package:tokendock/services/refresh_service.dart';
import 'package:tokendock/storage/connection_health_repository.dart';
import 'package:tokendock/storage/connection_repository.dart';
import 'package:tokendock/storage/quota_cache_repository.dart';

import '../support/controlled_provider.dart';
import '../support/memory_secret_store.dart';

class _ConnectionRepository implements ConnectionRepository {
  _ConnectionRepository(this.connection);

  Connection connection;

  @override
  Future<void> delete(String id) async {}

  @override
  Future<List<Connection>> getAll() async => [connection];

  @override
  Future<void> save(Connection connection) async {
    this.connection = connection;
  }
}

class _QuotaCacheRepository implements QuotaCacheRepository {
  _QuotaCacheRepository(this.quotas);

  List<Quota> quotas;

  @override
  Future<void> deleteForConnection(String connectionId) async {
    throw StateError('A credential tombstone must not delete cached quotas');
  }

  @override
  Future<List<Quota>> getAll(String connectionId) async => quotas;

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    this.quotas = quotas;
  }
}

class _HealthRepository implements ConnectionHealthRepository {
  ConnectionHealth? health;

  @override
  Future<ConnectionHealth?> get(String connectionId) async => health;

  @override
  Future<void> save(ConnectionHealth health) async {
    this.health = health;
  }
}

void main() {
  test('disabled event carries only cause and identity, never token bytes', () {
    const event = CredentialDisabledEvent(
      connectionId: 'conn-oauth',
      cause: 'invalid_grant',
      identityKey: 'person@example.test|account-1',
    );

    expect(event.connectionId, 'conn-oauth');
    expect(event.cause, 'invalid_grant');
    expect(event.identityKey, 'person@example.test|account-1');
    expect(event.toString(), isNot(contains('refresh')));
  });

  test('definitive failure tombstones credential while preserving quota cache', () async {
    const connectionId = 'conn-oauth';
    const identityKey = 'person@example.test|account-1';
    const secret = 'refresh-token-must-never-leak';
    const cachedQuota = Quota(
      id: 'weekly',
      label: 'Weekly',
      percent: 42,
      remaining: 42,
      limit: 100,
      unit: '%',
      resetAt: null,
    );
    final provider = ControlledProvider(id: 'antigravity')
      ..errorToThrow = StateError('invalid_grant: $secret');
    final connections = _ConnectionRepository(
      Connection(
        id: connectionId,
        provider: 'antigravity',
        displayName: 'OAuth account',
        group: null,
        plan: null,
        credentialRef: 'credential-ref',
        enabled: true,
        authType: 'oauth',
        identityKey: identityKey,
      ),
    );
    final cache = _QuotaCacheRepository([cachedQuota]);
    final health = _HealthRepository();
    final events = <CredentialDisabledEvent>[];
    final service = RefreshService.forTest(
      provider: provider,
      connectionRepository: connections,
      quotaCacheRepository: cache,
      connectionHealthRepository: health,
      secretStore: MemorySecretStore({'credential-ref': secret}),
    );
    service.addDisabledListener(events.add);

    await service.refreshOne(connectionId);

    expect(cache.quotas, [cachedQuota]);
    expect(events, hasLength(1));
    expect(events.single.connectionId, connectionId);
    expect(events.single.cause, 'invalid_grant');
    expect(events.single.identityKey, identityKey);
    expect(events.single.toString(), isNot(contains(secret)));
    expect(health.health?.status, ConnectionStatus.authError);
    expect(health.health?.error, 'invalid_grant');
    expect(health.health?.error, isNot(contains(secret)));
    expect(connections.connection.enabled, isTrue);

    service.dispose();
  });

  test('bare 401 is definitive but unrelated failures are retryable', () {
    expect(isDefinitiveOAuthFailure(StateError('401')), isTrue);
    expect(isDefinitiveOAuthFailure(StateError('invalid_grant')), isTrue);
    expect(isDefinitiveOAuthFailure(StateError('503 unavailable')), isFalse);
  });
}
