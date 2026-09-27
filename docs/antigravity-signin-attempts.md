# Antigravity remote sign-in: every attempt, 2026-09-26

Ten live attempts against Google's Cloud Code Assist endpoints, from a Debug
build of TokenDock, all driving the real OAuth flow in a browser. Recorded here
because the pattern matters more than any single failure: **the reported error
was never the actual fault**, and four attempts produced a message that pointed
somewhere other than where the bug was.

Reproduce with `flutter build windows --debug`, run
`build\windows\x64\runner\Debug\tokendock.exe` with stdout redirected, and watch
the `Antigravity:` lines. The logging is behind `kDebugMode` on purpose.

**Current state: the OAuth exchange, the account lookup and the Cloud Code
provisioning call all succeed. The attempt fails immediately after, and the
failure is not yet attributed.** See attempt 10.

## The one fact that was never in doubt

The browser round trip always succeeded. `authorization code received from the
loopback listener` appeared in every attempt that got that far. Nothing in this
document is about Google authentication failing.

## The pattern worth more than any individual fix

Three of the nine attempts failed *because of a fix applied in an earlier one*:

| Attempt | The fix | The 400 it caused |
|---|---|---|
| 3 | three-field metadata in the request body | the body declared the caller to be the Gemini CLI |
| 7 | `userIdentifier` in the body | a field the endpoint does not accept |
| 8 | `Client-Metadata` and `X-Goog-Api-Client` headers | headers the endpoint does not accept |

In all three the reference implementation was to hand and had been read only
partially. Every one produced `400 INVALID_ARGUMENT`, which names a symptom and
never a cause.

The rule that came out of it, and is now written into the code: **for an
endpoint that answers `INVALID_ARGUMENT`, copy the exact request shape from an
implementation that works — field by field — and assert the exact set, not the
presence of the fields you expect.** `cloud_code_headers_test.dart` asserts
`headers.keys == {Authorization, Accept, Content-Type, User-Agent}` and
`body.keys == ['metadata']`, so an extra field fails even when the four correct
ones still pass.

A second pattern, twice: **a fixture that invents the field the code reads hides
the bug.** The account identity was `email|accountId` for four attempts. Google
sends no account id anywhere on this path; the field existed only in
TokenDock's own test fixtures. The guard therefore passed in tests and failed on
every live attempt. An invented fixture field converts a live bug into an
invisible one.

## Attempts

### 1 — `invalid_scope`, rejected at the authorization request

**Seen:** `Error 400: invalid_scope [invalid=[cloud-platform, userinfo.email,
userinfo.profile]]` on a Google error page. The app showed "Unable to sign in."

**Actually wrong — four defects, one visible:**

1. `clientId` was `681255809395-…`, the **Gemini CLI** client, not Antigravity's
   (`1071006060591-…`). An OAuth client may only use the scopes registered to
   it, which is why the error *lists the scopes* and reads as a scope problem.
2. Two of the five registered scopes were missing: `cclog` and
   `experimentsandconfigs`.
3. Scopes were sent in short form. Only the registered full-URL form matches.
4. `prompt=consent` was absent, so Google reused a grant and issued no refresh
   token — a failure that surfaces on the *next* login as "OAuth refresh token
   missing", pointing at the token exchange rather than the request that caused
   it.

### 2 — silent, no log line at all

**Actually wrong:** the sign-in path caught every exception and turned it into
one fixed user-facing string. Correct for the user — an exception object can
carry SQL, table names and credential-shaped text — and useless for whoever has
to fix it. There was no `debugPrint` anywhere in the OAuth path, so a failure
was indistinguishable from a failure of a different kind.

**Attempts 2, 3, 5, 6, 7, 8 and 9 were all diagnosed by reading a browser page
or by guessing, because the app said nothing.**

### 3 — `400 INVALID_ARGUMENT` from `loadCodeAssist`

