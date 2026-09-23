import 'dart:convert';
import 'dart:io';

import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../../services/refreshable_credential.dart';
import '../../storage/secret_store.dart';
import '../provider_adapter.dart';
import 'antigravity_local.dart';

class AntigravityOAuthHttpResponse {
  const AntigravityOAuthHttpResponse({required this.statusCode, required this.body});
  final int statusCode;
  final String body;
}

abstract interface class AntigravityOAuthHttpRunner {
  Future<AntigravityOAuthHttpResponse> post(Uri uri, {required Map<String, String> headers, required String body});
}

class AntigravityOnboardingRequired implements Exception {
  const AntigravityOnboardingRequired();
  @override
  String toString() => 'Complete Antigravity onboarding before connecting';
}

class AntigravitySchemaChanged implements Exception {
  const AntigravitySchemaChanged();
  @override
  String toString() => 'quota_source_changed';
}

class AntigravityOAuthLoginResult {
  const AntigravityOAuthLoginResult({required this.secret, required this.identityKey, required this.projectId, required this.tier});
  final String secret;
  final String identityKey;
  final String? projectId;
  final String? tier;
}

class AntigravitySelectedAccountGuard {
  const AntigravitySelectedAccountGuard();
  bool accepts({required String? expected, required Map<String, dynamic> payload}) {
    if (expected == null || expected.isEmpty) return true;
    return identityOf(payload) == expected;
  }
  static String? identityOf(Map<String, dynamic> payload) {
    final root = payload['response'] is Map ? Map<String, dynamic>.from(payload['response'] as Map) : payload;
    final email = (root['accountEmail'] ?? root['email'])?.toString();
    final account = (root['accountId'] ?? root['account_id'] ?? root['account'])?.toString();
    if (email == null || email.isEmpty || account == null || account.isEmpty) return null;
    return '$email|$account';
  }
}

class AntigravityOAuthProvider implements ProviderAdapter {
  AntigravityOAuthProvider({AntigravityOAuthHttpRunner? http, SecretStore? secretStore})
      : _http = http ?? _HttpClientRunner(), _secretStore = secretStore;
  final AntigravityOAuthHttpRunner _http;
  final SecretStore? _secretStore;
  static const tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const prodHost = 'https://cloudcode-pa.googleapis.com';
  static const dailyHost = 'https://daily-cloudcode-pa.googleapis.com';
  static const clientId = '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com';

  @override String get id => 'antigravity';
  @override String get name => 'Antigravity';
  @override AuthKind get authKind => AuthKind.oauth;
  @override Map<String, String> buildAuthHeader(String secret) => {'Authorization': 'Bearer ${_credential(secret)['accessToken'] ?? secret}'};

  Future<AntigravityOAuthLoginResult> login(Connection connection, {required String code, required String codeVerifier, required String redirectUri}) async {
    final token = await _postJson(Uri.parse(tokenEndpoint), {
      'client_id': clientId,
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      'grant_type': 'authorization_code',
    });
    final access = (token['access_token'] ?? '').toString();
    if (access.isEmpty) throw StateError('OAuth token exchange failed');
    final identity = AntigravitySelectedAccountGuard.identityOf(token) ?? connection.identityKey;
    final provisioning = await _loadCodeAssist(access, identity: identity, projectId: _providerData(connection)['projectId']?.toString());
    final project = _project(provisioning);
    if (project == null || project.isEmpty) throw const AntigravityOnboardingRequired();
    final identityKey = identity ?? AntigravitySelectedAccountGuard.identityOf(provisioning);
    if (identityKey == null) throw StateError('OAuth account identity missing');
    final secret = jsonEncode({
      'accessToken': access,
      'refreshToken': token['refresh_token'],
      'expiresAt': _expiry(token)?.toIso8601String(),
      'identityKey': identityKey,
      'projectId': project,
      'tier': _tier(provisioning),
    });
    await _secretStore?.write(connection.credentialRef, secret);
    return AntigravityOAuthLoginResult(secret: secret, identityKey: identityKey, projectId: project, tier: _tier(provisioning));
  }

  Future<Map<String, dynamic>> _loadCodeAssist(String access, {String? identity, String? projectId}) async {
    for (final host in const [prodHost, dailyHost]) {
      try {
        final result = await _postJson(Uri.parse('$host/v1internal:loadCodeAssist'), {
          'metadata': {'pluginType': 'ANTIGRAVITY', 'ideType': 'IDE_UNSPECIFIED'},
          if (projectId != null && projectId.isNotEmpty) 'cloudaicompanionProject': projectId,
          if (identity != null) 'userIdentifier': identity,
        }, bearer: access);
        if (result['response'] is Map) return result;
      } catch (_) {}
    }
    throw StateError('loadCodeAssist unavailable');
  }

