import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/components/quota_bar.dart';
import 'package:tokendock/ui/components/quota_row.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// The default density was showing one number per account and calling it a
/// quota display.
///
/// Three defects, all of which this suite pins. The screenshots that prompted
/// them showed an app with three accounts, each reading `100/100 %` under a
/// repeated green `Connected` — which is exactly the shape a one-line-per-
/// account layout produces.
///
/// 1. **Quotas were discarded.** The window is 360px, which is the *normal*
///    density, and `_buildNormal` rendered `quotas.first`. OpenCode Go reports
///    three windows, MiniMax two, z.ai three; every one but the first was
///    dropped. The product question is "which of my subscriptions still has
///    limit?", and the binding window is frequently *not* the first.
/// 2. **A percentage rendered as `remaining/limit`.** A percent quota has
///    `limit == 100`, so it always read `100/100 %` — redundant, and ambiguous
///    enough to be read as "100% used", the opposite of its meaning.
/// 3. **An absent cap was the headline.** A key with no ceiling rendered
///    `No key cap` in the largest type on the card, promoting an absence over
///    every real figure in the app.
///
/// The contrast, density-parity, cache-age and accessibility work is unchanged
/// and deliberately not touched here.
/// The style `QuotaRow` uses for its authoritative value, so a test can assert
/// that a given string is *not* being presented as one.
TextStyle? quotaTextStyle(Color ink) =>
    TokenDockTypography.quotaStyle(color: ink);

