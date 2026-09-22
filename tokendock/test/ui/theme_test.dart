import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/ui/components/quota_bar.dart';

void main() {
  test('high-contrast ramp is fully opaque', () {
    for (final color in TokenDockTheme.highContrast.values) {
      expect(color.opacity, 1.0, reason: 'high-contrast $color must be opaque');
    }
  });

  test('high-contrast text stays usable on the canvas', () {
    final colors = TokenDockTheme.highContrast;
    expect(colors.ink, isNot(colors.canvas));
    expect(colors.mutedInk, isNot(colors.canvas));
  });

  test('quota typography uses tabular figures', () {
    final style = TokenDockTypography.quotaStyle();
    expect(style.fontFamily, TokenDockTypography.fontFamily);
    expect(
      style.fontFeatures,
      contains(const FontFeature.tabularFigures()),
    );
  });

  testWidgets('quota bar fill uses semantic normal blue in light theme',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: const Scaffold(
          body: QuotaBar(percent: 50),
        ),
      ),
    );

    final fillBox = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    final fill = fillBox.child! as Container;
    expect(
      fill.color,
      TokenDockTheme.light.statusNormal,
      reason: 'determinate quota fill must use status blue, not lime',
    );
  });
}
