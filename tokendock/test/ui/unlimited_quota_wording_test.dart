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

/// An unlimited key must not read as a failure.
///
/// Audit C-31: the first-goal design requires that when either numeric value is
/// null the row renders `No key cap` rather than zero. The implementation
/// renders `Unavailable`, which is the same word used for a real error state,
/// so an OpenRouter key with no cap looks broken. The string `No key cap`
/// appeared nowhere in lib/ or test/.
void main() {
  const unlimited = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: null,
    remaining: null,
    limit: null,
    unit: 'USD',
    resetAt: null,
  );

  const partial = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 25,
    remaining: null,
    limit: 10,
    unit: 'USD',
    resetAt: null,
  );

  const finite = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 50,
    remaining: 50,
    limit: 100,
    unit: 'USD',
    resetAt: null,
  );

  group('quota row wording', () {
    test('a finite quota shows the remaining/limit pair', () {
      expect(QuotaRow.valueTextOf(finite), '50/100 USD');
    });

    test('an unlimited quota says so, and never says "Unavailable"', () {
      final text = QuotaRow.valueTextOf(unlimited);
      expect(text, 'No key cap');
      expect(
        text,
        isNot(contains('Unavailable')),
        reason: '"Unavailable" is the word used for a real error state',
      );
    });

    test('a quota with no limit but a known percentage also says so', () {
      expect(QuotaRow.valueTextOf(partial), 'No key cap');
    });
  });

  AccountItem accountWith(Quota quota) => AccountItem(
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
          quotas: [quota],
          balance: null,
          fetchedAt: DateTime.now().toUtc(),
          error: null,
        ),
      );

  testWidgets('an unlimited key does not look like a broken connection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: TokenDockWidget.loaded(accounts: [accountWith(unlimited)]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No key cap'), findsWidgets);
    expect(find.text('Unavailable'), findsNothing);
  });

  testWidgets('the bar shows no fill when usage is unknown', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: const Scaffold(body: QuotaBar(percent: null)),
      ),
    );

    final fillBox = tester.widget<FractionallySizedBox>(
      find.byType(FractionallySizedBox),
    );
    expect(fillBox.widthFactor, 0);
    // The label is authoritative; the bar must not imply 0% usage.
    expect(
      tester.getSemantics(find.byType(QuotaBar)).label,
      contains('unknown'),
    );
  });

  testWidgets('a finite quota still renders its numbers', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: TokenDockWidget.loaded(accounts: [accountWith(finite)]),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('50/100 USD'), findsWidgets);
    expect(find.text('No key cap'), findsNothing);
  });
}
