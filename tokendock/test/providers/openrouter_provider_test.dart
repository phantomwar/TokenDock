import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/openrouter/openrouter_provider.dart';
import 'package:tokendock/providers/openrouter/openrouter_response.dart';
import 'package:tokendock/providers/provider_registry.dart';

String loadFixture(String name) {
  final paths = [
    'test/fixtures/$name',
    'tokendock/test/fixtures/$name',
    '../test/fixtures/$name',
  ];
  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) {
      return file.readAsStringSync();
    }
  }
  throw StateError('Fixture $name not found in search paths: $paths');
}

class FakeHttpHeaders implements HttpHeaders {
  final Map<String, String> values = {};

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  String? value(String name) => values[name.toLowerCase()];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientResponse extends Stream<List<int>>
    implements HttpClientResponse {
  FakeHttpClientResponse({
    this.statusCode = 200,
    String body = '',
    String? retryAfter,
  }) : _bodyBytes = utf8.encode(body) {
    if (retryAfter != null) headers.set('retry-after', retryAfter);
  }

  @override
  final int statusCode;

  @override
  final FakeHttpHeaders headers = FakeHttpHeaders();

  final List<int> _bodyBytes;

  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return Stream<List<int>>.fromIterable([_bodyBytes]).listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClientRequest implements HttpClientRequest {
  FakeHttpClientRequest({required this.url, this.handler});

  final Uri url;
  final Future<HttpClientResponse> Function(Uri url, FakeHttpHeaders headers)?
  handler;
  final FakeHttpHeaders _headers = FakeHttpHeaders();

  @override
  HttpHeaders get headers => _headers;

  @override
  Future<HttpClientResponse> close() async {
    if (handler != null) {
      return handler!(url, _headers);
    }
    return FakeHttpClientResponse();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeHttpClient implements HttpClient {
  FakeHttpClient({this.handler});

  final Future<HttpClientResponse> Function(Uri url, FakeHttpHeaders headers)?
  handler;

  @override
  Duration? connectionTimeout;

  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    return FakeHttpClientRequest(url: url, handler: handler);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  const testConnection = Connection(
    id: 'conn-1',
    provider: 'openrouter',
    displayName: 'My OpenRouter Key',
    group: 'AI',
    plan: 'Pro Plan',
    credentialRef: 'cred-1',
    enabled: true,
  );

  group('OpenRouterResponse parser', () {
    test('finite key fixture maps percent: 75, remaining: 2.5, limit: 10, status: ok', () {
      final json = loadFixture('openrouter_key_finite.json');
      final fetchedAt = DateTime.utc(2026, 9, 22, 12);
      final snapshot = OpenRouterResponse.parseKey(
        connectionId: 'conn-1',
        body: json,
        fetchedAt: fetchedAt,
      );

      expect(snapshot.connectionId, 'conn-1');
      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.balance, isNull);
      expect(snapshot.error, isNull);
      expect(snapshot.fetchedAt, fetchedAt);

      expect(snapshot.quotas.length, 1);
      final quota = snapshot.quotas.single;
      expect(quota.id, 'key-limit');
      expect(quota.label, 'Key limit');
      expect(quota.unit, 'USD');
      expect(quota.limit, 10.0);
      expect(quota.remaining, 2.5);
      expect(quota.percent, 75.0);
      expect(quota.resetAt, isNull);
    });

    test('unlimited key fixture preserves limit: null, remaining: null, percent: null, status: ok', () {
      final json = loadFixture('openrouter_key_unlimited.json');
      final fetchedAt = DateTime.utc(2026, 9, 22, 12);
      final snapshot = OpenRouterResponse.parseKey(
        connectionId: 'conn-1',
        body: json,
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.quotas.length, 1);
      final quota = snapshot.quotas.single;
      expect(quota.limit, isNull);
      expect(quota.remaining, isNull);
      expect(quota.percent, isNull);
      expect(quota.unit, 'USD');
    });

    test(
      'malformed key fixture maps to error status with Unknown response',
      () {
        final json = loadFixture('openrouter_key_malformed.json');
        final fetchedAt = DateTime.utc(2026, 9, 22, 12);
        final snapshot = OpenRouterResponse.parseKey(
          connectionId: 'conn-1',
          body: json,
          fetchedAt: fetchedAt,
        );

        expect(snapshot.status, ConnectionStatus.error);
        expect(snapshot.error, 'Unknown response');
        expect(snapshot.quotas, isEmpty);
      },
    );

    test(
      'invalid non-JSON body maps to error status with Unknown response',
      () {
        final fetchedAt = DateTime.utc(2026, 9, 22, 12);
        final snapshot = OpenRouterResponse.parseKey(
          connectionId: 'conn-1',
          body: 'Not a json document',
          fetchedAt: fetchedAt,
        );

        expect(snapshot.status, ConnectionStatus.error);
        expect(snapshot.error, 'Unknown response');
      },
    );

    test('402 fixture maps to ConnectionStatus.limited', () {
      final json = loadFixture('openrouter_error_402.json');
      final fetchedAt = DateTime.utc(2026, 9, 22, 12);
      final snapshot = OpenRouterResponse.parseKey(
        connectionId: 'conn-1',
        body: json,
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, ConnectionStatus.limited);
      expect(snapshot.error, 'Insufficient credits');
    });

    test('limit_reset parses numeric Unix timestamp into UTC DateTime', () {
      const json = '''
      {
        "data": {
          "limit": 50.0,
          "limit_remaining": 25.0,
          "limit_reset": 1774224000
        }
      }
      ''';
      final snapshot = OpenRouterResponse.parseKey(
        connectionId: 'conn-1',
        body: json,
        fetchedAt: DateTime.utc(2026, 9, 22),
      );

      expect(
        snapshot.quotas.single.resetAt,
        DateTime.fromMillisecondsSinceEpoch(1774224000 * 1000, isUtc: true),
      );
    });

    test('limit_reset parses ISO-8601 string into UTC DateTime', () {
      const json = '''
      {
        "data": {
          "limit": 50.0,
          "limit_remaining": 25.0,
          "limit_reset": "2026-10-01T00:00:00Z"
        }
      }
      ''';
      final snapshot = OpenRouterResponse.parseKey(
        connectionId: 'conn-1',
        body: json,
        fetchedAt: DateTime.utc(2026, 9, 22),
      );

      expect(snapshot.quotas.single.resetAt, DateTime.utc(2026, 10, 1));
    });
  });

  group('HTTP status code mapping', () {
    test('401 maps to authError with Invalid API key', () {
      final result = OpenRouterResponse.mapHttpStatus(401);
      expect(result.status, ConnectionStatus.authError);
      expect(result.error, 'Invalid API key');
    });

    test('403 maps to error with Forbidden', () {
      final result = OpenRouterResponse.mapHttpStatus(403);
      expect(result.status, ConnectionStatus.error);
      expect(result.error, 'Forbidden');
    });

    test('402 maps to limited with Insufficient credits', () {
      final result = OpenRouterResponse.mapHttpStatus(402);
      expect(result.status, ConnectionStatus.limited);
      expect(result.error, 'Insufficient credits');
    });

    test('429 maps to warning with Rate limited', () {
      final result = OpenRouterResponse.mapHttpStatus(429);
      expect(result.status, ConnectionStatus.warning);
      expect(result.error, 'Rate limited');
    });

    test('500..599 maps to error with Provider unavailable', () {
      for (final code in [500, 502, 503, 504, 599]) {
        final result = OpenRouterResponse.mapHttpStatus(code);
        expect(result.status, ConnectionStatus.error);
        expect(result.error, 'Provider unavailable');
      }
    });

    test('timeout maps to error with Timeout', () {
      final snapshot = OpenRouterResponse.timeoutSnapshot(
        connectionId: 'conn-1',
        fetchedAt: DateTime.utc(2026, 9, 22),
      );
      expect(snapshot.status, ConnectionStatus.error);
      expect(snapshot.error, 'Timeout');
    });
  });

  group('ProviderRegistry', () {
    test('default registry contains OpenRouterProvider', () {
      final registry = ProviderRegistry.instance;
      final adapter = registry.get('openrouter');
      expect(adapter, isNotNull);
      expect(adapter, isA<OpenRouterProvider>());
      expect(adapter!.id, 'openrouter');
      expect(adapter.name, 'OpenRouter');
    });

    test('getAll returns unmodifiable list containing registered adapters', () {
      final registry = ProviderRegistry();
      expect(registry.getAll().any((a) => a.id == 'openrouter'), isTrue);
    });

    test('can register custom adapter in empty registry', () {
      final registry = ProviderRegistry(registerDefaults: false);
      expect(registry.getAll(), isEmpty);
      expect(registry.get('openrouter'), isNull);

      final openRouter = OpenRouterProvider();
      registry.register(openRouter);
      expect(registry.get('openrouter'), equals(openRouter));
      expect(registry.getAll().length, 1);
    });
  });

  group('OpenRouterProvider adapter', () {
    test('id and name properties are openrouter and OpenRouter', () {
      final provider = OpenRouterProvider();
      expect(provider.id, 'openrouter');
      expect(provider.name, 'OpenRouter');
    });

    test('fetch() sends Bearer <secret> header to https://openrouter.ai/api/v1/key', () async {
      Uri? capturedUrl;
      String? capturedAuthHeader;

      final client = FakeHttpClient(
        handler: (url, headers) async {
          capturedUrl = url;
          capturedAuthHeader = headers.value(HttpHeaders.authorizationHeader);
          return FakeHttpClientResponse(
            body: loadFixture('openrouter_key_finite.json'),
          );
        },
      );

      final provider = OpenRouterProvider(client: client);
      final snapshot = await provider.fetch(testConnection, 'secret-12345');

      expect(capturedUrl, Uri.parse('https://openrouter.ai/api/v1/key'));
      expect(capturedAuthHeader, 'Bearer secret-12345');
      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.quotas.single.remaining, 2.5);
    });

    test(
      'test() sends Bearer <secret> header to https://openrouter.ai/api/v1/key',
      () async {
        Uri? capturedUrl;
        String? capturedAuthHeader;

        final client = FakeHttpClient(
          handler: (url, headers) async {
            capturedUrl = url;
            capturedAuthHeader = headers.value(HttpHeaders.authorizationHeader);
            return FakeHttpClientResponse(
              body: loadFixture('openrouter_key_finite.json'),
            );
          },
        );

        final provider = OpenRouterProvider(client: client);
        final testResult = await provider.test(testConnection, 'secret-67890');

        expect(capturedUrl, Uri.parse('https://openrouter.ai/api/v1/key'));
        expect(capturedAuthHeader, 'Bearer secret-67890');
        expect(testResult.isSuccess, isTrue);
        expect(testResult.plan, 'Pro Plan');
        expect(testResult.quotas.single.percent, 75.0);
        expect(testResult.error, isNull);
      },
    );

    test('test() returns TestResult.failure on error response', () async {
      final client = FakeHttpClient(
        handler: (url, headers) async {
          return FakeHttpClientResponse(
            statusCode: 401,
            body: '{"error": {"code": 401, "message": "Invalid API key"}}',
          );
        },
      );

      final provider = OpenRouterProvider(client: client);
      final testResult = await provider.test(testConnection, 'invalid-secret');

      expect(testResult.isSuccess, isFalse);
      expect(testResult.error, 'Invalid API key');
      expect(testResult.quotas, isEmpty);
      expect(testResult.plan, isNull);
    });
    test('402 in-flight budget with Retry-After is transient', () async {
      final client = FakeHttpClient(
        handler: (url, headers) async => FakeHttpClientResponse(
          statusCode: 402,
          body:
              '{"error":{"code":402,"message":"temporary budget",'
              '"metadata":{"limit_source":"openrouter_in_flight_budget"}}}',
          retryAfter: '60',
        ),
      );

      final snapshot = await OpenRouterProvider(client: client)
          .fetch(testConnection, 'secret');

      expect(snapshot.status, ConnectionStatus.warning);
      expect(snapshot.error, 'Rate limited');
    });
    test('429 Retry-After seconds produce a connection cooldown', () async {
      final client = FakeHttpClient(
        handler: (url, headers) async => FakeHttpClientResponse(
          statusCode: 429,
          body: '{"error":{"code":429,"message":"rate limited"}}',
          retryAfter: '60',
        ),
      );

      final snapshot = await OpenRouterProvider(client: client)
          .fetch(testConnection, 'secret');

      expect(
        snapshot.cooldownUntil,
        snapshot.fetchedAt.add(const Duration(seconds: 60)),
      );
    });

    test('503 Retry-After HTTP date is parsed as UTC cooldown', () async {
      final target = DateTime.now().toUtc().add(const Duration(minutes: 2));
      final expected = DateTime.utc(
        target.year,
        target.month,
        target.day,
        target.hour,
        target.minute,
        target.second,
      );
      final client = FakeHttpClient(
        handler: (url, headers) async => FakeHttpClientResponse(
          statusCode: 503,
          body: '{"error":{"code":503,"message":"unavailable"}}',
          retryAfter: HttpDate.format(target),
        ),
      );

      final snapshot = await OpenRouterProvider(client: client)
          .fetch(testConnection, 'secret');

      expect(snapshot.cooldownUntil, expected);
      expect(snapshot.cooldownUntil!.isUtc, isTrue);
    });

    test('malformed Retry-After does not create a cooldown', () async {
      final client = FakeHttpClient(
        handler: (url, headers) async => FakeHttpClientResponse(
          statusCode: 429,
          body: '{"error":{"code":429}}',
          retryAfter: 'later',
        ),
      );

      final snapshot = await OpenRouterProvider(client: client)
          .fetch(testConnection, 'secret');

      expect(snapshot.cooldownUntil, isNull);
    });

    test(
      'fetch() maps TimeoutException to error status with Timeout',
      () async {
        final client = FakeHttpClient(
          handler: (url, headers) async {
            throw TimeoutException('Request timed out');
          },
        );

        final provider = OpenRouterProvider(client: client);
        final snapshot = await provider.fetch(testConnection, 'secret-key');

        expect(snapshot.status, ConnectionStatus.error);
        expect(snapshot.error, 'Timeout');
      },
    );

    test('bearer token is never logged or exposed in snapshot errors or test failure', () async {
      const secret = 'super-confidential-bearer-token-99999';

      for (final statusCode in [401, 402, 403, 429, 500, 503]) {
        final client = FakeHttpClient(
          handler: (url, headers) async {
            return FakeHttpClientResponse(
              statusCode: statusCode,
              body: '{"error": {"code": $statusCode}}',
            );
          },
        );

        final provider = OpenRouterProvider(client: client);
        final snapshot = await provider.fetch(testConnection, secret);
        expect(snapshot.error, isNotNull);
        expect(snapshot.error!.contains(secret), isFalse);

        final testResult = await provider.test(testConnection, secret);
        expect(testResult.error, isNotNull);
        expect(testResult.error!.contains(secret), isFalse);
      }
    });
  });
}
