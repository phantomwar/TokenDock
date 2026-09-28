import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../../services/oauth_loopback.dart';
import '../../services/refreshable_credential.dart';
import '../../storage/secret_store.dart';
import '../provider_adapter.dart';
import 'antigravity_local.dart';

class AntigravityOAuthHttpResponse {
  const AntigravityOAuthHttpResponse({
    required this.statusCode,
    required this.body,
    this.retryAfter,
  });
  final int statusCode;
  final String body;
  final String? retryAfter;
}

abstract interface class AntigravityOAuthHttpRunner {
  Future<AntigravityOAuthHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  });

  /// A GET, for the userinfo endpoint.
  ///
  /// Added with the account-email lookup rather than routing a GET through
  /// [post]: the method is part of the request, and a runner that has to guess
  /// it from an empty body is a runner whose tests can pass for the wrong
  /// reason.
  Future<AntigravityOAuthHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  });
}

class AntigravityOnboardingRequired implements Exception {
  const AntigravityOnboardingRequired();
  @override
  String toString() => 'Complete Antigravity onboarding before connecting';
}

class AntigravityTransportFailure implements Exception {
  const AntigravityTransportFailure(this.cause);
  final Object cause;
}

class AntigravityLoginCancelled implements Exception {
  const AntigravityLoginCancelled();
  @override
  String toString() => 'Antigravity login cancelled';
}

class AntigravityTransientFailure implements Exception {
  const AntigravityTransientFailure(this.statusCode, {this.cooldownUntil});
  final int statusCode;
  final DateTime? cooldownUntil;
  @override
  String toString() => 'Antigravity transient HTTP $statusCode';
}

class AntigravitySchemaChanged implements Exception {
  const AntigravitySchemaChanged();
  @override
  String toString() => 'quota_source_changed';
}

/// A non-success HTTP response, carrying the status for classification.
///
/// Failure handling classifies on [statusCode] rather than on message text, as
/// the design spec requires ("status + header + provider code first, never
/// fragile message regex").
class AntigravityHttpStatus implements Exception {
  const AntigravityHttpStatus(this.statusCode);
  final int statusCode;
  @override
  String toString() => 'Antigravity HTTP $statusCode';
}

class AntigravityOAuthLoginResult {
  const AntigravityOAuthLoginResult({
    required this.secret,
    required this.identityKey,
    required this.projectId,
    required this.tier,
  });
  final String secret;
  final String identityKey;
  final String? projectId;
  final String? tier;
}

class AntigravitySelectedAccountGuard {
  const AntigravitySelectedAccountGuard();
  bool accepts({
    required String? expected,
    required Map<String, dynamic> payload,
  }) => expected == null || expected.isEmpty || identityOf(payload) == expected;

  /// The identity carried by a payload, or `null` when it carries none.
  ///
  /// The email alone, and only the email -- see
  /// [AntigravityOAuthProvider.identityFrom] for why there is no account id.
  /// Composed as `email|accountId` until the ninth live attempt proved that the
  /// account id is not sent by any Google response this flow sees.
  static String? identityOf(Map<String, dynamic> payload) {
    final root = payload['response'] is Map
        ? Map<String, dynamic>.from(payload['response'] as Map)
        : payload;
    final email = (root['accountEmail'] ?? root['email'])?.toString().trim();
    return email == null || email.isEmpty ? null : email;
  }
}

class AntigravityOAuthProvider implements ProviderAdapter {
  AntigravityOAuthProvider({
    AntigravityOAuthHttpRunner? http,
    this._secretStore,
    Future<void> Function(Uri url)? launchExternalBrowser,
    Future<void> Function(Duration delay)? sleep,
    Random? random,
  }) : _http = http ?? AntigravityHttpClientRunner(),
       launchExternalBrowser = launchExternalBrowser ?? launchWindowsBrowser,
       _sleep = sleep ?? Future<void>.delayed,
       _random = random ?? Random.secure();
  final AntigravityOAuthHttpRunner _http;
  final SecretStore? _secretStore;
  final Future<void> Function(Uri url) launchExternalBrowser;
  final Future<void> Function(Duration delay) _sleep;
  final Random _random;

  /// Refresh tokens rotated out by this process, oldest first, bounded by
  /// [maxRememberedRotatedRefreshTokens].
  final LinkedHashMap<String, bool> _rotatedRefreshTokens =
      LinkedHashMap<String, bool>();

  /// Coalesces concurrent exchanges presenting the same stored secret.
  final Map<String, Future<String>> _exchangeInFlight = {};
  static const _maximumTransientAttempts = 3;

  static Future<void> launchWindowsBrowser(Uri url) async {
    if (Platform.isWindows) {
      await Process.run('rundll32.exe', [
        'url.dll,FileProtocolHandler',
        url.toString(),
      ]);
      return;
    }
    throw UnsupportedError(
      'External browser handoff is unsupported on this platform',
    );
  }

  static const tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const prodHost = 'https://cloudcode-pa.googleapis.com';
  static const dailyHost = 'https://daily-cloudcode-pa.googleapis.com';
  static const authorizationEndpoint =
      'https://accounts.google.com/o/oauth2/v2/auth';
  static const revokeEndpoint = 'https://oauth2.googleapis.com/revoke';

  /// The Antigravity OAuth client id.
  ///
  /// Read from the build environment so the credential never lives in the
  /// repository: pass `--dart-define=ANTIGRAVITY_CLIENT_ID=...` (and
  /// `ANTIGRAVITY_CLIENT_SECRET=...`) to `flutter build`, `flutter run` and
  /// `flutter test`. Without them this falls back to an obviously-fake
  /// placeholder, so a build that forgets the defines fails at the token
  /// endpoint instead of silently using the wrong client.
  ///
  /// This was previously the *Gemini CLI* client (`681255809395-...`), and an
  /// OAuth client is only permitted the scopes registered to it. Asking the
  /// Gemini CLI client for Antigravity's scopes produced Google's
  /// `Error 400: invalid_scope ... [invalid=[cloud-platform, userinfo.email,
  /// userinfo.profile]]`, which lists the scopes and so looks like a scope
  /// problem rather than a client problem.
  static const clientId = String.fromEnvironment(
    'ANTIGRAVITY_CLIENT_ID',
    defaultValue: 'UNCONFIGURED.apps.googleusercontent.com',
  );

  /// The client secret for [clientId].
  ///
  /// Antigravity's client is a **confidential** client, so both the code
  /// exchange and the refresh require the secret. Omitting it fails at the token
  /// endpoint rather than at the consent screen, which is why it presents as a
  /// different fault from the one it actually is.
  ///
  /// Like [clientId] this comes from `--dart-define=ANTIGRAVITY_CLIENT_SECRET`
  /// and is deliberately not embedded in the source: a desktop binary is
  /// readable, so anyone determined can extract an embedded secret, and GitHub
  /// push protection refuses to store one. The reference implementation this
  /// value came from ships it base64-encoded, which is obfuscation and not
  /// encryption.
  ///
  /// The alternative is to run the maintainer's own Google Cloud OAuth
  /// credentials, so the exposed secret is theirs rather than Google's. That is
  /// the supported route for a distributed desktop app, and it is a product
  /// decision rather than a code one.
  static const clientSecret = String.fromEnvironment(
    'ANTIGRAVITY_CLIENT_SECRET',
    defaultValue: 'UNCONFIGURED_ANTIGRAVITY_CLIENT_SECRET',
  );

  /// The five scopes Antigravity registers.
  ///
  /// Full URLs, not the short forms. Google accepts both spellings, but only
  /// the registered form matches the client's scope list, and the short forms
  /// are what came back verbatim in the `invalid_scope` response.
  ///
  /// `cclog` and `experimentsandconfigs` were missing from the previous request
  /// entirely.
  /// The order the Cloud Code endpoints are probed in.
  ///
  /// **Daily first.** `cortexkit/antigravity-auth` probes
  /// `daily-cloudcode-pa.googleapis.com` before production, and records that live
  /// `agy` CLI 1.1.24 traffic uses the daily endpoint. TokenDock probed
  /// production first, which meant the endpoint a real Antigravity client
  /// actually talks to was only reached after production had already failed.
  static const List<String> loadEndpointOrder = <String>[dailyHost, prodHost];

