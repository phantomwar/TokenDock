import '../models/connection_status.dart';
import '../models/provider_snapshot.dart';
import 'provider_status.dart';

/// Why a provider refused a call, which is a different question from whether it
/// refused.
///
/// ## The rule this exists to enforce
///
/// **Only [ThrottleReason.invalidCredential] revokes a key.** Everything else
/// is a statement about the account at this moment, not about the credential
/// being wrong, and reporting one as the other tells the user to re-enter a
/// perfectly good key.
///
/// This was not hypothetical. A first implementation of the MiniMax and z.ai
/// adapters mapped *every* non-success body code to `authError` with
/// `ProviderFailureCause.invalidCredential`, which meant a MiniMax frequency cap
/// (code 1002) revoked the user's working credential and prompted a pointless
/// re-login. MiniMax publishes six documented body codes and not one of them
/// means the key is invalid.
///
/// ## Provenance
///
/// The taxonomy and the backoff ladder are adapted from
/// `packages/ai/src/error/rate-limit.ts` in `can1357/oh-my-pi`, which draws the
/// same line between "burn this credential" and "wait a bit": a usage limit gets
/// a temporary block, and only a hard auth failure marks the credential
/// suspect. The MiniMax code list comes from this repository's own
/// `docs/auth-quota-hardening-plan.md`.
///
/// ## The fallback that matters
///
/// An unrecognised code or status is [ThrottleReason.unknown] and never
/// revokes. oh-my-pi phrases the same rule as keeping the exception "scoped to
/// text we actually classify, rather than to any [signal]". A vendor that adds
/// a new rate-limit code must not start silently deleting users' credentials,
/// and a permissive default is the wrong way to be wrong here: it costs a
/// cooldown the user does not need, whereas a revocation costs them their setup.
enum ThrottleReason {
  /// Too many requests in flight. Clears in seconds.
  concurrent,

  /// A frequency or burst cap. Clears within the minute.
  rateLimit,

  /// A window or balance is spent. Clears in minutes or at the next reset.
  quotaExhausted,

  /// The account's **balance** is spent, as opposed to a quota window running
  /// out. Distinct from [quotaExhausted] because the two mean different things
  /// to a user and call for different action: a window refills on its own,
  /// whereas an empty balance needs a top-up.
  ///
  /// oh-my-pi keeps the same distinction as `QUOTA_EXHAUSTED` versus
  /// `INSUFFICIENT_G1_CREDITS_BALANCE`, and OpenRouter's 402 carries the
  /// vendor's own wording ("Insufficient credits"), which is more useful to a
  /// user than anything generic.
  creditsExhausted,

  /// The provider itself is at capacity.
  capacity,

  /// The provider returned a server error.
  serverError,

  /// The credential is valid but access was denied -- a plan, model or
  /// organisation restriction. Explicitly **not** a revocation: audit C-34
  /// established that a key which authenticated and was then refused must keep
  /// its credential, or the user re-enters a key that works.
  ///
  /// oh-my-pi keeps this in the same family ("403 -- token valid but access
  /// denied") and never treats it as a hard auth failure.
  forbidden,

  /// A refusal we cannot classify. Reported as transient, never as a bad key.
  unknown,

  /// The credential itself was rejected. **The only revoking reason.**
  invalidCredential,
}

/// The classification of one refusal: what happened, how the user should see it,
/// how long to wait, and whether the credential is at risk.
///
/// [revokesCredential] travels *with* the verdict rather than being a separate
/// lookup, because the bug this exists to prevent was a caller receiving a
/// rejection and deciding on its own that the key was bad. A caller now has the
/// answer in hand, and the flag is derived in exactly one place so it cannot
/// drift from [reason].
typedef ThrottleVerdict = ({
  ThrottleReason reason,
  ConnectionStatus status,
  String error,
  Duration? cooldown,
  bool revokesCredential,
});

/// Classifies a provider refusal into a [ThrottleVerdict].
///
/// Every provider that reads a vendor-specific body code should route through
/// here rather than deciding for itself, because the decision that matters --
/// revoke or do not revoke -- is the one most easily got wrong per vendor.
///
/// There is deliberately no "success" reason. A successful call has no refusal
/// to classify, and adding a value for it would only create a way to represent
/// `ok` here, which is a decision a provider adapter makes before it ever gets
/// here.
abstract final class ProviderThrottle {
  const ProviderThrottle._();

  // The ladder, from `rate-limit.ts`. Ordered by how long the cap actually
  // lasts, so a concurrency cap is not made to wait as long as a spent window.
  static const Duration concurrentBackoff = Duration(seconds: 5);
  static const Duration rateLimitBackoff = Duration(seconds: 30);
  static const Duration serverErrorBackoff = Duration(seconds: 20);
  static const Duration capacityBackoff = Duration(seconds: 45);
  static const Duration quotaExhaustedBackoff = Duration(minutes: 30);

  /// MiniMax `base_resp.status_code`, from `docs/auth-quota-hardening-plan.md`.
  ///
  /// Deliberately a lookup rather than a range: these are documented values
  /// with distinct meanings, and a range would invent meanings for the codes in
  /// between -- including codes a future release may add.
  static const Map<int, ThrottleReason> _miniMaxCodes = {
    1002: ThrottleReason.rateLimit, // frequencia
    2045: ThrottleReason.rateLimit, // rajada
    1041: ThrottleReason.concurrent, // conexoes
    1039: ThrottleReason.rateLimit, // tokens
    1008: ThrottleReason.creditsExhausted, // saldo -- a balance, not a window
    2056: ThrottleReason.quotaExhausted, // Token Plan -- a window that refills
  };

