import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/models/connection_status.dart';
import 'package:tokendock/ui/components/status_indicator.dart';

void main() {
  testWidgets('limited status shows Limited text and semantic label',
      (tester) async {
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

  testWidgets('every status exposes its label as text and semantics',
      (tester) async {
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

        expect(find.text(label), findsOneWidget);
        expect(find.bySemanticsLabel(label), findsOneWidget);
      }
    } finally {
      handle.dispose();
    }
  });
}
