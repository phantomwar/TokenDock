# Task 6 Report

## Status

Complete and committed.

## Changes

- Added `CredentialDisabledEvent` with only `connectionId`, stable `cause`, and nullable `identityKey`; the event type has no token/secret field.
- Added the public `isDefinitiveOAuthFailure` and `definitiveOAuthFailureCause` classifier contract. It recognizes `invalid_grant` and minimal bare-401 forms while leaving unrelated failures retryable.
- Added `RefreshService.addDisabledListener` / `removeDisabledListener` and disposal cleanup.
- Updated `RefreshService` provider-failure handling so `invalid_grant` and bare 401 become an `authError` health tombstone whose persisted `last_error` is the stable cause, emit a credential-disabled event, preserve cached quotas, and never publish the original token-bearing error.
- The tombstone does not delete quota cache or mutate the `Connection`; the disabled event is the hook for reconnection UI.
- Added focused tests for event contents/token exclusion, classifier behavior, event delivery, identity propagation, persisted auth tombstone, and cache preservation.

## TDD evidence

Initial red command:

```text
flutter test --no-pub test/services/tombstone_test.dart
```

Initial red result: the focused test failed to compile because `credential_events.dart`, `CredentialDisabledEvent`, the definitive-failure classifier, and disabled listeners did not exist, as expected.

Focused green command:

```text
flutter test --no-pub test/services/tombstone_test.dart test/services/refresh_service_test.dart
```

Focused green result: all 14 tests passed; exit code 0.

## Commit

`feat: add credential tombstone and disabled event` (this commit)

## Concerns

- Project-wide tests, linters, analyzers, builds, and formatters were intentionally not run per task instructions; the main agent owns the single project-wide validation after sibling tasks land.
- Definitive classification is intentionally limited to the two Task 6 contracts (`invalid_grant` and bare 401). Token-family reuse and Task 8 schema-change causes remain for their owning integration work.
- The event listener is a minimal service hook; the reconnection banner is deferred to the UI task.

## Reviewer follow-up

- Fixed returned provider `authError` snapshots (including OpenRouter's non-throwing HTTP 401 path) so they emit `CredentialDisabledEvent(cause: bare_401)`, persist the stable `bare_401` tombstone cause, and retain cached quotas without exposing the provider error or token.
- Reviewer regression red command: `flutter test --no-pub test/services/tombstone_test.dart` — the new returned-401 test failed because no disabled event was emitted, as expected.
- Reviewer regression green command: `flutter test --no-pub test/services/tombstone_test.dart test/services/refresh_service_test.dart` — all 15 focused tests passed; exit code 0.
