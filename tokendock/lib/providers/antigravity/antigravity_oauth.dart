import 'dart:convert';
import 'dart:io';

import '../../models/connection.dart';
import '../../models/connection_status.dart';
import '../../models/provider_snapshot.dart';
import '../../models/test_result.dart';
import '../../services/oauth_loopback.dart';
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
  @override String toString() => 'Complete Antigravity onboarding before connecting';
}
class AntigravityTransportFailure implements Exception {
  const AntigravityTransportFailure(this.cause);
  final Object cause;
}
class AntigravityTransientFailure implements Exception {
  const AntigravityTransientFailure(this.statusCode);
  final int statusCode;
  @override String toString() => 'Antigravity transient HTTP $statusCode';
}
class AntigravitySchemaChanged implements Exception {
  const AntigravitySchemaChanged();
  @override String toString() => 'quota_source_changed';
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
  bool accepts({required String? expected, required Map<String, dynamic> payload}) =>
      expected == null || expected.isEmpty || identityOf(payload) == expected;
  static String? identityOf(Map<String, dynamic> payload) {
    final root = payload['response'] is Map ? Map<String, dynamic>.from(payload['response'] as Map) : payload;
    final email = (root['accountEmail'] ?? root['email'])?.toString();
    final account = (root['accountId'] ?? root['account_id'] ?? root['account'])?.toString();
    return email == null || email.isEmpty || account == null || account.isEmpty ? null : '$email|$account';
  }
}

class AntigravityOAuthProvider implements ProviderAdapter {
  AntigravityOAuthProvider({AntigravityOAuthHttpRunner? http, SecretStore? secretStore, Future<void> Function(Uri url)? launchExternalBrowser})
      : _http = http ?? _HttpClientRunner(), _secretStore = secretStore, launchExternalBrowser = launchExternalBrowser ?? launchWindowsBrowser;
  final AntigravityOAuthHttpRunner _http;
  final SecretStore? _secretStore;
  final Future<void> Function(Uri url) launchExternalBrowser;

  static Future<void> launchWindowsBrowser(Uri url) async {
    if (Platform.isWindows) {
      await Process.run('rundll32.exe', ['url.dll,FileProtocolHandler', url.toString()]);
      return;
    }
    throw UnsupportedError('External browser handoff is unsupported on this platform');
  }
  static const tokenEndpoint = 'https://oauth2.googleapis.com/token';
  static const prodHost = 'https://cloudcode-pa.googleapis.com';
  static const dailyHost = 'https://daily-cloudcode-pa.googleapis.com';
  static const authorizationEndpoint = 'https://accounts.google.com/o/oauth2/v2/auth';
  static const clientId = '681255809395-oo8ft2oprdrnp9e3aqf6av3hmdib135j.apps.googleusercontent.com';
  @override String get id => 'antigravity';
  @override String get name => 'Antigravity';
  @override AuthKind get authKind => AuthKind.oauth;
  @override Map<String, String> buildAuthHeader(String secret) => {'Authorization': 'Bearer ${_credential(secret)['accessToken'] ?? secret}'};
  @override RefreshableCredential? refreshableCredential(String secret) => AntigravityRefreshableCredential(this, secret);

  Future<AntigravityOAuthLoginResult> loginWithLoopback(Connection connection) async {
    final session = await OAuthLoopback.start();
    final verifier = newCodeVerifier();
    final state = newState();
    final url = session.launchUrl(Uri.parse(authorizationEndpoint), parameters: {
      'client_id': clientId, 'response_type': 'code',
      'scope': 'cloud-platform userinfo.email userinfo.profile',
      'code_challenge': buildCodeChallenge(verifier), 'code_challenge_method': 'S256', 'state': state,
    });
    try {
      final delivered = session.waitForCode(state);
      await launchExternalBrowser(url);
      final result = await delivered;
      return login(connection, code: result.code, codeVerifier: verifier, redirectUri: session.redirectUri.toString());
    } finally { await session.close(); }
  }

