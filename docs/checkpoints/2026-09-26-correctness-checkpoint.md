# TokenDock checkpoint — correctness and claims integrity

**Date:** 2026-09-26
**Branch:** `master` @ `9ae626f`
**Checkpoint parent:** `0f5205e` (last pre-audit commit)
**Commits in this session:** 21, all local, nothing pushed
**Status:** all P0 and P1 findings closed. 366/366 tests, 0 errors, 0 warnings.

**Companion documents**

- `docs/audit-2026-09-25-second-pass.md` — the 36 findings, with per-item state
- `docs/superpowers/plans/2026-09-25-tokendock-correctness-plan.md` — the plan
- `docs/auth-quota-hardening-plan.md` — the original phased auth/quota plan
- `PRODUCT.md`, `PRD.txt` — product status, synchronised with this checkpoint

---

## What changed, and why

The audit behind this session produced 36 findings. Every P0 and every P1 is
closed. The session was executed test-first: each fix has a test that was
observed failing against the old code first, and several findings were corrected
by that evidence rather than confirmed.

### P0 — closed (5/5)

| ID | Fix | Commit |
|---|---|---|
| C-01 | Antigravity OAuth transport had no timeout, no response cap | `4f79598` |
| C-02 | Migration DDL and `user_version` were not atomic; a crash bricked startup | `1e144e1` |
| C-03 | `DateTime.parse` without `tryParse` on the read path | `1e144e1` |
| C-04 | A benign refresh race revoked a live credential | `f477ac9` |
| C-05 | Cancellation rollback masked the cancellation with a storage error | `c95b584` |

### P1 — closed (11/11)

| ID | Fix | Commit |
|---|---|---|
| C-06 | Dark ramp reused light status colours; 3.06–3.29:1 against a 4.5:1 requirement | `91b8840` |
| C-07 | `Colors.green`/`Colors.red` hardcoded; 2.78:1 | `91b8840` |
| C-08 | `Last updated` froze on the first frame | `b1ba687` |
| C-09 | Token exchange had no single-flight; wiring it naively deadlocked | `a4f902c` |
| C-10 | A corrupt credential read was sent as a bearer token | `44bcf25` |
| C-11 | Failure classification matched message text; three separate instances | `44bcf25` |
| C-12 | Raw exception interpolated into user-facing copy | `ca749bf` |
| C-13 | `provider_data` sanitiser was token-blind | `1e144e1` |
| C-14 | OAuth loopback IPv6 companion was shared between processes | `daf4af0` |
| C-15 | SQLite exceptions reached the UI with SQL and table names | `ca749bf` |
| C-25 | Rotated-refresh-token ledger was unbounded and held plaintext | `f477ac9` |

### P2/P3 — closed (7)

| ID | Fix | Commit |
|---|---|---|
| C-16 | No keyed lookup, so a refresh cycle issued 1+N full table reads | `ba67afd` |
| C-17 | `load()` issued 1+2N queries; health was selected then discarded | `d2b8467` |
| C-18 | PowerShell session discovery unbounded and inline on the fetch path | `841eede` |
| C-20 | The authoritative quota value rendered in muted ink | `e353e9f` |
| C-21 | Countdown ticked every second, once per quota | `e353e9f` |
| C-31 | An uncapped key rendered `Unavailable`, the word used for real errors | `4faea73` |
| — | C-13's shared `isSensitiveKeyName` predicate, used by both redaction and persistence | `1e144e1` |

---

## Findings the execution corrected

TDD did not just confirm this audit. It refuted parts of it, and those
corrections are recorded in the audit rather than quietly dropped.

1. **C-05 was overstated.** The audit claimed the interleaved
   `await Future<void>.value()` no-ops made cancellation timing-dependent. A
   test that cancels synchronously as the login resolves, repeated 25 times,
   **passed against the old code**: microtasks run FIFO, so a cancel delivered
   before a real await is already queued ahead of the continuation. The real,
   reproducible defect was different and was not in the original finding: the
   compensating delete reported a storage error instead of the cancellation.

2. **C-06 was worse than documented.** `statusUpdating` in the dark ramp was
   also below 4.5:1 and was missing from the original table. The parameterized
   contrast test caught it.

3. **C-09 contained a deadlock the audit did not predict.**
   `runTokenOperation` delegated to `runConnectionOperation`, which *chains*
   when the connection already has an in-flight operation, and
   `_performRefreshOne` runs while holding that slot. Wiring it in naively would
   have made a refresh wait on itself forever. My first test passed for the
   wrong reason: it issued the token operation as the outer operation's first
   action, before the in-flight entry was published. It only failed once
   corrected to yield first, as the real code does.

4. **C-11 had three instances, not one.** Beyond the classifier, the prod-to-daily
   host fallback tested `error.message.contains('HTTP 404')` and the snapshot
   mapper tested `contains('http 403')`. They surfaced only when the typed
   status replaced the string sentinel.

5. **A test pinned the leak as expected behaviour.**
   `connections_screen_test.dart` asserted
   `find.textContaining('Database write failed')` under the comment "Safe error
   message is displayed". That text only reached the UI through interpolation.

6. **An assertion of mine was wrong.** Demanding 3:1 from the hairline, which is
   a decorative 1px separator at 1.2:1 that WCAG 1.4.11 exempts. The
   requirement is the quota fill and the focus ring.

7. **Two flakes I introduced, of the same shape as the bug being fixed.** The
   C-18 test raced a real five-second budget against a ten-second timeout, and
   then let the reader fall through to the `agy` CLI with the real process
   runner, so a unit test was spawning processes. Both fixed; five consecutive
   full runs now pass where three earlier runs failed.

