# TokenDock First Functional Goal Design

**Goal:** Deliver a Windows desktop widget that securely tracks and refreshes any number of independent OpenRouter API-key connections, keeps a usable cached view offline, and remains available through the system tray.

**Source:** `PRD.txt`, sections 1–41, 67–71, 83–90, and 94–97.

## Implementation status — first slice complete (2026-09-23, `master` `7154db3`); deps upgraded same day (`flutter_secure_storage ^11.2.0`, `sqflite_common_ffi ^2.4.3`); OpenRouter quota hardening merged later the same day (`master` `17d489e`)

- All contracts above are implemented in `tokendock/` and verified: 96 widget/unit tests, 3 fixture-backed integration proofs, `flutter analyze` clean, and a Windows release build that runs. Re-verified after the v11 upgrade: 96/96 + 3/3 + analyze 0 errors (5 pre-existing infos) + release build ok. Hardening merged at `17d489e`: classification 401/402/403/429/503, documented `Retry-After`, per-connection persisted health/cooldown (`Migration002`, `user_version = 2`), cache preservation, secret redaction, cooldown cleared on success; re-verified `flutter test --no-pub` 109/109, `analyze` 0 errors/0 warnings/5 infos, Windows integration pending on symlink/Developer Mode.
- Deviations from this design text: `secure_secret_store.dart` is the shipped filename for the adapter this document calls `dpapi_secret_store.dart`; production never renders the original five-provider mock data — first run shows skeleton rows, then `No connections yet` with one `Add Connection` action; seeded fixtures live only in `test/fixtures/` and `test/support/`.
- Live-provider end-to-end against three real OpenRouter keys was not exercised; see the scope guard and the review record in `.superpowers/sdd/tokendock-openrouter-first-goal/task-12-review.md`.
- Post-slice research: `docs/auth-research-oh-my-pi-9router.md`; hardening implemented and merged per `docs/auth-quota-hardening-plan.md`.

## Scope

This design implements the approved first functional slice. OpenRouter replaces OpenCode Go as the first live provider because it exposes an official API-key quota contract; the technical architecture and multi-account validation goal remain unchanged. Connection count is not capped.

```text
TokenDock.exe
→ attractive responsive widget
→ tray resident after close
→ add, test, and save independent OpenRouter API-key connections
→ protect every connection credential
→ independently fetch and display key limits and remaining credit
→ refresh automatically
→ restore saved connections and cached quotas after restart
```

The first slice includes the visual modes, Windows framing and tray behavior, domain models, SQLite persistence, encrypted-at-rest secrets, Connections CRUD, OpenRouter, cache-first refresh, countdown rendering when a provider exposes a timestamp, error/stale states, and tests that prove multi-account isolation.

**Corrected (2026-09-26).** This line said "DPAPI-backed secrets", and that claim was wrong. `flutter_secure_storage` 11.2 delegates to the federated `flutter_secure_storage_windows`, which applies its own cipher and writes `%APPDATA%\<CompanyName>\<ProductName>\flutter_secure_storage.dat`. No `CryptProtectData` is involved, so the ciphertext is not bound to the Windows account by the OS the way DPAPI would bind it. The property that is actually true — and the one worth holding — is that the plaintext is not on disk, now asserted against the real plugin by `integration_test/secret_store_windows_test.dart`. See `PRODUCT.md` for the corrected description.

It excludes OpenCode live quota monitoring, MiniMax, Antigravity, groups, custom status thresholds, notifications, Windows startup, persisted window geometry, installer work, release documentation, charts, history, cloud services, plugin loading, analytics, and any backend.

## Platform and dependency boundaries

- Target Windows 10/11 x64 only. Do not enable mobile, web, macOS, or Linux targets.
- Start with `window_manager`, `tray_manager`, and `path_provider`.
- Add `sqflite_common_ffi` only in the persistence task and `flutter_secure_storage` only in the secret-storage task.
- Use Dart's reusable `HttpClient` for OpenRouter transport. Do not add an HTTP package by default.
- The application is one local process, one SQLite database, and no server or cloud dependency.

## Module boundaries

