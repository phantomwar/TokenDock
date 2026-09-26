import 'dart:convert';

import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/quota.dart';
import '../provider_status.dart';

/// Parses MiniMax Token Plan usage from `GET /v1/token_plan/remains`.
///
/// The response shape was taken from a working implementation rather than
/// guessed: `packages/ai/src/usage/minimax-code.ts` in `can1357/oh-my-pi`.
///
/// ## The property that makes this parser necessary
///
/// **MiniMax answers HTTP 200 even for a rejected credential.** The real success
/// signal is `base_resp.status_code === 0`. A parser that trusted the HTTP status
/// would report a pristine quota for a key that does not work, which is worse
/// than reporting nothing.
///
/// ## Windows
///
/// Each `model_remains[]` bucket carries two independent budgets: a rolling
/// interval (5 hours for text quotas, and the span is reported rather than
/// assumed) and a weekly window. Both are emitted as separate quotas, because
/// showing only one hides half of the picture and the two run out at different
/// times.
class MiniMaxUsageResponse {
  const MiniMaxUsageResponse._();

  /// The international endpoint. There is also a domestic host, which this
  /// adapter does not use.
  static const String baseUrl = 'https://api.minimax.io';

  static const String remainsPath = '/v1/token_plan/remains';

  static Uri get remainsEndpoint => Uri.parse('$baseUrl$remainsPath');

  /// Parses a successful 200 body.
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

