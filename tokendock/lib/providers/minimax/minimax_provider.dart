import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../provider_adapter.dart';
import '../provider_http.dart';
import '../../services/refreshable_credential.dart';
import 'minimax_response.dart';

/// MiniMax, via its OpenAI-compatible API.
///
/// ## What this adapter can and cannot tell you
///
/// It **can** verify a credential. `GET /v1/models` returns 401 for a bad key,
/// which was confirmed against the live endpoint, so the test-before-save gate
/// is a real gate here. That is why this provider exists and why
/// `OpenCodeZen`/`OpenCodeGo` do not -- see the note in `provider_registry.dart`.
///
/// It **cannot** report usage. MiniMax publishes no balance, usage or quota
/// endpoint anywhere in its documented API surface. The Token Plan quota "is
/// shown as a usage bar in the console" and pay-as-you-go draws down a console
/// balance. So the snapshot carries connection health and an empty quota list,
/// and the widget shows a healthy account with no usage row. Emitting a number
/// here would mean inventing it and showing it to the user as fact.
class MiniMaxProvider implements ProviderAdapter {
  MiniMaxProvider({ProviderHttpProbe? probe, Uri? endpoint})
    : _probe = probe ?? ProviderHttpProbe(),
      _endpoint = endpoint ?? defaultEndpoint;

  final ProviderHttpProbe _probe;
  final Uri _endpoint;

  /// The vendor's own OpenAPI document names `https://api.minimax.io` as the
  /// server for `GET /v1/models`.
  static final Uri defaultEndpoint = Uri.parse(
    'https://api.minimax.io/v1/models',
  );

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
    final result = await _probe.getJson(_endpoint, secret: secret);
    final fetchedAt = DateTime.now().toUtc();

    if (result.isSuccess) {
      return MiniMaxResponse.parseModels(
        connectionId: connection.id,
        body: result.body ?? '',
        fetchedAt: fetchedAt,
      );
    }

    return MiniMaxResponse.mapError(
      connectionId: connection.id,
      fetchedAt: fetchedAt,
      statusCode: result.statusCode,
      body: result.body,
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
