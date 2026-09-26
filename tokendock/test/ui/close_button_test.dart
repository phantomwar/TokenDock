import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/app/window_controller.dart';
import 'package:tokendock/models/connection.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/models/provider_snapshot.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

import '../support/test_app.dart';

/// The window is frameless, so the specification's close affordance never had
/// anything to attach to.
///
/// PRD section 10 defines a close button that hides to tray; PRD section 11
/// defines a tray `Exit` that finalises the app. `main` applies
/// `TitleBarStyle.hidden`, which removes the native title bar, so section 10's
/// `X` has no home and the only way to quit was a right-click on a tray icon
/// most users never find. The app looked like a dashboard with no off switch.
///
/// These tests pin the button that closes the **program** — the section 11
/// action — and, just as importantly, that it is reachable from every state the
/// app can be in. The header actions were gated on `accounts.isNotEmpty`, which
/// meant a first-run user with no connections had *no* header actions at all and
/// therefore no way out of the window.
void main() {
  // Fixed, so the relative-age label this snapshot drives has a stable value and
  // does not tick the test.
  final fetchedAt = DateTime.utc(2026, 9, 26, 12);

  // `final`, not `const`: `fetchedAt` is a runtime value, and a const
  // constructor cannot read a local.
  final account = AccountItem(
    connection: Connection(
      id: 'conn-1',
      provider: 'openrouter',
      displayName: 'Primary Key',
      group: null,
      plan: 'Pro',
      credentialRef: 'ref-1',
      enabled: true,
    ),
    snapshot: ProviderSnapshot(
      connectionId: 'conn-1',
      status: ConnectionStatus.ok,
      quotas: [],
      balance: null,
      fetchedAt: fetchedAt,
      error: null,
    ),
  );

  const closeButton = Key('headerCloseButton');
  const refreshButton = Key('headerRefreshButton');
  const settingsButton = Key('headerSettingsButton');

  AppState loaded() => createTestAppState(accounts: <AccountItem>[account]);

  Future<WindowController> pump(
    WidgetTester tester,
    AppState state, {
    double? windowWidth,
  }) async {
    final controller = WindowController.forTest();
    Widget app = TokenDockApp(appState: state, windowController: controller);
    if (windowWidth != null) {
      app = MaterialApp(
        theme: TokenDockTheme.lightTheme(),
        home: Scaffold(
          body: SizedBox(width: windowWidth, height: 700, child: app),
        ),
      );
    }
    await tester.pumpWidget(app);
    await tester.pumpAndSettle();
    return controller;
  }

  group('the program can be closed from the window', () {
    testWidgets('a close button exists in the header', (tester) async {
      await pump(tester, loaded());
      expect(find.byKey(closeButton), findsOneWidget);
    });

    testWidgets('tapping it quits, and quits exactly once', (tester) async {
      var quits = 0;
      await tester.pumpWidget(
        TokenDockApp(
          appState: loaded(),
          windowController: WindowController.forTest(quit: () async => quits++),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(closeButton));
      await tester.pumpAndSettle();

      expect(quits, 1, reason: 'the button must finalise the app, once');
    });

    testWidgets('it quits rather than hiding, because hide is a lie here', (
      tester,
    ) async {
      // The native close hides to tray, so a button that merely hid the window
      // would close the *window* and leave the program running with no visible
      // sign of it. That is the opposite of what a close button is for.
      var hides = 0;
      var quits = 0;
      await tester.pumpWidget(
        TokenDockApp(
          appState: loaded(),
          windowController: WindowController.forTest(
            hide: () async => hides++,
            quit: () async => quits++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(closeButton));
      await tester.pumpAndSettle();

      expect(quits, 1);
      expect(hides, 0, reason: 'hide-to-tray is PRD section 10, not this');
    });

    testWidgets('it says what it does, for a screen reader', (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, loaded());

      expect(
        find.bySemanticsLabel('Close TokenDock'),
        findsOneWidget,
        reason:
            'a bare "Exit" or an unlabelled glyph tells a screen reader '
            'nothing about whether the window or the program goes away',
      );
      handle.dispose();
    });
  });

  group('and it is reachable from every state', () {
    testWidgets('first run, with no connections at all', (tester) async {
      // The regression that made this more than a missing feature. Header
      // actions were gated on `accounts.isNotEmpty`, so the empty state — the
      // very first thing a new user sees — had no header actions whatsoever.
      await pump(tester, createTestAppState());

      expect(find.text('No connections yet'), findsOneWidget);
      expect(find.byKey(closeButton), findsOneWidget);
    });

    testWidgets('while connections are still loading', (tester) async {
      await pump(tester, createTestAppState(isLoading: true));
      expect(find.byKey(closeButton), findsOneWidget);
    });

    testWidgets('refresh and settings keep their existing gate', (
      tester,
    ) async {
      // Only the close button is unconditional. Hiding refresh and settings with
      // no accounts is right — there is nothing to refresh and nowhere to
      // configure — and the close button must not drag them back into the empty
      // state just to be near itself.
      await pump(tester, createTestAppState());

      expect(find.byKey(closeButton), findsOneWidget);
      expect(find.byKey(refreshButton), findsNothing);
      expect(find.byKey(settingsButton), findsNothing);
    });
  });

  group('it does not crowd the widget', () {
    testWidgets('it is the last header action, furthest from refresh', (
      tester,
    ) async {
      // Refresh is the most-clicked button in the widget and the close button
      // kills the process, so they must not be neighbours. Windows puts close at
      // the far right for the same reason.
      await pump(tester, loaded());

      final refresh = tester.getCenter(find.byKey(refreshButton));
      final settings = tester.getCenter(find.byKey(settingsButton));
      final close = tester.getCenter(find.byKey(closeButton));

      expect(refresh.dx, lessThan(settings.dx));
      expect(settings.dx, lessThan(close.dx));
    });

    testWidgets('it matches the size of the actions beside it', (tester) async {
      await pump(tester, loaded());

      final close = tester.getSize(find.byKey(closeButton));
      final settings = tester.getSize(find.byKey(settingsButton));

      expect(
        close,
        settings,
        reason:
            'a smaller target in an always-on-top '
            'window is a target people miss',
      );
    });

    testWidgets('it survives the header layout at every density', (
      tester,
    ) async {
      // 300 is the window's own minimumSize, 360 the shipped width, 800 the
      // maximum. The header is outside the density switch, but "outside" is an
      // implementation claim, and this is where it gets checked.
      for (final width in <double>[300, 360, 800]) {
        await pump(tester, loaded(), windowWidth: width);
        expect(
          find.byKey(closeButton),
          findsOneWidget,
          reason: 'missing at ${width}px',
        );
        expect(tester.takeException(), isNull, reason: 'threw at ${width}px');
      }
    });
  });

  group('it is reachable from the keyboard', () {
    testWidgets('tab lands on it and Enter activates it', (tester) async {
      var quits = 0;
      await tester.pumpWidget(
        TokenDockApp(
          appState: loaded(),
          windowController: WindowController.forTest(quit: () async => quits++),
        ),
      );
      await tester.pumpAndSettle();

      // Header order is refresh, settings, close, so the third tab lands on it.
      for (var i = 0; i < 3; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }

      // Assert *which* control holds focus. Checking only that something is
      // focused passes for any layout at all, and that is exactly the assertion
      // that would let this button fall out of the traversal order unnoticed.
      final focusContext = FocusManager.instance.primaryFocus?.context;
      expect(
        focusContext?.findAncestorWidgetOfExactType<IconButton>()?.key,
        closeButton,
        reason:
            'the close button must be in the traversal order, or a keyboard '
            'user cannot quit an app whose window has no title bar either',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(quits, 1);
    });
  });

  group('the standalone widget is unaffected', () {
    testWidgets('it still renders with no window controller at all', (
      tester,
    ) async {
      // `TokenDockWidget` is pumped standalone in several density tests with no
      // controller in scope. It must not throw on a null callback.
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 360,
              height: 700,
              child: TokenDockWidget(state: loaded()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(closeButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