  Future<AntigravityOAuthLoginResult> login(Connection connection, {required String code, required String codeVerifier, required String redirectUri}) async {
    final token = await _postJson(Uri.parse(tokenEndpoint), {
      'client_id': clientId, 'code': code, 'code_verifier': codeVerifier, 'redirect_uri': redirectUri, 'grant_type': 'authorization_code',
    });
    final access = (token['access_token'] ?? '').toString().trim();
    if (access.isEmpty) throw StateError('OAuth access token missing');
    final identity = AntigravitySelectedAccountGuard.identityOf(token) ?? connection.identityKey;
    var provisioning = await _loadCodeAssist(access, identity: identity, projectId: _providerData(connection)['projectId']?.toString());
    _requireProvisioningIdentity(provisioning, identity);
    var project = _project(provisioning);
    if (_tier(provisioning) == null) {
      provisioning = await _onboardUser(access, identity: identity, projectId: project);
      _requireProvisioningIdentity(provisioning, identity);
      project = _project(provisioning);
    }
    if (project == null || project.isEmpty) throw const AntigravityOnboardingRequired();
    final identityKey = identity ?? AntigravitySelectedAccountGuard.identityOf(provisioning);
    if (identityKey == null) throw StateError('OAuth account identity missing');
    final secret = jsonEncode({
      'accessToken': access, 'refreshToken': token['refresh_token'], 'expiresAt': _expiry(token)?.toIso8601String(),
      'identityKey': identityKey, 'projectId': project, 'tier': _tier(provisioning),
    });
    await _secretStore?.write(connection.credentialRef, secret);
    return AntigravityOAuthLoginResult(secret: secret, identityKey: identityKey, projectId: project, tier: _tier(provisioning));
  }

  Future<Map<String, dynamic>> _loadCodeAssist(String access, {String? identity, String? projectId}) async {
    AntigravityTransportFailure? transportFailure;
    for (final host in const [prodHost, dailyHost]) {
      try {
        final result = await _postJson(Uri.parse('$host/v1internal:loadCodeAssist'), {
          'metadata': {'pluginType': 'ANTIGRAVITY', 'ideType': 'IDE_UNSPECIFIED'},
          if (projectId != null && projectId.isNotEmpty) 'cloudaicompanionProject': projectId,
          if (identity != null) 'userIdentifier': identity,
        }, bearer: access);
        if (result['response'] is Map) return result;
        throw const AntigravitySchemaChanged();
      } on AntigravityTransportFailure catch (error) { transportFailure = error; }
    }
    if (transportFailure != null) throw transportFailure;
    throw StateError('loadCodeAssist unavailable');
  }
  Future<Map<String, dynamic>> _onboardUser(String access, {String? identity, String? projectId}) async {
    final result = await _postJson(Uri.parse('$prodHost/v1internal:onboardUser'), {
      'metadata': {'pluginType': 'ANTIGRAVITY', 'ideType': 'IDE_UNSPECIFIED'},
      if (projectId != null && projectId.isNotEmpty) 'cloudaicompanionProject': projectId,
      if (identity != null) 'userIdentifier': identity,
    }, bearer: access);
    if (result['response'] is! Map) throw const AntigravitySchemaChanged();
    return result;
  }
  static void _requireProvisioningIdentity(Map<String, dynamic> payload, String? expected) {
    if (expected == null || expected.isEmpty) return;
    if (AntigravitySelectedAccountGuard.identityOf(payload) != expected) throw StateError('Account mismatch');
  }

  static void _requireQuotaSchema(Map<String, dynamic> payload, {bool legacy = false}) {
    final root = payload['response'] is Map ? Map<String, dynamic>.from(payload['response'] as Map) : payload;
    if (root.containsKey('groups')) {
      final groups = root['groups'];
      if (groups is! List || groups.isEmpty) throw const AntigravitySchemaChanged();
      for (final raw in groups) {
        if (raw is! Map) throw const AntigravitySchemaChanged();
        final group = Map<String, dynamic>.from(raw);
        final groupId = (group['groupId'] ?? group['id'])?.toString() ?? '';
        final buckets = group['buckets'];
        if (groupId.isEmpty || buckets is! List || buckets.isEmpty) throw const AntigravitySchemaChanged();
        for (final rawBucket in buckets) {
          if (rawBucket is! Map) throw const AntigravitySchemaChanged();
          final bucket = Map<String, dynamic>.from(rawBucket);
          final bucketId = (bucket['bucketId'] ?? bucket['id'])?.toString() ?? '';
          final remaining = bucket['remaining'] is Map ? Map<String, dynamic>.from(bucket['remaining'] as Map) : bucket;
          final fraction = remaining['remainingFraction'];
          final reset = bucket['resetTime'] ?? bucket['resetAt'];
          if (bucketId.isEmpty || (fraction is! num && double.tryParse('$fraction') == null) || (reset != null && reset.toString().isEmpty)) throw const AntigravitySchemaChanged();
        }
      }
      return;
    }
    if (root.containsKey('quotaInfo')) {
      final quota = root['quotaInfo'];
      if (quota is! Map || quota.isEmpty) throw const AntigravitySchemaChanged();
      for (final raw in quota.values) {
        if (raw is! Map) throw const AntigravitySchemaChanged();
        final value = Map<String, dynamic>.from(raw);
        final fraction = value['remainingFraction'];
        final reset = value['resetTime'] ?? value['resetAt'];
        if (fraction is! num && double.tryParse('$fraction') == null) throw const AntigravitySchemaChanged();
        if (reset != null && reset.toString().isEmpty) throw const AntigravitySchemaChanged();
      }
      return;
    }
    if (root.containsKey('availability')) {
      final availability = root['availability'];
      if (availability is! Map || availability.isEmpty) throw const AntigravitySchemaChanged();
      if (availability.values.any((value) => value is! num && double.tryParse('$value') == null)) throw const AntigravitySchemaChanged();
      return;
    }
    throw const AntigravitySchemaChanged();
  }

