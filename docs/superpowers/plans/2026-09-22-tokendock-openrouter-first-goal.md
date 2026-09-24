# TokenDock OpenRouter First Functional Goal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the Windows TokenDock widget that securely tracks, caches, and refreshes three independent OpenRouter API-key limits from the system tray.

**Architecture:** The Flutter app renders a cache-first responsive widget backed by provider-neutral models, SQLite repositories, and DPAPI-backed credentials. `OpenRouterProvider` is the sole live adapter and calls the public `GET /api/v1/key` contract through one reusable `HttpClient`; `RefreshService` owns bounded, deduplicated refresh work and never erases valid cache after an error.

**Tech Stack:** Flutter/Dart; Windows 10/11 x64; `window_manager`; current native `tray_manager` API; `path_provider`; `sqflite_common_ffi`; `flutter_secure_storage`; SQLite; Dart `HttpClient`; Flutter widget and integration tests.

**Spec:** `docs/superpowers/specs/2026-09-22-tokendock-first-functional-goal-design.md`

## Implementation status — first slice complete (2026-09-23, `master` `7154db3`); deps upgraded same day (`flutter_secure_storage ^11.2.0`, `sqflite_common_ffi ^2.4.3`); OpenRouter quota hardening merged later the same day (`master` `17d489e`)

- All 12 tasks executed (subagent-driven; Task 12 finished inline after two provider-quota dispatch failures).
- Verification: `flutter test` 96/96; `flutter test integration_test/multi_account_flow_test.dart` 3/3; `flutter analyze` 0 errors, 0 warnings; `flutter build windows --release` succeeds; the release run created the real `%LOCALAPPDATA%` database, rendered the first-run state, and hid to the tray on close. Re-verified after the v11 upgrade (test fake migrated `IOSOptions/MacOsOptions` → `AppleOptions`; no `lib/` change). Hardening re-verified at `17d489e`: `flutter test --no-pub` 109/109, `analyze` 0 errors/0 warnings/5 infos, Windows integration pending on symlink/Developer Mode.
- Record: `.superpowers/sdd/tokendock-openrouter-first-goal/` (ledger `progress.md`, per-task briefs/reports/reviews). Tasks 1–11 independently reviewed; Task 12 self-reviewed by the controller after subagent quota exhaustion.
- Known deviations from the constraints above: `sqflite_common` is declared alongside `sqflite_common_ffi` (four storage files import it directly); `integration_test` SDK dev dependency was added because this plan's own verification command runs `flutter test integration_test/...`.
- Post-slice research: `docs/auth-research-oh-my-pi-9router.md`; hardening implemented and merged per `docs/auth-quota-hardening-plan.md`.

## Global Constraints

- Target Windows 10/11 x64 only. Do not enable mobile, web, macOS, or Linux targets.
- Build one local process, one local SQLite database, no server, cloud service, analytics, plugin system, or ORM.
- Add only `window_manager`, `tray_manager`, and `path_provider` at bootstrap; add `sqflite_common_ffi` at persistence and `flutter_secure_storage` at secret storage.
- Use one reusable Dart `HttpClient` for OpenRouter. Do not add an HTTP package.
- Keep every API key, token, cookie, session, request body, and raw response body out of SQLite, logs, exceptions, analytics, and UI state.
- Store only `credentialRef`/`secret_ref` in SQLite. Store a secret only through `SecretStore`.
- Use `OpenRouterProvider.id == 'openrouter'` and only `GET https://openrouter.ai/api/v1/key` with `Authorization: Bearer <secret>` in this slice.
- Do not call OpenRouter inference endpoints to validate a key; `/api/v1/key` must be sufficient.
- Do not add OpenCode quota monitoring, MiniMax, Antigravity, OpenRouter Management API imports, browser automation, private RPC use, session-cookie storage, charts, history, command palette, notifications, startup registration, or window-position persistence.
- Use the approved visual system: warm off-white and near-black surfaces, lime only for selected controls and the primary action, `Segoe UI Variable`, tabular quota figures, one shell, grouped account rows, no nested-card stack, no glow, and no glass.
- Meet WCAG 2.2 AA for text and essential controls; pair every status color with a label and glyph; support keyboard traversal, Windows contrast themes, text scaling, and `MediaQuery.disableAnimations`.
- Preserve cached values after refresh failure. Render `Last updated <relative age>` instead of `0%` for stale data.
- Persist `fetchedAt` and `resetAt` as UTC. Render a past reset as `Resetting…`, never a negative duration.
- Limit distinct connection refreshes to four concurrent requests and coalesce concurrent requests for the same connection ID.
- Use sanitized fixtures only. No real key appears in source control or tests.

---

## File Structure

