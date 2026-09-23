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

Result: `+1: All tests passed!`

## Scope Notes

Project-wide tests, linters, and formatters were not run, per assignment. Existing test-only `ProviderAdapter` implementations were identified as requiring the new interface members if they are exercised by a broader suite; they were not expanded in this task because the brief names only the production OpenRouter adapter and the new focused test.

## Commit

Pending commit at report-write time; the commit hash is supplied with the final task result.
