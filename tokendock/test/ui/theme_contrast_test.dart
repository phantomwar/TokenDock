import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';

/// WCAG 2.2 AA contrast, measured across every ramp the app ships.
///
/// Audit C-06: the dark ramp reused the light ramp's status colours verbatim
/// while only `quotaFill` was adapted. The previous suite had exactly one
/// contrast assertion in the whole repository — a non-text 3:1 pair in one
/// theme — so nothing caught it. `PRODUCT.md` and the design spec both commit
/// to AA for text and essential controls in light, dark and high contrast.
double _linearize(double channel) {
  final c = channel / 255.0;
  return c <= 0.04045
      ? c / 12.92
      : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
}

double _luminance(Color color) =>
    0.2126 * _linearize(color.r * 255.0) +
    0.7152 * _linearize(color.g * 255.0) +
    0.0722 * _linearize(color.b * 255.0);

double _contrast(Color a, Color b) {
  final l1 = _luminance(a);
  final l2 = _luminance(b);
  return (math.max(l1, l2) + 0.05) / (math.min(l1, l2) + 0.05);
}

const double textAA = 4.5;
const double nonTextAA = 3.0;

void main() {
  final ramps = <String, TokenDockColors>{
    'light': TokenDockTheme.light,
    'dark': TokenDockTheme.dark,
    'highContrast': TokenDockTheme.highContrast,
  };

  group('WCAG AA text contrast', () {
    // Every pair below is a colour that actually renders text in the app.
    final textPairs = <String, List<(String, Color, Color)>>{
      'light': [
        (
          'ink on canvas',
          TokenDockTheme.light.ink,
          TokenDockTheme.light.canvas,
        ),
        (
          'ink on surface',
          TokenDockTheme.light.ink,
          TokenDockTheme.light.surface,
        ),
        (
          'ink on mutedSurface',
          TokenDockTheme.light.ink,
          TokenDockTheme.light.mutedSurface,
        ),
        (
          'mutedInk on canvas',
          TokenDockTheme.light.mutedInk,
          TokenDockTheme.light.canvas,
        ),
        (
          'mutedInk on surface',
          TokenDockTheme.light.mutedInk,
          TokenDockTheme.light.surface,
        ),
        (
          'mutedInk on mutedSurface',
          TokenDockTheme.light.mutedInk,
          TokenDockTheme.light.mutedSurface,
        ),
        (
          'statusOk on surface',
          TokenDockTheme.light.statusOk,
          TokenDockTheme.light.surface,
        ),
        (
          'statusWarning on surface',
          TokenDockTheme.light.statusWarning,
          TokenDockTheme.light.surface,
        ),
        (
          'statusLimited on surface',
          TokenDockTheme.light.statusLimited,
          TokenDockTheme.light.surface,
        ),
        (
          'statusNormal on surface',
          TokenDockTheme.light.statusNormal,
          TokenDockTheme.light.surface,
        ),
        (
          'statusUpdating on surface',
          TokenDockTheme.light.statusUpdating,
          TokenDockTheme.light.surface,
        ),
        (
          'limeInk on lime',
          TokenDockTheme.light.limeInk,
          TokenDockTheme.light.lime,
        ),
      ],
      'dark': [
        ('ink on canvas', TokenDockTheme.dark.ink, TokenDockTheme.dark.canvas),
        (
          'ink on surface',
          TokenDockTheme.dark.ink,
          TokenDockTheme.dark.surface,
        ),
        (
          'ink on mutedSurface',
          TokenDockTheme.dark.ink,
          TokenDockTheme.dark.mutedSurface,
        ),
        (
          'mutedInk on canvas',
          TokenDockTheme.dark.mutedInk,
          TokenDockTheme.dark.canvas,
        ),
        (
          'mutedInk on surface',
          TokenDockTheme.dark.mutedInk,
          TokenDockTheme.dark.surface,
        ),
        (
          'mutedInk on mutedSurface',
          TokenDockTheme.dark.mutedInk,
          TokenDockTheme.dark.mutedSurface,
        ),
        (
          'statusOk on surface',
          TokenDockTheme.dark.statusOk,
          TokenDockTheme.dark.surface,
        ),
        (
          'statusWarning on surface',
          TokenDockTheme.dark.statusWarning,
          TokenDockTheme.dark.surface,
        ),
        (
          'statusLimited on surface',
          TokenDockTheme.dark.statusLimited,
          TokenDockTheme.dark.surface,
        ),
        (
          'statusNormal on surface',
          TokenDockTheme.dark.statusNormal,
          TokenDockTheme.dark.surface,
        ),
        (
          'statusUpdating on surface',
          TokenDockTheme.dark.statusUpdating,
          TokenDockTheme.dark.surface,
        ),
        (
          'limeInk on lime',
          TokenDockTheme.dark.limeInk,
          TokenDockTheme.dark.lime,
        ),
      ],
      'highContrast': [
        (
          'ink on canvas',
          TokenDockTheme.highContrast.ink,
          TokenDockTheme.highContrast.canvas,
        ),
        (
          'ink on surface',
          TokenDockTheme.highContrast.ink,
          TokenDockTheme.highContrast.surface,
        ),
        (
          'ink on mutedSurface',
          TokenDockTheme.highContrast.ink,
          TokenDockTheme.highContrast.mutedSurface,
        ),
        (
          'mutedInk on canvas',
          TokenDockTheme.highContrast.mutedInk,
          TokenDockTheme.highContrast.canvas,
        ),
        (
          'mutedInk on mutedSurface',
          TokenDockTheme.highContrast.mutedInk,
          TokenDockTheme.highContrast.mutedSurface,
        ),
        (
          'statusOk on surface',
          TokenDockTheme.highContrast.statusOk,
          TokenDockTheme.highContrast.surface,
        ),
        (
          'statusWarning on surface',
          TokenDockTheme.highContrast.statusWarning,
          TokenDockTheme.highContrast.surface,
        ),
        (
          'statusLimited on surface',
          TokenDockTheme.highContrast.statusLimited,
          TokenDockTheme.highContrast.surface,
        ),
        (
          'statusNormal on surface',
          TokenDockTheme.highContrast.statusNormal,
          TokenDockTheme.highContrast.surface,
        ),
        (
          'statusUpdating on surface',
          TokenDockTheme.highContrast.statusUpdating,
          TokenDockTheme.highContrast.surface,
        ),
        (
          'limeInk on lime',
          TokenDockTheme.highContrast.limeInk,
          TokenDockTheme.highContrast.lime,
        ),
      ],
    };

    textPairs.forEach((rampName, pairs) {
      for (final (label, foreground, background) in pairs) {
        test('$rampName: $label meets 4.5:1', () {
          final ratio = _contrast(foreground, background);
          expect(
            ratio,
            greaterThanOrEqualTo(textAA),
            reason:
                '$rampName $label is ${ratio.toStringAsFixed(2)}:1, '
                'below the WCAG 2.2 AA threshold of $textAA:1 for body text',
          );
        });
      }
    });
  });

  group('WCAG AA non-text contrast', () {
    test('light quota fill against its track meets 3:1', () {
      expect(
        _contrast(
          TokenDockTheme.light.quotaFill,
          TokenDockTheme.light.mutedSurface,
        ),
        greaterThanOrEqualTo(nonTextAA),
      );
    });

    test('dark quota fill against its track meets 3:1', () {
      expect(
        _contrast(
          TokenDockTheme.dark.quotaFill,
          TokenDockTheme.dark.mutedSurface,
        ),
        greaterThanOrEqualTo(nonTextAA),
      );
    });

    test('high contrast quota fill against its track meets 3:1', () {
      expect(
        _contrast(
          TokenDockTheme.highContrast.quotaFill,
          TokenDockTheme.highContrast.mutedSurface,
        ),
        greaterThanOrEqualTo(nonTextAA),
      );
    });

    test('the structural hairline is perceivable in high contrast', () {
      // Light and dark use a deliberately quiet 1px separator (about 1.2:1 and
      // 1.6:1). WCAG 1.4.11 exempts purely decorative elements, and forcing a
      // divider to 3:1 on a near-white canvas would read as a heavy border, so
      // the soft value is intentional. In high contrast the same token is the
      // card boundary and carries structural meaning, so it must be visible.
      expect(
        _contrast(
          TokenDockTheme.highContrast.hairline,
          TokenDockTheme.highContrast.canvas,
        ),
        greaterThanOrEqualTo(nonTextAA),
      );
    });
  });

  group('ramp independence', () {
    test('the dark ramp does not reuse the light status colours verbatim', () {
      // Only quotaFill was adapted before; the status colours were copied, so
      // the dark "Connected"/"Degraded"/"Limited" labels sat near 3:1 on the
      // dark surface.
      expect(
        TokenDockTheme.dark.statusOk,
        isNot(TokenDockTheme.light.statusOk),
      );
      expect(
        TokenDockTheme.dark.statusWarning,
        isNot(TokenDockTheme.light.statusWarning),
      );
      expect(
        TokenDockTheme.dark.statusLimited,
        isNot(TokenDockTheme.light.statusLimited),
      );
      expect(
        TokenDockTheme.dark.statusNormal,
        isNot(TokenDockTheme.light.statusNormal),
      );
    });

    test('status accents keep their semantic hue across ramps', () {
      // Brightening for contrast must not turn green into blue: the label
      // text, not just the colour, carries meaning, but hue is a cue.
      bool isGreen(Color c) => c.g > c.r && c.g > c.b;
      bool isAmber(Color c) => c.r > c.b && c.g > c.b * 0.5 && c.g < c.r;
      bool isRed(Color c) => c.r > c.g && c.r > c.b;
      bool isBlue(Color c) => c.b >= c.g && c.b > c.r;

      ramps.forEach((name, colors) {
        expect(isGreen(colors.statusOk), isTrue, reason: '$name statusOk hue');
        expect(
          isAmber(colors.statusWarning),
          isTrue,
          reason: '$name statusWarning hue',
        );
        expect(
          isRed(colors.statusLimited),
          isTrue,
          reason: '$name statusLimited hue',
        );
        expect(
          isBlue(colors.statusNormal),
          isTrue,
          reason: '$name statusNormal hue',
        );
      });
    });

    test('every ramp is fully opaque', () {
      ramps.forEach((name, colors) {
        for (final color in colors.values) {
          expect(color.a, 1.0, reason: '$name $color must be opaque');
        }
      });
    });
  });
}
