import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/components/account_header.dart';
import 'package:tokendock/ui/components/compact_account_row.dart';
import 'package:tokendock/ui/components/quota_row.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// Audit C-35: the test gaps the audit listed.
///
/// Three things were asserted nowhere, each of which had actually gone wrong at
/// some point: a zero limit, the exact density boundaries, and the parity
/// between densities (the last is covered by `density_parity_test.dart`).
void main() {
  const zeroLimit = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: null,
    remaining: 5,
    limit: 0,
    unit: 'USD',
    resetAt: null,
  );

  const zeroRemaining = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 0,
    remaining: 0,
    limit: 100,
    unit: 'USD',
    resetAt: null,
  );

  group('zero is not a cap', () {
    test('a zero limit reads as no cap, not as "5 out of 0"', () {
      // `limit == 0` is how a provider reports "no quota configured", which is
      // the same situation as an absent limit. Rendering it numerically produced
      // "5/0 USD", which no user can interpret.
      expect(QuotaRow.valueTextOf(zeroLimit), 'No key cap');
    });

    test('a genuinely exhausted quota still shows its numbers', () {
      // The guard against over-correcting: zero *remaining* against a real
      // limit is a real, meaningful state and must stay numeric.
      expect(QuotaRow.valueTextOf(zeroRemaining), '0/100 USD');
    });
  });

  group('density boundaries', () {
    AccountItem accountWithTwoQuotas() => AccountItem(
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
            id: 'first',
            label: 'First',
            percent: 10,
            remaining: 10,
            limit: 100,
            unit: 'USD',
            resetAt: null,
          ),
          Quota(
            id: 'second',
            label: 'Second',
            percent: 20,
            remaining: 20,
            limit: 100,
            unit: 'USD',
            resetAt: null,
          ),
        ],
        balance: null,
        fetchedAt: DateTime.utc(2026, 1, 1, 12),
        error: null,
      ),
    );

    /// The 330/550 breakpoints are specified against the **window** width, so
    /// the tests now set the window width directly.
    ///
    /// They previously compensated for `WidgetShell`'s padding with
    /// `contentWidth + 34`, which meant the test tracked the implementation
    /// rather than the spec — and so passed while the shipped 360px window
    /// rendered the compact density, because 360 - 32 = 328 is under 330. The
    /// density is now measured from `WidgetShellExtent`, which is captured
    /// outside the padding, so a width means what the spec says it means.
    Future<void> pumpAtWindowWidth(WidgetTester tester, double width) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(
            body: SizedBox(
              width: width,
              height: 700,
              child: TokenDockWidget(
                state: AppState(accounts: [accountWithTwoQuotas()]),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('329 is the last compact width', (tester) async {
      await pumpAtWindowWidth(tester, 329);
      expect(find.byType(CompactAccountRow), findsOneWidget);
      expect(find.byType(AccountHeader), findsNothing);
    });

    testWidgets('330 is the first normal width', (tester) async {
      await pumpAtWindowWidth(tester, 330);
      expect(find.byType(CompactAccountRow), findsNothing);
      // Normal shows every window: the account has two, and the one that is
      // nearly gone is the reason the user opened the app. Normal used to render
      // only the first, which discarded it.
      expect(find.byType(QuotaRow), findsNWidgets(2));
    });

    testWidgets('550 is still normal', (tester) async {
      await pumpAtWindowWidth(tester, 550);
      expect(find.byType(CompactAccountRow), findsNothing);
      expect(find.byType(QuotaRow), findsNWidgets(2));
    });

    testWidgets('551 is the first expanded width', (tester) async {
      await pumpAtWindowWidth(tester, 551);
      expect(find.byType(CompactAccountRow), findsNothing);
      expect(find.byType(QuotaRow), findsNWidgets(2));
    });

    testWidgets('the shipped 360px window is normal, not compact', (
      tester,
    ) async {
      // The regression that motivated all of this. 360 - 32 of padding is 328,
      // under the 330 threshold, so the default window was showing the compact
      // layout at every size the app is actually used.
      await pumpAtWindowWidth(tester, 360);
      expect(find.byType(CompactAccountRow), findsNothing);
      expect(find.byType(QuotaRow), findsNWidgets(2));
    });
  });
}
