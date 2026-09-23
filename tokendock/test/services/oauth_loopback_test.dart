import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/services/oauth_loopback.dart';

void main() {
  group('OAuthLoopback', () {
    test('builds the RFC 7636 S256 challenge without padding', () {
      expect(
        buildCodeChallenge(
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        ),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('generates PKCE verifier and state with secure formats', () {
      final verifier = newCodeVerifier();
      final state = newState();

      expect(verifier, hasLength(43));
      expect(verifier, matches(RegExp(r'^[A-Za-z0-9_-]+$')));
      expect(state, hasLength(32));
      expect(state, matches(RegExp(r'^[0-9a-f]+$')));
    });

    test('builds a launch URL with the bound loopback redirect', () async {
      final session = await OAuthLoopback.start();
      addTearDown(session.close);

      final url = session.launchUrl(
        Uri.parse('https://provider.example/authorize?client_id=original'),
        parameters: const {
          'client_id': 'public-client',
          'response_type': 'code',
          'code_challenge': 'challenge',
          'state': 'secure-state',
          'redirect_uri': 'https://attacker.example/steal',
        },
      );

      expect(url.origin, 'https://provider.example');
      expect(url.path, '/authorize');
      expect(url.queryParameters['client_id'], 'public-client');
      expect(url.queryParameters['response_type'], 'code');
      expect(url.queryParameters['code_challenge'], 'challenge');
      expect(url.queryParameters['state'], 'secure-state');
      expect(
        url.queryParameters['redirect_uri'],
        session.redirectUri.toString(),
      );
    });

    test('round-trips one valid callback and closes the listener', () async {
      final session = await OAuthLoopback.start(
        callbackPath: '/oauth/callback',
        timeout: const Duration(seconds: 5),
      );
      addTearDown(session.close);

      expect(session.redirectUri.scheme, 'http');
      expect(session.redirectUri.host, '127.0.0.1');
      expect(session.redirectUri.port, greaterThan(0));
      expect(session.redirectUri.path, '/oauth/callback');

      final delivered = session.waitForCode('expected-state');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final mismatchResponse = await (await client.getUrl(
        session.redirectUri.replace(
          queryParameters: {'code': 'wrong', 'state': 'other-state'},
        ),
      )).close();
      expect(mismatchResponse.statusCode, HttpStatus.badRequest);
      await mismatchResponse.drain<void>();

      final callbackResponse = await (await client.getUrl(
        session.redirectUri.replace(
          queryParameters: {
            'code': 'authorization-code',
            'state': 'expected-state',
          },
        ),
      )).close();
      expect(callbackResponse.statusCode, HttpStatus.ok);
      expect(
        await utf8.decoder.bind(callbackResponse).join(),
        contains('Authorization complete'),
      );

      final result = await delivered;
      expect(result.code, 'authorization-code');
      expect(result.state, 'expected-state');
      await expectLater(
        client.getUrl(session.redirectUri).then((request) => request.close()),
        throwsA(anyOf(isA<SocketException>(), isA<HttpException>())),
      );
    });

    test('rejects malformed callbacks and times out without a code', () async {
      final session = await OAuthLoopback.start(
        timeout: const Duration(milliseconds: 50),
      );
      addTearDown(session.close);

      final delivered = session.waitForCode('expected-state');
      final client = HttpClient();
      addTearDown(() => client.close(force: true));

      final response = await (await client.getUrl(
        session.redirectUri.replace(
          queryParameters: {'state': 'expected-state'},
        ),
      )).close();
      expect(response.statusCode, HttpStatus.badRequest);
      await response.drain<void>();

      await expectLater(delivered, throwsA(isA<TimeoutException>()));
    });
  });
}