  static const List<String> scopes = <String>[
    'https://www.googleapis.com/auth/cloud-platform',
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
    'https://www.googleapis.com/auth/cclog',
    'https://www.googleapis.com/auth/experimentsandconfigs',
  ];

  /// The scope list as it goes on the wire.
  ///
  /// Space separated, because that is what Google expects. A comma-separated
  /// list is read as a single unknown scope name.
  static String get scopeParameter => scopes.join(' ');

  /// Forces the consent screen.
  ///
  /// Without it Google can reuse an existing grant and return **no** refresh
  /// token. The failure then surfaces on the *next* login as "OAuth refresh
  /// token missing", which points at the token exchange rather than at the
  /// authorization request that caused it.
  static const String prompt = 'consent';

  static const String accessType = 'offline';

  /// The project id a *reference* client falls back to, recorded but not used.
  ///
  /// `cortexkit/antigravity-auth` hardcodes this for accounts the endpoint
  /// provisions no project for. It belongs to that project's owner. Using it
  /// here would point a user's requests and quota reporting at a Google Cloud
  /// project that is not theirs, so it is deliberately not applied -- see the
  /// branch in `login` for the full reasoning.
  static const String referenceFallbackProjectId = 'rising-fact-p41fc';

  // `Client-Metadata` and `X-Goog-Api-Client` used to be sent on every Cloud
  // Code call, on the reading that both were required. They are not: none of
  // `CLIProxyAPI`, `oh-my-pi` or `9router` sends either for `loadCodeAssist`,
  // and the endpoint answered `400 INVALID_ARGUMENT` while they were present.
  // `cortexkit` sends `Client-Metadata`, and is the one implementation that
  // does not work against a live account without its own project id. A header
  // only one of six sends is a fingerprint, not a contract -- so the constants
  // are gone rather than merely unused, and a test asserts the header set is
  // exactly the four that work.

  /// The account profile endpoint, used only to source the account email.
  ///
  /// `oauth2/**v2**/userinfo`, matching `CLIProxyAPI`. `9router` and `cortexkit`
  /// send `oauth2/v1/userinfo`; v2 is the endpoint Google documents and the one
  /// the most widely deployed implementation uses. The `userinfo.email` scope is
  /// already granted, so this needs no new scope and no new credential.
  static const String userInfoEndpoint =
      'https://www.googleapis.com/oauth2/v2/userinfo?alt=json';

  /// The account email, or `null` when it cannot be obtained.
  ///
  /// Degrades rather than fails, and that is the norm: `cortexkit` treats a
  /// non-OK response as an empty object and continues, and the same reasoning
  /// applies here. The credential is already proven — the provisioning call that
  /// follows is made *with* this access token, so a successful
  /// `loadCodeAssist` is itself the authentication. A Google-side outage on an
  /// unrelated endpoint must not lock users out of the provider.
  ///
  /// Never fabricates a value. A missing email is `null`, and the caller decides
  /// what an unknown identity means; inventing one would put a value into the
  /// account-binding guard that the guard then "verifies" against, which is the
  /// exact failure the guard exists to prevent.
  Future<String?> _fetchAccountEmail(String access) async {
    try {
      final response = await _get(
        Uri.parse(userInfoEndpoint),
        stage: 'userinfo',
        headers: <String, String>{
          'Authorization': 'Bearer $access',
          'Accept': 'application/json',
          'User-Agent': userAgent,
        },
      );
      final email = response['email']?.toString().trim();
      if (email == null || email.isEmpty) {
        _logStage('userinfo returned no email');
        return null;
      }
      // The email itself is an account identifier and is never logged, only
      // that one arrived.
      _logStage('userinfo returned the account email');
      return email;
    } on AntigravityTransportFailure {
      _logStage('userinfo transport failure; continuing without an email');
      return null;
    } on AntigravityTransientFailure catch (error) {
      // A 429 or 5xx after the retry ladder is spent. Worth naming separately
      // from a plain rejection because it is a rate limit on an endpoint whose
      // answer this login does not actually need, and the credential is fine.
      _logStage(
        'userinfo throttled or unavailable; continuing without an email',
        status: error.statusCode,
      );
      return null;
    } on AntigravityHttpStatus catch (error) {
      // Not fatal, and not silent. A 403 here means the scope was not granted
      // or the endpoint is blocked, which is worth knowing and is not worth
      // failing a working credential over.
      _logStage(
        'userinfo rejected; continuing without an email',
        status: error.statusCode,
        reason: rejectionReasonOf(''),
      );
      return null;
    } on AntigravitySchemaChanged {
      _logStage('userinfo returned an unexpected shape; continuing');
      return null;
    }
  }

  // The account email and account id used to be read off the provisioning
  // response, and there is a whole pair of helpers for it here that are now gone.
  // They were reading fields Google does not send on this call: the ninth live
  // attempt logged the real response keys and the `oh-my-pi` schema declares the
  // same five. What the flow still needs is the email, and that comes from
  // userinfo. See [identityFrom].

  /// The account identity: the email, and only the email.
  ///
  /// This used to be `email|accountId`, composed from two sources. **The
  /// `accountId` does not exist.** It was in TokenDock's own test fixtures and in
  /// nothing else:
  ///
  /// - `oh-my-pi` declares the `loadCodeAssist` response schema as exactly
  ///   `currentTier`, `paidTier`, `allowedTiers`, `ineligibleTiers` and
  ///   `cloudaicompanionProject`. No account fields. The file does not mention an
  ///   account identity at all.
  /// - `CLIProxyAPI`'s `userInfo` struct has one field, `email`.
  /// - The ninth live sign-in attempt logged the real response keys —
  ///   `allowedTiers, cloudaicompanionProject, currentTier, gcpManaged,
  ///   paidTier, upgradeSubscriptionUri` — and no `accountEmail`, no
  ///   `accountId`.
  ///
  /// So the identity is the email, which is what all six implementations use.
  ///
  /// **What is lost, stated plainly:** the cross-check that bound a stored
  /// credential to one account is gone. It was the only defence against a token
  /// for one account reading another's quota, and that failure mode is plausible
  /// output rather than an error. Reinstating it needs a second independent
  /// source, and the only candidate is the `id_token`, which requires adding
  /// `openid` to the five registered scopes — and a wrong scope set is what
  /// caused the very first failure of this whole sequence. That trade is the
  /// maintainer's to make, not a default to assume.
  static String? identityFrom({required String? email}) {
    if (email == null || email.isEmpty) return null;
    return email;
  }

  /// The metadata the **request body** carries on the provisioning calls.
  ///
  /// One field, and nothing else goes in the body at all.
  ///
  /// TokenDock got this wrong three times, and each error produced
  /// `400 INVALID_ARGUMENT` with nothing pointing at the cause:
  ///
  /// 1. `pluginType: 'ANTIGRAVITY'` with `ideType: 'IDE_UNSPECIFIED'` — the two
  ///    values on the wrong fields. `IDE_UNSPECIFIED` is the *Gemini CLI* value.
  /// 2. The corrected three-field map, which sends `pluginType: GEMINI` — the
  ///    marker that declares the caller to be the Gemini CLI.
  /// 3. A `userIdentifier` field, which the endpoint does not accept at all. The
  ///    account is resolved from the bearer token.
  ///
  /// `CLIProxyAPI`, `oh-my-pi` and `cortexkit` all build this body as exactly
  /// `{metadata: {ideType: ANTIGRAVITY}}`. See also
  /// `docs/antigravity-signin-attempts.md` for the eight attempts and
  /// `docs/antigravity-cross-reference.md` for the field-by-field comparison.
  static Map<String, dynamic> get bootstrapBodyMetadata => <String, dynamic>{
    'ideType': 'ANTIGRAVITY',
  };

