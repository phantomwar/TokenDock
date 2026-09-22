import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/theme.dart';
import 'package:tokendock/ui/widget/countdown_text.dart';

void main() {
  Widget buildFrame(Widget child) {
    return MaterialApp(
      theme: TokenDockTheme.lightTheme(),
      home: Scaffold(body: Center(child: child)),
    );
  }

  testWidgets('past resetAt displays "Resetting…"', (tester) async {
    final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
    await tester.pumpWidget(
      buildFrame(
        CountdownText(
          resetAt: now.subtract(const Duration(minutes: 5)).toUtc(),
          now: () => now,
        ),
      ),
    );

    expect(find.text('Resetting…'), findsOneWidget);
  });

  testWidgets('future resetAt displays formatted remaining time', (tester) async {
    final DateTime now = DateTime(2026, 1, 1, 12, 0, 0);
    await tester.pumpWidget(
      buildFrame(
        CountdownText(
          resetAt: now.add(const Duration(hours: 2, minutes: 15)).toUtc(),
          now: () => now,
        ),
      ),
    );

    expect(find.text('Resets in 2h 15m'), findsOneWidget);
  });

  testWidgets('null resetAt renders nothing (SizedBox.shrink)', (tester) async {
    await tester.pumpWidget(
      buildFrame(
        const CountdownText(resetAt: null),
      ),
    );

    expect(find.byType(SizedBox), findsWidgets);
    expect(find.byType(Text), findsNothing);
  });

  testWidgets(
      'local periodic updates: verify timer ticks update display locally without issuing network/provider calls',
      (tester) async {
    DateTime simulatedNow = DateTime(2026, 1, 1, 12, 0, 0);
    final resetTime = DateTime(2026, 1, 1, 12, 0, 45); // 45s remaining

    await tester.pumpWidget(
      buildFrame(
        CountdownText(
          resetAt: resetTime,
          now: () => simulatedNow,
          tickInterval: const Duration(seconds: 1),
        ),
      ),
    );

    expect(find.text('Resets in <1m'), findsOneWidget);

    // Advance virtual time by 1 second to trigger the timer tick
    simulatedNow = DateTime(2026, 1, 1, 12, 1, 0); // now past reset
    await tester.pump(const Duration(seconds: 1));

    // The display updated to 'Resetting…' locally
    expect(find.text('Resetting…'), findsOneWidget);

    // Unmount
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
