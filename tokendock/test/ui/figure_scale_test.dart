import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/components/provider_icon.dart';
import 'package:tokendock/ui/components/quota_row.dart';

/// Two sizes were shouting.
///
/// The percentage figure rendered at 20px in a 360px window, which made it the
/// loudest thing in the widget and pushed the quota label -- the thing that tells
/// you *which* window this is -- below it. The provider monogram was a 32px
/// disc competing with the account name for the same 32px of height.
///
/// Both are reductions in the wrong direction for a glanceable widget, and both
/// had a floor to respect: audit C-19 requires the quota figure to outrank
/// metadata, and C-20 requires it to stay in full-contrast ink rather than the
/// muted tone. Neither is touched.
void main() {
  group('the percentage figure is quieter', () {
    test('smaller than it was, and still outranks the metadata beside it', () {
      final figure = TokenDockTypography.quotaStyle().fontSize ?? 0;
      final metadata = TokenDockTypography.metadataStyle().fontSize ?? 0;
      final body = TokenDockTypography.bodyStyle().fontSize ?? 0;

      expect(
        figure,
        lessThan(20),
        reason: '20px overran a 360px window and dominated the row',
      );
      expect(
        figure,
        greaterThan(metadata),
        reason: 'audit C-19: the figure must outrank the metadata beside it',
      );
      expect(
        figure,
        greaterThan(body),
        reason:
            'it is still the authoritative value on the row, and C-20 gives it '
            'the emphasis; it just no longer shouts over the window label',
      );
    });

    testWidgets('and is no larger than the token it shares with the header', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: const Scaffold(
            body: QuotaRow(
              quota: Quota(
                id: 'w',
                label: 'Weekly limit',
                percent: 42,
                remaining: 58,
                limit: 100,
                unit: '%',
                resetAt: null,
              ),
            ),
          ),
        ),
      );

      final figure = tester.widget<Text>(find.text('42% used'));
      expect(figure.style?.fontSize, TokenDockTypography.quotaStyle().fontSize);
    });
  });

  group('the provider monogram is smaller', () {
    testWidgets('and no longer competes with the account name', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: const Scaffold(body: ProviderIcon(provider: 'openrouter')),
        ),
      );

      final size = tester.getSize(find.byType(ProviderIcon));
      expect(
        size.width,
        lessThan(32),
        reason: 'a 32px disc is as tall as the account name it precedes',
      );
      expect(size.width, size.height, reason: 'the monogram must stay a disc');
      expect(size.width, greaterThanOrEqualTo(24), reason: 'and stay legible');
    });

    testWidgets('the monogram still fits inside the disc', (tester) async {
      // A 15px glyph in a smaller disc would clip. This is what catches a naive
      // size reduction that shrinks the box and forgets the text.
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: const Scaffold(body: ProviderIcon(provider: 'z')),
        ),
      );

      expect(tester.takeException(), isNull);
      final glyph = tester.widget<Text>(find.text('Z'));
      final box = tester.getSize(find.byType(ProviderIcon));
      expect(
        (glyph.style?.fontSize ?? 0),
        lessThanOrEqualTo(box.width),
        reason: 'the glyph must fit within the disc it sits in',
      );
    });
  });

  group('the contrast guarantees are untouched', () {
    // Both reductions are typographic. C-20 exists because the authoritative
    // value was once rendered in muted ink, and nothing about a smaller size
    // permits moving it back.
    testWidgets('the figure stays in full-contrast ink', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: const Scaffold(
            body: QuotaRow(
              quota: Quota(
                id: 'w',
                label: 'Weekly limit',
                percent: 42,
                remaining: 58,
                limit: 100,
                unit: '%',
                resetAt: null,
              ),
            ),
          ),
        ),
      );

      final colors = TokenDockTheme.colorsOf(
        tester.element(find.text('42% used')),
      );
      expect(
        tester.widget<Text>(find.text('42% used')).style?.color,
        colors.ink,
        reason: 'audit C-20: the authoritative value is never muted',
      );
      expect(
        tester.widget<Text>(find.text('42% used')).style?.color,
        isNot(colors.mutedInk),
      );
    });
  });
}
