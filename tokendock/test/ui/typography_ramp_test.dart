import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// Audit C-19: the shipped type ramp did not match the design spec.
///
/// The first-goal spec fixes the ramp: "11px metadata, 13px body, 15px
/// account/provider label, 18px section heading, and 22px widget heading; quota
/// percentages use 20px semibold tabular figures so values do not reflow."
///
/// What shipped was 13px w500 quota figures, 13px w600 titles, 14px body and
/// 12px caption, with no 18px or 22px step at all. Two roles had no token, so
/// they were expressed as `copyWith` overrides at the call site -- which is how
/// a ramp drifts: the numbers were never anywhere a test could see them.
void main() {
  group('type ramp matches the spec', () {
    test('metadata is 11px', () {
      expect(TokenDockTypography.metadataStyle().fontSize, 11);
    });

    test('body is 13px', () {
      expect(TokenDockTypography.bodyStyle().fontSize, 13);
    });

    test('the account/provider label is 15px', () {
      expect(TokenDockTypography.titleStyle().fontSize, 15);
    });

    test('the section heading step exists at 18px', () {
      expect(TokenDockTypography.sectionHeadingStyle().fontSize, 18);
    });

    test('the widget heading step exists at 22px', () {
      expect(TokenDockTypography.widgetHeadingStyle().fontSize, 22);
    });

    test('quota figures are 20px semibold', () {
      final style = TokenDockTypography.quotaStyle();
      expect(style.fontSize, 20);
      expect(style.fontWeight, FontWeight.w600);
    });
  });

  group('every changing number is tabular', () {
    // The spec: "Use FontFeature.tabularFigures() for every changing number,
    // not a monospaced display face." Quota figures and the countdown both
    // change in place, so both must be tabular or the layout jitters.
    bool isTabular(TextStyle style) =>
        style.fontFeatures?.contains(const FontFeature.tabularFigures()) ??
        false;

    test('quota figures are tabular', () {
      expect(isTabular(TokenDockTypography.quotaStyle()), isTrue);
    });

    test('the countdown is tabular', () {
      expect(isTabular(TokenDockTypography.countdownStyle()), isTrue);
    });
  });

  test('the countdown is not as loud as the figure it annotates', () {
    // A secondary "resets in 2h 15m" line rendered at the same size and weight
    // as the number it explains competes with it. It is metadata about a
    // figure, so it sits on the metadata/body step, not the figure step.
    expect(
      TokenDockTypography.countdownStyle().fontSize!,
      lessThan(TokenDockTypography.quotaStyle().fontSize!),
    );
  });

  // The shipped window is 360x600, which after the shell's padding and border
  // leaves ~326px of content and therefore compact density -- the densest of
  // the three, and the one that renders the primary quota figure. No other test
  // pumps that narrow, so nothing else would catch a Row or Expanded overflow
  // there.
  //
  // Scope of this guard, stated honestly: it asserts that no layout exception is
  // raised at the real window with realistic long names and large figures. It
  // does *not* police the figure size. Raising the quota step to 40px still
  // passes, because the figure is a wrapping Text rather than a fixed-width
  // row, so the size question is settled by the ramp assertions above and by
  // the design pass, not by this test.
  testWidgets('the real 360x600 window lays out without overflow', (
    tester,
  ) async {
    Quota quota(String id, double remaining, double limit, String unit) =>
        Quota(
          id: id,
          label: 'Key limit',
          percent: (remaining / limit * 100).roundToDouble(),
          remaining: remaining,
          limit: limit,
          unit: unit,
          resetAt: DateTime.now().toUtc().add(const Duration(hours: 3)),
        );

    final accounts = [
      for (var i = 0; i < 4; i++)
        AccountItem(
          connection: Connection(
            id: 'c$i',
            provider: 'openrouter',
            displayName: 'Account number $i with a long name',
            group: null,
            plan: 'Pro',
            credentialRef: 'ref-$i',
            enabled: true,
          ),
          snapshot: ProviderSnapshot(
            connectionId: 'c$i',
            status: ConnectionStatus.ok,
            quotas: [
              quota('requests', 12345.5, 100000, 'requests'),
              quota('spend', 987.25, 1000, 'USD'),
            ],
            balance: null,
            fetchedAt: DateTime.now().toUtc(),
            error: i.isEven ? 'Provider rate-limited this account' : null,
          ),
        ),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: SizedBox(
            width: 360,
            height: 600,
            child: TokenDockWidget(state: AppState(accounts: accounts)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // The figure is on screen, not silently dropped by the narrower density.
    expect(find.textContaining('/'), findsWidgets);
  });
}
