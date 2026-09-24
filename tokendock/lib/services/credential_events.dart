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

/// Returns whether [error] definitively invalidates the current credential.
bool isDefinitiveOAuthFailure(Object error) =>
    _definitiveFailureCause(error) != null;

/// Converts a recognized definitive failure to a stable, token-free cause.
String? definitiveOAuthFailureCause(Object error) =>
    _definitiveFailureCause(error);

String? _definitiveFailureCause(Object error) {
  final message = error is StateError ? error.message : error.toString();
  final normalized = message.trim().toLowerCase();
  if (normalized.contains('invalid_grant')) return 'invalid_grant';
  if (normalized == '401' || normalized.endsWith(': 401') || normalized.contains('bad state: 401') || normalized.contains('http 401') || normalized.contains('status 401') || normalized.contains('statuscode=401')) return 'bare_401';
  return null;
}