```text
lib/
├── main.dart                         # Bootstrap native services and run app
├── app/
│   ├── app.dart                      # MaterialApp and root composition
│   └── theme.dart                    # TokenDockTheme and visual tokens
├── models/
│   ├── connection.dart               # Persisted account identity and settings
│   ├── quota.dart                    # Provider-neutral quota
│   ├── provider_snapshot.dart        # One fetch result
│   ├── connection_status.dart        # Six UI states from the PRD
│   └── test_result.dart              # Credential-validation outcome
├── providers/
│   ├── provider_adapter.dart         # Stable adapter boundary
│   ├── provider_registry.dart        # Provider id to adapter lookup
│   └── openrouter/
│       ├── openrouter_provider.dart  # test and fetch implementation
│       └── openrouter_response.dart  # Private response parsing only
├── services/
│   └── refresh_service.dart          # Bounded refresh, cache writes, timers
├── storage/
│   ├── database.dart                 # Path, opening, schema version, migration
│   ├── migration_001.dart            # Three initial tables
│   ├── connection_repository.dart    # Connection CRUD and cache cascade
│   ├── quota_cache_repository.dart   # Snapshot cache read/write/delete
│   ├── settings_repository.dart      # Refresh interval only in this slice
│   ├── secret_store.dart             # Abstract secret contract
│   └── dpapi_secret_store.dart       # flutter_secure_storage adapter
└── ui/
    ├── widget/                       # Responsive quota widget and view state
    ├── settings/                     # Connections screen and editor dialog
    └── components/                   # Reusable visual primitives
```

The folders reflect responsibilities, not framework ceremony. `ProviderAdapter`, `SecretStore`, and repository interfaces exist because they isolate external or durable dependencies and have defined future alternatives. There is no generic factory, controller, manager, plugin system, or ORM.

## Domain contract

```dart
class Connection {
  final String id;
  final String provider;
  final String displayName;
  final String? group;
  final String? plan;
  final String credentialRef;
  final bool enabled;
}

class Quota {
  final String id;
  final String label;
  final double? percent;
  final double? remaining;
  final double? limit;
  final String? unit;
  final DateTime? resetAt;
}

class ProviderSnapshot {
  final String connectionId;
  final ConnectionStatus status;
  final List<Quota> quotas;
  final double? balance;
  final DateTime fetchedAt;
  final String? error;
}

enum ConnectionStatus { ok, warning, limited, authError, error, updating }

abstract interface class ProviderAdapter {
  String get id;
  String get name;
  Future<TestResult> test(Connection connection, String secret);
  Future<ProviderSnapshot> fetch(Connection connection, String secret);
}
```

Each connection owns its provider identifier, opaque secret reference, enablement state, and display identity. A snapshot always belongs to exactly one connection. UI consumes only the common models, so later adapters cannot require changes to the main cards.

`TestResult` contains a success flag, detected plan, optional quotas, and user-safe error text. It must never retain, format, or log the supplied credential.

## Persistence and security

SQLite resides at `%LOCALAPPDATA%\\TokenDock\\tokendock.db` and begins at `schema_version = 1` with exactly these tables:

- `connections`: id, provider, display_name, group_name, plan, auth_type, secret_ref, enabled, sort_order, created_at, updated_at.
- `quota_cache`: connection_id, quota_key, label, percent, remaining, limit_value, unit, reset_at, status, updated_at.
- `settings`: key and value.

- `Migration001` creates the initial tables and appropriate primary keys/indexes needed to query connection quotas efficiently; there is no ORM. `Migration002` adds `last_status`, `last_checked_at`, `cooldown_until`, and `last_error` to `connections`; the database is at `user_version = 2`.

Adding or editing a connection validates the credential before it can be saved. Saving generates a UUID reference, writes the secret through `SecretStore`, then saves the connection's `secret_ref`. If database persistence fails after writing a newly generated secret, delete that secret before surfacing the failure. Replacing an existing secret writes a new reference first, commits the connection, then deletes the previous reference.

Removing a connection deletes its cached quotas and database row as one database transaction, then deletes the associated secure-storage item. If deletion of the secure-storage item fails, retain the database removal and surface a recoverable warning; the deleted connection must never remain usable in the app.

SQLite, logs, exception messages, analytics, and UI state never contain raw API keys, OAuth tokens, cookies, sessions, or request bodies. Saved credentials display only a deterministic masked form such as `sk-••••••••••82AD`.