8. **Two mistakes in my own commit hygiene, caught and corrected.** A
   `git add -A` mixed two logical changes under one message, and a
   `dart format` added roughly 230 lines of whitespace churn to a file whose
   real change was 18 lines. Both commits were redone, churn reduced to 18, and
   each commit is now verified in isolation with `flutter test`.

---

## Verification

Measured on `9ae626f`, not carried over from documentation.

- `flutter test --no-pub`: **366/366 passed**, on three consecutive runs after
  the flake fixes. Baseline before this session was 235.
- `flutter analyze --no-pub`: **0 errors, 0 warnings, 31 informational
  diagnostics**. Baseline before this session was 33.
- `dart format`: clean on every file this session touched. 36 files in the tree
  remain unformatted; they are pre-existing and were deliberately left alone
  rather than creating an unrelated diff.
- Commits verified individually: for example `ca749bf` alone passes 333/333.
- Working tree clean.

### Not verified

- `flutter build windows --release` — **not run in this session**.
- `flutter test integration_test/multi_account_flow_test.dart` — **not run in
  this session**.

Both need the full Windows toolchain. The README and `PRODUCT.md` lines about
them are unchanged from the previous session and remain unverified by this work.
No real Google OAuth, external browser, or Antigravity process was exercised:
every test uses sanitized fake HTTP and process fixtures.

---

## Resume checklist

Ordered by value. Each item names the audit ID it closes.

1. **C-23, schema integrity.** No foreign key is declared anywhere and
   `PRAGMA foreign_keys` is never enabled, so `quota_cache` is cleaned up
   manually in two places. `idx_quota_cache_connection` duplicates the
   `(connection_id, quota_key)` primary key. `quota_cache.status` is written
   always as null and never read. `connections` has no index on the
   `sort_order, created_at` it is ordered by. Adding the FK needs
   `onConfigure` on `openDatabase`, which does not exist yet. *Caution: this
   changes the schema and needs a migration.*
2. **C-22, density parity.** `_buildCompact`, `_buildNormal` and
   `_buildExpanded` duplicate their preamble and footer. Compact does not render
   `snapshot.error` while the other two do, and no test asserts that asymmetry.
   Decide whether compact should show errors, then extract the shared parts.
3. **C-19, typography against the spec.** The design spec requires 11/13/15/18/22px
   steps and 20px semibold quota figures. `theme.dart` ships 13px w500 quota
   figures, 13px w600 titles, 14px body, 12px caption, and no 18px or 22px step.
   This is a visual change and needs a design pass, not a mechanical edit.
4. **C-24, `AppState` notifier.** `AppState implements ChangeNotifier` by
   delegating to a private `_StateNotifier` through a static `Expando`, while its
   const constructors are canonicalised by Dart. Two `const AppState.loading()`
   instances therefore share one notifier, and `dispose()` on one affects the
   other. Convert to a real `ChangeNotifier` and drop the `Expando`.
5. **C-26, C-27, dead code.** `redactHeaders` and `redactUrl` in
   `log_redaction.dart` and `isDefinitiveOAuthFailure` in
   `credential_events.dart` have no callers. `_credential` is duplicated in
   `antigravity_oauth.dart` at two sites. Either wire or delete.
6. **C-29, C-30, cleanup.** `deleteSync` in a `finally` can mask the agy timeout
   and leak the temp directory. `_loadedRawSecret` is never cleared in the
   dialog's `dispose`.
7. **C-28, C-32, C-33, C-34, C-35, C-36, smaller items.** Dual representation of
   `AuthKind` versus raw `'oauth'`/`'none'` strings; `AppCard` and
   `SectionHeader` are never instantiated though the spec requires them;
   `defaultRefreshIntervalMinutes` is declared twice; remaining documentation
   drift; and the test gaps and real-wall-clock waits listed in the audit.

### Carry-over risks worth knowing

- **`redactSecret` does not catch a bare token.** It requires a `key:`/`key=`
  prefix or valid JSON. `"Rejected token sk-or-v1-..."` with no colon survives
  it. This is why the `UserSafeFailure` escape hatch was removed: every
  user-facing error string is now a compile-time literal at the call site, so
  the guarantee does not depend on the redactor.
- **Test fakes keyed to a call ordinal go inert silently** when a repository
  method changes. This bit twice in this session. Prefer an explicit flag or a
  hook on the method actually called.
- **Unit tests must not spawn processes.** A local-reader test that injects a
  discovery returning no sessions falls through to the real `agy` CLI unless a
  refusing `AntigravityProcessRunner` is injected.

---

## Non-goals for the next session

- Do not infer undocumented Antigravity quota fields or private endpoints.
- Do not add device-code or embedded WebView login.
- Do not store CSRF, access, refresh or ID tokens in SQLite.
- Do not push or merge without an explicit integration request. The 21 commits
  are local and `master` is 21 ahead of `origin/master`.
- Do not reformat the 36 pre-existing unformatted files as a side effect of
  touching something else.
- Do not add installer, notifications, groups, auto-start, history or charts;
  they remain deferred scope.
- Do not add a new dependency; none was added in this session.

---

## Open question for the maintainer

The `connections` table has no foreign key from `quota_cache` and
`PRAGMA foreign_keys` is never enabled, so referential integrity is currently
enforced only by application code (C-23). Enabling it changes runtime
behaviour for any existing database and needs a migration, and the project
deliberately owns `user_version` itself rather than using sqflite's `version:`
callback. **Decide whether to adopt sqflite's `onConfigure`/`onUpgrade` for
foreign keys only, or keep the manual ownership and add the pragma at open
time.** The manual route is smaller and consistent with what is already there.
