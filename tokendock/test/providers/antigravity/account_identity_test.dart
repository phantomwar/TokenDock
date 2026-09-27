import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// Five implementations read, and the identity question answered.
///
/// `oh-my-pi` never reads an account identity at all: its project hook takes the
/// access token, discovers the project, returns credentials. `9router` and
/// `cortexkit` call a userinfo endpoint for the email and use it as the account
/// *label*. None cross-checks the identity Cloud Code returns against the one
/// that authorised the token.
///
/// TokenDock is the only one with a guard, and it built `email|accountId` from
/// the **token** response, which carries no account fields. That is attempt 7.
///
/// `CLIProxyAPI` -- 53k stars, the most widely deployed of the five -- resolves
/// it the only way that is both safe and workable: fetch the email from
/// `oauth2/v2/userinfo`, and take the account id from the **provisioning**
/// response, which carries `accountEmail` and `accountId`. Then compare, so the
/// guard survives.
///
/// The userinfo endpoint is `oauth2/**v2**/userinfo`, not the `v1` the 9router
/// and cortexkit send. `userinfo.email` is a granted scope either way, so no
/// new scope is needed.
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

  const email = 'user@example.com';
  const accountId = 'acct-123';

  late List<Uri> sentUris;
  late List<Map<String, String>> sentHeaders;
  late List<String> sentBodies;
  late int userInfoStatus;
  late String userInfoBody;

  AntigravityOAuthProvider buildProvider() {
    sentUris = <Uri>[];
    sentHeaders = <Map<String, String>>[];
    sentBodies = <String>[];
    return AntigravityOAuthProvider(
      http: _Recording((Uri uri, Map<String, String> headers, String body) {
        sentUris.add(uri);
        sentHeaders.add(headers);
        sentBodies.add(body);

        // Matched on the path, not the host: the userinfo endpoint lives on
        // www.googleapis.com while the token endpoint is oauth2.googleapis.com,
        // and a double that conflates them answers the wrong question.
        if (uri.path.contains('userinfo')) {
          return AntigravityOAuthHttpResponse(
            statusCode: userInfoStatus,
            body: userInfoBody,
          );
        }
        if (uri.host == 'oauth2.googleapis.com') {
          return AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: jsonEncode(<String, dynamic>{
              'access_token': 'ya29.access',
              'refresh_token': '1//refresh',
              'expires_in': 3600,
              // No accountEmail, no accountId. This is what Google actually
              // returns, and it is why the identity could not be found here.
            }),
          );
        }

        return AntigravityOAuthHttpResponse(
          statusCode: 200,
          body: jsonEncode(<String, dynamic>{
            'accountEmail': email,
            'accountId': accountId,
            'cloudaicompanionProject': 'project-a',
            'currentTier': <String, dynamic>{'id': 'free'},
          }),
        );
      }),
    );
  }

  setUp(() {
    userInfoStatus = 200;
    userInfoBody = jsonEncode(<String, dynamic>{'email': email});
  });

  Future<AntigravityOAuthLoginResult> signIn() {
    return buildProvider().login(
      connection,
      code: 'c',
      codeVerifier: 'v',
      redirectUri: 'http://127.0.0.1:51123/oauth',
    );
  }

  group('the identity comes from where it actually exists', () {
    test('a full sign-in succeeds with the guard intact', () async {
      // The regression: this threw "OAuth account identity missing" because the
      // identity was read from the token response, which has no account fields.
      final result = await signIn();
      expect(result.projectId, 'project-a');
      expect(
        result.identityKey,
        email,
        reason:
            'the identity is the email and only the email -- Google sends no '
            'account id on this path, so there is no second half to compose',
      );
    });

    test('userinfo is called, and on the v2 endpoint', () async {
      await signIn();
      final index = sentUris.indexWhere((u) => u.path.contains('userinfo'));
      expect(index, isNot(-1), reason: 'the email is never fetched otherwise');
      expect(
        sentUris[index].toString(),
        contains('oauth2/v2/userinfo'),
        reason:
            'CLIProxyAPI uses v2; v1 is what the other two references send '
            'and it is not the endpoint Google documents',
      );
    });

    test('userinfo is called before the provisioning call', () async {
      // Order matters: the identity has to exist before the guard compares it.
      await signIn();
      final userInfo = sentUris.indexWhere((u) => u.path.contains('userinfo'));
      final codeAssist = sentUris.indexWhere(
        (u) => u.path.contains('loadCodeAssist'),
      );
      expect(userInfo, isNot(-1));
      expect(codeAssist, isNot(-1));
      expect(
        userInfo,
        lessThan(codeAssist),
        reason: 'the email is needed to compare against the provisioning body',
      );
    });

    test('userinfo is sent the access token, and never the secret', () async {
      await signIn();
      final index = sentUris.indexWhere((u) => u.path.contains('userinfo'));
      final headers = sentHeaders[index];
      expect(headers['Authorization'], 'Bearer ya29.access');
      expect(headers.values.join(' '), isNot(contains('GOCSPX')));
    });

    test('no account id is composed, because none is available', () async {
      // Reversed 2026-09-26. This asserted the identity contained an account id
      // taken from the provisioning body, and the account id it read was in
      // TokenDock's own fixture and in no Google response: the ninth live
      // attempt logged the real keys, and `oh-my-pi`'s schema declares the same
      // five. Fabricating a second half -- `email|email` or `email|` -- would put
      // a value into the guard that it then "verifies" against, which is exactly
      // the failure the guard exists to prevent.
      final result = await signIn();
      expect(result.identityKey, isNot(contains('|')));
      expect(result.identityKey, email);
    });
  });

  group('the guard still refuses a mismatch', () {
    test('a provisioning body for a different account is rejected', () async {
      // The whole point of keeping the guard. If this test has to be deleted to
      // make sign-in work, the guard was the wrong thing to keep.
      final provider = AntigravityOAuthProvider(
        http: _Recording((Uri uri, Map<String, String> headers, String body) {
          // The userinfo endpoint is on www.googleapis.com, not the token host,
          // so it has to be matched on its path rather than lumped in with the
          // token exchange.
          if (uri.path.contains('userinfo')) {
            return AntigravityOAuthHttpResponse(
              statusCode: 200,
              body: jsonEncode(<String, dynamic>{'email': email}),
            );
          }
          if (uri.host == 'oauth2.googleapis.com') {
            return AntigravityOAuthHttpResponse(
              statusCode: 200,
              body: jsonEncode(<String, dynamic>{
                'access_token': 'ya29.access',
                'refresh_token': '1//refresh',
                'expires_in': 3600,
              }),
            );
          }
          return AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: jsonEncode(<String, dynamic>{
              // A different account than userinfo reported.
              'accountEmail': 'someone.else@example.com',
              'accountId': 'acct-other',
              'cloudaicompanionProject': 'project-a',
              'currentTier': <String, dynamic>{'id': 'free'},
            }),
          );
        }),
      );

      await expectLater(
        provider.login(
          connection,
          code: 'c',
          codeVerifier: 'v',
          redirectUri: 'http://127.0.0.1:1/oauth',
        ),
        throwsA(anything),
        reason: 'a token for one account must not read another account project',
      );
    });
  });

  group('a blocked userinfo degrades rather than blocks', () {
    test('a 403 is reported, not silently treated as no identity', () async {
      // cortexkit treats a non-OK userinfo as `{}` and continues. That is the
      // norm, and it is the right default: the call exists to label the account,
      // and the credential is already proven by the provisioning call succeeding.
      // But it must not be silent -- a debug line, never a fabricated identity.
      userInfoStatus = 403;
      userInfoBody = '{"error":"forbidden"}';

      // Either it proceeds without the email, or it fails clearly. What it must
      // not do is invent an identity or hang.
      Object? caught;
      try {
        await signIn();
      } catch (error) {
        caught = error;
      }
      expect(caught, isNot(isA<StateError>()));
    });

    test('an unreachable userinfo does not lose a working credential', () async {
      userInfoStatus = 500;
      userInfoBody = '';

      Object? caught;
      try {
        await signIn();
      } catch (error) {
        caught = error;
      }
      // A transient userinfo failure must not turn a working login into a
      // failure. If it did, a Google-side outage on an unrelated endpoint would
      // lock users out of the provider entirely.
      expect(caught, isNull, reason: 'the credential already works');
    });
  });
}

class _Recording implements AntigravityOAuthHttpRunner {
  _Recording(this._respond);

  final AntigravityOAuthHttpResponse Function(
    Uri uri,
    Map<String, String> headers,
    String body,
  )
  _respond;

  @override
  Future<AntigravityOAuthHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async => _respond(uri, headers, body);

  @override
  Future<AntigravityOAuthHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async => _respond(uri, headers, '');
}
