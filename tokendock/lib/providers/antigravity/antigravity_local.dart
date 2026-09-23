import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/quota.dart';

/// Result returned by the local `agy` process runner. Deliberately contains
/// no credential material: stdout is only used for the requested usage JSON.
class AntigravityProcessResult {
  const AntigravityProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });

  final int exitCode;
  final String stdout;
  final String stderr;
}

abstract interface class AntigravityProcessRunner {
  Future<AntigravityProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
    int? maxOutputBytes,
  });
}

class AntigravityHttpResponse {
  const AntigravityHttpResponse({required this.statusCode, required this.body});

  final int statusCode;
  final String body;
}

abstract interface class AntigravityHttpRunner {
  Future<AntigravityHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  });
}

class _SystemProcessRunner implements AntigravityProcessRunner {
  @override
  Future<AntigravityProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Duration? timeout,
    int? maxOutputBytes,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    final limit = maxOutputBytes ?? 1024 * 1024;
    final stdout = <int>[];
    final stderr = <int>[];
    var outputTooLarge = false;
    final stdoutDone = process.stdout.listen((bytes) {
      if (stdout.length + bytes.length > limit) {
        outputTooLarge = true;
        process.kill(ProcessSignal.sigkill);
      } else {
        stdout.addAll(bytes);
      }
    }).asFuture<void>();
    final stderrDone = process.stderr.listen((bytes) {
      if (stderr.length + bytes.length > limit) {
        outputTooLarge = true;
        process.kill(ProcessSignal.sigkill);
      } else {
        stderr.addAll(bytes);
      }
    }).asFuture<void>();
    final exitCode = await process.exitCode.timeout(
      timeout ?? const Duration(seconds: 90),
      onTimeout: () {
        process.kill(ProcessSignal.sigkill);
        throw const AntigravitySourceException('agy process timed out');
      },
    );
    await Future.wait([stdoutDone, stderrDone]);
    if (outputTooLarge) {
      throw const AntigravitySourceException('agy output exceeded 1 MiB');
    }
    return AntigravityProcessResult(
      exitCode: exitCode,
      stdout: utf8.decode(stdout),
      stderr: utf8.decode(stderr),
    );
  }
}

class _LoopbackHttpRunner implements AntigravityHttpRunner {
  @override
  Future<AntigravityHttpResponse> post(
    Uri uri, {
    required Map<String, String> headers,
    required String body,
  }) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    client.badCertificateCallback = (certificate, host, port) =>
        host == '127.0.0.1' || host == 'localhost';
    try {
      final request = await client.postUrl(uri).timeout(const Duration(seconds: 10));
      request.headers.set('X-Codeium-Csrf-Token', headers['X-Codeium-Csrf-Token'] ?? '');
      request.headers.set('Connect-Protocol-Version', headers['Connect-Protocol-Version'] ?? '1');
      request.write(body);
      final response = await request.close().timeout(const Duration(seconds: 15));
      final text = await response.transform(utf8.decoder).join();
      return AntigravityHttpResponse(statusCode: response.statusCode, body: text);
    } finally {
      client.close(force: true);
    }
  }
}

class AntigravitySourceException implements Exception {
  const AntigravitySourceException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Read-only adapter for the local Antigravity language server and `agy` CLI.
class AntigravityLocalReader {
  AntigravityLocalReader({
    AntigravityProcessRunner? processRunner,
    AntigravityHttpRunner? httpRunner,
  })  : _processRunner = processRunner ?? _SystemProcessRunner(),
        _httpRunner = httpRunner ?? _LoopbackHttpRunner();

  final AntigravityProcessRunner _processRunner;
  final AntigravityHttpRunner _httpRunner;

