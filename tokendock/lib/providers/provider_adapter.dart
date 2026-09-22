import '../models/connection.dart';
import '../models/provider_snapshot.dart';
import '../models/test_result.dart';

abstract interface class ProviderAdapter {
  String get id;
  String get name;
  Future<TestResult> test(Connection connection, String secret);
  Future<ProviderSnapshot> fetch(Connection connection, String secret);
}
