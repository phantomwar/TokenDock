import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/services/credential_events.dart';

/// A credential read that is not valid JSON must be reported, not smuggled into
/// a request (audit C-10).
///
/// `_credential` caught the parse failure and returned `{'accessToken': raw}`,
/// so a DPAPI read that returned garbage, a truncated blob, or an empty value
/// became a literal bearer token. The account then failed with an opaque 401
/// instead of "this credential is unreadable", and a real provider error was
/// indistinguishable from local corruption.
void main() {
  const connection = Connection(
    id: 'c1',
    provider: 'antigravity',
    displayName: 'Antigravity',
    group: null,
    plan: null,
    credentialRef: 'ref',
    enabled: true,
    authType: 'oauth',
    identityKey: 'user@example.com|acct-1',
    providerData: '{"source":"remote","projectId":"proj-1"}',
  );

  group('remote fetch', () {
    test('an unreadable credential is reported as such, not sent as a bearer', () async {
      var posted = false;
      final provider = AntigravityOAuthProvider(
        launchExternalBrowser: (_) async {},
        http: _Recording((uri, {headers, body}) async {
          posted = true;
          return const AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: '{}',
          );
        }),
      );

      // Not JSON: what a truncated or corrupted secure-storage read looks like.
      final snapshot = await provider.fetch(connection, 'not-json-at-all');

      expect(posted, isFalse, reason: 'no request may carry a broken secret');
      expect(snapshot.status, isNot(ConnectionStatus.ok));
      expect(snapshot.error, isNotNull);
    });

    test('an empty credential is reported, not sent', () async {
      var posted = false;
      final provider = AntigravityOAuthProvider(
        launchExternalBrowser: (_) async {},
        http: _Recording((uri, {headers, body}) async {
          posted = true;
          return const AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: '{}',
          );
        }),
      );

      final snapshot = await provider.fetch(connection, '');

      expect(posted, isFalse);
      expect(snapshot.status, isNot(ConnectionStatus.ok));
    });

    test('a truncated JSON credential is reported', () async {
      var posted = false;
      final provider = AntigravityOAuthProvider(
        launchExternalBrowser: (_) async {},
        http: _Recording((uri, {headers, body}) async {
          posted = true;
          return const AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: '{}',
          );
        }),
      );

      final snapshot = await provider.fetch(
        connection,
        '{"accessToken":"ya29.partial',
      );

      expect(posted, isFalse);
      expect(snapshot.error, isNotNull);
    });

    test('a well-formed credential still reaches the provider', () async {
      var posted = false;
      final provider = AntigravityOAuthProvider(
        launchExternalBrowser: (_) async {},
        http: _Recording((uri, {headers, body}) async {
          posted = true;
          if (uri.path.endsWith('/loadCodeAssist') ||
              uri.path.contains('loadCodeAssist')) {
            return AntigravityOAuthHttpResponse(
              statusCode: 200,
              body: jsonEncode({
                'currentTier': {'id': 'free'},
                'cloudaicompanionProject': 'proj-1',
              }),
            );
          }
          if (uri.path.contains('retrieveUserQuotaSummary')) {
            return const AntigravityOAuthHttpResponse(
              statusCode: 200,
              body: '{"quotaSummaries":[]}',
            );
          }
          return const AntigravityOAuthHttpResponse(
            statusCode: 200,
            body: '{}',
          );
        }),
      );

      final snapshot = await provider.fetch(
        connection,
        jsonEncode({
          'accessToken': 'ya29.validtoken',
          'projectId': 'proj-1',
          'identityKey': 'user@example.com|acct-1',
          'expiresAt': DateTime.now()
              .toUtc()
              .add(const Duration(hours: 1))
              .toIso8601String(),
        }),
      );

      expect(posted, isTrue, reason: 'a valid credential must still be used');
      // The account guard still applies to this stub response; what matters is
      // that the credential was accepted rather than rejected as unreadable.
      expect(snapshot.error, isNot(contains('unreadable')));
    });
  });

  group('definitive failure classification', () {
    test('classifies a real 401 by status, not by message shape', () {
      expect(
        definitiveOAuthFailureCause(const AntigravityTransportFailure(401)),
        'bare_401',
      );
    });

    test('does not treat an unrelated message as a 401', () {
      // A StateError whose text merely happens to end in 401 was previously
      // classified as a definitive credential failure, which tore down a
      // working connection.
      expect(
        definitiveOAuthFailureCause(
          StateError('provider returned row 401 of the usage report'),
        ),
        isNull,
      );
    });

    test('still recognises invalid_grant, which has no status of its own', () {
      expect(
        definitiveOAuthFailureCause(StateError('invalid_grant')),
        'invalid_grant',
      );
    });

    test('a 403 guardrail is not a credential failure', () {
      expect(
        definitiveOAuthFailureCause(const AntigravityTransportFailure(403)),
        isNull,
        reason: '403 means forbidden, not a rejected credential',
      );
    });
  });
}

class _Recording implements AntigravityOAuthHttpRunner {
  _Recording(this.handler);
  final Future<AntigravityOAuthHttpResponse> Function(
    Uri uri, {
    Map<String, String>? headers,
    String? body,
  })
  handler;

  @override
  Future<AntigravityOAuthHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) => handler(uri, headers: headers, body: body);
}