  /// The `User-Agent` the provisioning endpoints expect.
  ///
  /// The harness CLI form, which is what the reference sends on this path. Its
  /// `getAntigravityHeaders()` carries a full Chrome/Electron string, but that
  /// is the *desktop IDE's* identity and this is a CLI; the reference uses the
  /// harness form for `loadCodeAssist` specifically.
  ///
  /// The version is the one the reference's captured traffic used. It is a
  /// protocol constant here, not a claim about TokenDock's own version -- the
  /// string names the Antigravity client surface, in the same way any
  /// `User-Agent` names the client. It deliberately does not claim to be Chrome
  /// or Electron, because TokenDock is neither.
  static String get userAgent =>
      'antigravity/cli/$antigravityCliVersion '
      '(aidev_client; os_type=$_harnessPlatform; arch=$_harnessArch; '
      'auth_method=consumer)';

  static const String antigravityCliVersion = '1.1.24';

  static String get _harnessPlatform =>
      Platform.isWindows ? 'windows' : 'macos';

  /// `x64` on the wire, as the reference normalises it. Dart has no
  /// architecture at runtime, and this app only ships for `windows-x64`.
  static const String _harnessArch = 'amd64';

  /// The OAuth error codes that may appear in a log line.
  ///
  /// An **allow-list**, and the first attempt was a shape test — "lowercase,
  /// digits, underscore, dot, dash, at most 40 characters" — which was wrong, and
  /// the test that now guards this caught it. `sk-or-v1-0123456789abcdefghij`
  /// satisfies that pattern exactly: a lowercase hex API key is shaped like an
  /// OAuth error code, so the shape test would have logged it. A shape test asks
  /// "does this look harmless"; an allow-list asks "did I recognise this", and
  /// only the second question has an answer that is guaranteed rather than
  /// probable.
  ///
  /// RFC 6749 section 4.1.2.1 and 4.1.2.6, plus the Google extensions that turn
  /// up in practice.
  static const Set<String> _loggableErrorCodes = <String>{
    // RFC 6749 4.1.2.1, authorization errors.
    'invalid_request',
    'invalid_client',
    'invalid_grant',
    'unauthorized_client',
    'unsupported_grant_type',
    'invalid_scope',
    'access_denied',
    'unsupported_response_type',
    // RFC 6749 4.1.2.6, token errors.
    'server_error',
    'temporarily_unavailable',
    // Google extensions.
    'consent_required',
    'login_required',
    'interaction_required',
    'user_cancelled',
    'bad_verification_code',
  };

  /// The OAuth `error` code in [body], or `null` when there is none to report.
  ///
  /// Added because a failed Google login was otherwise undiagnosable from the
  /// app: the sign-in path converts every failure into a fixed, deliberately
  /// vague user-facing string, which is right for the user and useless for
  /// whoever has to fix it. The original `Error 400: invalid_scope
  /// [invalid=[cloud-platform, userinfo.email, userinfo.profile]]` could only be
  /// read off a browser error page.
  ///
  /// Only the `error` field is read, and only when it is one of
  /// [_loggableErrorCodes]. `error_description` is never touched: Google echoes
  /// the request back in it, so it is a credential-shaped channel.
  ///
  /// The result is a *diagnostic label*, never an input to control flow.
  /// Classification still runs on the status code (audit C-11), and
  /// [AntigravityHttpStatus] is still what propagates.
  static String? oauthErrorCodeOf(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final value = decoded['error'];
    if (value is! String) return null;
    final code = value.trim();
    return _loggableErrorCodes.contains(code) ? code : null;
  }

  /// The canonical Google API status in [body], or `null`.
  ///
  /// The two error shapes are not interchangeable. Google's OAuth token endpoint
  /// answers with RFC 6749's `{"error": "invalid_scope"}`; the Cloud Code
  /// Assist endpoints answer with the Google API envelope,
  /// `{"error": {"code": 400, "message": "...", "status": "INVALID_ARGUMENT"}}`,
  /// where the code is nested and the useful field is called `status`. Reading
  /// only the flat shape meant a `loadCodeAssist` rejection logged as a bare
  /// `HTTP 400` with no reason attached — which is what happened on the first
  /// live sign-in attempt.
  ///
  /// `message` is never read: it is free text that can echo the request.
  /// `status` is a closed enum, and is allow-listed for the same reason the OAuth
  /// codes are.
  static const Set<String> _loggableApiStatuses = <String>{
    'CANCELLED',
    'UNKNOWN',
    'INVALID_ARGUMENT',
    'DEADLINE_EXCEEDED',
    'NOT_FOUND',
    'ALREADY_EXISTS',
    'PERMISSION_DENIED',
    'UNAUTHENTICATED',
    'RESOURCE_EXHAUSTED',
    'FAILED_PRECONDITION',
    'ABORTED',
    'OUT_OF_RANGE',
    'UNIMPLEMENTED',
    'INTERNAL',
    'UNAVAILABLE',
    'DATA_LOSS',
  };

  /// The Google API canonical status in [body], or `null` when there is none.
  static String? apiStatusOf(String body) {
    Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    final error = decoded['error'];
    if (error is! Map) return null;
    final status = error['status'];
    if (status is! String) return null;
    return _loggableApiStatuses.contains(status) ? status : null;
  }

  /// The single label to log for a rejected request: whichever of the two error
  /// shapes [body] turned out to be.
  ///
  /// Tries the OAuth code first, then the Google API status, so the log line
  /// says why rather than just that.
  static String? rejectionReasonOf(String body) =>
      oauthErrorCodeOf(body) ?? apiStatusOf(body);

  /// One log line per protocol stage.
  ///
  /// Never receives a token, an authorization code, a verifier or a redirect URI:
  /// the call sites pass only a stage name, a status, and [oauthErrorCodeOf]'s
  /// output. Debug-only, so a release build prints nothing at all — stdout from a
  /// desktop app ends up in whatever the user pastes into a bug report.
  /// The top-level keys of a provisioning envelope, for the log.
  ///
  /// Key **names** only, never values: an envelope carries the account email and
  /// the project id, and a shape that has shifted is diagnosable from which keys
  /// appeared without disclosing what they hold.
  static List<String> _envelopeKeys(Map<String, dynamic> value) {
    final response = value['response'];
    final source = response is Map
        ? Map<String, dynamic>.from(response)
        : value;
    final keys = source.keys.toList()..sort();
    return keys;
  }

  static void _logStage(String stage, {int? status, String? reason}) {
    if (!kDebugMode) return;
    debugPrint(
      <String>[
        'Antigravity: $stage',
        if (status != null) 'HTTP $status',
        if (reason != null) '($reason)',
      ].join(' '),
    );
  }

