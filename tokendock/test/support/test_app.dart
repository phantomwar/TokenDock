import 'dart:async';

import 'package:flutter/material.dart';
import 'package:tokendock/app/app.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
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

import 'memory_secret_store.dart';

/// Fake implementation of [ProviderAdapter] for testing.
class FakeProviderAdapter implements ProviderAdapter {
  FakeProviderAdapter({
    this.id = 'openrouter',
    this.name = 'OpenRouter',
    required this.testResult,
    this.authKind = AuthKind.apiKey,
  });

  @override
  final String id;

  @override
  final String name;
  @override
  final AuthKind authKind;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };
  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  TestResult testResult;

  int testCount = 0;
  Connection? lastTestedConnection;
  String? lastTestedSecret;

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    testCount++;
    lastTestedConnection = connection;
    lastTestedSecret = secret;
    return testResult;
  }

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    return ProviderSnapshot(
      connectionId: connection.id,
      status: testResult.isSuccess
          ? ConnectionStatus.ok
          : ConnectionStatus.error,
      quotas: testResult.quotas,
      balance: null,
      fetchedAt: DateTime.now().toUtc(),
      error: testResult.error,
    );
  }
}

/// In-memory implementation of [ConnectionRepository] for testing.
class MemoryConnectionRepository implements ConnectionRepository {
  MemoryConnectionRepository([List<Connection>? initialConnections])
    : _storage = {
        for (final c in initialConnections ?? <Connection>[]) c.id: c,
      };

  final Map<String, Connection> _storage;

  @override
  Future<List<Connection>> getAll() async {
    return _storage.values.toList();
  }

  @override
  Future<Connection?> getById(String id) async => _storage[id];

  @override
  Future<List<StoredConnection>> getAllWithHealth() async => _storage.values
      .map((row) => StoredConnection(connection: row))
      .toList();

  @override
  Future<void> save(Connection connection) async {
    _storage[connection.id] = connection;
  }

  @override
  Future<void> delete(String id) async {
    _storage.remove(id);
  }

  void clear() {
    _storage.clear();
  }
}

/// In-memory implementation of [QuotaCacheRepository] for testing.
class MemoryQuotaCacheRepository implements QuotaCacheRepository {
  MemoryQuotaCacheRepository([Map<String, List<Quota>>? initialData])
    : _storage = initialData != null
          ? {
              for (final e in initialData.entries)
                e.key: List<Quota>.from(e.value),
            }
          : <String, List<Quota>>{};

  final Map<String, List<Quota>> _storage;

  @override
  Future<List<Quota>> getAll(String connectionId) async {
    return List<Quota>.unmodifiable(_storage[connectionId] ?? const <Quota>[]);
  }

  @override
  Future<Map<String, List<Quota>>> getAllForAll(
    List<String> connectionIds,
  ) async =>
      {
        for (final id in connectionIds)
          id: List<Quota>.unmodifiable(_storage[id] ?? const <Quota>[]),
      };

  @override
  Future<void> saveAll(String connectionId, List<Quota> quotas) async {
    _storage[connectionId] = List<Quota>.from(quotas);
  }

  @override
  Future<void> deleteForConnection(String connectionId) async {
    _storage.remove(connectionId);
  }

  void clear() {
    _storage.clear();
  }
}

/// Creates an in-memory [AppState] test double wired with memory repositories.
AppState createTestAppState({
  ConnectionRepository? connectionRepo,
  QuotaCacheRepository? quotaCacheRepo,
  SecretStore? secretStore,
  ProviderRegistry? registry,
  List<AccountItem> accounts = const [],
  bool isLoading = false,
}) {
  final repo = connectionRepo ?? MemoryConnectionRepository();
  final cache = quotaCacheRepo ?? MemoryQuotaCacheRepository();
  final store = secretStore ?? MemorySecretStore();
  final reg =
      registry ??
      (ProviderRegistry(registerDefaults: false)..register(
        FakeProviderAdapter(testResult: TestResult.success(quotas: const [])),
      ));
  return AppState(
    isLoading: isLoading,
    accounts: accounts,
    connectionRepository: repo,
    quotaCacheRepository: cache,
    secretStore: store,
    providerRegistry: reg,
    autoStartRefreshTimer: false,
  );
}

