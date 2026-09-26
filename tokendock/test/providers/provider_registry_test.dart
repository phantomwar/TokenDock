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

  test('OpenCode Go is offered, because its usage endpoint really does gate', () {
    // This test previously asserted Go was absent. That was wrong: it generalised
    // from the model listing, which ignores the key because a listing is a
    // static catalogue. `GET /zen/go/v1/usage` returns 401 for a bad key and 403
    // for a valid key with no Go plan, so it is an honest gate, and it carries
    // the three windowed quotas.
    expect(registry.get('opencode-go'), isNotNull);
    expect(registry.get('opencode-go')!.name, 'OpenCode Go');
  });

  test('OpenCode Zen is deliberately not offered', () {
    // Zen is pay-as-you-go against a console balance with no documented balance
    // endpoint, so a Zen connection here would offer a credential the app cannot
    // verify and a number it cannot obtain. The reference implementation
    // registers a Go usage provider and no Zen one, so the gap is on their side
    // too rather than being a limitation of this port.
    expect(
      registry.getAll().map((adapter) => adapter.id),
      isNot(contains(anyOf('opencode', 'opencode-zen', 'zen'))),
    );
  });

  test(
    'the OpenCode endpoints that looked like probes are recorded as unsafe',
    () {
      // Present so nobody re-derives this by fetching a listing and concluding
      // the key is valid. The listings are listed, not used.
      expect(OpenCodeSupport.zenModels.host, 'opencode.ai');
      expect(OpenCodeSupport.goModels.host, 'opencode.ai');
      expect(OpenCodeSupport.usageIsConsoleOnly, contains('console'));
    },
  );
}
