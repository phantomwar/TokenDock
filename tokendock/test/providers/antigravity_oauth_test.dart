import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/providers/antigravity/antigravity_local.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/providers/antigravity/antigravity_provider.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';
import 'package:tokendock/storage/secret_store.dart';

void main() {
  test('remote provider keeps account tokens isolated', () async {
    final store = _Store();
    final http = _Http([
      _Response(200, jsonEncode({'access_token': 'access-a', 'refresh_token': 'refresh-a', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'project-a'}})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'groups': [{'groupId': 'gemini', 'buckets': [{'bucketId': 'weekly', 'remainingFraction': 0.25}]}]}})),
    ]);
    final provider = AntigravityOAuthProvider(http: http, secretStore: store);
    final connection = _connection('a');
    await provider.login(connection, code: 'code-a', codeVerifier: 'verifier-a', redirectUri: 'http://127.0.0.1/callback');
    expect(await store.read(connection.credentialRef), contains('access-a'));
    expect(provider.authKind, AuthKind.oauth);
    final snapshot = await provider.fetch(connection, (await store.read(connection.credentialRef))!);
    expect(snapshot.error, isNull);
    expect(snapshot.quotas.single.id, 'gemini-weekly');
  });

  test('provider routes opted-in local sources through the local reader', () async {
    final local = AntigravityProvider(
      localReader: AntigravityLocalReader(processRunner: _FakeProcessRunner([
        AntigravityProcessResult(
          exitCode: 0,
          stdout: 'agy 1.1.11\n',
          stderr: '',
        ),
        AntigravityProcessResult(
          exitCode: 0,
          stdout: jsonEncode({
            'quotaInfo': {
              'gemini': {'remainingFraction': 0.25},
            },
          }),
          stderr: '',
        ),
        AntigravityProcessResult(exitCode: 0, stdout: 'agy 1.1.11\n', stderr: ''),
        AntigravityProcessResult(
          exitCode: 0,
          stdout: jsonEncode({
            'quotaInfo': {
              'gemini': {'remainingFraction': 0.25},
            },
          }),
          stderr: '',
        ),
      ])),
    );
    final localConnection = _connection('local', providerData: jsonEncode({'source': 'agy-cli'}));

    expect((await local.fetch(localConnection, '')).quotas.single.remaining, 0.25);
    expect((await local.test(localConnection, '')).error, isNull);
  });

  test('provider keeps remote source as the default and explicit mode', () async {
    final http = _Http([
      _Response(200, jsonEncode({
        'response': {
          'accountEmail': 'a@example.com',
          'accountId': 'acct-a',
          'groups': [
            {
              'groupId': 'gemini',
              'buckets': [
                {'bucketId': 'weekly', 'remainingFraction': 0.4},
              ],
            },
          ],
        },
      })),
      _Response(200, jsonEncode({
        'response': {
          'accountEmail': 'a@example.com',
          'accountId': 'acct-a',
          'groups': [
            {
              'groupId': 'gemini',
              'buckets': [
                {'bucketId': 'weekly', 'remainingFraction': 0.4},
              ],
            },
          ],
        },
      })),
    ]);
    final provider = AntigravityProvider(http: http);
    final secret = jsonEncode({
      'accessToken': 'a',
      'identityKey': 'a@example.com|acct-a',
      'projectId': 'p',
    });

    expect((await provider.fetch(_connection('remote'), secret)).quotas.single.remaining, 0.4);
    expect(
      (await provider.fetch(
        _connection('explicit', providerData: jsonEncode({'source': 'remote'})),
        secret,
      )).quotas.single.remaining,
      0.4,
    );
  });

  test('mismatched selected account is rejected', () async {
    final store = _Store();
    final http = _Http([
      _Response(200, jsonEncode({'access_token': 'access-a', 'refresh_token': 'refresh-a', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'project-a'}})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'other@example.com', 'accountId': 'acct-a', 'quotaInfo': {'gemini': {'remainingFraction': 0.5}}}})),
    ]);
    final provider = AntigravityOAuthProvider(http: http, secretStore: store);
    final connection = _connection('a');
    await provider.login(connection, code: 'code', codeVerifier: 'verifier', redirectUri: 'http://127.0.0.1/callback');
    final snapshot = await provider.fetch(connection, (await store.read(connection.credentialRef))!);
    expect(snapshot.error, 'account_mismatch');
  });
  test('empty project requires onboarding', () async {
    final store = _Store();
    final http = _Http([
      _Response(200, jsonEncode({'access_token': 'access', 'refresh_token': 'refresh', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': ''}})),
    ]);
    final provider = AntigravityOAuthProvider(http: http, secretStore: store);
    await expectLater(provider.login(_connection('a'), code: 'code', codeVerifier: 'verifier', redirectUri: 'http://127.0.0.1/callback'), throwsA(isA<AntigravityOnboardingRequired>()));
  });
  test('quota schema rejects malformed remaining and reset but accepts reset-only bucket', () async {
    final provider = AntigravityOAuthProvider(http: _Http([
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'groups': [
        {'groupId': 'gemini', 'buckets': [
          {'bucketId': 'bad-remaining', 'remaining': 'not-a-map', 'resetTime': '2030-01-01T00:00:00Z'},
        ]},
      ]}})),
    ]));
    final malformed = await provider.fetch(_connection('a'), jsonEncode({'accessToken': 'a', 'identityKey': 'a@example.com|acct-a', 'projectId': 'p'}));
    expect(malformed.error, 'quota_source_changed');

    final valid = AntigravityOAuthProvider(http: _Http([
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'groups': [
        {'groupId': 'gemini', 'buckets': [
          {'bucketId': 'weekly', 'resetTime': '2030-01-01T00:00:00Z'},
        ]},
      ]}})),
    ]));
    final resetOnly = await valid.fetch(_connection('a'), jsonEncode({'accessToken': 'a', 'identityKey': 'a@example.com|acct-a', 'projectId': 'p'}));
    expect(resetOnly.error, isNull);
    expect(resetOnly.quotas.single.remaining, isNull);

    final badReset = AntigravityOAuthProvider(http: _Http([
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'groups': [
        {'groupId': 'gemini', 'buckets': [
          {'bucketId': 'weekly', 'resetTime': 'not-a-date'},
        ]},
      ]}})),
    ]));
    expect((await badReset.fetch(_connection('a'), jsonEncode({'accessToken': 'a', 'identityKey': 'a@example.com|acct-a', 'projectId': 'p'}))).error, 'quota_source_changed');
  });

  test('quota schema rejects non-finite and out-of-range fractions', () async {
    for (final fraction in <dynamic>[double.nan, double.infinity, -0.1, 1.1, '2']) {
      final provider = AntigravityOAuthProvider(http: _Http([
        _Response(200, jsonEncode({
          'response': {
            'accountEmail': 'a@example.com',
            'accountId': 'acct-a',
            'groups': [
              {
                'groupId': 'gemini',
                'buckets': [
                  {'bucketId': 'weekly', 'remainingFraction': '$fraction'},
                ],
              },
            ],
          },
        })),
      ]));

      final snapshot = await provider.fetch(
        _connection('a'),
        jsonEncode({
          'accessToken': 'a',
          'identityKey': 'a@example.com|acct-a',
          'projectId': 'p',
        }),
      );
      expect(snapshot.error, 'quota_source_changed', reason: '$fraction');
    }
  });

  test('legacy direct model quotaInfo inserts under model name and keeps worst pool fraction', () async {
    final provider = AntigravityOAuthProvider(http: _Http([
      _Response(404, '{}'),
      _Response(404, '{}'),
      _Response(200, jsonEncode({'response': {'models': [
        {'name': 'gemini-pro', 'quotaInfo': {'remainingFraction': 0.2, 'resetTime': '2030-01-01T00:00:00Z'}},
      ]}})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'quotaInfo': {
        'gemini': {'remainingFraction': 0.8, 'resetTime': '2030-01-01T00:00:00Z'},
      }}})),
    ]));
    final snapshot = await provider.fetch(_connection('a'), jsonEncode({'accessToken': 'a', 'identityKey': 'a@example.com|acct-a', 'projectId': 'p'}));
    expect(snapshot.error, isNull);
    expect(snapshot.quotas.single.remaining, 0.2);
  });

  test('refresh preserves refresh token when Google omits rotation', () async {
    final http = _Http([_Response(200, jsonEncode({'access_token': 'new-access', 'expires_in': 3600}))]);
    final provider = AntigravityOAuthProvider(http: http);
    final secret = await provider.refresh(jsonEncode({'accessToken': 'old', 'refreshToken': 'keep-me', 'identityKey': 'a@example.com|acct-a'}));
    final value = jsonDecode(secret) as Map<String, dynamic>;
    expect(value['accessToken'], 'new-access');
    expect(value['refreshToken'], 'keep-me');
  });

  test('refresh invalid_grant is definitive', () async {
    final provider = AntigravityOAuthProvider(http: _Http([_Response(400, '{"error":"invalid_grant"}')]));
    await expectLater(provider.refresh(jsonEncode({'refreshToken': 'revoked'})), throwsA(isA<StateError>()));
  });

  test('test refreshes an expiring refreshable credential once before fetch', () async {
    final http = _RecordingHttp([
      _Response(200, jsonEncode({'access_token': 'fresh', 'expires_in': 3600})),
      _Response(200, jsonEncode({
        'response': {
          'accountEmail': 'a@example.com',
          'accountId': 'acct-a',
          'groups': [
            {
              'groupId': 'gemini',
              'buckets': [
                {'bucketId': 'weekly', 'remainingFraction': 0.4},
              ],
            },
          ],
        },
      })),
    ]);
    final provider = AntigravityOAuthProvider(http: http);
    final secret = jsonEncode({
      'accessToken': 'stale',
      'refreshToken': 'refresh',
      'expiresAt': DateTime.now().toUtc().subtract(const Duration(seconds: 1)).toIso8601String(),
      'identityKey': 'a@example.com|acct-a',
      'projectId': 'p',
    });

    final result = await provider.test(_connection('a'), secret);

    expect(result.error, isNull);
    expect(http.requests.map((request) => request.uri), [
      Uri.parse(AntigravityOAuthProvider.tokenEndpoint),
      Uri.parse('${AntigravityOAuthProvider.prodHost}/v1internal:retrieveUserQuotaSummary'),
    ]);
  });

  test('rotated refresh-token reuse revokes the local pair and requires relogin', () async {
    final http = _RecordingHttp([
      _Response(200, jsonEncode({'access_token': 'new-access', 'refresh_token': 'new-refresh', 'expires_in': 3600})),
      _Response(400, '{"error":"invalid_grant"}'),
      _Response(200, '{}'),
    ]);
    final provider = AntigravityOAuthProvider(http: http);
    final original = jsonEncode({'accessToken': 'old', 'refreshToken': 'old-refresh'});

    await provider.refresh(original);

    await expectLater(
      provider.refresh(original),
      throwsA(
        predicate<Object>((error) => error.toString().contains('invalid_grant')),
      ),
    );
    expect(
      http.requests.any(
        (request) => request.uri == Uri.parse('https://oauth2.googleapis.com/revoke') &&
            request.body.contains('old-refresh'),
      ),
      isTrue,
    );
  });

  test('two accounts keep independent OAuth secrets', () async {
    final store = _Store();
    final a = AntigravityOAuthProvider(http: _Http([
      _Response(200, jsonEncode({'access_token': 'access-a', 'refresh_token': 'refresh-a', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'project-a'}})),
    ]), secretStore: store);
    final b = AntigravityOAuthProvider(http: _Http([
      _Response(200, jsonEncode({'access_token': 'access-b', 'refresh_token': 'refresh-b', 'expires_in': 3600, 'accountEmail': 'b@example.com', 'accountId': 'acct-b'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'b@example.com', 'accountId': 'acct-b', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'project-b'}})),
    ]), secretStore: store);
    await a.login(_connection('a'), code: 'a', codeVerifier: 'a', redirectUri: 'http://127.0.0.1/callback');
    await b.login(_connection('b'), code: 'b', codeVerifier: 'b', redirectUri: 'http://127.0.0.1/callback');
    expect(await store.read('secret-a'), contains('access-a'));
    expect(await store.read('secret-b'), contains('access-b'));
    expect(await store.read('secret-a'), isNot(contains('access-b')));
  });

  test('loginWithLoopback launches browser, delivers callback, and closes session', () async {
    final store = _Store();
    final http = _RecordingHttp([
      _Response(200, jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'p'}})),
    ]);
    Uri? opened;
    int? callbackStatus;
    final provider = AntigravityOAuthProvider(
      http: http,
      secretStore: store,
      launchExternalBrowser: (url) async {
        opened = url;
        final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
        final client = HttpClient();
        try {
          final response = await (await client.getUrl(redirect.replace(queryParameters: {
            'code': 'loop-code',
            'state': url.queryParameters['state']!,
          }))).close();
          callbackStatus = response.statusCode;
          await response.drain<void>();
        } finally {
          client.close(force: true);
        }
      },
    );

    final result = await provider.loginWithLoopback(_connection('a'));

    expect(result.identityKey, 'a@example.com|acct-a');
    expect(opened, isNotNull);
    expect(opened!.origin, 'https://accounts.google.com');
    expect(opened!.queryParameters['code_challenge_method'], 'S256');
    expect(opened!.queryParameters['code_challenge'], matches(RegExp(r'^[A-Za-z0-9_-]+$')));
    expect(opened!.queryParameters['state'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(opened!.queryParameters['redirect_uri'], startsWith('http://127.0.0.1:'));
    expect(callbackStatus, HttpStatus.ok);
    final tokenBody = jsonDecode(http.requests.first.body) as Map<String, dynamic>;
    expect(tokenBody['code'], 'loop-code');
    expect(tokenBody['redirect_uri'], opened!.queryParameters['redirect_uri']);
    expect(tokenBody, isNot(contains('client_secret')));
    expect(await store.read('secret-a'), contains('refreshToken'));

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    await expectLater(
      client.getUrl(Uri.parse(opened!.queryParameters['redirect_uri']!)).then((request) => request.close()),
      throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
    );
  });

  test('loadCodeAssist falls back from production transport failure to daily', () async {
    final http = _HostHttp({
      'https://oauth2.googleapis.com/token': _Response(200, jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      'https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist': AntigravityTransportFailure(Exception('offline')),
      'https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist': _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'p'}})),
    });
    final provider = AntigravityOAuthProvider(http: http);
    final result = await provider.login(_connection('a'), code: 'c', codeVerifier: 'v', redirectUri: 'http://127.0.0.1/callback');
    expect(result.projectId, 'p');
  });


  test('onboarding identity mismatch is rejected', () async {
    final provider = AntigravityOAuthProvider(http: _Http([
      _Response(200, jsonEncode({'access_token': 'a', 'refresh_token': 'r', 'expires_in': 3600, 'accountEmail': 'a@example.com', 'accountId': 'acct-a'})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'a@example.com', 'accountId': 'acct-a', 'cloudaicompanionProject': 'p'}})),
      _Response(200, jsonEncode({'response': {'accountEmail': 'other@example.com', 'accountId': 'acct-a', 'currentTier': {'id': 'free'}, 'cloudaicompanionProject': 'p'}})),
    ]));
    await expectLater(provider.login(_connection('a'), code: 'c', codeVerifier: 'v', redirectUri: 'http://127.0.0.1/callback'), throwsA(isA<StateError>()));
  });

  test('transient quota statuses produce warnings for 429 and 503', () async {
    final provider = AntigravityOAuthProvider(http: _Http([_Response(429, '{}'), _Response(503, '{}')]));
    final secret = jsonEncode({'accessToken': 'a', 'identityKey': 'a@example.com|acct-a', 'projectId': 'p'});
    final first = await provider.fetch(_connection('a'), secret);
    final second = await provider.fetch(_connection('a'), secret);
    expect(first.status.name, 'warning');
    expect(first.error, contains('429'));
    expect(second.status.name, 'warning');
    expect(second.error, contains('503'));
  });

  test('Retry-After seconds and HTTP-date set the transient cooldown floor', () async {
    final secret = jsonEncode({
      'accessToken': 'a',
      'identityKey': 'a@example.com|acct-a',
      'projectId': 'p',
    });
    final seconds = AntigravityOAuthProvider(http: _Http([
      _Response(429, '{}', retryAfter: '120'),
    ]));
    final first = await seconds.fetch(_connection('seconds'), secret);
    expect(
      first.cooldownUntil!.difference(first.fetchedAt),
      greaterThanOrEqualTo(const Duration(seconds: 119)),
    );

    final retryAt = DateTime.now().toUtc().add(const Duration(minutes: 4));
    final dated = AntigravityOAuthProvider(http: _Http([
      _Response(503, '{}', retryAfter: HttpDate.format(retryAt.toUtc())),
    ]));
    final second = await dated.fetch(_connection('dated'), secret);
    expect(second.cooldownUntil, isNotNull);
    expect(second.cooldownUntil!.difference(first.fetchedAt).inSeconds, inInclusiveRange(239, 241));
  });

  test('registry registers the default remote Antigravity provider', () {
    final registry = ProviderRegistry.withDefaults();
    expect(registry.get('antigravity'), isA<AntigravityOAuthProvider>());
  });

  test('retry policy honors first Retry-After floor and later Full Jitter', () {
    expect(
      AntigravityOAuthProvider.retryDelay(
        const Duration(seconds: 30),
        0,
      ),
      const Duration(seconds: 30),
    );
    final later = AntigravityOAuthProvider.retryDelay(
      const Duration(seconds: 30),
      3,
      random: _FixedRandom(0),
    );
    expect(later, Duration.zero);
  });
}
class _RecordingHttp extends _Http {
  _RecordingHttp(super.responses);
}

