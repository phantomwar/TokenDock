import '../models/connection.dart';
import '../models/provider_snapshot.dart';
import '../models/test_result.dart';
import '../services/refreshable_credential.dart';
enum AuthKind { apiKey, oauth, structuredBearer, none }


abstract interface class ProviderAdapter {
  String get id;
  String get name;
  AuthKind get authKind;
  Map<String, String> buildAuthHeader(String secret) =>
      {'Authorization': 'Bearer $secret'};
  Future<TestResult> test(Connection connection, String secret);
  Future<ProviderSnapshot> fetch(Connection connection, String secret);
  /// Optional refreshable credential factory for OAuth adapters.
  RefreshableCredential? refreshableCredential(String secret) => null;
}
