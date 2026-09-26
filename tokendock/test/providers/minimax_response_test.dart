import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/minimax/minimax_response.dart';

/// The MiniMax credential gate's two jobs, and nothing else.
///
/// The status-code mapping these tests exercise is **not** re-tested here: it
/// lives in `ProviderStatus` and `provider_status_test.dart` already covers it
/// generically, including that a failure carries no quotas. Repeating that table
/// per vendor is how a mapping drifts without anyone noticing.
///
/// So this file only pins what is genuinely MiniMax's:
///
/// - the gate endpoint, which must stay the one that answers 401;
/// - the `error.http_code` fallback, a MiniMax-specific envelope detail.
void main() {
  final fetchedAt = DateTime.utc(2026, 9, 26, 12);

  test('the gate is the endpoint that answers 401 for a bad key', () {
    expect(
      MiniMaxResponse.defaultModelsEndpoint,
      Uri.parse('https://api.minimax.io/v1/models'),
    );
  });

  group('the error.http_code fallback', () {
    // MiniMax puts the status in the body as a string. Relying only on the
    // transport code would mean a rejected credential is reported as an
    // unclassified failure, so the key is never revoked and the user is never
    // told to re-enter it.
    test('reads the status from the body when there is no transport code', () {
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        body:
            '{"type":"error","error":{"type":"authorized_error",'
            '"message":"login fail","http_code":"401"},"request_id":"abc"}',
      );

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.failureCause, isNotNull);
    });

    test('accepts the code as a number too, rather than assuming one form', () {
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        body: '{"error":{"http_code":403}}',
      );

      expect(snapshot.status, ConnectionStatus.error);
      expect(snapshot.failureCause, isNull);
    });

    test('the transport code wins when both are present', () {
      // Otherwise a stale or attacker-controlled body could override what the
      // server actually returned.
      final snapshot = MiniMaxResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 401,
        body: '{"error":{"http_code":500}}',
      );

      expect(snapshot.status, ConnectionStatus.authError);
    });

    test('an unrecognised envelope is unknown, not a guess', () {
      // The dangerous failure here is inventing a plausible number and
      // classifying the key by it.
      for (final body in <String>[
        '',
        'not json',
        '[]',
        '{}',
        '{"error":"a string"}',
        '{"error":{}}',
        '{"error":{"http_code":"not a number"}}',
        '{"error":{"http_code":null}}',
      ]) {
        final snapshot = MiniMaxResponse.mapError(
          connectionId: 'c1',
          fetchedAt: fetchedAt,
          body: body,
        );
        expect(
          snapshot.status,
          isNot(ConnectionStatus.authError),
          reason: 'body was "$body"',
        );
        expect(snapshot.error, 'Unknown response', reason: 'body was "$body"');
      }
    });

    test('never throws, whatever body it is handed', () {
      // This runs on the refresh path with a live socket; an escaping exception
      // would take down every connection's cached quota, not just this one.
      for (final body in <String>[
        '{',
        'null',
        '{"error":{"http_code":{}}}',
        '',
      ]) {
        final snapshot = MiniMaxResponse.mapError(
          connectionId: 'c1',
          fetchedAt: fetchedAt,
          body: body,
        );
        expect(snapshot.connectionId, 'c1', reason: 'body was "$body"');
      }
    });
  });

  test('a timeout is reported as a timeout, not a credential problem', () {
    // The distinction is the point of the whole class: a slow network must not
    // cost the user their key.
    final snapshot = MiniMaxResponse.mapError(
      connectionId: 'c1',
      fetchedAt: fetchedAt,
      isTimeout: true,
      body: '{"error":{"http_code":"401"}}',
    );

    expect(snapshot.error, 'Timeout');
    expect(snapshot.failureCause, isNull);
  });
}
