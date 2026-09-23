# Final Recovery 2 Report

## Scope

Implemented the six remaining findings from the final recovery review in the login-adaptation worktree, preserving the approved unofficial Antigravity and Google-native OAuth guidance.

## Fixes

1. `RefreshService` now detects persisted Antigravity `language-server` and `agy-cli` provider data before the generic credential gate. Local sources refresh with an empty secret; remote sources still fail closed with `authError` when no credential exists.
2. Local Antigravity identity checks normalize response email/account fields to the persisted `email|accountId` composite key before enforcing the selected-account guard. Added LS and agy parser/fetch regressions.
3. `TestResult` now carries an optional typed `replacementSecret`. OAuth test-time refresh returns the replacement, and `ConnectionsScreen` saves it atomically for add/update flows rather than the consumed input JSON.
4. `ProviderSnapshot` carries the current `Connection`; final refresh snapshots publish the post-rotation connection and `AppState` adopts it. Added an edit-after-rotation regression proving stale credential refs cannot be restored.
5. Redaction now applies the documented substring rule (`key|token|secret|auth|credential|cookie`) to JSON and query-like field names, including token, credential, oauth, and private_key, while retaining bearer and URL behavior.
6. Local account mismatch is reported as `ConnectionStatus.error` with `ProviderFailureCause.accountMismatch`, preserving cache and avoiding credential-disable events.

## Verification

- Focused command: `flutter test --no-pub test/providers/antigravity_local_test.dart test/providers/antigravity_oauth_test.dart test/services/oauth_loopback_test.dart test/services/refresh_service_test.dart test/services/log_redaction_test.dart test/app/app_state_test.dart test/ui/connections_screen_test.dart` — passed, 91 tests.
- Full command: `flutter test --no-pub` — passed, 187 tests.
- `flutter analyze` — completed with 7 pre-existing informational lints and no errors/warnings; the new unnecessary-interpolation info was removed before the final analyzer run.

## Concerns

- Analyzer exits nonzero on the repository's existing informational lint set; no project-wide formatting was run.
- Generated Windows plugin files touched by Flutter tooling were restored to their committed contents.
