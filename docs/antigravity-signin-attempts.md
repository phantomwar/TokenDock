# Antigravity remote sign-in: every attempt, 2026-09-26

Seven live attempts against Google's Cloud Code Assist endpoints, from a Debug
build of TokenDock, all driving the real OAuth flow in a browser. Recorded here
because the pattern matters more than any single failure: **the reported error
was never the actual fault**, and four of the seven attempts produced a message
that pointed somewhere other than where the bug was.

Reproduce with `flutter build windows --debug`, run
`build\windows\x64\runner\Debug\tokendock.exe` with stdout redirected, and watch
the `Antigravity:` lines. The logging is behind `kDebugMode` on purpose.

## The one fact that was never in doubt

The browser round trip always succeeded. `authorization code received from the
loopback listener` appeared in every attempt that got that far. Nothing in this
document is about Google authentication failing.

## Attempts

### 1 — `invalid_scope`, rejected at the authorization request

**What the user saw:** `Error 400: invalid_scope [invalid=[cloud-platform,
userinfo.email, userinfo.profile]]` on a Google error page. The app showed
"Unable to sign in. Please try again."

**What was actually wrong — four separate defects, one visible:**

1. `clientId` was `681255809395-…`, which is the **Gemini CLI** client, not
   Antigravity's (`1071006060591-…`). An OAuth client may only use the scopes
   registered to it, which is why the error *lists the scopes* and reads as a
   scope problem.
2. Two of the five registered scopes were missing: `cclog` and
   `experimentsandconfigs`.
3. Scopes were sent in short form. Only the registered full-URL form matches.
4. `prompt=consent` was absent, so Google reused a grant and issued no refresh
   token — a failure that surfaces on the *next* login as "OAuth refresh token
   missing", pointing at the token exchange rather than at the request that
   caused it.

**The lesson:** the error text named the symptom three times over and the cause
zero times. Nothing in the app could have told us this; the diagnosis came from
a browser error page.

### 2 — silent, no log line at all

**What the user saw:** the same "Unable to sign in."

**What was actually wrong:** the sign-in path caught every exception and turned
it into one fixed, deliberately vague user-facing string. Correct for the user
— an exception object can carry SQL, table names and credential-shaped text —
and useless for whoever has to fix it. There was no `debugPrint` anywhere in the
OAuth path, so a failure was indistinguishable from a failure of a different
kind. **Four consecutive attempts (2, 3, 5, 6) were diagnosed by reading a
browser page or by guessing, because the app said nothing.**

### 3 — `400 INVALID_ARGUMENT` from `loadCodeAssist`

**Logged:** `loadCodeAssist rejected HTTP 400 (INVALID_ARGUMENT)`.

**What was actually wrong — the client metadata was inverted:**

```dart
'pluginType': 'ANTIGRAVITY',   // wrong field
'ideType': 'IDE_UNSPECIFIED',  // and not accepted by this endpoint
```

`ideType: IDE_UNSPECIFIED` is the **Gemini CLI** value; the two were on the wrong
fields. `platform` was absent. Three headers both reference implementations send
were missing: `User-Agent`, `X-Goog-Api-Client`, `Client-Metadata`.

Nothing in the response says "you swapped two enum values". It says
`INVALID_ARGUMENT`.

### 4 — silent, stopped dead after the authorization code

**Logged:** nothing after `authorization code received`.

**What was actually wrong:** `loadCodeAssist` returns `cloudaicompanionProject`
and `currentTier` at the **top level** — there is no `response` envelope.
TokenDock required `result['response'] is Map` and threw
`AntigravitySchemaChanged` otherwise, and *that throw had no log line*.

So `_project` and `_tier` were also wrong: both read only the enveloped shape,
and `_project` accepted only the string form of the project id, never
`cloudaicompanionProject.id`. Three independent readers, one shared wrong
assumption, and the failure was invisible in both the UI and the log.

### 5 — `400 INVALID_ARGUMENT` again, after the metadata was fixed

**What was actually wrong — and it was the previous fix that caused it.** The
correction in attempt 3 put the full three-field map in the request **body**.
`cortexkit/antigravity-auth`, verified against live `agy` CLI 1.1.24 traffic,
returns exactly one field from `buildAntigravityLoadCodeAssistMetadata`:

```ts
return { ideType: 'ANTIGRAVITY' }
```

`pluginType: GEMINI` in the body is the marker that declares the caller to be
the **Gemini CLI**. `INVALID_ARGUMENT` was the endpoint refusing a body naming a
different client. The three-field map is correct in the `Client-Metadata`
**header** and wrong in the request **body**; the reference sends exactly that
pair.

A test written during attempt 3 asserted the three-field body and had to be
corrected — it encoded the same misreading.

### 6 — a regression from the attempt-4 fix

`AntigravitySchemaChanged` was being thrown for a body the endpoint had actually
accepted, because the acceptance check was `body['response'] is Map`. Attempt 4
fixed the *reader* and left the *check* wrong, so a working 200 was treated as
a schema change. Fixed by checking for provisioning data rather than an
envelope — with a test asserting that a 200 carrying neither a project nor a
tier is still rejected, so the fix could not turn every 200 into a success.