class _FixedRandom implements Random {
  _FixedRandom(this.value);
  final int value;
  @override
  bool nextBool() => false;
  @override
  double nextDouble() => value.toDouble();
  @override
  int nextInt(int max) => value;
}
class _HostHttp implements AntigravityOAuthHttpRunner {
  _HostHttp(this.responses);
  final Map<String, dynamic> responses;
  @override
  Future<AntigravityOAuthHttpResponse> post(Uri uri, {required Map<String, String> headers, required String body}) async {
    final value = responses[uri.toString()];
    if (value is AntigravityTransportFailure) throw value.cause;
    if (value is Exception) throw value;
    final response = value as _Response;
    return AntigravityOAuthHttpResponse(statusCode: response.statusCode, body: response.body, retryAfter: response.retryAfter);
  }
}

Connection _connection(String id, {String? providerData}) => Connection(id: id, provider: 'antigravity', displayName: 'Antigravity', group: null, plan: null, credentialRef: 'secret-$id', enabled: true, providerData: providerData);
class _Store implements SecretStore {
  final values = <String, String>{};
  @override Future<void> delete(String key) async => values.remove(key);
  @override Future<String?> read(String key) async => values[key];
  @override Future<void> write(String key, String value) async => values[key] = value;
}
class _Response {
  _Response(this.statusCode, this.body, {this.retryAfter});
  final int statusCode;
  final String body;
  final String? retryAfter;
}
class _Http implements AntigravityOAuthHttpRunner {
  _Http(this.responses);
  final List<_Response> responses;
  final requests = <({Uri uri, Map<String, String> headers, String body})>[];
  @override
  Future<AntigravityOAuthHttpResponse> post(Uri uri, {required Map<String, String> headers, required String body}) async {
    requests.add((uri: uri, headers: headers, body: body));
    final result = responses.removeAt(0);
    return AntigravityOAuthHttpResponse(
      statusCode: result.statusCode,
      body: result.body,
      retryAfter: result.retryAfter,
    );
  }
}

class _FakeProcessRunner implements AntigravityProcessRunner {
  _FakeProcessRunner(this.results);
  final List<AntigravityProcessResult> results;

  @override
  Future<AntigravityProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
    int? maxOutputBytes,
  }) async => results.removeAt(0);
}
