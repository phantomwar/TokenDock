import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

import '../test/support/test_app.dart';

/// Integration proofs for the first functional goal: three separate OpenRouter
/// accounts restore, refresh, cache, and fail independently.
///
/// Transport is fixture-backed and test-only; production construction still
/// resolves the live OpenRouter adapter and the real `%LOCALAPPDATA%` database.
void main() {
  const cachedProduction = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 25,
    remaining: 7.5,
    limit: 10,
    unit: 'USD',
    resetAt: null,
  );
  const cachedPersonal = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 60,
    remaining: 4,
    limit: 10,
    unit: 'USD',
    resetAt: null,
  );
  const cachedClient = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 90,
    remaining: 1,
    limit: 10,
    unit: 'USD',
    resetAt: null,
  );

  testWidgets('three OpenRouter accounts restore and fail independently',
      (tester) async {
    final app = TestApp.withConnections(
      connections: const ['Production', 'Personal', 'Client'],
      responses: const {
        'Production': FixtureResponse.success,
        'Personal': FixtureResponse.limited,
        'Client': FixtureResponse.timeout,
      },
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    expect(find.text('Production'), findsOneWidget);
    expect(find.text('Personal'), findsOneWidget);
    expect(find.text('Client'), findsOneWidget);
    expect(find.text('Timeout'), findsOneWidget);
  });

  testWidgets(
      'a failing account keeps its cached quota while a healthy account refreshes',
      (tester) async {
    final app = TestApp.withConnections(
      connections: const ['Production', 'Personal', 'Client'],
      responses: const {
        'Production': FixtureResponse.success,
        'Personal': FixtureResponse.limited,
        'Client': FixtureResponse.timeout,
      },
      initialCachedQuotas: const {
        'Production': [cachedProduction],
        'Personal': [cachedPersonal],
        'Client': [cachedClient],
      },
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Production refreshed successfully, so the provider value replaced the
    // cached one rather than being merged with it.
    expect(find.text('2.5/10 USD'), findsOneWidget);
    expect(find.text('7.5/10 USD'), findsNothing);

    // Client failed with a timeout: the failure did not erase its cache.
    expect(find.text('1/10 USD'), findsOneWidget);
    expect(find.text('Timeout'), findsOneWidget);

    // Personal reported an exhausted key: user-visible limited copy, and the
    // other two accounts are unaffected by it.
    expect(find.text('Limited'), findsOneWidget);
    expect(find.text('Key limit exceeded'), findsOneWidget);
  });

  testWidgets(
      'restart restores all three accounts from cache when every provider is unreachable',
      (tester) async {
    final app = TestApp.withConnections(
      connections: const ['Production', 'Personal', 'Client'],
      responses: const {
        'Production': FixtureResponse.timeout,
        'Personal': FixtureResponse.timeout,
        'Client': FixtureResponse.timeout,
      },
      initialCachedQuotas: const {
        'Production': [cachedProduction],
        'Personal': [cachedPersonal],
        'Client': [cachedClient],
      },
    );

    await tester.pumpWidget(app);
    await tester.pumpAndSettle();

    // Every provider call failed, so the only possible source for these values
    // is persisted cache restored on startup.
    expect(find.text('7.5/10 USD'), findsOneWidget);
    expect(find.text('4/10 USD'), findsOneWidget);
    expect(find.text('1/10 USD'), findsOneWidget);
    expect(find.text('Timeout'), findsNWidgets(3));
    expect(find.byType(TokenDockWidget), findsOneWidget);
  });
}
