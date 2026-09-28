import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/storage/secret_store.dart';

/// A failed Google login used to be silent outside the UI.
///
/// The sign-in path swallowed the exception into a fixed, deliberately vague
/// user-facing string — correctly, because an exception object can carry SQL,
/// table names and credential-shaped text. But the consequence was that the
/// original `Error 400: invalid_scope [invalid=[cloud-platform, ...]]` had to be
/// diagnosed by reading the error page in the browser: the app logged nothing,
/// and showed the same message for a cancelled login, a transport failure and a
/// schema change.
///
/// This pins the replacement: enough to diagnose, and provably not a credential
/// channel. Only the `error` field of an OAuth error response is ever read — a
/// short enum-like code such as `invalid_scope` or `invalid_client` — and only
/// when it passes a shape test. A token pasted into that field is refused
/// outright rather than redacted, because a log gets copied into bug reports and
/// a half-redacted secret is still a secret.
void main() {
  const connection = Connection(
    id: 'conn-1',
    provider: 'antigravity',
    displayName: 'Antigravity',
    group: null,
    plan: null,
    credentialRef: 'cred-1',
    enabled: true,
  );

  late List<String> log;
  late AntigravityOAuthHttpRunner http;
  late void Function(String?, {int? wrapWidth}) originalDebugPrint;

  /// A runner that answers the token endpoint with [tokenResponse] and every
  /// other host with a provisioned Code Assist payload.
  AntigravityOAuthHttpRunner runner({
    required int tokenStatus,
    String tokenBody = '{}',
  }) {
    return _Runner((Uri uri) {
      if (uri.host == 'oauth2.googleapis.com') {
        return AntigravityOAuthHttpResponse(
          statusCode: tokenStatus,
          body: tokenBody,
        );
      }
      return AntigravityOAuthHttpResponse(
        statusCode: 200,
        body: jsonEncode(<String, dynamic>{
          'response': <String, dynamic>{
            'accountEmail': 'a@example.com',
            'accountId': 'acct-a',
            'currentTier': <String, dynamic>{'id': 'free'},
            'cloudaicompanionProject': 'project-a',
          },
        }),
      );
    });
  }

  setUp(() {
    log = <String>[];
    originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) log.add(message);
    };
  });

  tearDown(() {
    debugPrint = originalDebugPrint;
  });

  String joined() => log.join('\n');

  group('the OAuth error code is extracted for the log', () {
    test('a 400 carrying invalid_scope is reported by code, not by body', () {
      expect(
        AntigravityOAuthProvider.oauthErrorCodeOf(
          '{"error":"invalid_scope","error_description":"Access denied"}',
        ),
        'invalid_scope',
      );
    });

    test('the other standard codes survive intact', () {
      for (final code in const [
        'invalid_client',
        'invalid_grant',
        'unauthorized_client',
        'access_denied',
        'invalid_request',
        'consent_required',
        'server_error',
        'temporarily_unavailable',
        'user_cancelled',
      ]) {
        expect(
          AntigravityOAuthProvider.oauthErrorCodeOf('{"error":"$code"}'),
          code,
        );
      }
    });

    test('a body that is not an OAuth error yields nothing, not a throw', () {
      expect(
        AntigravityOAuthProvider.oauthErrorCodeOf('<html>500</html>'),
        isNull,
      );
      expect(AntigravityOAuthProvider.oauthErrorCodeOf(''), isNull);
      expect(
        AntigravityOAuthProvider.oauthErrorCodeOf('{"access_token":"ya29.X"}'),
        isNull,
      );
    });

    test('anything that could be a credential is refused, not sanitised', () {
      for (final hostile in <String>[
        '{"error":"ya29.a0AfH6SMabcdefghijklmnopqrs"}',
        '{"error":"${AntigravityOAuthProvider.clientSecret}"}',
        '{"error":"1//0eXyZ-token-value-here"}',
        // The case that forced the allow-list. This passes every shape rule a
        // filter could reasonably write -- lowercase, digits, dashes, 26
        // characters -- because a lowercase hex API key *is* shaped like an OAuth
        // error code. Only "is this a code I recognise" refuses it.
        '{"error":"sk-or-v1-0123456789abcdefghij"}',
        '{"error":"a b"}',
        '{"error":"line\nbreak"}',
        '{"error":"semi;colon"}',
        '{"error":123}',
        '{"error":null}',
        '{"error":""}',
        // Well-formed but unrecognised: refused rather than guessed at, because
        // "we do not know what this is" is exactly when a log is least safe.
        '{"error":"some_future_google_code"}',
      ]) {
        expect(
          AntigravityOAuthProvider.oauthErrorCodeOf(hostile),
          isNull,
          reason: 'must be refused: $hostile',
        );
      }
    });
  });

  group('the Google API error envelope is read too', () {
    // The first live sign-in attempt logged a bare `HTTP 400` with no reason.
    // The cause: Google's OAuth token endpoint uses RFC 6749's flat
    // `{"error": "..."}`, but the Cloud Code Assist endpoints use the API
    // envelope `{"error": {"code": 400, "message": "...", "status": "..."}}`
    // — nested, and the useful field is named `status`. Reading only the flat
    // shape meant the endpoint that actually failed was indistinguishable from
    // one that returned no code at all.
    test('the canonical status is extracted from the nested envelope', () {
      expect(
        AntigravityOAuthProvider.apiStatusOf(
          '{"error":{"code":400,"message":"x","status":"INVALID_ARGUMENT"}}',
        ),
        'INVALID_ARGUMENT',
      );
    });

    test('every canonical status is recognised', () {
      for (final status in const [
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
      ]) {
        expect(
          AntigravityOAuthProvider.apiStatusOf(
            '{"error":{"status":"$status"}}',
          ),
          status,
        );
      }
    });

    test('the flat OAuth shape has no API status, and vice versa', () {
      // Two shapes, one reader. Neither extractor may claim the other's field, or
      // a log line will name a code that the endpoint never sent.
      expect(
        AntigravityOAuthProvider.apiStatusOf('{"error":"invalid_scope"}'),
        isNull,
      );
      expect(
        AntigravityOAuthProvider.oauthErrorCodeOf(
          '{"error":{"status":"INVALID_ARGUMENT"}}',
        ),
        isNull,
      );
    });

    test('the message is never read, because it echoes the request', () {
      expect(
        AntigravityOAuthProvider.apiStatusOf(
          '{"error":{"code":400,"message":"ya29.leaked-token-value",'
          '"status":"INVALID_ARGUMENT"}}',
        ),
        'INVALID_ARGUMENT',
      );
      // And a message with no status yields nothing at all, rather than falling
      // back to the message text.
      expect(
        AntigravityOAuthProvider.apiStatusOf(
          '{"error":{"code":400,"message":"sk-or-v1-0123456789abcdefghij"}}',
        ),
        isNull,
      );
    });

    test('an unrecognised status is refused, not passed through', () {
      for (final hostile in const <String>[
        '{"error":{"status":"ya29.a0AfH6SMabcdefghijklmnop"}}',
        '{"error":{"status":"sk-or-v1-0123456789abcdefghij"}}',
        '{"error":{"status":"lowercase_unknown"}}',
        '{"error":{"status":400}}',
        '{"error":{"status":"INVALID_ARGUMENT\nsecond line"}}',
      ]) {
        expect(
          AntigravityOAuthProvider.apiStatusOf(hostile),
          isNull,
          reason: 'must be refused: $hostile',
        );
      }
    });

    test('rejectionReasonOf prefers whichever shape the body actually is', () {
      expect(
        AntigravityOAuthProvider.rejectionReasonOf('{"error":"invalid_scope"}'),
        'invalid_scope',
      );
      expect(
        AntigravityOAuthProvider.rejectionReasonOf(
          '{"error":{"code":400,"status":"PERMISSION_DENIED"}}',
        ),
        'PERMISSION_DENIED',
      );
      expect(
        AntigravityOAuthProvider.rejectionReasonOf('<html>nope</html>'),
        isNull,
      );
    });
  });

  group('a failed token exchange says so in the log', () {
    test('a 400 logs the stage, the status and the code', () async {
      http = runner(
        tokenStatus: 400,
        tokenBody: '{"error":"invalid_scope","error_description":"nope"}',
      );
      final provider = AntigravityOAuthProvider(http: http);

      await expectLater(
        provider.login(
          connection,
          code: 'the-authorization-code',
          codeVerifier: 'the-code-verifier',
          redirectUri: 'http://127.0.0.1:51123/oauth',
        ),
        throwsA(
          isA<AntigravityHttpStatus>().having(
            (e) => e.statusCode,
            'statusCode',
            400,
          ),
        ),
      );

      // The failure still propagates as a status, never as parsed text, so
      // classification cannot start depending on a body (audit C-11).
      expect(joined(), contains('token'));
      expect(joined(), contains('400'));
      expect(joined(), contains('invalid_scope'));
    });

    test('an unexpected 500 logs the status and no invented code', () async {
      http = runner(tokenStatus: 500, tokenBody: 'upstream exploded');
      final provider = AntigravityOAuthProvider(http: http);

      await expectLater(
        provider.login(
          connection,
          code: 'c',
          codeVerifier: 'v',
          redirectUri: 'http://127.0.0.1:1/oauth',
        ),
        throwsA(isA<AntigravityTransientFailure>()),
      );

      expect(joined(), contains('500'));
      // 5xx is retried before it is logged, so the log must not claim a single
      // attempt when three were made.
      expect(joined(), contains('attempt'));
    });

    test(
      'the log never carries the code, the verifier or the credentials',
      () async {
        http = runner(tokenStatus: 400, tokenBody: '{"error":"invalid_scope"}');
        final provider = AntigravityOAuthProvider(http: http);

        await expectLater(
          provider.login(
            connection,
            code: 'the-authorization-code',
            codeVerifier: 'the-code-verifier',
            redirectUri: 'http://127.0.0.1:51123/oauth',
          ),
          throwsA(isA<AntigravityHttpStatus>()),
        );

        // Every value below is a real secret in the real flow.
        expect(joined(), isNot(contains('the-authorization-code')));
        expect(joined(), isNot(contains('the-code-verifier')));
        expect(
          joined(),
          isNot(contains(AntigravityOAuthProvider.clientSecret)),
        );
        expect(joined(), isNot(contains(AntigravityOAuthProvider.clientId)));
        expect(
          joined(),
          isNot(contains('error_description')),
          reason:
              'the description can echo the request back, so it is never read',
        );
      },
    );

    test('a successful sign-in logs progress and no secret either', () async {
      http = runner(
        tokenStatus: 200,
        tokenBody: jsonEncode(<String, dynamic>{
          'access_token': 'ya29.a-real-secret',
          'refresh_token': '1//a-real-refresh-secret',
          'expires_in': 3600,
          'accountEmail': 'a@example.com',
          'accountId': 'acct-a',
        }),
      );
      final store = _RecordingSecretStore();
      final provider = AntigravityOAuthProvider(http: http, secretStore: store);

      await provider.login(
        connection,
        code: 'the-authorization-code',
        codeVerifier: 'the-code-verifier',
        redirectUri: 'http://127.0.0.1:51123/oauth',
      );

      // The point of the test: progress is logged, and logging progress does not
      // become a way to print the tokens.
      expect(joined(), isNotEmpty, reason: 'progress must be visible');
      expect(joined(), isNot(contains('ya29.a-real-secret')));
      expect(joined(), isNot(contains('1//a-real-refresh-secret')));
      expect(joined(), isNot(contains('the-authorization-code')));
      expect(joined(), isNot(contains('the-code-verifier')));
    });
  });
}

class _Runner implements AntigravityOAuthHttpRunner {
  _Runner(this._respond);

  final AntigravityOAuthHttpResponse Function(Uri uri) _respond;

  @override
  Future<AntigravityOAuthHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async => _respond(uri);

  @override
  Future<AntigravityOAuthHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async => _respond(uri);
}

class _RecordingSecretStore implements SecretStore {
  final Map<String, String> written = <String, String>{};

  @override
  Future<void> write(String ref, String secret) async {
    written[ref] = secret;
  }

  @override
  Future<String?> read(String ref) async => written[ref];

  @override
  Future<void> delete(String ref) async {
    written.remove(ref);
  }
}
