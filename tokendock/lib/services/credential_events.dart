import '../providers/antigravity/antigravity_oauth.dart';

/// A credential was definitively rejected and requires reconnection, or -- with
/// [CredentialEventCause.recovered] -- has just been shown to work again.
///
/// The value deliberately carries no credential or token material.
class CredentialDisabledEvent {
  const CredentialDisabledEvent({
    required this.connectionId,
    required this.cause,
    this.identityKey,
  });

  final String connectionId;
  final String cause;
  final String? identityKey;
}

/// The `cause` values this layer emits, named so a typo cannot invent one.
///
/// Previously these were bare string literals at their call sites, and a
/// consumer that matched on the literal had no way to be told a new one had been
/// added.
abstract final class CredentialEventCause {
  /// The token endpoint reported the grant revoked. Definitive on the first
  /// response: the server is describing the credential, not one reply.
  static const String invalidGrant = 'invalid_grant';

  /// A 401 with no richer signal. **Suspect on its own** -- see the two-stage
  /// logic in `RefreshService._performRefreshOne`; this cause only reaches a
  /// listener once a second consecutive rejection confirms it.
  static const String bareUnauthorized = 'bare_401';

  /// A previously escalated credential has just fetched successfully, so any
  /// reconnection prompt raised for it should be taken down.
  static const String recovered = 'credential_recovered';
}

/// Converts a recognized definitive failure to a stable, token-free cause.
String? definitiveOAuthFailureCause(Object error) =>
    _definitiveFailureCause(error);

/// Converts a failure into a stable, token-free cause, or null when the
/// failure is not a definitive rejection of the current credential.
///
/// Classification is by **status**, not by message shape. The design spec is
/// explicit that the classifier must use "status + header + provider code
/// first (never fragile message regex)", and the previous implementation ran
/// six substring checks over a lowercased message, so an unrelated error whose
/// text merely ended in `401` tore down a working connection (audit C-11).
///
/// The one exception is `invalid_grant`: the token endpoint reports it in the
/// response body with no status that distinguishes it from a transient error,
/// so it is matched as a body-level, spec-defined token. Nothing else is
/// inferred from message text.
String? _definitiveFailureCause(Object error) {
  if (error is AntigravityHttpStatus) {
    return error.statusCode == 401
        ? CredentialEventCause.bareUnauthorized
        : null;
  }
  if (error is AntigravityTransportFailure) {
    final cause = error.cause;
    if (cause is int) {
      return cause == 401 ? CredentialEventCause.bareUnauthorized : null;
    }
    if (cause is AntigravityOAuthHttpResponse) {
      return cause.statusCode == 401
          ? CredentialEventCause.bareUnauthorized
          : null;
    }
    return null;
  }
  if (error is StateError) {
    final normalized = error.message.trim().toLowerCase();
    if (normalized.contains(CredentialEventCause.invalidGrant)) {
      return CredentialEventCause.invalidGrant;
    }
  }
  return null;
}
