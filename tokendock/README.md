# TokenDock

Windows 10/11 x64 desktop widget that tracks an unlimited number of independently authenticated provider connections: quota, reset time, persisted per-connection health/cooldown, and cached state. See `../PRODUCT.md` and `../PRD.txt`.

## Status

Login adaptation, final-review recovery, and Connections UI wiring are implemented in the current working tree. Registered providers are `openrouter` (`AuthKind.apiKey`) and `antigravity` (`AuthKind.oauth`). Antigravity local mode exposes explicit `language-server` and `agy-cli` read-only sources; remote mode uses per-account Google OAuth. Local CSRF custody is in-memory and sanitized out of SQLite `provider_data`. Google authorization-code and refresh calls are form-encoded, v1internal RPCs remain JSON, transient quota calls use bounded Full Jitter retries, schema changes durably quarantine the connection, and definitive failures retain cached quotas while showing a Reconnect action. OAuth credentials are stored only in secure storage; real Google/browser/process validation remains pending.

## Run

```powershell
flutter pub get
flutter test
flutter test integration_test/multi_account_flow_test.dart
flutter analyze
flutter run -d windows
flutter build windows --release
```

- `flutter test --no-pub`: 227/227 tests passed.
- `flutter test integration_test/multi_account_flow_test.dart --no-pub`: Windows Debug build and 3/3 tests passed when run in isolation.
- `flutter analyze --no-pub`: 0 errors and 0 warnings; 33 informational diagnostics, so the command exits nonzero.
- `flutter build windows --release --no-pub`: succeeds; plugin C/C++ conversion and `strcpy` warnings remain.
- `flutter run -d windows`: frameless 360x600 widget; first run shows `No connections yet` with one `Add Connection` action.
- Release smoke: `%LOCALAPPDATA%\TokenDock\tokendock.db` is created; close hides the window to the tray; Exit terminates.

## Checkpoint

Checkpoint date: 2026-09-23. The previous C++ ATL integration blocker is resolved in the current environment. Antigravity provider/source selection, remote onboarding, cancellation, and reconnect are now wired into the Connections UI. Resume with validation of one real Google account, external browser callback, and one real Antigravity process. See `../docs/checkpoints/2026-09-23-login-adaptation-checkpoint.md`.

## First use

1. Open the widget from the tray: `No connections yet` → `Add Connection`.
2. Enter provider `OpenRouter`, a display name, optional group, and the API key credential.
3. `Test Connection` must succeed before Save enables.
4. Repeat for any number of accounts. Refresh with Ctrl+R (ignored inside text fields), the header button, or the tray menu. TokenDock has no configured account-count limit; refresh remains bounded to four concurrent requests.

## Security model

- SQLite holds only opaque credential references (`secret_ref`); secret values live only in DPAPI-backed `flutter_secure_storage` v11 (user-scope: same Windows user + machine; file backend, not Credential Locker). Dev secrets stored under v9 may not migrate — delete `%LOCALAPPDATA%\TokenDock\tokendock.db` or re-register keys if `read` returns null.
- `Test Connection` validates through `GET https://openrouter.ai/api/v1/key`; no inference or usage is created. Timeouts: 10s connect, 15s response.
- Saved credentials show a masked preview (leading characters plus last four), never the full secret. Short secrets render `****`.
- Logs, errors, and UI text carry only user-safe status copy (`Invalid API key`, `Key limit exceeded`, `Rate limited`, `Timeout`, `Provider unavailable`, `Unknown response`).
- No real key exists in source control or tests; fixtures are sanitized.

## Not in this slice

No installer, portable ZIP, auto-start, charts, history, notifications, command palette, cloud sync, analytics, plugin system, web/mobile builds, or additional providers. OpenCode Go remains deferred: no verified public subscription-quota API. MiniMax remains blocked until an official response schema is available.

## Further reading

- `../docs/auth-research-oh-my-pi-9router.md` — auth patterns from `can1357/oh-my-pi` and `decolua/9router`.
- `../docs/auth-quota-hardening-plan.md` — implemented OpenRouter auth/secrets/quota hardening merged in `master` (`17d489e`).