/// Test harness for [ConnectionsScreen].
class TestConnectionsScreen extends StatelessWidget {
  const TestConnectionsScreen({
    super.key,
    this.connectionRepo,
    this.appState,
    this.quotaCacheRepo,
    this.secretStore,
    this.adapter,
    this.registry,
    this.initialTestSuccess,
  });

  factory TestConnectionsScreen.withResult({
    Key? key,
    ConnectionRepository? connectionRepo,
    QuotaCacheRepository? quotaCacheRepo,
    SecretStore? secretStore,
    required bool success,
    String? error,
    List<Quota>? quotas,
    String? plan,
    String? replacementSecret,
  }) {
    final adapter = FakeProviderAdapter(
      testResult: success
          ? TestResult.success(
              plan: plan ?? 'Pro',
              quotas: quotas ?? const [],
              replacementSecret: replacementSecret,
            )
          : TestResult.failure(error: error ?? 'Invalid API key'),
    );
    final registry = ProviderRegistry(registerDefaults: false);
    registry.register(adapter);

    return TestConnectionsScreen(
      key: key,
      connectionRepo: connectionRepo,
      quotaCacheRepo: quotaCacheRepo,
      secretStore: secretStore,
      adapter: adapter,
      registry: registry,
      initialTestSuccess: success,
    );
  }

  final ConnectionRepository? connectionRepo;
  final QuotaCacheRepository? quotaCacheRepo;
  final SecretStore? secretStore;
  final ProviderAdapter? adapter;
  final ProviderRegistry? registry;
  final AppState? appState;
  final bool? initialTestSuccess;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ConnectionsScreen(
        connectionRepository: connectionRepo,
        appState: appState,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
        adapter: adapter,
        providerRegistry: registry,
      ),
    );
  }
}

/// Test harness for the overall app or widget surface.
/// Response simulation modes for [TestApp.withConnections] and [FixtureProviderAdapter].
enum FixtureResponse { success, limited, timeout, authError, error }

class _FixtureTimeoutException implements TimeoutException {
  const _FixtureTimeoutException([this.message = 'Timeout']);

  @override
  final String? message;

  @override
  Duration? get duration => null;

  @override
  String toString() => message ?? 'Timeout';
}

/// Fixture-backed [ProviderAdapter] that maps connections to predefined [FixtureResponse]s.
class FixtureProviderAdapter implements ProviderAdapter {
  FixtureProviderAdapter({
    this.id = 'openrouter',
    this.name = 'OpenRouter',
    required this.responses,
  });

  @override
  final String id;

  @override
  final String name;
  @override
  AuthKind get authKind => AuthKind.apiKey;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };
  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  final Map<String, FixtureResponse> responses;

  FixtureResponse _responseFor(Connection connection) {
    return responses[connection.displayName] ??
        responses[connection.id] ??
        FixtureResponse.success;
  }

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    final resp = _responseFor(connection);
    return switch (resp) {
      FixtureResponse.success => TestResult.success(
        quotas: const [
          Quota(
            id: 'key-limit',
            label: 'Key limit',
            percent: 75.0,
            remaining: 2.5,
            limit: 10.0,
            unit: 'USD',
            resetAt: null,
          ),
        ],
      ),
      FixtureResponse.limited => TestResult.failure(
        error: 'Key limit exceeded',
      ),
      FixtureResponse.timeout => TestResult.failure(error: 'Timeout'),
      FixtureResponse.authError => TestResult.failure(error: 'Invalid API key'),
      FixtureResponse.error => TestResult.failure(
        error: 'Provider unavailable',
      ),
    };
  }

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final resp = _responseFor(connection);
    final now = DateTime.now().toUtc();
    return switch (resp) {
      FixtureResponse.success => ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.ok,
        quotas: const [
          Quota(
            id: 'key-limit',
            label: 'Key limit',
            percent: 75.0,
            remaining: 2.5,
            limit: 10.0,
            unit: 'USD',
            resetAt: null,
          ),
        ],
        balance: null,
        fetchedAt: now,
        error: null,
      ),
      FixtureResponse.limited => ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.limited,
        quotas: const [],
        balance: null,
        fetchedAt: now,
        error: 'Key limit exceeded',
      ),
      FixtureResponse.timeout => throw const _FixtureTimeoutException(
        'Timeout',
      ),
      FixtureResponse.authError => ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.authError,
        quotas: const [],
        balance: null,
        fetchedAt: now,
        error: 'Invalid API key',
      ),
      FixtureResponse.error => ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.error,
        quotas: const [],
        balance: null,
        fetchedAt: now,
        error: 'Provider unavailable',
      ),
    };
  }
}

