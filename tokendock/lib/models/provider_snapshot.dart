import 'connection_status.dart';
import 'quota.dart';

class ProviderSnapshot {
  const ProviderSnapshot({
    required this.connectionId,
    required this.status,
    required this.quotas,
    required this.balance,
    required this.fetchedAt,
    required this.error,
    this.cooldownUntil,
  });

  final String connectionId;
  final ConnectionStatus status;
  final List<Quota> quotas;
  final double? balance;
  final DateTime fetchedAt;
  final String? error;
  final DateTime? cooldownUntil;
}
