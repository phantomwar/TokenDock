import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/provider_registry.dart';

/// The registry is a product decision, not just a lookup table, so the two
/// decisions in it are pinned here.
void main() {
  final registry = ProviderRegistry(registerDefaults: true);

  test('MiniMax is offered', () {
    // It has a real, key-enforcing probe: `GET /v1/models` returns 401 for a
    // bad key, verified against the live endpoint on 2026-09-26.
    expect(registry.get('minimax'), isNotNull);
    expect(registry.get('minimax')!.name, 'MiniMax');
  });

  test('OpenRouter and Antigravity are still offered', () {
    expect(registry.get('openrouter'), isNotNull);
    expect(registry.get('antigravity'), isNotNull);
  });

  test('every registered provider has a distinct, non-empty id', () {
    final ids = registry.getAll().map((adapter) => adapter.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'ids must be unique');
    expect(ids.every((id) => id.trim().isNotEmpty), isTrue);
  });

  test('OpenCode Zen and Go are deliberately not offered', () {
    // Both `/zen/v1/models` and `/zen/go/v1/models` return 200 for a
    // deliberately invalid bearer token, so a connection built on them would
    // ship a test-before-save gate that always passes. The user would save a
    // broken key believing it had been verified, which is worse than the
    // provider being absent. See the note in `provider_registry.dart`.
    expect(
      registry.getAll().map((adapter) => adapter.id),
      isNot(contains(anyOf('opencode', 'opencode-go', 'opencode-zen', 'zen'))),
    );
  });

  test(
    'the OpenCode endpoints that looked like probes are recorded as unsafe',
    () {
      // Present so nobody re-derives this by fetching them and concluding the
      // key is valid.
      expect(OpenCodeSupport.zenModels.host, 'opencode.ai');
      expect(OpenCodeSupport.goModels.host, 'opencode.ai');
      expect(OpenCodeSupport.usageIsConsoleOnly, contains('console'));
    },
  );
}