### 7 — the 400 is gone; a different, correctly-named failure remains

**Logged:**

```
Antigravity: token exchange succeeded; asking Cloud Code to provision
Antigravity: loadCodeAssist returned provisioning data
Antigravity: provisioning keys: allowedTiers,cloudaicompanionProject,currentTier,gcpManaged,paidTier,upgradeSubscriptionUri
Antigravity: the token response carried no account identity
```

**`loadCodeAssist` now returns 200 with real data.** The key list is the
account's own: `allowedTiers`, `cloudaicompanionProject`, `currentTier`,
`gcpManaged`, `paidTier`, `upgradeSubscriptionUri`. Progress is real — attempt 3
never got this far.

**What is actually wrong:** the identity guard builds `email|accountId` from the
**token response**, reading `accountEmail`/`email` and `accountId`/`account_id`/
`account`. Google's token endpoint returns only `access_token`,
`refresh_token` and `expires_in` — **no account fields at all**, so
`identityOf` returns null and sign-in throws `OAuth account identity missing`.

The provisioning body *does* carry `accountEmail` and `accountId` (they arrived
in the fixture and in every Code Assist response seen), so the identity is
available — just not from where this code looks for it.

## The fix identified but not yet applied

`cortexkit/antigravity-auth` fetches the account email from a **separate
endpoint**, immediately after the token exchange:

```ts
const userInfoResponse = await fetchWithActiveTimeout(
  'https://www.googleapis.com/oauth2/v1/userinfo?alt=json',
  {
    headers: {
      Authorization: `Bearer ${tokenPayload.access_token}`,
      'User-Agent': GEMINI_CLI_HEADERS['User-Agent'],
    },
  },
)
const userInfo = userInfoResponse.ok ? await userInfoResponse.json() : {}
```

TokenDock never calls it. The `userinfo.email` scope is already granted, so the
call needs no new scope and no new credential.

Note the reference treats a non-OK response as `{}` rather than a failure, so a
blocked userinfo endpoint degrades the label rather than blocking sign-in.
Whether to match that or to treat a missing identity as fatal is a decision, and
it interacts with the guard below.

## The guard, and why it must not be weakened

`AntigravitySelectedAccountGuard` compares the identity from the token response
against the identity in the provisioning response, and refuses a mismatch. That
check exists because a shared or wrong account binding would attribute one
account's quota to another — the failure mode is *plausible output*, not an
error.

Fixing attempt 7 by loosening the guard to "accept whatever the provisioning
response says" would remove the only defence against that. The guard has to keep
comparing two independently-sourced identities, so the fix is to **source the
identity correctly** (userinfo, or the provisioning body) rather than to compare
less.

An open question: `userinfo` returns `email` but no `accountId`, so
`email|accountId` cannot be built from it alone. Building `email|email` or
`email|` would be fabricating a value the guard then compares against. The
account id has to come from the provisioning response, and the composition has
to be pinned by a test rather than chosen at the call site.

## Sources

Two independent working implementations, and both were needed — each caught
something the other did not:

- `cortexkit/antigravity-auth` — `packages/core/src/antigravity/oauth.ts`,
  `fingerprint.ts`, `constants.ts`. Verified against live `agy` CLI 1.1.24
  traffic. Caught: the one-field body metadata, the harness `User-Agent`, the
  bare (un-enveloped) provisioning response, both project-id shapes, the daily
  endpoint order, the separate userinfo call, and the fallback project id.
- `wiseai/picoclaw` — `docs/security/ANTIGRAVITY_AUTH.md`. Caught: the inverted
  metadata and the `X-Goog-Api-Client` header, and independently confirms the
  five scopes and the client id.
- `opencode-antigravity-auth` — `docs/ANTIGRAVITY_API_SPEC.md`. Confirms the
  five scopes, the required headers, and the three-field `Client-Metadata`.

## What is verified, and what is not

**Verified against live Google:** the OAuth authorization and token exchange,
and `loadCodeAssist` returning 200 with the account's real provisioning data.

**Not verified:** a complete sign-in. No test fixture anywhere in this
repository is a live Google response, and no automated test contacts Google.
Every shape above was read out of a real Debug log or a real browser page, not
out of a test.

**Not applied:** the userinfo call. It is the identified next step and is
deliberately left unapplied pending review, since the interaction with the
identity guard is the open question above and the fix is not a one-liner.

## Two decisions deliberately not copied

**The hardcoded fallback project id.** `cortexkit` falls back to
`rising-fact-p41fc` for accounts the endpoint provisions no project for. That
project belongs to the operator of that client. Using it in a distributed app
would point a user's requests and their quota reporting at a Google Cloud
project that is not theirs. A projectless account is reported as needing
onboarding instead. The id is recorded as
`referenceFallbackProjectId` so the decision stays checkable against the
reference rather than remembered.

**The Electron desktop `User-Agent`.** `getAntigravityHeaders()` in the
reference carries a full Chrome/Electron string. That is the desktop IDE's
identity; TokenDock is neither Chrome nor Electron, and the reference itself
uses the harness CLI form on the `loadCodeAssist` path. Only the harness form is
sent.
