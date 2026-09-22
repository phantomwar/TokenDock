import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';

import '../support/test_app.dart';

class SpyAppState extends AppState {
  SpyAppState({
    super.connectionRepository,
    super.quotaCacheRepository,
    super.secretStore,
    super.providerRegistry,
    super.settingsRepository,
    super.refreshService,
    super.accounts,
    super.isLoading,
  });

  int refreshAllCallCount = 0;

  @override
  Future<void> refreshAll() async {
    refreshAllCallCount++;
    return super.refreshAll();
  }
}

void main() {
  group('Accessibility & Startup Flow', () {
    testWidgets(
        'keyboard traversal reaches Add Connection from first-run state',
        (tester) async {
      await tester.pumpWidget(TestApp.empty());

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Connections'), findsOneWidget);
    });

    testWidgets('keyboard traversal can activate Add Connection via Space key',
        (tester) async {
      await tester.pumpWidget(TestApp.empty());

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();

      expect(find.text('Connections'), findsOneWidget);
    });

    testWidgets('Ctrl+R shortcut triggers refreshAll()', (tester) async {
      final spyState = SpyAppState();
      await tester.pumpWidget(TestApp(state: spyState));
      await tester.pumpAndSettle();

      expect(spyState.refreshAllCallCount, 0);

      // Press Ctrl+R
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(spyState.refreshAllCallCount, 1);
    });

    testWidgets(
        'Ctrl+R is ignored / not triggered while a text field has focus',
        (tester) async {
      final spyState = SpyAppState();
      final focusNode = FocusNode();
      final controller = TextEditingController();

      await tester.pumpWidget(
        TestApp(
          state: spyState,
          child: TextField(
            focusNode: focusNode,
            controller: controller,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Focus the text field
      focusNode.requestFocus();
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      // Press Ctrl+R while text field has focus
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Must NOT have called refreshAll
      expect(spyState.refreshAllCallCount, 0);

      // Unfocus the text field
      focusNode.unfocus();
      await tester.pump();
      expect(focusNode.hasFocus, isFalse);

      // Press Ctrl+R again
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      // Now it must trigger refreshAll
      expect(spyState.refreshAllCallCount, 1);
    });

    testWidgets('high-contrast mode applies opaque tokens and readable text',
        (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(highContrast: true),
          child: TestApp.empty(),
        ),
      );
      await tester.pumpAndSettle();

      final BuildContext context =
          tester.element(find.text('No connections yet'));
      final colors = TokenDockTheme.colorsOf(context);

      // Verify high-contrast ramp is resolved
      expect(colors, equals(TokenDockTheme.highContrast));

      // Verify all colors in the ramp are fully opaque (alpha == 255)
      for (final color in colors.values) {
        expect(
          color.alpha,
          equals(255),
          reason: 'Color $color must be fully opaque in high-contrast mode',
        );
      }

      // Verify extreme contrast between surface and ink
      expect(colors.canvas, const Color(0xFF000000));
      expect(colors.surface, const Color(0xFF000000));
      expect(colors.ink, const Color(0xFFFFFFFF));
    });

    testWidgets(
        'reduced motion: verify MediaQuery with disableAnimations renders cleanly without timing out',
        (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: TestApp.empty(),
        ),
      );
      // pumpAndSettle must complete without timeout or hanging animations
      await tester.pumpAndSettle();

      expect(find.text('TokenDock'), findsOneWidget);
      expect(find.text('No connections yet'), findsOneWidget);
      expect(find.text('Add Connection'), findsOneWidget);

      // Navigation under reduced motion also completes cleanly
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Connections'), findsOneWidget);
    });

    testWidgets(
        'keyboard traversal reaches header action buttons when accounts are loaded',
        (tester) async {
      const conn = Connection(
        id: 'conn-1',
        provider: 'openrouter',
        displayName: 'Primary Key',
        group: null,
        plan: 'Pro',
        credentialRef: 'ref-1',
        enabled: true,
      );
      final account = AccountItem(
        connection: conn,
        snapshot: ProviderSnapshot(
          connectionId: conn.id,
          status: ConnectionStatus.ok,
          quotas: const [],
          balance: null,
          fetchedAt: DateTime.utc(2026, 9, 22),
          error: null,
        ),
      );

      final state = createTestAppState(accounts: [account]);
      await tester.pumpWidget(TestApp(state: state));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('headerRefreshButton')), findsOneWidget);
      expect(find.byKey(const Key('headerSettingsButton')), findsOneWidget);

      // Tab 1: header refresh button receives focus
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);

      // Tab 2: header settings button receives focus
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);

      // Press Enter to activate header settings button -> navigates to ConnectionsScreen
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(find.text('Connections'), findsOneWidget);
    });
  });
}
