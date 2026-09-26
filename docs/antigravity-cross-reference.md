# Cross-reference: how oh-my-pi and 9router handle the Antigravity sign-in

Four implementations read side by side, because each got a piece of the flow
wrong or right that the others do not. Sources are pinned at the end.

| | TokenDock | oh-my-pi | 9router | cortexkit |
|---|---|---|---|---|
| language | Dart | TypeScript | JavaScript | TypeScript |
| body metadata | `{ideType: "ANTIGRAVITY"}` | `{ideType: "ANTIGRAVITY"}` | `{ideType: 9, platform: N, pluginType: 2}` | `{ideType: "ANTIGRAVITY"}` |
| `Client-Metadata` header | 3 string fields | **not sent** | **not sent** | 3 string fields |
| `X-Goog-Api-Client` | sent | **not sent** | **not sent** | not sent |
| `User-Agent` | `antigravity/cli/1.1.24 (aidev_client; os_type=windows; arch=amd64; auth_method=consumer)` | `antigravity/hub/2.8.0 (aidev_client; os_type=darwin; arch=arm64; cl=963137146)` | `antigravity/1.107.0` | `antigravity/cli/1.1.24 (…)` |
| endpoint | daily, then prod | **daily only** | config value | daily, then prod |
| response envelope | accepted either | flat (`cloudaicompanionProject` at top level) | flat | flat |
| project shapes | string + `.id` | string only | string + `.id` | string + `.id` |
| account identity | `email\|accountId` **from the token response** | **never read** | `userinfo` endpoint, `email` only | `userinfo` endpoint, `email` only |
| cross-check identity | yes, guard | **none** | **none** | **none** |
| `onboardUser` | no `tierId`, no polling | `tierId: "free-tier"`, polls `/v1internal/{name}` | `tierId`, polls 10×5s | no `tierId` |
| free-tier eligibility | not checked | `ineligibleTiers` → reason + `validationUrl` | not checked | not checked |
| fallback project | none (deliberate) | none | none | `rising-fact-p41fc` |

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

### 3. String vs numeric metadata enums — and a documented account-blocking risk

`9router` uses **numeric** enums: `ideType: 9, pluginType: 2`, with
`platform` as `5` on win32, `1`/`2` on darwin by arch, `3`/`4` on linux by arch.
`oh-my-pi` and `cortexkit` use the **strings** `"ANTIGRAVITY"`.

`9router` issue #1226 is titled *"Antigravity OAuth metadata mismatch causes
Google account blocking"*. Its claim: inconsistent fingerprints between the
token phase and the API phase let Google correlate and flag accounts, and the
fix is to use the numeric enums everywhere. It reports the bug as **unpatched**
in v0.4.52 and originally found in March 2026, with a related issue auto-closed
for inactivity.

**TokenDock's situation is the inverse of the one described.** The three-field
string map is consistent: the same values go in the `Client-Metadata` header on
every Cloud Code call, and the body carries only `ideType: ANTIGRAVITY` — the
`oh-my-pi` and `cortexkit` form, adopted after attempt 5. There is no mismatch
between phases to correlate.

Two things remain true regardless:

- **The numeric/strings question is unresolved across the ecosystem.** Three
  implementations use strings, one uses numbers, and the one that argues for
  numbers has an open bug report about it. Nobody has settled this with evidence.
- **TokenDock sends a third header combination** that no reference sends:
  `Client-Metadata` *and* `X-Goog-Api-Client` together. `cortexkit` sends both;
  `oh-my-pi` and `9router` send neither. This is a fingerprint surface with no
  corroboration, and the 400 in attempts 3–6 came from the body/header
  interaction, so the combination is not proven good — only untested against a
  working account.

That last point is the uncomfortable one. Attempt 7 got a 200 with the account's
real data, so the combination is **not** currently rejected. But a single
successful `loadCodeAssist` is not proof the fingerprint is clean, and #1226 is
specifically about fingerprints that work and get accounts blocked later.

