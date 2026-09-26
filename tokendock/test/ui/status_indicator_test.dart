import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/ui/components/status_indicator.dart';

void main() {
  testWidgets('limited status shows Limited text and semantic label', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: const Scaffold(
            body: StatusIndicator(status: ConnectionStatus.limited),
          ),
        ),
      );

      expect(find.text('Limited'), findsOneWidget);
      expect(find.bySemanticsLabel('Limited'), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });

  testWidgets('every status exposes its label as text and semantics', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    try {
      for (final status in ConnectionStatus.values) {
        final label = StatusIndicator.labelOf(status);
        await tester.pumpWidget(
          MaterialApp(
            theme: TokenDockTheme.lightTheme(),
            home: Scaffold(body: StatusIndicator(status: status)),
          ),
        );

        // Every status is announced. That is the accessibility guarantee and it
        // is unchanged: colour is never the only signal, and the state is always
        // available to a screen reader.
        expect(
          find.bySemanticsLabel(label),
          findsOneWidget,
          reason: '$status lost its semantic label',
        );

        if (status == ConnectionStatus.ok) {
          // A healthy connection is the default and its word is suppressed, so
          // three accounts do not each render a green "Connected". The glyph and
          // the semantic label still carry it.
          expect(
            find.text(label),
            findsNothing,
            reason: 'a healthy connection should not spend text on its state',
          );
        } else {
          // Anything needing attention says so in words, in the layout itself.
          expect(
            find.text(label),
            findsOneWidget,
            reason: '$status must be visible, not only announced',
          );
        }
      }
    } finally {
      handle.dispose();
    }
  });

  testWidgets('a healthy connection still announces itself', (tester) async {
    // The suppression is visual only. Without this, dropping the word would
    // quietly remove the state from the accessibility tree too.
    final handle = tester.ensureSemantics();
    try {
      await tester.pumpWidget(
        MaterialApp(
          theme: TokenDockTheme.lightTheme(),
          home: const Scaffold(
            body: StatusIndicator(status: ConnectionStatus.ok),
          ),
        ),
      );

      expect(find.bySemanticsLabel('Connected'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    } finally {
      handle.dispose();
    }
  });
}
