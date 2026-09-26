# Product

<!-- impeccable:product-schema 1 -->

## Platform

adaptive

## Stack

Flutter desktop application targeting Windows 10/11 x64. The first release does not enable web, mobile, macOS, or Linux targets.

## Users

People who maintain multiple paid AI subscriptions, local accounts, and API keys and need to identify the account with remaining quota without opening each provider dashboard.

## Product Purpose

TokenDock is a lightweight always-available desktop widget that shows the current quota, reset time, connection health, and cached state for several AI-provider accounts. Success is a trustworthy at-a-glance answer to: “Which of my subscriptions still has limit?”

## Positioning

A local, single-process Windows widget that aggregates independently authenticated AI accounts while keeping credentials outside its SQLite database.

## Operating Context

The app is opened from the Windows tray, then remains visible beside everyday work. Users add, test, refresh, edit, enable, or remove provider connections. The app starts from local cache and refreshes in the background, including when a provider is temporarily unavailable.

## Capabilities and Constraints

- Connections are not capped by account count; providers and local resources may impose their own operational constraints. Compact, normal, and expanded widget modes; tray behavior; SQLite cache; DPAPI-backed credential storage; and manual/periodic refresh are supported. OpenCode Go remains deferred because it has no verified public subscription-quota API.
- One local process, one local SQLite database, no server, cloud service, analytics, or plugin system.
- The UI must preserve prior cached values after a fetch failure and must never rely on color alone for status.
- Provider endpoints and response contracts must be established from official provider documentation before implementation; they are not guessed from product requirements.

## Brand Commitments

- The user-provided references in `docs/imagens/` are binding visual evidence: quiet, high-contrast operational interfaces; warm off-white surfaces; near-black anchors; rounded modules; sparse but intentional vivid green/lime emphasis; restrained semantic status color; clean sans-serif typography.
- The interface must stay desktop-native, readable at a glance, and calm enough to remain on-screen all day. It must not become a generic analytics dashboard or a neon/gamified AI interface.

## Evidence on Hand

- Product requirements: `PRD.txt`.
- Correctness audit of 2026-09-26: `docs/audit-2026-09-25-second-pass.md` (36 findings with per-item state), its plan `docs/superpowers/plans/2026-09-25-tokendock-correctness-plan.md`, and its checkpoint `docs/checkpoints/2026-09-26-correctness-checkpoint.md`.
- Approved technical design: `docs/superpowers/specs/2026-09-22-tokendock-first-functional-goal-design.md`.
- Visual references: `docs/imagens/windows-tray-dashboard.png`, `docs/imagens/HS0mcVHagAAQYiG.jpg`, `docs/imagens/HS0mbP5agAEg0nP.png`, `docs/imagens/HSzxw_Sb0AARFwe.png`, and `docs/imagens/HSzxv9UaIAAOXbw.jpg`.
- Sanitized OpenRouter fixtures exist at `tokendock/test/fixtures/` (finite, unlimited, malformed, and 402 payloads). No real API key exists in source control or tests. No installer, portable ZIP, Start Menu entries, auto-start behavior, user research, commercial claims, or final brand assets exist yet.
- Research: `docs/auth-research-oh-my-pi-9router.md` (auth patterns from `can1357/oh-my-pi` and `decolua/9router`, 2026-09-23) and `docs/auth-quota-hardening-plan.md` (phased auth/secrets/quota hardening plan correlated with 2026 OAuth, Windows-secrets, and rate-limit trends; implementation status is recorded below).

## Implementation Status