**Actually wrong:** the client metadata was inverted.

```dart
'pluginType': 'ANTIGRAVITY',   // wrong field
'ideType': 'IDE_UNSPECIFIED',  // and not accepted by this endpoint
```

`IDE_UNSPECIFIED` is the *Gemini CLI* value; the two were on the wrong fields.
`platform` was absent. Three headers both early references sent were missing.

### 4 — silent, stopped dead after the authorization code

**Actually wrong:** `loadCodeAssist` returns `cloudaicompanionProject` and
`currentTier` at the **top level** — there is no `response` envelope. TokenDock
required `result['response'] is Map` and threw `AntigravitySchemaChanged`
otherwise, *and that throw had no log line*.

`_project` and `_tier` were wrong the same way, and `_project` accepted only the
string form of the project id, never `cloudaicompanionProject.id`. Three
independent readers, one shared wrong assumption, invisible in both the UI and
the log.

### 5 — `400 INVALID_ARGUMENT` again, caused by the attempt-3 fix

The attempt-3 correction put the full three-field map in the request **body**.
`pluginType: GEMINI` in the body is the marker that declares the caller to be
the **Gemini CLI**. A test written during attempt 3 asserted the three-field body
and had to be corrected with it.

### 6 — a regression from the attempt-4 fix

Attempt 4 fixed the *reader* and left the *check* wrong, so a working 200 was
treated as a schema change. The acceptance check became "carries provisioning
data" rather than "is enveloped", with a test asserting a 200 carrying neither a
project nor a tier is still rejected.

### 7 — the 400 is gone; a different, correctly-named failure

```
token exchange succeeded
loadCodeAssist returned provisioning data
provisioning keys: allowedTiers,cloudaicompanionProject,currentTier,gcpManaged,paidTier,upgradeSubscriptionUri
the token response carried no account identity
```

**Actually wrong:** the identity guard built `email|accountId` from the **token
response**, reading `accountEmail`/`accountId`. Google's token endpoint returns
only `access_token`, `refresh_token` and `expires_in`.

### 8 — `400 INVALID_ARGUMENT` returns, from the attempt-7 work

The account email was sourced from `oauth2/v2/userinfo` — correct, and the
`CLIProxyAPI` form. But the request also carried two things it should not:

- **`userIdentifier` in the body.** `CLIProxyAPI` builds the body as
  `{metadata: ...}` and nothing else. The account is resolved from the bearer
  token.
- **`Client-Metadata` and `X-Goog-Api-Client` headers.** `CLIProxyAPI`,
  `oh-my-pi` and `9router` send neither on this call. Only `cortexkit` sends
  `Client-Metadata`, and that is the one implementation that does not work
  against a live account without its own hardcoded project id — so it is not
  evidence the header is accepted.

The cross-reference had already flagged this combination as "a fingerprint
surface with no corroboration, and not proven good". It was worse than
unproven: it was the thing the endpoint rejected.

### 9 — the 400 is gone, and a false premise is exposed

```
userinfo returned the account email
loadCodeAssist returned provisioning data
no account identity available from userinfo or provisioning
```

**Actually wrong:** the guard composed `email|accountId` from the userinfo email
*and* an account id read from the provisioning body. **The provisioning body
carries no account fields.** Three independent confirmations:

- `oh-my-pi` declares the `loadCodeAssist` response schema as exactly
  `currentTier`, `paidTier`, `allowedTiers`, `ineligibleTiers` and
  `cloudaicompanionProject`. The file never mentions an account identity.
- `CLIProxyAPI`'s `userInfo` struct has one field: `email`.
- The log line above is the real response, and there is no `accountEmail` and no
  `accountId` in it.

The `accountId` existed only in TokenDock's own fixtures. The identity is now the
email, which is what all six implementations use.

