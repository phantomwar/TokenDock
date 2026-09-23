import 'dart:convert';
import 'dart:io';

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

  static ({ConnectionStatus status, String error}) mapHttpStatus(
    int statusCode,
  ) {
    if (statusCode == 401) {
      return (status: ConnectionStatus.authError, error: 'Invalid API key');
    }
    if (statusCode == 403) {
      return (status: ConnectionStatus.error, error: 'Forbidden');
    }
    if (statusCode == 402) {
      return (status: ConnectionStatus.limited, error: 'Insufficient credits');
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
    DateTime? cooldownUntil,
  }) {
    return ProviderSnapshot(
      connectionId: connectionId,
      status: status,
      quotas: const [],
      balance: null,
      fetchedAt: fetchedAt,
      error: error,
      cooldownUntil: cooldownUntil,
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
    String? retryAfter,
  }) {
    if (isTimeout) {
      return timeoutSnapshot(connectionId: connectionId, fetchedAt: fetchedAt);
    }

    int? bodyStatusCode;
    String? limitSource;
    if (body != null) {
      try {
        final dynamic decoded = jsonDecode(body);
        if (decoded is Map && decoded['error'] is Map) {
          final error = decoded['error'] as Map;
          final code = error['code'];
          if (code is int) bodyStatusCode = code;
          final metadata = error['metadata'];
          if (metadata is Map && metadata['limit_source'] is String) {
            limitSource = metadata['limit_source'] as String;
          }
        }
      } catch (_) {}
    }

    final effectiveStatusCode = statusCode ?? bodyStatusCode;
    final retryAt = _parseRetryAfter(retryAfter, fetchedAt);
    if (effectiveStatusCode == 402 &&
        limitSource == 'openrouter_in_flight_budget' &&
        retryAt != null) {
      return errorSnapshot(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
        status: ConnectionStatus.warning,
        error: 'Rate limited',
        cooldownUntil: retryAt,
      );
    }

    if (effectiveStatusCode != null) {
      final mapped = mapHttpStatus(effectiveStatusCode);
      final honorsRetryAfter =
          effectiveStatusCode == 429 || effectiveStatusCode == 503;
      return errorSnapshot(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
        status: mapped.status,
        error: mapped.error,
        cooldownUntil: honorsRetryAfter ? retryAt : null,
      );
    }

    return malformedSnapshot(connectionId: connectionId, fetchedAt: fetchedAt);
  }

  static DateTime? _parseRetryAfter(String? value, DateTime fetchedAt) {
    final header = value?.trim();
    if (header == null || header.isEmpty) return null;

    final seconds = int.tryParse(header);
    if (seconds != null) {
      if (seconds <= 0) return null;
      try {
        return fetchedAt.toUtc().add(Duration(seconds: seconds));
      } catch (_) {
        return null;
      }
    }

    try {
      final retryAt = HttpDate.parse(header).toUtc();
      return retryAt.isAfter(fetchedAt) ? retryAt : null;
    } catch (_) {
      return null;
    }
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
