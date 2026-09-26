import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/providers/zai/zai_usage_response.dart';

/// z.ai (GLM Coding Plan) usage, ported from the shape oh-my-pi reads at
/// `GET https://api.z.ai/api/monitor/usage/quota/limit`.
///
/// Three things about this endpoint drive the design:
///
/// - **The body is the authority.** `success` is the real success signal, so a
///   `success: false` with an error `code` must not read as an empty quota.
/// - **`percentage` is server-rounded.** For 1438 of 12000 credits it reports
///   `11`, not `11.98`. So an exact ratio is preferred wherever both absolutes
///   are present, and `percentage` is the fallback only when they are not.
/// - **The window is encoded, not named.** `unit` is an enum and `number` is the
///   count, so "5 hours" is `unit: 3, number: 5`.
void main() {
  final fetchedAt = DateTime.utc(2026, 9, 26, 12);

  String limit({
    String type = 'TIME_LIMIT',
    int unit = 3,
    int number = 5,
    num usage = 600,
    num currentValue = 120,
    num? remaining,
    num? percentage,
    int? nextResetTime,
  }) {
    final parts = <String>[
      '"type":"$type"',
      '"unit":$unit',
      '"number":$number',
      '"usage":$usage',
      '"currentValue":$currentValue',
      if (remaining != null) '"remaining":$remaining',
      if (percentage != null) '"percentage":$percentage',
      if (nextResetTime != null) '"nextResetTime":$nextResetTime',
    ];
    return '{${parts.join(',')}}';
  }

  String envelope(List<String> limits, {bool success = true, String? level}) {
    return '{"success":$success,"code":0,"msg":"ok","data":'
        '{"limits":[${limits.join(',')}]'
        '${level == null ? '' : ',"level":"$level"'}}}';
  }

  group('a coding-plan payload', () {
    final snapshot = ZaiUsageResponse.parse(
      connectionId: 'z1',
      body: envelope([
        limit(
          unit: 3,
          number: 5,
          usage: 600,
          currentValue: 120,
          remaining: 480,
          percentage: 20,
          nextResetTime: 1789018000000,
        ),
      ], level: 'pro'),
      fetchedAt: fetchedAt,
    );

    test('is healthy', () {
      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.error, isNull);
    });

    test('reports total and remaining, which is the whole point', () {
      final quota = snapshot.quotas.single;
      expect(quota.remaining, 480);
      expect(quota.limit, 600);
      expect(quota.percent, 20);
      expect(quota.unit, 'requests');
    });

    test('derives the window label from unit and number, not a guess', () {
      expect(snapshot.quotas.single.label, '5 Hour limit');
    });

    test('the reset time is read as milliseconds', () {
      // 1789018000000 ms, not seconds. Treating it as seconds would put the
      // reset in the year 58000 and the countdown would never fire.
      expect(
        snapshot.quotas.single.resetAt!.toUtc().millisecondsSinceEpoch,
        1789018000000,
      );
    });

    test('each limit type is metered in its own unit', () {
      final quotas = {for (final q in snapshot.quotas) q.id: q};
      expect(quotas.values.map((q) => q.unit), everyElement('requests'));

      final mixed = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([
          limit(
            type: 'TIME_LIMIT',
            unit: 3,
            number: 5,
            usage: 600,
            currentValue: 120,
            percentage: 20,
          ),
          limit(
            type: 'TOKENS_LIMIT',
            unit: 6,
            number: 1,
            usage: 90000000,
            currentValue: 9000000,
            percentage: 10,
          ),
          limit(
            type: 'CREDIT_LIMIT',
            unit: 4,
            number: 1,
            usage: 12000,
            currentValue: 1438,
            percentage: 11,
          ),
        ]),
        fetchedAt: fetchedAt,
      );

      expect(
        {for (final q in mixed.quotas) q.id: q.unit},
        {
          'requests:5h': 'requests',
          'tokens:1w': 'tokens',
          'credits:1d': 'credits',
        },
      );
    });

    test('all three window shapes are labelled from the enum', () {
      final quotas = {
        for (final q in ZaiUsageResponse.parse(
          connectionId: 'z1',
          body: envelope([
            limit(
              type: 'TIME_LIMIT',
              unit: 3,
              number: 5,
              usage: 10,
              currentValue: 1,
              percentage: 10,
            ),
            limit(
              type: 'TOKENS_LIMIT',
              unit: 4,
              number: 7,
              usage: 10,
              currentValue: 1,
              percentage: 10,
            ),
            limit(
              type: 'CREDIT_LIMIT',
              unit: 5,
              number: 1,
              usage: 10,
              currentValue: 1,
              percentage: 10,
            ),
            limit(
              type: 'TIME_LIMIT',
              unit: 6,
              number: 1,
              usage: 10,
              currentValue: 1,
              percentage: 10,
            ),
          ]),
          fetchedAt: fetchedAt,
        ).quotas)
          q.id: q.label,
      };
      expect(
        quotas.values,
        containsAll(<String>[
          '5 Hour limit',
          '7 Day limit',
          'Monthly limit',
          'Weekly limit',
        ]),
      );
    });
  });

  group('percentage is rounded, so the exact ratio wins', () {
    test('an exact ratio is preferred over the rounded percentage', () {
      // 1438/12000 = 11.983%, but the server reports 11. Trusting 11 would
      // understate consumption by almost a full point.
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([
          limit(
            type: 'CREDIT_LIMIT',
            usage: 12000,
            currentValue: 1438,
            percentage: 11,
          ),
        ]),
        fetchedAt: fetchedAt,
      );

      final quota = snapshot.quotas.single;
      expect(quota.limit, 12000);
      expect(quota.remaining, 12000 - 1438);
      expect(quota.percent, greaterThan(11.9));
      expect(quota.percent, lessThan(12.0));
    });

    test('the percentage is the fallback when absolutes are missing', () {
      // Without both absolutes there is no ratio to compute, and 11 is the
      // best number available.
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body:
            '{"success":true,"code":0,"data":{"limits":['
            '{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":11}]}}',
        fetchedAt: fetchedAt,
      );

      final quota = snapshot.quotas.single;
      expect(quota.percent, 11);
      expect(quota.remaining, 89);
      expect(quota.limit, 100);
    });
  });

  group('a refusal in the body', () {
    // These two tests used to assert that `success: false` is always an auth
    // error. That was a bug, not a contract: z.ai's codes were never observed,
    // and the identical assumption in the MiniMax adapter turned out to revoke
    // working credentials on ordinary rate limits. A refusal whose code we
    // cannot name is reported as unclassified, which costs the user one
    // confusing status instead of their saved credential.
    test('is not assumed to be a bad key', () {
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: '{"success":false,"code":1002,"msg":"unauthorized","data":null}',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, isNot(ConnectionStatus.authError));
      expect(snapshot.quotas, isEmpty);
    });

    test('does not mark the credential as needing a re-login', () {
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: '{"success":false,"code":1002,"msg":"unauthorized"}',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.failureCause, isNull);
    });

    test('is still never reported as healthy', () {
      // The opposite mistake would be worse in a different way: a silent "ok"
      // would show a pristine quota for a key that is not working.
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: '{"success":false,"code":1002,"msg":"unauthorized"}',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, isNot(ConnectionStatus.ok));
    });
  });

  group('degenerate payloads', () {
    test('an exhausted limit reads as 100% used regardless of percentage', () {
      // The endpoint's own absolutes are more trustworthy than a percentage
      // that may be stale or rounded.
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([
          limit(usage: 600, currentValue: 600, remaining: 0, percentage: 20),
        ]),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.quotas.single.percent, 100);
      expect(snapshot.quotas.single.remaining, 0);
    });

    test('a limit with no usable number is skipped, not shown as zero', () {
      // Rendering 0% would read as "nothing used", which is the opposite of
      // "unknown".
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope(['{"type":"TIME_LIMIT","unit":3,"number":5}']),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.quotas, isEmpty);
    });

    test('an unknown window unit still yields a usable quota', () {
      // A future enum value must not cost the user their number.
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([
          limit(
            unit: 99,
            number: 1,
            usage: 10,
            currentValue: 5,
            percentage: 50,
          ),
        ]),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.quotas, isNotEmpty);
      expect(snapshot.quotas.single.remaining, 5);
    });

    test('an unknown limit type is ignored', () {
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([
          '{"type":"SOMETHING_NEW","unit":3,"number":5,"usage":10,'
              '"currentValue":9,"percentage":90}',
          limit(type: 'TIME_LIMIT', usage: 10, currentValue: 5, percentage: 50),
        ]),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.quotas, hasLength(1));
      expect(snapshot.quotas.single.id, 'requests:5h');
    });

    test('remaining and limit always share a scale', () {
      // The failure this guards: an absolute limit of 12000 credits beside a
      // percentage-derived remaining of 88 renders "88/12000", which no user
      // can interpret. A percent-only payload is the only case that uses 0-100.
      final absolute = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([
          limit(
            type: 'CREDIT_LIMIT',
            usage: 12000,
            currentValue: 1438,
            percentage: 11,
          ),
        ]),
        fetchedAt: fetchedAt,
      );
      expect(absolute.quotas.single.limit, 12000);
      expect(absolute.quotas.single.remaining, 10562);
      expect(
        absolute.quotas.single.remaining!,
        lessThanOrEqualTo(absolute.quotas.single.limit!),
      );

      final percentOnly = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body:
            '{"success":true,"data":{"limits":['
            '{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":11}]}}',
        fetchedAt: fetchedAt,
      );
      expect(percentOnly.quotas.single.limit, 100);
      expect(percentOnly.quotas.single.remaining, 89);
    });

    test('a key with no limits metered is healthy and empty', () {
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: envelope([]),
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, ConnectionStatus.ok);
      expect(snapshot.quotas, isEmpty);
      expect(snapshot.error, isNull);
    });
  });

  group('malformed input never throws and never invents a number', () {
    test('every shape degrades without an exception', () {
      for (final body in <String>[
        '',
        'not json',
        '[]',
        '{}',
        '{"success":true}',
        '{"success":true,"data":null}',
        '{"success":true,"data":{}}',
        '{"success":true,"data":{"limits":{}}}',
        '{"success":true,"data":{"limits":[null]}}',
        '{"success":true,"data":{"limits":[{}]}}',
        '{"success":true,"data":{"limits":[{"type":""}]}}',
        '{"success":"yes","data":{"limits":[]}}',
        'null',
      ]) {
        final snapshot = ZaiUsageResponse.parse(
          connectionId: 'z1',
          body: body,
          fetchedAt: fetchedAt,
        );
        expect(snapshot.connectionId, 'z1', reason: 'body was "$body"');
        expect(
          snapshot.quotas.where(
            (q) => q.percent == null && q.remaining == null,
          ),
          isEmpty,
          reason:
              'a quota with no numbers is worse than no quota, body "$body"',
        );
      }
    });

    test('a missing success flag is unknown, not success', () {
      // Assuming success is the failure mode that shows a pristine quota for a
      // key that does not work.
      final snapshot = ZaiUsageResponse.parse(
        connectionId: 'z1',
        body: '{"data":{"limits":[]}}',
        fetchedAt: fetchedAt,
      );

      expect(snapshot.status, isNot(ConnectionStatus.ok));
    });
  });

  test('an unparseable reset time drops the countdown, not the quota', () {
    final snapshot = ZaiUsageResponse.parse(
      connectionId: 'z1',
      body: envelope([
        limit(usage: 600, currentValue: 120, percentage: 20, nextResetTime: -1),
      ]),
      fetchedAt: fetchedAt,
    );

    expect(snapshot.quotas, hasLength(1));
    expect(snapshot.quotas.single.resetAt, isNull);
  });
}
