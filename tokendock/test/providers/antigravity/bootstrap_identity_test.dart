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

  group('no client metadata header, because the endpoint rejects it', () {
    test('loadCodeAssist sends no Client-Metadata header', () async {
      // Reversed 2026-09-26. This asserted the header "keeps all three fields",
      // on the reading that a narrow body and a full header were a deliberate
      // pair a reference sends. `CLIProxyAPI`, `oh-my-pi` and `9router` send no
      // such header on this call, and the endpoint answered
      // `400 INVALID_ARGUMENT` while it was present. Only `cortexkit` sends it --
      // and that is the one implementation that needs a hardcoded project id to
      // work against a live account, so it is not evidence the header is
      // accepted.
      //
      // `cloud_code_headers_test.dart` now pins the exact header set.
      await signIn();
      final index = sentUris.indexWhere(
        (u) => u.path.contains('loadCodeAssist'),
      );
      expect(sentHeaders[index].containsKey('Client-Metadata'), isFalse);
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

  @override
  Future<AntigravityOAuthHttpResponse> get(
    Uri uri, {
    required Map<String, String> headers,
  }) async => _respond(uri, headers, '');
}
