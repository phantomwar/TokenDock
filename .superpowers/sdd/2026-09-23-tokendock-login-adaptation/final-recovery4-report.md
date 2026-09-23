# Final Recovery 4 Report

## Scope

Fixed the two remaining CSRF custody findings from the final review in the `login-adaptation` worktree. No real credentials, OAuth accounts, Antigravity processes, or external services were used.

## Implemented fixes

1. `SqliteConnectionRepository` now recursively walks every nested map and list in `providerData` before JSON persistence. Any map key containing `csrf` (case-insensitive) is removed at every depth; malformed or non-object provider data remains rejected as before.
2. Language-server discovery now carries the Windows process ID in each discovered session. Runtime CSRF custody is keyed by connection, port, and process ID, and the reader rediscovers before using a cached session so a same-port process restart cannot receive the previous token.
3. A failed language-server endpoint invalidates the cached CSRF session. The reader rediscovers the port and retries once only when a different process/session or token is found; otherwise it proceeds through the existing endpoint and `agy` fallbacks without sending an unverified replacement.

## Regression coverage

- Nested provider-data regression covers a CSRF field inside a list and a nested map and asserts both secret strings are absent from SQLite persistence.
- Same-port restart regression uses two fake process IDs and tokens and asserts the second request uses the replacement token.
- Endpoint-failure regression uses a rejected token followed by a discovered replacement session and asserts invalidation, rediscovery, and replacement-token use.

## Verification

- Focused command: `flutter test --no-pub test/providers/antigravity_local_test.dart test/providers/antigravity_oauth_test.dart test/services/oauth_loopback_test.dart test/services/refresh_service_test.dart test/services/log_redaction_test.dart test/app/app_state_test.dart test/ui/connections_screen_test.dart` — 98 tests passed.
- CSRF-focused command: `flutter test --no-pub test/providers/antigravity_local_test.dart test/providers/antigravity_oauth_test.dart test/services/refresh_service_test.dart test/storage/repositories_test.dart` — 72 tests passed.
- Full command: `flutter test --no-pub` — 195 tests passed.
- Analyzer: `flutter analyze` — 0 errors, 0 warnings, 7 pre-existing informational diagnostics; exits nonzero as expected for the repository baseline.
- No project-wide formatting was run.

## TDD evidence

- RED: the new nested persistence and same-port/failure CSRF regressions initially exposed nested secret persistence and repeated use of the stale token.
- GREEN: after the minimal sanitizer and session-aware discovery/cache changes, all focused and full tests passed.

## Concerns

- Windows process discovery remains covered with sanitized fakes; no real Antigravity process was exercised.
- The analyzer's seven informational diagnostics are unchanged baseline findings.
