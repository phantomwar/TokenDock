import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../../services/refreshable_credential.dart';
import '../provider_adapter.dart';
import '../provider_http.dart';
import '../provider_status.dart';
import 'zai_usage_response.dart';

/// z.ai, the GLM Coding Plan.
///
/// ## Reports three independent meters
///
/// Requests, tokens and credits can each be metered over their own window, and
/// on a mixed plan the same window can appear twice under different meters.
/// They are all emitted, because showing only the request counter hides the one
/// that actually ran out.
///
/// ## The auth header is the raw key
///
/// z.ai sends `Authorization: <key>` with **no** `Bearer` prefix. The probe
/// takes a full header value for exactly this case; prefixing here would send
/// `Bearer <key>` and be rejected, so the credential is never actually verified.
/// The key is still never placed in the URL.
class ZaiProvider implements ProviderAdapter {
  ZaiProvider({ProviderHttpProbe? probe, Uri? usageEndpoint})
    : _probe = probe ?? ProviderHttpProbe(),
      _usageEndpoint = usageEndpoint ?? ZaiUsageResponse.quotaEndpoint;

  final ProviderHttpProbe _probe;
  final Uri _usageEndpoint;

  @override
  String get id => 'zai';

  @override
  String get name => 'z.ai';

  @override
  AuthKind get authKind => AuthKind.apiKey;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': secret,
  };

  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final result = await _probe.getJson(
      _usageEndpoint,
      secret: secret,
      authorization: secret,
    );
    final fetchedAt = DateTime.now().toUtc();

    if (result.isSuccess) {
      return ZaiUsageResponse.parse(
        connectionId: connection.id,
        body: result.body ?? '',
        fetchedAt: fetchedAt,
      );
    }

    return ProviderStatus.fromProbeResult(
      result: result,
      connectionId: connection.id,
      fetchedAt: fetchedAt,
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
