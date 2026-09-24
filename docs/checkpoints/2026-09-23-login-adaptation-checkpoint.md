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

- `flutter test --no-pub`: **227/227 passed**.
- Focused suites: AppState 20/20, RefreshService 24/24, ConnectionsScreen 27/27, provider OAuth 21/21.
- `flutter analyze`: **0 errors, 0 warnings, 33 informational diagnostics**; command exits nonzero because infos.
- Windows integration passed 3/3 when run in isolation; Windows release build succeeds.
- No real Google OAuth, external browser, or Antigravity process was exercised. Tests use sanitized fake HTTP/process fixtures.

## Resume checklist

1. Validate one real Google account, external browser callback, refresh-token rotation, and one real Antigravity process.
2. Keep MiniMax blocked until an official response schema is published.
3. Decide separately whether to implement adaptive polling, sibling-account fallback, groups, notifications, installer, and release 0.1.


## Non-goals for the next session

- Do not infer undocumented Antigravity quota fields.
- Do not add device-code or embedded WebView login.
- Do not store CSRF, access, refresh, or ID tokens in SQLite.
- Do not push or merge another branch without an explicit integration request.