  @override Future<TestResult> test(Connection connection, String secret) async {
    final snapshot = await fetch(connection, secret);
    return snapshot.error == null ? TestResult.success(quotas: snapshot.quotas, plan: connection.plan) : TestResult.failure(error: snapshot.error!);
  }
  @override Future<ProviderSnapshot> fetch(Connection connection, String secret) async {
    final credential = _credential(secret);
    final project = _providerData(connection)['projectId']?.toString() ?? credential['projectId']?.toString();
    if (project == null || project.isEmpty) return _error(connection.id, 'Complete Antigravity onboarding before connecting');
    final expected = credential['identityKey']?.toString() ?? connection.identityKey;
    try {
      for (final host in const [prodHost, dailyHost]) {
        try {
          final payload = await _postJson(Uri.parse('$host/v1internal:retrieveUserQuotaSummary'), {'project': project, 'userIdentifier': expected}, bearer: credential['accessToken']?.toString());
          if (!const AntigravitySelectedAccountGuard().accepts(expected: expected, payload: payload)) return _error(connection.id, 'Account mismatch');
          _requireQuotaSchema(payload);
          return AntigravityLocalReader.parseQuotaSummary(body: jsonEncode(payload), connectionId: connection.id);
        } on StateError catch (error) {
          if (!error.message.toString().contains('HTTP 404')) rethrow;
        }
      }
      return await _fetchLegacy(connection, credential, project, expected);
    } on AntigravitySchemaChanged {
      return _error(connection.id, 'quota_source_changed');
    } on AntigravityTransientFailure catch (error) {
      return ProviderSnapshot(connectionId: connection.id, status: ConnectionStatus.warning, quotas: const [], balance: null, fetchedAt: DateTime.now().toUtc(), error: error.toString(), cooldownUntil: DateTime.now().toUtc().add(const Duration(minutes: 1)));
    } catch (error) {
      return _error(connection.id, error.toString().replaceFirst('Exception: ', ''));
    }
  }
  Future<ProviderSnapshot> _fetchLegacy(Connection connection, Map<String, dynamic> credential, String project, String? expected) async {
    final modelsEnvelope = await _postJson(Uri.parse('$prodHost/v1internal:fetchAvailableModels'), {'project': project, 'userIdentifier': expected}, bearer: credential['accessToken']?.toString());
    final quotaEnvelope = await _postJson(Uri.parse('$prodHost/v1internal:retrieveUserQuota'), {'project': project, 'userIdentifier': expected}, bearer: credential['accessToken']?.toString());
    final models = _unwrapEnvelope(modelsEnvelope);
    final quota = _unwrapEnvelope(quotaEnvelope);
    if (!const AntigravitySelectedAccountGuard().accepts(expected: expected, payload: quota)) return _error(connection.id, 'Account mismatch');
    _requireQuotaSchema(quota, legacy: true);
    final quotaInfo = _mergeLegacyModels(quota, models);
    return AntigravityLocalReader.parseQuotaSummary(body: jsonEncode({'response': {'quotaInfo': quotaInfo, 'accountEmail': quota['accountEmail'], 'accountId': quota['accountId']}}), connectionId: connection.id);
  }
  static Map<String, dynamic> _unwrapEnvelope(Map<String, dynamic> value) => value['response'] is Map ? Map<String, dynamic>.from(value['response'] as Map) : value;
  static Map<String, dynamic> _mergeLegacyModels(Map<String, dynamic> quota, Map<String, dynamic> models) {
    final quotaInfo = _map(quota['quotaInfo'] ?? quota);
    final rawModels = models['models'] ?? models['availableModels'];
    if (rawModels is List) {
      for (final raw in rawModels) {
        if (raw is! Map) continue;
        final model = Map<String, dynamic>.from(raw);
        final name = (model['name'] ?? model['model'] ?? model['id'])?.toString();
        if (name != null && name.isNotEmpty) quotaInfo.putIfAbsent(name, () => model);
      }
    } else {
      for (final entry in _map(rawModels).entries) quotaInfo.putIfAbsent(entry.key, () => entry.value);
    }
    return quotaInfo;
  }

