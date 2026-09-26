import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';

/// Reuse detection must not punish a benign race (audit C-04, C-25).
///
/// Google's `/revoke` revokes the whole grant, not just the presented token.
/// A rotating refresh token is single-use, so two concurrent exchanges of the
/// same token make the loser receive `invalid_grant`. Revoking on that signal
/// logs the user out of a healthy account: the token the winner just received
/// dies with it. Revocation must therefore require positive evidence that the
/// token was already rotated out, not merely that the exchange failed.
void main() {
  String secretWith(String refreshToken) =>
      jsonEncode({'accessToken': 'old-access', 'refreshToken': refreshToken});

  final revoke = Uri.parse(AntigravityOAuthProvider.revokeEndpoint);
  bool isToken(Uri uri) => uri.path.endsWith('/token');

  test('two concurrent exchanges of a not-yet-rotated token share one request '
      'and do not revoke', () async {
    final gate = Completer<void>();
    var tokenCalls = 0;
    final http = _GateHttp((uri) async {
      if (!isToken(uri)) {
        return const AntigravityOAuthHttpResponse(statusCode: 200, body: '{}');
      }
      tokenCalls++;
      // Park the first caller so a second, un-coalesced caller would be
      // observable instead of silently serialised by response ordering.
      if (!gate.isCompleted) await gate.future;
      return AntigravityOAuthHttpResponse(
        statusCode: 200,
        body: jsonEncode({
          'access_token': 'new-access',
          'refresh_token': 'new-refresh',
          'expires_in': 3600,
        }),
      );
    });
    final provider = AntigravityOAuthProvider(http: http);
    final original = secretWith('old-refresh');

    final first = provider.refresh(original);
    final second = provider.refresh(original);
    await Future<void>.delayed(Duration.zero);
    gate.complete();

    expect(await first, contains('new-access'));
    expect(await second, contains('new-access'));
    expect(tokenCalls, 1, reason: 'one exchange must serve both callers');
    expect(
      http.logs.any((entry) => entry.uri == revoke),
      isFalse,
      reason: 'a benign race must not revoke the surviving grant',
    );
  });

  test(
    'a token that was genuinely rotated out and rejected still revokes',
    () async {
      var exchanges = 0;
      final http = _GateHttp((uri) async {
        if (uri == revoke) {
          return const AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: '{}',
          );
        }
        exchanges++;
        if (exchanges == 1) {
          return AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: jsonEncode({
              'access_token': 'new-access',
              'refresh_token': 'new-refresh',
              'expires_in': 3600,
            }),
          );
        }
        return const AntigravityOAuthHttpResponse(
          statusCode: 400,
          body: '{"error":"invalid_grant"}',
        );
      });
      final provider = AntigravityOAuthProvider(http: http);
      final original = secretWith('old-refresh');

      await provider.refresh(original);
      await expectLater(
        provider.refresh(original),
        throwsA(
          predicate<Object>((e) => e.toString().contains('invalid_grant')),
        ),
      );

      expect(
        http.logs.any(
          (entry) => entry.uri == revoke && entry.body.contains('old-refresh'),
        ),
        isTrue,
        reason: 'a rotated-out token must revoke the chain',
      );
    },
  );

  test(
    'the rotated-token ledger is bounded, not an unbounded plaintext set',
    () async {
      var exchange = 0;
      final http = _GateHttp((uri) async {
        if (uri == revoke) {
          return const AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: '{}',
          );
        }
        exchange++;
        return AntigravityOAuthHttpResponse(
          statusCode: 200,
          body: jsonEncode({
            'access_token': 'a$exchange',
            'refresh_token': 'rotated-$exchange',
            'expires_in': 3600,
          }),
        );
      });
      final provider = AntigravityOAuthProvider(http: http);

      final budget = AntigravityOAuthProvider.maxRememberedRotatedRefreshTokens;
      for (var i = 0; i < budget + 8; i++) {
        await provider.refresh(secretWith('token-$i'));
      }

      expect(
        provider.rememberedRotatedRefreshTokenCount,
        lessThanOrEqualTo(budget),
        reason:
            'the ledger must not grow without bound for a long-lived process',
      );
    },
  );
}

/// Records every request and lets the test decide the response, so a race can
/// be staged deterministically instead of relying on response ordering.
class _GateHttp implements AntigravityOAuthHttpRunner {
  _GateHttp(this.handler);

  final Future<AntigravityOAuthHttpResponse> Function(Uri uri) handler;
  final logs = <({Uri uri, String body})>[];

  @override
  Future<AntigravityOAuthHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) {
    logs.add((uri: uri, body: body));
    return handler(uri);
  }
}
