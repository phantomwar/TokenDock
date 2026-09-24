import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/models/quota.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

import '../test/support/test_app.dart';

/// Integration proofs for independent OpenRouter accounts: more than three
/// connections restore, refresh, cache, and fail independently.
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
  const cachedResearch = Quota(
    id: 'key-limit',
    label: 'Key limit',
    percent: 15,
    remaining: 8.5,
    limit: 10,
    unit: 'USD',
    resetAt: null,
  );

  const accountNames = ['Production', 'Personal', 'Client', 'Research'];

  const accountResponses = {
    'Production': FixtureResponse.success,
    'Personal': FixtureResponse.limited,
    'Client': FixtureResponse.timeout,
    'Research': FixtureResponse.success,
  };

  testWidgets(
    'more than three OpenRouter accounts restore and fail independently',
    (tester) async {
      final app = TestApp.withConnections(
        connections: accountNames,
        responses: accountResponses,
      );

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      expect(find.text('Production'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
      expect(find.text('Client'), findsOneWidget);
      expect(find.text('Research'), findsOneWidget);
      expect(find.text('Timeout'), findsOneWidget);
    },
  );

  testWidgets(
    'a failing account keeps its cached quota while healthy accounts refresh',
    (tester) async {
      final app = TestApp.withConnections(
        connections: accountNames,
        responses: accountResponses,
        initialCachedQuotas: const {
          'Production': [cachedProduction],
          'Personal': [cachedPersonal],
          'Client': [cachedClient],
          'Research': [cachedResearch],
        },
      );

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // Production and Research refreshed successfully, so provider values
      // replaced their cached values independently.
      expect(find.text('2.5/10 USD'), findsNWidgets(2));
      expect(find.text('7.5/10 USD'), findsNothing);
      expect(find.text('8.5/10 USD'), findsNothing);

      // Client failed with a timeout: the failure did not erase its cache.
      expect(find.text('1/10 USD'), findsOneWidget);
      expect(find.text('Timeout'), findsOneWidget);

      // Personal reported an exhausted key without affecting the other accounts.
      expect(find.text('Limited'), findsOneWidget);
      expect(find.text('Key limit exceeded'), findsOneWidget);
    },
  );

  testWidgets(
    'restart restores more than three accounts from cache when every provider is unreachable',
    (tester) async {
      final app = TestApp.withConnections(
        connections: accountNames,
        responses: const {
          'Production': FixtureResponse.timeout,
          'Personal': FixtureResponse.timeout,
          'Client': FixtureResponse.timeout,
          'Research': FixtureResponse.timeout,
        },
        initialCachedQuotas: const {
          'Production': [cachedProduction],
          'Personal': [cachedPersonal],
          'Client': [cachedClient],
          'Research': [cachedResearch],
        },
      );

      await tester.pumpWidget(app);
      await tester.pumpAndSettle();

      // Every provider call failed, so these values can only come from cache.
      expect(find.text('7.5/10 USD'), findsOneWidget);
      expect(find.text('4/10 USD'), findsOneWidget);
      expect(find.text('1/10 USD'), findsOneWidget);
      expect(find.text('8.5/10 USD'), findsOneWidget);
      expect(find.text('Timeout'), findsNWidgets(4));
      expect(find.byType(TokenDockWidget), findsOneWidget);
    },
  );
}