## UI and Windows behavior

### Visual direction

The visual authority is the user-provided set in `docs/imagens/`, interpreted for a small always-visible Windows widget rather than copied as a full dashboard. The style is **calm operational clarity**: warm, nearly-white workspace surfaces; near-black anchors; soft modular corners; a narrow lime signal for chosen actions; and dense, readable quota information. Do not add a sidebar, bento grid, hero metric, chart, glass effect, neon glow, or a card-inside-card stack merely because they appear in the reference dashboards.

This aligns with 2026 operational-interface practice: answer one critical question at the top of the visual hierarchy, use progressive disclosure for secondary detail, and reserve saturation for meaningful state or action. The primary question is always “Which account still has quota?”; each visible row makes its own primary quota and actionable exception legible without imposing a new account-ordering rule. The widget does not pretend to be an AI copilot, analytics suite, or settings dashboard.

`TokenDockTheme` offers Light, Dark, and System modes and owns every visual token. The light scene uses the reference family: `canvas #F5F5F0`, `surface #FFFFFF`, `surfaceMuted #F0F0EA`, `ink #17161B`, `mutedInk #6C6A73`, `hairline #E2E1DA`, `accentLime #C8F54A`, and `accentLimeInk #182000`. The dark scene is a true counterpart, not inverted white: `canvas #151419`, `surface #1E1D23`, `surfaceMuted #29272F`, `ink #F4F3F0`, `mutedInk #B6B2BD`, and `hairline #393640`. Lime is only for selected controls, the primary action, and a small non-status emphasis; text placed on it uses `accentLimeInk`.

Quota and connection state are semantic rather than decorative: `quotaNormal #1769C2`, `statusOk #087A4C`, `statusWarning #A85A00`, `statusLimited #C33737`, and `statusUpdating #6C6A73`, with dark-mode equivalents that meet their contrast target. A color never carries the state by itself: every state also has a named label and a distinct glyph. Standard text and essential controls meet WCAG 2.2 AA; non-text indicators and the visible focus ring meet a minimum 3:1 contrast against adjacent colors. When Windows contrast themes are active, `TokenDockTheme` switches to opaque system-aware high-contrast surface, foreground, focus, and status tokens; it does not attempt to preserve the lime palette at the expense of legibility.

**Dark accents, specified (audit C-34).** The dark scene's neutrals are fixed above, but the accent equivalents were left as a gesture, so the measured values had nowhere authoritative to live. They are `quotaNormal #8AB8FF`, `statusOk #34A853`, `statusWarning #E8A33D`, `statusLimited #F26D6D`, `statusUpdating #B6B2BD`, and `quotaFill #8AB8FF`. Each is a lightened counterpart of its light-scene hue rather than the light value reused: the light accents sat between 3.06:1 and 3.29:1 on the dark `surface`, below the 4.5:1 AA threshold for text. Lightening keeps the semantic hue, so the label and glyph still read as green/amber/red/blue while the text becomes legible. Contrast is asserted by test, not by inspection.

Use `Segoe UI Variable` on Windows, with the system sans-serif fallback, because it is native, compact, and aligned with Fluent’s current type-ramp guidance. Central tokens define: 11px metadata, 13px body, 15px account/provider label, 18px section heading, and 22px widget heading; quota percentages use 20px semibold tabular figures so values do not reflow. Use `FontFeature.tabularFigures()` for every changing number, not a monospaced display face. The spacing scale is 4, 8, 12, 16, 20, and 24px; corner radii are 12px for contained quota areas, 20px for the widget shell and primary groups, and a fully rounded token for pills. Elevation is a restrained one-pixel stroke plus a low-opacity shadow; it never substitutes for hierarchy.

The shell contains one header and one grouped account list. Account groups use thin dividers and a muted quota area instead of repeated floating cards. Compact mode shows a single dense row per connection. Normal mode adds the primary quota bar and reset label. Expanded mode reveals all quota windows, plan, refresh time, and any stale/error copy inline. Secondary controls appear on hover **and** keyboard focus, remain permanently visible in the Connections screen, and never displace quota content. The tab sequence follows the visual reading order: header controls, each connection row and its available actions, then the Connections action. `Enter` and `Space` activate a focused control. `Ctrl+R` runs Refresh All only when focus is not in a text field; there is no command palette in this slice. Animations are 120ms for control feedback and 180ms for layout/state transitions; `MediaQuery.disableAnimations` makes nonessential transitions instantaneous. An updating indicator may rotate once per second, but no status icon pulses continuously.

