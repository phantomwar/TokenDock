import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/opencode/opencode_go_provider.dart';
import 'package:tokendock/providers/provider_http.dart';

/// The provider half for OpenCode Go.
///
/// `OpenCodeUsageResponse` is covered in its own test file. What matters here is
/// the transport contract Go imposes: the endpoint that actually gates, the two
/// headers it requires, and that a 403 is not treated as a dead credential.
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
    id: 'conn-1',
    provider: 'opencode-go',
    displayName: 'OpenCode Go',
    group: null,
    plan: null,
    credentialRef: 'ref',
    enabled: true,
  );

  String window({String status = 'ok', int percent = 40}) =>
      '{"status":"$status","percent":$percent,'
      '"resetsAt":"2026-09-26T17:00:00.000Z"}';

  ProbeResult okUsage() => ProbeResult.response(
    statusCode: 200,
    body:
        '{"usage":{"rolling":${window(percent: 80)},'
        '"weekly":${window(percent: 45)},'
        '"monthly":${window(percent: 20)}}}',
  );

  test('calls the usage endpoint, not the model listing', () async {
    // The listing answers 200 for a garbage key, so probing it would mean
    // shipping test-before-save that always passes.
    final probe = _StubProbe([okUsage()]);

    await OpenCodeGoProvider(probe: probe).fetch(connection, 'sk-key');

    expect(
      probe.requestedUris.single,
      Uri.parse('https://opencode.ai/zen/go/v1/usage'),
    );
    expect(
      probe.requestedUris.single,
      isNot(contains('models')),
      reason: 'this endpoint cannot tell a good key from a bad one',
    );
  });

  test('sends the session header Go requires, and a real user agent', () async {
    final probe = _StubProbe([okUsage()]);

    await OpenCodeGoProvider(probe: probe).fetch(connection, 'sk-key');

    final headers = probe.sentHeaders.single;
    expect(
      headers['x-opencode-session'],
      isNotNull,
      reason: 'Go treats traffic without a stable session id as unrecognised',
    );
    expect(headers['x-opencode-session'], isNotEmpty);
    expect(headers['User-Agent'], OpenCodeGoProvider.userAgent);
    expect(headers['User-Agent'], isNotEmpty);
  });

  test('the session id is stable across refreshes', () async {
    // A random per-call value would defeat the routing and prompt caching the
    // header exists for, and would look like a new conversation every tick.
    final probe = _StubProbe([okUsage(), okUsage(), okUsage()]);
    final provider = OpenCodeGoProvider(probe: probe);

    await provider.fetch(connection, 'sk-key');
    await provider.fetch(connection, 'sk-key');
    await provider.fetch(connection, 'sk-key');

    final ids = probe.sentHeaders.map((h) => h['x-opencode-session']).toSet();
    expect(ids, hasLength(1));
  });

  test(
    'the session id is header-safe whatever the connection id contains',
    () async {
      // Connection ids reach this as user-visible names in some paths, and an
      // unescaped value would corrupt the header rather than fail loudly.
      for (final raw in <String>[
        'plain-id',
        'with space',
        'ação-ç',
        'quote"inject',
        'new\nline',
      ]) {
        final id = OpenCodeGoProvider.sessionIdFor(raw);
        expect(id, isNotEmpty, reason: 'id was "$raw"');
        expect(
          id,
          matches(RegExp(r'^[A-Za-z0-9_-]+$')),
          reason: 'id was "$raw"',
        );
      }
    },
  );

  test(
    'sends the secret as a bearer token, never in the query string',
    () async {
      final probe = _StubProbe([okUsage()]);

      await OpenCodeGoProvider(probe: probe)
          .fetch(connection, 'sk-secret-value');

      expect(probe.sentSecrets.single, 'sk-secret-value');
      expect(
        probe.requestedUris.single.toString(),
        isNot(contains('sk-secret-value')),
        reason: 'a credential in a URL ends up in logs and proxy history',
      );
    },
  );

  test(
    'a working key yields all three windows, so the binding one is visible',
    () async {
      final probe = _StubProbe([okUsage()]);

      final snapshot = await OpenCodeGoProvider(probe: probe)
          .fetch(connection, 'sk-key');

      expect(snapshot.status, ConnectionStatus.ok);
      expect(
        {for (final q in snapshot.quotas) q.id},
        <String>{'5h', '7d', 'monthly'},
      );
      final monthly = snapshot.quotas.firstWhere((q) => q.id == 'monthly');
      expect(monthly.remaining, 80);
    },
  );

  group('the gate is real', () {
    test('401 revokes the credential', () async {
      final probe = _StubProbe([
        const ProbeResult.response(statusCode: 401, body: '{}'),
      ]);

      final snapshot = await OpenCodeGoProvider(probe: probe)
          .fetch(connection, 'sk-bad');

      expect(snapshot.status, ConnectionStatus.authError);
      expect(
        snapshot.failureCause,
        isNotNull,
        reason: 'otherwise RefreshService retries a dead key forever',
      );
    });

    test('403 does not revoke the credential', () async {
      // Forbidden, not rejected: the key works, the account just has no Go
      // subscription. Telling the user to re-enter a working key is wrong.
      final probe = _StubProbe([
        const ProbeResult.response(statusCode: 403, body: '{}'),
      ]);

      final snapshot = await OpenCodeGoProvider(probe: probe)
          .fetch(connection, 'sk-key');

      expect(snapshot.status, isNot(ConnectionStatus.authError));
      expect(snapshot.failureCause, isNull);
      expect(snapshot.error, 'Forbidden');
    });

    test('5xx is transient and does not revoke the credential', () async {
      final probe = _StubProbe([
        const ProbeResult.response(statusCode: 503, body: ''),
      ]);

      final snapshot = await OpenCodeGoProvider(probe: probe)
          .fetch(connection, 'sk-key');

      expect(snapshot.failureCause, isNull);
    });
  });

  group('cache preservation', () {
    // RefreshService replaces the cached quota with whatever comes back, so a
    // non-ok result is what keeps the last known figures on screen.
    test(
      'a reshaped body keeps the cached values rather than blanking the card',
      () async {
        final probe = _StubProbe([
          const ProbeResult.response(
            statusCode: 200,
            body: '{"usage":{"rolling":{"status":"ok"}}}',
          ),
        ]);

        final snapshot = await OpenCodeGoProvider(probe: probe)
            .fetch(connection, 'sk-key');

        expect(snapshot.status, isNot(ConnectionStatus.ok));
        expect(snapshot.quotas, isEmpty);
        expect(snapshot.failureCause, isNull);
      },
    );

    test('a timeout is a timeout, and does not blame the key', () async {
      final probe = _StubProbe([const ProbeResult.timeout()]);

      final snapshot = await OpenCodeGoProvider(probe: probe)
          .fetch(connection, 'sk-key');

      expect(snapshot.error, 'Timeout');
      expect(snapshot.failureCause, isNull);
    });
  });

  group('test-before-save', () {
    test('succeeds for a valid key, with the windows attached', () async {
      final probe = _StubProbe([okUsage()]);

      final result = await OpenCodeGoProvider(probe: probe)
          .test(connection, 'sk-key');

      expect(result.isSuccess, isTrue);
      expect(result.quotas, isNotEmpty);
    });

    test('fails for a rejected key', () async {
      final probe = _StubProbe([
        const ProbeResult.response(statusCode: 401, body: '{}'),
      ]);

      final result = await OpenCodeGoProvider(probe: probe)
          .test(connection, 'sk-bad');

      expect(result.isSuccess, isFalse);
      expect(result.error, 'Invalid API key');
    });

    test('fails for a key with no Go subscription', () async {
      final probe = _StubProbe([
        const ProbeResult.response(statusCode: 403, body: '{}'),
      ]);

      final result = await OpenCodeGoProvider(probe: probe)
          .test(connection, 'sk-key');

      expect(result.isSuccess, isFalse);
    });
  });
}
