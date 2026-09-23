# Final Recovery 5 Report

## Scope

Closed the final CSRF no-replacement finding from `agent://FinalRecovery4Review` in the `login-adaptation` worktree. No real credentials, OAuth accounts, Antigravity processes, or external services were used.

## Implemented fix

After a local language-server endpoint rejects the request or throws, the reader now authorizes one retry only when rediscovery yields a different CSRF token or a different, non-null verified process/session. Losing the discovered session while the token callback still returns the rejected token is not a replacement.

When no replacement exists, the reader clears its local rejected token, leaves the entire language-server endpoint loop, and proceeds to the existing `agy` fallback. The rejected token is never sent to another local endpoint or retried on the same endpoint.

In callback-only mode (`csrfTokenFor` without runtime custody or a discovered session), a rejected or thrown endpoint now also clears the local token and exits the entire endpoint loop before `agy`. A 404 remains an unsupported-endency signal and continues through the ordered endpoint fallbacks.

## Regression coverage

Added `rejected CSRF token is not reused when rediscovery finds no replacement` to `test/providers/antigravity_local_test.dart`. The regression:

- discovers a session and receives a 401 for its CSRF token;
- makes rediscovery return no session while the token callback still returns the rejected token;
- asserts only one local HTTP request was sent and its token appeared exactly once;
- asserts runtime custody is empty and the reader entered the `agy` fallback.

Added `callback-only CSRF rejection leaves local endpoints for agy`. It supplies a callback-only token, receives 401, and asserts that only `RetrieveUserQuotaSummary` was called, the rejected token appeared once, and the `agy` fallback ran.

The existing same-port restart, replacement-after-failure, and ordered endpoint fallback regressions remain covered and passing.

## TDD evidence

- RED 1: the initial no-replacement regression exposed all three local endpoints being called with the rejected token.
- RED 2: after adding the outer-loop exit, the strengthened discovery-gap case exposed a second request to the same endpoint because a lost session incorrectly authorized reuse of the callback's unchanged token.
- RED 3: the callback-only regression exposed all three local endpoints being called with the rejected token; the first focused rerun then exposed that 404 unsupported endpoints still need ordered fallback.
- GREEN 1: requiring a changed token or a changed, non-null discovered session and exiting the outer loop without a replacement made the discovery-gap regression pass.
- GREEN 2: callback-only rejection now clears the token and breaks the outer endpoint loop, while 404 continues to the next supported endpoint.

## Verification

- Focused CSRF/storage command: `flutter test --no-pub test/providers/antigravity_local_test.dart test/providers/antigravity_oauth_test.dart test/services/refresh_service_test.dart test/storage/repositories_test.dart` — 74 tests passed.
- Full command: `flutter test --no-pub` — 197 tests passed.
- Analyzer: `flutter analyze` — 0 errors, 0 warnings, 7 pre-existing informational diagnostics; exits nonzero as expected for the repository baseline.
- No project-wide formatting was run.

## Remaining risk

Windows process discovery remains covered with sanitized fakes; no real Antigravity process was exercised. The unavoidable discovery-to-request race remains unchanged.