  @override
  Future<TestResult> test(Connection connection, String secret) async {
    final snapshot = await fetch(connection, secret);
    return snapshot.error == null ? TestResult.success(quotas: snapshot.quotas, plan: connection.plan) : TestResult.failure(error: snapshot.error!);
  }

  Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final credential = _credential(secret);
    final project = _providerData(connection)['projectId']?.toString() ?? credential['projectId']?.toString();
    if (project == null || project.isEmpty) {
      return _error(connection.id, 'Complete Antigravity onboarding before connecting');
    }
    final expected = credential['identityKey']?.toString() ?? connection.identityKey;
    try {
      for (final host in const [prodHost, dailyHost]) {
        try {
          final payload = await _postJson(Uri.parse('$host/v1internal:retrieveUserQuotaSummary'), {
            'project': project,
            'userIdentifier': expected,
          }, bearer: credential['accessToken']?.toString());
          if (!const AntigravitySelectedAccountGuard().accepts(expected: expected, payload: payload)) {
            return _error(connection.id, 'Account mismatch');
          }
          _requireQuotaSchema(payload);
          return AntigravityLocalReader.parseQuotaSummary(body: jsonEncode(payload), connectionId: connection.id);
        } on StateError catch (error) {
          if (!error.message.toString().contains('HTTP 404')) rethrow;
        }
      }
      return await _fetchLegacy(connection, credential, project, expected);
    } on AntigravitySchemaChanged {
      return _error(connection.id, 'quota_source_changed');
    } catch (error) {
      return _error(connection.id, error.toString().replaceFirst('Exception: ', ''));
    }
  }

  Future<ProviderSnapshot> _fetchLegacy(Connection connection, Map<String, dynamic> credential, String project, String? expected) async {
    final models = await _postJson(Uri.parse('$prodHost/v1internal:fetchAvailableModels'), {
      'project': project,
      'userIdentifier': expected,
    }, bearer: credential['accessToken']?.toString());
    final quota = await _postJson(Uri.parse('$prodHost/v1internal:retrieveUserQuota'), {
      'project': project,
      'userIdentifier': expected,
    }, bearer: credential['accessToken']?.toString());
    if (!const AntigravitySelectedAccountGuard().accepts(expected: expected, payload: quota)) {
      return _error(connection.id, 'Account mismatch');
    }
    _requireQuotaSchema(quota, legacy: true);
    return AntigravityLocalReader.parseQuotaSummary(
      body: jsonEncode({'response': {'quotaInfo': quota['quotaInfo'] ?? quota, 'accountEmail': quota['accountEmail'], 'accountId': quota['accountId'], 'models': models}}),
      connectionId: connection.id,
    );
  }

  static void _requireQuotaSchema(Map<String, dynamic> payload, {bool legacy = false}) {
    final root = payload['response'] is Map ? Map<String, dynamic>.from(payload['response'] as Map) : payload;
    final recognized = root.containsKey('groups') || root.containsKey('quotaInfo') || root.containsKey('availability');
    if (!recognized) throw const AntigravitySchemaChanged();
  }

  Future<String> refresh(String currentSecret) async {
    final value = _credential(currentSecret);
    final refreshToken = value['refreshToken']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) throw StateError('refresh token missing');
    final response = await _postJson(Uri.parse(tokenEndpoint), {
      'client_id': clientId,
      'refresh_token': refreshToken,
      'grant_type': 'refresh_token',
    });
    if (response['access_token'] == null) throw StateError('invalid_grant');
    return jsonEncode({
      ...value,
      'accessToken': response['access_token'],
      'refreshToken': response['refresh_token'] ?? refreshToken,
      'expiresAt': _expiry(response)?.toIso8601String(),
    });
  }

  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, dynamic> body, {String? bearer}) async {
    final response = await _http.post(uri, headers: {
      if (bearer != null && bearer.isNotEmpty) 'Authorization': 'Bearer $bearer',
      'Content-Type': 'application/json',
    }, body: jsonEncode(body));
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (response.statusCode == 401) throw StateError('401');
      if (response.statusCode == 400 && response.body.contains('invalid_grant')) throw StateError('invalid_grant');
      throw StateError('HTTP ${response.statusCode}');
    }
    return _map(jsonDecode(response.body));
  }

  static Map<String, dynamic> _map(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static Map<String, dynamic> _providerData(Connection connection) {
    try { return connection.providerData == null ? <String, dynamic>{} : _map(jsonDecode(connection.providerData!)); } catch (_) { return <String, dynamic>{}; }
  }
  static String? _project(Map<String, dynamic> value) {
    final root = _map(value['response']);
    return (root['cloudaicompanionProject'] ?? root['projectId'] ?? root['project'])?.toString();
  }
  static String? _tier(Map<String, dynamic> value) {
    final root = _map(value['response']);
    final tier = _map(root['currentTier']);
    return (tier['id'] ?? tier['name'] ?? root['tier'])?.toString();
  }
  static DateTime? _expiry(Map<String, dynamic> value) {
    final seconds = value['expires_in'];
    return seconds is num ? DateTime.now().toUtc().add(Duration(seconds: seconds.toInt())) : null;
  }
  static Map<String, dynamic> _credential(String raw) {
    try { return _map(jsonDecode(raw)); } catch (_) { return {'accessToken': raw}; }
  }
  ProviderSnapshot _error(String id, String error) => ProviderSnapshot(
        connectionId: id, status: ConnectionStatus.authError, quotas: const [], balance: null,
        fetchedAt: DateTime.now().toUtc(), error: error,
      );
}

class AntigravityRefreshableCredential implements RefreshableCredential {
  AntigravityRefreshableCredential(this.provider, this.secret);
  final AntigravityOAuthProvider provider;
  String secret;
  @override
  DateTime? get expiresAt => DateTime.tryParse(_credential(secret)['expiresAt']?.toString() ?? '');
  @override
  Duration get refreshLead => const Duration(minutes: 1);
  @override
  Future<String> refresh(String currentSecret) async {
    secret = await provider.refresh(currentSecret);
    return secret;
  }
  static Map<String, dynamic> _credential(String raw) {
    try { return Map<String, dynamic>.from(jsonDecode(raw) as Map); } catch (_) { return <String, dynamic>{}; }
  }
}

class _HttpClientRunner implements AntigravityOAuthHttpRunner {
  @override
  Future<AntigravityOAuthHttpResponse> post(Uri uri, {required Map<String, String> headers, required String body}) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(uri);
      headers.forEach(request.headers.set);
      request.write(body);
      final response = await request.close();
      return AntigravityOAuthHttpResponse(statusCode: response.statusCode, body: await response.transform(const Utf8Decoder()).join());
    } finally {
      client.close(force: true);
    }
  }
}
