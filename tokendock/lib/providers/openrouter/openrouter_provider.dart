import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../provider_adapter.dart';
import 'openrouter_response.dart';

class OpenRouterProvider implements ProviderAdapter {
  OpenRouterProvider({HttpClient? client}) : _client = client ?? HttpClient() {
    _client.connectionTimeout = _connectionTimeout;
  }

  final HttpClient _client;

  static const Duration _connectionTimeout = Duration(seconds: 10);
  static const Duration _responseTimeout = Duration(seconds: 15);
  static final Uri _endpoint = Uri.parse('https://openrouter.ai/api/v1/key');

  @override
  String get id => 'openrouter';

  @override
  String get name => 'OpenRouter';

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    try {
      final request = await _client.getUrl(_endpoint).timeout(_connectionTimeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
      final response = await request.close().timeout(_responseTimeout);
      final body = await utf8.decodeStream(response).timeout(_responseTimeout);
      final fetchedAt = DateTime.now().toUtc();

      if (response.statusCode == HttpStatus.ok) {
        return OpenRouterResponse.parseKey(
          connectionId: connection.id,
          body: body,
          fetchedAt: fetchedAt,
        );
      }

      return OpenRouterResponse.mapError(
        connectionId: connection.id,
        fetchedAt: fetchedAt,
        statusCode: response.statusCode,
        body: body,
      );
    } on TimeoutException {
      return OpenRouterResponse.timeoutSnapshot(
        connectionId: connection.id,
        fetchedAt: DateTime.now().toUtc(),
      );
    } on SocketException {
      return OpenRouterResponse.errorSnapshot(
        connectionId: connection.id,
        fetchedAt: DateTime.now().toUtc(),
        status: ConnectionStatus.error,
        error: 'Provider unavailable',
      );
    } catch (_) {
      return OpenRouterResponse.errorSnapshot(
        connectionId: connection.id,
        fetchedAt: DateTime.now().toUtc(),
        status: ConnectionStatus.error,
        error: 'Unknown response',
      );
    }
  }

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    final snapshot = await fetch(connection, secret);
    if (snapshot.status == ConnectionStatus.ok) {
      return TestResult.success(
        quotas: snapshot.quotas,
        plan: connection.plan,
      );
    }
    return TestResult.failure(
      error: snapshot.error ?? 'Connection failed',
    );
  }
}