      // The body is the authority on success, not the HTTP status.
      final baseResp = decoded['base_resp'];
      final statusCode = baseResp is Map
          ? _asInt(baseResp['status_code'])
          : null;
      if (statusCode == null) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }
      if (statusCode != 0) {
        return ProviderStatus.failure(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
          status: ConnectionStatus.authError,
          error: 'Invalid API key',
        );
      }

      final buckets = decoded['model_remains'];
      if (buckets is! List) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      final quotas = <Quota>[];
      for (final entry in buckets) {
        if (entry is! Map) continue;
        final bucket = _Bucket.tryParse(entry);
        if (bucket == null) continue;
        if (bucket.isOutsidePlan) continue;
        quotas
          ..addAll(
            bucket.windowQuotas(
              connectionId: connectionId,
              suffix: 'interval',
              label: _intervalLabel(bucket),
              windowStatus: bucket.intervalStatus,
              remainingPercent: bucket.intervalRemainingPercent,
              endTime: bucket.intervalEnd,
            ),
          )
          ..addAll(
            bucket.windowQuotas(
              connectionId: connectionId,
              suffix: '7d',
              label: '7 Day limit',
              windowStatus: bucket.weeklyStatus,
              remainingPercent: bucket.weeklyRemainingPercent,
              endTime: bucket.weeklyEnd,
            ),
          );
      }

      if (quotas.isEmpty) {
        // A valid key with nothing metered. Not an error, and deliberately not a
        // zeroed quota.
        return ProviderStatus.ok(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

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

  /// The plan endpoint could not be read at all: it timed out, 5xx'd, or the
  /// request never completed.
  ///
  /// The credential was already proven by the gate, so this is deliberately
  /// **not** `ok` and deliberately **not** an auth error. `RefreshService`
  /// replaces the cached quota with whatever a snapshot carries, so a healthy
  /// empty result would blank the user's card over a transient hiccup. A
  /// non-`ok` snapshot takes the error path instead, which keeps the last known
  /// values and shows how old they are.
  static ProviderSnapshot unreadable({
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    return ProviderStatus.failure(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: ConnectionStatus.error,
      error: 'Usage unavailable',
    );
  }

  /// The interval span is reported, not assumed, so a bucket that rolls daily
  /// is not labelled "5 Hour".
  static String _intervalLabel(_Bucket bucket) {
    final start = bucket.intervalStart;
    final end = bucket.intervalEnd;
    if (start == null || end == null) return 'Interval limit';
    final minutes = ((end - start) / 60).round();
    if (minutes <= 0) return 'Interval limit';
    if (minutes % 60 == 0) return '${minutes ~/ 60} Hour limit';
    return '$minutes Minute limit';
  }

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }
}

const int _statusExhausted = 2;
const int _statusUnlimited = 3;

/// One `model_remains[]` entry: a plan quota tracked over two windows.
class _Bucket {
  const _Bucket({
    required this.modelName,
    this.intervalStart,
    this.intervalEnd,
    this.intervalRemainingPercent,
    this.intervalStatus,
    this.weeklyStart,
    this.weeklyEnd,
    this.weeklyRemainingPercent,
    this.weeklyStatus,
    this.intervalTotalCount,
    this.weeklyTotalCount,
  });

  final String modelName;
  final int? intervalStart;
  final int? intervalEnd;
  final double? intervalRemainingPercent;
  final int? intervalStatus;
  final int? intervalTotalCount;
  final int? weeklyStart;
  final int? weeklyEnd;
  final double? weeklyRemainingPercent;
  final int? weeklyStatus;
  final int? weeklyTotalCount;

  /// A model outside the current plan is reported as both windows "unlimited"
  /// with zero totals and 100% remaining, which would otherwise read as a
  /// pristine quota. The vendors' own CLI treats that shape as "not in plan"
  /// (MiniMax-AI/cli#173).
  ///
  /// Zero totals alone are not sufficient: a live plan can report `0/0` with
  /// status 1 and a real remaining percentage.
  bool get isOutsidePlan =>
      intervalTotalCount == 0 &&
      weeklyTotalCount == 0 &&
      intervalStatus == _statusUnlimited &&
      weeklyStatus == _statusUnlimited;

  static _Bucket? tryParse(Map<Object?, Object?> raw) {
    final name = raw['model_name'];
    if (name is! String || name.trim().isEmpty) return null;
    return _Bucket(
      modelName: name.trim(),
      intervalStart: _epoch(raw['start_time']),
      intervalEnd: _epoch(raw['end_time']),
      intervalRemainingPercent: _pct(raw['current_interval_remaining_percent']),
      intervalStatus: _int(raw['current_interval_status']),
      intervalTotalCount: _int(raw['current_interval_total_count']),
      weeklyStart: _epoch(raw['weekly_start_time']),
      weeklyEnd: _epoch(raw['weekly_end_time']),
      weeklyRemainingPercent: _pct(raw['current_weekly_remaining_percent']),
      weeklyStatus: _int(raw['current_weekly_status']),
      weeklyTotalCount: _int(raw['current_weekly_total_count']),
    );
  }

  /// Builds the quota for one window, or nothing when the window reports no
  /// usable number.
  ///
  /// The endpoint's own status outranks the percentage: an exhausted window may
  /// omit the percentage, or keep a stale one that would render as healthy.
  List<Quota> windowQuotas({
    required String connectionId,
    required String suffix,
    required String label,
    required int? windowStatus,
    required double? remainingPercent,
    required int? endTime,
  }) {
    if (remainingPercent == null) return const <Quota>[];
    final usedPercent = windowStatus == _statusExhausted
        ? 100.0
        : (100 - remainingPercent).clamp(0.0, 100.0);

    return <Quota>[
      Quota(
        id: '$modelName:$suffix',
        label: label,
        percent: usedPercent,
        remaining: (100 - usedPercent).clamp(0.0, 100.0),
        limit: 100,
        unit: '%',
        resetAt: endTime == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(endTime * 1000, isUtc: true),
      ),
    ];
  }

  /// Unix seconds to a UTC instant, rejecting the 0 the "not in plan" shape
  /// uses as a placeholder.
  static int? _epoch(Object? value) {
    final parsed = _int(value);
    if (parsed == null || parsed <= 0) return null;
    return parsed;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  static double? _pct(Object? value) {
    if (value is num) return value.isFinite ? value.toDouble() : null;
    if (value is String) return double.tryParse(value.trim());
    return null;
  }
}
