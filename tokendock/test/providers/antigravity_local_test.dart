import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/antigravity/antigravity_local.dart';

String fixture(String name) {
  final candidates = [
    'test/fixtures/$name',
    'tokendock/test/fixtures/$name',
    '../test/fixtures/$name',
  ];
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file.readAsStringSync();
  }
  throw StateError('fixture not found: $name');
}

Connection connection({String? providerData, String? identityKey}) => Connection(
      id: 'agy-1',
      provider: 'antigravity',
      displayName: 'Antigravity',
      group: null,
      plan: null,
      credentialRef: '',
      enabled: true,
      identityKey: identityKey,
      providerData: providerData,
    );

void main() {
  test('quota summary maps Gemini and Claude/GPT pools and reset windows', () {
    final snapshot = AntigravityLocalReader.parseQuotaSummary(
      body: fixture('antigravity_quota_summary.json'),
      connectionId: 'agy-1',
    );

    expect(snapshot.status, ConnectionStatus.ok);
    expect(snapshot.quotas.map((q) => q.id), containsAll(['gemini-weekly', 'gemini-5h', 'claude-gpt-weekly', 'claude-gpt-5h']));
    final weekly = snapshot.quotas.firstWhere((q) => q.id == 'gemini-weekly');
    expect(weekly.percent, closeTo(25, 0.001));
    expect(weekly.remaining, closeTo(0.75, 0.001));
    expect(weekly.resetAt, DateTime.utc(2026, 9, 30));
  });

  test('legacy payload parses resetTime and rejects a mismatched account', () {
    final snapshot = AntigravityLocalReader.parseQuotaSummary(
      body: jsonEncode({
        'response': {
          'groups': [
            {
              'groupId': 'gemini',
              'buckets': [
                {
                  'bucketId': 'weekly',
                  'remainingFraction': 0.4,
                  'resetTime': '2026-10-01T00:00:00Z',
                },
              ],
            },
          ],
          'accountEmail': 'other@example.com',
        },
      }),
      connectionId: 'agy-1',
      expectedAccountKey: 'selected@example.com',
    );

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.error, 'Account mismatch');
  });

  test('missing agy identity is rejected when selected account is required', () {
    final snapshot = AntigravityLocalReader.parseAgyPrint(
      jsonEncode({'quotaInfo': {'gemini': {'remainingFraction': 0.5}}}),
      connectionId: 'agy-1',
      expectedAccountKey: 'selected@example.com',
    );

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.error, 'Account mismatch');
  });

  test('language server accepts persisted composite account identity', () {
    final snapshot = AntigravityLocalReader.parseQuotaSummary(
      body: jsonEncode({
        'response': {
          'accountEmail': 'selected@example.com',
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
      }),
      connectionId: 'agy-1',
      expectedAccountKey: 'selected@example.com|acct-a',
      requireIdentity: true,
    );

    expect(snapshot.status, ConnectionStatus.ok);
  });

  test('agy accepts persisted composite account identity', () {
    final snapshot = AntigravityLocalReader.parseAgyPrint(
      jsonEncode({
        'accountEmail': 'selected@example.com',
        'accountId': 'acct-a',
        'quotaInfo': {
          'gemini': {'remainingFraction': 0.5},
        },
      }),
      connectionId: 'agy-1',
      expectedAccountKey: 'selected@example.com|acct-a',
    );

    expect(snapshot.status, ConnectionStatus.ok);
  });

  test('language server fetch accepts persisted composite account identity', () async {
    final reader = AntigravityLocalReader(
      httpRunner: _FakeHttpRunner([
        AntigravityHttpResponse(statusCode: 200, body: jsonEncode({
          'response': {
            'accountEmail': 'selected@example.com',
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
      ]),
    );

    final snapshot = await reader.fetchSnapshot(connection(
      identityKey: 'selected@example.com|acct-a',
      providerData: jsonEncode({'source': 'language-server', 'port': 1234}),
    ));

    expect(snapshot.status, ConnectionStatus.ok);
  });

  test('availability-only payload is reported as Limits not available', () {
    final snapshot = AntigravityLocalReader.parseQuotaSummary(
      body: fixture('antigravity_availability_only.json'),
      connectionId: 'agy-1',
    );

    expect(snapshot.status, ConnectionStatus.warning);
    expect(snapshot.quotas, hasLength(1));
    expect(snapshot.quotas.single.label, 'Limits not available');
    expect(snapshot.quotas.single.percent, isNull);
  });

  test('requires explicit source opt-in', () async {
    final reader = AntigravityLocalReader(
      processRunner: _FakeProcessRunner([]),
      httpRunner: _FakeHttpRunner([]),
    );

    final snapshot = await reader.fetchSnapshot(connection());

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.error, 'Antigravity source is not enabled');
  });

  test('language server tries quota summary, status, then model configs before agy', () async {
    final http = _FakeHttpRunner([
      const AntigravityHttpResponse(statusCode: 404, body: ''),
      const AntigravityHttpResponse(statusCode: 404, body: ''),
      AntigravityHttpResponse(statusCode: 200, body: jsonEncode({
        'response': {
          'groups': [
            {'groupId': 'gemini', 'buckets': [
              {'bucketId': 'weekly', 'remainingFraction': 0.4},
            ]},
          ],
        },
      })),
    ]);
    final reader = AntigravityLocalReader(httpRunner: http);

    final snapshot = await reader.fetchSnapshot(connection(providerData: jsonEncode({
      'source': 'language-server', 'port': 1234, 'csrfToken': 'memory-only',
    })));

    expect(snapshot.status, ConnectionStatus.ok);
    expect(http.paths, ['/RetrieveUserQuotaSummary', '/GetUserStatus', '/GetCommandModelConfigs']);
  });
  test('quota summary without identity continues through status and configs', () async {
    final http = _FakeHttpRunner([
      AntigravityHttpResponse(statusCode: 200, body: jsonEncode({
        'response': {
          'groups': [
            {'groupId': 'gemini', 'buckets': [
              {'bucketId': 'weekly', 'remainingFraction': 0.4},
            ]},
          ],
        },
      })),
      AntigravityHttpResponse(statusCode: 200, body: jsonEncode({
        'response': {'accountEmail': 'selected@example.com'},
      })),
      AntigravityHttpResponse(statusCode: 200, body: jsonEncode({
        'response': {
          'groups': [
            {'groupId': 'gemini', 'buckets': [
              {'bucketId': 'weekly', 'remainingFraction': 0.3},
            ]},
          ],
        },
      })),
    ]);
    final reader = AntigravityLocalReader(httpRunner: http);

    final snapshot = await reader.fetchSnapshot(connection(
      identityKey: 'selected@example.com',
      providerData: jsonEncode({'source': 'language-server', 'port': 1234}),
    ));

    expect(snapshot.status, ConnectionStatus.ok);
    expect(snapshot.quotas.single.remaining, 0.3);
    expect(http.paths, ['/RetrieveUserQuotaSummary', '/GetUserStatus', '/GetCommandModelConfigs']);
  });

  test('agy availability-only cannot bypass selected identity', () {
    final snapshot = AntigravityLocalReader.parseAgyPrint(
      jsonEncode({'availability': {'gemini': 1.0}}),
      connectionId: 'agy-1',
      expectedAccountKey: 'selected@example.com',
    );

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.error, 'Account mismatch');
  });

  test('agy identity mismatch is rejected', () async {
    final reader = AntigravityLocalReader(processRunner: _FakeProcessRunner([
      _ProcessResult(0, 0, 'agy 1.1.11\n', ''),
      _ProcessResult(0, 0, jsonEncode({
        'accountEmail': 'other@example.com',
        'quotaInfo': {'gemini': {'remainingFraction': 0.5}},
      }), ''),
    ]));

    final snapshot = await reader.fetchSnapshot(connection(
      identityKey: 'selected@example.com',
      providerData: jsonEncode({'source': 'agy-cli'}),
    ));

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.error, 'Account mismatch');
  });

  test('agy fetch accepts persisted composite account identity', () async {
    final reader = AntigravityLocalReader(
      processRunner: _FakeProcessRunner([
        _ProcessResult(0, 0, 'agy 1.1.11\n', ''),
        _ProcessResult(0, 0, jsonEncode({
          'accountEmail': 'selected@example.com',
          'accountId': 'acct-a',
          'quotaInfo': {
            'gemini': {'remainingFraction': 0.5},
          },
        }), ''),
      ]),
    );

    final snapshot = await reader.fetchSnapshot(connection(
      identityKey: 'selected@example.com|acct-a',
      providerData: jsonEncode({'source': 'agy-cli'}),
    ));

    expect(snapshot.status, ConnectionStatus.ok);
  });

  test('legacy Gemini model entries merge into one worst-fraction pool row', () {
    final snapshot = AntigravityLocalReader.parseAgyPrint(
      jsonEncode({'quotaInfo': {
        'gemini-pro': {'remainingFraction': 0.8},
        'gemini-flash': {'remainingFraction': 0.3},
        'claude': {'remainingFraction': 0.6},
        'gpt': {'remainingFraction': 0.2},
      }}),
      connectionId: 'agy-1',
    );

    expect(snapshot.quotas.map((q) => q.id), ['gemini-5h', 'claude-gpt-5h']);
    expect(snapshot.quotas.first.remaining, 0.3);
    expect(snapshot.quotas.last.remaining, 0.2);
  });

  test('non-100 availability payload is not reported as limits unavailable', () {
    final snapshot = AntigravityLocalReader.parseQuotaSummary(
      body: jsonEncode({'response': {'availability': {'gemini': 0.5}}}),
      connectionId: 'agy-1',
    );

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.quotas, isEmpty);
  });

  test('agy source requires version 1.1.11 or newer', () async {
    final runner = _FakeProcessRunner([
      _ProcessResult(1, 0, 'agy 1.1.10\n', ''),
    ]);
    final reader = AntigravityLocalReader(processRunner: runner);

    final snapshot = await reader.fetchSnapshot(connection(
      providerData: jsonEncode({'source': 'agy-cli', 'agyBin': 'agy'}),
    ));

    expect(snapshot.status, ConnectionStatus.error);
    expect(snapshot.error, 'agy version is too old');
    expect(runner.calls, hasLength(1));
  });

  test('agy print mode is parsed through injectable process runner', () async {
    final runner = _FakeProcessRunner([
      _ProcessResult(0, 0, 'agy 1.1.11\n', ''),
      _ProcessResult(0, 0, fixture('antigravity_agy_print.json'), ''),
    ]);
    final reader = AntigravityLocalReader(processRunner: runner);

    final snapshot = await reader.fetchSnapshot(connection(
      providerData: jsonEncode({'source': 'agy-cli', 'agyBin': 'agy'}),
    ));

    expect(snapshot.status, ConnectionStatus.ok);
    expect(snapshot.quotas.map((q) => q.id), contains('claude-gpt-5h'));
    expect(runner.calls[1].arguments, ['-p', '/usage', '--output-format', 'json']);
  });

  test('local parser rejects invalid remaining fractions without clamping', () {
    for (final fraction in <dynamic>[double.nan, double.infinity, -0.1, 1.1, '2']) {
      final snapshot = AntigravityLocalReader.parseQuotaSummary(
        body: jsonEncode({
          'response': {
            'groups': [
              {
                'groupId': 'gemini',
                'buckets': [
                  {'bucketId': 'weekly', 'remainingFraction': '$fraction'},
                ],
              },
            ],
          },
        }),
        connectionId: 'agy-1',
      );
      expect(snapshot.status, ConnectionStatus.error, reason: '$fraction');
      expect(snapshot.quotas, isEmpty, reason: '$fraction');
    }
  });
}

class _FakeHttpRunner implements AntigravityHttpRunner {
  _FakeHttpRunner(this.results);
  final List<AntigravityHttpResponse> results;
  final List<String> paths = [];

  @override
  Future<AntigravityHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    paths.add(uri.path);
    return results.removeAt(0);
  }
}

class _ProcessResult {
  _ProcessResult(this.exitCode, this.pid, this.stdout, this.stderr);
  final int exitCode;
  final int pid;
  final String stdout;
  final String stderr;
}

class _ProcessCall {
  _ProcessCall(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

class _FakeProcessRunner implements AntigravityProcessRunner {
  _FakeProcessRunner(this.results);
  final List<_ProcessResult> results;
  final List<_ProcessCall> calls = [];

  @override
  Future<AntigravityProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
    int? maxOutputBytes,
  }) async {
    calls.add(_ProcessCall(executable, arguments));
    final result = results.removeAt(0);
    return AntigravityProcessResult(
      exitCode: result.exitCode,
      stdout: result.stdout,
      stderr: result.stderr,
    );
  }
}