void main() {
  final reset = DateTime.utc(2026, 9, 26, 17);

  /// A percent window, as every modern provider reports: 0-100 used, 100 total.
  Quota percent({
    required String id,
    required String label,
    required double used,
    DateTime? resetAt,
  }) => Quota(
    id: id,
    label: label,
    percent: used,
    remaining: 100 - used,
    limit: 100,
    unit: '%',
    resetAt: resetAt ?? reset,
  );

  AccountItem account({
    String name = 'OpenCode Go',
    String provider = 'opencode-go',
    ConnectionStatus status = ConnectionStatus.ok,
    List<Quota> quotas = const <Quota>[],
  }) => AccountItem(
    connection: Connection(
      id: 'c1',
      provider: provider,
      displayName: name,
      group: null,
      plan: null,
      credentialRef: 'ref',
      enabled: true,
    ),
    snapshot: ProviderSnapshot(
      connectionId: 'c1',
      status: status,
      quotas: quotas,
      balance: null,
      fetchedAt: DateTime.utc(2026, 9, 26, 12),
      error: null,
    ),
  );

  Future<void> pump(WidgetTester tester, List<AccountItem> items) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: SizedBox(
            // The real window width, so the default density is what renders.
            width: 360,
            height: 700,
            child: TokenDockWidget(state: AppState(accounts: items)),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  group('the default density shows every window', () {
    testWidgets('not just the first', (tester) async {
      await pump(tester, [
        account(
          quotas: [
            percent(id: '5h', label: '5 Hour limit', used: 20),
            percent(id: '7d', label: '7 Day limit', used: 55),
            percent(id: 'monthly', label: 'Monthly limit', used: 88),
          ],
        ),
      ]);

      // The three windows OpenCode Go actually reports. Rendering only the
      // first hid the two that were nearly exhausted.
      expect(find.text('5 Hour limit'), findsOneWidget);
      expect(find.text('7 Day limit'), findsOneWidget);
      expect(find.text('Monthly limit'), findsOneWidget);
    });

    testWidgets('and the most-exhausted window is not buried below the rest', (
      tester,
    ) async {
      // Order is what makes the layout useful: the answer to "what is about to
      // run out" has to be findable without reading three rows.
      await pump(tester, [
        account(
          quotas: [
            percent(id: '5h', label: '5 Hour limit', used: 20),
            percent(id: '7d', label: '7 Day limit', used: 55),
            percent(id: 'monthly', label: 'Monthly limit', used: 88),
          ],
        ),
      ]);

      final labels = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => s.endsWith('limit'))
          .toList();

      expect(labels, <String>[
        'Monthly limit',
        '7 Day limit',
        '5 Hour limit',
      ], reason: 'most-exhausted first, so the binding window leads');
    });

    testWidgets('a single-window provider is unaffected', (tester) async {
      await pump(tester, [
        account(
          quotas: [percent(id: 'w', label: 'Weekly limit', used: 10)],
        ),
      ]);

      expect(find.text('Weekly limit'), findsOneWidget);
    });
  });

  group('the default window is not the compact density', () {
    // The root cause of everything above, and the reason a screenshot of the
    // real app looked nothing like the reference.
    //
    // `WidgetShell` applies 16px of padding on each side, and the density
    // `LayoutBuilder` sat *inside* it. So a 360px window — the size the app
    // actually ships at — measured 360 - 32 = 328px, which is under the 330
    // compact threshold. The default window was therefore rendering the
    // least informative layout, permanently, and the breakpoints were being
    // compared against the content width when they were specified against the
    // window width.
    testWidgets('a 360px window shows quota windows, not one line per account', (
      tester,
    ) async {
      await pump(tester, [
        account(
          quotas: [
            percent(id: '5h', label: '5 Hour limit', used: 20),
            percent(id: '7d', label: '7 Day limit', used: 55),
          ],
        ),
      ]);

      // Compact renders a single `CompactAccountRow` and no `QuotaRow` at all,
      // so the presence of a window label is the discriminator.
      expect(find.byType(QuotaRow), findsWidgets);
      expect(find.text('5 Hour limit'), findsOneWidget);
      expect(find.text('7 Day limit'), findsOneWidget);
    });

    testWidgets('the density follows the window, not the padded content', (
      tester,
    ) async {
      // 330 is the documented compact/normal boundary, measured on the window.
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 330,
              height: 700,
              child: TokenDockWidget(
                state: AppState(
                  accounts: [
                    account(
                      quotas: [
                        percent(id: 'w', label: 'Weekly limit', used: 5),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      // 330 minus 32 of padding is 298, which would have selected compact under
      // the old measurement. At 330 the spec says normal.
      expect(find.text('Weekly limit'), findsOneWidget);
    });
  });

  group('a long value cannot overflow the row', () {
    // A latent overflow the density fix exposed. At 360px the window used to
    // fall into the compact density, which does not use `QuotaRow` at all, so
    // the row was never reachable at the size the app actually ships at. Its
    // value `Text` was unconstrained, so any value wider than the row drew a
    // 140px overflow stripe.
    testWidgets('a wide absolute meter stays inside its row', (tester) async {
      await pump(tester, [
        account(
          provider: 'openrouter',
          name: 'Main Key',
          quotas: const [
            Quota(
              id: 'requests',
              label: 'Key limit',
              percent: 12,
              remaining: 12345.5,
              limit: 100000,
              unit: 'requests',
              resetAt: null,
            ),
          ],
        ),
      ]);

      // The authoritative value must remain readable in full: truncating it
      // would be a regression of C-20, which is why the fix is to let it wrap
      // rather than to ellipsize it away.
      expect(find.text('12345.5/100000 requests'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long label also stays inside its row', (tester) async {
      await pump(tester, [
        account(
          quotas: const [
            Quota(
              id: 'very-long-window-identifier',
              label: 'Claude and GPT OSS combined session window',
              percent: 42,
              remaining: 58,
              limit: 100,
              unit: '%',
              resetAt: null,
            ),
          ],
        ),
      ]);

      expect(tester.takeException(), isNull);
    });
  });

  group('a percentage reads as a percentage', () {
    test('as used, not as a remaining/limit pair', () {
      final value = QuotaRow.valueTextOf(
        percent(id: '5h', label: '5 Hour limit', used: 88),
      );

      expect(value, '88% used');
      expect(
        value,
        isNot(contains('/')),
        reason:
            'a percent quota has limit 100, so "88/100 %" carried no '
            'information and read as "88% left" at best',
      );
    });

    test('and never claims a full quota is fully used', () {
      // The exact confusion this fixes: 100 remaining of 100 displayed as
      // "100/100 %" reads as "100% used", which is the opposite of the truth.
      final value = QuotaRow.valueTextOf(
        percent(id: '5h', label: '5 Hour limit', used: 0),
      );
      expect(value, '0% used');
    });

    test('an absolute meter keeps its remaining/limit pair', () {
      // OpenRouter reports credits, not a percentage, and the pair is
      // informative there.
      final value = QuotaRow.valueTextOf(
        const Quota(
          id: 'credits',
          label: 'Credits',
          percent: 50,
          remaining: 5.25,
          limit: 10.5,
          unit: 'USD',
          resetAt: null,
        ),
      );
      expect(value, '5.25/10.5 USD');
    });

    test('an exhausted absolute meter still shows a zero', () {
      // A zero remaining against a real limit is a meaningful state and must
      // not be confused with the absence of a cap.
      final value = QuotaRow.valueTextOf(
        const Quota(
          id: 'credits',
          label: 'Credits',
          percent: 100,
          remaining: 0,
          limit: 10.5,
          unit: 'USD',
          resetAt: null,
        ),
      );
      expect(value, '0/10.5 USD');
    });
  });

  group('an absent cap is not the headline', () {
    testWidgets('it never occupies the value position', (tester) async {
      await pump(tester, [
        account(
          provider: 'openrouter',
          name: 'Main Key',
          quotas: const [
            Quota(
              id: 'key-limit',
              label: 'Key limit',
              percent: null,
              remaining: null,
              limit: null,
              unit: null,
              resetAt: null,
            ),
          ],
        ),
      ]);

      // The word still appears — audit C-31 requires it, and it is genuinely
      // useful: a key with no ceiling should not read as broken. What changed is
      // its *rank*: it is quiet metadata, not the row's authoritative value in
      // the largest type on the card. The reference does the same thing, showing
      // "Google API (app closed)" as a quiet line rather than a headline.
      final cap = tester.widget<Text>(find.text('No key cap'));
      expect(
        cap.style,
        isNot(
          quotaTextStyle(
            TokenDockTheme.colorsOf(tester.element(find.text('No key cap')))
                .ink,
          ),
        ),
        reason: 'an absence must not be styled as the authoritative value',
      );

      // And no bar is drawn, because an unknown meter must not look like an
      // empty one that reads as "used nothing".
      expect(
        find.descendant(
          of: find.ancestor(
            of: find.text('No key cap'),
            matching: find.byType(Column),
          ),
          matching: find.byType(QuotaBar),
        ),
        findsNothing,
      );
    });

    test('the bar stays empty rather than implying zero usage', () {
      // A null percent is unknown, not zero, and the bar must not look like a
      // connection that has used nothing.
      expect(
        QuotaRow.valueTextOf(
          const Quota(
            id: 'k',
            label: 'Key limit',
            percent: null,
            remaining: null,
            limit: null,
            unit: null,
            resetAt: null,
          ),
        ),
        isNot('0% used'),
      );
    });
  });

  group('a healthy connection is quiet', () {
    testWidgets('the status word is not repeated on every account', (
      tester,
    ) async {
      // Three accounts each saying "Connected" in green is the same fact three
      // times, and it consumes the scarcest real estate: colour and text. The
      // accessibility guarantee is preserved through the semantic label, so
      // the information is still available to a screen reader.
      await pump(tester, [
        account(
          name: 'One',
          quotas: [percent(id: 'a', label: 'Weekly', used: 5)],
        ),
        account(
          name: 'Two',
          quotas: [percent(id: 'b', label: 'Weekly', used: 5)],
        ),
        account(
          name: 'Three',
          quotas: [percent(id: 'c', label: 'Weekly', used: 5)],
        ),
      ]);

      expect(find.text('Connected'), findsNothing);
    });

    testWidgets('but a connection that needs attention still says so', (
      tester,
    ) async {
      // Quiet must not mean silent about problems.
      await pump(tester, [
        account(
          name: 'Throttled',
          status: ConnectionStatus.limited,
          quotas: [percent(id: 'a', label: 'Weekly', used: 100)],
        ),
        account(
          name: 'Fine',
          quotas: [percent(id: 'b', label: 'Weekly', used: 5)],
        ),
      ]);

      expect(find.text('Limited'), findsOneWidget);
      expect(find.text('Connected'), findsNothing);
    });
  });

  group('the cache age is not repeated per account', () {
    testWidgets('one account states it, the rest do not', (tester) async {
      // Every account is refreshed in the same cycle, so three identical
      // "just now" lines are one fact written three times.
      await pump(tester, [
        account(
          name: 'One',
          quotas: [percent(id: 'a', label: 'A', used: 1)],
        ),
        account(
          name: 'Two',
          quotas: [percent(id: 'b', label: 'B', used: 1)],
        ),
      ]);

      final ageLines = tester
          .widgetList<Text>(find.byType(Text))
          .map((t) => t.data)
          .whereType<String>()
          .where((s) => s.contains('updated'))
          .length;

      expect(ageLines, lessThanOrEqualTo(1));
    });
  });
}
