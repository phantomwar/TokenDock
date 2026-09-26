import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// Audit C-22: the three densities had drifted apart.
///
/// `_buildCompact`, `_buildNormal` and `_buildExpanded` each re-implemented the
/// same preamble (`Divider`, `Focus`, `Semantics`) and the same footer (cache
/// age, error line). The duplication was not cosmetic: compact had silently
/// stopped rendering `snapshot.error`, so a failing account showed a stale quota
/// number in the default density with no visible reason, while the other two
/// densities explained themselves. Nothing asserted the asymmetry, so it read
/// as intent rather than drift.
///
/// These tests pin the shared parts across densities so the next divergence is
/// a failing test instead of a code review comment.
void main() {
  // Widths at which the widget switches density. Mirrors the table in
  // `cache_age_test.dart`; the two must not drift apart.
  const densities = <(String, double)>[
    ('compact', 300.0),
    ('normal', 400.0),
    ('expanded', 600.0),
  ];

  AccountItem account({
    String? error,
    ConnectionStatus status = ConnectionStatus.ok,
    List<Quota> quotas = const [
      Quota(
        id: 'key-limit',
        label: 'Key limit',
        percent: 50,
        remaining: 50,
        limit: 100,
        unit: 'USD',
        resetAt: null,
      ),
    ],
  }) => AccountItem(
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
      status: status,
      quotas: quotas,
      balance: null,
      fetchedAt: DateTime.utc(2026, 1, 1, 12),
      error: error,
    ),
  );

  Future<void> pumpDensity(
    WidgetTester tester,
    double width, {
    required AccountItem item,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: SizedBox(
            width: width,
            height: 700,
            child: TokenDockWidget(state: AppState(accounts: [item])),
          ),
        ),
      ),
    );
  }

  group('every density reports why a connection is failing (C-22)', () {
    for (final (label, width) in densities) {
      testWidgets('$label renders the error text', (tester) async {
        await pumpDensity(
          tester,
          width,
          item: account(
            error: 'Rate limited by provider',
            status: ConnectionStatus.error,
          ),
        );

        expect(
          find.text('Rate limited by provider'),
          findsOneWidget,
          reason:
              '$label must say why it is failing. Cache-first truth only '
              'works if the user can see that the value is stale.',
        );
      });
    }

    testWidgets(
      'a successful connection renders no error line in any density',
      (tester) async {
        for (final (label, width) in densities) {
          await pumpDensity(tester, width, item: account());
          expect(
            find.textContaining('Rate limited'),
            findsNothing,
            reason: '$label must not invent an error for a healthy connection',
          );
        }
      },
    );
  });

  group('every density keeps the account identifiable (C-22)', () {
    for (final (label, width) in densities) {
      testWidgets('$label announces the account and its status', (
        tester,
      ) async {
        final handle = tester.ensureSemantics();
        await pumpDensity(
          tester,
          width,
          item: account(status: ConnectionStatus.limited),
        );

        // `Semantics` here is not a container, so the annotation merges with
        // the descendants' own text into one node. Match on the prefix the
        // widget composes, not on the whole node label.
        expect(
          find.bySemanticsLabel(RegExp('Main Key, Limited')),
          findsOneWidget,
          reason:
              '$label must expose the account name and status label, '
              'not rely on colour alone',
        );
        handle.dispose();
      });
    }
  });
}