/// Test harness for the overall app or widget surface.
class TestApp extends StatefulWidget {
  TestApp({super.key, AppState? state, this.child})
    : state = state ?? createTestAppState(),
      autoLoadAndRefresh = false;

  TestApp.empty({super.key})
    : state = createTestAppState(accounts: const [], isLoading: false),
      child = null,
      autoLoadAndRefresh = false;

  const TestApp._internal({required this.state, this.autoLoadAndRefresh = true})
    : child = null;

  final AppState state;
  final Widget? child;
  final bool autoLoadAndRefresh;

  /// Creates a test app pre-configured with the specified [connections]
  /// and mapped fixture [responses].
  static Widget withConnections({
    required List<String> connections,
    required Map<String, FixtureResponse> responses,
    Map<String, List<Quota>>? initialCachedQuotas,
    AppState? appState,
  }) {
    final connectionList = <Connection>[];
    final secretMap = <String, String>{};
    final quotaMap = <String, List<Quota>>{};

    for (final name in connections) {
      final id = 'conn-${name.toLowerCase().replaceAll(RegExp(r'\s+'), '_')}';
      final secretRef = 'cred-$id';
      final conn = Connection(
        id: id,
        provider: 'openrouter',
        displayName: name,
        group: null,
        plan: 'OpenRouter',
        credentialRef: secretRef,
        enabled: true,
      );
      connectionList.add(conn);
      secretMap[secretRef] = 'sk-test-$name';

      final quotas =
          initialCachedQuotas?[name] ??
          initialCachedQuotas?[id] ??
          const <Quota>[];
      if (quotas.isNotEmpty) {
        quotaMap[id] = quotas;
        quotaMap[name] = quotas;
      }
    }

    if (appState != null) {
      if (appState.connectionRepository is MemoryConnectionRepository) {
        final repo =
            appState.connectionRepository as MemoryConnectionRepository;
        for (final conn in connectionList) {
          repo.save(conn);
        }
      }
      if (appState.secretStore is MemorySecretStore) {
        final store = appState.secretStore as MemorySecretStore;
        for (final entry in secretMap.entries) {
          store.write(entry.key, entry.value);
        }
      }
      if (appState.quotaCacheRepository is MemoryQuotaCacheRepository) {
        final cache =
            appState.quotaCacheRepository as MemoryQuotaCacheRepository;
        for (final entry in quotaMap.entries) {
          cache.saveAll(entry.key, entry.value);
        }
      }
    }

    final connRepo =
        appState?.connectionRepository ??
        MemoryConnectionRepository(connectionList);
    final quotaCacheRepo =
        appState?.quotaCacheRepository ?? MemoryQuotaCacheRepository(quotaMap);
    final secretStore = appState?.secretStore ?? MemorySecretStore(secretMap);
    final registry =
        appState?.providerRegistry ??
        (ProviderRegistry(registerDefaults: false)
          ..register(FixtureProviderAdapter(responses: responses)));

    if (registry.get('openrouter') is! FixtureProviderAdapter) {
      registry.register(FixtureProviderAdapter(responses: responses));
    }

    final initialAccounts = <AccountItem>[];
    for (final conn in connectionList) {
      final quotas = quotaMap[conn.id] ?? const <Quota>[];
      final snapshot = ProviderSnapshot(
        connectionId: conn.id,
        status: ConnectionStatus.ok,
        quotas: quotas,
        balance: null,
        fetchedAt: DateTime.now().toUtc(),
        error: null,
      );
      initialAccounts.add(AccountItem(connection: conn, snapshot: snapshot));
    }

    final effectiveState =
        appState ??
        AppState(
          isLoading: false,
          accounts: initialAccounts,
          connectionRepository: connRepo,
          quotaCacheRepository: quotaCacheRepo,
          secretStore: secretStore,
          providerRegistry: registry,
          autoStartRefreshTimer: false,
        );

    return TestApp._internal(state: effectiveState, autoLoadAndRefresh: true);
  }

  @override
  State<TestApp> createState() => _TestAppState();
}

class _TestAppState extends State<TestApp> {
  @override
  void initState() {
    super.initState();
    if (widget.autoLoadAndRefresh) {
      widget.state.load().then((_) {
        if (mounted) {
          widget.state.refreshAll();
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return TokenDockApp(appState: widget.state, child: widget.child);
  }
}
