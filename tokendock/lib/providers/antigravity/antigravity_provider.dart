import '../../models/connection.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../provider_adapter.dart';
import 'antigravity_local.dart';

class AntigravityProvider implements ProviderAdapter {
  AntigravityProvider({AntigravityLocalReader? reader}) : _reader = reader ?? AntigravityLocalReader();

  final AntigravityLocalReader _reader;

  @override
  String get id => 'antigravity';

  @override
  String get name => 'Antigravity';

  @override
  AuthKind get authKind => AuthKind.none;

  @override
  Map<String, String> buildAuthHeader(String secret) => const {};

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    final snapshot = await _reader.fetchSnapshot(connection);
    if (snapshot.error == null) {
      return TestResult.success(quotas: snapshot.quotas, plan: connection.plan);
    }
    return TestResult.failure(error: snapshot.error!);
  }

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) =>
      _reader.fetchSnapshot(connection);
}
