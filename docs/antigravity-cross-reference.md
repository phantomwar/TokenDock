# Cross-reference: how oh-my-pi and 9router handle the Antigravity sign-in

Four implementations read side by side, because each got a piece of the flow
wrong or right that the others do not. Sources are pinned at the end.

| | TokenDock | CLIProxyAPI | oh-my-pi | 9router | cortexkit |
|---|---|---|---|---|---|
| stars | — | 53k | 33k | 30k | — |
| language | Dart | Go | TypeScript | JavaScript | TypeScript |
| body metadata | `{ideType: "ANTIGRAVITY"}` | `{ideType: "ANTIGRAVITY"}` | `{ideType: "ANTIGRAVITY"}` | `{ideType: 9, platform: N, pluginType: 2}` | `{ideType: "ANTIGRAVITY"}` |
| body `userIdentifier` | **not sent** | **not sent** | not sent | not sent | not sent |
| `Client-Metadata` hdr | **not sent** | **not sent** | **not sent** | **not sent** | 3 string fields |
| `X-Goog-Api-Client` | **not sent** | **not sent** | **not sent** | **not sent** | not sent |
| `Accept` on Cloud Code | `*/*` | `*/*` | not sent | not sent | `gzip` |
| `User-Agent` | `antigravity/cli/1.1.24 (aidev_client; os_type=windows; arch=amd64; auth_method=consumer)` | `antigravity/hub/{v} {os}/{arch}` + `google-api-nodejs-client/10.3.0` on onboard | `antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)` | `antigravity/1.107.0` | `antigravity/cli/1.1.24 (…)` |
| UA version source | pinned | **discovered from Google's update manifest** | **discovered from Google's update manifest** | pinned | pinned |
| endpoint | daily, then prod | prod, configurable per account | **daily only** | config value | daily, then prod |
| response envelope | accepted either | flat | flat | flat | flat |
| project shapes | string + `.id` | string + `.id` | string only | string + `.id` | string + `.id` |
| account email | `oauth2/**v2**/userinfo` | `oauth2/**v2**/userinfo` | **never fetched** | `oauth2/**v1**/userinfo` | `oauth2/**v1**/userinfo` |
| account identity | **email only** | email only | **none** | email, as a label | email, as a label |
| cross-check identity | **none** (given up, see below) | **none** | **none** | **none** | **none** |
| `onboardUser` tier | **not sent** | `tier_id` (snake_case) | `tierId: "free-tier"` | `tierId` | not sent |
| `onboardUser` polling | **none** | 5 × 2s on `done` | `GET /v1internal/{name}` every 1s, 30s cap | 10 × 5s | none |
| `onboardUser` metadata | 1 field | **3 fields, snake_case**: `ide_type`, `ide_version`, `ide_name` | 1 field | 3 numeric fields | 1 field |
| free-tier eligibility | not checked | not checked | `ineligibleTiers` → reason + `validationUrl` | not checked | not checked |
| `paidTier` read | **no** | **yes** | **yes** (the paid marker) | no | no |
| fallback project | none (deliberate) | none | none | none | `rising-fact-p41fc` |

`CLIProxyAPI` was added after the first version of this table was written, and it
changed the answer on two rows: the `Accept` header, and the fact that **none** of
the five send `Client-Metadata` or `X-Goog-Api-Client` for `loadCodeAssist` —
`cortexkit` alone sends the former, and is the one implementation that does not
work against a live account without its own project id.

`onboardUser`'s metadata differs again between implementations, and the three
observed shapes are incompatible with each other. That is recorded as open, not
resolved: no live account has reached `onboardUser` in this project's testing,
because every account tried already carries a tier.

## The three findings that matter

### 1. TokenDock's identity guard is the only one of the four — and it is why sign-in fails

**Three of four implementations never read an account identity at all.**

`oh-my-pi`'s `googleAntigravityProjectHook` takes `credentials.access`, calls
`discoverProject`, and returns `{...credentials, projectId}`. There is no
`accountEmail`, no `accountId`, no comparison, no guard anywhere in
`registry/oauth/google-antigravity.ts`. `9router` and `cortexkit` call
`oauth2/v1/userinfo` and read `email` — for the account *label* only. None of
them cross-checks the identity returned by Cloud Code against the identity that
authorised the token.

TokenDock builds `email|accountId` from the **token response** and requires a
matching identity in the provisioning body. Google's token endpoint returns
`access_token`, `refresh_token` and `expires_in` — **no account fields** — so
`identityOf` returns null and sign-in throws.

**That is attempt 7, exactly.** The guard is not a bug; it is reading a field
that is not there. Three working implementations confirm the field does not
exist in that response.

The guard's *purpose* is still sound and worth keeping: it is the only defence
against a token from one account being used to read another's quota, which fails
as plausible output rather than as an error. The defect is the source, not the
check.

