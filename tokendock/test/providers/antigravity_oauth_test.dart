import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';
import 'package:tokendock/storage/secret_store.dart';

void main() {
  test('remote provider is registered as oauth and keeps account tokens isolated', () async {
    final store = _Store();
    final http = _Http([
      _Response(200, jsonEncode({
        'access_token': 'access-a',
        'refresh_token': 'refresh-a',
        'expires_in': 3600,
        'accountEmail': 'a@example.com',
        'accountId': 'acct-a',
      })),
      _Response(200, jsonEncode({
        'response': {
          'currentTier': {'id': 'free'},
          'cloudaicompanionProject': 'project-a',
        },
      })),
      _Response(200, jsonEncode({
        'response': {
          'accountEmail': 'a@example.com',
          'accountId': 'acct-a',
          'groups': [
            {'groupId': 'gemini', 'buckets': [
              {'bucketId': 'weekly', 'remainingFraction': 0.25},
            ]},
          ],
        },
      })),
    ]);
    final provider = AntigravityOAuthProvider(http: http, secretStore: store);
    final connection = _connection('a');
    await provider.login(connection, code: 'code-a', codeVerifier: 'verifier-a', redirectUri: 'http://127.0.0.1/callback');
    expect(await store.read(connection.credentialRef), contains('access-a'));
    expect(provider.authKind, AuthKind.oauth);
    expect(http.requests[0].body, isNot(contains('client_secret')));
    final snapshot = await provider.fetch(connection, (await store.read(connection.credentialRef))!);
    expect(snapshot.error, isNull);
    expect(snapshot.quotas.single.id, 'gemini-weekly');
  });

  test('mismatched selected account is rejected without caching', () async {
    final store = _Store();
    final http = _Http([
      _Response(200, jsonEncode({
        'access_token': 'access-a', 'refresh_token': 'refresh-a', 'expires_in': 3600,
        'accountEmail': 'a@example.com', 'accountId': 'acct-a',
      })),
      _Response(200, jsonEncode({
        'response': {'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'project-a'},
      })),
      _Response(200, jsonEncode({
        'response': {'accountEmail': 'other@example.com', 'accountId': 'acct-a', 'quotaInfo': {
          'gemini': {'remainingFraction': 0.5},
        }},
      })),
    ]);
    final provider = AntigravityOAuthProvider(http: http, secretStore: store);
    final connection = _connection('a');
    await provider.login(connection, code: 'code', codeVerifier: 'verifier', redirectUri: 'http://127.0.0.1/callback');
    final snapshot = await provider.fetch(connection, (await store.read(connection.credentialRef))!);
    expect(snapshot.error, 'Account mismatch');
  });

  test('empty project requires onboarding instead of inventing a project', () async {
    final store = _Store();
    final http = _Http([
      _Response(200, jsonEncode({
        'access_token': 'access', 'refresh_token': 'refresh', 'expires_in': 3600,
        'accountEmail': 'a@example.com', 'accountId': 'acct-a',
      })),
      _Response(200, jsonEncode({
        'response': {'currentTier': {'id': 'free'}, 'cloudaicompanionProject': ''},
      })),
    ]);
    final provider = AntigravityOAuthProvider(http: http, secretStore: store);
    await expectLater(
      provider.login(_connection('a'), code: 'code', codeVerifier: 'verifier', redirectUri: 'http://127.0.0.1/callback'),
      throwsA(isA<AntigravityOnboardingRequired>()),
    );
  });
}

Connection _connection(String id) => Connection(
      id: id, provider: 'antigravity', displayName: 'Antigravity', group: null,
      plan: null, credentialRef: 'secret-$id', enabled: true,
    );

class _Store implements SecretStore {
  final values = <String, String>{};
  @override Future<void> delete(String key) async => values.remove(key);
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async => values[key] = value;
}

class _Response {
  _Response(this.statusCode, this.body);
  final int statusCode;
  final String body;
}

class _Http implements AntigravityOAuthHttpRunner {
  _Http(this.responses);
  final List<_Response> responses;
  final requests = <({Uri uri, String body})>[];
  @override
  Future<AntigravityOAuthHttpResponse> post(Uri uri, {required Map<String, String> headers, required String body}) async {
    requests.add((uri: uri, body: body));
    final result = responses.removeAt(0);
    return AntigravityOAuthHttpResponse(statusCode: result.statusCode, body: result.body);
  }
}
