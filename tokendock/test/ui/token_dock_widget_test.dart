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
import 'package:tokendock/ui/widget/countdown_text.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

const _connection = Connection(
  id: 'c1',
  provider: 'openrouter',
  displayName: 'Main Key',
  group: null,
  plan: 'Pro',
  credentialRef: 'ref',
  enabled: true,
);

Quota _quota({
  String id = 'q1',
  String label = 'Credits',
  DateTime? resetAt,
}) {
  return Quota(
    id: id,
    label: label,
    percent: 50,
    remaining: 50,
    limit: 100,
    unit: 'USD',
    resetAt: resetAt,
  );
}

AccountItem _account({
  Connection connection = _connection,
  ConnectionStatus status = ConnectionStatus.ok,
  List<Quota>? quotas,
  String? error,
  DateTime? fetchedAt,
}) {
  return AccountItem(
    connection: connection,
    snapshot: ProviderSnapshot(
      connectionId: connection.id,
      status: status,
      quotas: quotas ?? <Quota>[_quota()],
      balance: null,
      fetchedAt: fetchedAt ?? DateTime.utc(2026, 9, 22, 12),
      error: error,
    ),
  );
}

void main() {
  testWidgets('loading shows title, three skeletons, no compact rows',
      (tester) async {
    // Pumped standalone: WidgetShell must supply Directionality/Material.
    await tester.pumpWidget(const TokenDockWidget.loading());

    expect(find.text('TokenDock'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('skeleton-0')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('skeleton-1')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('skeleton-2')), findsOneWidget);
    expect(find.byType(CompactAccountRow), findsNothing);
  });

  testWidgets('empty shows first-run state and fires add callback',
      (tester) async {
    var pressed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: TokenDockWidget.empty(
            onAddConnection: () => pressed = true,
          ),
        ),
      ),
    );

    expect(find.text('TokenDock'), findsOneWidget);
    expect(find.text('No connections yet'), findsOneWidget);
    expect(find.text('Add Connection'), findsOneWidget);
    await tester.tap(find.text('Add Connection'));
    expect(pressed, isTrue);
  });

  testWidgets('compact width renders compact rows', (tester) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 300,
          child: TokenDockWidget.loaded(accounts: <AccountItem>[_account()]),
        ),
      ),
    );

    expect(find.byType(CompactAccountRow), findsOneWidget);
    expect(find.text('Main Key'), findsOneWidget);
    expect(find.text('50/100 USD'), findsOneWidget);
    expect(find.byType(QuotaRow), findsNothing);
    expect(find.byType(AccountHeader), findsNothing);
  });

  testWidgets('normal width renders header and primary quota', (tester) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 400,
          child: TokenDockWidget.loaded(
            accounts: <AccountItem>[
              _account(
                quotas: <Quota>[
                  _quota(
                    resetAt:
                        DateTime.now().add(const Duration(hours: 2, minutes: 15)),
                  ),
                  _quota(id: 'q2', label: 'Requests'),
                ],
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(AccountHeader), findsOneWidget);
    expect(find.byType(QuotaRow), findsOneWidget);
    expect(find.byType(CompactAccountRow), findsNothing);
    // Only the primary quota is shown in normal density.
    expect(find.text('Credits'), findsOneWidget);
    expect(find.text('Requests'), findsNothing);
    expect(find.textContaining('Resets in'), findsOneWidget);
  });

  testWidgets('expanded width renders all quotas, plan, and error',
      (tester) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 600,
          child: TokenDockWidget.loaded(
            accounts: <AccountItem>[
              _account(
                status: ConnectionStatus.error,
                quotas: <Quota>[
                  _quota(),
                  _quota(id: 'q2', label: 'Requests'),
                ],
                error: 'Provider unavailable',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(AccountHeader), findsOneWidget);
    expect(find.byType(QuotaRow), findsNWidgets(2));
    expect(find.text('Credits'), findsOneWidget);
    expect(find.text('Requests'), findsOneWidget);
    expect(find.text('Pro'), findsOneWidget);
    expect(find.text('Provider unavailable'), findsOneWidget);
    expect(find.textContaining('Updated'), findsOneWidget);
  });

  testWidgets('stale snapshot keeps quotas while showing error', (tester) async {
    await tester.pumpWidget(
      Center(
        child: SizedBox(
          width: 400,
          child: TokenDockWidget.loaded(
            accounts: <AccountItem>[
              _account(
                status: ConnectionStatus.error,
                error: 'Provider unavailable',
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('Credits'), findsOneWidget);
    expect(find.text('50/100 USD'), findsOneWidget);
    expect(find.text('Provider unavailable'), findsOneWidget);
  });

  testWidgets('countdown shows resetting for past reset', (tester) async {
    final DateTime now = DateTime(2026, 1, 1, 12);
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: CountdownText(
            resetAt: now.subtract(const Duration(hours: 1)).toUtc(),
            now: () => now,
          ),
        ),
      ),
    );

    expect(find.text('Resetting…'), findsOneWidget);
  });

  testWidgets('countdown shows remaining for future reset', (tester) async {
    final DateTime now = DateTime(2026, 1, 1, 12);
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: CountdownText(
            resetAt: now.add(const Duration(hours: 2, minutes: 15)).toUtc(),
            now: () => now,
          ),
        ),
      ),
    );

    expect(find.text('Resets in 2h 15m'), findsOneWidget);
  });

  testWidgets('countdown renders nothing without reset', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: const Scaffold(body: CountdownText(resetAt: null)),
      ),
    );

    expect(find.byType(Text), findsNothing);
  });
}
