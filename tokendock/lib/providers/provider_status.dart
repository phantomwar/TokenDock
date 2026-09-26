import '../models/connection_status.dart';
import '../models/provider_snapshot.dart';
import '../models/quota.dart';

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
  /// The mapping is generic rather than per-vendor, and was verified against two
  /// independent vendors: OpenRouter, and MiniMax, whose 401 body is
  /// `{"type":"error","error":{"type":"authorized_error",...}}`.
  static ({ConnectionStatus status, String error}) fromHttpStatus(int code) {
    if (code == 401) {
      return (status: ConnectionStatus.authError, error: 'Invalid API key');
    }
    if (code == 403) {
      // Forbidden, not a rejected credential. A key that authenticated and was
      // then refused must not be revoked (audit C-34).
      return (status: ConnectionStatus.error, error: 'Forbidden');
    }
    if (code == 402) {
      return (status: ConnectionStatus.limited, error: 'Insufficient credits');
    }
    if (code == 429) {
      return (status: ConnectionStatus.warning, error: 'Rate limited');
    }
    if (code >= 500 && code <= 599) {
      return (status: ConnectionStatus.error, error: 'Provider unavailable');
    }
    return (status: ConnectionStatus.error, error: 'Unknown response');
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
}
