import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/providers/provider_status.dart';

/// The shared status rules, extracted from `OpenRouterResponse` and now also
/// used by `MiniMaxResponse`.
///
/// This file exists to keep one copy of the load-bearing part. The 401 row is
/// what makes `RefreshService` treat a key as definitively dead, prompt a
/// re-login, and stop retrying it. Two copies of that table would eventually
/// disagree, and the disagreement would be a connection that silently never
/// recovers.
void main() {
  group('status mapping', () {
    test('401 invalidates the credential', () {
      final mapped = ProviderStatus.fromHttpStatus(401);
      expect(mapped.status, ConnectionStatus.authError);
      expect(mapped.error, 'Invalid API key');
    });

    test('403 is forbidden, not a dead credential', () {
      // A key that authenticated and was then refused must not be revoked.
      // Mapping 403 to authError told users to re-enter a working key, and is
      // the correction recorded in the first-goal spec (audit C-34).
      final mapped = ProviderStatus.fromHttpStatus(403);
      expect(mapped.status, ConnectionStatus.error);
      expect(mapped.status, isNot(ConnectionStatus.authError));
    });

    test('402 is an exhausted balance, not a bad key', () {
      expect(
        ProviderStatus.fromHttpStatus(402).status,
        ConnectionStatus.limited,
      );
    });

    test('429 is a warning, and does not invalidate anything', () {
      final mapped = ProviderStatus.fromHttpStatus(429);
      expect(mapped.status, ConnectionStatus.warning);
      expect(mapped.error, 'Rate limited');
    });

    test('5xx is the provider having a bad day', () {
      for (final code in [500, 502, 503, 599]) {
        final mapped = ProviderStatus.fromHttpStatus(code);
        expect(mapped.status, ConnectionStatus.error, reason: 'code $code');
        expect(mapped.error, 'Provider unavailable', reason: 'code $code');
      }
    });

    test('an unmapped code degrades to an unknown response, never a guess', () {
      for (final code in [0, 204, 301, 400, 418, 600]) {
        expect(
          ProviderStatus.fromHttpStatus(code).error,
          'Unknown response',
          reason: 'code $code',
        );
      }
    });
  });

  group('failure snapshots', () {
    final fetchedAt = DateTime.utc(2026, 9, 26, 12);

    test('carry no quotas, so a failure never erases the cache', () {
      // Cache-first truth: the user keeps the last known value during a
      // provider failure.
      final snapshot = ProviderStatus.failure(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        status: ConnectionStatus.error,
        error: 'Provider unavailable',
      );

      expect(snapshot.quotas, isEmpty);
      expect(snapshot.connectionId, 'c1');
      expect(snapshot.fetchedAt, fetchedAt);
    });

    test('mark only auth errors as a definitive credential failure', () {
      ProviderFailureCause? causeFor(ConnectionStatus status) =>
          ProviderStatus.failure(
            connectionId: 'c1',
            fetchedAt: fetchedAt,
            status: status,
            error: 'x',
          ).failureCause;

      expect(causeFor(ConnectionStatus.authError), isNotNull);
      expect(causeFor(ConnectionStatus.error), isNull);
      expect(causeFor(ConnectionStatus.warning), isNull);
      expect(causeFor(ConnectionStatus.limited), isNull);
    });

    test('a timeout says so', () {
      expect(
        ProviderStatus.timeout(connectionId: 'c1', fetchedAt: fetchedAt).error,
        'Timeout',
      );
    });

    test('a malformed body says unknown response', () {
      expect(
        ProviderStatus.malformed(
          connectionId: 'c1',
          fetchedAt: fetchedAt,
        ).error,
        'Unknown response',
      );
    });
  });
}
