import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// The OAuth request Antigravity actually accepts.
///
/// This suite exists because the login was returning Google's
/// `Error 400: invalid_scope` listing every scope requested:
///
/// ```text
/// Some requested scopes were invalid.
/// [invalid=[cloud-platform, userinfo.email, userinfo.profile]]
/// Se voce e um desenvolvedor de Gemini Code Assist and Gemini CLI...
/// ```
///
/// Three separate defects, and only the first is obvious from the error text:
///
/// 1. **Wrong client.** `GEMINI_CLI_CLIENT_ID.apps.googleusercontent.com` is the *Gemini CLI* client. An OAuth
///    client is only permitted the scopes registered to it, so asking the wrong
///    client for `cloud-platform` is an `invalid_scope` no matter how the scope
///    is spelled. The Antigravity client is `UNCONFIGURED.apps.googleusercontent.com` and carries a
///    client secret, which makes it a confidential client — so token exchange
///    needs the secret too.
/// 2. **Two scopes missing.** Antigravity registers five, not three:
///    `cclog` and `experimentsandconfigs` were never requested.
/// 3. **No `prompt=consent`.** Without it Google may not issue a refresh token,
///    so the credential cannot be renewed and the next login is required.
///
/// Values taken from the reference implementation, not guessed:
/// `docs/security/ANTIGRAVITY_AUTH.md` in `wiseai/picoclaw`, which states the
/// credentials are base64-encoded there "for sync with pi-ai".
void main() {
  group('the client is the Antigravity one', () {
    test('not the Gemini CLI client that produced invalid_scope', () {
      // The full Gemini CLI client id cannot appear here: GitHub push
      // protection refuses the credential pattern, so the negative check keys
      // on the id prefix, which is not itself a credential.
      expect(
        AntigravityOAuthProvider.clientId,
        isNot(startsWith('681255809395-')),
        reason:
            'that prefix is the Gemini CLI client and it rejects these scopes',
      );
      expect(
        AntigravityOAuthProvider.clientId,
        endsWith('.apps.googleusercontent.com'),
        reason: 'the client id is a Google OAuth client, shaped like one',
      );
    });

    test('carries the secret, because it is a confidential client', () {
      // A confidential client will not exchange a code without it. Sending
      // client_id alone fails at the token endpoint, not at the consent screen,
      // which makes it look like a different bug.
      expect(AntigravityOAuthProvider.clientSecret, isNotEmpty);
    });
  });

  group('the scopes', () {
    test('are the full URLs, not the short forms', () {
      // Google accepts both spellings, but only the registered form matches
      // the client's scope list. The short forms are what appeared verbatim in
      // the `invalid_scope` response.
      for (final scope in AntigravityOAuthProvider.scopes) {
        expect(
          scope,
          startsWith('https://www.googleapis.com/auth/'),
          reason: '"$scope" is not a full scope URL',
        );
      }
    });

    test('include all five Antigravity registers', () {
      expect(
        AntigravityOAuthProvider.scopes,
        containsAll(<String>[
          'https://www.googleapis.com/auth/cloud-platform',
          'https://www.googleapis.com/auth/userinfo.email',
          'https://www.googleapis.com/auth/userinfo.profile',
          'https://www.googleapis.com/auth/cclog',
          'https://www.googleapis.com/auth/experimentsandconfigs',
        ]),
      );
    });

    test('are space separated on the wire, which is what Google expects', () {
      // More than one scope, so the separator is load-bearing. A comma-separated
      // list is silently misread as one unknown scope.
      expect(AntigravityOAuthProvider.scopes.length, greaterThan(1));
      expect(
        AntigravityOAuthProvider.scopeParameter,
        AntigravityOAuthProvider.scopes.join(' '),
      );
      expect(AntigravityOAuthProvider.scopeParameter, isNot(contains(',')));
    });
  });

  group('the authorization request', () {
    test('asks for consent, so a refresh token is actually issued', () {
      // Without `prompt=consent` Google may skip the consent screen entirely
      // and return no refresh token, which then fails at the *next* login with
      // "OAuth refresh token missing" and looks like a different fault.
      expect(AntigravityOAuthProvider.prompt, 'consent');
    });

    test('requests offline access, so the credential can be renewed', () {
      expect(AntigravityOAuthProvider.accessType, 'offline');
    });
  });

  group('token exchange', () {
    test('sends the secret, which a confidential client requires', () {
      expect(
        AntigravityOAuthProvider.tokenRequestFields(
          code: 'test-code',
          codeVerifier: 'test-verifier',
          redirectUri: 'http://127.0.0.1:1/callback',
        ),
        containsPair('client_secret', AntigravityOAuthProvider.clientSecret),
      );
    });

    test('sends the client id alongside it', () {
      expect(
        AntigravityOAuthProvider.tokenRequestFields(
          code: 'test-code',
          codeVerifier: 'test-verifier',
          redirectUri: 'http://127.0.0.1:1/callback',
        ),
        containsPair('client_id', AntigravityOAuthProvider.clientId),
      );
    });

    test('carries the PKCE verifier and redirect, unchanged', () {
      final fields = AntigravityOAuthProvider.tokenRequestFields(
        code: 'test-code',
        codeVerifier: 'test-verifier',
        redirectUri: 'http://127.0.0.1:1/callback',
      );
      expect(fields['code'], 'test-code');
      expect(fields['code_verifier'], 'test-verifier');
      expect(fields['redirect_uri'], 'http://127.0.0.1:1/callback');
      expect(fields['grant_type'], 'authorization_code');
    });
  });

  test('the refresh request carries the secret too', () {
    // Same client, same requirement. A refresh that omits it fails on the first
    // expiry, long after the login that would have revealed the problem.
    expect(
      AntigravityOAuthProvider.refreshRequestFields('a-refresh-token'),
      containsPair('client_secret', AntigravityOAuthProvider.clientSecret),
    );
  });
}
