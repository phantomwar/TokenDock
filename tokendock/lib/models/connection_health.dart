import 'connection_status.dart';

class ConnectionHealth {
  const ConnectionHealth({
    required this.connectionId,
    required this.status,
    required this.lastCheckedAt,
    required this.cooldownUntil,
    required this.error,
  });

  final String connectionId;
  final ConnectionStatus status;
  final DateTime lastCheckedAt;
  final DateTime? cooldownUntil;
  final String? error;
}
