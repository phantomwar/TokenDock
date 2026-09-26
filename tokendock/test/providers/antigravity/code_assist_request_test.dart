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
        if (uri.host == 'oauth2.googleapis.com') {
          return AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: jsonEncode(<String, dynamic>{
              'access_token': 'ya29.access',
              'refresh_token': '1//refresh',
              'expires_in': 3600,
              'accountEmail': 'a@example.com',
              'accountId': 'acct-a',
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
    final body = sentBodies.firstWhere((b) => b.contains('pluginType'));
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

    test('pluginType is GEMINI, which is not a typo', () async {
      // This is the field that reads like a mistake and is not: the Antigravity
      // surface is carried by the *IDE* type, and the plugin that reaches it is
      // the Gemini one. Both working implementations send exactly this pair.
      await signIn();
      expect(
        firstCodeAssistMetadata()['pluginType'],
        'GEMINI',
        reason: 'ANTIGRAVITY belongs in ideType, not pluginType',
      );
    });

    test('platform is present', () async {
      await signIn();
      expect(
        firstCodeAssistMetadata().keys,
        contains('platform'),
        reason: 'the reference sends platform alongside ideType and pluginType',
      );
    });

    test('the same metadata appears on the onboardUser call', () async {
      // Two call sites wrote the metadata independently, which is exactly how
      // they came to disagree. Asserted together so they cannot drift again.
      await signIn();
      final bodies = sentBodies.where((b) => b.contains('pluginType'));
      // At minimum loadCodeAssist; onboardUser only runs when there is no tier.
      expect(bodies, isNotEmpty);
      for (final body in bodies) {
        final metadata =
            (jsonDecode(body) as Map<String, dynamic>)['metadata']
                as Map<String, dynamic>;
        expect(metadata['ideType'], 'ANTIGRAVITY');
        expect(metadata['pluginType'], 'GEMINI');
      }
    });
  });

  group('the required headers are sent', () {
    test('X-Goog-Api-Client, which both implementations send', () async {
      await signIn();
      for (final headers in sentHeaders.where(
        (h) => h.containsKey('Authorization'),
      )) {
        expect(
          headers['X-Goog-Api-Client'],
          isNotNull,
          reason: 'missing on ${sentUris[sentHeaders.indexOf(headers)]}',
        );
      }
    });

    test('a User-Agent, which both implementations send', () async {
      await signIn();
      for (final headers in sentHeaders.where(
        (h) => h.containsKey('Authorization'),
      )) {
        expect(headers['User-Agent'], isNotNull);
      }
    });

    test('Client-Metadata on loadCodeAssist, matching the body', () async {
      await signIn();
      final index = sentUris.indexWhere(
        (u) => u.path.contains('loadCodeAssist'),
      );
      expect(index, isNot(-1), reason: 'loadCodeAssist was never called');
      final header = sentHeaders[index]['Client-Metadata'];
      expect(header, isNotNull);
      final decoded = jsonDecode(header!) as Map<String, dynamic>;
      expect(decoded['ideType'], 'ANTIGRAVITY');
      expect(decoded['pluginType'], 'GEMINI');
    });

    test(
      'the token endpoint is not given a bearer or client metadata',
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

  group('the identity is still sent when there is one', () {
    test('userIdentifier reaches the body', () async {
      await signIn();
      final body = jsonDecode(
        sentBodies.firstWhere((b) => b.contains('pluginType')),
      ) as Map<String, dynamic>;
      expect(
        body['userIdentifier'],
        'a@example.com|acct-a',
        reason:
            'the guard composes the identity as email|accountId, so asserting the '
            'exact shape is what catches a half-built identity being sent as a '
            'valid-looking string',
      );
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
}
