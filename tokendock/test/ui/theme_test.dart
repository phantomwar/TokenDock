import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/ui/components/quota_bar.dart';

double _linearize(double channel) {
  final c = channel / 255.0;
  return c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) {
  return 0.2126 * _linearize(color.r * 255.0) +
      0.7152 * _linearize(color.g * 255.0) +
      0.0722 * _linearize(color.b * 255.0);
}

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  final light = math.max(l1, l2);
  final dark = math.min(l1, l2);
  return (light + 0.05) / (dark + 0.05);
}

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

  testWidgets('quota bar fill meets non-text contrast in dark theme',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.darkTheme(),
        home: const Scaffold(
          body: QuotaBar(percent: 50),
        ),
      ),
    );

    final fillBox = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    final fillColor = (fillBox.child! as Container).color!;
    final trackColor = tester
        .widgetList<Container>(find.byType(Container))
        .firstWhere((container) => container.child is FractionallySizedBox)
        .color!;
    expect(
      _contrast(fillColor, trackColor),
      greaterThanOrEqualTo(3.0),
      reason: 'dark quota fill/track contrast must meet >=3:1',
    );
  });
}
