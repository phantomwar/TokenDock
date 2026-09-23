import 'quota.dart';

class TestResult {
  const TestResult({
    required this.isSuccess,
    required this.plan,
    required this.quotas,
    required this.error,
    this.replacementSecret,
  });

  factory TestResult.success({
    String? plan,
    List<Quota> quotas = const [],
    String? replacementSecret,
  }) {
    return TestResult(
      isSuccess: true,
      plan: plan,
      quotas: quotas,
      error: null,
      replacementSecret: replacementSecret,
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
}