  /// Classifies from whatever the vendor gave us.
  ///
  /// [bodyCode] is a vendor's own numeric code and outranks [statusCode], because
  /// it is the more specific signal: a vendor that sends both has told us
  /// something the status cannot express.
  static ThrottleVerdict classify({
    int? statusCode,
    int? bodyCode,
    ThrottleReason? reason,
  }) {
    if (reason != null) return _verdict(reason);
    if (bodyCode != null) {
      // Only a code we can actually name becomes a reason. Everything else is
      // unknown, and unknown does not revoke.
      return _verdict(_miniMaxCodes[bodyCode] ?? ThrottleReason.unknown);
    }
    if (statusCode != null) {
      return _verdict(_fromStatus(statusCode));
    }
    return _verdict(ThrottleReason.unknown);
  }

  static ThrottleReason _fromStatus(int statusCode) {
    if (statusCode == 401) return ThrottleReason.invalidCredential;
    if (statusCode == 403) return ThrottleReason.forbidden;
    if (statusCode == 429) return ThrottleReason.rateLimit;
    if (statusCode == 402) return ThrottleReason.creditsExhausted;
    if (statusCode >= 500 && statusCode <= 599) {
      return ThrottleReason.serverError;
    }
    return ThrottleReason.unknown;
  }

  static ThrottleVerdict _verdict(ThrottleReason reason) {
    return (
      reason: reason,
      status: _statusOf(reason),
      error: _copyOf(reason),
      cooldown: _cooldownOf(reason),
      // The narrowest predicate in the codebase, on purpose: one reason, one
      // consequence, and it is the reason that actually means the key is bad.
      revokesCredential: reason == ThrottleReason.invalidCredential,
    );
  }

  /// Turns a verdict into the snapshot the refresh path persists.
  ///
  /// One constructor for every classified refusal, so the cooldown that
  /// `RefreshService` stores and the `failureCause` it uses to decide whether
  /// to revoke are always derived from the same verdict. Building the snapshot
  /// at each call site is how the two drift apart, and a drift there revokes
  /// credentials.
  ///
  /// Carries no quotas on purpose: a refused fetch must not erase what the user
  /// already had (the cache-first rule, PRD "Nunca apagar cache após erro").
  static ProviderSnapshot snapshot({
    required ThrottleVerdict verdict,
    required String connectionId,
    required DateTime fetchedAt,
  }) {
    return ProviderStatus.failure(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: verdict.status,
      error: verdict.error,
      cooldownUntil: verdict.cooldown == null
          ? null
          : fetchedAt.add(verdict.cooldown!),
    );
  }

  static ConnectionStatus _statusOf(ThrottleReason reason) {
    switch (reason) {
      case ThrottleReason.invalidCredential:
        return ConnectionStatus.authError;
      // "Your key works, you are being rate limited" is a warning, not a
      // failure. The account is healthy and the number is still meaningful.
      case ThrottleReason.concurrent:
      case ThrottleReason.rateLimit:
      case ThrottleReason.capacity:
        return ConnectionStatus.warning;
      // A spent window or an empty balance is a real, non-transient state about
      // the account, and it is the answer to the question the product exists to
      // answer.
      case ThrottleReason.quotaExhausted:
      case ThrottleReason.creditsExhausted:
        return ConnectionStatus.limited;
      case ThrottleReason.serverError:
      case ThrottleReason.unknown:
        return ConnectionStatus.error;
      // A refusal, and an accurate one, but not a broken credential.
      case ThrottleReason.forbidden:
        return ConnectionStatus.error;
    }
  }

  static String _copyOf(ThrottleReason reason) {
    switch (reason) {
      case ThrottleReason.concurrent:
        return 'Too many requests in flight';
      case ThrottleReason.rateLimit:
        return 'Rate limited';
      case ThrottleReason.quotaExhausted:
        return 'Quota exhausted';
      case ThrottleReason.creditsExhausted:
        return 'Insufficient credits';
      case ThrottleReason.capacity:
        return 'Provider at capacity';
      case ThrottleReason.serverError:
        return 'Provider unavailable';
      case ThrottleReason.forbidden:
        return 'Forbidden';
      case ThrottleReason.unknown:
        return 'Unknown response';
      case ThrottleReason.invalidCredential:
        return 'Invalid API key';
    }
  }

  static Duration? _cooldownOf(ThrottleReason reason) {
    switch (reason) {
      case ThrottleReason.concurrent:
        return concurrentBackoff;
      case ThrottleReason.rateLimit:
        return rateLimitBackoff;
      case ThrottleReason.capacity:
        return capacityBackoff;
      case ThrottleReason.serverError:
        return serverErrorBackoff;
      case ThrottleReason.quotaExhausted:
      case ThrottleReason.creditsExhausted:
        return quotaExhaustedBackoff;
      // No cooldown: a credential rejection is not going to clear, so retrying
      // on a timer would only spend requests re-confirming it. A denial is not
      // going to clear either, and the copy already tells the user what it is.
      case ThrottleReason.forbidden:
      case ThrottleReason.unknown:
      case ThrottleReason.invalidCredential:
        return null;
    }
  }
}
