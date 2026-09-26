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

1. ~~**C-23, schema integrity.**~~ **Closed at `6b93b7b`.** `Migration004`
   rebuilds `quota_cache` with the cascade to `connections`, drops the dead
   `status` column and the index the composite primary key already covered, and
   adds `idx_connections_sort_order` — the index C.1 left behind. See
   § Open question below for why the pragma is applied after the migrations
   rather than through `onConfigure`, which is the part that is easy to get
   wrong on a future schema change.
2. ~~**C-22, density parity.**~~ **Closed at `ddd03f7`.** The three densities
   now share one frame (`_buildAccounts`) that owns the cache age and the error
   line, so the footer cannot drift again. Compact renders errors — decided with
   the maintainer, on the grounds that a stale number presented as current breaks
   cache-first truth. `test/ui/density_parity_test.dart` pins the parity.
3. ~~**C-19, typography against the spec.**~~ **Closed at `b853186`.** The ramp is
   now the spec's 11/13/15/18/22 with 20px semibold tabular figures, every step
   a named token. The two roles that had no token were `copyWith` overrides at
   the call site, which is how the ramp drifted unnoticed. The countdown got its
   own step: sharing `quotaStyle` would have made "resets in 2h 15m" shout as
   loudly as the figure it annotates, in the one density where that figure
   already competes for space.
4. ~~**C-24, `AppState` notifier.**~~ **Closed at `3705170`.** `AppState` is a
   real `ChangeNotifier` and owns its own listener list. The `Expando`, the
   `_StateNotifier` delegate and the const constructors are gone.

   One trap to know about if you touch `TokenDockApp`: its fallback state is
   built **in the constructor**, not in `build`. Building a fresh `AppState` per
   build would look correct and would silently drop the `ListenableBuilder`'s
   subscription every time an ancestor rebuilt.
5. ~~**C-26, C-27, dead code.**~~ **Closed at `45aad6c`.** `redactHeaders`,
   `redactUrl` and `isDefinitiveOAuthFailure` are deleted; each had no
   production caller and existed only alongside tests that exercised it, which
   is the worst kind of dead code. The duplicated `_credential` was worse than
   duplication: one copy threw `credentialUnreadable` and the other silently
   returned `{}`, so the C-10 tightening had left the second one swallowing.
   Both now delegate to one pair of functions whose names state the difference.
6. ~~**C-29, C-30, cleanup.**~~ **Closed at `f43e27b`.** A throw from a
   `finally` was discarding the snapshot the `try` was about to return, so a
   locked temp directory turned a good quota read into a `FileSystemException`.
   Cleanup is now injected and swallows failures. The dialog no longer keeps a
   plaintext credential in a `State` field: `RefreshService.testAdapter`
   re-reads it from the store anyway, so the copy was only ever a fallback for a
   store read that had already failed.
7. ~~**C-28, C-32, C-33, C-34, C-35, C-36.**~~ **Closed across `14f6979`,
   `75b7ef5` and `757aa09`.** `auth_type` is derived from `AuthKind` and guarded
   by a source guard; `AppCard` and `SectionHeader` are deleted and the spec now
   records that the design moved to a card-free shell; the duplicated
   `defaultRefreshIntervalMinutes` is gone; the masked credential format now
   matches the spec's bullet run; `limit == 0` reads as `No key cap`; the 330/550
   breakpoints are pinned; and the 250ms socket budget is a named 2s liveness
   guard.

### The whole audit is closed

All 36 findings are done, and both previously unverified gates have now been
run for the first time:

- `flutter build windows --release` — **succeeds**, `tokendock.exe` in 158s, 8
  `C4267`/`C4996` warnings all inside the third-party `cnativeapi` plugin and
  none in this repository's code.
- `flutter test integration_test/multi_account_flow_test.dart -d windows` —
  **3/3**, on the `windows-x64` device. Fixture-backed, so it proves the
  multi-account restore/cache/failure wiring against the real `%LOCALAPPDATA%`
  database, not a live provider call.

