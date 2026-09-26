import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../../services/refreshable_credential.dart';
import '../provider_adapter.dart';
import '../provider_http.dart';
import 'opencode_usage_response.dart';

/// OpenCode Go, the $10/month subscription tier.
///
/// ## What it reports
///
/// Three windows the plan meters independently -- 5-hour, weekly and monthly --
/// so the user can see which one is actually binding. Go falls back to free
/// models when a limit is reached, and optionally to the Zen balance, so an
/// exhausted window is not the end of the connection.
///
/// ## Provenance, and the risk that comes with it
///
/// The usage endpoint `GET /zen/go/v1/usage` is first-party but
/// **undocumented**; the reference implementation records that its shape
/// "changed once on merge day". It is parsed all-or-nothing so a reshape costs
/// the user a number rather than showing them a wrong one, and a test pins
/// that. Re-check `opencode_usage_response.dart` against the vendor before
/// trusting a number.
///
/// ## Why this provider exists when the `/models` listing cannot gate
///
/// `GET /zen/go/v1/models` answers 200 for an invalid key, so it is useless as a
/// credential check. This endpoint does enforce it: 401 for a bad key, 403 for a
/// valid key with no Go subscription.
class OpenCodeGoProvider implements ProviderAdapter {
  OpenCodeGoProvider({ProviderHttpProbe? probe, Uri? usageEndpoint})
    : _probe = probe ?? ProviderHttpProbe(),
      _usageEndpoint = usageEndpoint ?? OpenCodeUsageResponse.usageEndpoint;

  final ProviderHttpProbe _probe;
  final Uri _usageEndpoint;

  @override
  String get id => 'opencode-go';

  @override
  String get name => 'OpenCode Go';

  @override
  AuthKind get authKind => AuthKind.apiKey;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };

  /// Go expects clients to identify themselves and to carry a stable session
  /// header; without them it treats the traffic as unrecognised.
  ///
  /// The session id has to be stable per conversation for OpenCode to optimise
  /// routing and prompt caching, so it is derived from the connection rather
  /// than randomised per call.
  static String sessionIdFor(String connectionId) =>
      connectionId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');

  /// A real user agent rather than a bare SDK name; Go flags generic agents.
  static const String userAgent = 'tokendock/0.1 (windows)';

  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final result = await _probe.getJson(
      _usageEndpoint,
      secret: secret,
      extraHeaders: <String, String>{
        'User-Agent': userAgent,
        'x-opencode-session': sessionIdFor(connection.id),
      },
    );
    final fetchedAt = DateTime.now().toUtc();

    if (result.isSuccess) {
      return OpenCodeUsageResponse.parse(
        connectionId: connection.id,
        body: result.body ?? '',
        fetchedAt: fetchedAt,
      );
    }

    return OpenCodeUsageResponse.mapError(
      connectionId: connection.id,
      fetchedAt: fetchedAt,
      statusCode: result.statusCode,
      isTimeout: result.isTimeout,
    );
  }

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    final snapshot = await fetch(connection, secret);
    if (snapshot.status == ConnectionStatus.ok) {
      return TestResult.success(quotas: snapshot.quotas, plan: connection.plan);
    }
    return TestResult.failure(error: snapshot.error ?? 'Connection failed');
  }
}
