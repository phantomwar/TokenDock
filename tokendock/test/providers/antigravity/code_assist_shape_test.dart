import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// Three defects, all found by reading `cortexkit/antigravity-auth`, which talks
/// to the same endpoints and is verified against live CLI traffic.
///
/// **The response is not wrapped in a `response` envelope.** TokenDock required
/// `result['response'] is Map` and threw `AntigravitySchemaChanged` otherwise --
/// silently, because that throw had no log line. `cortexkit` reads
/// `data.cloudaicompanionProject` straight off the top level, and also accepts
/// `data.cloudaicompanionProject.id`. That silent throw is where a live sign-in
/// stopped dead: the log ended at the authorization code and never named the
/// endpoint again.
///
/// **`platform` is a real value, not `PLATFORM_UNSPECIFIED`.** `cortexkit`
/// sends `platform: "WINDOWS"` on win32 and `"MACOS"` otherwise, in both the
/// `Client-Metadata` header and the body.
///
/// **The endpoint order is daily first.** `cortexkit` probes
/// `daily-cloudcode-pa.googleapis.com` before prod, and comments that live agy
/// CLI 1.1.24 traffic uses daily. TokenDock tried prod first.
///
/// Plus: a hardcoded fallback project id, for the business and workspace
/// accounts where the endpoint returns none. Without it those accounts cannot
/// connect at all.
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

  AntigravityOAuthProvider providerWith(
    Future<AntigravityOAuthHttpResponse> Function(Uri uri, String body) post,
  ) {
    return AntigravityOAuthProvider(
      http: _Runner(
        (Uri uri, Map<String, String> headers, String body) async =>
            post(uri, body),
      ),
    );
  }

  /// Answers the token endpoint, then [onCodeAssist] for every Code Assist call.
  /// A provider that completes the token exchange, then answers every Cloud Code
  /// call with [codeAssistFields] wrapped in an envelope of [enveloped].
  ///
  /// The account identity travels in the provisioning body as well as the token
  /// response, and the guard compares the two. A fixture that omits it fails as
  /// an account mismatch -- which is the guard working, not the shape under test.
  AntigravityOAuthProvider provider(
    Map<String, dynamic> codeAssistFields, {
    bool enveloped = false,
  }) {
    return providerWith((Uri uri, String body) async {
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
      final inner = <String, dynamic>{
        'accountEmail': 'a@example.com',
        'accountId': 'acct-a',
        ...codeAssistFields,
      };
      return AntigravityOAuthHttpResponse(
        statusCode: 200,
        body: jsonEncode(
          enveloped ? <String, dynamic>{'response': inner} : inner,
        ),
      );
    });
  }

  group('a bare loadCodeAssist response is accepted', () {
    test('the project id at the top level, with no response envelope', () async {
      // This is the shape the endpoint actually returns, and the one a live
      // attempt returned. It is the regression: TokenDock required the envelope
      // and failed silently on exactly this body.
      final result =
          await provider(<String, dynamic>{
            'cloudaicompanionProject': 'project-a',
            'currentTier': <String, dynamic>{'id': 'free'},
          }).login(
            connection,
            code: 'c',
            codeVerifier: 'v',
            redirectUri: 'http://127.0.0.1:1/oauth',
          );

      expect(result.projectId, 'project-a');
    });

    test('the project id as an object, which the endpoint also returns', () async {
      // `cloudaicompanionProject.id` is the second shape `cortexkit` accepts, and
      // a hard requirement to handle: a client that only reads the string form
      // reports "no project" for every account served the object form.
      final result =
          await provider(<String, dynamic>{
            'cloudaicompanionProject': <String, dynamic>{'id': 'project-obj'},
            'currentTier': <String, dynamic>{'name': 'free'},
          }).login(
            connection,
            code: 'c',
            codeVerifier: 'v',
            redirectUri: 'http://127.0.0.1:1/oauth',
          );

      expect(result.projectId, 'project-obj');
    });

    test('the enveloped shape still works, so nothing regresses', () async {
      final result =
          await provider(<String, dynamic>{
            'cloudaicompanionProject': 'project-env',
            'currentTier': <String, dynamic>{'id': 'free'},
          }, enveloped: true).login(
            connection,
            code: 'c',
            codeVerifier: 'v',
            redirectUri: 'http://127.0.0.1:1/oauth',
          );

      expect(result.projectId, 'project-env');
    });

    test('the tier is read from the top level too', () async {
      final result =
          await provider(<String, dynamic>{
            'cloudaicompanionProject': 'project-a',
            'currentTier': <String, dynamic>{'id': 'pro-tier'},
          }).login(
            connection,
            code: 'c',
            codeVerifier: 'v',
            redirectUri: 'http://127.0.0.1:1/oauth',
          );

      expect(
        result.tier,
        'pro-tier',
        reason: 'a bare response carries the tier at the top level as well',
      );
    });

    test('a 200 with neither a project nor a tier is still rejected', () async {
      // The fix must not turn every 200 into a success. A body with no
      // provisioning at all is a schema change, and has to keep saying so.
      await expectLater(
        provider(const <String, dynamic>{'somethingElse': true}).login(
          connection,
          code: 'c',
          codeVerifier: 'v',
          redirectUri: 'http://127.0.0.1:1/oauth',
        ),
        throwsA(isA<AntigravitySchemaChanged>()),
      );
    });
  });

  group('daily is probed before production', () {
    test('loadCodeAssist hits daily first, and does not need the fallback', () async {
      // Only the first host is asserted. TokenDock's cross-host fallback catches
      // `AntigravityTransportFailure`, and a 503 is deliberately *not* one -- it
      // is retryable within a host and classified as a throttle elsewhere. So a
      // healthy daily endpoint ends the loop, and asserting the second host was
      // reached would be asserting a fallback that correctly never fires.
      final hosts = <String>[];
      final provider = AntigravityOAuthProvider(
        http: _Runner((
          Uri uri,
          Map<String, String> headers,
          String body,
        ) async {
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
          hosts.add(uri.host);
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

      await provider.login(
        connection,
        code: 'c',
        codeVerifier: 'v',
        redirectUri: 'http://127.0.0.1:1/oauth',
      );

      expect(hosts, isNotEmpty, reason: 'no Cloud Code call was made at all');
      expect(
        hosts.every((h) => h == 'daily-cloudcode-pa.googleapis.com'),
        isTrue,
        reason:
            'live agy CLI traffic uses the daily endpoint, and TokenDock '
            'probed production first, so the endpoint a real client actually '
            'talks to was only reached after production had already failed',
      );
    });

    test('production is still reachable when daily is unreachable', () async {
      // The cross-host fallback has to survive the reordering, or accounts whose
      // daily endpoint is down have no path at all.
      final hosts = <String>[];
      final provider = AntigravityOAuthProvider(
        http: _Runner((
          Uri uri,
          Map<String, String> headers,
          String body,
        ) async {
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
          hosts.add(uri.host);
          // A thrown transport error is what the cross-host loop catches; a 503
          // is a throttle and is deliberately not one.
          if (uri.host.startsWith('daily-')) {
            throw const AntigravityTransportFailure('daily unreachable');
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

      final result = await provider.login(
        connection,
        code: 'c',
        codeVerifier: 'v',
        redirectUri: 'http://127.0.0.1:1/oauth',
      );

      expect(hosts.first, 'daily-cloudcode-pa.googleapis.com');
      expect(hosts, contains('cloudcode-pa.googleapis.com'));
      expect(result.projectId, 'project-a');
    });
  });

  group('the account metadata names the real platform', () {
    test('platform is WINDOWS on Windows, not PLATFORM_UNSPECIFIED', () {
      // `PLATFORM_UNSPECIFIED` is what the Gemini CLI sends. Sending it here is
      // the same class of mistake as sending `ideType: IDE_UNSPECIFIED`: it
      // names a different client.
      expect(
        AntigravityOAuthProvider.clientMetadata['platform'],
        isNot('PLATFORM_UNSPECIFIED'),
        reason: 'the reference sends WINDOWS on win32',
      );
      expect(
        AntigravityOAuthProvider.clientMetadata['platform'],
        AntigravityOAuthProvider.currentPlatform,
      );
    });

    test('ideType and pluginType keep the values the endpoint needs', () {
      expect(AntigravityOAuthProvider.clientMetadata['ideType'], 'ANTIGRAVITY');
      expect(AntigravityOAuthProvider.clientMetadata['pluginType'], 'GEMINI');
    });
  });

  group('a project-less account is reported, not papered over', () {
    test('no fallback project is ever substituted', () async {
      // `cortexkit` hardcodes `rising-fact-p41fc`, but that project belongs to
      // that project's owner. Substituting it here would point a user's requests
      // and their quota reporting at a Google Cloud project that is not theirs.
      // A shared hardcoded project works for one deployer and misattributes for
      // everyone else, so the truthful state is reported instead: the account
      // needs onboarding.
      await expectLater(
        provider(<String, dynamic>{
          'cloudaicompanionProject': '',
          'currentTier': <String, dynamic>{'id': 'free'},
        }).login(
          connection,
          code: 'c',
          codeVerifier: 'v',
          redirectUri: 'http://127.0.0.1:1/oauth',
        ),
        throwsA(isA<AntigravityOnboardingRequired>()),
      );
    });

    test('and the reference id is recorded without being used', () {
      // Kept so the decision is checkable against the reference rather than
      // remembered.
      expect(
        AntigravityOAuthProvider.referenceFallbackProjectId,
        'rising-fact-p41fc',
      );
    });
  });
}

class _Runner implements AntigravityOAuthHttpRunner {
  _Runner(this._respond);

  final Future<AntigravityOAuthHttpResponse> Function(
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
  }) => _respond(uri, headers, body);
}