## What TokenDock is missing that `oh-my-pi` has

Not needed for sign-in, but real gaps found by reading it:

- **`onboardUser` is a long-running operation.** `oh-my-pi` sends
  `tierId: "free-tier"`, then polls `GET /v1internal/{operationName}` every
  second for 30s until `done: true`. `9router` polls 10× at 5s. TokenDock sends
  **no `tierId` and never polls** — it treats the response as final. On an
  account that needs onboarding, TokenDock will read an unfinished operation as
  a completed one.
- **Free-tier eligibility is a first-class check.** `oh-my-pi` inspects
  `ineligibleTiers` for `free-tier` and surfaces `reasonMessage` plus
  `validationUrl` — a link the user can act on. TokenDock has no equivalent and
  would report a generic failure for an account that is simply not eligible.
- **The second `loadCodeAssist`.** When `paidTier` is absent but a project
  exists, `oh-my-pi` re-calls `loadCodeAssist` with the project. TokenDock calls
  it once.
- **`paidTier` is the real tier signal.** `oh-my-pi` treats
  `hasMessageField(payload, "paidTier")` as the paid-account marker.
  TokenDock reads only `currentTier`. Attempt 7's log shows `paidTier` in the
  response, so the account may be paid and TokenDock is reporting the wrong tier.

Attempt 7's captured keys were
`allowedTiers, cloudaicompanionProject, currentTier, gcpManaged, paidTier,
upgradeSubscriptionUri` — which is `oh-my-pi`'s schema almost field for field,
confirming the response is the one it expects.

## Correlation across all four

**Universal agreement, four for four:**

- the Antigravity client id `1071006060591-…` and its secret
- the five scopes, full-URL form
- `prompt=consent` for a refresh token
- the `antigravity` family of `User-Agent`, `aidev_client` in the string
- `ideType` must be `ANTIGRAVITY` — the Gemini CLI's `IDE_UNSPECIFIED` is wrong
  here, which is what attempt 1's `invalid_scope` was really about

**Universal disagreement:**

- numeric vs string enums (1 vs 3)
- `User-Agent` version: `2.8.0` / `1.107.0` / `1.1.24` / `1.1.24` — and
  `oh-my-pi` fetches it live from Google's update manifest rather than pinning
- daily-only vs daily-then-prod
- whether the harness `User-Agent` should be `antigravity/cli` or
  `antigravity/hub` — `oh-my-pi` says `hub`, captured from the real
  `antigravity/hub` client, and `cortexkit` says `cli`

**Nobody agrees on, and nobody implements:**

- an account identity cross-check
- `Client-Metadata` on the provisioning call as a *string* map plus a numeric
  body (only `cortexkit` sends the header at all)

## What this means for the next attempt

The `oh-my-pi` implementation is the most defensible of the four, on the
evidence: its metadata is a single frozen constant, its response schema is
declared with a validator, its tests assert exact request bodies, and its
`User-Agent` version is discovered rather than invented. `9router` has an open
bug report about its own metadata. `cortexkit` has the correct shape but a
hardcoded project id that is not portable.

The three changes that follow from this cross-reference, in order:

1. **Source the account identity correctly** — `userinfo` for the email, the
   provisioning body for the account id — and decide whether the guard stays.
   This is attempt 7's blocker and needs a decision, not more reading.
2. **Add `tierId` and operation polling to `onboardUser`**, matching
   `oh-my-pi`. Only reached for accounts without a tier, so it is not blocking
   sign-in today.
3. **Read `paidTier`, and surface free-tier ineligibility** with its
   `validationUrl`. Attempt 7's account has a `paidTier`, so the tier TokenDock
   reports is probably wrong right now.

Change 1 is the only one that unblocks sign-in. 2 and 3 are correctness issues
that would surface as wrong quota data afterwards.

## Sources

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
