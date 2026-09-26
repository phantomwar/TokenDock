import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/test_result.dart';
import 'package:tokendock/providers/provider_registry.dart';
import 'package:tokendock/ui/settings/connections_screen.dart';

import '../support/test_app.dart';

/// The design system contract in `lib/app/theme.dart` states that components
/// "resolve the active ramp with [TokenDockTheme.colorsOf] so they stay flat,
/// composable content primitives with no hardcoded colors".
///
/// Audit C-07: the connection dialog used `Colors.green` and `Colors.red` for
/// its success and error copy, measuring 2.78:1 and 3.68:1 on white, and no
/// test or enabled lint could see it. `flutter_lints` only checks partially
/// specified hex inside a `Color(...)` constructor, so a named palette
/// constant is structurally invisible to it.
void main() {
  /// Colours actually handed to a [Text] or [Icon] in the built tree.
  List<Color> renderedColors(WidgetTester tester) {
    final colors = <Color>[];
    for (final text in tester.widgetList<Text>(find.byType(Text))) {
      final color = text.style?.color;
      if (color != null) colors.add(color);
    }
    for (final icon in tester.widgetList<Icon>(find.byType(Icon))) {
      final color = icon.color;
      if (color != null) colors.add(color);
    }
    return colors;
  }

  /// Raw Material palette entries carry no TokenDock meaning and do not adapt
  /// to the light, dark or high-contrast ramp.
  final banned = <Color>{
    Colors.green,
    Colors.red,
    Colors.blue,
    Colors.orange,
    Colors.yellow,
    Colors.purple,
    Colors.teal,
    Colors.pink,
    Colors.brown,
    Colors.grey,
    Colors.blueGrey,
    Colors.amber,
    Colors.lime,
    Colors.indigo,
    Colors.cyan,
  };

  group('source guard', () {
    test('no lib/ file outside theme.dart uses the Material palette', () {
      // flutter_lints cannot catch this: its only colour rule,
      // use_full_hex_values_for_flutter_colors, inspects partially specified
      // hex inside a Color(...) constructor, and
      // prefer_const_constructors_in_immutables actively rewards
      // `const TextStyle(color: Colors.red)`. A named palette constant is
      // therefore structurally invisible to the analyzer, so the invariant is
      // asserted against the source instead.
      final lib = Directory('lib');
      expect(lib.existsSync(), isTrue, reason: 'run from the package root');

      final offenders = <String>[];
      var inspected = 0;
      for (final file in lib.listSync(recursive: true).whereType<File>()) {
        if (!file.path.endsWith('.dart')) continue;
        if (file.path.replaceAll('\\', '/').endsWith('app/theme.dart')) {
          continue;
        }
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          if (line.trimLeft().startsWith('//')) continue;
          if (line.contains('Colors.') &&
              !line.contains('Colors.transparent')) {
            offenders.add('${file.path}:${i + 1}  ${line.trim()}');
          }
        }
        inspected++;
      }

      expect(
        inspected,
        greaterThan(30),
        reason: 'the guard must actually walk lib/, not pass vacuously',
      );
      expect(
        offenders,
        isEmpty,
        reason:
            'use TokenDockTheme tokens instead of the Material palette:\n'
            '${offenders.join('\n')}',
      );
    });
  });

  /// Builds the real [ConnectionsScreen] under a chosen ramp.
  ///
  /// `TestConnectionsScreen` wraps its own `MaterialApp` with no theme, which
  /// would override the ramp under test, so the screen is mounted directly.
  Future<void> openDialog(
    WidgetTester tester, {
    required bool success,
    ThemeData? theme,
  }) async {
    final registry = ProviderRegistry(registerDefaults: false)
      ..register(
        FakeProviderAdapter(
          testResult: success
              ? TestResult.success(plan: 'Pro')
              : TestResult.failure(error: 'Invalid API key'),
        ),
      );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme ?? TokenDockTheme.lightTheme(),
        home: ConnectionsScreen(providerRegistry: registry),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('connection dialog follows the theme ramp', () {
    testWidgets('a successful test renders the statusOk token', (tester) async {
      await openDialog(tester, success: true);
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      expect(find.text('Connected'), findsOneWidget);
      expect(
        renderedColors(tester),
        contains(TokenDockTheme.light.statusOk),
        reason: 'the success tick and label must come from the ramp',
      );
    });

    testWidgets('a failed test renders the statusLimited token', (
      tester,
    ) async {
      await openDialog(tester, success: false);
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      expect(find.text('Invalid API key'), findsOneWidget);
      expect(
        renderedColors(tester),
        contains(TokenDockTheme.light.statusLimited),
      );
    });
  });

  group('no raw Material palette colours in the dialog', () {
    testWidgets('the success state renders no Colors.* constant', (
      tester,
    ) async {
      await openDialog(tester, success: true);
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      expect(renderedColors(tester).where(banned.contains).toList(), isEmpty);
    });

    testWidgets('the error state renders no Colors.* constant', (tester) async {
      await openDialog(tester, success: false);
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      expect(renderedColors(tester).where(banned.contains).toList(), isEmpty);
    });

    testWidgets('the dialog adapts its colours to the dark ramp', (
      tester,
    ) async {
      await openDialog(
        tester,
        success: true,
        theme: TokenDockTheme.darkTheme(),
      );
      await tester.tap(find.byKey(const Key('addConnection')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('testConnectionButton')));
      await tester.pumpAndSettle();

      expect(
        renderedColors(tester),
        contains(TokenDockTheme.dark.statusOk),
        reason: 'the success colour must follow the active ramp',
      );
    });
  });
}
