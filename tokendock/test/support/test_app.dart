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
  });

  @override
  final String id;

  @override
  final String name;

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
      status:
          testResult.isSuccess ? ConnectionStatus.ok : ConnectionStatus.error,
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
          for (final c in initialConnections ?? <Connection>[]) c.id: c
        };

  final Map<String, Connection> _storage;

  @override
  Future<List<Connection>> getAll() async {
    return _storage.values.toList();
  }

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
  MemoryQuotaCacheRepository();

  final Map<String, List<Quota>> _storage = {};

  @override
  Future<List<Quota>> getAll(String connectionId) async {
    return List<Quota>.unmodifiable(_storage[connectionId] ?? const <Quota>[]);
  }

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
  final reg = registry ??
      (ProviderRegistry(registerDefaults: false)
        ..register(FakeProviderAdapter(
          testResult: TestResult.success(quotas: const []),
        )));
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
  }) {
    final adapter = FakeProviderAdapter(
      testResult: success
          ? TestResult.success(plan: plan ?? 'Pro', quotas: quotas ?? const [])
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
  final bool? initialTestSuccess;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: ConnectionsScreen(
        connectionRepository: connectionRepo,
        quotaCacheRepository: quotaCacheRepo,
        secretStore: secretStore,
        adapter: adapter,
        providerRegistry: registry,
      ),
    );
  }
}

/// Test harness for the overall app or widget surface.
class TestApp extends StatelessWidget {
  TestApp({
    super.key,
    AppState? state,
    this.child,
  })  : state = state ?? createTestAppState(),
        child = child;

  TestApp.empty({super.key})
      : state = createTestAppState(accounts: const [], isLoading: false),
        child = null;

  final AppState state;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return TokenDockApp(
      appState: state,
      child: child,
    );
  }
}
