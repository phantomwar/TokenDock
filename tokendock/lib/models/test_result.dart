import 'quota.dart';

class TestResult {
  const TestResult({
    required this.isSuccess,
    required this.plan,
    required this.quotas,
    required this.error,
    this.replacementSecret,
    this.schemaRevalidated = false,
  });

  factory TestResult.success({
    String? plan,
    List<Quota> quotas = const [],
    String? replacementSecret,
    bool schemaRevalidated = false,
  }) {
    return TestResult(
      isSuccess: true,
      plan: plan,
      quotas: quotas,
      replacementSecret: replacementSecret,
      schemaRevalidated: schemaRevalidated,
      error: null,
    );
  }

  factory TestResult.failure({required String error, String? replacementSecret}) {
    return TestResult(
      isSuccess: false,
      plan: null,
      quotas: const [],
      error: error,
      replacementSecret: replacementSecret,
    );
  }

  final bool isSuccess;
  final String? plan;
  final List<Quota> quotas;
  final String? error;

  /// Secret returned by a provider test when probing rotated it. When set,
  /// callers must persist this value instead of the original input secret.
  final String? replacementSecret;

  /// A successful explicit provider test revalidated a quarantined schema.
  /// Persistence happens with the connection edit so stale UI metadata cannot
  /// restore the quarantine.
  final bool schemaRevalidated;
}
