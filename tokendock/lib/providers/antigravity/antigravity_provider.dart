import 'dart:convert';

import '../../models/connection.dart';
import '../../models/provider_snapshot.dart';
import 'antigravity_local.dart';
import 'antigravity_oauth.dart';

/// Antigravity adapter with explicit local-source dispatch and remote OAuth as
/// the default for ordinary API-key-style OAuth connections.
class AntigravityProvider extends AntigravityOAuthProvider {
  AntigravityProvider({
    super.http,
    super.secretStore,
    AntigravityLocalReader? localReader,
  }) : _localReader = localReader ?? AntigravityLocalReader();

  final AntigravityLocalReader _localReader;

  @override
  Future<ProviderSnapshot> fetch(Connection connection, String secret) {
    final source = _source(connection);
    if (source == 'language-server' || source == 'agy-cli') {
      return _localReader.fetchSnapshot(connection);
    }
    return super.fetch(connection, secret);
  }

  static String? _source(Connection connection) {
    if (connection.providerData == null) return null;
    try {
      final decoded = jsonDecode(connection.providerData!);
      return decoded is Map ? decoded['source']?.toString() : null;
    } catch (_) {
      return null;
    }
  }
}
