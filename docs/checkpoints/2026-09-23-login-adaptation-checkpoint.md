# TokenDock checkpoint — login adaptation and Antigravity

**Date:** 2026-09-23  
**Branch:** `master`  
**Checkpoint parent:** `b03190e`  
**Status:** implementation merged locally; no implementation worktree registered.

## Completed

- OpenRouter quota hardening merged and preserved: 401/402/403/429/503 classification, `Retry-After`, per-connection cooldown/health, cache-first recovery, and credential redaction.
- Login infrastructure merged: `AuthKind`, `Migration003` (`identity_key`, `provider_data`, SQLite `user_version = 3`), refreshable credentials, per-connection single-flight, OAuth loopback, tombstones, reconnect state, and schema quarantine.
- Antigravity adaptation merged using patterns from Oh My Pi and 9router:
  - Explicit local `language-server` / `agy-cli` source selection.
  - In-memory CSRF discovery and recursive SQLite sanitization.
  - Per-account remote OAuth with form-encoded Google token requests, PKCE S256, external loopback browser, stable refresh-token handling, reuse revocation, and bounded `Retry-After` + Full Jitter retries.
- Documentation synchronized across `PRODUCT.md`, `PRD.txt`, `tokendock/README.md`, and `docs/auth-quota-hardening-plan.md`.

## Verification

- `flutter test --no-pub`: **197/197 passed**.
- `flutter analyze`: **0 errors, 0 warnings, 7 pre-existing informational diagnostics**; command exits nonzero because of infos.
- No real Google OAuth, external browser, Antigravity process, or Windows integration flow was exercised. Tests use sanitized fake HTTP/process fixtures.
- Latest Windows integration attempt now fails during native compilation with:

```text
flutter_secure_storage_windows_plugin.cpp(6,10): error C1083:
Não é possível abrir arquivo incluir: 'atlstr.h'
```

The previous symlink/Developer Mode error is no longer the first blocker in this environment.

## Resume checklist

1. In Visual Studio Installer, enable **C++ ATL for latest v143 build tools (x86 & x64)** under Individual components.
2. Restart the terminal and run:

   ```powershell
   cd D:/Projetos/TokenDock/tokendock
   flutter clean
   flutter pub get
   flutter test integration_test/multi_account_flow_test.dart --no-pub
   ```

3. If the integration test passes, wire Antigravity login and source selection into the Connections UI.
4. Validate one real Google account, external browser callback, and one real Antigravity process.
5. Keep MiniMax blocked until an official response schema is published.
6. Decide separately whether to implement adaptive polling, sibling-account fallback, groups, notifications, installer, and release 0.1.

## Non-goals for the next session

- Do not infer undocumented Antigravity quota fields.
- Do not add device-code or embedded WebView login.
- Do not store CSRF, access, refresh, or ID tokens in SQLite.
- Do not push or merge another branch without an explicit integration request.
