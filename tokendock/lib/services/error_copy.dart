import 'dart:async';

import 'package:flutter/foundation.dart';

import '../providers/antigravity/antigravity_oauth.dart';
import 'credential_events.dart';

/// User-safe description of a failure.
///
/// The one rule this module exists to enforce: **never interpolate the
/// exception object**. A `DatabaseException` renders as
/// `DatabaseException(SqliteException(1): while executing, no such table:
/// connections, SQL logic error (code 1) Causing statement: SELECT * FROM
/// connections)`, so formatting it into user-facing copy exposes table names,
/// SQL, column names and driver error codes. A provider exception can carry a
/// credential in its message, which is worse.
///
/// [fallback] is supplied by the call site and must be a fixed string chosen
/// for that operation. The exception itself is not consulted for detail, so a
/// failure the app does not recognise still produces calm, actionable copy
/// rather than a stack trace.
String userSafeErrorMessage(Object error, {required String fallback}) {
  // The fallback arm used to be silent, and that is what made nine live sign-in
  // attempts undiagnosable from the app. A failure this module does not
  // recognise produced the same calm sentence and nothing else: no log line, no
  // exception type, no indication of which step failed.
  //
  // The user-facing copy stays exactly as careful as before -- the *type* is a
  // Dart class name and cannot carry a secret, a path or a credential. What is
  // added is for a developer, in a debug build, on stdout.
  if (fallback == 'Unable to sign in. Please try again.') {
    debugPrint(
      'TokenDock: sign-in failed with an unrecognised error type '
      '${error.runtimeType}; the message shown is the generic fallback, so the '
      'log lines above are the only diagnosis available.',
    );
  }

  // Known failure modes that already carry deliberate, user-safe copy.
  if (error is AntigravityOnboardingRequired) {
    return 'Complete onboarding in Antigravity, then try again.';
  }
  if (error is AntigravityLoginCancelled) {
    return 'Sign-in cancelled.';
  }
  if (error is AntigravityTransientFailure) {
    return 'Provider is busy. Try again shortly.';
  }
  if (error is AntigravitySchemaChanged) {
    return 'Antigravity changed its quota format. Re-test this connection.';
  }
  if (error is AntigravityTransportFailure) {
    return 'Could not reach the provider.';
  }
  if (error is AntigravitySelectedAccountGuard) {
    return 'This account does not match the selected Antigravity account.';
  }
  if (error is TimeoutException) {
    return 'The provider took too long to respond.';
  }
  if (error is FormatException) {
    return 'The provider returned an unexpected response.';
  }
  if (error is UnsupportedError) {
    return 'That operation is not supported on this platform.';
  }
  return fallback;
}

/// Deliberate, user-facing copy for a credential rejection.
///
/// This exists because the classification tokens are not copy. `bare_401` and
/// `invalid_grant` are for internal routing -- deciding whether to escalate and
/// whether a secret must be deleted -- and `token_dock_widget` renders
/// `snapshot.error` **verbatim**, which meant a connection rejected with a bare
/// 401 put the literal text `bare_401` on screen.
///
/// An unrecognised token falls back to the generic rejection copy rather than
/// being echoed: a token this version does not know about should still produce
/// something a user can read, and an unknown token is not a safe thing to
/// render precisely because it was not anticipated.
String credentialRejectionMessage(String? cause) {
  if (cause == null || cause.isEmpty) return 'Invalid API key';
  if (cause == CredentialEventCause.invalidGrant) {
    return 'Session expired. Reconnect to continue.';
  }
  return 'Invalid API key';
}
