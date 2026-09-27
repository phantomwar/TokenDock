import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// The Cloud Code headers, checked field by field against the one
/// implementation that demonstrably works against live traffic.
///
/// `CLIProxyAPI` -- 53k stars, the most widely deployed of the six read -- sets
/// exactly four headers on `loadCodeAssist`:
///
/// ```go
/// httpReq.Header.Set("Authorization", "Bearer "+token)
/// httpReq.Header.Set("Accept", "*/*")
/// httpReq.Header.Set("Content-Type", "application/json")
/// httpReq.Header.Set("User-Agent", userAgent)
/// ```
///
/// TokenDock was sending `Client-Metadata` and `X-Goog-Api-Client` as well, and
/// the endpoint answered `400 INVALID_ARGUMENT` on the sixth and eighth live
/// attempts. Neither header appears anywhere in `CLIProxyAPI`, `oh-my-pi` or
/// `9router` for this call -- only `cortexkit` sends `Client-Metadata`, and it is
/// the one implementation that also hardcodes a project id that is not portable.
///
/// The cross-reference in `docs/antigravity-cross-reference.md` recorded this as
/// "a fingerprint surface with no corroboration, and not proven good". It turns
/// out to be worse than unproven: it is the thing the endpoint rejects.
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

  late List<Uri> sentUris;
  late List<Map<String, String>> sentHeaders;

  AntigravityOAuthProvider buildProvider() {
    sentUris = <Uri>[];
    sentHeaders = <Map<String, String>>[];
    return AntigravityOAuthProvider(
      http: _Recording((Uri uri, Map<String, String> headers, String body) {
        sentUris.add(uri);
        sentHeaders.add(headers);
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
            'accountEmail': 'a@example.com',
            'accountId': 'acct-a',
            'cloudaicompanionProject': 'project-a',
            'currentTier': <String, dynamic>{'id': 'free'},
          }),
        );
      }),
    );
  }

  Future<void> signIn() => buildProvider().login(
    connection,
    code: 'c',
    codeVerifier: 'v',
    redirectUri: 'http://127.0.0.1:51123/oauth',
  );

  /// The headers of the `loadCodeAssist` call, by name.
  Map<String, String> loadCodeAssistHeaders() {
    final index = sentUris.indexWhere((u) => u.path.contains('loadCodeAssist'));
    expect(index, isNot(-1), reason: 'loadCodeAssist was never called');
    return sentHeaders[index];
  }

  group('the Cloud Code request carries exactly the four working headers', () {
    setUp(signIn);

    test('Authorization, Accept, Content-Type and User-Agent', () {
      final headers = loadCodeAssistHeaders();
      expect(headers['Authorization'], 'Bearer ya29.access');
      expect(
        headers['Accept'],
        '*/*',
        reason: 'CLIProxyAPI sends it and TokenDock did not',
      );
      expect(headers['Content-Type'], 'application/json');
      expect(headers['User-Agent'], isNotNull);
    });

    test('and no Client-Metadata', () {
      expect(
        loadCodeAssistHeaders().containsKey('Client-Metadata'),
        isFalse,
        reason:
            'only cortexkit sends this, and it is the one implementation '
            'that does not work against a live account without its own project '
            'id. A header only one of six sends is a fingerprint, not a contract',
      );
    });

    test('and no X-Goog-Api-Client', () {
      expect(
        loadCodeAssistHeaders().containsKey('X-Goog-Api-Client'),
        isFalse,
        reason: 'absent from every implementation for this call',
      );
    });

    test('so the header set is exactly the four', () {
      // Asserted as a set rather than field by field, so a header added later
      // fails here even if the four above still pass.
      expect(loadCodeAssistHeaders().keys.toSet(), <String>{
        'Authorization',
        'Accept',
        'Content-Type',
        'User-Agent',
      });
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
