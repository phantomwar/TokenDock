import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/models/test_result.dart';
import '../support/controlled_provider.dart';
import '../support/test_app.dart';
import 'package:tokendock/providers/provider_registry.dart';

void main() {
  test('openrouter declares apiKey and builds Bearer at call time', () {
    final adapter = ProviderRegistry.withDefaults().get('openrouter')!;
    expect(adapter.authKind, AuthKind.apiKey);
    expect(adapter.buildAuthHeader('sek-ret'), {
      'Authorization': 'Bearer sek-ret',
    });
  });

  test('test doubles implement the auth boundary', () {
    final adapters = <ProviderAdapter>[
      ControlledProvider(),
      FakeProviderAdapter(testResult: TestResult.success()),
      FixtureProviderAdapter(responses: const {}),
    ];

    for (final adapter in adapters) {
      expect(adapter.authKind, AuthKind.apiKey);
      expect(adapter.buildAuthHeader('sek-ret'), {
        'Authorization': 'Bearer sek-ret',
      });
    }
  });
}
