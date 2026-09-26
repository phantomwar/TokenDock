import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/minimax/minimax_provider.dart';
import 'package:tokendock/providers/provider_http.dart';

/// The provider half: does the documented probe actually gate a credential.
///
/// `MiniMaxResponse` is covered in `minimax_response_test.dart`. What matters
/// here is that the adapter calls the endpoint the vendor documents, sends a
/// bearer token, and turns the probe's outcome into the right state.
class _StubProbe extends ProviderHttpProbe {
  _StubProbe(this._result) : super(client: null);

  final ProbeResult _result;
  Uri? requestedUri;
  String? sentSecret;

  @override
  Future<ProbeResult> getJson(Uri uri, {required String secret}) async {
    requestedUri = uri;
    sentSecret = secret;
    return _result;
  }
}

void main() {
  final connection = Connection(
    id: 'mm',
    provider: 'minimax',
    displayName: 'MiniMax',
    group: null,
    plan: null,
    credentialRef: 'ref',
    enabled: true,
  );

  test('calls the endpoint from the vendor OpenAPI document', () async {
    final probe = _StubProbe(
      const ProbeResult.response(
        statusCode: 200,
        body: '{"object":"list","data":[{"id":"MiniMax-M3"}]}',
      ),
    );

    await MiniMaxProvider(probe: probe).fetch(connection, 'sk-key');

    expect(probe.requestedUri, Uri.parse('https://api.minimax.io/v1/models'));
  });

  test(
    'sends the secret as a bearer token, never in the query string',
    () async {
      final probe = _StubProbe(
        const ProbeResult.response(statusCode: 200, body: '{"data":[]}'),
      );

      await MiniMaxProvider(probe: probe).fetch(connection, 'sk-secret-value');

      expect(probe.sentSecret, 'sk-secret-value');
      expect(
        probe.requestedUri.toString(),
        isNot(contains('sk-secret-value')),
        reason: 'a credential in a URL ends up in logs and proxy history',
      );
    },
  );

  test(
    'a 401 is reported as an auth error, which is the gate working',
    () async {
      final probe = _StubProbe(
        const ProbeResult.response(
          statusCode: 401,
          body:
              '{"type":"error","error":{"type":"authorized_error",'
              '"http_code":"401"}}',
        ),
      );

      final snapshot = await MiniMaxProvider(probe: probe)
          .fetch(connection, 'sk-bad');

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.failureCause, isNotNull);
    },
  );

  test('a timeout is a timeout, not a generic failure', () async {
    final probe = _StubProbe(const ProbeResult.timeout());

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.error, 'Timeout');
  });

  test('a refused connection does not claim to be a timeout', () async {
    // The distinction is why ProviderHttpProbe exists: conflating the two
    // tells the user the wrong thing about why their number did not move.
    final probe = _StubProbe(const ProbeResult.transportFailure());

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.error, isNot('Timeout'));
    expect(snapshot.status, ConnectionStatus.error);
  });

  test('a valid key yields no invented usage figure', () async {
    final probe = _StubProbe(
      const ProbeResult.response(
        statusCode: 200,
        body:
            '{"object":"list","data":[{"id":"MiniMax-M3"},'
            '{"id":"MiniMax-M2.7"}]}',
      ),
    );

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.status, ConnectionStatus.ok);
    expect(
      snapshot.quotas,
      isEmpty,
      reason:
          'MiniMax publishes no usage API, so there is no honest number to '
          'show. Emitting one would display a fabrication as fact.',
    );
  });

  group('test-before-save', () {
    test('succeeds for a valid key', () async {
      final probe = _StubProbe(
        const ProbeResult.response(
          statusCode: 200,
          body: '{"object":"list","data":[{"id":"MiniMax-M3"}]}',
        ),
      );

      final result = await MiniMaxProvider(probe: probe)
          .test(connection, 'sk-key');

      expect(result.isSuccess, isTrue);
    });

    test('fails for a rejected key', () async {
      final probe = _StubProbe(
        const ProbeResult.response(statusCode: 401, body: '{}'),
      );

      final result = await MiniMaxProvider(probe: probe)
          .test(connection, 'sk-bad');

      expect(result.isSuccess, isFalse);
      expect(result.error, 'Invalid API key');
    });
  });
}
