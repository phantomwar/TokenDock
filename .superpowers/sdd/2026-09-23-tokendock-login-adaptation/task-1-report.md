# Task 1 Implementation Report: AuthKind + auth header building

## Status

Implemented and focused-test verified.

## Changes

- Added `AuthKind { apiKey, oauth, structuredBearer, none }` to `lib/providers/provider_adapter.dart`.
- Extended `ProviderAdapter` with required `authKind` and `buildAuthHeader(String secret)`, returning `Authorization: Bearer <secret>`.
- Declared `OpenRouterProvider.authKind` as `AuthKind.apiKey`.
- Implemented `OpenRouterProvider.buildAuthHeader` explicitly because the provider uses Dart `implements ProviderAdapter` rather than inheriting the interface default.
- Documented the default OpenRouter registry entry as API-key authenticated.
- Added `test/providers/auth_kind_test.dart`, covering registry lookup, the OpenRouter auth kind, and call-time Bearer header construction.

## TDD Evidence

1. Wrote `test/providers/auth_kind_test.dart` before production changes.
2. Ran the focused test; it failed to compile because `AuthKind`, `authKind`, and `buildAuthHeader` were absent.
3. Added the minimal interface/provider/registry changes.
4. The first implementation run exposed Dart's explicit `implements` requirement for concrete interface members; added the OpenRouter override.
5. Ran the focused test again; it passed.

Focused command:

```text
flutter test --no-pub test/providers/auth_kind_test.dart
```

Result: `+2: All tests passed!`

## Scope Notes

Project-wide tests, linters, and formatters were not run, per assignment. Focused coverage was expanded to compile and exercise the three existing test-only provider implementations.

## Commit

Pending commit at report-write time; the commit hash is supplied with the final task result.

## Follow-up Fix

The reviewer identified that the required interface members were missing from the test-only `ControlledProvider`, `FakeProviderAdapter`, and `FixtureProviderAdapter` implementations. Each now declares `AuthKind.apiKey` and returns the same call-time Bearer header map as OpenRouter. The focused test imports and exercises all three doubles, ensuring the new contract compiles and is observable.

Follow-up focused command and result:

```text
flutter test --no-pub test/providers/auth_kind_test.dart
+2: All tests passed!
```

The fix is committed separately after the original Task 1 commit.
