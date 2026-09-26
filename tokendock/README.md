# TokenDock

Windows 10/11 x64 desktop widget that tracks an unlimited number of independently authenticated provider connections: quota, reset time, persisted per-connection health/cooldown, and cached state. See `../PRODUCT.md` and `../PRD.txt`.

## Status

Correctness and accessibility remediation implemented. All P0 and P1 findings from the 2026-09-26 audit are closed, and `flutter analyze` is now clean — no errors, no warnings, no informational diagnostics. Registered providers are `openrouter` (`AuthKind.apiKey`), `antigravity` (`AuthKind.oauth`), `minimax`, `opencode-go` and `zai` (all `AuthKind.apiKey`), and **all five report quota**. Antigravity local mode auto-discovers a sole language-server session in memory, with a bounded discovery budget applied by the reader; remote mode uses per-account Google OAuth with actionable onboarding errors, cancellation, reconnect, refresh rotation, and cache preservation. Connections exposes persisted 1/3/5/10/manual refresh intervals; the widget shell scrolls large account sets and shows a cache age that keeps counting in every density.

Three provider traps are worth knowing before you touch this code, because each one produces a plausible-looking wrong answer rather than an error:

- **MiniMax returns HTTP 200 for a rejected credential.** The real signal is `base_resp.status_code === 0`. A parser that trusted the status line would show a full quota for a key that does not work.
- **OpenCode Go's usage route is first-party but undocumented**, and the reference implementation records that its shape changed once already. Its parse is all-or-nothing for that reason.
- **z.ai sends the raw key in `Authorization` with no `Bearer` prefix.** Prefixing it would be rejected, leaving a credential that is never actually verified while the app reports it broken.

And one rule that spans all of them: a fetch that fails or comes back incomplete must return a **non-`ok`** snapshot. `RefreshService` replaces the cached quota with whatever a snapshot carries, so "healthy, no usage data" would blank the user's card because an endpoint timed out.

The rule most likely to be got wrong, and the one that is tested hardest: **only a credential rejection revokes a credential.** A rate limit, a spent window, a spent balance and a busy provider are statements about the account at this moment, not about the key. `ProviderThrottle` is the single taxonomy; **an unrecognised code or status is transient and never revokes**, because a permissive default costs a cooldown the user did not need while an aggressive one costs them their configuration.

And the one that is easy to miss entirely: a **Reconnect** prompt comes back down when the credential next works. It used to be cleared only by editing or reconnecting by hand, so a single transient 401 nagged about a key the app was simultaneously refreshing successfully.

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

- `flutter test --no-pub`: **620/620 passed**, re-confirmed on two consecutive runs. The 366-test gate was met on three consecutive runs at `9ae626f`; 379, 386, 389, 399, 409, 410, 417, 430, 465, 507, 542, 576, 586, 597, 615 and 620 were each re-confirmed before the next change. Baseline before the 2026-09-26 session was 235.
- **Providers:** OpenRouter, Antigravity, MiniMax, OpenCode Go, z.ai — all with a real credential gate and real quota. Each of the four ported response shapes was taken from a working implementation in `can1357/oh-my-pi` rather than inferred. OpenCode Zen stays absent: its pay-as-you-go balance has no documented endpoint, and the reference implementation registers a Go usage provider and no Zen one.
- `flutter analyze --no-pub`: **no issues found**. This was 31 informational diagnostics before the lint sweep; it is now zero across errors, warnings and informational. The sweep was lint-specific and scoped per file, so no pre-existing unformatted file was reformatted as a side effect.
- `flutter build windows --release --no-pub`: **succeeds** (first run in this project, 2026-09-26), `tokendock.exe` produced in 158s. 8 C4267/C4996 warnings, all inside the third-party `cnativeapi` plugin (the `strcpy` and `size_t` conversions); **zero warnings in this repository's code**. The build requires Windows Developer Mode or an elevated shell, because Flutter creates the plugin symlinks under `windows/flutter/ephemeral/.plugin_symlinks`.
- `flutter test integration_test/multi_account_flow_test.dart -d windows`: **3/3 passed** (first run in this project, 2026-09-26). Builds a Debug binary and runs it on the `windows-x64` device. Transport is fixture-backed, so it proves independent multi-account restore/cache/failure wiring against the real `%LOCALAPPDATA%` database — **not** a live OpenRouter call.
- Release smoke: `%LOCALAPPDATA%\TokenDock\tokendock.db` is created; close hides the window to the tray; Exit terminates.
- `dart format` is clean on every file this session touched. 36 files in the tree remain unformatted; they are pre-existing and were deliberately left alone.

## Checkpoint

**Continue from `../docs/checkpoints/2026-09-26-correctness-checkpoint.md`.** It records what each audit finding's fix was, the things the execution corrected in the audit itself, the two false provider conclusions and the process error behind them, the verification actually performed, and the carry-over risks worth knowing before touching tests.

