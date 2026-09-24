import 'connection.dart';
import 'connection_status.dart';
import 'quota.dart';


enum ProviderFailureCause {
  onboardingRequired,
  accountMismatch,
  quotaSourceChanged,
  forbidden,
  transport,
  transient,
  invalidCredential,
}
class ProviderSnapshot {
  const ProviderSnapshot({
    required this.connectionId,
    required this.status,
    required this.quotas,
    required this.balance,
    required this.fetchedAt,
    required this.error,
    this.cooldownUntil,
    this.failureCause,
    this.connection,
  });

  final String connectionId;
  final ConnectionStatus status;
  final List<Quota> quotas;
  final double? balance;
  final DateTime fetchedAt;
  final String? error;
  final DateTime? cooldownUntil;
  final ProviderFailureCause? failureCause;

  /// Current persisted connection when a refresh rotated its credential.
  final Connection? connection;

  ProviderSnapshot copyWith({Connection? connection}) => ProviderSnapshot(
        connectionId: connectionId,
        status: status,
        quotas: quotas,
        balance: balance,
        fetchedAt: fetchedAt,
        error: error,
        cooldownUntil: cooldownUntil,
        failureCause: failureCause,
        connection: connection ?? this.connection,
      );
}
