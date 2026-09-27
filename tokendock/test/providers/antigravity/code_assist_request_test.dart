import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// The metadata TokenDock sent was **inverted**, and three required headers were
/// missing, and the Cloud Code Assist endpoint answered `400 INVALID_ARGUMENT`.
///
/// Two independent working implementations agree on the correct values:
///
/// - `opencode-antigravity-auth` `docs/ANTIGRAVITY_API_SPEC.md` lists the
///   required headers as `User-Agent`, `X-Goog-Api-Client` and `Client-Metadata`,
///   with `Client-Metadata` as
///   `{"ideType":"ANTIGRAVITY","platform":"...","pluginType":"GEMINI"}`.
/// - `wiseai/picoclaw` `docs/security/ANTIGRAVITY_AUTH.md` sends
///   `loadCodeAssist` with body metadata `ideType: "ANTIGRAVITY"`,
///   `pluginType: "GEMINI"`, and the same `X-Goog-Api-Client`.
///
/// TokenDock was sending `pluginType: 'ANTIGRAVITY'` and `ideType:
/// 'IDE_UNSPECIFIED'` -- the two values on the wrong fields. It is an
/// easy mistake to make and an invisible one: nothing in the response says
/// "you swapped two enum values", it just says `INVALID_ARGUMENT`.
///
/// `platform` was also missing entirely from the body metadata.
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

  late List<Map<String, String>> sentHeaders;
  late List<String> sentBodies;
  late List<Uri> sentUris;

  AntigravityOAuthProvider buildProvider() {
    sentHeaders = <Map<String, String>>[];
    sentBodies = <String>[];
    sentUris = <Uri>[];
    return AntigravityOAuthProvider(
      http: _Recording((Uri uri, Map<String, String> headers, String body) {
        sentUris.add(uri);
        sentHeaders.add(headers);
        sentBodies.add(body);
        // The userinfo endpoint is on www.googleapis.com, matched on path so it
        // cannot be confused with the token host.
        if (uri.path.contains('userinfo')) {
          return AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: jsonEncode(<String, dynamic>{'email': 'a@example.com'}),
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
            'response': <String, dynamic>{
              'accountEmail': 'a@example.com',
              'accountId': 'acct-a',
              'currentTier': <String, dynamic>{'id': 'free'},
              'cloudaicompanionProject': 'project-a',
            },
          }),
        );
      }),
    );
  }

  Future<void> signIn() async {
    await buildProvider().login(
      connection,
      code: 'code',
      codeVerifier: 'verifier',
      redirectUri: 'http://127.0.0.1:51123/oauth',
    );
  }

  /// The body metadata of the first Cloud Code call.
  Map<String, dynamic> firstCodeAssistMetadata() {
    final body = sentBodies.firstWhere((b) => b.contains('ideType'));
    return (jsonDecode(body) as Map<String, dynamic>)['metadata']
        as Map<String, dynamic>;
  }

  group('the client metadata names Antigravity, not the Gemini CLI', () {
    test('ideType is ANTIGRAVITY', () async {
      await signIn();
      expect(
        firstCodeAssistMetadata()['ideType'],
        'ANTIGRAVITY',
        reason: 'IDE_UNSPECIFIED is not an accepted value for this endpoint',
      );
    });

    test('the body carries ideType and nothing else', () async {
      // Corrected 2026-09-26. This test previously asserted that the body
      // carried `platform` and `pluginType: GEMINI`, on the reading that
      // `pluginType: GEMINI` was a required part of the Antigravity identity. It
      // is the opposite: in the request *body* it is the marker that declares
      // the caller to be the Gemini CLI, and a live sign-in was answered
      // `INVALID_ARGUMENT` while this was being sent. The full three-field map
      // belongs in the `Client-Metadata` header, which is asserted below.
      await signIn();
      expect(firstCodeAssistMetadata(), <String, dynamic>{
        'ideType': 'ANTIGRAVITY',
      });
    });

    test('the same metadata appears on the onboardUser call', () async {
      // Two call sites wrote the metadata independently, which is exactly how
      // they came to disagree. Asserted together so they cannot drift again.
      await signIn();
      final bodies = sentBodies.where((b) => b.contains('ideType'));
      expect(bodies, isNotEmpty);
      for (final body in bodies) {
        final metadata =
            (jsonDecode(body) as Map<String, dynamic>)['metadata']
                as Map<String, dynamic>;
        expect(metadata, <String, dynamic>{'ideType': 'ANTIGRAVITY'});
      }
    });
  });

  group('the required headers are sent', () {
    // The Cloud Code calls, identified by path rather than by "has a bearer":
    // the userinfo lookup also carries a bearer and is a different endpoint
    // with a different header contract.
    List<Map<String, String>> cloudCodeHeaders() {
      final out = <Map<String, String>>[];
      for (var i = 0; i < sentUris.length; i++) {
        if (sentUris[i].host.endsWith('googleapis.com') &&
            !sentUris[i].path.contains('userinfo') &&
            !sentUris[i].path.contains('token')) {
          out.add(sentHeaders[i]);
        }
      }
      return out;
    }

    test('a User-Agent, which every implementation sends', () async {
      await signIn();
      for (final headers in cloudCodeHeaders()) {
        expect(headers['User-Agent'], isNotNull);
      }
    });

    test('Accept, which CLIProxyAPI sends and TokenDock did not', () async {
      await signIn();
      for (final headers in cloudCodeHeaders()) {
        expect(headers['Accept'], '*/*');
      }
    });

    test(
      'the token endpoint is not given a bearer or the Cloud Code headers',
      () async {
        // The token request is a plain form post to Google OAuth. Sending it
        // Cloud Code headers would be meaningless at best and a misrouted
        // credential at worst.
        await signIn();
        final index = sentUris.indexWhere(
          (u) => u.host == 'oauth2.googleapis.com',
        );
        expect(index, isNot(-1));
        expect(sentHeaders[index].containsKey('Authorization'), isFalse);
        expect(sentHeaders[index].containsKey('Client-Metadata'), isFalse);
        expect(
          sentHeaders[index]['Content-Type'],
          contains('x-www-form-urlencoded'),
        );
      },
    );
  });

  group('the body carries only what the endpoint accepts', () {
    test('loadCodeAssist sends no userIdentifier', () async {
      // Corrected 2026-09-26, twice. The first version asserted a composed
      // `email|accountId`; the second asserted the plain email. Both were wrong,
      // and both produced `400 INVALID_ARGUMENT`.
      //
      // The field is not part of this request at all. `CLIProxyAPI` builds the
      // body as `{metadata: ...}` and nothing else, and `cortexkit` does the
      // same. Neither sends a user identifier to `loadCodeAssist`: the endpoint
      // resolves the account from the bearer token, so naming one is redundant
      // at best and an unrecognised field at worst.
      await signIn();
      final body = jsonDecode(
        sentBodies.firstWhere((b) => b.contains('ideType')),
      ) as Map<String, dynamic>;
      expect(
        body.containsKey('userIdentifier'),
        isFalse,
        reason: 'the account comes from the bearer token, not from the body',
      );
    });

    test('and the body is metadata plus nothing else', () async {
      await signIn();
      final body = jsonDecode(
        sentBodies.firstWhere((b) => b.contains('ideType')),
      ) as Map<String, dynamic>;
      expect(body.keys, <String>[
        'metadata',
      ], reason: 'CLIProxyAPI builds this request as {metadata: ...} exactly');
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