  /// The body of an authorization-code exchange.
  ///
  /// Built in one place so the exchange and the refresh cannot drift apart on
  /// whether the secret is included — the kind of omission that passes a login
  /// test and then fails on the first expiry.
  static Map<String, String> tokenRequestFields({
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) {
    return <String, String>{
      'client_id': clientId,
      'client_secret': clientSecret,
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
    };
  }

  /// The body of a refresh exchange.
  static Map<String, String> refreshRequestFields(String refreshToken) {
    return <String, String>{
      'client_id': clientId,
      'client_secret': clientSecret,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
      // Carried over from the previous hand-built request. Google ignores it on
      // a refresh grant, and removing it would be a change with no reason behind
      // it in a path that only runs on expiry.
      'access_type': accessType,
    };
  }

  @override
  String get id => 'antigravity';
  @override
  String get name => 'Antigravity';
  @override
  AuthKind get authKind => AuthKind.oauth;
  @override
  Map<String, String> buildAuthHeader(String secret) => {
    'Authorization': 'Bearer ${_credential(secret)['accessToken'] ?? secret}',
  };
  @override
  RefreshableCredential? refreshableCredential(String secret) =>
      AntigravityRefreshableCredential(this, secret);

  Future<AntigravityOAuthLoginResult> loginWithLoopback(
    Connection connection, {
    Future<void>? cancellation,
  }) async {
    final session = await OAuthLoopback.start();
    final verifier = newCodeVerifier();
    final state = newState();
    final url = session.launchUrl(
      Uri.parse(authorizationEndpoint),
      parameters: {
        'client_id': clientId,
        'response_type': 'code',
        'scope': scopeParameter,
        'code_challenge': buildCodeChallenge(verifier),
        'code_challenge_method': 'S256',
        'state': state,
        'access_type': accessType,
        // Forces the consent screen so Google actually issues a refresh token.
        'prompt': prompt,
      },
    );
    // Logged before the browser opens, and deliberately without the URL: it
    // carries the client id, the state and the code challenge. What matters for
    // diagnosis is *which* stage the flow reached, and a silent login that
    // produced no log line at all was indistinguishable from a login that was
    // never started.
    _logStage('sign-in started, waiting for the browser round trip');
    final delivered = session.waitForCode(state);
    var cancelRequested = false;
    final cancellationSignal = cancellation?.then<bool>((_) async {
      cancelRequested = true;
      await session.close();
      return true;
    });
    try {
      if (cancellationSignal != null) {
        await Future.any<Object?>([
          launchExternalBrowser(url),
          cancellationSignal,
        ]);
        try {
          final outcome = await Future.any<Object?>([
            delivered,
            cancellationSignal,
          ]);
          final result = outcome as OAuthLoopbackResult;
          _logStage('authorization code received from the loopback listener');
          return await login(
            connection,
            code: result.code,
            codeVerifier: verifier,
            redirectUri: session.redirectUri.toString(),
          );
        } catch (_) {
          if (cancelRequested) {
            _logStage('sign-in cancelled by the user');
            throw const AntigravityLoginCancelled();
          }
          rethrow;
        }
      }
      await launchExternalBrowser(url);
      final result = await delivered;
      _logStage('authorization code received from the loopback listener');
      return await login(
        connection,
        code: result.code,
        codeVerifier: verifier,
        redirectUri: session.redirectUri.toString(),
      );
    } finally {
      await session.close();
    }
  }

  Future<AntigravityOAuthLoginResult> login(
    Connection connection, {
    required String code,
    required String codeVerifier,
    required String redirectUri,
  }) async {
    final token = await _postForm(
      Uri.parse(tokenEndpoint),
      tokenRequestFields(
        code: code,
        codeVerifier: codeVerifier,
        redirectUri: redirectUri,
      ),
      stage: 'token exchange',
    );
    final access = (token['access_token'] ?? '').toString().trim();
    if (access.isEmpty) {
      _logStage('token exchange returned no access token', status: 200);
      throw StateError('OAuth access token missing');
    }
    // The exchange succeeded. Logged explicitly, because every subsequent step
    // is a provisioning question rather than an authentication one, and the
    // difference decides where a failure is even possible.
    _logStage('token exchange succeeded; asking Cloud Code to provision');
    final refresh = (token['refresh_token'] ?? '').toString().trim();
    if (refresh.isEmpty) {
      // Named separately because it is the `prompt=consent` failure: Google
      // reused a grant and issued no refresh token, so the *next* login breaks
      // here while pointing at the token exchange rather than at the
      // authorization request that caused it.
      _logStage(
        'token exchange returned no refresh token (consent?)',
        status: 200,
      );
      throw StateError('OAuth refresh token missing');
    }
    // Past this point the token exchange has succeeded, so every remaining step
    // is a provisioning question rather than an authentication one. Each one
    // used to be able to fail with *no log line at all*, which is how a live
    // attempt could stop dead after the authorization code and leave nothing to
    // diagnose. The step names are logged as they are entered.

    // The email, from the only place it exists at this point. Google's token
    // response carries no account fields at all -- reading the identity from it
    // is what made the seventh live attempt fail with "OAuth account identity
    // missing", and it is why three of the five reference implementations call a
    // userinfo endpoint instead.
    final email = await _fetchAccountEmail(access);

    // A previously stored identity, when reconnecting, so a reconnecting
    // connection keeps the identity it was bound to rather than re-deriving one
    // from whatever the account reports now.
    var identity =
        connection.identityKey ??
        AntigravitySelectedAccountGuard.identityOf(token);

    var provisioning = await _loadCodeAssist(
      access,
      identity: email,
      projectId: _providerData(connection)['projectId']?.toString(),
    );
    _logStage('loadCodeAssist returned provisioning data');

    // The provisioning response carries no account fields at all -- see
    // [identityFrom] -- so there is nothing here to cross-check the email
    // against. The identity is the email, and the guard below degrades to
    // accepting a body that simply has no identity to compare.
    if (identity == null && email != null) {
      identity = identityFrom(email: email);
    }
    _logStage('identity resolved');
    _requireProvisioningIdentity(provisioning, identity);
    _logStage('account guard passed');
    var project = _projectOf(provisioning);
    _logStage('project read from the response');
    if (_tier(provisioning) == null) {
      _logStage('no tier on the account, onboarding');
      provisioning = await _onboardUser(
        access,
        identity: email,
        projectId: project,
      );
      _requireProvisioningIdentity(provisioning, identity);
      project = _projectOf(provisioning);
    }
    // Which keys the body actually carried, so a shape that shifted is visible
    // without logging any of their values.
    _logStage('provisioning keys: ${_envelopeKeys(provisioning).join(',')}');
    if (project == null || project.isEmpty) {
      // No fallback project, unlike the reference, and the difference is
      // deliberate.
      //
      // `cortexkit/antigravity-auth` hardcodes `rising-fact-p41fc` for accounts
      // the endpoint provisions no project for. That project is *theirs*: it
      // belongs to the operator of that client. Copying the id into a
      // distributed app would point a user's requests -- and their quota
      // reporting -- at a Google Cloud project that is not theirs and that they
      // have no relationship with. A shared hardcoded project is a resource
      // that works for one deployer and misattributes for everyone else.
      //
      // So a projectless account is reported as needing onboarding, which is the
      // truthful state: there is no project to use, and the user has to create
      // one. The cost is that business and workspace accounts cannot connect
      // until they do; the alternative would be silently billing someone else's
      // project.
      _logStage(
        'no project provisioned for this account; onboarding is required',
      );
      throw const AntigravityOnboardingRequired();
    }
    final identityKey =
        identity ??
        AntigravitySelectedAccountGuard.identityOf(provisioning) ??
        identityFrom(email: email);
    if (identityKey == null) {
      // Only reachable when userinfo failed *and* the token response carried no
      // stored identity. The credential itself works at this point -- the
      // provisioning calls above succeeded with it -- so this is reported as
      // needing onboarding rather than as a failed sign-in, because the user has
      // something they can actually do about it.
      _logStage('no account identity available from userinfo or provisioning');
      throw const AntigravityOnboardingRequired();
    }
    final secret = jsonEncode({
      'accessToken': access,
      'refreshToken': token['refresh_token'],
      'expiresAt': _expiry(token)?.toIso8601String(),
      'identityKey': identityKey,
      'projectId': project,
      'tier': _tier(provisioning),
    });
    await _secretStore?.write(connection.credentialRef, secret);
    // The one line that proves a login worked, which nothing did before. The
    // project id and tier are not credentials; the tokens that were just written
    // are, and neither appears here.
    _logStage('sign-in complete (tier ${_tier(provisioning) ?? 'unknown'})');
    return AntigravityOAuthLoginResult(
      secret: secret,
      identityKey: identityKey,
      projectId: project,
      tier: _tier(provisioning),
    );
  }

  Future<Map<String, dynamic>> _loadCodeAssist(
    String access, {
    String? identity,
    String? projectId,
  }) async {
    AntigravityTransportFailure? transportFailure;
    for (final host in loadEndpointOrder) {
      try {
        final payload = <String, dynamic>{
          // One field only. See [bootstrapBodyMetadata]: the full three-field map
          // in the body declares the caller to be the Gemini CLI, and the
          // endpoint answers INVALID_ARGUMENT to that.
          'metadata': Map<String, dynamic>.of(bootstrapBodyMetadata),
          if (projectId case final project? when project.isNotEmpty)
            'cloudaicompanionProject': project,
        };
        // Deliberately no `userIdentifier`. The account is resolved from the
        // bearer token; `CLIProxyAPI` and `cortexkit` both send `{metadata}`
        // alone. TokenDock sent one and the endpoint answered 400
        // INVALID_ARGUMENT, so the field is not merely redundant here -- it is
        // rejected. The identity is still checked, against what the response
        // says, after this call returns.
        final result = await _postJson(
          Uri.parse('$host/v1internal:loadCodeAssist'),
          payload,
          bearer: access,
          stage: 'loadCodeAssist',
        );
        if (_hasProvisioning(result)) return result;
        // The silent one, and where a live sign-in actually stopped. Key *names*
        // only, never values: the body is the account's own provisioning data.
        _logStage(
          '$host answered 200 with no project and no tier; '
          'top-level keys: ${_envelopeKeys(result).join(',')}',
        );
        throw const AntigravitySchemaChanged();
      } on AntigravityTransportFailure catch (error) {
        transportFailure = error;
      }
    }
    if (transportFailure != null) {
      _logStage('loadCodeAssist failed on every host, transport failure');
      throw transportFailure;
    }
    _logStage('loadCodeAssist returned no provisioning at all');
    throw StateError('loadCodeAssist unavailable');
  }

  Future<Map<String, dynamic>> _onboardUser(
    String access, {
    String? identity,
    String? projectId,
  }) async {
    final payload = <String, dynamic>{
      'metadata': Map<String, dynamic>.of(bootstrapBodyMetadata),
      if (projectId case final project? when project.isNotEmpty)
        'cloudaicompanionProject': project,
    };
    // No `userIdentifier` here either, for the same reason as loadCodeAssist.
    final result = await _postJson(
      Uri.parse('$prodHost/v1internal:onboardUser'),
      payload,
      bearer: access,
      stage: 'onboardUser',
    );
    if (!_hasProvisioning(result)) {
      _logStage(
        'onboardUser answered 200 with no project and no tier; '
        'top-level keys: ${_envelopeKeys(result).join(',')}',
      );
      throw const AntigravitySchemaChanged();
    }
    return result;
  }

  static void _requireProvisioningIdentity(
    Map<String, dynamic> payload,
    String? expected,
  ) {
    if (expected == null || expected.isEmpty) return;
    if (AntigravitySelectedAccountGuard.identityOf(payload) != expected) {
      throw StateError('Account mismatch');
    }
  }

  static void _requireQuotaSchema(
    Map<String, dynamic> payload, {
    bool legacy = false,
  }) {
    final root = payload['response'] is Map
        ? Map<String, dynamic>.from(payload['response'] as Map)
        : payload;
    if (root.containsKey('groups')) {
      final groups = root['groups'];
      if (groups is! List || groups.isEmpty) {
        throw const AntigravitySchemaChanged();
      }
      for (final raw in groups) {
        if (raw is! Map) throw const AntigravitySchemaChanged();
        final group = Map<String, dynamic>.from(raw);
        final groupId = (group['groupId'] ?? group['id'])?.toString() ?? '';
        final buckets = group['buckets'];
        if (groupId.isEmpty || buckets is! List || buckets.isEmpty) {
          throw const AntigravitySchemaChanged();
        }
        for (final rawBucket in buckets) {
          if (rawBucket is! Map) throw const AntigravitySchemaChanged();
          final bucket = Map<String, dynamic>.from(rawBucket);
          final bucketId =
              (bucket['bucketId'] ?? bucket['id'])?.toString() ?? '';
          if (bucket.containsKey('remaining') && bucket['remaining'] is! Map) {
            throw const AntigravitySchemaChanged();
          }
          final remaining = bucket['remaining'] is Map
              ? Map<String, dynamic>.from(bucket['remaining'] as Map)
              : bucket;
          final fraction = remaining['remainingFraction'];
          final reset =
              bucket['resetTime'] ??
              bucket['resetAt'] ??
              remaining['resetTime'] ??
              remaining['resetAt'];
          if (bucketId.isEmpty ||
              (fraction != null && !_validFraction(fraction)) ||
              (reset != null && !_validReset(reset)) ||
              (fraction == null && reset == null)) {
            throw const AntigravitySchemaChanged();
          }
        }
      }
      return;
    }
    if (root.containsKey('quotaInfo')) {
      final quota = root['quotaInfo'];
      if (quota is! Map || quota.isEmpty) {
        throw const AntigravitySchemaChanged();
      }
      for (final raw in quota.values) {
        if (raw is! Map) throw const AntigravitySchemaChanged();
        final value = Map<String, dynamic>.from(raw);
        final fraction = value['remainingFraction'];
        final reset = value['resetTime'] ?? value['resetAt'];
        if (fraction != null && !_validFraction(fraction)) {
          throw const AntigravitySchemaChanged();
        }
        if (reset != null && !_validReset(reset)) {
          throw const AntigravitySchemaChanged();
        }
        if (fraction == null && reset == null) {
          throw const AntigravitySchemaChanged();
        }
      }
      return;
    }
    if (root.containsKey('availability')) {
      final availability = root['availability'];
      if (availability is! Map || availability.isEmpty) {
        throw const AntigravitySchemaChanged();
      }
      if (availability.values.any(
        (value) => value is! num && double.tryParse('$value') == null,
      )) {
        throw const AntigravitySchemaChanged();
      }
      return;
    }
    throw const AntigravitySchemaChanged();
  }

  static bool _validFraction(dynamic value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite && parsed >= 0 && parsed <= 1;
  }

  static bool _validReset(dynamic value) {
    if (value is num) return true;
    final text = value.toString().trim();
    return text.isNotEmpty &&
        (DateTime.tryParse(text) != null || int.tryParse(text) != null);
  }

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    var testSecret = secret;
    final credential = refreshableCredential(testSecret);
    final expiresAt = credential?.expiresAt;
    if (credential != null &&
        expiresAt != null &&
        expiresAt.isBefore(
          DateTime.now().toUtc().add(credential.refreshLead),
        )) {
      testSecret = await credential.refresh(testSecret);
    }
    final snapshot = await fetch(connection, testSecret);
    final replacementSecret = testSecret == secret ? null : testSecret;
    return snapshot.error == null
        ? TestResult.success(
            quotas: snapshot.quotas,
            plan: connection.plan,
            replacementSecret: replacementSecret,
          )
        : TestResult.failure(
            error: snapshot.error!,
            replacementSecret: replacementSecret,
          );
  }

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    // A stored credential that cannot be parsed is reported as a snapshot
    // rather than thrown, so a corrupt secure-storage read surfaces as a
    // readable connection error instead of an escaping exception and an opaque
    // 401 (audit C-10).
    final Map<String, dynamic> credential;
    try {
      credential = _credential(secret);
    } on StateError {
      return _error(
        connection.id,
        credentialUnreadable,
        ProviderFailureCause.invalidCredential,
      );
    }
    final project =
        _providerData(connection)['projectId']?.toString() ??
        credential['projectId']?.toString();
    if (project == null || project.isEmpty) {
      return _error(
        connection.id,
        'onboarding_required',
        ProviderFailureCause.onboardingRequired,
      );
    }
    final expected =
        credential['identityKey']?.toString() ?? connection.identityKey;
    try {
      for (final host in const [prodHost, dailyHost]) {
        try {
          final payload = await _postJson(
            Uri.parse('$host/v1internal:retrieveUserQuotaSummary'),
            {
              'project': project,
              'userIdentifier': expected,
              'metadata': Map<String, dynamic>.of(bootstrapBodyMetadata),
            },
            bearer: credential['accessToken']?.toString(),
            stage: 'retrieveUserQuotaSummary',
          );
          if (!const AntigravitySelectedAccountGuard().accepts(
            expected: expected,
            payload: payload,
          )) {
            return _error(
              connection.id,
              'account_mismatch',
              ProviderFailureCause.accountMismatch,
            );
          }
          _requireQuotaSchema(payload);
          return AntigravityLocalReader.parseQuotaSummary(
            body: jsonEncode(payload),
            connectionId: connection.id,
          );
        } on AntigravityHttpStatus catch (error) {
          // A 404 on one host means the daily host may still serve it.
          if (error.statusCode != 404) rethrow;
        }
      }
      return await _fetchLegacy(connection, credential, project, expected);
    } on AntigravitySchemaChanged {
      return _error(
        connection.id,
        'quota_source_changed',
        ProviderFailureCause.quotaSourceChanged,
      );
    } on AntigravityTransientFailure catch (error) {
      final fetchedAt = DateTime.now().toUtc();
      return ProviderSnapshot(
        connectionId: connection.id,
        status: ConnectionStatus.warning,
        quotas: const [],
        balance: null,
        fetchedAt: fetchedAt,
        error: error.toString(),
        cooldownUntil:
            error.cooldownUntil ?? fetchedAt.add(const Duration(minutes: 1)),
        failureCause: ProviderFailureCause.transient,
      );
    } on AntigravityTransportFailure {
      return _error(connection.id, 'transport', ProviderFailureCause.transport);
    } on AntigravityHttpStatus catch (error) {
      // Classified by status, never by matching the message text.
      if (error.statusCode == 403) {
        return _error(
          connection.id,
          'forbidden',
          ProviderFailureCause.forbidden,
        );
      }
      if (error.statusCode == 401) {
        return _error(
          connection.id,
          'bare_401',
          ProviderFailureCause.invalidCredential,
        );
      }
      return _error(
        connection.id,
        AntigravityHttpStatus(error.statusCode).toString(),
        null,
      );
    } on StateError catch (error) {
      final normalized = error.toString().toLowerCase();
      if (normalized.contains('invalid_grant')) {
        return _error(
          connection.id,
          'invalid_grant',
          ProviderFailureCause.invalidCredential,
        );
      }
      return _error(
        connection.id,
        normalized.replaceFirst('bad state: ', ''),
        null,
      );
    } catch (_) {
      return _error(connection.id, 'error', null);
    }
  }

  Future<ProviderSnapshot> _fetchLegacy(
    Connection connection,
    Map<String, dynamic> credential,
    String project,
    String? expected,
  ) async {
    final modelsEnvelope = await _postJson(
      Uri.parse('$prodHost/v1internal:fetchAvailableModels'),
      {
        'project': project,
        'userIdentifier': expected,
        'metadata': Map<String, dynamic>.of(bootstrapBodyMetadata),
      },
      bearer: credential['accessToken']?.toString(),
      stage: 'fetchAvailableModels',
    );
    final quotaEnvelope = await _postJson(
      Uri.parse('$prodHost/v1internal:retrieveUserQuota'),
      {
        'project': project,
        'userIdentifier': expected,
        'metadata': Map<String, dynamic>.of(bootstrapBodyMetadata),
      },
      bearer: credential['accessToken']?.toString(),
      stage: 'retrieveUserQuota',
    );
    final models = _unwrapEnvelope(modelsEnvelope);
    final quota = _unwrapEnvelope(quotaEnvelope);
    if (!const AntigravitySelectedAccountGuard().accepts(
      expected: expected,
      payload: quota,
    )) {
      return _error(
        connection.id,
        'account_mismatch',
        ProviderFailureCause.accountMismatch,
      );
    }
    final quotaInfo = _mergeLegacyModels(quota, models);
    _requireQuotaSchema({'quotaInfo': quotaInfo}, legacy: true);
    return AntigravityLocalReader.parseQuotaSummary(
      body: jsonEncode({
        'response': {
          'quotaInfo': quotaInfo,
          'accountEmail': quota['accountEmail'],
          'accountId': quota['accountId'],
        },
      }),
      connectionId: connection.id,
    );
  }

  static Map<String, dynamic> _unwrapEnvelope(Map<String, dynamic> value) =>
      value['response'] is Map
      ? Map<String, dynamic>.from(value['response'] as Map)
      : value;

  /// True when a provisioning body carries usable data, enveloped or not.
  ///
  /// **`loadCodeAssist` does not wrap its response in a `response` envelope.**
  /// It returns `cloudaicompanionProject` and `currentTier` at the top level.
  /// TokenDock required `body['response'] is Map` and threw
  /// `AntigravitySchemaChanged` otherwise — and that throw had no log line, so a
  /// live sign-in stopped dead there and the log simply ended at the
  /// authorization code.
  ///
  /// Both shapes are accepted, because the enveloped one is what `onboardUser`
  /// and the quota endpoints return and the two were never distinguished.
  static bool _hasProvisioning(Map<String, dynamic> body) {
    if (body['response'] is Map) return true;
    return body['cloudaicompanionProject'] != null ||
        body['currentTier'] != null ||
        body['projectId'] != null ||
        body['project'] != null;
  }

  /// The project id, in either of the two forms the endpoint returns.
  ///
  /// `cortexkit` accepts `cloudaicompanionProject` as a plain string *and* as an
  /// object with an `id`. A client that reads only the string form reports "no
  /// project" for every account served the object form, which is a silent
  /// failure that looks like an ineligible account.
  static String? _projectOf(Map<String, dynamic> body) {
    final raw = _unwrapEnvelope(body)['cloudaicompanionProject'];
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is Map) {
      final id = raw['id'];
      if (id is String && id.isNotEmpty) return id;
    }
    final unwrapped = _unwrapEnvelope(body);
    final flat = unwrapped['projectId'] ?? unwrapped['project'];
    if (flat is String && flat.isNotEmpty) return flat;
    return null;
  }

  static Map<String, dynamic> _mergeLegacyModels(
    Map<String, dynamic> quota,
    Map<String, dynamic> models,
  ) {
    final quotaInfo = _map(quota['quotaInfo'] ?? quota);
    final rawModels = models['models'] ?? models['availableModels'];
    if (rawModels is List) {
      for (final raw in rawModels) {
        if (raw is! Map) continue;
        final model = Map<String, dynamic>.from(raw);
        final name = (model['name'] ?? model['model'] ?? model['id'])
            ?.toString();
        final nested = _map(model['quotaInfo']);
        if (name != null &&
            name.isNotEmpty &&
            (nested.isEmpty || _isDirectQuotaObject(nested))) {
          _mergeLegacyQuota(quotaInfo, name, nested.isEmpty ? model : nested);
        } else {
          nested.forEach(
            (key, value) => _mergeLegacyQuota(quotaInfo, key, value),
          );
        }
      }
    } else {
      for (final entry in _map(rawModels).entries) {
        _mergeLegacyQuota(quotaInfo, entry.key, entry.value);
      }
    }
    return quotaInfo;
  }

  static bool _isDirectQuotaObject(Map<String, dynamic> value) =>
      value.containsKey('remainingFraction') ||
      value.containsKey('remaining') ||
      value.containsKey('resetTime') ||
      value.containsKey('resetAt');

  static void _mergeLegacyQuota(
    Map<String, dynamic> quotaInfo,
    String key,
    dynamic raw,
  ) {
    final value = _map(raw);
    if (value.isEmpty) return;
    final existing = _map(quotaInfo[key]);
    if (existing.isEmpty) {
      quotaInfo[key] = value;
      return;
    }
    final currentFraction = _quotaFraction(existing);
    final nextFraction = _quotaFraction(value);
    if (currentFraction == null ||
        (nextFraction != null && nextFraction < currentFraction)) {
      quotaInfo[key] = value;
    }
  }

  static double? _quotaFraction(Map<String, dynamic> value) {
    final raw =
        value['remainingFraction'] ??
        _map(value['remaining'])['remainingFraction'];
    if (raw is num) return raw.toDouble();
    return double.tryParse(raw?.toString() ?? '');
  }

  /// Exchanges [currentSecret] for a fresh access/refresh pair.
  ///
  /// A rotating refresh token is single-use, so concurrent callers presenting
  /// the same token must not each hit `/token`: the loser receives
  /// `invalid_grant`, and because Google's `/revoke` invalidates the whole
  /// grant, revoking on that signal would destroy the token the winner just
  /// obtained. Exchanges are therefore coalesced per presented token, and the
  /// chain is revoked only when there is positive evidence the token was
  /// already rotated out (audit C-04).
  Future<String> refresh(String currentSecret) {
    final inFlight = _exchangeInFlight[currentSecret];
    if (inFlight != null) return inFlight;

    final future = _exchange(currentSecret);
    _exchangeInFlight[currentSecret] = future;
    return future.whenComplete(() {
      if (identical(_exchangeInFlight[currentSecret], future)) {
        _exchangeInFlight.remove(currentSecret);
      }
    });
  }

  Future<String> _exchange(String currentSecret) async {
    final value = _credential(currentSecret);
    final refreshToken = value['refreshToken']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) {
      throw StateError('refresh token missing');
    }
    // Sampled before the request: a token rotated out by a *concurrent* winner
    // is not evidence that this caller is an attacker replaying a stolen one.
    final reused = _rotatedRefreshTokens.containsKey(refreshToken);
    try {
      final response = await _postForm(
        Uri.parse(tokenEndpoint),
        // Same client, same secret requirement. A refresh that omits the secret
        // fails on the first expiry, long after the login that would have
        // revealed the problem.
        refreshRequestFields(refreshToken),
        stage: 'token refresh',
      );
      if (response['access_token'] == null) throw StateError('invalid_grant');
      final replacement = response['refresh_token']?.toString();
      if (replacement != null &&
          replacement.isNotEmpty &&
          replacement != refreshToken) {
        _rememberRotated(refreshToken);
      }
      return jsonEncode({
        ...value,
        'accessToken': response['access_token'],
        'refreshToken': replacement ?? refreshToken,
        'expiresAt': _expiry(response)?.toIso8601String(),
      });
    } on StateError catch (error) {
      if (!error.toString().contains('invalid_grant')) rethrow;
      if (reused) await _revokeBestEffort(refreshToken);
      rethrow;
    } on AntigravityTransportFailure {
      if (reused) await _revokeBestEffort(refreshToken);
      rethrow;
    }
  }

  /// Records a rotated-out token, evicting the oldest once [cap] is reached.
  ///
  /// The ledger is a bounded window, not permanent storage: it holds recent
  /// refresh tokens in plaintext for the life of the process, so an unbounded
  /// set would grow for as long as the widget stays resident. A token evicted
  /// past the window is treated as a first sighting, which fails open towards
  /// keeping the user's account rather than towards revoking it.
  void _rememberRotated(String refreshToken) {
    _rotatedRefreshTokens[refreshToken] = true;
    while (_rotatedRefreshTokens.length > maxRememberedRotatedRefreshTokens) {
      _rotatedRefreshTokens.remove(_rotatedRefreshTokens.keys.first);
    }
  }

  /// Upper bound on remembered rotated-out refresh tokens.
  static const int maxRememberedRotatedRefreshTokens = 32;

  /// Size of the rotated-token window. Exposed for the bound assertion.
  @visibleForTesting
  int get rememberedRotatedRefreshTokenCount => _rotatedRefreshTokens.length;

  Future<void> _revokeBestEffort(String refreshToken) async {
    try {
      await _http.post(
        Uri.parse(revokeEndpoint),
        headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
        body: 'token=$refreshToken',
      );
    } catch (_) {}
  }

  Future<Map<String, dynamic>> _postForm(
    Uri uri,
    Map<String, dynamic> body, {
    String stage = 'request',
  }) async {
    return _post(
      uri,
      stage: stage,
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
      body: Uri(
        queryParameters: body.map((key, value) => MapEntry(key, '$value')),
      ).query,
    );
  }

  Future<Map<String, dynamic>> _postJson(
    Uri uri,
    Map<String, dynamic> body, {
    String? bearer,
    String stage = 'request',
  }) {
    // Exactly the four headers `CLIProxyAPI` sets on a Cloud Code call, and
    // nothing else.
    //
    // TokenDock also sent `Client-Metadata` and `X-Goog-Api-Client`, on the
    // reading that both were required. `CLIProxyAPI`, `oh-my-pi` and `9router`
    // send neither for this call, and the endpoint answered
    // `400 INVALID_ARGUMENT` while they were present. `cortexkit` does send
    // `Client-Metadata` -- and is the one implementation that does not work
    // against a live account without its own hardcoded project id, so it is not
    // evidence that the header is accepted.
    //
    // A header only one of six implementations sends is a fingerprint, not a
    // contract. The cross-reference already flagged it as unproven; it turned
    // out to be the thing the endpoint rejects.
    return _post(
      uri,
      stage: stage,
      headers: <String, String>{
        if (bearer != null && bearer.isNotEmpty)
          'Authorization': 'Bearer $bearer',
        'Accept': '*/*',
        'Content-Type': 'application/json',
        'User-Agent': userAgent,
      },
      body: jsonEncode(body),
    );
  }

  /// A GET, sharing [_\u0063ommonExchange]'s classification and retry ladder.
  ///
  /// The userinfo endpoint is a GET, so it cannot go through [_\u0070ost]. The
  /// classification is identical to every other call, so it is factored out
  /// rather than duplicated -- a second copy is how the two error shapes started
  /// diverging in the first place.
  Future<Map<String, dynamic>> _get(
    Uri uri, {
    required Map<String, String> headers,
    String stage = 'request',
  }) {
    return _commonExchange(
      uri,
      stage: stage,
      send: () => _http.get(uri, headers: headers),
    );
  }

  Future<Map<String, dynamic>> _post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
    String stage = 'request',
  }) {
    return _commonExchange(
      uri,
      stage: stage,
      send: () => _http.post(uri, headers: headers, body: body),
    );
  }

  /// The single place a Cloud Code or Google response is classified.
  ///
  /// One implementation on purpose: the retry ladder, the status classification
  /// and the logging were previously spread across the callers, and a request
  /// shape that behaves differently from its neighbours is exactly how the
  /// error-shape divergence started.
  Future<Map<String, dynamic>> _commonExchange(
    Uri uri, {
    required String stage,
    required Future<AntigravityOAuthHttpResponse> Function() send,
  }) async {
    for (var attempt = 0; attempt < _maximumTransientAttempts; attempt++) {
      AntigravityOAuthHttpResponse response;
      try {
        response = await send();
      } catch (error) {
        _logStage('$stage transport failure on attempt ${attempt + 1}');
        throw AntigravityTransportFailure(error);
      }
      if (response.statusCode == 429 || response.statusCode >= 500) {
        final now = DateTime.now().toUtc();
        final retryAt = _parseRetryAfter(response.retryAfter, now);
        if (attempt + 1 < _maximumTransientAttempts) {
          final floor = retryAt == null
              ? Duration.zero
              : retryAt.difference(now).isNegative
              ? Duration.zero
              : retryAt.difference(now);
          await _sleep(retryDelay(floor, attempt, random: _random));
          continue;
        }
        // Logged only on the last attempt, so the line reports what actually
        // happened rather than implying the request was rejected once.
        _logStage(
          '$stage gave up after ${attempt + 1} attempts',
          status: response.statusCode,
        );
        throw AntigravityTransientFailure(
          response.statusCode,
          cooldownUntil: retryAt ?? now.add(const Duration(minutes: 1)),
        );
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (response.statusCode == 400 &&
            response.body.contains('invalid_grant')) {
          // The token endpoint reports this in the body; it has no status of
          // its own that distinguishes it from a transient rejection.
          _logStage(
            '$stage rejected',
            status: response.statusCode,
            reason: rejectionReasonOf(response.body),
          );
          throw StateError('invalid_grant');
        }
        // The one line that makes a login failure diagnosable. `reason` is a
        // single allow-listed enum from one of two known error shapes, so this
        // says *why* the endpoint said no without ever putting the request or
        // the response in the log.
        _logStage(
          '$stage rejected',
          status: response.statusCode,
          reason: rejectionReasonOf(response.body),
        );
        // Carries the status so failure classification never has to parse
        // message text (audit C-11).
        throw AntigravityHttpStatus(response.statusCode);
      }
      try {
        return _map(jsonDecode(response.body));
      } catch (_) {
        _logStage(
          '$stage returned a body that is not the expected shape',
          status: response.statusCode,
        );
        throw const AntigravitySchemaChanged();
      }
    }
    throw StateError('HTTP retry budget exhausted');
  }

  static DateTime? _parseRetryAfter(String? value, DateTime now) {
    final header = value?.trim();
    if (header == null || header.isEmpty) return null;
    final seconds = int.tryParse(header);
    if (seconds != null) {
      return seconds > 0 ? now.add(Duration(seconds: seconds)) : null;
    }
    try {
      final retryAt = HttpDate.parse(header).toUtc();
      return retryAt.isAfter(now) ? retryAt : null;
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic> _map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static Map<String, dynamic> _providerData(Connection c) {
    try {
      return c.providerData == null
          ? <String, dynamic>{}
          : _map(jsonDecode(c.providerData!));
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  // `_project` is gone: it read only the enveloped shape and only the string
  // form of the project, and is replaced by `_projectOf`. See that method for
  // the two response shapes and the two project shapes it has to accept.

  /// The tier, from either response shape.
  ///
  /// Read through [_unwrapEnvelope] for the same reason [_projectOf] exists: a
  /// bare `loadCodeAssist` body carries `currentTier` at the top level, and
  /// reading only the enveloped shape reported "no tier" for exactly those
  /// accounts -- which sent them down the onboarding path unnecessarily.
  static String? _tier(Map<String, dynamic> v) {
    final r = _unwrapEnvelope(v);
    final t = _map(r['currentTier']);
    return (t['id'] ?? t['name'] ?? r['tier'])?.toString();
  }

  static DateTime? _expiry(Map<String, dynamic> v) {
    final s = v['expires_in'];
    return s is num
        ? DateTime.now().toUtc().add(Duration(seconds: s.toInt()))
        : null;
  }

  /// Marker for a stored credential that could not be parsed.
  static const String credentialUnreadable = 'credential unreadable';

  /// Parses a stored credential blob.
  ///
  /// Strict by design: a value that is not a JSON object is a corrupt,
  /// truncated or foreign secure-storage read, and must be reported rather
  /// than used. The previous implementation caught the parse failure and
  /// returned `{'accessToken': raw}`, which turned garbage into a bearer token
  /// and surfaced an opaque 401 instead of "this credential is unreadable"
  /// (audit C-10).
  static Map<String, dynamic> _credential(String raw) =>
      parseStoredCredential(raw);

  ProviderSnapshot _error(
    String id,
    String error,
    ProviderFailureCause? cause,
  ) => ProviderSnapshot(
    connectionId: id,
    status: cause == ProviderFailureCause.invalidCredential
        ? ConnectionStatus.authError
        : ConnectionStatus.error,
    quotas: const [],
    balance: null,
    fetchedAt: DateTime.now().toUtc(),
    error: error,
    failureCause: cause,
  );

  /// First retry honors the provider floor; later retryable attempts use Full
  /// Jitter. This helper is intentionally separate from non-retryable errors.
  static Duration retryDelay(
    Duration retryAfterFloor,
    int attempt, {
    Random? random,
  }) {
    if (attempt <= 0) return retryAfterFloor;
    final capSeconds = min(60, 1 << min(attempt, 6));
    final jitterMs = (random ?? Random.secure()).nextInt(capSeconds * 1000 + 1);
    return Duration(milliseconds: jitterMs);
  }
}

class AntigravityRefreshableCredential implements RefreshableCredential {
  AntigravityRefreshableCredential(this.provider, this.secret);
  final AntigravityOAuthProvider provider;
  String secret;
  @override
  DateTime? get expiresAt =>
      DateTime.tryParse(_credential(secret)['expiresAt']?.toString() ?? '');
  @override
  Duration get refreshLead => const Duration(minutes: 1);
  @override
  Future<String> refresh(String currentSecret) async {
    secret = await provider.refresh(currentSecret);
    return secret;
  }

  static Map<String, dynamic> _credential(String raw) =>
      parseStoredCredentialOrEmpty(raw);
}

/// Parses a stored credential blob, or throws [StateError] carrying
/// [AntigravityOAuthProvider.credentialUnreadable].
///
/// Audit C-10: the previous implementation caught the parse failure and
/// returned `{'accessToken': raw}`, which turned garbage into a bearer token and
/// surfaced an opaque 401 instead of "this credential is unreadable".
Map<String, dynamic> parseStoredCredential(String raw) {
  if (raw.trim().isEmpty) {
    throw StateError(AntigravityOAuthProvider.credentialUnreadable);
  }
  try {
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  } catch (_) {
    throw StateError(AntigravityOAuthProvider.credentialUnreadable);
  }
}

/// The same parse, degrading to an empty map.
///
/// Used only by the refresh path, where an unreadable blob has nothing sensible
/// to refresh and the caller already treats a missing expiry as "no expiry".
/// The two behaviours used to live in two private copies of the same function,
/// which is how the strict one could be tightened (C-10) while the lenient one
/// silently kept swallowing (audit C-27).
Map<String, dynamic> parseStoredCredentialOrEmpty(String raw) {
  try {
    return parseStoredCredential(raw);
  } catch (_) {
    return <String, dynamic>{};
  }
}

/// Production HTTP transport for the Antigravity OAuth surface.
///
/// Every await is bounded and the response body is capped. Without this a hung
/// socket left the connection's in-flight future pending forever, and
/// `RefreshService` chains every later refresh and probe behind that future
/// (audit C-01). Bounds match the sibling OpenRouter transport: 10s to connect,
/// 15s for the response.
class AntigravityHttpClientRunner implements AntigravityOAuthHttpRunner {
  AntigravityHttpClientRunner({
    this.connectionTimeout = defaultConnectionTimeout,
    this.responseTimeout = defaultResponseTimeout,
    this.maxResponseBytes = defaultMaxResponseBytes,
  });

  static const Duration defaultConnectionTimeout = Duration(seconds: 10);
  static const Duration defaultResponseTimeout = Duration(seconds: 15);

  /// Token, provisioning and quota envelopes are small JSON documents. A cap
  /// turns an unexpectedly large body into a failure instead of an
  /// out-of-memory condition on an always-resident desktop widget.
  static const int defaultMaxResponseBytes = 256 * 1024;

  final Duration connectionTimeout;
  final Duration responseTimeout;
  final int maxResponseBytes;

  @override
  Future<AntigravityOAuthHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) {
    return _send(uri, headers: headers, method: 'POST', body: body);
  }

  @override
  Future<AntigravityOAuthHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) {
    return _send(uri, headers: headers, method: 'GET');
  }

  /// One request path for both methods.
  ///
  /// Shared so the GET cannot drift from the POST on the things that matter for
  /// safety: the connection timeout, the response timeout, the byte cap and the
  /// `retryAfter` capture. A second copy of that is a second copy to forget one
  /// of them.
  Future<AntigravityOAuthHttpResponse> _send(
    Uri uri, {
    required Map<String, String> headers,
    required String method,
    String? body,
  }) async {
    final client = HttpClient()..connectionTimeout = connectionTimeout;
    try {
      final request =
          await (method == 'GET' ? client.getUrl(uri) : client.postUrl(uri))
              .timeout(connectionTimeout);
      headers.forEach(request.headers.set);
      if (body != null) request.write(body);
      final response = await request.close().timeout(responseTimeout);
      return AntigravityOAuthHttpResponse(
        statusCode: response.statusCode,
        body: await _readBounded(response),
        retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
      );
    } finally {
      client.close(force: true);
    }
  }

  /// Reads at most [maxResponseBytes], failing loudly past the cap rather than
  /// buffering an unbounded body.
  Future<String> _readBounded(HttpClientResponse response) async {
    final chunks = <int>[];
    var total = 0;
    await for (final chunk in response.timeout(responseTimeout)) {
      total += chunk.length;
      if (total > maxResponseBytes) {
        throw const AntigravityTransportFailure(
          'Antigravity response too large',
        );
      }
      chunks.addAll(chunk);
    }
    return utf8.decode(chunks);
  }
}
