import 'dart:convert';

import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/quota.dart';
import '../provider_status.dart';

/// Parses z.ai / GLM Coding Plan usage from
/// `GET https://api.z.ai/api/monitor/usage/quota/limit`.
///
/// The response shape was ported from a working implementation rather than
/// guessed: `packages/ai/src/usage/zai.ts` in `can1357/oh-my-pi`.
///
/// ## Three properties that shape this parser
///
/// **The body is the authority.** `success` is the real success signal, so a
/// `success: false` carrying an error `code` must never read as an empty quota.
/// A parser that trusted HTTP alone would show a pristine plan for a key that
/// does not work.
///
/// **`percentage` is server-rounded.** 1438 of 12000 credits is reported as
/// `11`, not `11.98`. So an exact ratio is preferred wherever both absolutes
/// are present, and `percentage` is only the fallback.
///
/// **The window is encoded, not named.** `unit` is an enum and `number` is the
/// count, so "5 hours" is `unit: 3, number: 5`. Hardcoding "5h" would be wrong
/// on any other tier.
class ZaiUsageResponse {
  const ZaiUsageResponse._();

  static const String baseUrl = 'https://api.z.ai';

  static const String quotaPath = '/api/monitor/usage/quota/limit';

  static Uri get quotaEndpoint => Uri.parse('$baseUrl$quotaPath');

  /// `unit`: how the window length is expressed. `number` scales it.
  static const int _unitHours = 3;
  static const int _unitDays = 4;
  static const int _unitMonths = 5;
  static const int _unitWeek = 6;

  static const String _typeTime = 'TIME_LIMIT';
  static const String _typeTokens = 'TOKENS_LIMIT';
  static const String _typeCredits = 'CREDIT_LIMIT';

  static ProviderSnapshot parse({
    required String connectionId,
    required String body,
    required DateTime fetchedAt,
  }) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      // Absent is not false, and absent is not success. Guessing either way is
      // how a dead key ends up looking like a pristine plan.
      final success = decoded['success'];
      if (success is! bool) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }
      if (!success) {
        return ProviderStatus.failure(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
          status: ConnectionStatus.authError,
          error: 'Invalid API key',
        );
      }

      final data = decoded['data'];
      final limits = data is Map ? data['limits'] : null;
      if (limits is! List) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      final quotas = <Quota>[];
      for (final entry in limits) {
        if (entry is! Map) continue;
        final quota = _decodeLimit(entry);
        if (quota != null) quotas.add(quota);
      }

      // A valid key with nothing metered. Not an error, and deliberately not a
      // zeroed quota.
      return ProviderStatus.ok(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
        quotas: quotas,
      );
    } catch (_) {
      return ProviderStatus.malformed(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    }
  }

  /// One `limits[]` entry, or null when it is not a type we meter or carries no
  /// usable number.
  static Quota? _decodeLimit(Map<Object?, Object?> raw) {
    final type = raw['type'];
    if (type is! String || type.isEmpty) return null;

    final String idPrefix;
    final String unit;
    switch (type) {
      case _typeTime:
        idPrefix = 'requests';
        unit = 'requests';
      case _typeTokens:
        idPrefix = 'tokens';
        unit = 'tokens';
      case _typeCredits:
        idPrefix = 'credits';
        unit = 'credits';
      default:
        // A future type. Ignoring it costs the user one row; guessing a unit
        // for it would display a wrong number.
        return null;
    }

    final limit = _num(raw['usage']);
    final used = _num(raw['currentValue']);
    final percentage = _num(raw['percentage']);
    final remaining = _num(raw['remaining']);

    final double usedPercent;
    final double limitValue;
    final double remainingValue;

    if (limit != null && limit > 0 && used != null) {
      // An absolute meter. The exact ratio is preferred over `percentage`,
      // because the server rounds it: 1438 of 12000 credits is reported as 11.
      usedPercent = (used / limit * 100).clamp(0.0, 100.0).toDouble();
      limitValue = limit;
      // The server's own figure wins when it sent one; otherwise the complement
      // of the exact ratio. Clamped so a payload that disagrees with itself
      // cannot render a negative or over-full number.
      //
      // `limit` and `remaining` must share a scale. An absolute limit of 12000
      // credits beside a percentage-derived remaining of 88 would render
      // "88/12000", which no user can interpret.
      remainingValue = (remaining ?? (limit - used)).clamp(0.0, limit);
    } else if (percentage != null) {
      // Percent-only, so 0-100 is the only coherent scale.
      usedPercent = percentage.clamp(0.0, 100.0).toDouble();
      limitValue = 100;
      remainingValue = 100 - usedPercent;
    } else {
      // Neither an exact ratio nor a percentage is a real absence of evidence,
      // and rendering 0% would read as "nothing used".
      return null;
    }

    final window = _window(raw);
    return Quota(
      id: '$idPrefix:${window.id}',
      label: '${window.label} limit',
      percent: usedPercent,
      remaining: remainingValue,
      limit: limitValue,
      unit: unit,
      resetAt: _instant(raw['nextResetTime']),
    );
  }

  /// The window length, derived from the `unit` enum and its `number` count.
  ///
  /// An unrecognised `unit` still yields a usable window rather than dropping
  /// the quota: a new enum value should cost the label, not the number.
  static ({String id, String label}) _window(Map<Object?, Object?> raw) {
    final unit = _int(raw['unit']);
    final count = (_int(raw['number']) ?? 1) > 0 ? _int(raw['number'])! : 1;
    switch (unit) {
      case _unitHours:
        return (id: '${count}h', label: '$count Hour');
      case _unitDays:
        return (id: '${count}d', label: '$count Day');
      case _unitMonths:
        return (
          id: '${count}mo',
          label: count == 1 ? 'Monthly' : '$count Month',
        );
      case _unitWeek:
        return (id: '1w', label: 'Weekly');
      default:
        return (id: unit == null ? 'quota' : '${count}u$unit', label: 'Quota');
    }
  }

  /// `nextResetTime` as an instant, tolerating seconds or milliseconds.
  ///
  /// The field is milliseconds, but a seconds value is plausible enough to
  /// detect by magnitude: reading 1789018000 as milliseconds would place the
  /// reset in January 1970 and the countdown would never fire.
  static DateTime? _instant(Object? value) {
    final parsed = _num(value);
    if (parsed == null || parsed <= 0) return null;
    final millis = parsed < 100000000000
        ? (parsed * 1000).round()
        : parsed.round();
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.isFinite ? value.toInt() : null;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static double? _num(Object? value) {
    if (value is num) return value.isFinite ? value.toDouble() : null;
    if (value is String) return double.tryParse(value.trim());
    return null;
  }
}