The correction to read first: an earlier revision concluded that MiniMax publishes no usage API and that OpenCode Go could not be registered. Both were wrong, and both came from generalising a single measurement — a model listing that ignores the credential, which is correct behaviour for a static catalog — without looking for the endpoint that actually meters the account. The answer for MiniMax was already written in this repository at `docs/auth-quota-hardening-plan.md`.

Two further defects in this project's own work came out of reading the reference implementation's auth more closely, and both are worth knowing because both are the kind that produce *plausible* output rather than an error: a rate limit was revoking a working credential, and a Reconnect prompt outlived the failure that raised it. The checkpoint records both, plus a **consolidated list of everything still open** — which is short, and split by whether it needs credentials, a product decision, or nothing at all.

## Known issues

- **Antigravity login is unverified against Google.** The client credentials were wrong and are now corrected from a reference implementation — wrong client, two missing scopes, no `client_secret`, no `prompt=consent` — but no successful login has been observed, only the `invalid_scope` rejection that proved the old credentials were wrong. The credentials are Google's, embedded in a public repository, and GitHub push protection blocks the commit as a detected secret. See `../PRODUCT.md` and the checkpoint; this is unresolved and is a maintainer decision.
- **The window can restore off-screen.** PRD §60 requires that a window whose monitor no longer exists moves to the primary display. There is no `Screen`/`bounds` handling in `lib/`, and the app has been observed restoring itself entirely off-screen on a second display. Until fixed, the window may need to be dragged back into view.

Carry-over risks worth knowing before touching tests: `redactSecret` does not catch a bare token with no `key:` prefix, which is why every user-facing error string is a call-site literal; test fakes keyed to a repository call ordinal go silently inert when a method changes, which bit twice this session; and a local-reader test that injects a discovery returning no sessions falls through to the real `agy` CLI unless a refusing `AntigravityProcessRunner` is injected.

## First use

1. Open the widget from the tray: `No connections yet` → `Add Connection`.
2. Enter provider `OpenRouter`, a display name, optional group, and the API key credential.
3. `Test Connection` must succeed before Save enables.
4. Repeat for any number of accounts. Refresh with Ctrl+R (ignored inside text fields), the header button, or the tray menu. TokenDock has no configured account-count limit; refresh remains bounded to four concurrent requests.

## Security model

- SQLite holds only opaque credential references (`secret_ref`); secret values live only in `flutter_secure_storage` v11, which encrypts them at rest into `%APPDATA%\<CompanyName>\<ProductName>\flutter_secure_storage.dat` (user-scope: same Windows user + machine; file backend, not Credential Locker). **Not DPAPI**, despite what earlier revisions of this file said — the plugin applies its own cipher instead of `CryptProtectData`. `integration_test/secret_store_windows_test.dart` asserts against the real plugin that the plaintext never reaches disk. `CompanyName` is now `TokenDock`, so the path is `%APPDATA%\TokenDock\tokendock\`; a store left in the old `com.example` folder by an earlier build is relocated on first launch by `lib/storage/secret_store_migration.dart`. Dev secrets stored under v9 may not migrate - delete `%LOCALAPPDATA%\TokenDock\tokendock.db` or re-register keys if `read` returns null.
- `Test Connection` validates through `GET https://openrouter.ai/api/v1/key`; no inference or usage is created. Timeouts: 10s connect, 15s response.
- Saved credentials show a masked preview (leading characters plus last four), never the full secret. Short secrets render `****`.
- Logs, errors, and UI text carry only user-safe status copy (`Invalid API key`, `Key limit exceeded`, `Rate limited`, `Timeout`, `Provider unavailable`, `Unknown response`).
- No real key exists in source control or tests; fixtures are sanitized.

## Not in this slice

No installer, portable ZIP, auto-start, charts, history, notifications, command palette, cloud sync, analytics, plugin system, or web/mobile builds. OpenCode Zen remains deferred — its pay-as-you-go balance has no documented endpoint.

The PRD's 0.3 roadmap also names **GitHub Copilot, Codex, Claude and the Gemini API**. None is registered, and none is stubbed. Each needs a new *auth flow* rather than an adapter: a GitHub entitlement token, a per-CLI OAuth exchange, or its own token exchange. The Gemini CLI case additionally obtains higher rate limits by presenting the official Gemini CLI `User-Agent`, which is a terms-of-service decision for the maintainer rather than something to decide silently in an adapter. Each blocker is written up in the checkpoint.

## Further reading

- `../docs/auth-research-oh-my-pi-9router.md` — auth patterns from `can1357/oh-my-pi` and `decolua/9router`.
- `../docs/auth-quota-hardening-plan.md` — implemented OpenRouter auth/secrets/quota hardening merged in `master` (`17d489e`).