  static ProviderSnapshot parseQuotaSummary({
    required String body,
    required String connectionId,
    String? expectedAccountKey,
    bool requireIdentity = false,
    DateTime? fetchedAt,
  }) {
    final now = (fetchedAt ?? DateTime.now()).toUtc();
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('not an object');
      final root = _map(decoded['response']) ?? _map(decoded)!;
      if (requireIdentity) {
        _requireAccountIdentity(root, expectedAccountKey);
      } else {
        _rejectMismatchedAccount(root, expectedAccountKey);
      }
      final groups = root['groups'];
      if (groups is List) {
        final quotas = _quotasFromGroups(groups);
        if (quotas.isNotEmpty) {
          return ProviderSnapshot(
            connectionId: connectionId,
            status: ConnectionStatus.ok,
            quotas: quotas,
            balance: null,
            fetchedAt: now,
            error: null,
          );
        }
      }
      final legacy = _quotasFromLegacy(_map(root['quotaInfo']) ?? root);
      if (legacy.isNotEmpty) return _ok(connectionId, now, legacy);
      if (_looksAvailabilityOnly(root)) {
        return ProviderSnapshot(
          connectionId: connectionId,
          status: ConnectionStatus.warning,
          quotas: const [Quota(
            id: 'limits-not-available',
            label: 'Limits not available',
            percent: null,
            remaining: null,
            limit: null,
            unit: null,
            resetAt: null,
          )],
          balance: null,
          fetchedAt: now,
          error: null,
        );
      }
      return _error(connectionId, now, 'Limits not available');
    } on AntigravitySourceException catch (error) {
      final schemaChanged = error.message == 'quota_source_changed';
      return ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.error,
        quotas: const [],
        balance: null,
        fetchedAt: now,
        error: error.message,
        failureCause: schemaChanged ? ProviderFailureCause.quotaSourceChanged : ProviderFailureCause.accountMismatch,
      );
    } catch (_) {
      return _error(connectionId, now, 'Limits not available');
    }
  }

  static ProviderSnapshot parseAgyPrint(
    String body, {
    required String connectionId,
    String? expectedAccountKey,
    DateTime? fetchedAt,
  }) {
    final now = (fetchedAt ?? DateTime.now()).toUtc();
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) throw const FormatException('not an object');
      final root = _map(decoded['response']) ?? _map(decoded)!;
      final info = _map(root['quotaInfo']) ?? root;
      final quotas = _quotasFromLegacy(info);
      _requireAccountIdentity(root, expectedAccountKey);
      if (quotas.isEmpty && _looksAvailabilityOnly(root)) {
        return parseQuotaSummary(
          body: body,
          connectionId: connectionId,
          expectedAccountKey: expectedAccountKey,
          requireIdentity: true,
          fetchedAt: now,
        );
      }
      return quotas.isEmpty ? _error(connectionId, now, 'Limits not available') : _ok(connectionId, now, quotas);
    } on AntigravitySourceException catch (error) {
      final schemaChanged = error.message == 'quota_source_changed';
      return ProviderSnapshot(
        connectionId: connectionId,
        status: ConnectionStatus.error,
        quotas: const [],
        balance: null,
        fetchedAt: now,
        error: error.message,
        failureCause: schemaChanged ? ProviderFailureCause.quotaSourceChanged : ProviderFailureCause.accountMismatch,
      );
    } catch (_) {
      return _error(connectionId, now, 'Limits not available');
    }
  }

  Future<ProviderSnapshot> fetchSnapshot(Connection connection) async {
    final providerData = _decodeProviderData(connection.providerData);
    final source = providerData['source'] as String?;
    if (source != 'language-server' && source != 'agy-cli') {
      return _error(connection.id, DateTime.now().toUtc(), 'Antigravity source is not enabled');
    }
    if (source == 'agy-cli') return _fetchAgy(connection, providerData);
    final port = providerData['port'] as int?;
    var accountMatched = false;
    if (port != null) {
      final headers = {
        'X-Codeium-Csrf-Token': providerData['csrfToken'] as String? ?? '',
        'Connect-Protocol-Version': '1',
      };
      for (final endpoint in const [
        'RetrieveUserQuotaSummary',
        'GetUserStatus',
        'GetCommandModelConfigs',
      ]) {
        try {
          final response = await _httpRunner.post(
            Uri.parse('https://127.0.0.1:$port/$endpoint'),
            headers: headers,
            body: '{}',
          );
          if (response.statusCode >= 200 && response.statusCode < 300) {
            if (_accountMatches(response.body, connection.identityKey)) accountMatched = true;
            final snapshot = parseQuotaSummary(
              body: response.body,
              connectionId: connection.id,
              expectedAccountKey: accountMatched ? connection.identityKey : null,
            );
            if (snapshot.quotas.isNotEmpty &&
                (connection.identityKey == null ||
                    connection.identityKey!.isEmpty ||
                    accountMatched)) {
              return snapshot;
            }
          }
        } catch (_) {
          // Try the next local language-server method, then agy.
        }
      }
    }
    return _fetchAgy(connection, providerData);
  }
  Future<ProviderSnapshot> _fetchAgy(Connection connection, Map<String, dynamic> data) async {
    final executable = data['agyBin'] as String? ?? 'agy';
    final privateCwd = Directory.systemTemp.createTempSync('tokendock_agy_');
    try {
      final version = await _processRunner.run(
        executable,
        ['--version'],
        workingDirectory: privateCwd.path,
        timeout: const Duration(seconds: 10),
        maxOutputBytes: 64 * 1024,
      );
      if (version.exitCode != 0 || !_supportsPrintMode(version.stdout)) {
        return _error(connection.id, DateTime.now().toUtc(), 'agy version is too old');
      }
      final usage = await _processRunner.run(
        executable,
        ['-p', '/usage', '--output-format', 'json'],
        workingDirectory: privateCwd.path,
        timeout: const Duration(seconds: 90),
        maxOutputBytes: 1024 * 1024,
      );
      if (usage.exitCode != 0) return _error(connection.id, DateTime.now().toUtc(), 'agy usage unavailable');
      return parseAgyPrint(
        usage.stdout,
        connectionId: connection.id,
        expectedAccountKey: connection.identityKey,
      );
    } on AntigravitySourceException catch (error) {
      return _error(connection.id, DateTime.now().toUtc(), error.message);
    } catch (_) {
      return _error(connection.id, DateTime.now().toUtc(), 'agy usage unavailable');
    } finally {
      privateCwd.deleteSync(recursive: true);
    }
  }

  static bool _supportsPrintMode(String output) {
    final match = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(output);
    if (match == null) return false;
    final major = int.parse(match.group(1)!);
    final minor = int.parse(match.group(2)!);
    final patch = int.parse(match.group(3)!);
    return major > 1 || (major == 1 && (minor > 1 || (minor == 1 && patch >= 11)));
  }

  static Map<String, dynamic> _decodeProviderData(String? value) {
    if (value == null || value.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static List<Quota> _quotasFromGroups(List<dynamic> groups) {
    final values = <String, _Bucket>{};
    for (final rawGroup in groups) {
      final group = _map(rawGroup);
      if (group == null) continue;
      final groupId = (group['groupId'] ?? group['id'] ?? '').toString().toLowerCase();
      final pool = _pool(groupId);
      if (pool == null) continue;
      final buckets = group['buckets'];
      if (buckets is! List) continue;
      for (final rawBucket in buckets) {
        final bucket = _map(rawBucket);
        if (bucket == null) continue;
        final window = _window((bucket['bucketId'] ?? bucket['id'] ?? '').toString());
        final rawFraction = bucket.containsKey('remainingFraction')
            ? bucket['remainingFraction']
            : _map(bucket['remaining'])?['remainingFraction'];
        if (rawFraction != null && !_validFraction(rawFraction)) {
          throw const AntigravitySourceException('quota_source_changed');
        }
        final fraction = _number(rawFraction);
        final reset = _date(bucket['resetTime'] ?? bucket['resetAt']);
        final candidate = _Bucket(fraction, reset, bucket['description']?.toString());
        final key = '$pool-$window';
        final current = values[key];
        if (current == null || (candidate.fraction != null &&
            (current.fraction == null || candidate.fraction! < current.fraction!))) {
          values[key] = candidate;
        }
      }
    }
    return values.entries.map((entry) => _quota(entry.key, entry.value)).toList();
  }

  static List<Quota> _quotasFromLegacy(Map<String, dynamic> info) {
    final merged = <String, _Bucket>{};
    info.forEach((key, raw) {
      final pool = _pool(key);
      final value = _map(raw);
      if (pool == null || value == null) return;
      final rawFraction = value['remainingFraction'];
      if (rawFraction != null && !_validFraction(rawFraction)) {
        throw const AntigravitySourceException('quota_source_changed');
      }
      final fraction = _number(rawFraction);
      final reset = _date(value['resetTime'] ?? value['resetAt']);
      if (fraction == null && reset == null) return;
      final id = '$pool-5h';
      final current = merged[id];
      if (current == null || (fraction != null && (current.fraction == null || fraction < current.fraction!))) {
        merged[id] = _Bucket(fraction, reset, null);
      }
    });
    return merged.entries.map((entry) => _quota(entry.key, entry.value)).toList();
  }

  static Quota _quota(String id, _Bucket value) {
    final remaining = value.fraction;
    return Quota(
      id: id,
      label: id.replaceAll('-', ' '),
      percent: remaining == null ? null : (1 - remaining) * 100,
      remaining: remaining,
      limit: null,
      unit: null,
      resetAt: value.reset,
    );
  }

  static String? _pool(String id) {
    if (id.contains('gemini') || id.contains('pro') || id.contains('flash')) return 'gemini';
    if (id.contains('claude') || id.contains('gpt')) return 'claude-gpt';
    return null;
  }

  static String _window(String id) {
    final lower = id.toLowerCase();
    return lower.contains('week') || lower.contains('7d') ? 'weekly' : '5h';
  }

  static bool _validFraction(dynamic value) {
    final parsed = value is num ? value.toDouble() : double.tryParse('$value');
    return parsed != null && parsed.isFinite && parsed >= 0 && parsed <= 1;
  }

  static double? _number(dynamic value) {
    if (value == null) return null;
    final parsed = value is num ? value.toDouble() : double.tryParse(value.toString());
    return parsed != null && parsed.isFinite && parsed >= 0 && parsed <= 1 ? parsed : null;
  }

  static DateTime? _date(dynamic value) {
    if (value == null) return null;
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch(value.toInt() * 1000, isUtc: true);
    }
    final text = value.toString();
    return DateTime.tryParse(text)?.toUtc() ??
        (int.tryParse(text) == null ? null : DateTime.fromMillisecondsSinceEpoch(int.parse(text) * 1000, isUtc: true));
  }

  static bool _looksAvailabilityOnly(Map<String, dynamic> root) {
    if (root.containsKey('groups') || root.containsKey('quotaInfo')) return false;
    final availability = root['availability'];
    if (availability is! Map || availability.isEmpty) return false;
    return availability.values.every((value) => _number(value) == 1.0);
  }

  static bool _accountMatches(String body, String? expected) {
    if (expected == null || expected.isEmpty) return true;
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map) return false;
      final root = _map(decoded['response']) ?? _map(decoded)!;
      return _identityMatches(root, expected);
    } catch (_) {
      return false;
    }
  }

  static void _rejectMismatchedAccount(Map<String, dynamic> root, String? expected) {
    if (expected == null || expected.isEmpty) return;
    if (!_identityMatches(root, expected) && _responseIdentity(root) != null) {
      throw const AntigravitySourceException('Account mismatch');
    }
  }

  static void _requireAccountIdentity(Map<String, dynamic> root, String? expected) {
    if (expected == null || expected.isEmpty) return;
    if (!_identityMatches(root, expected)) {
      throw const AntigravitySourceException('Account mismatch');
    }
  }

  static bool _identityMatches(Map<String, dynamic> root, String expected) {
    if (expected.contains('|')) {
      return _responseIdentity(root)?.toLowerCase() == expected.toLowerCase();
    }
    final email = (root['accountEmail'] ?? root['email'])?.toString().trim();
    final account =
        (root['accountId'] ?? root['account_id'] ?? root['account'])?.toString().trim();
    final normalized = expected.toLowerCase();
    return email?.toLowerCase() == normalized || account?.toLowerCase() == normalized;
  }

  static String? _responseIdentity(Map<String, dynamic> root) {
    final email = (root['accountEmail'] ?? root['email'])?.toString().trim();
    final account =
        (root['accountId'] ?? root['account_id'] ?? root['account'])?.toString().trim();
    if (email != null && email.isNotEmpty && account != null && account.isNotEmpty) {
      return '$email|$account';
    }
    if (email != null && email.isNotEmpty) return email;
    return account != null && account.isNotEmpty ? account : null;
  }

  static ProviderSnapshot _ok(String id, DateTime at, List<Quota> quotas) => ProviderSnapshot(
        connectionId: id, status: ConnectionStatus.ok, quotas: quotas, balance: null, fetchedAt: at, error: null,
      );
  static ProviderSnapshot _error(String id, DateTime at, String error) => ProviderSnapshot(
        connectionId: id, status: ConnectionStatus.error, quotas: const [], balance: null, fetchedAt: at, error: error,
      );
  static Map<String, dynamic>? _map(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : null;
}

class _Bucket {
  const _Bucket(this.fraction, this.reset, this.description);
  final double? fraction;
  final DateTime? reset;
  final String? description;
}
