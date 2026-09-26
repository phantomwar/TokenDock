import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The outcome of a probe: either a response, or a transport failure.
///
/// Every outcome is a [ProbeResult], including exceptions, so a caller cannot
/// forget the timeout case.
class ProbeResult {
  const ProbeResult._({
    required this.statusCode,
    required this.body,
    required this.isTimeout,
    required this.transportFailure,
  });

  const ProbeResult.response({required int statusCode, required String body})
    : this._(
        statusCode: statusCode,
        body: body,
        isTimeout: false,
        transportFailure: false,
      );

  const ProbeResult.timeout()
    : this._(
        statusCode: null,
        body: null,
        isTimeout: true,
        transportFailure: false,
      );

  const ProbeResult.transportFailure()
    : this._(
        statusCode: null,
        body: null,
        isTimeout: false,
        transportFailure: true,
      );

  final int? statusCode;
  final String? body;

  /// The request did not complete in time. Kept distinct from
  /// [transportFailure] because the user-facing copy differs: a timeout is not
  /// the same news as a refused connection.
  final bool isTimeout;

  /// The request failed before a response: DNS, refused, reset, TLS.
  final bool transportFailure;

  bool get isSuccess {
    final code = statusCode;
    return code != null && code >= 200 && code < 300;
  }
}

/// A bounded, authenticated GET against a provider API.
///
/// `OpenRouterProvider`, `MiniMaxProvider` and `OpenCodeGoProvider` all need the
/// same thing, and were about to become three copies of it: an `HttpClient` with
/// a connection timeout, a bearer header, a response timeout, a body read with a
/// cap, and the distinction between "the request did not finish" and "the
/// request failed".
///
/// OpenCode Go is also why [getJson] takes [extraHeaders]: it treats traffic
/// without a stable `x-opencode-session` or a real user agent as unrecognised, so
/// a bearer token alone is not enough to get a response. That requirement is
/// per-provider, so the parameter is a plain map rather than a per-vendor
/// subclass -- a subclass would multiply for a difference that is two headers.
///
/// The bounds are the reason this exists. Audit C-01 established that a hung
/// socket leaves a connection's in-flight future pending forever, and
/// `RefreshService` chains every later refresh behind it, so every await here is
/// bounded. Collapsing a timeout into a generic error would tell the user the
/// wrong thing about why their number did not update.
class ProviderHttpProbe {
  ProviderHttpProbe({
    HttpClient? client,
    this.connectionTimeout = const Duration(seconds: 10),
    this.responseTimeout = const Duration(seconds: 15),
    this.maxBodyBytes = 1024 * 1024,
  }) : _client = client ?? HttpClient() {
    _client.connectionTimeout = connectionTimeout;
  }

  final HttpClient _client;
  final Duration connectionTimeout;
  final Duration responseTimeout;
  final int maxBodyBytes;

  /// GETs [uri] with `Authorization: Bearer <secret>`.
  ///
  /// [extraHeaders] carries provider-specific requirements. OpenCode Go, for
  /// instance, treats traffic as unrecognised without a stable
  /// `x-opencode-session` and a real user agent, and says so in its own
  /// documentation.
  ///
  /// [authorization] overrides the whole header when a vendor does not use the
  /// Bearer scheme. z.ai sends the raw key in `Authorization` with no prefix,
  /// so prefixing it here would send `Bearer <key>` and be rejected. The
  /// credential is still never placed in the URL, and the adapter decides the
  /// scheme by returning a header value -- the probe has no knowledge of which
  /// vendors exist.
  ///
  /// Never throws. Every failure becomes a [ProbeResult], because this runs on
  /// the refresh path where an escaping exception would take down every
  /// connection's cached quota rather than just this one.
  Future<ProbeResult> getJson(
    Uri uri, {
    required String secret,
    Map<String, String> extraHeaders = const <String, String>{},
    String? authorization,
  }) async {
    try {
      final request = await _client.getUrl(uri).timeout(connectionTimeout);
      request.headers.set(
        HttpHeaders.authorizationHeader,
        authorization ?? 'Bearer $secret',
      );
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      extraHeaders.forEach(request.headers.set);

      final response = await request.close().timeout(responseTimeout);
      final bytes = await _readBounded(response);
      return ProbeResult.response(
        statusCode: response.statusCode,
        body: bytes == null ? '' : utf8.decode(bytes, allowMalformed: true),
      );
    } on TimeoutException {
      return const ProbeResult.timeout();
    } on SocketException {
      return const ProbeResult.transportFailure();
    } on HandshakeException {
      return const ProbeResult.transportFailure();
    } on HttpException {
      return const ProbeResult.transportFailure();
    } on Object {
      return const ProbeResult.transportFailure();
    }
  }

  /// Reads at most [maxBodyBytes], so a huge or endless body cannot exhaust
  /// memory on the refresh path.
  Future<List<int>?> _readBounded(HttpClientResponse response) async {
    final chunks = <int>[];
    var total = 0;
    await for (final chunk in response) {
      total += chunk.length;
      if (total > maxBodyBytes) {
        return chunks;
      }
      chunks.addAll(chunk);
    }
    return chunks;
  }

  void close() => _client.close(force: true);
}
