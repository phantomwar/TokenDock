import 'dart:async';

import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/models/test_result.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/services/refreshable_credential.dart';

/// Test provider adapter allowing programmatic control over fetch responses,
/// delays, concurrency tracking, and errors.
class ControlledProvider implements ProviderAdapter {
  ControlledProvider({
    this.id = 'openrouter',
    this.name = 'Controlled',
    this.defaultQuotas = const [],
    this.defaultBalance = 100.0,
  });

  @override
  final String id;

  @override
  final String name;
  @override
  AuthKind get authKind => AuthKind.apiKey;

  @override
  Map<String, String> buildAuthHeader(String secret) =>
      {'Authorization': 'Bearer $secret'};
  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  final List<Quota> defaultQuotas;
  final double? defaultBalance;

  /// Number of times [fetch] has been invoked.
  int fetchCalls = 0;

  /// Number of times [test] has been invoked.
  int testCalls = 0;

  /// Connections passed to [fetch].
  final List<Connection> fetchedConnections = [];

  /// Current number of simultaneous in-flight [fetch] executions.
  int currentConcurrentFetches = 0;

  /// Peak number of simultaneous in-flight [fetch] executions observed.
  int maxConcurrentFetches = 0;

  /// Completer to pause fetch executions until completed by the test.
  Completer<void>? gate;

  /// Optional error to throw on [fetch].
  Object? errorToThrow;

  /// Optional custom fetch implementation.
  Future<ProviderSnapshot> Function(Connection connection, String secret)? onFetch;

  /// Optional delay simulated on [fetch].
  Duration? simulatedDelay;

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    testCalls++;
    if (errorToThrow != null) {
      return TestResult.failure(error: errorToThrow.toString());
    }
    return TestResult.success(plan: 'Controlled');
  }

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    fetchCalls++;
    fetchedConnections.add(connection);
    currentConcurrentFetches++;
    if (currentConcurrentFetches > maxConcurrentFetches) {
      maxConcurrentFetches = currentConcurrentFetches;
    }

    try {
      if (gate != null) {
        await gate!.future;
      }

      if (simulatedDelay != null) {
        await Future<void>.delayed(simulatedDelay!);
      }

      if (onFetch != null) {
        return await onFetch!(connection, secret);
      }

      if (errorToThrow != null) {
        throw errorToThrow!;
      }

      return ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.ok,
        quotas: defaultQuotas,
        balance: defaultBalance,
        fetchedAt: DateTime.now().toUtc(),
        error: null,
      );
    } finally {
      currentConcurrentFetches--;
    }
  }

  /// Resets call counters and concurrency tracking.
  void reset() {
    fetchCalls = 0;
    testCalls = 0;
    fetchedConnections.clear();
    currentConcurrentFetches = 0;
    maxConcurrentFetches = 0;
    gate = null;
    errorToThrow = null;
    onFetch = null;
    simulatedDelay = null;
  }
}
