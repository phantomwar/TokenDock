import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/antigravity/antigravity_local.dart';

/// Session discovery must never stall a refresh.
///
/// Audit C-18: `_WindowsAntigravitySessionDiscovery` ran
/// `Get-CimInstance Win32_Process`, which enumerates every process on the
/// machine, through `Process.run` with no timeout and no output cap, inline on
/// the quota fetch path. The unbounded read mirrors the OAuth transport that
/// was already fixed (audit C-01).
void main() {
  const connection = Connection(
    id: 'c1',
    provider: 'antigravity',
    displayName: 'Antigravity',
    group: null,
    plan: null,
    credentialRef: '',
    enabled: true,
    authType: 'none',
    providerData: '{"source":"language-server"}',
  );

  group('local reader tolerates a hostile discovery', () {
    test('a discovery that never completes does not hang the fetch', () async {
      final reader = AntigravityLocalReader(
        sessionDiscovery: _NeverEndingDiscovery(),
        processRunner: _NoProcessRunner(),
        // A short budget keeps the test off wall-clock time; the default is
        // seconds, which is its own flake source under a loaded suite.
        discoveryBudget: const Duration(milliseconds: 50),
      );

      final snapshot = await reader
          .fetchSnapshot(connection)
          .timeout(const Duration(seconds: 5));

      expect(
        snapshot.status,
        isNot(ConnectionStatus.ok),
        reason: 'an unresponsive discovery must surface, not wedge the widget',
      );
    });

    test('a discovery that throws does not throw out of the reader', () async {
      final reader = AntigravityLocalReader(
        sessionDiscovery: _ThrowingDiscovery(),
        processRunner: _NoProcessRunner(),
        discoveryBudget: const Duration(milliseconds: 50),
      );

      final snapshot = await reader
          .fetchSnapshot(connection)
          .timeout(const Duration(seconds: 5));

      expect(snapshot.status, isNot(ConnectionStatus.ok));
      expect(snapshot.error, isNotNull);
    });
  });

  group('discovery output is parsed defensively', () {
    test('a non-JSON body yields no sessions instead of throwing', () async {
      final discovery = parseAntigravityDiscoveryOutput('not json at all');
      expect(discovery, isEmpty);
    });

    test('empty and null bodies yield no sessions', () {
      expect(parseAntigravityDiscoveryOutput(''), isEmpty);
      expect(parseAntigravityDiscoveryOutput('   '), isEmpty);
      expect(parseAntigravityDiscoveryOutput('null'), isEmpty);
    });

    test('a well-formed body is parsed into sessions', () {
      final sessions = parseAntigravityDiscoveryOutput(
        jsonEncode([
          {'port': 1234, 'processId': 99, 'csrfToken': 'tok'},
        ]),
      );
      expect(sessions, hasLength(1));
      expect(sessions.single.port, 1234);
      expect(sessions.single.csrfToken, 'tok');
    });

    test('entries missing a port or token are dropped, not half-built', () {
      final sessions = parseAntigravityDiscoveryOutput(
        jsonEncode([
          {'port': 1234, 'processId': 99, 'csrfToken': 'tok'},
          {'port': 5555, 'processId': 100},
          {'processId': 101, 'csrfToken': 'tok'},
        ]),
      );
      expect(sessions, hasLength(1));
      expect(sessions.single.port, 1234);
    });

    test('output is bounded, so an oversized body cannot exhaust memory', () {
      final huge = '[${'0,' * 200000}]';
      expect(
        parseAntigravityDiscoveryOutput(huge, maxBytes: 4096),
        isEmpty,
        reason: 'a body beyond the cap must be rejected, not buffered',
      );
    });
  });
}

/// Refuses every process, so the reader cannot fall through to the real `agy`
/// CLI. A unit test must never spawn a process.
class _NoProcessRunner implements AntigravityProcessRunner {
  @override
  Future<AntigravityProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
    int? maxOutputBytes,
  }) async => throw const AntigravitySourceException('no agy in a unit test');
}

class _NeverEndingDiscovery implements AntigravitySessionDiscovery {
  @override
  Future<List<AntigravityLocalSession>> discover() =>
      Completer<List<AntigravityLocalSession>>().future;
}

class _ThrowingDiscovery implements AntigravitySessionDiscovery {
  @override
  Future<List<AntigravityLocalSession>> discover() async =>
      throw StateError('Get-CimInstance failed');
}
