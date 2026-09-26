import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/components/quota_row.dart';
import 'package:tokendock/ui/widget/countdown_text.dart';
import 'package:tokendock/ui/widget/relative_age_text.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// The number that answers "which account still has quota" must be the most
/// prominent thing on the row (audit C-20, C-19), and the widget must not burn
/// a per-second timer per quota to keep it current (audit C-21).
void main() {
  final colors = TokenDockTheme.light;

  const quota = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 50,
    remaining: 50,
    limit: 100,
    unit: 'USD',
    resetAt: null,
  );

  AccountItem account(Quota q) => AccountItem(
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
          quotas: [q],
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: null,
        ),
      );

  group('the primary quota leads the row (C-20)', () {
    testWidgets('the quota value uses ink, not mutedInk', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(body: QuotaRow(quota: quota)),
        ),
      );

      final value = tester.widget<Text>(find.text('50/100 USD'));
      expect(
        value.style?.color,
        colors.ink,
        reason: 'the number that decides where the user can work next must '
            'not be de-emphasised',
      );
    });

    testWidgets('compact density also gives the quota full-contrast ink', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: SizedBox(
            width: 300,
            height: 600,
            child: TokenDockWidget.loaded(accounts: [account(quota)]),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final value = tester.widget<Text>(find.text('50/100 USD'));
      expect(value.style?.color, colors.ink);
    });

    test('quota figures outrank caption metadata in size (C-19)', () {
      final quotaSize = TokenDockTypography.quotaStyle().fontSize ?? 0;
      final captionSize = TokenDockTypography.captionStyle().fontSize ?? 0;
      expect(
        quotaSize,
        greaterThan(captionSize),
        reason: 'the primary figure must outrank the metadata beside it',
      );
    });

    test('the quota style carries tabular figures so values do not jitter', () {
      expect(
        TokenDockTypography.quotaStyle().fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });
  });

  group('idle cost stays bounded (C-21)', () {
    test('the countdown does not tick every second by default', () {
      // The countdown only renders hours and minutes, so a one-second tick
      // spends rebuilds for no visible change, and one per quota multiplies by
      // account count.
      const subject = CountdownText(resetAt: null);
      expect(
        subject.tickInterval,
        greaterThanOrEqualTo(const Duration(seconds: 15)),
        reason: 'a per-second tick per countdown multiplies by account count',
      );
    });

    test('the relative age label ticks on a coarse interval too', () {
      final subject = RelativeAgeText(
        since: DateTime.utc(2026, 1, 1),
      );
      expect(
        subject.tickInterval,
        greaterThanOrEqualTo(const Duration(seconds: 15)),
      );
    });
  });
}
