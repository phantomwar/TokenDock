import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/minimax/minimax_provider.dart';
import 'package:tokendock/providers/provider_http.dart';

/// The provider half: does the documented gate actually gate, and does the
/// Token Plan endpoint supply the quota.
///
/// `MiniMaxResponse` and `MiniMaxUsageResponse` are covered in their own test
/// files. What matters here is the two-endpoint sequence: MiniMax splits
/// credential checking (`/v1/models`, which 401s) from plan usage
/// (`/v1/token_plan/remains`, which returns 200 even for a bad key).
class _StubProbe extends ProviderHttpProbe {
  _StubProbe(this._results) : super(client: null);

  /// Answers in order, one per call. A call past the end repeats the last.
  final List<ProbeResult> _results;

  final requestedUris = <Uri>[];
  final sentSecrets = <String>[];
  final sentHeaders = <Map<String, String>>[];

  @override
  Future<ProbeResult> getJson(
    Uri uri, {
    required String secret,
    Map<String, String> extraHeaders = const <String, String>{},
    String? authorization,
  }) async {
    requestedUris.add(uri);
    sentSecrets.add(secret);
    sentHeaders.add(extraHeaders);
    final index = requestedUris.length - 1;
    return index < _results.length ? _results[index] : _results.last;
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

  ProbeResult okModels() => const ProbeResult.response(
    statusCode: 200,
    body: '{"object":"list","data":[{"id":"MiniMax-M3"}]}',
  );

  ProbeResult okPlan() => const ProbeResult.response(
    statusCode: 200,
    body:
        '{"base_resp":{"status_code":0},"model_remains":[{"model_name":'
        '"general","start_time":1789000000,"end_time":1789018000,'
        '"current_interval_remaining_percent":40,'
        '"current_interval_total_count":6320,'
        '"current_interval_usage_count":3792,'
        '"current_interval_status":1,"weekly_start_time":1788486400,'
        '"weekly_end_time":1789091200,'
        '"current_weekly_remaining_percent":72,'
        '"current_weekly_total_count":15790,'
        '"current_weekly_usage_count":4431,'
        '"current_weekly_status":1}]}',
  );

  test('gates on the endpoint that 401s, then reads the plan', () async {
    final probe = _StubProbe([okModels(), okPlan()]);

    await MiniMaxProvider(probe: probe).fetch(connection, 'sk-key');

    expect(
      probe.requestedUris,
      hasLength(2),
      reason: 'the gate must run before the usage call',
    );
    expect(
      probe.requestedUris.first,
      Uri.parse('https://api.minimax.io/v1/models'),
      reason: 'this is the endpoint that actually enforces the key',
    );
    expect(
      probe.requestedUris.last,
      Uri.parse('https://api.minimax.io/v1/token_plan/remains'),
    );
  });

  test(
    'a working key yields the plan windows, so total and remaining show',
    () async {
      final probe = _StubProbe([okModels(), okPlan()]);

      final snapshot = await MiniMaxProvider(probe: probe)
          .fetch(connection, 'sk-key');

      expect(snapshot.status, ConnectionStatus.ok);
      final byId = {for (final q in snapshot.quotas) q.id: q};
      expect(
        byId.keys,
        containsAll(<String>['general:interval', 'general:7d']),
      );
      expect(byId['general:interval']!.remaining, 40);
      expect(byId['general:interval']!.limit, 100);
    },
  );

  test('a rejected key stops before the usage call', () async {
    final probe = _StubProbe([
      const ProbeResult.response(statusCode: 401, body: '{}'),
    ]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-bad');

    expect(snapshot.status, ConnectionStatus.authError);
    expect(
      probe.requestedUris,
      hasLength(1),
      reason: 'a key already known to be rejected must not be used again',
    );
  });

  test('a rejection only in the plan body still fails the connection', () async {
    // The plan endpoint returns 200 for a bad key, so its body is the only
    // signal there. A definitive rejection is evidence and outranks the 200 the
    // gate just saw -- it must not be swallowed as "no usage data".
    final probe = _StubProbe([
      okModels(),
      const ProbeResult.response(
        statusCode: 200,
        body: '{"base_resp":{"status_code":1004},"model_remains":[]}',
      ),
    ]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-bad');

    expect(snapshot.status, ConnectionStatus.authError);
    expect(snapshot.quotas, isEmpty);
  });

  test('an unreachable plan endpoint keeps the last known quota', () async {
    // The credential is already proven by the gate, so this is not an auth
    // error. But it must not be `ok` either: `RefreshService` replaces the
    // cached quota with whatever comes back, so "healthy, no quotas" would
    // blank the user's card because one endpoint timed out.
    final probe = _StubProbe([okModels(), const ProbeResult.timeout()]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.status, isNot(ConnectionStatus.ok));
    expect(snapshot.failureCause, isNull, reason: 'the key is fine');
    expect(snapshot.error, 'Usage unavailable');
    expect(snapshot.quotas, isEmpty);
  });

  test('a reshaped plan body keeps the last known quota', () async {
    // The endpoint is not in MiniMax's published OpenAPI, so a shape change is
    // the expected failure mode, not an exotic one. It must cost a number, not
    // a connection and not the cached value.
    final probe = _StubProbe([
      okModels(),
      const ProbeResult.response(
        statusCode: 200,
        body: '{"totally":"different"}',
      ),
    ]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.status, isNot(ConnectionStatus.ok));
    expect(snapshot.failureCause, isNull);
    expect(snapshot.quotas, isEmpty);
  });

  test('a key on a plan-free tier reports healthy with no quota', () async {
    // The genuine no-quota case, which is the opposite of a failure: the
    // endpoint answered correctly and says this key meters nothing. Wiping the
    // cache here is correct, because there is nothing to keep.
    final probe = _StubProbe([
      okModels(),
      const ProbeResult.response(
        statusCode: 200,
        body: '{"base_resp":{"status_code":0},"model_remains":[]}',
      ),
    ]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.status, ConnectionStatus.ok);
    expect(snapshot.quotas, isEmpty);
    expect(snapshot.error, isNull);
  });

  test(
    'sends the secret as a bearer token, never in the query string',
    () async {
      final probe = _StubProbe([okModels(), okPlan()]);

      await MiniMaxProvider(probe: probe).fetch(connection, 'sk-secret-value');

      expect(probe.sentSecrets, everyElement('sk-secret-value'));
      for (final uri in probe.requestedUris) {
        expect(
          uri.toString(),
          isNot(contains('sk-secret-value')),
          reason: 'a credential in a URL ends up in logs and proxy history',
        );
      }
    },
  );

  test(
    'a 401 is reported as an auth error, which is the gate working',
    () async {
      final probe = _StubProbe([
        const ProbeResult.response(
          statusCode: 401,
          body:
              '{"type":"error","error":{"type":"authorized_error",'
              '"http_code":"401"}}',
        ),
      ]);

      final snapshot = await MiniMaxProvider(probe: probe)
          .fetch(connection, 'sk-bad');

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.failureCause, isNotNull);
    },
  );

  test('a timeout is a timeout, not a generic failure', () async {
    final probe = _StubProbe([const ProbeResult.timeout()]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.error, 'Timeout');
  });

  test('a refused connection does not claim to be a timeout', () async {
    // The distinction is why ProviderHttpProbe exists: conflating the two
    // tells the user the wrong thing about why their number did not move.
    final probe = _StubProbe([const ProbeResult.transportFailure()]);

    final snapshot = await MiniMaxProvider(probe: probe)
        .fetch(connection, 'sk-key');

    expect(snapshot.error, isNot('Timeout'));
    expect(snapshot.status, ConnectionStatus.error);
  });

  group('test-before-save', () {
    test('succeeds for a valid key, with the plan windows attached', () async {
      final probe = _StubProbe([okModels(), okPlan()]);

      final result = await MiniMaxProvider(probe: probe)
          .test(connection, 'sk-key');

      expect(result.isSuccess, isTrue);
      expect(result.quotas, isNotEmpty);
    });

    test('fails for a rejected key', () async {
      final probe = _StubProbe([
        const ProbeResult.response(statusCode: 401, body: '{}'),
      ]);

      final result = await MiniMaxProvider(probe: probe)
          .test(connection, 'sk-bad');

      expect(result.isSuccess, isFalse);
      expect(result.error, 'Invalid API key');
    });
  });
}
