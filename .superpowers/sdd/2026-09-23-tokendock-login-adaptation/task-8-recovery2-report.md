# Task 8 Recovery Pass 2 Report

## Findings closed
- Legacy `fetchAvailableModels` entries whose `quotaInfo` is a direct quota object are now stored under the model name. Existing pool entries are merged by selecting the lower remaining fraction, so the worst observed pool is retained.
- The OAuth regression test now drives the real `loginWithLoopback()` path with a fake external launcher and loopback HTTP callback. It verifies the Google authorization URL, PKCE S256 challenge, state, callback delivery, token exchange redirect/code, persisted secret, and closed listener.
- RefreshService lifecycle tests now cover proactive rotation, one reactive 401 refresh/retry, invalid-grant disable/tombstone notification, repeated failed-cleanup refs, and disposal of cleanup work. Transient coverage consumes both queued 429 and 503 responses.

## Red/green evidence
- RED: Recovery review reproduced the direct `{name: 'gemini-pro', quotaInfo: {remainingFraction: 0.2, resetTime: ...}}` shape as `quota_source_changed`; the old browser test bypassed `loginWithLoopback()` and asserted `opened == null`; rotation/reuse and repeated cleanup paths were not exercised through RefreshService.
- GREEN: `flutter test --no-pub test/providers/antigravity_oauth_test.dart test/providers/antigravity_local_test.dart test/services/oauth_loopback_test.dart test/services/refreshable_test.dart test/services/refresh_service_test.dart` passed (49 tests).
- GREEN: `git diff --check` passed with no whitespace errors.

## Implementation notes
- Direct model quota entries are distinguished from pool maps by quota fields (`remainingFraction`, `remaining`, `resetTime`, or `resetAt`) and merged with the lower fraction.
- RefreshService now invokes the refreshable credential directly from its own refresh operation, avoiding the prior self-wait through `runTokenOperation()` while preserving one refresh per `refreshOne()`.
- No project-wide validation was run.

## Commit
- Recovery changes are committed in the current branch HEAD (`fix: close Task 8 recovery findings`).
