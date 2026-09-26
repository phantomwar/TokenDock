import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/oauth_loopback.dart';

/// The loopback listener must own its port exclusively.
///
/// Audit C-14: the IPv6 companion socket was bound with `shared: true`, which
/// lets another local process take the same `[::1]:port` and receive the
/// authorization code and state. Both the design spec and the hardening plan
/// require `SO_EXCLUSIVEADDRUSE`-like semantics.
void main() {
  test(
    'the IPv6 loopback companion is not shared with another listener',
    () async {
      final session = await OAuthLoopback.start();
      addTearDown(session.close);
      final port = session.redirectUri.port;

      // If the session holds [::1]:port as a shared socket, a second listener
      // can take the same address and receive the authorization code and state.
      HttpServer? squatter;
      try {
        squatter = await HttpServer.bind(
          InternetAddress.loopbackIPv6,
          port,
          shared: true,
        );
      } on SocketException {
        squatter = null;
      }
      addTearDown(() async {
        final bound = squatter;
        if (bound != null) await bound.close(force: true);
      });

      expect(
        squatter,
        isNull,
        reason:
            'the IPv6 loopback port must not be bindable by a second process',
      );
    },
  );

  test('the session still serves the callback over IPv6 loopback', () async {
    final session = await OAuthLoopback.start();
    addTearDown(session.close);
    const state = 'ipv6-state';
    final code = session.waitForCode(state);

    // The redirect target stays the literal IPv4 address, but a browser may
    // resolve the loopback host to ::1 first, so the companion must listen.
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri(
        scheme: 'http',
        host: '[${InternetAddress.loopbackIPv6.address}]',
        port: session.redirectUri.port,
        path: session.redirectUri.path,
        queryParameters: {'code': 'ipv6-code', 'state': state},
      ),
    );
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.ok);
    final result = await code;
    expect(result.code, 'ipv6-code');
  }, skip: false);

  test(
    'the session still completes a normal authorization-code callback',
    () async {
      final session = await OAuthLoopback.start();
      addTearDown(session.close);
      const state = 'expected-state-value';
      final code = session.waitForCode(state);

      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.getUrl(
        session.redirectUri.replace(
          queryParameters: {'code': 'auth-code', 'state': state},
        ),
      );
      final response = await request.close();
      await response.drain<void>();

      final result = await code;
      expect(result.code, 'auth-code');
      expect(result.state, state);
    },
  );

  test('a mismatched state is rejected without completing the wait', () async {
    final session = await OAuthLoopback.start();
    addTearDown(session.close);
    final code = session.waitForCode('expected-state-value');
    // The pending wait errors when the session closes; keep that from surfacing
    // as an unhandled async error in this test.
    final outcomes = <String>[];
    unawaited(
      code.then(
        (r) => outcomes.add('ok:${r.code}'),
        onError: (Object e) => outcomes.add('error'),
      ),
    );

    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      session.redirectUri.replace(
        queryParameters: {'code': 'auth-code', 'state': 'attacker-state'},
      ),
    );
    final response = await request.close();
    await response.drain<void>();

    expect(response.statusCode, HttpStatus.badRequest);

    // The legitimate wait must still be pending, not satisfied.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(outcomes, isEmpty);
  });
}
