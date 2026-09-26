import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/minimax/minimax_usage_response.dart';

/// MiniMax Token Plan usage, ported from the shape oh-my-pi reads at
/// `GET /v1/token_plan/remains`.
///
/// The important, counter-intuitive property, and the reason this parser looks
/// at the body rather than the HTTP status: **MiniMax answers HTTP 200 even for
/// a rejected credential.** The real success signal is
/// `base_resp.status_code === 0`. A parser that trusted the status code would
/// report a full quota for a key that does not work.
void main() {
  final fetchedAt = DateTime.utc(2026, 9, 26, 12);

  /// A live `general` bucket: 5-hour window at 40% remaining, weekly at 72%.
  String liveBucket({int intervalStatus = 1, int weeklyStatus = 1}) =>
      '''
    {
      "model_name": "general",
      "start_time": 1789000000,
      "end_time": 1789018000,
      "current_interval_remaining_percent": 40,
      "current_interval_total_count": 6320,
      "current_interval_usage_count": 3792,
      "current_interval_status": $intervalStatus,
      "weekly_start_time": 1788486400,
      "weekly_end_time": 1789091200,
      "current_weekly_remaining_percent": 72,
      "current_weekly_total_count": 15790,
      "current_weekly_usage_count": 4431,
      "current_weekly_status": $weeklyStatus
    }''';

  String envelope(List<String> buckets, {int statusCode = 0}) =>
      '''
    {"base_resp": {"status_code": $statusCode, "status_msg": "success"},
     "model_remains": [${buckets.join(',')}]}''';

  group('a live plan', () {
    final snapshot = MiniMaxUsageResponse.parse(
      connectionId: 'c1',
      body: envelope([liveBucket()]),
      fetchedAt: fetchedAt,
    );

    test('is healthy', () {
      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.error, isNull);
    });

    test(
      'reports one quota per window, so the user sees total and remaining',
      () {
        final byId = {for (final q in snapshot.quotas) q.id: q};
        expect(
          byId.keys,
          containsAll(<String>['general:interval', 'general:7d']),
          reason:
              'both the rolling interval and the weekly window are separate '
              'budgets, and showing only one would hide half the picture',
        );
      },
    );

    test('remaining percent is reported as remaining, not used', () {
      final interval = snapshot.quotas.firstWhere(
        (q) => q.id == 'general:interval',
      );
      // 40% remaining means 60% used.
      expect(interval.remaining, 40);
      expect(interval.percent, 60);
      expect(interval.limit, 100);
      expect(interval.unit, '%');
    });

    test('the weekly window is reported separately', () {
      final weekly = snapshot.quotas.firstWhere((q) => q.id == 'general:7d');
      expect(weekly.remaining, 72);
      expect(weekly.percent, 28);
    });

    test('the reset time comes from the window end', () {
      final interval = snapshot.quotas.firstWhere(
        (q) => q.id == 'general:interval',
      );
      expect(interval.resetAt, isNotNull);
      expect(
        interval.resetAt!.toUtc().millisecondsSinceEpoch,
        1789018000 * 1000,
      );
    });

    test('labels are human readable rather than raw ids', () {
      expect(
        snapshot.quotas.map((q) => q.label),
        containsAll(<String>['5 Hour limit', '7 Day limit']),
      );
    });
  });

  group('a rejected credential', () {
    test('is detected from the body even though the status was 200', () {
      // This is the whole reason the parser exists. An HTTP-only check would
      // report a pristine quota for a key that does not work.
      final snapshot = MiniMaxUsageResponse.parse(
        connectionId: 'c1',
        body: envelope([liveBucket()], statusCode: 1004),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, ConnectionStatus.authError);
      expect(snapshot.error, 'Invalid API key');
      expect(snapshot.quotas, isEmpty);
    });

    test(
      'is marked as a definitive credential failure so the key is revoked',
      () {
        final snapshot = MiniMaxUsageResponse.parse(
          connectionId: 'c1',
          body: envelope([], statusCode: 1004),
          fetchedAt: fetchedAt,
        );

        expect(snapshot.failureCause, isNotNull);
      },
    );
  });

  group('window status', () {
    test('an exhausted window is 100% used regardless of the percentage', () {
      // The endpoint's own status outranks the percentage: an exhausted window
      // can omit it or keep a stale value that would render as healthy quota.
      final snapshot = MiniMaxUsageResponse.parse(
        connectionId: 'c1',
        body: envelope([liveBucket(intervalStatus: 2)]),
        fetchedAt: fetchedAt,
      );

      final interval = snapshot.quotas.firstWhere(
        (q) => q.id == 'general:interval',
      );
      expect(interval.percent, 100);
      expect(interval.remaining, 0);
    });

    test('a live plan reporting zero totals is still a real plan', () {
      // 0/0 with status 1 and a real remaining percentage is a live plan whose
      // counters happen to be zero. Only the both-unlimited shape means
      // "not in plan".
      final snapshot = MiniMaxUsageResponse.parse(
        connectionId: 'c1',
        body: envelope([
          '{"model_name":"general","start_time":1789000000,'
              '"end_time":1789018000,"current_interval_remaining_percent":100,'
              '"current_interval_total_count":0,"current_interval_usage_count":0,'
              '"current_interval_status":1,"weekly_start_time":1788486400,'
              '"weekly_end_time":1789091200,"current_weekly_remaining_percent":100,'
              '"current_weekly_total_count":0,"current_weekly_usage_count":0,'
              '"current_weekly_status":1}',
        ]),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.quotas, isNotEmpty);
      expect(snapshot.quotas.first.remaining, 100);
    });

    test(
      'a model outside the plan is dropped rather than shown as pristine',
      () {
        // MiniMax reports an out-of-plan model as both windows "unlimited" with
        // zero totals and 100% remaining, which would otherwise read as a
        // perfect quota. The vendors own CLI treats that same shape as
        // "not in plan" (MiniMax-AI/cli#173).
        final snapshot = MiniMaxUsageResponse.parse(
          connectionId: 'c1',
          body: envelope([
            '{"model_name":"not-in-plan","start_time":0,"end_time":0,'
                '"current_interval_remaining_percent":100,'
                '"current_interval_total_count":0,"current_interval_usage_count":0,'
                '"current_interval_status":3,"weekly_start_time":0,'
                '"weekly_end_time":0,"current_weekly_remaining_percent":100,'
                '"current_weekly_total_count":0,"current_weekly_usage_count":0,'
                '"current_weekly_status":3}',
          ]),
          fetchedAt: fetchedAt,
        );

        expect(snapshot.quotas, isEmpty);
      },
    );
  });

  group('malformed input', () {
    test('never throws and never invents a quota', () {
      for (final body in <String>[
        '',
        'not json',
        '[]',
        '{}',
        '{"base_resp":{"status_code":0}}',
        '{"base_resp":{"status_code":0},"model_remains":{}}',
        '{"base_resp":{"status_code":0},"model_remains":[null]}',
        '{"base_resp":{"status_code":0},"model_remains":[{}]}',
        '{"base_resp":{"status_code":0},"model_remains":[{"model_name":""}]}',
      ]) {
        final snapshot = MiniMaxUsageResponse.parse(
          connectionId: 'c1',
          body: body,
          fetchedAt: fetchedAt,
        );
        expect(snapshot.connectionId, 'c1', reason: 'body was "$body"');
        expect(
          snapshot.quotas.where(
            (q) => q.percent == null && q.remaining == null,
          ),
          isEmpty,
          reason: 'a quota with no numbers is worse than no quota',
        );
      }
    });

    test(
      'a bucket missing its percentage is skipped, not rendered as zero',
      () {
        // Rendering 0% would read as "nothing used", which is the opposite of
        // "unknown".
        final snapshot = MiniMaxUsageResponse.parse(
          connectionId: 'c1',
          body: envelope(['{"model_name":"general","end_time":1789018000}']),
          fetchedAt: fetchedAt,
        );

        expect(snapshot.quotas, isEmpty);
      },
    );

    test('a missing base_resp is treated as unknown, not as success', () {
      final snapshot = MiniMaxUsageResponse.parse(
        connectionId: 'c1',
        body: '{"model_remains":[]}',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, isNot(ConnectionStatus.ok));
    });
  });
}