  Future<String> refresh(String currentSecret) async {
    final value = _credential(currentSecret); final refreshToken = value['refreshToken']?.toString();
    if (refreshToken == null || refreshToken.isEmpty) throw StateError('refresh token missing');
    final response = await _postJson(Uri.parse(tokenEndpoint), {'client_id': clientId, 'refresh_token': refreshToken, 'grant_type': 'refresh_token', 'access_type': 'offline'});
    if (response['access_token'] == null) throw StateError('invalid_grant');
    return jsonEncode({...value, 'accessToken': response['access_token'], 'refreshToken': response['refresh_token'] ?? refreshToken, 'expiresAt': _expiry(response)?.toIso8601String()});
  }
  Future<Map<String, dynamic>> _postJson(Uri uri, Map<String, dynamic> body, {String? bearer}) async {
    AntigravityOAuthHttpResponse response;
    try { response = await _http.post(uri, headers: {if (bearer != null && bearer.isNotEmpty) 'Authorization': 'Bearer $bearer', 'Content-Type': 'application/json'}, body: jsonEncode(body)); }
    catch (error) { throw AntigravityTransportFailure(error); }
    if (response.statusCode == 429 || response.statusCode >= 500) throw AntigravityTransientFailure(response.statusCode);
    if (response.statusCode < 200 || response.statusCode >= 300) { if (response.statusCode == 401) throw StateError('401'); if (response.statusCode == 400 && response.body.contains('invalid_grant')) throw StateError('invalid_grant'); throw StateError('HTTP ${response.statusCode}'); }
    try { return _map(jsonDecode(response.body)); } catch (_) { throw const AntigravitySchemaChanged(); }
  }
  static Map<String, dynamic> _map(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};
  static Map<String, dynamic> _providerData(Connection c) { try { return c.providerData == null ? <String, dynamic>{} : _map(jsonDecode(c.providerData!)); } catch (_) { return <String, dynamic>{}; } }
  static String? _project(Map<String, dynamic> v) { final r = _map(v['response']); return (r['cloudaicompanionProject'] ?? r['projectId'] ?? r['project'])?.toString(); }
  static String? _tier(Map<String, dynamic> v) { final r = _map(v['response']); final t = _map(r['currentTier']); return (t['id'] ?? t['name'] ?? r['tier'])?.toString(); }
  static DateTime? _expiry(Map<String, dynamic> v) { final s = v['expires_in']; return s is num ? DateTime.now().toUtc().add(Duration(seconds: s.toInt())) : null; }
  static Map<String, dynamic> _credential(String raw) { try { return _map(jsonDecode(raw)); } catch (_) { return {'accessToken': raw}; } }
  ProviderSnapshot _error(String id, String error) => ProviderSnapshot(connectionId: id, status: ConnectionStatus.authError, quotas: const [], balance: null, fetchedAt: DateTime.now().toUtc(), error: error);
}

class AntigravityRefreshableCredential implements RefreshableCredential {
  AntigravityRefreshableCredential(this.provider, this.secret);
  final AntigravityOAuthProvider provider;
  String secret;
  @override DateTime? get expiresAt => DateTime.tryParse(_credential(secret)['expiresAt']?.toString() ?? '');
  @override Duration get refreshLead => const Duration(minutes: 1);
  @override Future<String> refresh(String currentSecret) async { secret = await provider.refresh(currentSecret); return secret; }
  static Map<String, dynamic> _credential(String raw) { try { return Map<String, dynamic>.from(jsonDecode(raw) as Map); } catch (_) { return <String, dynamic>{}; } }
}
class _HttpClientRunner implements AntigravityOAuthHttpRunner {
  @override Future<AntigravityOAuthHttpResponse> post(Uri uri, {required Map<String, String> headers, required String body}) async { final client = HttpClient(); try { final request = await client.postUrl(uri); headers.forEach(request.headers.set); request.write(body); final response = await request.close(); return AntigravityOAuthHttpResponse(statusCode: response.statusCode, body: await response.transform(const Utf8Decoder()).join()); } finally { client.close(force: true); } }
}
