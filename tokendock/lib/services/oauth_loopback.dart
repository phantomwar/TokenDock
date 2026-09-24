import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

final class OAuthLoopbackResult {
  const OAuthLoopbackResult({required this.code, required this.state});

  final String code;
  final String state;
}

abstract final class OAuthLoopback {
  static Future<OAuthLoopbackSession> start({
    String callbackPath = '/callback',
    Duration timeout = const Duration(seconds: 300),
  }) async {
    if (!callbackPath.startsWith('/') ||
        callbackPath.contains('?') ||
        callbackPath.contains('#')) {
      throw ArgumentError.value(
        callbackPath,
        'callbackPath',
        'must be an absolute path without a query or fragment',
      );
    }
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'must be positive');
    }

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpServer? ipv6Server;
    try {
      ipv6Server = await HttpServer.bind(
        InternetAddress.loopbackIPv6,
        server.port,
        shared: true,
      );
    } on SocketException {
      ipv6Server = null;
    }
    final session = OAuthLoopbackSession._(
      servers: [server, if (ipv6Server != null) ipv6Server],
      callbackPath: callbackPath,
      timeout: timeout,
    );
    session._startListening();
    return session;
  }
}

final class OAuthLoopbackSession {
  OAuthLoopbackSession._({
    required List<HttpServer> servers,
    required String callbackPath,
    required Duration timeout,
  }) : _servers = List.unmodifiable(servers),
       _callbackPath = callbackPath,
       redirectUri = Uri(
         scheme: 'http',
         host: InternetAddress.loopbackIPv4.address,
         port: servers.first.port,
         path: callbackPath,
       ) {
    _timer = Timer(timeout, () {
      unawaited(
        _closeWithError(
          TimeoutException('OAuth loopback callback timed out', timeout),
        ),
      );
    });
  }

  final List<HttpServer> _servers;
  final String _callbackPath;
  Completer<OAuthLoopbackResult>? _result;
  final Uri redirectUri;

  late final Timer _timer;
  final List<StreamSubscription<HttpRequest>> _requestSubscriptions = [];
  Future<void>? _closeFuture;
  String? _expectedState;
  OAuthLoopbackResult? _completedResult;
  bool _closed = false;

  void _startListening() {
    for (final server in _servers) {
      _requestSubscriptions.add(server.listen(
        (request) => unawaited(_handleRequest(request)),
        onError: (Object error, StackTrace stackTrace) {
          _fail(error, stackTrace);
        },
        cancelOnError: false,
      ));
    }
  }

  Uri launchUrl(
    Uri authorizationEndpoint, {
    Map<String, String> parameters = const {},
  }) {
    return authorizationEndpoint.replace(
      queryParameters: {
        ...parameters,
        'redirect_uri': redirectUri.toString(),
      },
    );
  }

  Future<OAuthLoopbackResult> waitForCode(String expectedState) {
    final completedResult = _completedResult;
    if (completedResult != null) {
      return Future.value(completedResult);
    }
    if (_closed) {
      throw StateError('OAuth loopback session is closed.');
    }
    if (_expectedState != null) {
      throw StateError('A callback state is already being awaited.');
    }
    if (expectedState.isEmpty) {
      throw ArgumentError.value(
        expectedState,
        'expectedState',
        'must not be empty',
      );
    }

    _expectedState = expectedState;
    return (_result ??= Completer<OAuthLoopbackResult>()).future;
  }

  Future<void> _handleRequest(HttpRequest request) async {
    if (_closed || _completedResult != null) {
      await _close(force: true);
      return;
    }
    if (request.method != 'GET') {
      await _respond(
        request.response,
        HttpStatus.methodNotAllowed,
        'Not allowed',
      );
      return;
    }
    if (request.uri.path != _callbackPath) {
      await _respond(request.response, HttpStatus.notFound, 'Not found');
      return;
    }

    final code = request.uri.queryParameters['code'];
    final state = request.uri.queryParameters['state'];
    final expectedState = _expectedState;
    final resultCompleter = _result;
    if (code == null ||
        code.isEmpty ||
        state == null ||
        expectedState == null ||
        state != expectedState ||
        resultCompleter == null) {
      await _respond(
        request.response,
        HttpStatus.badRequest,
        'Invalid callback',
      );
      return;
    }

    final result = OAuthLoopbackResult(code: code, state: state);
    _completedResult = result;
    resultCompleter.complete(result);

    try {
      await _respond(
        request.response,
        HttpStatus.ok,
        'Authorization complete. You may close this window.',
      );
    } finally {
      await close();
    }
  }

  Future<void> close() => _close(force: true);

  Future<void> _closeWithError(Object error, [StackTrace? stackTrace]) {
    _fail(error, stackTrace);
    return _close(force: true);
  }

  Future<void> _close({required bool force}) {
    return _closeFuture ??= _closeInternal(force);
  }

  Future<void> _closeInternal(bool force) async {
    _fail(
      StateError('OAuth loopback session was closed before completion.'),
    );
    _closed = true;
    _timer.cancel();
    for (final subscription in _requestSubscriptions) {
      await subscription.cancel();
    }
    for (final server in _servers) {
      await server.close(force: force);
    }
  }

  void _fail(Object error, [StackTrace? stackTrace]) {
    final result = _result;
    if (result == null || result.isCompleted) {
      return;
    }
    if (stackTrace == null) {
      result.completeError(error);
    } else {
      result.completeError(error, stackTrace);
    }
  }

  Future<void> _respond(
    HttpResponse response,
    int statusCode,
    String body,
  ) async {
    response.statusCode = statusCode;
    response.headers.contentType = ContentType.html;
    response.write(body);
    await response.close();
  }
}

String buildCodeChallenge(String verifier) {
  final digest = sha256.convert(ascii.encode(verifier)).bytes;
  return base64UrlEncode(digest).replaceAll('=', '');
}

String newCodeVerifier() {
  return _secureBase64Url(32);
}

String newState() {
  return _secureBytes(16).map((byte) {
    return byte.toRadixString(16).padLeft(2, '0');
  }).join();
}

String _secureBase64Url(int byteCount) {
  return base64UrlEncode(_secureBytes(byteCount)).replaceAll('=', '');
}

List<int> _secureBytes(int byteCount) {
  final random = Random.secure();
  return List<int>.generate(
    byteCount,
    (_) => random.nextInt(256),
    growable: false,
  );
}
