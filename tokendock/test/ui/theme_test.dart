import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';

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
}
