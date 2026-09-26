import 'dart:convert';

import '../../models/provider_snapshot.dart';
import '../../models/quota.dart';
import '../provider_http.dart';
import '../provider_status.dart';

/// Parses OpenCode Go usage from `GET https://opencode.ai/zen/go/v1/usage`.
///
/// ## Provenance, and why the parsing is strict
///
/// The response shape was ported from a working implementation rather than
/// guessed: `packages/ai/src/usage/opencode-go.ts` in `can1357/oh-my-pi`.
///
/// That file records the risk plainly: this route is first-party but
/// **undocumented**, and "its shape changed once on merge day". So every window
/// is validated and a single bad window discards the whole report. A partial
/// report is worse than none, because it replaces a complete last-good one in
/// the cache and silently drops the windows the user would have seen.
///
/// ## Auth
///
/// Unlike the `/models` listing, this endpoint enforces the key: 401 for a
/// missing or invalid key, 403 for a valid key with no Go subscription.
class OpenCodeUsageResponse {
  const OpenCodeUsageResponse._();

  static const String baseUrl = 'https://opencode.ai/zen/go';

  static const String usagePath = '/v1/usage';

  static Uri get usageEndpoint => Uri.parse('$baseUrl$usagePath');

  /// The three windows Go meters independently, in the order they bite.
  ///
  /// The monthly window anchors on the subscription anniversary rather than a
  /// rolling span, so it carries no duration and is display-only.
  static const List<({String key, String id, String label})> _windows = [
    (key: 'rolling', id: '5h', label: '5 Hour limit'),
    (key: 'weekly', id: '7d', label: 'Weekly limit'),
    (key: 'monthly', id: 'monthly', label: 'Monthly limit'),
  ];

  /// Parses a 200 body. Returns an empty, healthy snapshot when the report is
  /// not fully decodable, so the last cached values keep serving.
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
      final usage = decoded['usage'];
      if (usage is! Map) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      final quotas = <Quota>[];
      for (final window in _windows) {
        final quota = _decodeWindow(usage[window.key], window.id, window.label);
        if (quota == null) {
          // All-or-nothing, and a *malformed* result rather than a healthy empty
          // one. `RefreshService` replaces the cached quota with whatever this
          // returns, so reporting `ok` with no quotas would blank the user's
          // card because an undocumented route changed shape. A non-ok snapshot
          // takes the error path, which keeps the last known values.
          return ProviderStatus.malformed(
            connectionId: connectionId,
            fetchedAt: fetchedAt,
          );
        }
        quotas.add(quota);
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

  /// One window, or null when it is absent or not the documented shape.
  ///
  /// The endpoint's own `status` outranks `percent`: a rate-limited window can
  /// report a stale percentage that would otherwise render as healthy quota.
  static Quota? _decodeWindow(Object? raw, String id, String label) {
    if (raw is! Map) return null;

    final percent = raw['percent'];
    if (percent is! num || !percent.isFinite) return null;
    if (percent < 0 || percent > 100) return null;

    final status = raw['status'];
    if (status != 'ok' && status != 'rate-limited') return null;

    final resetsAtRaw = raw['resetsAt'];
    if (resetsAtRaw is! String) return null;
    final resetsAt = DateTime.tryParse(resetsAtRaw);
    if (resetsAt == null) return null;

    final usedPercent = status == 'rate-limited' ? 100.0 : percent.toDouble();

    return Quota(
      id: id,
      label: label,
      percent: usedPercent,
      remaining: (100 - usedPercent).clamp(0.0, 100.0),
      limit: 100,
      unit: '%',
      resetAt: resetsAt.toUtc(),
    );
  }

  /// Maps a non-2xx response.
  ///
  /// The rules live in [ProviderStatus] and are not re-decided per vendor: a
  /// timeout is a timeout, and only 401 invalidates a credential. In particular
  /// 403 means a valid key with no Go subscription, and telling the user to
  /// re-enter a key that is fine is wrong.
  static ProviderSnapshot mapError({
    required String connectionId,
    required DateTime fetchedAt,
    int? statusCode,
    bool isTimeout = false,
  }) {
    return ProviderStatus.fromProbeResult(
      result: isTimeout
          ? const ProbeResult.timeout()
          : statusCode == null
          ? const ProbeResult.transportFailure()
          : ProbeResult.response(statusCode: statusCode, body: ''),
      connectionId: connectionId,
      fetchedAt: fetchedAt,
    );
  }
}
