# Task 8 Recovery Report

## Status
Recovery pass completed for Antigravity per-account remote OAuth.

## Red/green evidence
- RED: Added focused fake-HTTP tests for malformed `remaining`/reset values, reset-only buckets, nested legacy model `quotaInfo`, transport fallback, onboarding identity mismatch, transient statuses, registry registration, secret persistence/no client secret, token rotation/reuse, invalid_grant, and two-account isolation. The initial run failed on malformed schema acceptance, legacy merge parsing, and transport fallback fixture setup.
- GREEN: `flutter test --no-pub test/providers/antigravity_oauth_test.dart test/providers/antigravity_local_test.dart` passed (26 tests).
- GREEN: `flutter test --no-pub test/services/oauth_loopback_test.dart test/services/refreshable_test.dart test/services/refresh_service_test.dart` passed (21 tests).
- GREEN: combined focused Task 8 + Task 7 + RefreshService command passed (47 tests).

## Changes
- Deep quota validation rejects non-map `remaining`, malformed reset strings, and entries without fraction/reset while allowing valid reset-only entries.
- Legacy model entries now merge nested `quotaInfo` before local parsing; merged quota data is validated before parsing.
- Pending old-secret cleanup is a set of refs, preserving every orphaned ref; dispose cancels the cleanup timer and prevents rescheduling.
- Restored/expanded fake HTTP acceptance coverage for account isolation, registry defaults, no client secret/request-body leakage, prod-to-daily transport fallback, onboarding mismatch, schema tombstones/transient statuses, rotation/reuse, and invalid_grant.

## Remaining concerns
- Tests use injected fake HTTP and do not contact Google or launch a real Windows browser.
- Cleanup retry remains timer-based at one minute; dispose intentionally cancels pending retries.

## Commit
- Source/test recovery commit: `0392f70d20e135a0df52288f4673d1e8297b0771` (`fix: recover Antigravity provider review findings`)
