import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/refreshable_credential.dart';

class _Fake implements RefreshableCredential {
  final DateTime? expiresAt = DateTime.utc(2026, 9, 23, 12);
  int calls = 0;

  @override
  Duration get refreshLead => const Duration(minutes: 1);

  @override
  Future<String> refresh(String currentSecret) async {
    calls++;
    return 'new-$currentSecret';
  }
}

void main() {
  test('contract exposes expiry, lead, and refresh', () async {
    final credential = _Fake();

    expect(credential.expiresAt, DateTime.utc(2026, 9, 23, 12));
    expect(credential.refreshLead, const Duration(minutes: 1));
    expect(await credential.refresh('a'), 'new-a');
    expect(credential.calls, 1);
  });
}
