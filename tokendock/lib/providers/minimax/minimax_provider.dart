import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../../services/refreshable_credential.dart';
import '../provider_adapter.dart';
import '../provider_http.dart';
import 'minimax_response.dart';
import 'minimax_usage_response.dart';

/// MiniMax, via its OpenAI-compatible API.
///
/// ## Two endpoints, because MiniMax splits them
///
/// - `GET /v1/models` returns 401 for a bad key, so it is the honest
///   test-before-save probe, and it is what the gate uses.
/// - `GET /v1/token_plan/remains` carries the Token Plan windows, and **answers
///   HTTP 200 even for a rejected credential**. The real success signal is
///   `base_resp.status_code === 0`. Trusting the HTTP status there would report a
///   pristine quota for a key that does not work, which is worse than reporting
///   nothing.
///
/// The two answers are used for different purposes, so a key that authenticates
/// but whose plan endpoint is unreachable still shows as a healthy connection.
///
/// ## Provenance
///
/// The usage response shape was ported from a working implementation rather than
/// guessed: `packages/ai/src/usage/minimax-code.ts` in `can1357/oh-my-pi`. It is
/// not in MiniMax's published OpenAPI, so it is parsed defensively and a shape
/// change degrades to "no quota shown" rather than to a wrong number.
class MiniMaxProvider implements ProviderAdapter {
  MiniMaxProvider({ProviderHttpProbe? probe, Uri? modelsEndpoint})
    : _probe = probe ?? ProviderHttpProbe(),
      _modelsEndpoint = modelsEndpoint ?? MiniMaxResponse.defaultModelsEndpoint;

  final ProviderHttpProbe _probe;
  final Uri _modelsEndpoint;

  @override
  String get id => 'minimax';

  @override
  String get name => 'MiniMax';

  @override
  AuthKind get authKind => AuthKind.apiKey;

  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer $secret',
  };

  @override
  RefreshableCredential? refreshableCredential(String secret) => null;

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final fetchedAt = DateTime.now().toUtc();

    // The gate runs first, and its failure ends the fetch. A rejected key must
    // not then be followed by a usage call, and a transport failure should not
    // be spent twice waiting out a second timeout to find out.
    final gate = await _probe.getJson(_modelsEndpoint, secret: secret);
    if (!gate.isSuccess) {
      return MiniMaxResponse.mapError(
        connectionId: connection.id,
        fetchedAt: fetchedAt,
        statusCode: gate.statusCode,
        body: gate.body,
        isTimeout: gate.isTimeout,
      );
    }

    // Usage is best effort, with one hard exception. A malformed or unreachable
    // plan body must NOT be reported as a healthy empty result: `RefreshService`
    // replaces the cached quota with whatever comes back, so "ok, no quotas"
    // would blank the user's card because the plan endpoint hiccuped. Returning
    // the malformed snapshot takes the error path, which keeps the last known
    // values and shows the age they were fetched.
    final usage = await _probe.getJson(
      MiniMaxUsageResponse.remainsEndpoint,
      secret: secret,
    );
    if (usage.isSuccess) {
      // This single return covers both interesting cases. A definitive rejection
      // is evidence and outranks the 200 the gate just saw, because this
      // endpoint answers 200 for rejected credentials by design. A reshape is
      // absence of evidence, and is reported as such.
      return MiniMaxUsageResponse.parse(
        connectionId: connection.id,
        body: usage.body ?? '',
        fetchedAt: fetchedAt,
      );
    }

    return MiniMaxUsageResponse.unreadable(
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
