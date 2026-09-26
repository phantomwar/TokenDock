import 'dart:async';

import '../providers/antigravity/antigravity_oauth.dart';

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