### 2. The identity has to be composed from two responses, and no reference composes it

`userinfo` returns `email` and no `accountId` (`9router`,
`cortexkit`). The Cloud Code provisioning body returns `accountEmail` **and**
`accountId` — the account's own keys, visible in attempt 7's log as part of
every response. So the correct identity is `email` from `userinfo` and
`accountId` from provisioning, compared against the same two fields in the
provisioning body.

No reference does this, because none of them needs to. This is TokenDock-specific
work, and it is the one part of the flow where there is no working implementation
to copy — which is why it is the open question in
`antigravity-signin-attempts.md` rather than a known fix.

Two ways it can go, and they are not equivalent:

- **Cross-check, keep the guard:** `userinfo.email` versus the provisioning
  body's `accountEmail`, and refuse a mismatch. Keeps the defence, needs the extra
  call, and a blocked `userinfo` would fail sign-in.
- **Label only, drop the guard:** `cortexkit`'s choice — a non-OK `userinfo`
  yields `{}` and sign-in continues. Simpler and matches every reference, but
  removes the only account-binding check in the ecosystem.

`cortexkit` already takes the second option by default, so following it is not
unprecedented — it is the norm.

### 3. Nobody sends `Client-Metadata` or `X-Goog-Api-Client` on `loadCodeAssist`

This row has changed since the first version of this document, and it changed
because `CLIProxyAPI` was read afterwards.

`CLIProxyAPI` sets exactly four headers on a Cloud Code call:

```go
httpReq.Header.Set("Authorization", "Bearer "+token)
httpReq.Header.Set("Accept", "*/*")
httpReq.Header.Set("Content-Type", "application/json")
httpReq.Header.Set("User-Agent", userAgent)
```

`oh-my-pi` sends three of those four and no extras. `9router` sends two.
`cortexkit` sends `Client-Metadata` — and is the one implementation that does
not work against a live account without its own hardcoded project id, so it is
not evidence the header is accepted.

TokenDock was sending six, including both extra headers, and the endpoint answered
`400 INVALID_ARGUMENT` on the sixth and eighth live attempts. The first version
of this table called that combination "a fingerprint surface with no
corroboration". It was worse than unproven: it was the thing the endpoint
rejected.