- Status: correctness and accessibility remediation implemented. All P0 and P1 findings from `docs/audit-2026-09-25-second-pass.md` are closed; Windows 10/11 x64 only. See `docs/checkpoints/2026-09-26-correctness-checkpoint.md`.
- Provider list: `openrouter` and `antigravity` are registered. OpenRouter uses `AuthKind.apiKey`; Antigravity uses `AuthKind.oauth` and dispatches only explicit `providerData.source` values `language-server` or `agy-cli` to the local reader. Remote is the default and remains available when source is absent or `remote`.
- `Migration001` creates `auth_type`; `Migration003` adds `identity_key` and `provider_data`; `Migration004` rebuilds `quota_cache` to declare `FOREIGN KEY (connection_id) REFERENCES connections(id) ON DELETE CASCADE`, drops the dead `status` column and the index the composite primary key already covered, and adds `idx_connections_sort_order` on `(sort_order, created_at)`. `AppDatabase.open` runs `Migration001`–`Migration004` and then applies `PRAGMA foreign_keys = ON`.
- The pragma is applied **after** the migrations on purpose. `PRAGMA foreign_keys` is a no-op inside a transaction, so enabling it earlier — including through sqflite's `onConfigure`, which fires before the hand-rolled migrations run — would leave enforcement active across the rebuild that declaring the cascade requires, and no statement in that migration can turn it off. Measured: a rebuild with one pre-existing orphan row fails with SQLite error 787. `Migration004` therefore filters orphans out of the copy with `WHERE EXISTS`, which also keeps the migration from aborting, and gates the rebuild on `PRAGMA foreign_key_list` so a run whose DDL committed without its version marker is recognised as already done.
- Migrations stamp `user_version` inside the DDL transaction and gate `ALTER TABLE` on `PRAGMA table_info`, so an interrupted migration is resumable instead of failing on `duplicate column name`.
- Storage reads degrade rather than throw: an unparseable `reset_at`, `last_checked_at` or `cooldown_until` becomes null instead of failing the read for every connection.
- `provider_data` is sanitised through the shared `isSensitiveKeyName` predicate, so `accessToken`, `refreshToken`, `idToken`, `apiKey` and `csrfToken` are all stripped at any nesting depth. Non-secret metadata (`source`, `projectId`, `tier`) is preserved.
- OpenRouter retains quota hardening: 401 invalid credentials, 402 insufficient credits except documented in-flight-budget responses with `Retry-After`, 403 forbidden, and 429/503 honoring valid `Retry-After`; failures preserve cached quotas and redact current credential fields.
- Antigravity local read-only quota is explicit opt-in through the Connections UI. Session discovery is bounded by a five-second budget applied by the reader, and a failed or unresponsive discovery means "no session found" rather than a stalled or throwing refresh. Account mismatch rejection, strict fraction validation, and no credential custody remain mandatory. CSRF values never enter SQLite.
- Antigravity remote OAuth is exposed through the Connections UI with external loopback browser + PKCE, form-encoded Google token requests, least scopes, isolated refreshable secrets, per-connection operation lock, typed failure causes, account guard, quota retrieval, actionable onboarding-required copy, bounded Full Jitter retries after `Retry-After`, rotated-token reuse revocation, durable schema quarantine, and reconnect while preserving cache. The loopback port is bound exclusively on both IPv4 and IPv6, so no other local process can take it. A stored credential that cannot be parsed is reported as unreadable rather than sent as a bearer token. Access, refresh, ID, and CSRF values never enter SQLite. Real Google/browser/process validation remains pending.
- Credential exchange is single-flight per connection in two places: `RefreshService.runTokenOperation` for refresh and probe paths, and the provider for its own test-time refresh, which bypasses the service. A rotating refresh token is now exchanged once per connection, and the grant is revoked only on positive evidence of reuse rather than on any `invalid_grant`. The rotated-token ledger is a bounded 32-entry window.
- Per-connection health is persisted alongside auth metadata. Active cooldowns skip only that connection; successful refresh clears the cooldown. Timer cadence remains fixed; adaptive polling and automatic account fallback are not implemented.
- Connections have no configured count limit. Refresh is manual, Ctrl+R/Cmd+R (disabled while a text field has focus), tray action, and one periodic timer. Connections exposes the persisted 1/3/5/10/manual selector; manual cancels the timer, and other stored values normalize to the 3-minute default. At most four connection refreshes run concurrently and same-ID operations coalesce.
- Read cost is independent of account count: `ConnectionRepository.getById` serves per-connection work, `getAllWithHealth` returns a connection with the health already on its row, and `QuotaCacheRepository.getAllForAll` loads every cached quota in one query. A refresh cycle reads the connections table once instead of once per connection, and startup issues two queries instead of `1 + 2N`.
- Cache-first: cached quotas render immediately; refresh failures preserve prior values and show `Last updated <relative age>` in compact, normal, and expanded modes, and that age keeps counting. Past resets render `Resetting…`. A quota with no provider cap renders `No key cap`, which is distinct from the `Unavailable` used for genuine failures.
- The authoritative quota value renders in full-contrast ink rather than the muted tone reserved for metadata, in both the quota row and compact density. Countdown and cache-age labels tick every 30 seconds, the shortest interval that can change an hours-and-minutes label.
- User-facing error copy never interpolates an exception object. `userSafeErrorMessage` maps known failures to deliberate wording and otherwise returns a fixed per-call-site literal, so SQL, table names, column names, driver codes and credential-shaped text cannot reach the UI.
- Window/tray: frameless 360x600 window, hide-to-tray on close, explicit Exit, and a scrollable widget shell for large connection sets. The tray menu exposes Open TokenDock, Refresh All, Always on Top, Connections, and Exit, with double-click restoring the widget.
- Credentials: UUIDv4 references in `%LOCALAPPDATA%\TokenDock\tokendock.db`; secret values only in DPAPI-backed `flutter_secure_storage` (`^11.2.0`, user-scope file backend on Windows, no Credential Locker). Saved credentials display a masked preview (leading characters plus last four), never the full secret.

