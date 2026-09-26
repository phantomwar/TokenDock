import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/opencode/opencode_usage_response.dart';

/// OpenCode Go usage, ported from the shape oh-my-pi reads at
/// `GET https://opencode.ai/zen/go/v1/usage`.
///
/// ## Provenance and its risk
///
/// This route is first-party but **undocumented**; oh-my-pi records that its
/// shape "changed once on merge day". That is a materially different risk from
/// MiniMax's published OpenAPI, so the parser is all-or-nothing: if any window is
/// missing or malformed the whole report is discarded, because a partial report
/// would replace a complete one and silently drop the windows the user actually
/// needs to see.
///
/// ## Auth
///
/// Unlike the `/models` listing, this endpoint **does** enforce the key: 401 for
/// a missing or invalid key, 403 for a valid key with no Go subscription. Both
/// mean the credential cannot be used.
void main() {
  final fetchedAt = DateTime.utc(2026, 9, 26, 12);

  String window({
    String status = 'ok',
    int percent = 40,
    String resetsAt = '2026-09-26T17:00:00.000Z',
  }) => '{"status":"$status","percent":$percent,"resetsAt":"$resetsAt"}';

  String envelope({
    String rolling = 'null',
    String weekly = 'null',
    String monthly = 'null',
  }) => '{"usage":{"rolling":$rolling,"weekly":$weekly,"monthly":$monthly}}';

  String full() => envelope(
    rolling: window(percent: 80),
    weekly: window(percent: 45),
    monthly: window(percent: 20),
  );

  group('a complete report', () {
    final snapshot = OpenCodeUsageResponse.parse(
      connectionId: 'c1',
      body: full(),
      fetchedAt: fetchedAt,
    );

    test('is healthy', () {
      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.error, isNull);
    });

    test('reports all three windows, so the user sees the binding one', () {
      // Go meters 5-hour, weekly and monthly independently. Showing one and
      // calling it "the quota" would hide whichever is actually exhausted.
      final byId = {for (final q in snapshot.quotas) q.id: q};
      expect(byId.keys, containsAll(<String>['5h', '7d', 'monthly']));
    });

    test('percent is used, and remaining is derived from it', () {
      final rolling = snapshot.quotas.firstWhere((q) => q.id == '5h');
      expect(rolling.percent, 80);
      expect(rolling.remaining, 20);
      expect(rolling.limit, 100);
      expect(rolling.unit, '%');
    });

    test('reset times come from the payload', () {
      final rolling = snapshot.quotas.firstWhere((q) => q.id == '5h');
      expect(rolling.resetAt, isNotNull);
      expect(
        rolling.resetAt!.toUtc().toIso8601String(),
        '2026-09-26T17:00:00.000Z',
      );
    });

    test('labels name the window', () {
      expect(
        snapshot.quotas.map((q) => q.label),
        containsAll(<String>['5 Hour limit', 'Weekly limit', 'Monthly limit']),
      );
    });
  });

  group('exhaustion', () {
    test(
      'a rate-limited window is 100% used even if the percent disagrees',
      () {
        final snapshot = OpenCodeUsageResponse.parse(
          connectionId: 'c1',
          body: envelope(
            rolling: window(status: 'rate-limited', percent: 12),
            weekly: window(),
            monthly: window(),
          ),
          fetchedAt: fetchedAt,
        );

        final rolling = snapshot.quotas.firstWhere((q) => q.id == '5h');
        expect(rolling.percent, 100);
        expect(rolling.remaining, 0);
      },
    );
  });

  group('all-or-nothing', () {
    // `RefreshService` replaces the cached quota with whatever a snapshot
    // carries, so a report that cannot be fully decoded must NOT come back
    // healthy-and-empty: that would blank the user's card the moment an
    // undocumented route changed shape. A non-ok snapshot takes the error path,
    // which keeps the last known values and their age.
    test(
      'a missing window discards the whole report rather than half of it',
      () {
        final snapshot = OpenCodeUsageResponse.parse(
          connectionId: 'c1',
          body: envelope(rolling: window(), weekly: window()),
          fetchedAt: fetchedAt,
        );

        expect(snapshot.quotas, isEmpty);
        expect(
          snapshot.status,
          isNot(ConnectionStatus.ok),
          reason: 'a partial report is a reshape, not an empty quota',
        );
      },
    );

    test('a malformed window discards the whole report', () {
      for (final bad in <String>[
        '{"status":"ok","percent":"40","resetsAt":"2026-09-26T17:00:00.000Z"}',
        '{"status":"ok","percent":140,"resetsAt":"2026-09-26T17:00:00.000Z"}',
        '{"status":"ok","percent":-5,"resetsAt":"2026-09-26T17:00:00.000Z"}',
        '{"status":"weird","percent":40,"resetsAt":"2026-09-26T17:00:00.000Z"}',
        '{"status":"ok","percent":40}',
        '{"status":"ok","percent":40,"resetsAt":"not-a-date"}',
      ]) {
        final snapshot = OpenCodeUsageResponse.parse(
          connectionId: 'c1',
          body: envelope(rolling: bad, weekly: window(), monthly: window()),
          fetchedAt: fetchedAt,
        );
        expect(snapshot.quotas, isEmpty, reason: 'bad window: $bad');
        expect(snapshot.status, isNot(ConnectionStatus.ok));
      }
    });

    test('a body that is not the documented shape is an unknown response', () {
      for (final body in <String>[
        '',
        'not json',
        '[]',
        '{}',
        '{"usage":[]}',
        '{"usage":{}}',
        '{"usage":null}',
      ]) {
        final snapshot = OpenCodeUsageResponse.parse(
          connectionId: 'c1',
          body: body,
          fetchedAt: fetchedAt,
        );
        expect(
          snapshot.status,
          isNot(ConnectionStatus.ok),
          reason: 'body was "$body"',
        );
        expect(snapshot.quotas, isEmpty, reason: 'body was "$body"');
      }
    });
  });

  group('auth', () {
    test('401 means the key is not usable', () {
      final snapshot = OpenCodeUsageResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 401,
      );

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.failureCause, isNotNull);
    });

    test('403 means a valid key with no Go subscription', () {
      // Forbidden, not a rejected credential. Reporting it as an auth error
      // would tell the user to re-enter a key that is fine.
      final snapshot = OpenCodeUsageResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 403,
      );

      expect(snapshot.status, ConnectionStatus.error);
      expect(snapshot.error, 'Forbidden');
    });

    test('5xx is transient and does not invalidate the key', () {
      final snapshot = OpenCodeUsageResponse.mapError(
        connectionId: 'c1',
        fetchedAt: fetchedAt,
        statusCode: 503,
      );

      expect(snapshot.failureCause, isNull);
    });
  });

  test('the parser never throws', () {
    for (final body in <String>['{', 'null', '[]', '{"usage":null}', '']) {
      final snapshot = OpenCodeUsageResponse.parse(
        connectionId: 'c1',
        body: body,
        fetchedAt: fetchedAt,
      );
      expect(snapshot.connectionId, 'c1', reason: 'body was "$body"');
    }
  });
}
