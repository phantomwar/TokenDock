# Antigravity Connections UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make registered providers and Antigravity authentication modes usable from the Connections screen without exposing credentials in SQLite or UI.

**Architecture:** Keep `ConnectionsScreen` as the form owner and `AppState` as the persistence boundary. API-key providers retain test-before-save; Antigravity local sources use the same provider test/save gate with no credential; Antigravity remote uses a cancellable OAuth action that commits credentials through compensation-safe methods. Existing refresh and secret custody remain unchanged.

**Tech Stack:** Flutter, Dart, Material 3, `ProviderAdapter`, `AppState`, `MemorySecretStore`, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-09-23-tokendock-login-adaptation-design.md` plus the approved follow-up scope in this session.

## Global Constraints

- Windows 10/11 x64 only.
- Never persist access, refresh, ID, or CSRF tokens in SQLite.
- Never render an Antigravity OAuth credential in the form.
- OpenRouter keeps test-before-save and masked credential behavior.
- Antigravity local source must be explicitly `language-server` or `agy-cli`.
- Antigravity remote must persist source `remote` plus project/tier metadata and identity key.
- Connection count remains uncapped.
- Refresh remains bounded to four concurrent connection operations.

---

### Task 1: Provider and source selection

**Files:**
- Modify: `tokendock/lib/ui/settings/connections_screen.dart`
- Test: `tokendock/test/ui/connections_screen_test.dart`
- Modify: `tokendock/test/support/test_app.dart`

**Interfaces:**
- Consumes: `ProviderRegistry.getAll()` and each adapter's `id`, `name`, and `authKind`.
- Produces: keys `connectionProviderField`, `antigravitySourceField`, `connectionCredentialField`, and persisted `Connection.providerData`.

- [ ] Add a failing widget test that selects Antigravity, chooses `language-server`, verifies the credential field is absent, tests success, saves, and observes `providerData == {"source":"language-server"}` in the real memory repository.
- [ ] Run the focused test and confirm it fails because Antigravity is not selectable and the source control is absent.
- [ ] Replace the read-only provider controller with a dropdown populated from the injected/default registry. Keep provider immutable while editing.
- [ ] Add an Antigravity source dropdown with `remote`, `language-server`, and `agy-cli`. Preserve an existing explicit source in `providerData`.
- [ ] For local sources, pass `providerData` into the test connection and hide/disable the credential field. Require successful test before Save.
- [ ] Run the focused test and the existing ConnectionsScreen suite.

### Task 2: Cancellable remote OAuth onboarding

**Files:**
- Modify: `tokendock/lib/providers/antigravity/antigravity_oauth.dart`
- Modify: `tokendock/lib/app/app_state.dart`
- Modify: `tokendock/lib/ui/settings/connections_screen.dart`
- Test: `tokendock/test/providers/antigravity_oauth_test.dart`
- Test: `tokendock/test/app/app_state_test.dart`
- Test: `tokendock/test/ui/connections_screen_test.dart`

**Interfaces:**
- Consumes: `AntigravityOAuthProvider.loginWithLoopback`, `AppState.addAntigravityConnection`.
- Produces: `AntigravityLoginCancelled`, optional `Future<void> cancellation` on login, `AppState.reconnectAntigravityConnection`, and the `Sign in with Google` action.

- [ ] Add a failing provider test proving cancellation closes the loopback session and raises `AntigravityLoginCancelled` without a callback.
- [ ] Add a failing AppState test proving a successful remote login stores the credential only in `SecretStore`, persists source/project/tier/identity metadata, and leaves no orphan after a failed row save.
- [ ] Add a failing widget test proving `Sign in with Google` calls the injected Antigravity provider, closes the dialog on success, and leaves the repository populated with one OAuth connection.
- [ ] Run each new test and confirm the expected missing-method or missing-widget failure.
- [ ] Add cancellation support to `loginWithLoopback` by closing the loopback session when the supplied future completes and mapping the resulting closure to `AntigravityLoginCancelled`.
- [ ] Extend `AppState.addAntigravityConnection` with cancellation and explicit remote `providerData`; implement `reconnectAntigravityConnection` as an in-place credential replacement preserving connection ID, cache, enabled state, and provider metadata.
- [ ] In remote mode, hide generic credential/test/save controls. Show a Google sign-in action, progress copy, inline safe errors, and a working cancel action. Route existing Antigravity Reconnect to the same OAuth action.
- [ ] Run focused provider, AppState, and widget tests.

### Task 3: Surface hardening and documentation

**Files:**
- Modify: `tokendock/test/ui/connections_screen_test.dart`
- Modify: `PRODUCT.md`
- Modify: `PRD.txt`
- Modify: `tokendock/README.md`

**Interfaces:**
- Consumes: completed provider/source/OAuth UI behavior.
- Produces: documented live Antigravity flow and verification evidence.

- [ ] Add a widget regression proving the remote form never contains `connectionCredentialField` and that safe OAuth failure text is visible while secrets remain absent from the form.
- [ ] Run the focused test and fix only failures caused by the implementation.
- [ ] Update product status from backend/test-only to UI-exposed, retaining the warning that real Google/process validation has not been exercised in automated tests.
- [ ] Update usage and verification counts from fresh commands.
- [ ] Run `dart format` on changed Dart files.
- [ ] Run `flutter test --no-pub`.
- [ ] Run `flutter test integration_test/multi_account_flow_test.dart --no-pub` in isolation.
- [ ] Run `flutter analyze --no-pub` and report the actual diagnostic count.
- [ ] Run `flutter build windows --release --no-pub` in isolation.
