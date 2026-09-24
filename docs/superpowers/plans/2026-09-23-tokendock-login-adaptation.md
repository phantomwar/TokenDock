# TokenDock Login Adaptation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement generic login infrastructure (AuthKind + probes, refreshable credentials, loopback OAuth, redaction, Migration003) plus the user-approved Antigravity appendices: local read-only quota (A) and per-account remote OAuth (B).

**Architecture:** Extend `ProviderAdapter` with `AuthKind` and header building; add `RefreshableCredential` with proactive/reactive/test-time refresh under the existing per-connection single-flight lock; add `oauth_loopback.dart` (ephemeral `dart:io` loopback + external browser + PKCE); persist `auth_type`/`identity_key`/`provider_data` via `Migration003`; add `log_redaction.dart`; add Antigravity local reader (A) then remote per-account provider (B). No new packages: `dart:io`, `dart:math`, `dart:convert`, `crypto` (already transitive via Flutter; add only if import fails), `url_launcher` (add only for the external browser step — check `pubspec.yaml` first; if missing, add `url_launcher: ^6.3.1`).

**Tech Stack:** Flutter/Dart; Windows 10/11 x64; `sqflite_common_ffi`; `flutter_secure_storage ^11.2.0`; `dart:io HttpServer`; `url_launcher` (external browser only).

**Spec:** `docs/superpowers/specs/2026-09-23-tokendock-login-adaptation-design.md` (core + Appendix A + Appendix B)

**Execution status (2026-09-23):** completed and merged into `master` (`b03190e`). The implementation required direct `crypto` and `url_launcher` dependencies and Windows ATL for the native integration build; the final code/test counts and remaining work are recorded in `docs/checkpoints/2026-09-23-login-adaptation-checkpoint.md`.

## Global Constraints

- One local process, one local SQLite database, no server, cloud service, analytics, or plugin system.
- Store only `secret_ref` in SQLite; secret values only through `SecretStore` (DPAPI-backed on Windows).
- Preserve cached values after refresh failure; render `Last updated <relative age>` instead of `0%` for stale data.
- Never rely on color alone for status; keep text + icon/symbol labels.
- Limit distinct connection refreshes to four concurrent requests; coalesce concurrent requests for the same connection ID.
- Use sanitized fixtures only; no real key, token, or credential appears in source control or tests.
- Never log, persist, or surface credential bytes; listings never return secret material.
- Windows 10/11 x64 only; do not enable mobile, web, macOS, or Linux targets.
- `flutter test --no-pub` green; `flutter analyze` 0 errors (informational `prefer_initializing_formals` in `RefreshService` pre-exists — do not add new lints).

---

### Task 1: AuthKind + header building on the adapter boundary

**Files:**
- Modify: `tokendock/lib/providers/provider_adapter.dart`
- Modify: `tokendock/lib/providers/openrouter/openrouter_provider.dart`
- Modify: `tokendock/lib/providers/provider_registry.dart`
- Test: `tokendock/test/providers/auth_kind_test.dart`

**Interfaces:**
- Consumes: existing `ProviderAdapter.test/fetch`, `Connection`, `TestResult`, `ProviderSnapshot`.
- Produces: `enum AuthKind { apiKey, oauth, structuredBearer, none }`; `ProviderAdapter.authKind`, `ProviderAdapter.buildAuthHeader(String secret)`; registry exposes each adapter's kind unchanged lookup.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';

