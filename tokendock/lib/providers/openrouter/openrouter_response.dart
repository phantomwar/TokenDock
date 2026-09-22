import 'dart:convert';

import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/quota.dart';

class OpenRouterResponse {
  const OpenRouterResponse._();

  static ProviderSnapshot parseKey({
    required String connectionId,
    required String body,
    required DateTime fetchedAt,
  }) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return malformedSnapshot(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      if (decoded.containsKey('error')) {
        final errorObj = decoded['error'];
        final code = errorObj is Map ? errorObj['code'] : null;
        if (code is int) {
          final mapped = mapHttpStatus(code);
          return errorSnapshot(
            connectionId: connectionId,
            fetchedAt: fetchedAt,
            status: mapped.status,
            error: mapped.error,
          );
        }
        return malformedSnapshot(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      final data = decoded['data'];
      if (data is! Map<String, dynamic>) {
        return malformedSnapshot(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      final rawLimit = data['limit'];
      final rawRemaining = data['limit_remaining'];
      final rawReset = data['limit_reset'];

      double? limit;
      double? remaining;
      double? percent;

      if (rawLimit is num && rawRemaining is num && rawLimit > 0) {
        limit = rawLimit.toDouble();
        remaining = rawRemaining.toDouble();
        percent = ((limit - remaining) / limit * 100).clamp(0.0, 100.0);
      }

      final resetAt = _parseResetAt(rawReset);

      final quota = Quota(
        id: 'key-limit',
        label: 'Key limit',
        percent: percent,
        remaining: remaining,
        limit: limit,
        unit: 'USD',
        resetAt: resetAt,
      );

      return ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.ok,
        quotas: [quota],
        balance: null,
        fetchedAt: fetchedAt,
        error: null,
      );
    } catch (_) {
      return malformedSnapshot(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    }
  }

  static ({ConnectionStatus status, String error}) mapHttpStatus(int statusCode) {
    if (statusCode == 401 || statusCode == 403) {
      return (status: ConnectionStatus.authError, error: 'Invalid API key');
    }
    if (statusCode == 402) {
      return (status: ConnectionStatus.limited, error: 'Key limit exceeded');
    }
    if (statusCode == 429) {
      return (status: ConnectionStatus.warning, error: 'Rate limited');
    }
    if (statusCode >= 500 && statusCode <= 599) {
      return (status: ConnectionStatus.error, error: 'Provider unavailable');
    }
    return (status: ConnectionStatus.error, error: 'Unknown response');
  }

  static ProviderSnapshot errorSnapshot({
    required String connectionId,
    required DateTime fetchedAt,
    required ConnectionStatus status,
    required String error,
  }) {
    return ProviderSnapshot(
      connectionId: connectionId,
      status: status,
      quotas: const [],
      balance: null,
      fetchedAt: fetchedAt,
      error: error,
    );
  }

  static ProviderSnapshot timeoutSnapshot({
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    return errorSnapshot(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: ConnectionStatus.error,
      error: 'Timeout',
    );
  }

  static ProviderSnapshot malformedSnapshot({
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    return errorSnapshot(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: ConnectionStatus.error,
      error: 'Unknown response',
    );
  }

  static ProviderSnapshot mapError({
    required String connectionId,
    required DateTime fetchedAt,
    int? statusCode,
    bool isTimeout = false,
    String? body,
  }) {
    if (isTimeout) {
      return timeoutSnapshot(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    }
    if (body != null) {
      try {
        final dynamic decoded = jsonDecode(body);
        if (decoded is Map && decoded['error'] is Map) {
          final err = decoded['error'] as Map;
          final code = err['code'];
          if (code is int) {
            final mapped = mapHttpStatus(code);
            return errorSnapshot(
              connectionId: connectionId,
              fetchedAt: fetchedAt,
              status: mapped.status,
              error: mapped.error,
            );
          }
        }
      } catch (_) {}
    }
    if (statusCode != null) {
      final mapped = mapHttpStatus(statusCode);
      return errorSnapshot(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
        status: mapped.status,
        error: mapped.error,
      );
    }
    return malformedSnapshot(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
    );
  }

  static DateTime? _parseResetAt(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      final millis = value > 100000000000
          ? value.toInt()
          : (value * 1000).toInt();
      if (millis <= 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
    }
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      final asNum = num.tryParse(trimmed);
      if (asNum != null) {
        return _parseResetAt(asNum);
      }
      final parsed = DateTime.tryParse(trimmed);
      return parsed?.toUtc();
    }
    return null;
  }
}
