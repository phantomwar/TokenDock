import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/ui/boot_failure.dart';
import 'package:tokendock/ui/maintenance.dart';

/// Plan A.5: the boot path was not resilient.
///
/// `main` awaited `AppDatabase.open()` with no guard, so a failed migration
/// threw out of `main` before `runApp`. The process died with no window and no
/// message. These tests cover the surface that replaced it, and the guard that
/// decides between the app and the surface.
void main() {
  group('openOrSurface', () {
    test('returns the value when opening succeeds', () async {
      final result = await openOrSurface(
        open: () async => 'opened',
        surface: (_) => 'surfaced',
      );
      expect(result, 'opened');
    });

    test('returns the surface instead of rethrowing', () async {
      final result = await openOrSurface(
        open: () async => throw StateError('migration blew up'),
        surface: (_) => 'surfaced',
      );
      expect(result, 'surfaced');
    });

    test('the original error is still available to the caller', () async {
      // The surface must be able to log or report the cause. It is not
      // swallowed, only kept from reaching `runApp`.
      Object? seen;
      await openOrSurface(
        open: () async => throw StateError('boom'),
        surface: (error) {
          seen = error;
          return 'surfaced';
        },
      );
      expect(seen, isA<StateError>());
    });

    test('a surface that itself throws is not masked either', () async {
      // If the surface cannot build, there is nothing left to show. Letting
      // this propagate is correct: a silent blank window would be worse.
      await expectLater(
        openOrSurface(
          open: () async => throw StateError('boom'),
          surface: (_) => throw StateError('surface is broken too'),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('BootFailureApp', () {
    testWidgets('says what happened and offers a retry and an exit', (
      tester,
    ) async {
      var retries = 0;
      var exits = 0;

      await tester.pumpWidget(
        MaterialApp(
          home: BootFailureApp(
            onRetry: () async => retries++,
            onExit: () async => exits++,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text(BootFailureApp.title), findsOneWidget);
      expect(find.text(BootFailureApp.body), findsOneWidget);

      await tester.tap(find.byKey(const Key('bootRetryButton')));
      await tester.pumpAndSettle();
      expect(retries, 1);

      await tester.tap(find.byKey(const Key('bootExitButton')));
      await tester.pumpAndSettle();
      expect(exits, 1);
    });

    testWidgets('never renders a raw exception, SQL, or a credential', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: BootFailureApp(onRetry: () async {}, onExit: () async {}),
        ),
      );
      await tester.pumpAndSettle();

      final rendered = tester
          .widgetList<Text>(find.byType(Text))
          .map((widget) => widget.data ?? '')
          .join(' ')
          .toLowerCase();

      for (final leak in const [
        'sqlite',
        'select',
        'insert ',
        'delete from',
        'quota_cache',
        'user_version',
        'causing statement',
        'sk-',
        'exception',
      ]) {
        expect(
          rendered,
          isNot(contains(leak)),
          reason: 'the boot surface must not expose "$leak"',
        );
      }
    });

    testWidgets('is readable in every theme, not just light', (tester) async {
      for (final theme in <ThemeData>[
        TokenDockTheme.lightTheme(),
        TokenDockTheme.darkTheme(),
        TokenDockTheme.highContrastTheme(),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: BootFailureApp(onRetry: () async {}, onExit: () async {}),
          ),
        );
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.text(BootFailureApp.title), findsOneWidget);
      }
    });
  });
}