Both needed Windows Developer Mode. Flutter creates the plugin symlinks under
`windows/flutter/ephemeral/.plugin_symlinks`, and on Windows that requires
either Developer Mode or an elevated shell. This was the blocker the first-goal
spec had already recorded as "Windows integration pending on symlink/Developer
Mode" — it was never a code problem, and no amount of Dart-side work would have
cleared it.

### Carry-over risks worth knowing

- **`redactSecret` does not catch a bare token.** It requires a `key:`/`key=`
  prefix or valid JSON. `"Rejected token sk-or-v1-..."` with no colon survives
  it. This is why the `UserSafeFailure` escape hatch was removed: every
  user-facing error string is now a compile-time literal at the call site, so
  the guarantee does not depend on the redactor.
- **Test fakes keyed to a call ordinal go inert silently** when a repository
  method changes. This bit twice in this session. Prefer an explicit flag or a
  hook on the method actually called.
- **`saveAll` can now raise where it used to succeed.** With
  `PRAGMA foreign_keys` on, caching a quota for a connection that no longer
  exists is rejected with SQLite error 787 instead of silently writing an
  orphan. **This was resolved** by `RefreshService._connectionStillExists`,
  which runs only on the failure path and distinguishes the two reasons a write
  can fail, because they need opposite responses: a connection deleted while the
  refresh was in flight ends the refresh quietly (the write has nothing to
  attach to), while a genuine storage fault still reports "Local storage
  unavailable". A failure to answer the existence question is treated as "still
  there", since guessing "gone" would swallow a real fault and leave a stale
  number with no explanation.
- **The Windows build needs Developer Mode.** `flutter build windows` and any
  `integration_test` on `windows-x64` fail at CMake with "add_subdirectory given
  source ... which is not an existing directory" unless the plugin symlinks can
  be created. On Windows that needs `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock\AllowDevelopmentWithoutDevLicense = 1`
  (Developer Mode, no admin required once toggled in Settings) or an elevated
  shell. Turning on `flutter config --enable-windows-desktop` alone is not
  enough, and `--no-pub` makes it worse because the plugin registrations are
  never regenerated.
- **Any future table rebuild inherits the same trap.** `PRAGMA foreign_keys` is
  a no-op inside a transaction, so a migration that must rebuild a table has to
  run with enforcement off, which is why the pragma sits after the migration
  list in `AppDatabase.open`. Moving it earlier, or into `onConfigure`, looks
  like a harmless tidy-up and breaks the upgrade path for any database holding
  a single violating row.
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

## Open question for the maintainer — **resolved 2026-09-26**

The `connections` table has no foreign key from `quota_cache` and
`PRAGMA foreign_keys` is never enabled, so referential integrity is currently
enforced only by application code (C-23). Enabling it changes runtime
behaviour for any existing database and needs a migration, and the project
deliberately owns `user_version` itself rather than using sqflite's `version:`
callback. **Decide whether to adopt sqflite's `onConfigure`/`onUpgrade` for
foreign keys only, or keep the manual ownership and add the pragma at open
time.** The manual route is smaller and consistent with what is already there.

### Decision: keep the manual ownership, enable the pragma **after** the migrations run

`AppDatabase.open` runs the migrations by hand, after `openDatabase` returns.
The pragma therefore goes in `AppDatabase.open` too, in this order:

1. `openDatabase`
2. `Migration001` … `Migration004`
3. `PRAGMA foreign_keys = ON`

**This is not only the smaller diff. `onConfigure` is the option that cannot
work.** Measured against the bundled SQLite (`sqflite_common_ffi` 2.4.3), with
a throwaway probe that was run and then deleted:

- `PRAGMA foreign_keys = OFF` **issued inside a transaction is a no-op.** The
  pragma stayed at `1` after the `OFF` and the transaction still saw
  enforcement on. SQLite only accepts the toggle when no `BEGIN`/`SAVEPOINT`
  is pending.
- An `INSERT` of an orphan row into an FK-declared table fails with
  `FOREIGN KEY constraint failed (code 787)`, as expected.
