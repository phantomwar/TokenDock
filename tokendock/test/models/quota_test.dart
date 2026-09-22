import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/quota.dart';

void main() {
  test('null limit-related values are representable without coercion', () {
    const quota = Quota(
      id: 'key-limit',
      label: 'Key limit',
      percent: null,
      remaining: null,
      limit: null,
      unit: 'USD',
      resetAt: null,
    );

    expect(quota.percent, isNull);
    expect(quota.remaining, isNull);
    expect(quota.limit, isNull);
    expect(quota.unit, 'USD');
  });

  test('provided values are retained', () {
    final resetAt = DateTime.utc(2026, 9, 22, 12);
    final quota = Quota(
      id: 'key-limit',
      label: 'Key limit',
      percent: 72,
      remaining: 2.8,
      limit: 10,
      unit: 'USD',
      resetAt: resetAt,
    );

    expect(quota.id, 'key-limit');
    expect(quota.label, 'Key limit');
    expect(quota.percent, 72);
    expect(quota.remaining, 2.8);
    expect(quota.limit, 10);
    expect(quota.unit, 'USD');
    expect(quota.resetAt, resetAt);
  });
}