The 9router account-blocking issue (#1226) is about a *different* fingerprint
problem — inconsistent identity between the token phase and the API phase — and
does not apply to TokenDock, whose identity is now consistent across every call.
Its numeric-enum position remains a minority view with an unpatched bug report
behind it, and is recorded as unresolved rather than settled.

### 4. The account id does not exist, and four attempts assumed it did

This is the most consequential row, and it was invisible until a live response
was logged.

The identity was `email|accountId` for four attempts. The email comes from
`userinfo`; the account id was read from the provisioning body. **The
provisioning body carries no account fields.**

- `oh-my-pi` declares the response schema as exactly `currentTier`, `paidTier`,
  `allowedTiers`, `ineligibleTiers`, `cloudaicompanionProject`. The file never
  mentions an account identity at all.
- `CLIProxyAPI`'s `userInfo` struct has one field, `email`.
- The ninth live attempt logged the real keys: `allowedTiers,
  cloudaicompanionProject, currentTier, gcpManaged, paidTier,
  upgradeSubscriptionUri`. No `accountEmail`, no `accountId`.

The `accountId` existed only in TokenDock's own test fixtures. A fixture that
invents the field the code reads is not a neutral convenience — it converts a
live bug into an invisible one, and four attempts passed in CI because of it.

**What was given up.** The cross-check that bound a stored credential to one
account is gone. It was the only defence in the entire ecosystem against a token
for one account reading another's quota, and that failure mode is plausible
output rather than an error. All five references accept the same loss, because
none of them ever had the check.

**How it could come back.** The `id_token` is a JWT whose payload carries the
subject and the email — a genuinely independent second source. It requires adding
`openid` to the five registered scopes, and a wrong scope set is what caused
attempt 1. That is a maintainer's trade, not a default.

## What TokenDock is missing that `oh-my-pi` and `CLIProxyAPI` have

Not blocking sign-in, but real gaps found by reading them:

- **`onboardUser` is a long-running operation, and the three implementations
  disagree about how to call it.** `oh-my-pi` sends `tierId: "free-tier"`, then
  polls `GET /v1internal/{name}` every second for 30s until `done: true`.
  `CLIProxyAPI` sends **`tier_id`** — snake_case, which is not the same field
  name — and polls the same endpoint 5 times at 2s. TokenDock sends **no tier
  and never polls**, so it reads an unfinished operation as a finished one.

  The metadata differs again: `CLIProxyAPI` sends three snake_case fields
  (`ide_type`, `ide_version`, `ide_name`) where the others send one. Three
  incompatible shapes, and no live account has reached this path in this
  project's testing because every account tried already carries a tier. Recorded
  as open rather than guessed at.

- **`paidTier` is the real paid-account marker and TokenDock ignores it.**
  `oh-my-pi` tests `hasMessageField(payload, "paidTier")`; `CLIProxyAPI` reads
  `paidTier.id` and `paidTier.availableCredits` for its balance report. The
  account used in testing **has** a `paidTier`, so the tier TokenDock is about to
  report — from `currentTier` alone — is probably wrong.

- **Free-tier eligibility is a first-class check.** `oh-my-pi` inspects
  `ineligibleTiers` and surfaces `reasonMessage` plus a `validationUrl` the user
  can act on. TokenDock would report a generic failure for an account that is
  simply not eligible.

- **The second `loadCodeAssist`.** When `paidTier` is absent but a project
  exists, `oh-my-pi` re-calls `loadCodeAssist` with the project. TokenDock calls
  it once.

- **The `User-Agent` version can be discovered rather than pinned.** Both
  `oh-my-pi` and `CLIProxyAPI` fetch it from Google's own update manifest
  (`antigravity-hub-auto-updater-974169037036.us-central1.run.app`). TokenDock,
  `cortexkit` and `9router` pin a constant, which goes stale silently. A pinned
  version that the server stops accepting would be a `400` with no explanation,
  which is precisely the failure mode the other two are defending against.

## Correlation across all five

**Universal agreement, five for five:**

- the Antigravity client id `1071006060591-…` and its secret
- the five scopes, full-URL form
- `prompt=consent` for a refresh token
- the `antigravity` family of `User-Agent`
- `ideType` must be `ANTIGRAVITY` — the Gemini CLI's `IDE_UNSPECIFIED` is wrong
  here, which is what attempt 1's `invalid_scope` was really about
- **no `userIdentifier` on `loadCodeAssist`** — the account comes from the bearer
  token, and TokenDock learned that by having the endpoint reject it
- **the email alone is the identity**, and the account id is nowhere to be found

**Universal disagreement:**

- numeric vs string enums (1 vs 4)
- `User-Agent` version: `2.8.0` / `1.107.0` / `1.1.24` / `1.1.24` / live
- `antigravity/cli` vs `antigravity/hub` vs bare `antigravity/1.107.0`
- daily-only vs daily-then-prod vs prod-only
- `tierId` vs `tier_id` vs no tier, and one-field vs three-field onboard metadata

**Nobody implements:**

- an account identity cross-check. All five accept the same loss, because none
  of them ever had the check — TokenDock is the only one that had it and gave it
  up deliberately, having proved the second source does not exist.

## What this means for the next attempt

`CLIProxyAPI` is the most defensible of the five on the evidence: 53k stars, the
four-header set confirmed by a second call site, the identity reduced to what
actually exists, and a `User-Agent` version it does not have to guess. `oh-my-pi`
is the most rigorous in its testing — frozen constants, a declared response
schema, exact request-body assertions.

The remaining work, in order:

1. **Attribute the attempt-10 failure.** Every step between
   `loadCodeAssist returned provisioning data` and the next log line is now
   individually named, and an unrecognised error type prints its name. This is a
   run, not a design question.
2. **Read `paidTier`**, and surface free-tier ineligibility with its
   `validationUrl`. The account in testing is paid, so the tier about to be
   reported is likely wrong.
3. **`onboardUser`: tier and polling.** The three field names disagree, so this
   needs a decision rather than a copy — and it is unreachable for any account
   that already has a tier.
4. **Discover the `User-Agent` version** from Google's update manifest, as the two
   strongest implementations do.

Only (1) blocks sign-in. The rest are correctness issues that would surface as
wrong quota data afterwards.

## Sources

- `router-for-me/CLIProxyAPI` — `internal/auth/antigravity/auth.go`,
  `internal/auth/antigravity/constants.go`,
  `internal/runtime/executor/antigravity_executor_credits.go`,
  `internal/misc/antigravity_version.go`
- `can1357/oh-my-pi` — `packages/ai/src/registry/oauth/google-antigravity.ts`,
  `packages/catalog/src/wire/gemini-headers.ts`,
  `packages/ai/test/google-antigravity-oauth.test.ts`
- `decolua/9router` — `src/lib/oauth/constants/oauth.js`,
  `src/lib/oauth/services/antigravity.js`, issue #1226
- `cortexkit/antigravity-auth` — `packages/core/src/antigravity/oauth.ts`,
  `fingerprint.ts`, `constants.ts`
- `wiseai/picoclaw` — `docs/security/ANTIGRAVITY_AUTH.md`
- `opencode-antigravity-auth` — `docs/ANTIGRAVITY_API_SPEC.md`
- Live Debug logs from this project, 2026-09-26, in
  `docs/antigravity-signin-attempts.md`