- The standard table rebuild — create `quota_cache_new` with the FK, copy,
  drop, rename — run inside a transaction with a **pre-existing orphan** in
  `quota_cache` **fails with error 787**, and the in-transaction `foreign_keys
  = OFF` does not rescue it.

That third result is the whole decision. `onConfigure` fires *before*
`AppDatabase.open` gets the handle back, so it would leave FK enforcement
active across the migration that has to rebuild the table, and no statement
inside that migration can turn it off. Any existing database holding a single
orphan row would fail to launch. Ordering the pragma after the migrations
keeps the rebuild in the configuration the file has always been in, and the
rebuild also purges orphans explicitly so the new table is clean regardless of
the pragma's state.

The costs accepted: the pragma is now asserted by a test rather than by the
type system, and `TestDatabase.create` must set it too or the repositories
would be tested under a weaker contract than production. Both are one line
each and both are asserted.

`PRAGMA foreign_keys` is off by default in SQLite, so the route also preserves
the existing invariant that nothing on the write path depends on enforcement
being on — `saveAll` is called from the refresh path and would now raise
instead of silently orphaning a row if the parent connection were gone.

---

## Addendum: MiniMax quota and OpenCode Go — the previous session's conclusion was wrong

The session above closed the audit. A later session added providers, and **first
got MiniMax and OpenCode wrong in a way worth carrying forward.**

### What was claimed, and why it was wrong

The earlier note concluded: MiniMax "publishes no balance, usage or quota
endpoint", and OpenCode Zen and Go were both unregistrable because
`GET /zen*/v1/models` returns **200 for a garbage key** (which was measured, and
is true).

Both conclusions were false, and they failed the same way — **a conclusion was
drawn from one measurement without asking whether the measurement was the right
one.**

- The model listing ignoring the key is *correct behaviour*, not a defect. A
  catalog is static by definition, so an account-independent answer is exactly
  what it should be. From "the listing cannot gate a credential" it does not
  follow that "nothing can".
- The endpoints that actually matter were never probed. MiniMax has
  `GET /v1/token_plan/remains`; OpenCode Go has `GET /zen/go/v1/usage`, which
  returns **401** for a bad key and **403** for a valid key with no Go plan.
- **`docs/auth-quota-hardening-plan.md` line 79 already listed
  `GET /v1/token_plan/remains` as MiniMax's official Token Plan endpoint.** The
  answer was in this repository. The conclusion was written anyway without
  reading it.

### The rule this session should have applied

Before declaring a provider unsupported, check **in this order**:

1. This repository's own planning docs, not just the vendor's OpenAPI.
2. A working third-party implementation, if one exists. `can1357/oh-my-pi` had
   `packages/ai/src/usage/minimax-code.ts` and `opencode-go.ts` on the shelf the
   whole time.
3. Only then the vendor's live endpoints.

Absence from a published API document is not absence from the API. A working
implementation is the strongest available evidence, and it was free.

### Carry-over risks from the new providers

- **OpenCode Go's usage route is first-party but undocumented**, and oh-my-pi
  records that its shape "changed once on merge day". It is decoded
  all-or-nothing, pinned against recorded fixtures. If the numbers ever look
  wrong, check the vendor **before** trusting the parser.
- **`GET /v1/token_plan/remains` returns HTTP 200 for a rejected credential.**
  The success signal is `base_resp.status_code === 0`. Any future code that
  trusts the HTTP status there will report a pristine quota for a dead key.
- **An `ok` snapshot with an empty quota list wipes the user's cached card.**
  `RefreshService` calls `saveAll(connectionId, snapshot.quotas)`, which
  *replaces* the row set. So "healthy, no usage data" is not a safe fallback for
  a failed or reshaped endpoint — it has to be a non-`ok` snapshot, which takes
  the error path and keeps the last known values. Both new parsers encode this,
  and tests pin it.
- **A model outside the Token Plan is reported by MiniMax as both windows
  "unlimited", zero totals and 100% remaining** — the same shape as a perfect
  quota. It is dropped rather than rendered; see `MiniMax-AI/cli#173`.
