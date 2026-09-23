# TokenDock

Windows 10/11 x64 desktop widget that tracks up to three independent OpenRouter API-key connections: quota, reset time, persisted per-connection health/cooldown, and cached state. See `../PRODUCT.md` and `../PRD.txt`.

## Status

Login adaptation and final-review recovery are implemented in the current worktree. Registered providers are `openrouter` (`AuthKind.apiKey`) and `antigravity` (`AuthKind.oauth`). Antigravity routes only explicit `providerData.source` values `language-server` and `agy-cli` to the opt-in local reader; absent/`remote` source uses per-account remote OAuth. `Migration001` creates `auth_type`; `Migration003` adds `identity_key` and `provider_data` and sets SQLite `user_version = 3`. Both Antigravity flows are backend/test-only and are not wired into the Connections UI. OpenRouter hardening and Antigravity quota/auth handling are covered by sanitized fake HTTP/process fixtures; no real Google integration or real browser launch was exercised.

## Run

```powershell
flutter pub get
flutter test
flutter test integration_test/multi_account_flow_test.dart
flutter analyze
flutter run -d windows
flutter build windows --release
```

- `flutter test --no-pub`: 179/179 tests passed.
- `flutter test integration_test/multi_account_flow_test.dart`: Windows integration build requires symlink support/Developer Mode; pending in this environment (baseline had 3 fixture-backed proofs: independent restore, cache replacement on success, cache preservation on timeout, restart restore from cache).
- `flutter analyze`: 0 errors and 0 warnings; 7 informational diagnostics (one null-aware-elements suggestion and six pre-existing RefreshService initializing-formals suggestions).
- `flutter run -d windows`: frameless 360x600 widget; first run shows `No connections yet` with one `Add Connection` action.
- Release smoke: `%LOCALAPPDATA%\TokenDock\tokendock.db` is created; close hides the window to the tray; Exit terminates.

## First use

1. Open the widget from the tray: `No connections yet` → `Add Connection`.
2. Enter provider `OpenRouter`, a display name, optional group, and the API key credential.
3. `Test Connection` must succeed before Save enables.
4. Repeat for up to three accounts. Refresh with Ctrl+R (ignored inside text fields), the header button, or the tray menu.

## Security model

- SQLite holds only opaque credential references (`secret_ref`); secret values live only in DPAPI-backed `flutter_secure_storage` v11 (user-scope: same Windows user + machine; file backend, not Credential Locker). Dev secrets stored under v9 may not migrate — delete `%LOCALAPPDATA%\TokenDock\tokendock.db` or re-register keys if `read` returns null.
- `Test Connection` validates through `GET https://openrouter.ai/api/v1/key`; no inference or usage is created. Timeouts: 10s connect, 15s response.
- Saved credentials show a masked preview (leading characters plus last four), never the full secret. Short secrets render `****`.
- Logs, errors, and UI text carry only user-safe status copy (`Invalid API key`, `Key limit exceeded`, `Rate limited`, `Timeout`, `Provider unavailable`, `Unknown response`).
- No real key exists in source control or tests; fixtures are sanitized.

## Not in this slice

No installer, portable ZIP, auto-start, charts, history, notifications, command palette, cloud sync, analytics, plugin system, web/mobile builds, or additional providers. OpenCode Go remains deferred: no verified public subscription-quota API.

## Further reading

- `../docs/auth-research-oh-my-pi-9router.md` — auth patterns from `can1357/oh-my-pi` and `decolua/9router`.
- `../docs/auth-quota-hardening-plan.md` — implemented OpenRouter auth/secrets/quota hardening merged in `master` (`17d489e`).
