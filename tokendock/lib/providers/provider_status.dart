import '../models/connection_status.dart';
import '../models/provider_snapshot.dart';
import '../models/quota.dart';
import 'provider_http.dart';
import 'provider_throttle.dart';

/// The parts of a provider response every adapter needs.
///
/// Extracted from `openrouter_response.dart`, which grew them first. MiniMax
/// needed the identical status mapping and the identical snapshot constructors,
/// and copying them would have put a second copy of the 401-means-invalidate-
/// credential rule in the tree. That rule is load-bearing: it is what makes
/// `RefreshService` revoke a dead key and prompt a re-login instead of retrying
/// it forever, so it must have exactly one definition.
abstract final class ProviderStatus {
  const ProviderStatus._();

  /// Maps an HTTP status to the user-facing state and copy.
  ///
  /// Delegates to [ProviderThrottle] rather than keeping a second status table.
  /// Two tables is how a mapping drifts: one copy classified 403 as an auth
  /// error (audit C-34) while the other treated it as a denial, and the
  /// difference is whether the user is told to re-enter a working key.
  ///
  /// The mapping was verified against three independent vendors: OpenRouter,
  /// MiniMax, whose 401 body is
  /// `{"type":"error","error":{"type":"authorized_error",...}}`, and OpenCode
  /// Go, which uses 403 to mean "valid key, no Go subscription".
  static ({ConnectionStatus status, String error}) fromHttpStatus(int code) {
    final verdict = ProviderThrottle.classify(statusCode: code);
    return (status: verdict.status, error: verdict.error);
  }

  /// A snapshot describing a failure, with no cached values attached.
  ///
  /// Carries no quotas on purpose: a failed fetch must not erase what the user
  /// already had (PRD "cache-first truth").
  static ProviderSnapshot failure({
    required String connectionId,
    required DateTime fetchedAt,
    required ConnectionStatus status,
    required String error,
    DateTime? cooldownUntil,
  }) {
    return ProviderSnapshot(
      connectionId: connectionId,
      status: status,
      quotas: const <Quota>[],
      balance: null,
      failureCause: status == ConnectionStatus.authError
          ? ProviderFailureCause.invalidCredential
          : null,
      fetchedAt: fetchedAt,
      error: error,
      cooldownUntil: cooldownUntil,
    );
  }

  /// The request did not complete in time.
  static ProviderSnapshot timeout({
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    return failure(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: ConnectionStatus.error,
      error: 'Timeout',
    );
  }

  /// The response arrived but did not match the documented shape.
  static ProviderSnapshot malformed({
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    return failure(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: ConnectionStatus.error,
      error: 'Unknown response',
    );
  }

  /// A healthy snapshot carrying the values a provider actually published.
  static ProviderSnapshot ok({
    required String connectionId,
    required DateTime fetchedAt,
    List<Quota> quotas = const <Quota>[],
  }) {
    return ProviderSnapshot(
      connectionId: connectionId,
      status: ConnectionStatus.ok,
      quotas: quotas,
      balance: null,
      fetchedAt: fetchedAt,
      error: null,
    );
  }

  /// Turns a failed [ProbeResult] into a snapshot.
  ///
  /// Every provider that reaches a network endpoint needs exactly this, and
  /// getting it subtly different per vendor is how "a timeout is reported as a
  /// dead credential" or "a 403 revokes a working key" happens. The two rules
  /// that matter are already load-bearing in [fromHttpStatus] and are not
  /// re-decided here:
  ///
  /// - a timeout is a timeout, not a credential problem, and must never revoke
  ///   a key;
  /// - only 401 invalidates a credential.
  ///
  /// [fallback] handles a result with no status code at all, which only happens
  /// on a transport failure.
  static ProviderSnapshot fromProbeResult({
    required ProbeResult result,
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    if (result.isTimeout) {
      return timeout(connectionId: connectionId, fetchedAt: fetchedAt);
    }
    final code = result.statusCode;
    if (code == null) {
      return malformed(connectionId: connectionId, fetchedAt: fetchedAt);
    }
    final mapped = fromHttpStatus(code);
    return failure(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: mapped.status,
      error: mapped.error,
    );
  }
}
