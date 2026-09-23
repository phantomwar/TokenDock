import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/provider_adapter.dart';
import 'package:tokendock/providers/provider_registry.dart';

void main() {
  test('openrouter declares apiKey and builds Bearer at call time', () {
    final adapter = ProviderRegistry.withDefaults().get('openrouter')!;
    expect(adapter.authKind, AuthKind.apiKey);
    expect(adapter.buildAuthHeader('sek-ret'), {
      'Authorization': 'Bearer sek-ret',
    });
  });
}