## Verification Evidence

- Baseline evidence at `7154db3`: `flutter test` 96/96; `flutter test integration_test/multi_account_flow_test.dart` 3/3; `flutter analyze` 0 errors and 0 warnings; Windows release build succeeds.
- Covered: compact/normal/expanded layouts, large-account scrolling, stale-age metadata in every density, light/dark/high-contrast themes, keyboard-only flows (Tab/Enter/Space reach Add Connection), reduced motion, test-before-save CRUD with credential compensation, persisted refresh interval selection, refresh concurrency and coalescing, cache preservation, more-than-three-account isolation, provider/source selection, ephemeral language-server discovery, local keyless Antigravity connections, remote onboarding, actionable onboarding-required errors, cancellation, and reconnect compensation.
- Current evidence at `ddd03f7`: `flutter test --no-pub` passes **386 tests**; the 366-test gate was met on three consecutive runs at `9ae626f`, 379/379 was re-confirmed on three consecutive runs before the density change, and the tests added since are verified in isolation. `flutter analyze` reports **0 errors, 0 warnings, 31 informational diagnostics** — the same count as before this work, with none in the touched files. Prior baseline was 235 tests and 33 diagnostics.
- Newly covered: WCAG AA contrast across all three ramps for every text pair that renders, plus non-text pairs, ramp independence and hue preservation; a source guard that fails if any `lib/` file outside `theme.dart` uses the Material palette; error-copy safety for storage and provider failures; credential-integrity tests for unreadable and truncated secrets; refresh-token rotation, reuse detection and the bounded ledger; OAuth loopback exclusivity; bounded session discovery and defensive discovery parsing; corrupt-row and migration-crash recovery; and query-cost assertions proving the refresh and load paths do not scale with account count.
- Schema integrity is now enforced by the database rather than by application code: a v3 file is upgraded on disk through a real restart, the declared cascade is asserted via `PRAGMA foreign_key_list`, enforcement is asserted via `PRAGMA foreign_keys`, an orphaned cache row is proven to be purged rather than carried forward, a stale `user_version` over an already-rebuilt table is proven resumable, and the retired column and index are proven gone. Turning the pragma on inside `TestDatabase` also exposed two fixtures that were caching quotas for connections that never existed.
- The three widget densities share one frame and cannot drift: all of them render the cache age and the error line, and a table-driven suite asserts the parity across the three widths. Compact previously omitted the error, so a failing account showed a stale quota number in the default density with no visible reason while the other two densities explained themselves.
- **Not verified in the 2026-09-26 session:** `flutter build windows --release` and `integration_test/multi_account_flow_test.dart` were not run; both need the full Windows toolchain. Their README lines are unchanged and remain unverified by this work.
- No real Google integration, external browser launch, or Antigravity process was exercised; those tests use sanitized fake HTTP/process fixtures.

## Product Principles

1. Cache-first truth: a usable last-known value is more valuable than an empty card during a provider failure.
2. Independent accounts: a connection's credential, result, error, and cache never leak into another connection.
3. Glance before detail: lead with the quota that determines where the user can work next.
4. Local by default: credentials are references in SQLite and values in platform-backed secure storage.
5. Calm operational clarity: visual emphasis marks action or risk, not decoration.

## Accessibility & Inclusion

Meet WCAG 2.2 Level AA contrast for text and essential controls; expose a visible keyboard focus state and logical tab order; retain text and icon/symbol status labels alongside color; honor Windows text scaling, contrast themes, and reduced-motion preferences; keep all core flows keyboard-operable.