- **Both providers are unverified against a live key.** Every test uses recorded
  fixtures. The shapes were ported from a working implementation, which is
  strong evidence but is not the same as a live response.

### Third provider: z.ai, and what the pattern proved

z.ai was added after the two above, and it needed no change to any card, no new
abstraction, and no edit outside `lib/providers/`. That is the PRD's rule for a
new provider ("apenas `ProviderAdapter` + models específicos internos + tests.
Nunca exigir mudança nos cards principais"), and it is now asserted by
`provider_registry_test.dart` so the next provider cannot quietly break it.

What it contributed, beyond one more quota:

- **A second auth scheme.** z.ai sends the raw key in `Authorization` with no
  `Bearer` prefix. `ProviderHttpProbe.getJson` now takes a full header value for
  this. Prefixing would have been rejected, and the failure mode is vicious: a
  credential that is never actually verified, reported to the user as broken.
- **A scale bug the tests caught.** z.ai reports absolute meters *and* a
  server-rounded `percentage`. Deriving `remaining` from that percentage beside
  an absolute `limit` rendered `88/12000`. `limit` and `remaining` must share a
  scale; only a percent-only payload uses 0-100. Two tests failed on the first
  implementation for exactly this.
- **A shared rule, extracted.** Three providers each hand-rolled
  "ProbeResult → snapshot error", which is how a timeout gets reported as a dead
  credential or a 403 revokes a working key. It is now
  `ProviderStatus.fromProbeResult`, and the load-bearing rules stay in one place.

### What is left, and why each item is blocked

Not everything in the PRD's 0.3 roadmap is an adapter-shaped task. The honest
split:

| Provider | Blocker |
|---|---|
| Gemini API / Gemini CLI | Reuses the `v1internal:*` surface Antigravity already consumes, but needs **its own OAuth client** and a `buckets[]` parser. It also obtains higher rate limits by presenting the official Gemini CLI `User-Agent` — a terms-of-service decision for the maintainer, not an implementation detail. **Not decided, therefore not built.** |
| GitHub Copilot | Needs a GitHub *entitlement token*, not an API key, plus Enterprise and billing-API handling. 426 lines in the reference implementation for a reason. |
| Codex, Claude | Each needs its own token exchange with refresh-token rotation and a rotation ledger. |
| OpenAI API, Groq, DeepSeek | No usage provider in the reference implementation. Would require probing for a documented, key-enforcing, non-billable endpoint — the same gate that had to be applied to MiniMax and OpenCode Go. |

None of these is stubbed or faked. The rule is unchanged: a provider enters only
with a real credential gate — a `GET /models`-like route that requires the key
and does not spend quota.

### Third pass: the Reconnect prompt outliving its own failure

Reading further into oh-my-pi — `CredentialBlocks.reconcile` — turned up a second
defect in code this project already had.

`AppState` shows a Reconnect action when `RefreshService` raises
`CredentialDisabledEvent`. That flag was cleared in exactly four places, all of
them explicit user actions: edit, reconnect, delete, and a rollback. **No
successful refresh ever cleared it.** So one transient 401 — a proxy blip, a
provider hiccup, clock skew — left a working key showing a Reconnect prompt for
the rest of the session, while the app refreshed that same key successfully
behind the prompt. The numbers were right and the card was still asking for a
fix that was not needed.

Fixed by raising `CredentialEventCause.recovered` when an escalated credential
next fetches successfully, and having `AppState` remove the prompt on it. Three
details that are easy to get wrong and are each pinned by a test:

- **Reported at most once per escalation.** Otherwise every healthy connection
  emits an event on every refresh cycle and the UI churns forever.
- **A throttled response is not recovery.** It shows the account is rate-limited,
  not that the credential works, so the prompt has to stay up.
- **The escalation set is in memory only.** It is a UI prompt, not a verdict; the
  durable unhealthy signal is the persisted health row, and a prompt that
  outlived a restart would nag about a credential nothing had re-tested.

#### The version of this that was built and thrown away

The first implementation made escalation **two-stage**, copied from oh-my-pi's
suspect/confirmed split: a first 401 would report the error but not raise the
prompt, and only a second consecutive one would.

It broke a real flow. `connections_screen_test.dart` has a test asserting the
Reconnect action appears after a single Antigravity rejection, and it is right
to: **for an OAuth connection there is no "edit the key"** — re-authenticating
in a browser is the only remedy, so the affordance has to appear on the first
failure or the user has nothing to click.

The two things are worth separating, because only one of them was a proven
defect:

- **Missing recovery** — a bug, reproduced, and the fix is right.
- **Too-eager escalation** — a plausible improvement inferred from a system
  built for a different job. oh-my-pi's suspect state exists to decide whether
  to *burn a sibling credential*, not what to show a human.

The second was reverted. Escalation still happens on the first rejection. The
lesson generalises past this function: a failing test is not automatically a
stale test, and "this matches the reference implementation" is not by itself a
reason to change behaviour the reference was never solving.

### Second review of oh-my-pi's auth, and the bug it found in my own code

Re-reading `can1357/oh-my-pi` after the providers landed found a defect **this
project had introduced**, which matters more than any endpoint added.

`MiniMaxUsageResponse` and `ZaiUsageResponse` mapped *every* non-success body
code to `authError` with `ProviderFailureCause.invalidCredential`. A MiniMax
**frequency cap (code 1002) therefore revoked the user's credential** and
prompted a re-login for a key that was working fine.

This is the same class of defect as audit finding C-34 — a refusal that is not a
credential rejection, reported as one — reached through a different door. The
irony is not lost: the code table naming 1002/2045/1041/1039/1008/2056 was
sitting in this repository's own `auth-quota-hardening-plan.md`, and had been
read and then dismissed as irrelevant. It exists precisely to separate "the key
is wrong" from "this account is capped right now", and **not one of the six
codes means the key is wrong.**

What oh-my-pi makes obvious once read, in `error/auth-classify.ts`:
*"Transient 429s stay in the upstream-backoff lane."* A usage limit gets a
temporary block; only an explicit credential rejection marks it suspect. In
`rotation()` the ordering is structural — the usage-limit branch returns before
the revocation branch is ever reached.

The safety detail that decided the design, from `error/rate-limit.ts`:
*"this keeps the exception scoped to text we actually classify, rather than to
any [signal]."* **An unrecognised code or status is transient and never
revokes.** A permissive default costs a cooldown the user did not need; an
aggressive one costs them their configuration.

Adapted as `lib/providers/provider_throttle.dart`: one `ThrottleReason`
taxonomy with the backoff ladder from `rate-limit.ts` — concurrency 5s,
frequency 30s, capacity 45s, 5xx 20s, spent window 30min, spent balance 30min,
denied, invalid, unknown. `ProviderStatus.fromHttpStatus` now delegates to it,
which **removes the duplicate status table** that let C-34 happen in the first
place: one copy classified 403 as an auth error while the other treated it as a
denial. `provider_throttle_test.dart` pins the invariant that makes routing
providers through here safe — `authError` and `revokesCredential` are the same
predicate, because `ProviderStatus.failure` derives `failureCause` from the
*status* and the two outputs must therefore agree.

`rotation`, `affinity`, `pool` and `rank` were **not** ported. They exist to
rotate between sibling credentials without burning a good account on a transient
error. TokenDock shows every account side by side and never makes an inference
call, so there is no sibling to protect; copying the rotation machinery would be
complexity without a problem.

### Two smaller open items

- **Three generated files under `windows/flutter/` are versioned** and are
  rewritten by every build, producing spurious CRLF `M` status. Restored with
  `git checkout --` each time. Offered twice and not taken: `git rm --cached`
  plus an ignore entry. It is a repository-hygiene decision, not a code one.
- **36 pre-existing files remain unformatted** and were deliberately left alone.
  The lint sweep that took `flutter analyze` from 31 diagnostics to zero was
  lint-specific and applied per file, so it did not reformat any of them.