```text
tokendock/
├── pubspec.yaml
├── assets/
│   └── tray_icon.ico
├── lib/
│   ├── main.dart
│   ├── app/
│   │   ├── app.dart
│   │   ├── app_state.dart
│   │   ├── theme.dart
│   │   ├── tray_controller.dart
│   │   └── window_controller.dart
│   ├── models/
│   │   ├── connection.dart
│   │   ├── connection_status.dart
│   │   ├── provider_snapshot.dart
│   │   ├── quota.dart
│   │   └── test_result.dart
│   ├── providers/
│   │   ├── provider_adapter.dart
│   │   ├── provider_registry.dart
│   │   └── openrouter/
│   │       ├── openrouter_provider.dart
│   │       └── openrouter_response.dart
│   ├── services/
│   │   └── refresh_service.dart
│   ├── storage/
│   │   ├── connection_repository.dart
│   │   ├── database.dart
│   │   ├── migration_001.dart
│   │   ├── quota_cache_repository.dart
│   │   ├── secret_store.dart
│   │   ├── secure_secret_store.dart
│   │   └── settings_repository.dart
│   └── ui/
│       ├── components/
│       │   ├── account_header.dart
│       │   ├── app_card.dart
│       │   ├── compact_account_row.dart
│       │   ├── provider_icon.dart
│       │   ├── quota_bar.dart
│       │   ├── quota_row.dart
│       │   ├── section_header.dart
│       │   └── status_indicator.dart
│       ├── settings/
│       │   └── connections_screen.dart
│       └── widget/
│           ├── countdown_text.dart
│           ├── token_dock_widget.dart
│           └── widget_shell.dart
├── test/
│   ├── fixtures/
│   │   ├── openrouter_key_finite.json
│   │   ├── openrouter_key_unlimited.json
│   │   ├── openrouter_key_malformed.json
│   │   └── openrouter_error_402.json
│   ├── models/
│   ├── providers/
│   ├── services/
│   ├── storage/
│   ├── support/
│   │   ├── controlled_provider.dart
│   │   ├── memory_secret_store.dart
│   │   ├── test_app.dart
│   │   └── test_database.dart
│   └── ui/
└── integration_test/
    └── multi_account_flow_test.dart
```

### Task 1: Bootstrap the Windows Flutter application

**Files:**
- Create: `tokendock/` generated Flutter Windows project
- Modify: `tokendock/pubspec.yaml`
- Create: `tokendock/assets/tray_icon.ico`
- Create: `tokendock/lib/main.dart`
- Delete: `tokendock/test/widget_test.dart`

**Interfaces:**
- Produces: a Windows-only Flutter app with assets and the three bootstrap dependencies.
- Consumes: no application code.

- [ ] **Step 1: Create the Windows project**

Run:

```powershell
flutter create --platforms=windows tokendock
```

Expected: `tokendock/windows/`, `tokendock/lib/`, and `tokendock/test/` exist; no mobile or web platform folders are generated.

- [ ] **Step 1a: Remove the obsolete generated widget test**

Run:

```powershell
Remove-Item test/widget_test.dart
```

Expected: the generated counter test cannot reference the removed `MyApp` starter widget.

- [ ] **Step 2: Add only bootstrap dependencies and declare the tray asset**

Run:

```powershell
flutter pub add window_manager tray_manager path_provider
```

Add this exact asset declaration under the `flutter:` key in `pubspec.yaml`:

```yaml
assets:
  - assets/tray_icon.ico
```

- [ ] **Step 3: Replace the starter entry point with native bootstrap ordering**

```dart
import 'package:flutter/widgets.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();
  runApp(const TokenDockApp());
}
```

- [ ] **Step 4: Run the Windows smoke launch**

Run:

```powershell
flutter run -d windows
```

Expected: a Windows desktop window opens without a missing-plugin error.

- [ ] **Step 5: Commit**

```powershell
git add tokendock
git commit -m "feat: bootstrap Windows Flutter app"
```

### Task 2: Define domain contracts and status presentation

**Files:**
- Create: `tokendock/lib/models/connection.dart`
- Create: `tokendock/lib/models/connection_status.dart`
- Create: `tokendock/lib/models/quota.dart`
- Create: `tokendock/lib/models/provider_snapshot.dart`
- Create: `tokendock/lib/models/test_result.dart`
- Create: `tokendock/test/models/quota_test.dart`
- Create: `tokendock/test/models/provider_snapshot_test.dart`

**Interfaces:**
- Produces: `Connection`, `Quota`, `ProviderSnapshot`, `TestResult`, and `ConnectionStatus` used by storage, adapters, refresh, and UI.
- Consumes: no storage or provider implementation.

- [ ] **Step 1: Write failing model tests for observable invariants**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';

