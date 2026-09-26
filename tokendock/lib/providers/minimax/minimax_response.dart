import 'dart:convert';

import '../../models/provider_snapshot.dart';
import '../provider_status.dart';

/// Parses MiniMax's OpenAI-compatible `GET /v1/models` response.
///
/// The schema is the vendor's own OpenAPI document, not a guess:
/// `{"object":"list","data":[{"id":...,"object":"model","created":...,
/// "owned_by":...}]}`.
class MiniMaxResponse {
  const MiniMaxResponse._();

  /// The credential is valid when the body is the documented list shape.
  ///
  /// There are deliberately no quotas. MiniMax publishes no balance, usage or
  /// quota endpoint anywhere in its documented API surface: the Token Plan quota
  /// "is shown as a usage bar in the console", and pay-as-you-go draws down a
  /// console balance. A quota emitted here would be a number this app invented
  /// and showed to the user as if the provider had reported it.
  static ProviderSnapshot parseModels({
    required String connectionId,
    required String body,
    required DateTime fetchedAt,
  }) {
    try {
      final dynamic decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      final data = decoded['data'];
      if (data is! List) {
        return ProviderStatus.malformed(
          connectionId: connectionId,
          fetchedAt: fetchedAt,
        );
      }

      // Every entry must carry a non-empty id. A list of objects that do not is
      // not the documented shape, and treating it as success would let a
      // future error envelope pass the credential gate.
      for (final entry in data) {
        if (entry is! Map) {
          return ProviderStatus.malformed(
            connectionId: connectionId,
            fetchedAt: fetchedAt,
          );
        }
        final id = entry['id'];
        if (id is! String || id.isEmpty) {
          return ProviderStatus.malformed(
            connectionId: connectionId,
            fetchedAt: fetchedAt,
          );
        }
      }

      // An empty list is a valid, authenticated key with no models enabled.
      return ProviderStatus.ok(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    } catch (_) {
      return ProviderStatus.malformed(
        connectionId: connectionId,
        fetchedAt: fetchedAt,
      );
    }
  }

  /// Maps a non-2xx response onto the shared status rules.
  ///
  /// MiniMax's error envelope puts the status in `error.http_code` as a
  /// **string**, confirmed against the live endpoint:
  /// `{"type":"error","error":{"type":"authorized_error","message":"...",
  /// "http_code":"401"},"request_id":"..."}`. Both forms are accepted so the
  /// classification does not depend on the transport reporting a usable code.
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
