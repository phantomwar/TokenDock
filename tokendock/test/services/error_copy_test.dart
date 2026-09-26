import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/antigravity/antigravity_oauth.dart';
import 'package:tokendock/services/error_copy.dart';

/// The single rule behind `userSafeErrorMessage`: the exception object is never
/// interpolated (audit C-12, C-15).
void main() {
  group('known failures map to deliberate copy', () {
    test('a transport failure does not read as a crash', () {
      expect(
        userSafeErrorMessage(
          const AntigravityTransportFailure(
            'Connection refused to 10.0.0.5:5432 with token ya29.LEAK',
          ),
          fallback: 'fallback',
        ),
        'Could not reach the provider.',
      );
    });

    test(
      'onboarding, cancellation, transient and schema changes are distinct',
      () {
        expect(
          userSafeErrorMessage(
            const AntigravityOnboardingRequired(),
            fallback: 'f',
          ),
          contains('onboarding'),
        );
        expect(
          userSafeErrorMessage(
            const AntigravityLoginCancelled(),
            fallback: 'f',
          ),
          contains('cancelled'),
        );
        expect(
          userSafeErrorMessage(
            const AntigravityTransientFailure(429),
            fallback: 'f',
          ),
          contains('busy'),
        );
        expect(
          userSafeErrorMessage(const AntigravitySchemaChanged(), fallback: 'f'),
          contains('quota format'),
        );
      },
    );

    test('a timeout and a malformed body read differently', () {
      expect(
        userSafeErrorMessage(TimeoutException('took too long'), fallback: 'f'),
        contains('too long'),
      );
      expect(
        userSafeErrorMessage(const FormatException('bad json'), fallback: 'f'),
        contains('unexpected response'),
      );
    });
  });

  group('an unrecognised failure never reaches the user verbatim', () {
    test('an exception carrying SQL falls back to the caller copy', () {
      const leaky =
          'SQL logic error (code 1) no such table: connections. '
          'Causing statement: SELECT secret_ref FROM connections';
      final message = userSafeErrorMessage(
        _Leaky(leaky),
        fallback: 'Could not save this connection.',
      );
      expect(message, 'Could not save this connection.');
      expect(message, isNot(contains('SELECT')));
      expect(message, isNot(contains('secret_ref')));
    });

    test('an exception carrying a credential falls back', () {
      final message = userSafeErrorMessage(
        _Leaky('probe failed for key: sk-or-v1-LIVEKEY0123456789'),
        fallback: 'Could not reach the provider.',
      );
      expect(message, isNot(contains('LIVEKEY')));
      expect(message, isNot(contains('sk-')));
    });

    test('an unsupported platform is reported as such', () {
      expect(
        userSafeErrorMessage(
          UnsupportedError('browser handoff'),
          fallback: 'f',
        ),
        contains('not supported'),
      );
    });
  });
}

class _Leaky implements Exception {
  _Leaky(this.message);
  final String message;
  @override
  String toString() => message;
}