The first-run surface is explicit: while SQLite opens, show a neutral shell with three noninteractive skeleton rows; when opening finishes with no connections, replace it with “No connections yet” and one `Add Connection` action. Production never renders mock accounts after this state resolves. Cached connections render their real values immediately rather than a skeleton. The visual system is informed by the 2026 research, but the research does not expand scope: no AI-generated summary, personalization, drag-and-drop layout, history chart, notification engine, or command palette enters this slice.


The widget uses one responsive composition through `LayoutBuilder`:

| Available width | Mode | Visible account information |
| --- | --- | --- |
| `< 330px` | Compact | alias, status glyph and label, primary quota |
| `330–550px` | Normal | provider, alias, primary quotas, reset, status |
| `> 550px` | Expanded | all quotas, plan, last refresh, stale/error information |

Initial mock data covers the five provider examples from the PRD, but OpenRouter fixture data becomes the actual source after integration. The main reusable components are `QuotaBar`, `ProviderIcon`, `StatusIndicator`, `AccountHeader`, `QuotaRow`, `CompactAccountRow`, and a named icon-button component that does not shadow Flutter's `IconButton` type.

**Superseded (audit C-32).** This list originally also named `AppCard` and `SectionHeader`. Both were implemented and never instantiated: the visual system moved to a single card-free container, `WidgetShell`, with accounts grouped by thin dividers ("no nested floating cards", per `TokenDockWidget`). `AppCard` was by then actively misleading, since its own doc claimed to be "the one shell surface in the visual system" while `WidgetShell` was that surface. Both files were removed rather than composed, because composing them would have reintroduced the card chrome the design deliberately dropped.

The native window is frameless, resizable within product-defined minimum/maximum dimensions, draggable, and always-on-top. Closing the window calls `hide()` rather than ending the process. The tray menu exposes Open TokenDock, Refresh All, Always on Top, Connections, and Exit; a double click reveals the widget. Exit explicitly disables the close-to-tray behavior and terminates the process. Advanced edge snapping and stored window geometry remain later work.

The Connections screen supports add, edit, refresh, remove, and enable/disable for OpenRouter accounts. The add/edit form requires provider, display name, optional group, and credential. `Test Connection` must succeed before Save becomes enabled. The credential field clears after save; the edit form shows a masked existing credential and requires a new secret only when the user replaces it.

## Refresh, cache, and state transitions

1. Startup opens SQLite and secret storage, reads enabled connections and their quota cache, renders cached data immediately, and schedules a background `refreshAll()`. If no saved connection exists, it presents the first-run empty state instead of placeholder provider data.
2. `RefreshService.refreshOne(connectionId)` looks up the connection, reads its secret only when needed, gets the matching adapter from `ProviderRegistry`, and sets a transient `updating` presentation state without erasing the cached snapshot.
3. The service keeps one in-flight future per connection ID. A manual refresh, periodic refresh, or tray refresh targeting the same connection while it is in flight joins that future rather than sending a duplicate request. Different connection IDs remain eligible for the queue's four-request concurrency limit.
4. On success, it atomically replaces that connection's cache rows, records `fetchedAt`, and publishes the new snapshot.
5. On an adapter failure, it maps authentication errors, 429, timeout, unavailable/5xx, and malformed responses to a safe `ConnectionStatus` and user-facing copy. It retains the previous cached quota values and labels their freshness as `Last updated <relative age>`.
6. `refreshAll()` processes enabled connections through a simple queue capped at four concurrent requests. The default interval is three minutes; supported values are 1, 3, 5, and 10 minutes, or manual. Exactly one `Timer.periodic` exists, and changing the setting cancels and recreates it.
7. `fetchedAt` and `Quota.resetAt` are normalized and persisted as UTC. The UI converts them to local time only for display; a past reset timestamp renders `Resetting…` rather than a negative countdown. Countdown text derives locally from `Quota.resetAt` and a display timer; it never causes network traffic.