**What is lost, deliberately:** the cross-check that bound a stored credential to
one account. It was the only defence against a token for one account reading
another's quota, and that failure mode is plausible output rather than an error.
The maintainer chose the working login over the check. Reinstating it needs a
second independent source, and the only candidate is the `id_token`, which
requires adding `openid` to the five registered scopes — and a wrong scope set is
what caused attempt 1.

### 10 — everything upstream of the failure now succeeds

```
sign-in started, waiting for the browser round trip
authorization code received from the loopback listener
token exchange succeeded; asking Cloud Code to provision
userinfo returned the account email
loadCodeAssist returned provisioning data
```

No error line. The user-facing message is the generic "Unable to sign in", so the
failure is between the sixth line and the seventh that should have followed it —
in the identity resolution, the account guard, the project read, or the tier
read. **Not yet attributed.** Two changes were made to find it, and neither has
been exercised against a live account:

- A log line at each of those four steps, so the next attempt names the step
  rather than stopping one line short of it.
- `userSafeErrorMessage` no longer returns the generic fallback silently. The
  fallback arm was the reason nine attempts were undiagnosable from the app: an
  unrecognised failure produced calm, unhelpful copy and *nothing else*. It now
  prints the exception **type** — a Dart class name, which cannot carry a
  secret, a path or a credential. The user-facing copy is unchanged.

**The account is a paid one** (`paidTier` is present in the response), so the
free-tier ineligibility path is not in play.

## Sources

Two independent working implementations, and both were needed — each caught
something the other did not:

- `cortexkit/antigravity-auth` — `packages/core/src/antigravity/oauth.ts`,
  `fingerprint.ts`, `constants.ts`. Caught: the one-field body metadata, the
  harness `User-Agent`, the bare provisioning response, both project-id shapes,
  the daily endpoint order, the separate userinfo call.
- `CLIProxyAPI` — `internal/auth/antigravity/auth.go`,
  `internal/runtime/executor/antigravity_executor_credits.go`. 53k stars, the most
  widely deployed. Caught: the four-header set, the absence of `userIdentifier`,
  the `oauth2/v2` form, and that the identity is the email alone.
- `wiseai/picoclaw` — `docs/security/ANTIGRAVITY_AUTH.md`. Caught: the inverted
  metadata; independently confirms the five scopes and the client id.
- `opencode-antigravity-auth` — `docs/ANTIGRAVITY_API_SPEC.md`. Confirms the five
  scopes and the required headers.
- `decolua/9router` — `src/lib/oauth/services/antigravity.js`, and issue #1226
  on account-blocking fingerprints. Its numeric-enum metadata is a minority
  position and it reports its own bug unpatched.
- `can1357/oh-my-pi` — `packages/ai/src/registry/oauth/google-antigravity.ts`.
  The most defensible of the six: a frozen metadata constant, a declared response
  schema, tests asserting exact request bodies, and a `User-Agent` version
  discovered from Google's own update manifest rather than invented.

## What is verified, and what is not

**Verified against live Google:** the OAuth authorization and token exchange, the
`userinfo` account lookup, and `loadCodeAssist` returning 200 with the account's
real provisioning data.

**Not verified:** a complete sign-in. No fixture in this repository is a live
Google response, and no automated test contacts Google. Every shape above was
read out of a real Debug log or a real browser page, not out of a test.

## Two decisions deliberately not copied

**The hardcoded fallback project id.** `cortexkit` falls back to
`rising-fact-p41fc` for accounts the endpoint provisions no project for. That
project belongs to the operator of that client; using it in a distributed app
would point a user's requests and their quota reporting at a Google Cloud
project that is not theirs. A projectless account is reported as needing
onboarding instead. The id is recorded as `referenceFallbackProjectId`.

**The Electron desktop `User-Agent`.** `getAntigravityHeaders()` in the
reference carries a full Chrome/Electron string. That is the desktop IDE's
identity, and TokenDock is neither Chrome nor Electron. Only the harness form is
sent, and a test asserts the string contains neither.
