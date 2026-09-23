# Final Recovery 3 Report

## Scope

Implemented all eight findings from the final whole-branch review in the `login-adaptation` worktree while preserving the user-approved unofficial Antigravity contracts and Google native-app OAuth guidance.

## Implemented fixes

1. Google authorization-code and refresh-token requests now use `application/x-www-form-urlencoded`; v1internal RPCs remain JSON. Fake HTTP regressions assert both wire formats and the authorization-code payload.
2. Test-time adapter probes now run through `RefreshService` under the same per-connection operation lock as refresh. The overlap regression proves one rotating refresh and no concurrent rotating-token submission.
3. RefreshService tracks every active rotated secret and redacts the old and current values from post-rotation fetch errors and persisted health.
4. Language-server CSRF values are discovered from the running Windows process command line (`language_server --extension_server_port/--csrf_token`) and cached only in the injected in-memory runtime configuration. SQLite `ConnectionRepository.save` strips CSRF-named fields, and regressions prove persisted `provider_data` contains neither the key nor value and that the correct session is selected among multiple running servers.
5. `quota_source_changed` persists an independent `quotaSourceDisabled` marker in connection metadata. Every refresh is gated even if the enabled switch changes, cached quotas remain intact, and explicit Test+Save revalidation removes the marker without changing the user's enabled preference.
6. `AppState` subscribes to `CredentialDisabledEvent`; ConnectionsScreen renders a text-and-icon Reconnect action. Cached quotas remain available while reconnection is required, and successful persisted replacement clears the reconnect state.
7. Transient 429/503 requests use a bounded three-attempt loop: the first wait honors `Retry-After`; later waits use Full Jitter. The regression asserts request count and exact injected delay sequence.
8. `PRODUCT.md`, `tokendock/README.md`, and `docs/auth-quota-hardening-plan.md` now record 97 focused and 193 full tests, the analyzer's seven informational diagnostics/nonzero exit, and accurate backend/UI reachability.

## Verification

- CSRF discovery was not exercised against a real Antigravity process; the Windows CIM parser is covered with an injected multi-session fake.
- Focused command: `flutter test --no-pub test/providers/antigravity_local_test.dart test/providers/antigravity_oauth_test.dart test/services/oauth_loopback_test.dart test/services/refresh_service_test.dart test/services/log_redaction_test.dart test/app/app_state_test.dart test/ui/connections_screen_test.dart` — 97 tests passed.
- Full command: `flutter test --no-pub` — 193 tests passed.
- Analyzer: `flutter analyze` — 0 errors, 0 warnings, 7 pre-existing informational diagnostics; exits nonzero as expected for this repository baseline.
- `git diff --check` — passed; only Git line-ending notices were emitted.

## TDD evidence

- RED: the new focused regressions initially failed to compile because form-post injection, CSRF runtime injection, locked adapter tests, AppState reconnect state, and the SQLite boundary did not exist; the redaction/quarantine/UI tests exposed the old behavior.
- GREEN: the focused command passed all 97 tests after the minimal production changes.

## Concerns

- No real Google endpoint, OAuth account, Antigravity process, external browser, or Windows integration flow was exercised; all network/process tests use sanitized fakes.
- Antigravity local-source selection and remote OAuth entry remain backend-only. The existing Connections UI surfaces Reconnect and generic connection management, but does not add the Antigravity login/source picker.
- Schema quarantine is durable and reversible only through an explicit connection update/re-validation path; there is no dedicated Antigravity revalidation screen yet.
- Analyzer remains nonzero solely because of the seven recorded pre-existing informational diagnostics.
- No project-wide formatting was run. Generated Windows plugin files touched by Flutter tooling were restored.