The UI must distinguish a 100% known quota from an unavailable refresh. It never turns an error into `0%`, and it does not depend on color alone: status uses text and an icon/symbol in addition to color.

## OpenRouter adapter contract

`OpenRouterProvider.id` is `openrouter`. `test()` and `fetch()` call `GET https://openrouter.ai/api/v1/key` with `Authorization: Bearer <secret>` and one reusable `HttpClient`. This validation request does not run inference or create usage. Standard individual API keys are the only credential type in this slice; the Management API and `/api/v1/credits` are deferred.

From the response `data`, map `limit`, `limit_remaining`, and `limit_reset` into a single `Quota(id: 'key-limit', label: 'Key limit', unit: 'USD')`. When `limit` and `limit_remaining` are finite, set `percent` to `((limit - limitRemaining) / limit * 100).clamp(0, 100)`, `remaining` to `limit_remaining`, and `limit` to `limit`. When either numeric value is `null`, preserve it as `null` and render `No key cap` rather than zero. `limit_reset` becomes `resetAt` only when it is an absolute timestamp; no date is invented from a textual reset policy. `ProviderSnapshot.balance` remains `null` because account credits require a Management API key outside this slice.

Map 401 to `authError`, **403 to `error` with `Forbidden`**, 402 to `limited`, 429 to `warning` with `Rate limited`, timeouts to `error` with `Timeout`, 5xx to `error` with `Provider unavailable`, and malformed JSON/schema to `error` with `Unknown response`. Each connection fetches independently, preserves its prior cache on failure, uses a 5–10 second connection timeout and 10–15 second request timeout, and never logs the bearer token or response body.

**Corrected (audit C-34).** This line previously read "Map 401 and 403 to `authError`". Only 401 invalidates a credential. 403 is *forbidden* — the credential authenticated and was then refused — so surfacing it as `authError` told the user to re-enter a key that was working. It is also why the classifier keys on status alone rather than message shape: treating 403 as a credential failure tore down connections that only needed a permission change. See `definitiveOAuthFailureCause` and the 403 guardrail test in `credential_integrity_test.dart`.

## Verification strategy

- Widget tests cover the compact, normal, and expanded breakpoints; light/dark/system and high-contrast theming; first-run loading and empty states; status indicators; stale cache; error cards; keyboard focus order; reduced motion; and the semantic type, spacing, radius, and color tokens used by all three modes.
- A visual acceptance pass compares Windows screenshots at the three breakpoints against the reference-derived direction: one shell, quiet chrome, no nested-card stack, readable tabular quotas, lime only for action/selection, and explicit non-color status labels.
- Storage tests use a temporary database to verify Migration001, CRUD, cache replacement, cache deletion, UTC timestamp serialization, and connection-scoped isolation.
- Secret-store tests use a fake behind the `SecretStore` interface to verify reference-only persistence, replacement cleanup, deletion behavior, and masking without testing DPAPI internals. **Superseded (2026-09-26):** there are no DPAPI internals to test, because nothing calls DPAPI. The property that matters is now checked for real, against the plugin, in `integration_test/secret_store_windows_test.dart`: the value survives a write/read round trip and the plaintext is absent from every byte written to disk.
- OpenRouter parser tests use sanitized fixtures for valid finite and unlimited keys, invalid/forbidden authentication, 402 exhausted limit, 429, 500, timeout, malformed JSON, and absent or non-timestamp reset policies.
- Refresh-service tests prove queue concurrency never exceeds four, concurrent requests for one connection coalesce, background refresh preserves cache on failure, manual refresh targets one connection, UTC reset values display correctly, and more than three connections update and fail independently.
- A Windows smoke run confirms the frameless app launches, first-run keyboard navigation reaches Add Connection, close hides to tray, tray double-click restores the widget, Ctrl+R refreshes all from the widget, Exit terminates it, and cached fixture-backed data appears after restart.

## Acceptance criteria

The slice is complete only when `flutter run -d windows` starts without critical warnings and the following end-to-end path works:

1. Add more than three separately named OpenRouter accounts with distinct API keys.
2. Test each account, save it only after a valid result, close and reopen the app.
3. Confirm all connections and their last cached quotas restore independently without a configured count limit.
4. Refresh all accounts with at most four simultaneous requests.
5. Force one account to fail and verify its prior quota remains visible with a stale/error state while other accounts refresh normally.
6. Close the window, restore it from the tray, and exit explicitly from the tray menu.
7. Start without persisted data, reach `Add Connection` with the keyboard, and verify production mock accounts never appear.
8. Verify Light, Dark, Windows contrast-theme, and reduced-motion rendering preserve readable quotas, visible focus, and non-color status labels.

## Scope guard

The next provider must be added only by a `ProviderAdapter`, provider-private parser/models, fixtures, and tests. If it requires modifying common cards, `Connection`, `Quota`, `ProviderSnapshot`, or `RefreshService`, stop and revise the common model before continuing. Features outside the first functional goal remain deferred until this slice is used and proven stable.

## Deferred opportunities after the first functional goal

The following are recorded for future evaluation, not authorized for the first slice:

- **Providers and accounts:** OpenCode live quota monitoring, MiniMax, Antigravity, provider autodetection, and multi-account Antigravity. Each requires an official credential and quota contract before implementation.
- **Operational workflow:** groups, manual/provider/status ordering, drag-and-drop, configurable status thresholds, configurable notifications, startup with Windows, persisted window geometry, and sleep/wake refresh.
- **Data and command surfaces:** usage history, charts, OpenRouter Management API imports, a command palette, workspace personalization, and AI-generated summaries. Reconsider these only after the widget has proven stable with a large account set without degrading glanceability or local-first behavior.
- **Distribution and expansion:** portable ZIP, installer, update checking, documentation, web, mobile, server, cloud synchronization, analytics, and a plugin system.
- **Explicitly rejected experimental route:** OpenCode Console scraping, browser automation, private RPC use, or storage of session cookies. Reconsider only through a new security review and explicit user approval; it must never enter the standard provider path by accident.

## Research sources used for the visual revision

- Microsoft Fluent 2: [color](https://fluent2.microsoft.design/color), [typography](https://fluent2.microsoft.design/typography), [accessibility](https://fluent2.microsoft.design/accessibility), and [card usage](https://fluent2.microsoft.design/components/web/react/core/card/usage). These establish tokenized color roles, readable native desktop typography, keyboard focus, and restrained surface elevation.
- Nielsen Norman Group: [Preattentive processing](https://www.nngroup.com/articles/dashboards-preattentive/), [chart selection](https://www.nngroup.com/articles/choosing-chart-types/), and [chart clutter](https://www.nngroup.com/articles/clutter-charts/). These support at-a-glance hierarchy, contextual data, and removal of decorative noise.
- 2026 directional research: [Republic of UX](https://republicofux.com/ux-product-design-trends-to-watch-in-2026/) and [SaaSFrame](https://www.saasframe.io/blog/the-anatomy-of-high-performance-saas-dashboard-design-2026-trends-patterns). These are trend signals, not normative standards; the adopted parts are calm operational surfaces, explicit primary questions, intentional density, and progressive disclosure.
- Current accessibility guidance: [University of Chicago data visualization accessibility](https://digitalaccessibility.uchicago.edu/resources/data-visualization/) and [WCAG 2.2](https://www.w3.org/TR/WCAG22/). These support the non-color status rule, contrast, focus visibility, and keyboard order.
- Windows accessibility and interaction guidance: [accessibility overview](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/accessibility-overview), [keyboard interactions](https://learn.microsoft.com/en-us/windows/apps/develop/input/keyboard-interactions), and [contrast themes](https://learn.microsoft.com/en-us/windows/apps/design/accessibility/high-contrast-themes). These add high-contrast tokens, logical tab order, keyboard-only flow verification, and intentionally narrow shortcuts.
- Flutter desktop guidance: [desktop input](https://docs.flutter.dev/ui/adaptive-responsive/input) and [focus](https://docs.flutter.dev/ui/interactivity/focus). These support `FocusTraversalGroup`, explicit focus appearance, keyboard activation, and `MediaQuery.disableAnimations`.
- OpenRouter official contract: [authentication](https://openrouter.ai/docs/api_reference/authentication), [key limits](https://openrouter.ai/docs/api_reference/limits), and [credits](https://openrouter.ai/docs/api/api-reference/credits/get-remaining-credits). These establish the standard API-key `GET /api/v1/key` contract and preserve Management API data as deferred scope.
