import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/providers/minimax/minimax_response.dart';

/// MiniMax has a real, auth-enforcing probe and no published usage figure.
///
/// `GET https://api.minimax.io/v1/models` returns 401 for a bad key, which
/// makes it a genuine credential gate. But MiniMax publishes no balance or
/// usage endpoint anywhere in its documented API surface -- the Token Plan quota
/// is "shown as a usage bar in the console" and everything else is pay-as-you-go
/// billed against a console balance. So the snapshot must carry connection
/// health and nothing else. These tests exist to stop that from quietly becoming
/// an invented number.
void main() {
  final fetchedAt = DateTime.utc(2026, 9, 26, 12);

  group('a valid key', () {
    final snapshot = MiniMaxResponse.parseModels(
      connectionId: 'c1',
      body:
          '{"object":"list","data":['
          '{"id":"MiniMax-M3","object":"model","created":1780272000,'
          '"owned_by":"minimax"},'
          '{"id":"MiniMax-M2.7","object":"model","created":1773799200,'
          '"owned_by":"minimax"}]}',
      fetchedAt: fetchedAt,
    );

    test('is a healthy connection', () {
      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.error, isNull);
    });

    test('reports no usage figure rather than inventing one', () {
      expect(
        snapshot.quotas,
        isEmpty,
        reason:
            'MiniMax publishes no usage API. Emitting a quota here would '
            'be a fabricated number shown to the user as fact.',
      );
    });

    test('carries the fetch time so the cache age has something to show', () {
      expect(snapshot.fetchedAt, fetchedAt);
    });
  });

  group('errors', () {
    test('401 is an auth error, which is what makes the probe a real gate', () {
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 401,
        body:
            '{"type":"error","error":{"type":"authorized_error",'
            '"message":"login fail","http_code":"401"},"request_id":"abc"}',
      );

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.error, 'Invalid API key');
    });

    test('an auth error is marked as a definitive credential failure', () {
      // This is what makes the refresh path revoke and prompt a re-login,
      // rather than retrying a key that will never work.
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 401,
      );

      expect(snapshot.failureCause, isNotNull);
    });

    test('429 is a warning, not a dead connection', () {
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 429,
      );

      expect(snapshot.status, ConnectionStatus.warning);
      expect(snapshot.failureCause, isNull);
    });

    test('5xx is a provider problem, not the key', () {
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 503,
      );

      expect(snapshot.status, ConnectionStatus.error);
      expect(snapshot.failureCause, isNull);
    });

    test('a timeout is reported as a timeout', () {
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        isTimeout: true,
      );

      expect(snapshot.error, 'Timeout');
    });
  });

  group('malformed responses', () {
    test('a body that is not JSON is an unknown response, not a crash', () {
      final snapshot = MiniMaxResponse.parseModels(
        connectionId: 'c1',
        body: 'not json at all',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, ConnectionStatus.error);
      expect(snapshot.error, 'Unknown response');
    });

    test('JSON that is not the documented shape is an unknown response', () {
      for (final body in <String>[
        '[]',
        '"a string"',
        '{"object":"list"}',
        '{"object":"list","data":{}}',
        '{"object":"list","data":[{"no_id":true}]}',
      ]) {
        final snapshot = MiniMaxResponse.parseModels(
          connectionId: 'c1',
          body: body,
          fetchedAt: fetchedAt,
        );
        expect(snapshot.error, 'Unknown response', reason: 'body was $body');
      }
    });

    test('an empty model list is still a valid, healthy key', () {
      // A key that authenticates but has no models enabled is a real state,
      // and it is not an error.
      final snapshot = MiniMaxResponse.parseModels(
        connectionId: 'c1',
        body: '{"object":"list","data":[]}',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.quotas, isEmpty);
    });
  });

  test('the parser never throws, whatever it is handed', () {
    // A provider fetch runs on the refresh path with a live socket. An escaping
    // exception there would take down every connection's cached quota, not just
    // this one -- the same reasoning the read-resilience tests use elsewhere.
    for (final body in <String>['', '{', 'null', '[]', '{"data":null}']) {
      final ProviderSnapshot snapshot = MiniMaxResponse.parseModels(
        connectionId: 'c1',
        body: body,
        fetchedAt: fetchedAt,
      );
      expect(snapshot.connectionId, 'c1', reason: 'body was "$body"');
    }
  });
}
