import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/zai/zai_provider.dart';
import 'package:tokendock/providers/provider_http.dart';

/// The provider half for z.ai.
///
/// `ZaiUsageResponse` is covered in its own test file. What matters here is the
/// transport contract: the endpoint, and above all the auth header, which is the
/// one place this provider differs from every other one.
class _StubProbe extends ProviderHttpProbe {
  _StubProbe(this._result) : super(client: null);

  final ProbeResult _result;

  final requestedUris = <Uri>[];
  final sentSecrets = <String>[];

  /// Nullable because the parameter is, and a provider that never sets it would
  /// otherwise look identical to one that sent `Bearer`.
  List<String?> sentAuthorization = [];

  @override
  Future<ProbeResult> getJson(
    Uri uri, {
    required String secret,
    Map<String, String> extraHeaders = const <String, String>{},
    String? authorization,
  }) async {
    requestedUris.add(uri);
    sentSecrets.add(secret);
    sentAuthorization.add(authorization);
    return _result;
  }
}

void main() {
  final connection = Connection(
    id: 'zai-1',
    provider: 'zai',
    displayName: 'z.ai',
    group: null,
    plan: null,
    credentialRef: 'ref',
    enabled: true,
  );

  ProbeResult okQuota() => const ProbeResult.response(
    statusCode: 200,
    body:
        '{"success":true,"code":0,"data":{"level":"pro","limits":['
        '{"type":"TIME_LIMIT","unit":3,"number":5,"usage":600,'
        '"currentValue":120,"remaining":480,"percentage":20,'
        '"nextResetTime":1789018000000}]}}',
  );

  test('calls the documented quota endpoint', () async {
    final probe = _StubProbe(okQuota());

    await ZaiProvider(probe: probe).fetch(connection, 'raw-key');

    expect(
      probe.requestedUris.single,
      Uri.parse('https://api.z.ai/api/monitor/usage/quota/limit'),
    );
  });

  test('sends the raw key with no Bearer prefix', () async {
    // This is the whole reason the probe takes a full header value. Prefixing
    // would send "Bearer <key>", which z.ai rejects, so the credential would
    // never actually be verified and the user would be told their key is bad.
    final probe = _StubProbe(okQuota());

    await ZaiProvider(probe: probe).fetch(connection, 'raw-key');

    expect(probe.sentAuthorization.single, 'raw-key');
    expect(
      probe.sentAuthorization.single,
      isNot(startsWith('Bearer')),
      reason: 'z.ai expects the raw key in Authorization',
    );
  });

  test('declares the same header for anything that inspects the adapter', () {
    // Kept in step with what fetch actually sends, so a caller building a
    // request by hand is not handed a Bearer token that the vendor rejects.
    expect(ZaiProvider().buildAuthHeader('raw-key'), {
      'Authorization': 'raw-key',
    });
  });

  test('never places the credential in the URL', () async {
    final probe = _StubProbe(okQuota());

    await ZaiProvider(probe: probe).fetch(connection, 'super-secret');

    expect(
      probe.requestedUris.single.toString(),
      isNot(contains('super-secret')),
      reason: 'a credential in a URL ends up in logs and proxy history',
    );
    expect(probe.sentSecrets.single, 'super-secret');
  });

  test(
    'a working key yields the plan windows, so total and remaining show',
    () async {
      final probe = _StubProbe(okQuota());

      final snapshot = await ZaiProvider(probe: probe)
          .fetch(connection, 'raw-key');

      expect(snapshot.status, ConnectionStatus.ok);
      final quota = snapshot.quotas.single;
      expect(quota.remaining, 480);
      expect(quota.limit, 600);
      expect(quota.percent, 20);
      expect(quota.unit, 'requests');
    },
  );

  test(
    'a rejection in the body fails the connection even behind HTTP 200',
    () async {
      // The gate is `success` in the body, not the status line.
      final probe = _StubProbe(
        const ProbeResult.response(
          statusCode: 200,
          body: '{"success":false,"code":1002,"msg":"unauthorized"}',
        ),
      );

      final snapshot = await ZaiProvider(probe: probe)
          .fetch(connection, 'bad-key');

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.failureCause, isNotNull);
    },
  );

  group('a failed call never costs the cached values', () {
    // RefreshService replaces the cached quota with whatever a snapshot carries,
    // so a healthy-but-empty result would blank the user's card.
    test('a timeout is a timeout and does not blame the key', () async {
      final probe = _StubProbe(const ProbeResult.timeout());

      final snapshot = await ZaiProvider(probe: probe)
          .fetch(connection, 'raw-key');

      expect(snapshot.error, 'Timeout');
      expect(snapshot.failureCause, isNull);
      expect(snapshot.status, isNot(ConnectionStatus.ok));
    });

    test('a 5xx is transient and does not blame the key', () async {
      final probe = _StubProbe(
        const ProbeResult.response(statusCode: 503, body: ''),
      );

      final snapshot = await ZaiProvider(probe: probe)
          .fetch(connection, 'raw-key');

      expect(snapshot.failureCause, isNull);
      expect(snapshot.error, 'Provider unavailable');
    });

    test('a 403 does not blame the key either', () async {
      // Forbidden, not rejected: the credential is fine and the account is not
      // entitled. Revoking here would make the user re-enter a working key.
      final probe = _StubProbe(
        const ProbeResult.response(statusCode: 403, body: '{}'),
      );

      final snapshot = await ZaiProvider(probe: probe)
          .fetch(connection, 'raw-key');

      expect(snapshot.status, isNot(ConnectionStatus.authError));
      expect(snapshot.failureCause, isNull);
    });

    test('a 401 does revoke it', () async {
      final probe = _StubProbe(
        const ProbeResult.response(statusCode: 401, body: '{}'),
      );

      final snapshot = await ZaiProvider(probe: probe)
          .fetch(connection, 'bad-key');

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.failureCause, isNotNull);
    });
  });

  group('test-before-save', () {
    test('succeeds for a valid key, with the quota attached', () async {
      final probe = _StubProbe(okQuota());

      final result = await ZaiProvider(probe: probe)
          .test(connection, 'raw-key');

      expect(result.isSuccess, isTrue);
      expect(result.quotas, isNotEmpty);
    });

    test('fails for a rejected key', () async {
      final probe = _StubProbe(
        const ProbeResult.response(statusCode: 401, body: '{}'),
      );

      final result = await ZaiProvider(probe: probe)
          .test(connection, 'bad-key');

      expect(result.isSuccess, isFalse);
      expect(result.error, 'Invalid API key');
    });
  });
}
