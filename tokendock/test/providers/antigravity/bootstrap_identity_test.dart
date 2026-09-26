import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// The bootstrap request was sending the wrong client identity in three ways.
///
/// `cortexkit/antigravity-auth` was verified against live `agy` CLI 1.1.24
/// traffic, and its `buildAntigravityLoadCodeAssistMetadata` returns exactly one
/// field:
///
/// ```ts
/// return { ideType: 'ANTIGRAVITY' }
/// ```
///
/// TokenDock sent `{ideType: ANTIGRAVITY, platform: WINDOWS, pluginType: GEMINI}`
/// -- and `pluginType: GEMINI` is the marker that declares the caller to be the
/// **Gemini CLI**, which this client is not. `INVALID_ARGUMENT` is the endpoint
/// refusing a body that claims to be a different client. The full three-field
/// map is correct in the `Client-Metadata` *header*; it is wrong in the request
/// *body*.
///
/// Second, the bootstrap `User-Agent`. The reference uses the harness CLI form,
/// not the Electron desktop form in its own `getAntigravityHeaders()`.
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
            'accountEmail': 'a@example.com',
            'accountId': 'acct-a',
            'cloudaicompanionProject': 'project-a',
            'currentTier': <String, dynamic>{'id': 'free'},
          }),
        );
      }),
    );
  }

  Future<void> signIn() async {
    await buildProvider().login(
      connection,
      code: 'c',
      codeVerifier: 'v',
      redirectUri: 'http://127.0.0.1:51123/oauth',
    );
  }

  Map<String, dynamic> bodyOf(String pathFragment) {
    final index = sentUris.indexWhere((u) => u.path.contains(pathFragment));
    expect(index, isNot(-1), reason: '$pathFragment was never called');
    return jsonDecode(sentBodies[index]) as Map<String, dynamic>;
  }

  group('the bootstrap body declares only the IDE type', () {
    test('metadata is exactly {ideType: ANTIGRAVITY}', () async {
      await signIn();

      final metadata =
          bodyOf('loadCodeAssist')['metadata'] as Map<String, dynamic>;

      expect(
        metadata,
        <String, dynamic>{'ideType': 'ANTIGRAVITY'},
        reason:
            'the reference sends one field. pluginType: GEMINI in the body '
            'declares the caller to be the Gemini CLI, and the endpoint answers '
            'INVALID_ARGUMENT to a body naming a client it is not',
      );
    });

    test('and in particular carries no pluginType', () async {
      await signIn();
      final metadata =
          bodyOf('loadCodeAssist')['metadata'] as Map<String, dynamic>;
      expect(metadata.containsKey('pluginType'), isFalse);
      expect(metadata.containsKey('platform'), isFalse);
    });

    test('the same one-field metadata on onboardUser', () async {
      await signIn();
      final index = sentUris.indexWhere((u) => u.path.contains('onboardUser'));
      // Only reached when the account has no tier, so the assertion has to
      // tolerate its absence rather than silently passing.
      if (index >= 0) {
        final body = jsonDecode(sentBodies[index]) as Map<String, dynamic>;
        expect(body['metadata'], <String, dynamic>{'ideType': 'ANTIGRAVITY'});
      } else {
        expect(
          sentUris.any((u) => u.path.contains('loadCodeAssist')),
          isTrue,
          reason: 'neither endpoint was called',
        );
      }
    });
  });

  group('the header still carries the full client metadata', () {
    test('Client-Metadata keeps all three fields', () async {
      // The narrow body and the full header are not a contradiction: the
      // reference sends exactly this pair. Narrowing the header too would lose
      // the platform declaration the header exists to carry.
      await signIn();
      final index = sentUris.indexWhere(
        (u) => u.path.contains('loadCodeAssist'),
      );
      final decoded = jsonDecode(
        sentHeaders[index]['Client-Metadata']!,
      ) as Map<String, dynamic>;

      expect(decoded['ideType'], 'ANTIGRAVITY');
      expect(decoded['platform'], 'WINDOWS');
      expect(decoded['pluginType'], 'GEMINI');
    });
  });

  group('the bootstrap User-Agent is the harness form', () {
    test('and identifies as the antigravity cli, not the Electron IDE', () {
      expect(
        AntigravityOAuthProvider.userAgent,
        startsWith('antigravity/cli/'),
        reason:
            'the reference sends the harness form; the Electron desktop '
            'string belongs to the IDE, and a CLI is not the IDE',
      );
    });

    test('it names the os and arch, which the endpoint reads', () {
      final ua = AntigravityOAuthProvider.userAgent;
      expect(ua, contains('os_type=windows'));
      expect(ua, contains('arch=amd64'));
    });

    test('it does not claim to be Chrome or Electron', () {
      // Sending a browser identity would be impersonating the desktop IDE, and
      // the reference does not do it for the CLI path.
      final ua = AntigravityOAuthProvider.userAgent.toLowerCase();
      expect(ua, isNot(contains('chrome')));
      expect(ua, isNot(contains('electron')));
      expect(ua, isNot(contains('mozilla')));
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
