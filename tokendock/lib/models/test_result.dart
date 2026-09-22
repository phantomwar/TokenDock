import 'quota.dart';

class TestResult {
  const TestResult({
    required this.isSuccess,
    required this.plan,
    required this.quotas,
    required this.error,
  });

  factory TestResult.success({String? plan, List<Quota> quotas = const []}) {
    return TestResult(
      isSuccess: true,
      plan: plan,
      quotas: quotas,
      error: null,
    );
  }

  factory TestResult.failure({required String error}) {
    return TestResult(
      isSuccess: false,
      plan: null,
      quotas: const [],
      error: error,
    );
  }

  final bool isSuccess;
  final String? plan;
  final List<Quota> quotas;
  final String? error;
}
