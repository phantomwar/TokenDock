import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// The production HTTP transport must never block forever.
///
/// Audit C-01: `_HttpClientRunner` set no `connectionTimeout` and applied no
/// `.timeout()` to any await, so a hung socket kept the connection's in-flight
/// future pending forever and chained every later refresh and test behind it.
void main() {
  /// Accepts the connection and then never answers, so the client blocks
  /// waiting for response headers.
  Future<HttpServer> silentServer() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    // Deliberately no response: the request is accepted and dropped.
    unawaited(server.forEach((_) {}).catchError((Object _) {}));
    return server;
  }

  group('AntigravityHttpClientRunner timeouts', () {
    test('aborts when the server accepts but never responds', () async {
      final server = await silentServer();
      addTearDown(() => server.close(force: true));

      final runner = AntigravityHttpClientRunner(
        connectionTimeout: const Duration(seconds: 2),
        responseTimeout: const Duration(milliseconds: 300),
      );

      await expectLater(
        runner.post(
          Uri.parse('http://127.0.0.1:${server.port}/token'),
          headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
          body: 'grant_type=refresh_token',
        ),
        throwsA(isA<TimeoutException>()),
      );
    });

    test('a normal response is still returned intact', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      unawaited(
        server.forEach((request) async {
          request.response.statusCode = 200;
          request.response.headers.set('Retry-After', '7');
          request.response.write('{"access_token":"a"}');
          await request.response.close();
        }),
      );

      final runner = AntigravityHttpClientRunner(
        connectionTimeout: const Duration(seconds: 2),
        responseTimeout: const Duration(seconds: 5),
      );

      final response = await runner.post(
        Uri.parse('http://127.0.0.1:${server.port}/token'),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'grant_type=refresh_token',
      );

      expect(response.statusCode, 200);
      expect(response.body, '{"access_token":"a"}');
      expect(response.retryAfter, '7');
    });

    test(
      'rejects an oversized response body instead of buffering it',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        unawaited(
          server.forEach((request) async {
            request.response.statusCode = 200;
            // Far beyond the configured cap.
            for (var i = 0; i < 40; i++) {
              request.response.write('x' * 1024);
            }
            await request.response.close();
          }),
        );

        final runner = AntigravityHttpClientRunner(
          connectionTimeout: const Duration(seconds: 2),
          responseTimeout: const Duration(seconds: 5),
          maxResponseBytes: 4096,
        );

        await expectLater(
          runner.post(
            Uri.parse('http://127.0.0.1:${server.port}/token'),
            headers: const {
              'Content-Type': 'application/x-www-form-urlencoded',
            },
            body: 'grant_type=refresh_token',
          ),
          throwsA(
            isA<AntigravityTransportFailure>().having(
              (e) => e.cause.toString(),
              'cause',
              contains('too large'),
            ),
          ),
        );
      },
    );
  });

  group('AntigravityOAuthProvider never hangs on an unresponsive token '
      'endpoint', () {
    test(
      'fetch completes with a failure snapshot instead of hanging',
      () async {
        final server = await silentServer();
        addTearDown(() => server.close(force: true));

        final provider = AntigravityOAuthProvider(
          http: AntigravityHttpClientRunner(
            connectionTimeout: const Duration(seconds: 2),
            responseTimeout: const Duration(milliseconds: 300),
          ),
        );
        final secret =
            '{"accessToken":"a","projectId":"p",'
            '"identityKey":"user@example.com"}';

        final snapshot = await provider
            .fetch(_connection(), secret)
            .timeout(const Duration(seconds: 10));

        expect(snapshot.status, isNot(ConnectionStatus.ok));
        expect(snapshot.error, isNotNull);
      },
    );
  });
}

Connection _connection() => const Connection(
  id: 'c1',
  provider: 'antigravity',
  displayName: 'Antigravity',
  group: null,
  plan: null,
  credentialRef: 'ref',
  enabled: true,
  authType: 'oauth',
  identityKey: 'user@example.com',
  providerData: '{"source":"remote","projectId":"p"}',
);
