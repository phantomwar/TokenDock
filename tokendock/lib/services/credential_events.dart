import '../providers/antigravity/antigravity_oauth.dart';

/// A credential was definitively rejected and requires reconnection.
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
    return error.statusCode == 401 ? 'bare_401' : null;
  }
  if (error is AntigravityTransportFailure) {
    final cause = error.cause;
    if (cause is int) {
      return cause == 401 ? 'bare_401' : null;
    }
    if (cause is AntigravityOAuthHttpResponse) {
      return cause.statusCode == 401 ? 'bare_401' : null;
    }
    return null;
  }
  if (error is StateError) {
    final normalized = error.message.trim().toLowerCase();
    if (normalized.contains('invalid_grant')) return 'invalid_grant';
  }
  return null;
}
