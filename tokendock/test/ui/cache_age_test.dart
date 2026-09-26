import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/widget/relative_age_text.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// `Last updated <relative age>` must keep counting.
///
/// Audit C-08: `formatRelativeAge` is a pure static function called during
/// `build` with no timer driving it, so the label froze at whatever
/// `DateTime.now()` was on the first frame. With a manual refresh interval, or
/// a provider that keeps failing, the widget showed "just now" indefinitely.
/// The prior tests only asserted the substring "Last updated", so any suffix
/// would have passed.
///
/// Note on what is verifiable here: `tester.pump(duration)` advances the fake
/// timer clock but not `DateTime.now()`, which `flutter_test` does not fake. The
/// age therefore cannot be moved forward by pumping. What is provable, and what
/// the fix depends on, is that a timer re-reads the clock on a tick: the tests
/// below inject a clock and move it, which is the same code path production
/// takes through `DateTime.now()`.
void main() {
  final epoch = DateTime.utc(2026, 1, 1);

  AccountItem accountFetchedAt(DateTime fetchedAt) => AccountItem(
    connection: const Connection(
      id: 'c1',
      provider: 'openrouter',
      displayName: 'Main Key',
      group: null,
      plan: 'Pro',
      credentialRef: 'ref',
      enabled: true,
    ),
    snapshot: ProviderSnapshot(
      connectionId: 'c1',
      status: ConnectionStatus.ok,
      quotas: const [
        Quota(
          id: 'key-limit',
          label: 'Key limit',
          percent: 50,
          remaining: 50,
          limit: 100,
          unit: 'USD',
          resetAt: null,
        ),
      ],
      balance: null,
      fetchedAt: fetchedAt,
      error: null,
    ),
  );

  Future<void> pumpDensity(
    WidgetTester tester,
    double width, {
    required DateTime fetchedAt,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 700,
            child: TokenDockWidget(
              state: AppState(accounts: [accountFetchedAt(fetchedAt)]),
            ),
          ),
        ),
      ),
    );
  }

  group('relative age formatting', () {
    test('covers every branch', () {
      final base = DateTime.utc(2026, 5, 4, 12);
      String age(DateTime at) => RelativeAgeText.format(at, now: base);

      expect(age(base), 'just now');
      expect(age(base.subtract(const Duration(seconds: 59))), 'just now');
      expect(age(base.subtract(const Duration(minutes: 5))), '5m ago');
      expect(age(base.subtract(const Duration(hours: 3))), '3h ago');
      expect(age(base.subtract(const Duration(days: 2))), '2d ago');
    });

    test('the minute boundary flips from just now to 1m ago', () {
      final base = DateTime.utc(2026, 5, 4, 12);
      expect(
        RelativeAgeText.format(
          base.subtract(const Duration(seconds: 60)),
          now: base,
        ),
        '1m ago',
      );
    });

    test('a timestamp in the future from clock skew reads as just now', () {
      final base = DateTime.utc(2026, 5, 4, 12);
      expect(
        RelativeAgeText.format(
          base.add(const Duration(minutes: 10)),
          now: base,
        ),
        'just now',
      );
    });

    test('TokenDockWidget keeps its formatRelativeAge entry point', () {
      final base = DateTime.utc(2026, 5, 4, 12);
      expect(
        TokenDockWidget.formatRelativeAge(
          base.subtract(const Duration(hours: 2)),
          now: base,
        ),
        '2h ago',
      );
    });
  });

  group('the label re-reads the clock on a tick', () {
    testWidgets('advances as the injected clock moves, without a rebuild '
        'trigger', (tester) async {
      var clock = DateTime.utc(2026, 5, 4, 12);
      final since = DateTime.utc(2026, 5, 4, 10);

      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(
            body: RelativeAgeText(since: since, now: () => clock),
          ),
        ),
      );
      expect(find.text('Last updated 2h ago'), findsOneWidget);

      // Move the clock without touching the widget tree: only a timer can
      // notice.
      clock = DateTime.utc(2026, 5, 4, 13);
      expect(find.text('Last updated 2h ago'), findsOneWidget);

      await tester.pump(const Duration(seconds: 30));

      expect(
        find.text('Last updated 3h ago'),
        findsOneWidget,
        reason: 'the tick must re-read the clock',
      );
    });

    testWidgets('a new since value restarts the timer and re-renders', (
      tester,
    ) async {
      final base = DateTime.utc(2026, 5, 4, 12);
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(
            body: RelativeAgeText(
              since: DateTime.utc(2026, 5, 4, 10),
              now: () => base,
            ),
          ),
        ),
      );
      expect(find.text('Last updated 2h ago'), findsOneWidget);

      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(
            body: RelativeAgeText(
              since: DateTime.utc(2026, 5, 4, 11),
              now: () => base,
            ),
          ),
        ),
      );

      expect(find.text('Last updated 1h ago'), findsOneWidget);
    });

    testWidgets('the timer is cancelled on dispose', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(body: RelativeAgeText(since: epoch)),
        ),
      );
      // A leaked periodic timer surfaces here as an active timer after the
      // widget tree is gone.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(minutes: 5));
      expect(tester.takeException(), isNull);
    });
  });

  group('every density renders a live age label', () {
    for (final (label, width) in const [
      ('compact', 300.0),
      ('normal', 400.0),
      ('expanded', 600.0),
    ]) {
      testWidgets('$label density shows the cache age', (tester) async {
        final fetchedAt = DateTime.now().toUtc().subtract(
          const Duration(hours: 2),
        );
        await pumpDensity(tester, width, fetchedAt: fetchedAt);

        expect(
          find.text('Last updated 2h ago'),
          findsOneWidget,
          reason: '$label must show the real cache age, not just a label',
        );
      });
    }
  });
}
