import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';

void main() {
  test('stale cache retains its known quota while status changes', () {
    final snapshot = ProviderSnapshot(
      connectionId: 'connection-a',
      status: ConnectionStatus.error,
      quotas: const [
        Quota(
          id: 'key-limit',
          label: 'Key limit',
          percent: 72,
          remaining: 2.8,
          limit: 10,
          unit: 'USD',
          resetAt: null,
        ),
      ],
      balance: null,
      fetchedAt: DateTime.utc(2026, 9, 22, 12),
      error: 'Provider unavailable',
    );

    expect(snapshot.quotas.single.percent, 72);
    expect(snapshot.status, ConnectionStatus.error);
  });
}