void main() {
  test('stale cache retains its known quota while status changes', () {
    final snapshot = ProviderSnapshot(
      connectionId: 'connection-a',
      status: ConnectionStatus.error,
      quotas: const [
        Quota(
          id: 'key-limit',
          label: 'Key limit',
          percent: 72,
          remaining: 2.8,
          limit: 10,
          unit: 'USD',
          resetAt: null,
        ),
      ],
      balance: null,
      fetchedAt: DateTime.utc(2026, 9, 22, 12),
      error: 'Provider unavailable',
    );

    expect(snapshot.quotas.single.percent, 72);
    expect(snapshot.status, ConnectionStatus.error);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails before the types exist**

Run:

```powershell
flutter test test/models/provider_snapshot_test.dart
```

Expected: compilation failure because the model imports do not exist.

- [ ] **Step 3: Implement immutable contracts**

```dart
enum ConnectionStatus { ok, warning, limited, authError, error, updating }

class Quota {
  const Quota({
    required this.id,
    required this.label,
    required this.percent,
    required this.remaining,
    required this.limit,
    required this.unit,
    required this.resetAt,
  });

  final String id;
  final String label;
  final double? percent;
  final double? remaining;
  final double? limit;
  final String? unit;
  final DateTime? resetAt;
}

class ProviderSnapshot {
  const ProviderSnapshot({
    required this.connectionId,
    required this.status,
    required this.quotas,
    required this.balance,
    required this.fetchedAt,
    required this.error,
  });

  final String connectionId;
  final ConnectionStatus status;
  final List<Quota> quotas;
  final double? balance;
  final DateTime fetchedAt;
  final String? error;
}
```

Define `Connection` with `id`, `provider`, `displayName`, `group`, `plan`, `credentialRef`, and `enabled`. Define `TestResult` with `isSuccess`, `plan`, `quotas`, and `error`; its successful factory sets `isSuccess` to true and its failed factory sets it to false.

- [ ] **Step 4: Run the model tests**

Run:

```powershell
flutter test test/models
```

Expected: all model tests pass.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/models tokendock/test/models
git commit -m "feat: add provider-neutral quota models"
```

### Task 3: Build the tokenized visual system and reusable primitives

**Files:**
- Create: `tokendock/lib/app/theme.dart`
- Create: `tokendock/lib/ui/components/app_card.dart`
- Create: `tokendock/lib/ui/components/quota_bar.dart`
- Create: `tokendock/lib/ui/components/provider_icon.dart`
- Create: `tokendock/lib/ui/components/status_indicator.dart`
- Create: `tokendock/lib/ui/components/account_header.dart`
- Create: `tokendock/lib/ui/components/quota_row.dart`
- Create: `tokendock/lib/ui/components/compact_account_row.dart`
- Create: `tokendock/lib/ui/components/section_header.dart`
- Create: `tokendock/test/ui/theme_test.dart`
- Create: `tokendock/test/ui/status_indicator_test.dart`

**Interfaces:**
- Produces: `TokenDockTheme`, typed visual tokens, and presentational components consuming models without storage or networking.
- Consumes: `Quota` and `ConnectionStatus` from Task 2.

- [ ] **Step 1: Write failing widget tests for non-color status and tabular quota text**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/ui/components/status_indicator.dart';

void main() {
  testWidgets('limited status exposes label and glyph', (tester) async {
    await tester.pumpWidget(
      const StatusIndicator(status: ConnectionStatus.limited),
    );

    expect(find.text('Limited'), findsOneWidget);
    expect(find.bySemanticsLabel('Limited'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/ui/status_indicator_test.dart
```

Expected: compilation failure because `StatusIndicator` does not exist.

- [ ] **Step 3: Implement visual tokens and primitives**

Create `TokenDockTheme` with named light, dark, and high-contrast token groups. Light tokens use `#F5F5F0`, `#FFFFFF`, `#F0F0EA`, `#17161B`, `#6C6A73`, `#E2E1DA`, `#C8F54A`, and `#182000`. Typography uses `Segoe UI Variable` and tabular `FontFeature.tabularFigures()` for changing quota figures. Use spacing tokens 4, 8, 12, 16, 20, and 24; radii 12 and 20; and a fully rounded pill radius.

Implement a `StatusIndicator` that returns a label and a semantic label for every `ConnectionStatus`. Use a status glyph plus text; do not expose color as the only state. Implement `QuotaBar` so a null `percent` shows no filled progress and leaves the accompanying textual value authoritative.

- [ ] **Step 4: Run widget tests**

Run:

```powershell
flutter test test/ui/theme_test.dart test/ui/status_indicator_test.dart
```

Expected: status labels, high-contrast tokens, and tabular quota configuration pass their tests.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/app/theme.dart tokendock/lib/ui/components tokendock/test/ui
git commit -m "feat: add TokenDock visual system"
```

### Task 4: Deliver the responsive mock widget and first-run states

**Files:**
- Create: `tokendock/lib/app/app.dart`
- Create: `tokendock/lib/app/app_state.dart`
- Create: `tokendock/lib/ui/widget/widget_shell.dart`
- Create: `tokendock/lib/ui/widget/token_dock_widget.dart`
- Create: `tokendock/lib/ui/widget/countdown_text.dart`
- Create: `tokendock/test/ui/token_dock_widget_test.dart`

**Interfaces:**
- Produces: a single `LayoutBuilder` widget tree with compact, normal, and expanded density; loading and no-connections states.
- Consumes: Task 2 models and Task 3 primitives.

- [ ] **Step 1: Write failing breakpoint and empty-state tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

void main() {
  testWidgets('uses compact rows below 330 logical pixels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 600));
    await tester.pumpWidget(const TokenDockWidget.loading());

    expect(find.text('TokenDock'), findsOneWidget);
    expect(find.byType(CompactAccountRow), findsNothing);
  });

  testWidgets('shows one add action when no connections exist', (tester) async {
    await tester.pumpWidget(const TokenDockWidget.empty());

    expect(find.text('No connections yet'), findsOneWidget);
    expect(find.text('Add Connection'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/ui/token_dock_widget_test.dart
```

Expected: compilation failure because the widget and state constructors do not exist.

- [ ] **Step 3: Implement one responsive composition**

Use `LayoutBuilder` and select density from the available width only:

```dart
Widget build(BuildContext context) {
  return LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 330) {
        return _buildCompact(context);
      }
      if (constraints.maxWidth <= 550) {
        return _buildNormal(context);
      }
      return _buildExpanded(context);
    },
  );
}
```

Render three neutral skeleton rows only while the database state is opening. Render `No connections yet` and one `Add Connection` action after an empty load. Render cached account rows immediately when snapshots exist. `CountdownText` converts a UTC `resetAt` to local time and returns `Resetting…` when the duration is not positive.

- [ ] **Step 4: Run widget tests at all widths**

Run:

```powershell
flutter test test/ui/token_dock_widget_test.dart
```

Expected: compact, normal, expanded, loading, empty, and stale-state assertions pass.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/app tokendock/lib/ui/widget tokendock/test/ui/token_dock_widget_test.dart
git commit -m "feat: add responsive quota widget"
```

### Task 5: Integrate frameless window and current native tray API

**Files:**
- Modify: `tokendock/lib/main.dart`
- Create: `tokendock/lib/app/window_controller.dart`
- Create: `tokendock/lib/app/tray_controller.dart`
- Modify: `tokendock/pubspec.yaml`
- Modify: `tokendock/assets/tray_icon.ico`
- Create: `tokendock/test/app/window_controller_test.dart`

**Interfaces:**
- Produces: `WindowController.showWidget()`, `hideWidget()`, `setAlwaysOnTop(bool)`, and `exitApplication()`; tray actions call only these methods.
- Consumes: `window_manager`, current object-based `tray_manager` API, and the root widget from Task 4.

- [ ] **Step 1: Write a failing controller contract test using fakes**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/window_controller.dart';

void main() {
  test('close request hides rather than exits', () async {
    final calls = <String>[];
    final controller = WindowController.forTest(
      hide: () async => calls.add('hide'),
      quit: () async => calls.add('quit'),
    );

    await controller.handleCloseRequest();

    expect(calls, ['hide']);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/app/window_controller_test.dart
```

Expected: compilation failure because `WindowController` does not exist.

- [ ] **Step 3: Implement native setup without legacy tray APIs**

Configure `WindowOptions` with hidden title bar, a product-defined minimum and maximum size, and a flicker-free `waitUntilReadyToShow` callback. `WindowController.handleCloseRequest()` calls `windowManager.hide()`. `exitApplication()` first marks explicit exit, then destroys the tray icon and closes the native window.

Use the current `TrayIcon`, `Menu`, and item-listener API from `tray_manager`; do not import `package:tray_manager/legacy.dart`. Create menu items for Open TokenDock, Refresh All, separator, Always on Top, Connections, separator, and Exit. Route double-click to `showWidget()`.

- [ ] **Step 4: Run controller tests and a Windows tray smoke check**

Run:

```powershell
flutter test test/app/window_controller_test.dart
flutter run -d windows
```

Expected: closing the visible window leaves the process in the tray; double-click restores it; Exit terminates it.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/main.dart tokendock/lib/app tokendock/pubspec.yaml tokendock/assets/tray_icon.ico tokendock/test/app
git commit -m "feat: add frameless window and tray controls"
```

### Task 6: Create SQLite schema, migration, and repositories

**Files:**
- Modify: `tokendock/pubspec.yaml`
- Create: `tokendock/lib/storage/database.dart`
- Create: `tokendock/lib/storage/migration_001.dart`
- Create: `tokendock/lib/storage/connection_repository.dart`
- Create: `tokendock/lib/storage/quota_cache_repository.dart`
- Create: `tokendock/lib/storage/settings_repository.dart`
- Create: `tokendock/test/storage/repositories_test.dart`
- Create: `tokendock/test/support/test_database.dart`

**Interfaces:**
- Produces: `ConnectionRepository`, `QuotaCacheRepository`, and `SettingsRepository` backed by `%LOCALAPPDATA%\\TokenDock\\tokendock.db`.
- Consumes: Task 2 models and `sqflite_common_ffi`.

- [ ] **Step 1: Add the persistence dependency**

Run:

```powershell
flutter pub add sqflite_common_ffi
```

- [ ] **Step 2: Write failing repository isolation tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/quota.dart';

void main() {
  test('replacing one connection cache does not alter another', () async {
    final fixture = await TestDatabase.open();
    await fixture.quotaCache.saveAll('a', const [
      Quota(id: 'key-limit', label: 'Key limit', percent: 10, remaining: 9, limit: 10, unit: 'USD', resetAt: null),
    ]);
    await fixture.quotaCache.saveAll('b', const [
      Quota(id: 'key-limit', label: 'Key limit', percent: 50, remaining: 5, limit: 10, unit: 'USD', resetAt: null),
    ]);

    expect((await fixture.quotaCache.getAll('a')).single.percent, 10);
    expect((await fixture.quotaCache.getAll('b')).single.percent, 50);
  });
}
```

- [ ] **Step 3: Implement `Migration001` and repositories**

Create only these tables: `connections`, `quota_cache`, and `settings`. Use a migration table or `PRAGMA user_version` with version `1`; run `Migration001` exactly once. Store dates as UTC ISO-8601 strings. Make `QuotaCacheRepository.saveAll(connectionId, quotas)` delete existing rows for that connection and insert the new rows in one transaction. Make `ConnectionRepository.delete(id)` delete the connection and its cache rows in one transaction.

Expose these repository methods:

```dart
abstract interface class ConnectionRepository {
  Future<List<Connection>> getAll();
  Future<void> save(Connection connection);
  Future<void> delete(String id);
}

abstract interface class QuotaCacheRepository {
  Future<List<Quota>> getAll(String connectionId);
  Future<void> saveAll(String connectionId, List<Quota> quotas);
  Future<void> deleteForConnection(String connectionId);
}
```

- [ ] **Step 4: Run repository tests**

Run:

```powershell
flutter test test/storage/repositories_test.dart
```

Expected: migration, cache replacement, connection deletion, and UTC serialization pass.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/pubspec.yaml tokendock/lib/storage tokendock/test/storage
git commit -m "feat: add SQLite connection and quota cache"
```

### Task 7: Add DPAPI-backed secret lifecycle

**Files:**
- Modify: `tokendock/pubspec.yaml`
- Create: `tokendock/lib/storage/secret_store.dart`
- Create: `tokendock/lib/storage/secure_secret_store.dart`
- Create: `tokendock/test/storage/secret_store_test.dart`
- Create: `tokendock/test/support/memory_secret_store.dart`

**Interfaces:**
- Produces: `SecretStore.write`, `read`, and `delete`; SQLite receives only secret references.
- Consumes: `flutter_secure_storage` and Task 6 repositories.

- [ ] **Step 1: Add the secure-storage dependency**

Run:

```powershell
flutter pub add flutter_secure_storage
```

- [ ] **Step 2: Write failing secret-reference tests with an in-memory fake**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/storage/secret_store.dart';

void main() {
  test('deleting a secret reference removes only that credential', () async {
    final store = MemorySecretStore();
    await store.write('secret-a', 'sk-a');
    await store.write('secret-b', 'sk-b');
    await store.delete('secret-a');

    expect(await store.read('secret-a'), isNull);
    expect(await store.read('secret-b'), 'sk-b');
  });
}
```

- [ ] **Step 3: Implement the stable secure-store boundary**

```dart
abstract interface class SecretStore {
  Future<void> write(String key, String value);
  Future<String?> read(String key);
  Future<void> delete(String key);
}
```

Implement `SecureSecretStore` using `FlutterSecureStorage` with Windows-compatible defaults. Generate references locally as UUIDv4 strings from 16 `Random.secure()` bytes; do not add a UUID dependency. Add a `maskSecret(String value)` helper that returns the prefix plus the final four characters and never returns the full secret after persistence.

- [ ] **Step 4: Run secret tests**

Run:

```powershell
flutter test test/storage/secret_store_test.dart
```

Expected: write/read/delete and masking tests pass without printing secret values.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/pubspec.yaml tokendock/lib/storage tokendock/test/storage/secret_store_test.dart
git commit -m "feat: add secure credential storage"
```

### Task 8: Implement the OpenRouter adapter from official fixtures

**Files:**
- Create: `tokendock/lib/providers/provider_adapter.dart`
- Create: `tokendock/lib/providers/provider_registry.dart`
- Create: `tokendock/lib/providers/openrouter/openrouter_response.dart`
- Create: `tokendock/lib/providers/openrouter/openrouter_provider.dart`
- Create: `tokendock/test/fixtures/openrouter_key_finite.json`
- Create: `tokendock/test/fixtures/openrouter_key_unlimited.json`
- Create: `tokendock/test/fixtures/openrouter_key_malformed.json`
- Create: `tokendock/test/fixtures/openrouter_error_402.json`
- Create: `tokendock/test/providers/openrouter_provider_test.dart`

**Interfaces:**
- Produces: `OpenRouterProvider` registered under `openrouter`.
- Consumes: Task 2 models, Task 7 `SecretStore` at caller level, and the official `/api/v1/key` response contract.

- [ ] **Step 1: Write failing finite-limit parsing and 402 mapping tests**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/openrouter/openrouter_response.dart';

void main() {
  test('maps remaining key credit to used percentage', () {
    final snapshot = OpenRouterResponse.parseKey(
      connectionId: 'a',
      body: '{"data":{"limit":10.0,"limit_remaining":2.5,"limit_reset":null}}',
      fetchedAt: DateTime.utc(2026, 9, 22),
    );

    expect(snapshot.quotas.single.percent, 75);
    expect(snapshot.quotas.single.remaining, 2.5);
    expect(snapshot.quotas.single.limit, 10);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/providers/openrouter_provider_test.dart
```

Expected: compilation failure because `OpenRouterResponse` does not exist.

- [ ] **Step 3: Implement adapter and parser**

```dart
abstract interface class ProviderAdapter {
  String get id;
  String get name;
  Future<TestResult> test(Connection connection, String secret);
  Future<ProviderSnapshot> fetch(Connection connection, String secret);
}
```

`OpenRouterProvider` owns one injected `HttpClient` and sends only this request:

```dart
final request = await _client.getUrl(
  Uri.parse('https://openrouter.ai/api/v1/key'),
);
request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $secret');
final response = await request.close();
```

Set connection timeout to 10 seconds and response timeout to 15 seconds. Parse only `data.limit`, `data.limit_remaining`, and `data.limit_reset`; never retain the raw JSON outside the parser. Use quota ID `key-limit`, label `Key limit`, and unit `USD`. For finite `limit > 0` and finite `limit_remaining`, calculate `percent` as used credit. For null values, leave `percent`, `remaining`, and `limit` null. Treat `limit_reset` as `resetAt` only when it parses as an absolute timestamp. `test()` calls the same endpoint and returns the parsed plan/limit preview without inference.

Map 401 and 403 to `authError`; 402 to `limited`; 429 to `warning`; 5xx, timeout, and malformed data to `error` with the approved user-safe labels.

- [ ] **Step 4: Run provider tests**

Run:

```powershell
flutter test test/providers/openrouter_provider_test.dart
```

Expected: finite, unlimited, auth, 402, 429, timeout, 5xx, and malformed fixtures map to the intended public statuses without emitting a bearer token.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/providers tokendock/test/providers tokendock/test/fixtures
git commit -m "feat: add OpenRouter key quota provider"
```

### Task 9: Build connection CRUD with test-before-save and credential compensation

**Files:**
- Create: `tokendock/lib/ui/settings/connections_screen.dart`
- Modify: `tokendock/lib/app/app_state.dart`
- Create: `tokendock/test/ui/connections_screen_test.dart`
- Create: `tokendock/test/support/test_app.dart`

**Interfaces:**
- Produces: add, edit, refresh, enable/disable, and remove actions for OpenRouter connections.
- Consumes: Tasks 6–8 repositories, `SecretStore`, `OpenRouterProvider`, and the root app state.

- [ ] **Step 1: Write failing save-gate and delete-flow tests**

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Save remains disabled until a connection test succeeds', (tester) async {
    await tester.pumpWidget(TestConnectionsScreen.withResult(success: false));

    await tester.enterText(find.byLabelText('Display name'), 'Production');
    await tester.enterText(find.byLabelText('Credential'), 'sk-test');
    await tester.tap(find.text('Test Connection'));
    await tester.pumpAndSettle();

    expect(tester.widget<ElevatedButton>(find.byKey(const Key('saveConnection'))).onPressed, isNull);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/ui/connections_screen_test.dart
```

Expected: compilation failure because the screen and test harness do not exist.

- [ ] **Step 3: Implement the connection flow**

The form fields are Provider (fixed to OpenRouter), Display name, Group, and Credential. On Test Connection, call `OpenRouterProvider.test()` with the entered secret. Render `Connected` plus the returned key-limit preview on success; expose only a user-safe error label on failure.

On first save, generate a connection ID and secret reference; write the secret first, then save the `Connection`. If repository save fails, delete the newly written secret before displaying the error. On replacement, write the new secret reference, save the updated connection, then delete the prior secret reference. On removal, delete the database connection and cache transaction first, then delete the secure secret; if secure deletion fails, keep the connection deleted and display a recoverable cleanup warning.

- [ ] **Step 4: Run connection screen tests**

Run:

```powershell
flutter test test/ui/connections_screen_test.dart
```

Expected: failed credentials cannot save, successful credentials can save, and removal clears the visible connection.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/ui/settings tokendock/lib/app/app_state.dart tokendock/test/ui/connections_screen_test.dart
git commit -m "feat: add OpenRouter connection management"
```

### Task 10: Implement cache-first refresh, deduplication, and countdown updates

**Files:**
- Create: `tokendock/lib/services/refresh_service.dart`
- Modify: `tokendock/lib/app/app_state.dart`
- Modify: `tokendock/lib/ui/widget/token_dock_widget.dart`
- Create: `tokendock/test/services/refresh_service_test.dart`
- Create: `tokendock/test/ui/countdown_text_test.dart`
- Create: `tokendock/test/support/controlled_provider.dart`

**Interfaces:**
- Produces: `RefreshService.refreshOne(String)` and `RefreshService.refreshAll()` plus a three-minute default refresh timer.
- Consumes: `ConnectionRepository`, `QuotaCacheRepository`, `SecretStore`, `ProviderRegistry`, and the UI state from earlier tasks.

- [ ] **Step 1: Write failing concurrency and stale-cache tests**

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('joins duplicate refreshes for one connection', () async {
    final provider = ControlledProvider();
    final service = RefreshService.forTest(provider: provider, maximumConcurrent: 4);

    final first = service.refreshOne('a');
    final second = service.refreshOne('a');
    await Future.wait([first, second]);

    expect(provider.fetchCalls, 1);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/services/refresh_service_test.dart
```

Expected: compilation failure because `RefreshService` does not exist.

- [ ] **Step 3: Implement bounded, coalesced refresh**

Keep a private `Map<String, Future<void>>` of in-flight connection refreshes. Return the existing future when the same ID is requested. Process unique enabled connections with a queue that has at most four active fetches. On success, replace only that connection's cache rows and publish its new snapshot. On failure, keep its stored quota rows, publish a new error status, and derive `Last updated <relative age>` from the cache timestamp.

Use exactly one `Timer.periodic`; default to three minutes and rebuild it when settings selects 1, 3, 5, 10, or manual. The timer must be cancelled in app-state disposal. `Ctrl+R`, tray Refresh All, and UI refresh controls call this service rather than making provider requests directly.

- [ ] **Step 4: Run service and countdown tests**

Run:

```powershell
flutter test test/services/refresh_service_test.dart test/ui/countdown_text_test.dart
```

Expected: the four-request bound, same-ID coalescing, per-account error isolation, cache preservation, UTC display, and `Resetting…` behavior pass.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/services tokendock/lib/app/app_state.dart tokendock/lib/ui/widget tokendock/test/services tokendock/test/ui/countdown_text_test.dart
git commit -m "feat: add cache-first refresh service"
```

### Task 11: Wire app startup, accessibility, and visual state into the real widget

**Files:**
- Modify: `tokendock/lib/main.dart`
- Modify: `tokendock/lib/app/app.dart`
- Modify: `tokendock/lib/app/app_state.dart`
- Modify: `tokendock/lib/ui/widget/token_dock_widget.dart`
- Modify: `tokendock/lib/ui/settings/connections_screen.dart`
- Create: `tokendock/test/ui/accessibility_flow_test.dart`
- Modify: `tokendock/test/support/test_app.dart`

**Interfaces:**
- Produces: startup sequence `SQLite cache → immediate render → background refresh`, keyboard traversal, high-contrast mode, and reduced-motion rendering.
- Consumes: all prior app modules.

- [ ] **Step 1: Write failing keyboard-only and reduced-motion tests**

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('keyboard traversal reaches Add Connection from first-run state', (tester) async {
    await tester.pumpWidget(TestApp.empty());

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    expect(find.text('Connections'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails**

Run:

```powershell
flutter test test/ui/accessibility_flow_test.dart
```

Expected: the root app test harness does not yet expose first-run focus traversal.

- [ ] **Step 3: Wire the full application state**

On startup, initialize database and repositories, load connections and quota cache, publish cached rows, then call `refreshAll()` without blocking first paint. If no connections exist, publish the empty state. Add `FocusTraversalGroup` around the shell so header controls, connection rows, and Connections action follow visual order. Scope `Ctrl+R` through `Shortcuts` and `Actions`, with the action disabled while a text field has focus. Read high contrast and animation preference from `MediaQuery`; high contrast uses opaque semantic tokens and disabled animations use zero-duration state changes.

- [ ] **Step 4: Run focused UI tests**

Run:

```powershell
flutter test test/ui/accessibility_flow_test.dart test/ui/token_dock_widget_test.dart test/ui/connections_screen_test.dart
```

Expected: keyboard, empty, stale, high-contrast, and reduced-motion flows pass.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/lib/main.dart tokendock/lib/app tokendock/lib/ui tokendock/test/ui
git commit -m "feat: wire cache-first accessible app flow"
```

### Task 12: Prove the three-account workflow on Windows

**Files:**
- Create: `tokendock/integration_test/multi_account_flow_test.dart`
- Modify: `tokendock/test/fixtures/openrouter_key_finite.json`
- Modify: `tokendock/test/fixtures/openrouter_error_402.json`

**Interfaces:**
- Produces: an integration proof that three separate OpenRouter connections restore, refresh, cache, and fail independently.
- Consumes: complete application.

- [ ] **Step 1: Write the integration scenario with three distinct fixture-backed adapters**

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('three OpenRouter accounts restore and fail independently', (tester) async {
    final app = TestApp.withConnections(
      connections: const ['Production', 'Personal', 'Client'],
      responses: const {
        'Production': FixtureResponse.success,
        'Personal': FixtureResponse.limited,
        'Client': FixtureResponse.timeout,
      },
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.text('Production'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Client'), findsOneWidget);
    expect(find.text('Timeout'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails before the complete wiring exists**

Run:

```powershell
flutter test integration_test/multi_account_flow_test.dart
```

Expected: the test fails until fixture routing and app state are fully connected.

- [ ] **Step 3: Implement only the test harness seams required for fixture-backed integration**

Inject a provider registry and database path into the root app constructor for tests. Production construction continues to use the real OpenRouter registry and `%LOCALAPPDATA%\\TokenDock\\tokendock.db`. Keep fixture transport inside tests; production code receives no test URL or hidden fallback.

- [ ] **Step 4: Run integration and Windows release smoke checks**

Run:

```powershell
flutter test integration_test/multi_account_flow_test.dart
flutter build windows --release
```

Then launch the release executable and verify: first-run empty state, add/test/save three distinct OpenRouter keys, restart restore, tray hide/restore/exit, Ctrl+R, a 402 limited account, and a timeout account retaining cached values.

- [ ] **Step 5: Commit**

```powershell
git add tokendock/integration_test tokendock/test/fixtures tokendock/lib
git commit -m "test: prove independent OpenRouter accounts"
```

## Plan Self-Review

### Spec coverage

- Bootstrap, Windows x64, frameless window, close-to-tray, tray menu, and explicit exit are Tasks 1 and 5.
- Visual modes, reference-derived tokens, responsive layout, loading, empty, stale, error, typography, contrast, keyboard, and reduced motion are Tasks 3, 4, and 11.
- Provider-neutral models, SQLite migrations, cache, settings, secure references, masking, deletion, and UTC handling are Tasks 2, 6, and 7.
- OpenRouter official key-limit contract, 401/403/402/429/5xx/timeout/malformed mappings, finite/unlimited keys, and no Management API are Task 8.
- Test-before-save CRUD, replacement compensation, and credential deletion are Task 9.
- Auto refresh, four-request concurrency, same-ID coalescing, cache-first startup, countdown, and stale preservation are Task 10.
- Three independent live-provider accounts, restart, failure isolation, and Windows smoke proof are Task 12.
- Deferred providers, private OpenCode Console routes, browser automation, session cookies, history, charts, notifications, startup registration, installer, and all cloud features remain outside this plan.

### Placeholder scan

The plan names every created or modified source, fixture, test, command, public interface, provider endpoint, status mapping, and acceptance command. It contains no placeholder implementation steps.

### Type consistency

`Connection`, `Quota`, `ProviderSnapshot`, `TestResult`, `ConnectionStatus`, `ProviderAdapter`, `ConnectionRepository`, `QuotaCacheRepository`, `SecretStore`, `OpenRouterProvider`, and `RefreshService` use the same names and ownership boundaries in every task. `OpenRouterProvider` is the only first-slice live adapter and uses provider ID `openrouter` throughout.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-09-22-tokendock-openrouter-first-goal.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task and review after each task.
2. **Inline Execution** — execute tasks in this session using `executing-plans`, with checkpoints for review.

Choose one approach before implementation.
