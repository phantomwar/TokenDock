import 'dart:convert';

import '../../models/provider_snapshot.dart';
import '../provider_status.dart';

/// The MiniMax credential gate: `GET /v1/models`, plus the error mapping.
///
/// The schema of a successful body is the vendor's own OpenAPI document, not a
/// guess: `{"object":"list","data":[{"id":...,"object":"model",
/// "created":...,"owned_by":...}]}`. Nothing here decodes it, and that is
/// deliberate.
///
/// This class once parsed the catalog to decide whether a credential was good,
/// and had a note explaining why it emitted no quota: the catalog carries no
/// usage, so a number built from it would be invented. Both parts of that are
/// now superseded. The quota is real and comes from
/// `minimax_usage_response.dart`; and the gate no longer needs a second opinion
/// on validity, because the Token Plan body carries MiniMax's own success signal
/// in `base_resp.status_code`, which is strictly more authoritative than
/// "the list looked the way I expected". One authority beats two, and the
/// weaker one is the one that would have to be kept in step.
///
/// What remains is the transport concern: which endpoint, and how a failure is
/// classified.
class MiniMaxResponse {
  const MiniMaxResponse._();

  /// The vendor's own OpenAPI document names `https://api.minimax.io` as the
  /// server for `GET /v1/models`. This is the credential gate: it answers 401
  /// for a bad key, which the Token Plan endpoint does not -- that one answers
  /// 200 regardless and signals rejection in the body.
  static final Uri defaultModelsEndpoint = Uri.parse(
    'https://api.minimax.io/v1/models',
  );

  /// Maps a non-2xx response onto the shared status rules.
  ///
  /// The status-code mapping itself lives in `ProviderStatus` and is not
  /// duplicated here. What MiniMax contributes is the fallback: its error
  /// envelope carries the status inside the body, as a **string**, confirmed
  /// against the live endpoint:
  /// `{"type":"error","error":{"type":"authorized_error","message":"...",
  /// "http_code":"401"},"request_id":"..."}`. Reading it means a rejected
  /// credential is still classified as rejected if the transport does not
  /// surface a usable code.
  static ProviderSnapshot mapError({
    required String connectionId,
    required DateTime fetchedAt,
    int? statusCode,
    String? body,
    bool isTimeout = false,
  }) {
    if (isTimeout) {
      return ProviderStatus.timeout(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    }

    final effective = statusCode ?? _statusFromBody(body);
    if (effective == null) {
      return ProviderStatus.malformed(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    }
    final mapped = ProviderStatus.fromHttpStatus(effective);
    return ProviderStatus.failure(
      connectionId: connectionId,
      fetchedAt: fetchedAt,
      status: mapped.status,
      error: mapped.error,
    );
  }

  /// Reads `error.http_code`, tolerating either type.
  ///
  /// Returns null rather than guessing, so an unrecognised envelope becomes
  /// "Unknown response" instead of being classified as whatever the nearest
  /// plausible number happens to be.
  static int? _statusFromBody(String? body) {
    if (body == null || body.isEmpty) return null;
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map) return null;
      final error = decoded['error'];
      if (error is! Map) return null;
      final code = error['http_code'];
      if (code is int) return code;
      if (code is String) return int.tryParse(code.trim());
      return null;
    } catch (_) {
      return null;
    }
  }
}
