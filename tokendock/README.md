# TokenDock

Windows 10/11 x64 desktop widget that tracks an unlimited number of independently authenticated provider connections: quota, reset time, persisted per-connection health/cooldown, and cached state. See `../PRODUCT.md` and `../PRD.txt`.

## Status

Correctness and accessibility remediation implemented. All P0 and P1 findings from the 2026-09-26 audit are closed. Registered providers are `openrouter` (`AuthKind.apiKey`) and `antigravity` (`AuthKind.oauth`). Antigravity local mode auto-discovers a sole language-server session in memory, with a bounded discovery budget applied by the reader; remote mode uses per-account Google OAuth with actionable onboarding errors, cancellation, reconnect, refresh rotation, and cache preservation. Connections exposes persisted 1/3/5/10/manual refresh intervals; the widget shell scrolls large account sets and shows a cache age that keeps counting in every density.

Reliability properties now enforced by tests rather than by convention: a refresh cycle reads the connections table once instead of once per connection; credential exchange is single-flight per connection in both the service and the provider; the OAuth loopback port is bound exclusively on IPv4 and IPv6; the OAuth transport and the local session discovery are both time-bounded; a stored credential that cannot be parsed is reported rather than sent; migrations are resumable; a corrupt cache row degrades instead of failing every connection; and user-facing error copy never interpolates an exception, so SQL, table names and credential-shaped text cannot reach the UI.

## Run

```powershell
flutter pub get
flutter test
flutter test integration_test/multi_account_flow_test.dart
flutter analyze
flutter run -d windows
flutter build windows --release
```

- `flutter test --no-pub`: **379/379 passed** (`6b93b7b`). The 366-test gate was met on three consecutive runs at `9ae626f`; the 13 tests added since are verified in isolation. Baseline before the 2026-09-26 session was 235.
- `flutter analyze --no-pub`: **0 errors, 0 warnings, 31 informational diagnostics**. Unchanged from before `6b93b7b`, with none in the files it touched. Baseline was 33.
- `flutter test integration_test/multi_account_flow_test.dart --no-pub`: **not run in the 2026-09-26 session**; unchanged from the previous baseline of 3/3 and still unverified by this work.
- `flutter build windows --release --no-pub`: **not run in the 2026-09-26 session**; previously succeeded, with plugin C/C++ conversion and `strcpy` warnings remaining.
- `flutter run -d windows`: frameless 360x600 scrollable widget; first run shows `No connections yet` with one `Add Connection` action.
- Release smoke: `%LOCALAPPDATA%\TokenDock\tokendock.db` is created; close hides the window to the tray; Exit terminates.
- `dart format` is clean on every file the session touched. 36 files in the tree remain unformatted; they are pre-existing and were deliberately left alone.

## Checkpoint

**Continue from `../docs/checkpoints/2026-09-26-correctness-checkpoint.md`.** It records the 21 local commits, what each finding's fix was, the seven things the execution corrected in the audit itself, the verification actually performed, and a resume checklist ordered by value: C-23 schema integrity (no foreign key, redundant index, dead column), C-22 density parity, C-19 typography against the spec, C-24 the `Expando`-backed notifier, then dead code and cleanup.

Carry-over risks worth knowing before touching tests: `redactSecret` does not catch a bare token with no `key:` prefix, which is why every user-facing error string is a call-site literal; test fakes keyed to a repository call ordinal go silently inert when a method changes, which bit twice this session; and a local-reader test that injects a discovery returning no sessions falls through to the real `agy` CLI unless a refusing `AntigravityProcessRunner` is injected.

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
