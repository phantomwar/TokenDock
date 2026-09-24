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
- Approved technical design: `docs/superpowers/specs/2026-09-22-tokendock-first-functional-goal-design.md`.
- Visual references: `docs/imagens/windows-tray-dashboard.png`, `docs/imagens/HS0mcVHagAAQYiG.jpg`, `docs/imagens/HS0mbP5agAEg0nP.png`, `docs/imagens/HSzxw_Sb0AARFwe.png`, and `docs/imagens/HSzxv9UaIAAOXbw.jpg`.
- Sanitized OpenRouter fixtures exist at `tokendock/test/fixtures/` (finite, unlimited, malformed, and 402 payloads). No real API key exists in source control or tests. No installer, portable ZIP, Start Menu entries, auto-start behavior, user research, commercial claims, or final brand assets exist yet.
- Research: `docs/auth-research-oh-my-pi-9router.md` (auth patterns from `can1357/oh-my-pi` and `decolua/9router`, 2026-09-23) and `docs/auth-quota-hardening-plan.md` (phased auth/secrets/quota hardening plan correlated with 2026 OAuth, Windows-secrets, and rate-limit trends; implementation status is recorded below).

## Implementation Status

- Status: login adaptation, final-review recovery, and Connections UI wiring are implemented in the current working tree; Windows 10/11 x64 only.
- Provider list: `openrouter` and `antigravity` are registered. OpenRouter uses `AuthKind.apiKey`; Antigravity uses `AuthKind.oauth` and dispatches only explicit `providerData.source` values `language-server` or `agy-cli` to the local reader. Remote is the default and remains available when source is absent or `remote`.
- `Migration001` creates `auth_type`; `Migration003` adds `identity_key` and `provider_data` and sets SQLite `user_version = 3`. `AppDatabase.open` runs `Migration001`–`Migration003`.
- OpenRouter retains quota hardening: 401 invalid credentials, 402 insufficient credits except documented in-flight-budget responses with `Retry-After`, 403 forbidden, and 429/503 honoring valid `Retry-After`; failures preserve cached quotas and redact current credential fields.
- Antigravity local read-only quota is explicit opt-in through the Connections UI: language-server sources then bounded `agy` CLI fallback, account mismatch rejection, strict fraction validation, and no credential custody. CSRF values live only in the injected in-memory runtime configuration; SQLite `provider_data` is sanitized before persistence.
- Antigravity remote OAuth is exposed through the Connections UI with external loopback browser + PKCE, form-encoded Google token requests, least scopes, isolated refreshable secrets, per-connection operation lock, typed failure causes, account guard, quota retrieval, onboarding prompt, bounded Full Jitter retries after `Retry-After`, rotated-token reuse revocation, durable schema quarantine, and reconnect while preserving cache. Access, refresh, ID, and CSRF values never enter SQLite. Real Google/browser/process validation remains pending.
- Per-connection health is persisted alongside auth metadata. Active cooldowns skip only that connection; successful refresh clears the cooldown. Timer cadence remains fixed; adaptive polling and automatic account fallback are not implemented.
- Connections have no configured count limit. Refresh is manual, Ctrl+R/Cmd+R (disabled while a text field has focus), tray action, and one periodic timer (default 3 minutes; 1/3/5/10/manual), with at most four concurrent connection refreshes and same-ID coalescing. The concurrency cap controls simultaneous work, not the number of saved accounts. OAuth refresh, test-time credential rotation, and Antigravity reconnect share the per-connection operation lock.
- Cache-first: cached quotas render immediately; refresh failures preserve prior values and show `Last updated <relative age>`; past resets render `Resetting…`.
- Window/tray: frameless 360x600 window, hide-to-tray on close, explicit Exit; tray menu exposes Open TokenDock, Refresh All, Always on Top, Connections, and Exit, with double-click restoring the widget.
- Credentials: UUIDv4 references in `%LOCALAPPDATA%\TokenDock\tokendock.db`; secret values only in DPAPI-backed `flutter_secure_storage` (`^11.2.0`, user-scope file backend on Windows, no Credential Locker). Saved credentials display a masked preview (leading characters plus last four), never the full secret.

## Verification Evidence

- Baseline evidence at `7154db3`: `flutter test` 96/96; `flutter test integration_test/multi_account_flow_test.dart` 3/3; `flutter analyze` 0 errors and 0 warnings; Windows release build succeeds.
- Covered: compact/normal/expanded layouts, light/dark/high-contrast themes, keyboard-only flows (Tab/Enter/Space reach Add Connection), reduced motion, test-before-save CRUD with credential compensation, refresh concurrency and coalescing, cache preservation, more-than-three-account isolation, provider/source selection, local keyless Antigravity connections, remote onboarding, cancellation, and reconnect compensation.
- Current evidence: full `flutter test --no-pub` passes 227 tests; focused provider OAuth (21/21), AppState (20/20), RefreshService (24/24), and ConnectionsScreen (27/27) suites pass; the Windows integration suite builds and passes 3/3 when run in isolation, and the release build succeeds. `flutter analyze` reports 0 errors and 0 warnings with 33 informational diagnostics and exits nonzero. No real Google integration, external browser launch, or Antigravity process was exercised; those tests use sanitized fake HTTP/process fixtures.

## Product Principles

1. Cache-first truth: a usable last-known value is more valuable than an empty card during a provider failure.
2. Independent accounts: a connection's credential, result, error, and cache never leak into another connection.
3. Glance before detail: lead with the quota that determines where the user can work next.
4. Local by default: credentials are references in SQLite and values in platform-backed secure storage.
5. Calm operational clarity: visual emphasis marks action or risk, not decoration.

## Accessibility & Inclusion

Meet WCAG 2.2 Level AA contrast for text and essential controls; expose a visible keyboard focus state and logical tab order; retain text and icon/symbol status labels alongside color; honor Windows text scaling, contrast themes, and reduced-motion preferences; keep all core flows keyboard-operable.
