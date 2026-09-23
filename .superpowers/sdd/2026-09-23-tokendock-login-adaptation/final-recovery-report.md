# Final Recovery Report

## Status

All nine final-review findings were implemented with regression coverage. The Antigravity Connections UI remains intentionally unwired; local and remote Antigravity support are backend/test-only and are not claimed as live UI flows.

## Red/green evidence

- RED: Added and ran regressions for named credential-field redaction; the old implementation leaked JSON values.
- GREEN: `flutter test --no-pub test/services/log_redaction_test.dart` — 8 passed.
- RED: Added local-source dispatch tests; the old facade always called remote OAuth and failed to compile with `localReader` injection.
- GREEN: `flutter test --no-pub test/providers/antigravity_oauth_test.dart` — 20 passed.
- RED: Added range, test-time refresh, reuse/revoke, Retry-After, and typed-failure tests; old code lacked the contracts and failed compilation/behavior assertions.
- GREEN: `flutter test --no-pub test/providers/antigravity_oauth_test.dart` — 20 passed.
- RED: Added local parser non-finite/out-of-range regression; old parser clamped numeric values and accepted NaN.
- GREEN: `flutter test --no-pub test/providers/antigravity_local_test.dart` — 14 passed.
- RED: Added IPv6 loopback callback regression; old IPv4-only listener refused `[::1]`.
- GREEN: `flutter test --no-pub test/services/oauth_loopback_test.dart` — 8 passed.
- RED: Added typed RefreshService failure matrix, current-ref rotation cleanup, and invalid-grant local-pair deletion regressions; old service tombstoned all `authError` values and retained reusable secrets.
- GREEN: `flutter test --no-pub test/services/refresh_service_test.dart test/services/tombstone_test.dart` — 22 passed.
- Focused final command: `flutter test --no-pub test/providers/antigravity_oauth_test.dart test/providers/antigravity_local_test.dart test/services/oauth_loopback_test.dart test/services/refreshable_test.dart test/services/refresh_service_test.dart test/services/tombstone_test.dart test/services/log_redaction_test.dart` — 72 passed.
- Full command: `flutter test --no-pub` — 179 passed.
- Analyzer: `flutter analyze` — 0 errors, 0 warnings, 7 informational diagnostics (one null-aware-elements suggestion and six pre-existing RefreshService initializing-formals suggestions).

## Implemented fixes

1. `AntigravityProvider` dispatches only explicit `language-server`/`agy-cli` sources to `AntigravityLocalReader`; absent or `remote` source remains remote OAuth.
2. Provider snapshots carry typed failure causes; RefreshService only emits credential-disabled for actual invalid-credential 401, preserving onboarding, mismatch, schema, forbidden, transport, and transient status/cooldown semantics.
3. Rotated refresh-token reuse is tracked in memory; `invalid_grant`/reuse revokes the token best effort, deletes the local pair, and requires relogin. Stable Google refresh tokens remain supported.
4. Rotation updates the connection to the new reference and deletes that current reference on every rotation, with pending cleanup retained.
5. Redaction covers named credential fields and case variants in strings/JSON while preserving URL query/fragment rules.
6. Non-finite and out-of-range fractions are rejected as `quota_source_changed`; valid reset-only entries remain valid.
7. `Retry-After` seconds and HTTP-date are honored as transient cooldown floors; 429 never enters quota cache. Full Jitter is isolated to retryable attempts.
8. OAuth loopback binds an IPv6 `[::1]` companion where available and closes both listeners safely.
9. OAuth provider tests perform one test-time refresh for expiring refreshable credentials before fetching.

## Documentation

Updated `PRODUCT.md`, `tokendock/README.md`, and `docs/auth-quota-hardening-plan.md` to state v3/provider/backend-only reachability and final evidence without claiming real Google integration.

## Commit

Pending commit at report-write time; the implementation commit hash will be supplied by the worker result.

## Remaining concerns

- No real Google endpoint, real OAuth account, real Antigravity process, or real external browser was exercised; tests use sanitized fake HTTP/process fixtures.
- Connections UI does not expose Antigravity local-source selection or remote OAuth login.
- Automatic account fallback and adaptive polling remain out of scope.
- Windows integration remains pending on symlink support/Developer Mode.