void main() {
  test('openrouter declares apiKey and builds Bearer at call time', () {
    final adapter = ProviderRegistry.withDefaults().get('openrouter')!;
    expect(adapter.authKind, AuthKind.apiKey);
    expect(adapter.buildAuthHeader('sek-ret'), {
      'Authorization': 'Bearer sek-ret',
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/providers/auth_kind_test.dart`
Expected: FAIL — `authKind`/`buildAuthHeader` do not exist.

- [ ] **Step 3: Write minimal implementation**

```dart
enum AuthKind { apiKey, oauth, structuredBearer, none }

// in ProviderAdapter:
AuthKind get authKind;
Map<String, String> buildAuthHeader(String secret) =>
    {'Authorization': 'Bearer $secret'};
```

```dart
// in OpenRouterProvider:
@override
AuthKind get authKind => AuthKind.apiKey;
```

Registry needs no signature change (lookup unchanged); document `openrouter=apiKey` in a comment.

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test --no-pub test/providers/auth_kind_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/providers/provider_adapter.dart tokendock/lib/providers/openrouter/openrouter_provider.dart tokendock/lib/providers/provider_registry.dart tokendock/test/providers/auth_kind_test.dart
git commit -m "feat: declare AuthKind and build auth headers at call time"
```

### Task 2: Log redaction helper + audit

**Files:**
- Create: `tokendock/lib/services/log_redaction.dart`
- Modify: `tokendock/lib/services/refresh_service.dart:247-271`
- Test: `tokendock/test/services/log_redaction_test.dart`

**Interfaces:**
- Consumes: raw error strings, header maps, URLs.
- Produces: `String redactSecret(String input, [List<String> secrets])`, `Map<String, String> redactHeaders(Map<String, String> headers)`, `String redactUrl(String url)`; refresh path uses them instead of single `replaceAll`.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/log_redaction.dart';

void main() {
  test('redacts bearer, query string, and named secrets', () {
    expect(
      redactSecret('failed with sk-live-123', ['sk-live-123']),
      isNot(contains('sk-live-123')),
    );
    expect(redactHeaders({'Authorization': 'Bearer x', 'X-Ok': '1'}),
        {'Authorization': '[redacted]', 'X-Ok': '1'});
    expect(redactUrl('https://h/p?token=abc&x=1'), 'https://h/p');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/services/log_redaction_test.dart`
Expected: FAIL — library does not exist.

- [ ] **Step 3: Write minimal implementation**

```dart
final _sensitive = RegExp(
  r'key|token|secret|auth|credential|cookie',
  caseSensitive: false,
);

String redactSecret(String input, [List<String> secrets = const []]) {
  var out = input;
  for (final s in secrets) {
    if (s.isNotEmpty) out = out.replaceAll(s, '[redacted]');
  }
  return out.replaceAll(
    RegExp(r'(Bearer\s+)[^\s"\x27,}]+', caseSensitive: false),
    r'$1[redacted]',
  );
}

Map<String, String> redactHeaders(Map<String, String> headers) {
  return headers.map(
    (k, v) => MapEntry(k, _sensitive.hasMatch(k) ? '[redacted]' : v),
  );
}

String redactUrl(String url) {
  final q = url.indexOf('?');
  return q == -1 ? url : url.substring(0, q);
}
```

In `refresh_service.dart`, replace both `replaceAll(secret, '[REDACTED]')` sites with `redactSecret(..., [secret])`.

- [ ] **Step 4: Run tests**

Run: `flutter test --no-pub test/services/log_redaction_test.dart test/services/refresh_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/services/log_redaction.dart tokendock/lib/services/refresh_service.dart tokendock/test/services/log_redaction_test.dart
git commit -m "feat: centralize secret redaction for logs and errors"
```

### Task 3: Migration003 — identity_key + provider_data + auth_type activation

**Files:**
- Create: `tokendock/lib/storage/migration_003.dart`
- Modify: `tokendock/lib/storage/database.dart:59-60`
- Modify: `tokendock/lib/models/connection.dart`
- Modify: `tokendock/lib/storage/connection_repository.dart:16-73`
- Test: `tokendock/test/storage/migration_003_test.dart`

**Interfaces:**
- Consumes: `Migration001`/`Migration002` chain, `PRAGMA user_version`.
- Produces: `Migration003.version = 3` adding `identity_key TEXT`, `provider_data TEXT`; `Connection.authType`, `Connection.identityKey`, `Connection.providerData` round-tripped by the repository; `AppDatabase.open` runs all three migrations.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tokendock/storage/database.dart';

void main() {
  test('migration003 adds identity columns and bumps to v3', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await AppDatabase.open(path: inMemoryDatabasePath).then((a) => a.close());
    final v = (await db.rawQuery('PRAGMA user_version')).first.values.first;
    // asserts columns exist
    final cols = await db.rawQuery('PRAGMA table_info(connections)');
    final names = cols.map((c) => c['name']).toSet();
    expect(v, 3);
    expect(names, containsAll(['identity_key', 'provider_data', 'auth_type']));
    await db.close();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/storage/migration_003_test.dart`
Expected: FAIL — version stays 2, columns missing.

- [ ] **Step 3: Write minimal implementation**

```dart
import 'package:sqflite_common/sqlite_api.dart';

class Migration003 {
  static const int version = 3;

  static Future<void> run(Database db) async {
    final result = await db.rawQuery('PRAGMA user_version');
    final currentVersion = (result.first.values.first as num?)?.toInt() ?? 0;
    if (currentVersion >= version) return;
    await db.transaction((txn) async {
      await txn.execute(
        'ALTER TABLE connections ADD COLUMN identity_key TEXT',
      );
      await txn.execute(
        'ALTER TABLE connections ADD COLUMN provider_data TEXT',
      );
    });
    await db.execute('PRAGMA user_version = $version');
  }
}
```

Wire `Migration003.run(db)` after `Migration002` in `database.dart`; extend `Connection` with nullable `authType`, `identityKey`, `providerData`; read/write them in `SqliteConnectionRepository` (insert sets `auth_type` from the model instead of hardcoded null; update writes `identity_key`/`provider_data`).

- [ ] **Step 4: Run tests**

Run: `flutter test --no-pub test/storage/migration_003_test.dart test/storage/repositories_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/storage/migration_003.dart tokendock/lib/storage/database.dart tokendock/lib/models/connection.dart tokendock/lib/storage/connection_repository.dart tokendock/test/storage/migration_003_test.dart
git commit -m "feat: add migration003 identity and provider metadata"
```

### Task 4: RefreshableCredential + single-flight token lock in RefreshService

**Files:**
- Create: `tokendock/lib/services/refreshable_credential.dart`
- Modify: `tokendock/lib/services/refresh_service.dart:96-147`
- Test: `tokendock/test/services/refreshable_test.dart`

**Interfaces:**
- Consumes: `_inFlight` coalescing, `SecretStore`, `ConnectionHealthRepository`.
- Produces: `abstract interface RefreshableCredential { DateTime? get expiresAt; Duration get refreshLead; Future<String> refresh(String currentSecret); }`; `RefreshService.ensureFreshSecret(connectionId)` joining in-flight work; proactive skew 60s; reactive single retry kept for later tasks.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/refreshable_credential.dart';

class _Fake implements RefreshableCredential {
  int calls = 0;
  @override
  DateTime? get expiresAt => DateTime.now().toUtc().add(
        const Duration(seconds: 30),
      );
  @override
  Duration get refreshLead => const Duration(minutes: 1);
  @override
  Future<String> refresh(String s) async {
    calls++;
    return 'new-$s';
  }
}

void main() {
  test('contract exposes expiry, lead, and refresh', () async {
    final c = _Fake();
    expect(c.refreshLead, const Duration(minutes: 1));
    expect(await c.refresh('a'), 'new-a');
    expect(c.calls, 1);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/services/refreshable_test.dart`
Expected: FAIL — interface missing.

- [ ] **Step 3: Write minimal implementation**

```dart
abstract interface class RefreshableCredential {
  DateTime? get expiresAt;
  Duration get refreshLead;
  Future<String> refresh(String currentSecret);
}
```

In `RefreshService`, key token operations by `'token:$provider:$connectionId'` in the same `_inFlight` map (rename map usage to a generic in-flight registry if needed without changing the public `refreshOne` contract); API-key adapters ignore the interface.

- [ ] **Step 4: Run tests**

Run: `flutter test --no-pub test/services/refreshable_test.dart test/services/refresh_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/services/refreshable_credential.dart tokendock/lib/services/refresh_service.dart tokendock/test/services/refreshable_test.dart
git commit -m "feat: add refreshable credential contract and token lock"
```

### Task 5: Generic OAuth loopback flow (fake provider in tests)

**Files:**
- Create: `tokendock/lib/services/oauth_loopback.dart`
- Test: `tokendock/test/services/oauth_loopback_test.dart`

**Interfaces:**
- Consumes: `dart:io HttpServer`, `dart:math Random.secure`, `dart:convert` (base64url SHA-256 via `crypto` — use `package:crypto` only if not already transitive; check import first).
- Produces: `class OAuthLoopbackResult { String code; String state; }`; `Future<OAuthLoopbackSession> OAuthLoopback.start({String callbackPath = '/callback', Duration timeout = 300s})` with `redirectUri`, `launchUrl`, `waitForCode(expectedState)`; `String buildCodeChallenge(String verifier)` (S256, no padding); `String newCodeVerifier()`, `String newState()`.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/oauth_loopback.dart';

void main() {
  test('challenge is S256 without padding and session round-trips', () async {
    final session = await OAuthLoopback.start();
    expect(session.redirectUri.startsWith('http://127.0.0.1:'), isTrue);
    final delivered = session.waitForCode('s1');
    final uri = Uri.parse(
      '${session.redirectUri}?code=abc&state=s1',
    );
    // simulate browser hit via HttpClient get(uri)
    // expect(await delivered, code == 'abc')
    await session.close();
    expect(buildCodeChallenge('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/services/oauth_loopback_test.dart`
Expected: FAIL — module missing.

- [ ] **Step 3: Write minimal implementation**

Loopback-only `HttpServer.bind(InternetAddress.loopbackIPv4, 0)`; handle `GET callbackPath` → validate `state`, capture `code`, respond minimal HTML, complete future; timeout closes server; `close()` idempotent. Verifier: 32 `Random.secure()` bytes → base64url no padding (43 chars). Challenge: SHA-256 bytes → base64url no padding. State: 16 bytes hex.

- [ ] **Step 4: Run test**

Run: `flutter test --no-pub test/services/oauth_loopback_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/services/oauth_loopback.dart tokendock/test/services/oauth_loopback_test.dart
git commit -m "feat: add generic OAuth loopback flow with PKCE"
```

### Task 6: Tombstone + credential-disabled event

**Files:**
- Create: `tokendock/lib/services/credential_events.dart`
- Modify: `tokendock/lib/services/refresh_service.dart:293-319`
- Test: `tokendock/test/services/tombstone_test.dart`

**Interfaces:**
- Consumes: `_persistHealthAndPublish`, `ConnectionHealthRepository`.
- Produces: `class CredentialDisabledEvent { String connectionId; String cause; String? identityKey; }`; `RefreshService.addDisabledListener/removeDisabledListener`; definitive failures (`invalid_grant`, bare 401) publish the event and persist `last_error` tombstone without erasing cache.

- [ ] **Step 1: Write the failing test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/credential_events.dart';

void main() {
  test('disabled event carries cause and identity, never token', () {
    const e = CredentialDisabledEvent(
      connectionId: 'c1',
      cause: 'invalid_grant',
      identityKey: 'a@b|x',
    );
    expect(e.toString(), isNot(contains('refresh')));
    expect(e.cause, 'invalid_grant');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/services/tombstone_test.dart`
Expected: FAIL — event type missing.

- [ ] **Step 3: Write minimal implementation**

Value class + listener list in `RefreshService` mirroring `_snapshotListeners`; helper `isDefinitiveOAuthFailure(Object error)` matching `invalid_grant` / bare-401 strings (status-first, minimal).

- [ ] **Step 4: Run tests**

Run: `flutter test --no-pub test/services/tombstone_test.dart test/services/refresh_service_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/services/credential_events.dart tokendock/lib/services/refresh_service.dart tokendock/test/services/tombstone_test.dart
git commit -m "feat: add credential tombstone and disabled event"
```

### Task 7: Appendix A — Antigravity local read-only quota source

**Files:**
- Create: `tokendock/lib/providers/antigravity/antigravity_local.dart`
- Create: `tokendock/lib/providers/antigravity/antigravity_provider.dart`
- Test: `tokendock/test/providers/antigravity_local_test.dart`

**Interfaces:**
- Consumes: `ProviderAdapter` (authKind `none`), `Connection.providerData` (`{"source":"language-server"|"agy-cli","agyBin":...}`), `RefreshService` fetch path.
- Produces: `AntigravityLocalReader.fetchSnapshot(Connection)` implementing source order language_server (`RetrieveUserQuotaSummary` → `GetUserStatus` → `GetCommandModelConfigs` over loopback HTTPS with CSRF) → `agy -p /usage --output-format json` subprocess gated on `agy --version >= 1.1.11`, 90s/1MiB bounds; pools Gemini + Claude/GPT with weekly/5h windows; `Limits not available` on availability-only payloads; account mismatch rejected.

- [ ] **Step 1: Write the failing test**

Fake JSON fixtures: `antigravity_quota_summary.json` (groups/buckets with `remainingFraction`), `antigravity_agy_print.json` (print-mode shape), `antigravity_availability_only.json` (all-100% no quota echo). Assert pool mapping, reset parsing, `Limits not available`, version gate rejects `1.1.10`.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test --no-pub test/providers/antigravity_local_test.dart`
Expected: FAIL — reader missing.

- [ ] **Step 3: Write minimal implementation**

Pure parsing + source-selection logic first; process execution (`Process.run`) isolated behind an injectable runner for tests. No CSRF/token persisted beyond the in-memory snapshot; insecure TLS scoped to `127.0.0.1` only.

- [ ] **Step 4: Run test**

Run: `flutter test --no-pub test/providers/antigravity_local_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/providers/antigravity/antigravity_local.dart tokendock/lib/providers/antigravity/antigravity_provider.dart tokendock/test/providers/antigravity_local_test.dart tokendock/test/fixtures/antigravity_*.json
git commit -m "feat: add Antigravity local read-only quota source"
```

### Task 8: Appendix B — per-account remote OAuth provider

**Files:**
- Create: `tokendock/lib/providers/antigravity/antigravity_oauth.dart`
- Modify: `tokendock/lib/providers/antigravity/antigravity_provider.dart`
- Modify: `tokendock/lib/providers/provider_registry.dart`
- Test: `tokendock/test/providers/antigravity_oauth_test.dart`

**Interfaces:**
- Consumes: `OAuthLoopback`, `RefreshableCredential`, `SecretStore` (one `secret_ref` per connection), `Connection.identityKey` (`email+accountId`), `Connection.providerData` (`projectId`/`tier`), Appendix A pool mapping.
- Produces: `AntigravityOAuthProvider` (`authKind = AuthKind.oauth`) with login (`loadCodeAssist` prod/daily retry + `onboardUser` when tierless; empty project → onboarding prompt, never invented), quota (`retrieveUserQuotaSummary` first, legacy merged by worst fraction), `SelectedAccountGuard` (mismatch rejected without caching), schema-change tombstone `quota_source_changed` with cache preserved.

- [ ] **Step 1: Write the failing tests**

Fake HTTP: login exchange, `loadCodeAssist` with/without project, `retrieveUserQuotaSummary` buckets, mismatch account, changed schema. Assert per-account isolation (two connections never share tokens), guard rejection, tombstone cause.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test --no-pub test/providers/antigravity_oauth_test.dart`
Expected: FAIL — provider missing.

- [ ] **Step 3: Write minimal implementation**

Register `antigravity` in `ProviderRegistry` defaults behind the existing pattern; reuse Appendix A parsing; token exchange POSTs `code` + `code_verifier` + `redirect_uri` (no `client_secret`).

- [ ] **Step 4: Run tests**

Run: `flutter test --no-pub test/providers/antigravity_oauth_test.dart test/providers/antigravity_local_test.dart test/providers/auth_kind_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add tokendock/lib/providers/antigravity/antigravity_oauth.dart tokendock/lib/providers/antigravity/antigravity_provider.dart tokendock/lib/providers/provider_registry.dart tokendock/test/providers/antigravity_oauth_test.dart
git commit -m "feat: add per-account Antigravity remote OAuth provider"
```

### Task 9: Docs sync + full verification

**Files:**
- Modify: `PRODUCT.md`, `tokendock/README.md`, `docs/auth-quota-hardening-plan.md` (status lines only)

**Interfaces:**
- Consumes: all tasks above.
- Produces: status lines naming new modules, `user_version = 3`, provider list (`openrouter`, `antigravity`), verification evidence.

- [ ] **Step 1: Update status lines** (no code changes in this task).
- [ ] **Step 2: Run full suite**

Run: `flutter test --no-pub`
Expected: all tests pass (109 baseline + new tests).

- [ ] **Step 3: Run analyzer**

Run: `flutter analyze`
Expected: 0 errors (pre-existing 5 infos in `RefreshService` unchanged; no new diagnostics).

- [ ] **Step 4: Commit**

```bash
git add PRODUCT.md tokendock/README.md docs/auth-quota-hardening-plan.md
git commit -m "docs: sync status to login adaptation implementation"
```
