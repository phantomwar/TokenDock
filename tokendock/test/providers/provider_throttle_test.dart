import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/provider_throttle.dart';

/// Why a provider refuses a call is a different question from whether it
/// refused, and conflating the two is how a working credential gets revoked.
///
/// The rule these tests exist to pin: **only an explicit credential rejection
/// revokes a key.** A frequency cap, a burst cap, a concurrency cap, an
/// exhausted balance and a busy provider are all statements about the *account
/// at this moment*, not about the key being wrong. Treating them as an auth
/// failure tells the user to re-enter a credential that is perfectly fine.
///
/// The taxonomy and the backoff ladder are adapted from
/// `packages/ai/src/error/rate-limit.ts` in `can1357/oh-my-pi`, which draws the
/// same line: a usage limit gets a temporary block, and only a hard auth
/// failure marks the credential suspect. The MiniMax codes come from this
/// repository's own `docs/auth-quota-hardening-plan.md`.
void main() {
  group('the only reason that revokes a credential', () {
    test('is an explicit credential rejection', () {
      final verdict = ProviderThrottle.classify(statusCode: 401);
      expect(verdict.reason, ThrottleReason.invalidCredential);
      expect(verdict.status, ConnectionStatus.authError);
      expect(verdict.revokesCredential, isTrue);
    });

    test('is never produced by a code we do not recognise', () {
      // The single most important assertion in this file. oh-my-pi states the
      // principle as "this keeps the exception scoped to text we actually
      // classify" -- guessing is how a vendor's new rate-limit code starts
      // silently deleting users' credentials.
      for (final code in <int>[-1, 0, 1, 999, 1234, 99999, 1001, 1003, 2057]) {
        final verdict = ProviderThrottle.classify(bodyCode: code);
        expect(
          verdict.revokesCredential,
          isFalse,
          reason: 'unrecognised code $code must not revoke a credential',
        );
      }
    });

    test('a 403 is not a revocation either', () {
      // Audit C-34: a key that authenticated and was then refused must not be
      // revoked, or the user re-enters a working key.
      final verdict = ProviderThrottle.classify(statusCode: 403);
      expect(verdict.revokesCredential, isFalse);
      expect(verdict.status, ConnectionStatus.error);
    });
  });

  group('MiniMax body codes', () {
    // Documented in docs/auth-quota-hardening-plan.md: 1002 frequencia,
    // 2045 rajada, 1041 conexoes, 1039 tokens, 1008 saldo, 2056 Token Plan.
    // Not one of them means the key is wrong.
    test('1002 is a frequency cap, so a short backoff and a warning', () {
      final verdict = ProviderThrottle.classify(bodyCode: 1002);
      expect(verdict.reason, ThrottleReason.rateLimit);
      expect(verdict.status, ConnectionStatus.warning);
      expect(verdict.cooldown, ProviderThrottle.rateLimitBackoff);
      expect(verdict.revokesCredential, isFalse);
    });

    test('2045 is a burst cap, treated as a rate limit', () {
      final verdict = ProviderThrottle.classify(bodyCode: 2045);
      expect(verdict.reason, ThrottleReason.rateLimit);
      expect(verdict.revokesCredential, isFalse);
    });

    test('1041 is a concurrency cap, so the shortest backoff of all', () {
      final verdict = ProviderThrottle.classify(bodyCode: 1041);
      expect(verdict.reason, ThrottleReason.concurrent);
      expect(verdict.cooldown, ProviderThrottle.concurrentBackoff);
      expect(verdict.revokesCredential, isFalse);
    });

    test('1039 is a token cap, so a short backoff rather than a long one', () {
      final verdict = ProviderThrottle.classify(bodyCode: 1039);
      expect(verdict.reason, ThrottleReason.rateLimit);
      expect(verdict.cooldown, ProviderThrottle.rateLimitBackoff);
    });

    test('1008 is an exhausted balance, not a spent window', () {
      // `saldo` is a balance. The two need different action from the user -- a
      // window refills by itself, a balance needs a top-up -- so they are not
      // the same reason, following oh-my-pi's `QUOTA_EXHAUSTED` versus
      // `INSUFFICIENT_G1_CREDITS_BALANCE`.
      final verdict = ProviderThrottle.classify(bodyCode: 1008);
      expect(verdict.reason, ThrottleReason.creditsExhausted);
      expect(verdict.status, ConnectionStatus.limited);
      expect(verdict.error, 'Insufficient credits');
      expect(verdict.cooldown, ProviderThrottle.quotaExhaustedBackoff);
    });

    test('2056 is a spent Token Plan window', () {
      final verdict = ProviderThrottle.classify(bodyCode: 2056);
      expect(verdict.reason, ThrottleReason.quotaExhausted);
      expect(verdict.status, ConnectionStatus.limited);
    });
    test('every documented MiniMax code leaves the credential alone', () {
      for (final code in <int>[1002, 2045, 1041, 1039, 1008, 2056]) {
        expect(
          ProviderThrottle.classify(bodyCode: code).revokesCredential,
          isFalse,
          reason: 'code $code',
        );
      }
    });
  });

  group('the backoff ladder is ordered by how long the cap lasts', () {
    test(
      'concurrency clears before a frequency cap, which clears before a window',
      () {
        expect(
          ProviderThrottle.concurrentBackoff,
          lessThan(ProviderThrottle.rateLimitBackoff),
        );
        expect(
          ProviderThrottle.rateLimitBackoff,
          lessThan(ProviderThrottle.quotaExhaustedBackoff),
        );
      },
    );

    test('a quota window waits far longer than a server blip', () {
      // A provider that is briefly unavailable is worth retrying soon. A spent
      // 5-hour window is not, and hammering it is what the cooldown prevents.
      expect(
        ProviderThrottle.quotaExhaustedBackoff,
        greaterThan(ProviderThrottle.serverErrorBackoff),
      );
    });
  });

  group('HTTP status without a richer body', () {
    test('429 is a rate limit, not a dead credential', () {
      final verdict = ProviderThrottle.classify(statusCode: 429);
      expect(verdict.reason, ThrottleReason.rateLimit);
      expect(verdict.status, ConnectionStatus.warning);
      expect(verdict.revokesCredential, isFalse);
    });

    test('402 is an exhausted balance', () {
      final verdict = ProviderThrottle.classify(statusCode: 402);
      expect(verdict.reason, ThrottleReason.creditsExhausted);
      expect(verdict.status, ConnectionStatus.limited);
      expect(verdict.error, 'Insufficient credits');
      expect(verdict.revokesCredential, isFalse);
    });

    test('403 is a denial, with its own copy rather than a generic one', () {
      // Audit C-34: not a revocation, and the user is told what actually
      // happened instead of "Unknown response".
      final verdict = ProviderThrottle.classify(statusCode: 403);
      expect(verdict.reason, ThrottleReason.forbidden);
      expect(verdict.error, 'Forbidden');
      expect(verdict.revokesCredential, isFalse);
    });

    test('5xx is the provider having a bad day, with a short retry', () {
      final verdict = ProviderThrottle.classify(statusCode: 503);
      expect(verdict.reason, ThrottleReason.serverError);
      expect(verdict.status, ConnectionStatus.error);
      expect(verdict.cooldown, ProviderThrottle.serverErrorBackoff);
      expect(verdict.revokesCredential, isFalse);
    });

    test('a body code wins over the status, because it is more specific', () {
      // A MiniMax frequency cap arrives with HTTP 200 and a body code, so
      // there is no conflict there -- but a vendor that sends both must not have
      // its specific reason flattened to whatever the status implies. A 429
      // means a 30s backoff; code 1008 means 30 minutes and an empty balance.
      final verdict = ProviderThrottle.classify(
        statusCode: 429,
        bodyCode: 1008,
      );
      expect(verdict.reason, ThrottleReason.creditsExhausted);
      expect(verdict.cooldown, ProviderThrottle.quotaExhaustedBackoff);
    });

    test('no status and no code is unknown, and stays unknown', () {
      final verdict = ProviderThrottle.classify();
      expect(verdict.reason, ThrottleReason.unknown);
      expect(verdict.status, ConnectionStatus.error);
      expect(verdict.cooldown, isNull);
      expect(verdict.revokesCredential, isFalse);
    });

    test('an unmapped status stays unknown rather than becoming a guess', () {
      for (final code in <int>[418, 451, 0, -5, 999]) {
        expect(
          ProviderThrottle.classify(statusCode: code).reason,
          ThrottleReason.unknown,
          reason: 'status $code',
        );
      }
    });
  });

  group('the verdict is safe to render', () {
    test('every reason has user-facing copy, and none of it names a key', () {
      for (final reason in ThrottleReason.values) {
        final verdict = ProviderThrottle.classify(reason: reason);
        expect(verdict.error, isNotEmpty, reason: '$reason');
        if (reason != ThrottleReason.invalidCredential) {
          expect(
            verdict.error.toLowerCase(),
            isNot(contains('api key')),
            reason:
                '$reason is not a credential problem, so its copy must not tell '
                'the user their key is wrong',
          );
        }
      }
    });

    test('a throttled connection is never reported as healthy', () {
      // A cooldown that is reported as `ok` would let the next refresh run
      // straight back into the cap the cooldown exists to avoid.
      for (final reason in ThrottleReason.values) {
        expect(
          ProviderThrottle.classify(reason: reason).status,
          isNot(ConnectionStatus.ok),
          reason: '$reason',
        );
      }
    });

    test('revokesCredential agrees with the reason, and only that reason', () {
      for (final reason in ThrottleReason.values) {
        expect(
          ProviderThrottle.classify(reason: reason).revokesCredential,
          reason == ThrottleReason.invalidCredential,
          reason: '$reason',
        );
      }
    });

    test(
      'a cooldown accompanies every reason that has one, and it expires',
      () {
        for (final reason in ThrottleReason.values) {
          final verdict = ProviderThrottle.classify(reason: reason);
          if (verdict.cooldown != null) {
            expect(
              verdict.cooldown,
              greaterThan(Duration.zero),
              reason: '$reason has a cooldown that never expires',
            );
          }
        }
      },
    );
  });

  group('turning a verdict into a snapshot', () {
    // `ProviderStatus.failure` derives `failureCause` from the *status*, not
    // from the reason. So the classifier's two outputs must agree, or the
    // snapshot would revoke a credential the verdict said to keep. This is the
    // invariant that makes routing providers through here safe at all.
    test('authError and revokesCredential are the same predicate', () {
      for (final reason in ThrottleReason.values) {
        final verdict = ProviderThrottle.classify(reason: reason);
        expect(
          verdict.status == ConnectionStatus.authError,
          verdict.revokesCredential,
          reason:
              '$reason: the snapshot would revoke a credential the verdict '
              'said to keep',
        );
      }
    });

    test('a throttled credential keeps its failureCause null', () {
      // This is the property the whole refactor exists for: a rate limit must
      // not mark the credential as needing a re-login.
      for (final reason in ThrottleReason.values) {
        if (reason == ThrottleReason.invalidCredential) continue;
        final snapshot = ProviderThrottle.snapshot(
          verdict: ProviderThrottle.classify(reason: reason),
          connectionId: 'c1',
          fetchedAt: DateTime.utc(2026, 9, 26, 12),
        );
        expect(
          snapshot.failureCause,
          isNull,
          reason: '$reason must not mark the credential as revoked',
        );
      }
    });

    test('a throttled snapshot carries no quotas, so the cache is kept', () {
      // `RefreshService` replaces the cached quota with whatever a snapshot
      // carries, so a refusal carrying quotas would overwrite good values with
      // the ones it happened to have.
      final snapshot = ProviderThrottle.snapshot(
        verdict: ProviderThrottle.classify(bodyCode: 1002),
        connectionId: 'c1',
        fetchedAt: DateTime.utc(2026, 9, 26, 12),
      );
      expect(snapshot.quotas, isEmpty);
    });

    test(
      'a cooldown becomes an absolute deadline the refresh path can store',
      () {
        final fetchedAt = DateTime.utc(2026, 9, 26, 12);
        final snapshot = ProviderThrottle.snapshot(
          verdict: ProviderThrottle.classify(bodyCode: 1002),
          connectionId: 'c1',
          fetchedAt: fetchedAt,
        );
        expect(snapshot.cooldownUntil, isNotNull);
        expect(
          snapshot.cooldownUntil!.toUtc(),
          fetchedAt.add(ProviderThrottle.rateLimitBackoff),
        );
      },
    );

    test('a refusal with no cooldown stores no deadline', () {
      // A credential rejection will not clear, so a deadline would only spend
      // requests re-confirming it.
      for (final reason in <ThrottleReason>[
        ThrottleReason.unknown,
        ThrottleReason.invalidCredential,
      ]) {
        final snapshot = ProviderThrottle.snapshot(
          verdict: ProviderThrottle.classify(reason: reason),
          connectionId: 'c1',
          fetchedAt: DateTime.utc(2026, 9, 26, 12),
        );
        expect(snapshot.cooldownUntil, isNull, reason: '$reason');
      }
    });
  });
}
