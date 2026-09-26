import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/providers/provider_adapter.dart';
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

  test(
    'z.ai is offered, and sends the one non-Bearer auth header in the tree',
    () {
      expect(registry.get('zai'), isNotNull);
      expect(registry.get('zai')!.name, 'z.ai');
      // z.ai expects the raw key in `Authorization`. A provider that declared a
      // Bearer header while its adapter sent something else would pass a
      // credential check it never actually performs.
      expect(registry.get('zai')!.buildAuthHeader('raw-key'), {
        'Authorization': 'raw-key',
      });
    },
  );

  test('every api-key provider identifies itself and sends a non-empty header', () {
    // The PRD rule for a new provider is that it needs an adapter, its own
    // models and tests -- and no change to the cards. This is the check that
    // keeps that true as providers are added: a provider with no display name
    // renders as a blank row, and one that sends an empty Authorization header
    // could never be verified.
    //
    // Scoped to `apiKey` deliberately. `buildAuthHeader` takes whatever the
    // provider's `authKind` calls a credential, and the OAuth adapters
    // *correctly* reject a bare string -- `AntigravityOAuthProvider` throws
    // "credential unreadable" rather than sending a raw token as a bearer. A
    // blanket call here would assert the opposite of the behaviour C-10 fixed.
    for (final adapter in registry.getAll()) {
      expect(adapter.name, isNotEmpty, reason: '${adapter.id} has no name');
      if (adapter.authKind != AuthKind.apiKey) continue;
      expect(
        adapter.buildAuthHeader('probe-value')['Authorization'],
        isNotEmpty,
        reason: '${adapter.id} sends an empty Authorization header',
      );
    }
  });

  test('an OAuth provider refuses a bare string rather than sending it as a bearer', () {
    // The C-10 guarantee, asserted at the registry level so a future OAuth
    // provider inherits it instead of re-deciding it. A credential that cannot
    // be parsed must be reported, not transmitted.
    for (final adapter in registry.getAll()) {
      if (adapter.authKind == AuthKind.apiKey) continue;
      expect(
        () => adapter.buildAuthHeader('not-a-json-credential'),
        throwsA(anything),
        reason:
            '${adapter.id} accepted a bare string as a credential; that would '
            'put an unverified value in an Authorization header',
      );
    }
  });

  test('authKind matches whether the provider can refresh its credential', () {
    // A provider that is `oauth` without a refresh path could never recover a
    // dead key, and one that is `apiKey` with a refresh path would be rotating
    // a secret that has no expiry. Both are silent until a user needs recovery.
    for (final adapter in registry.getAll()) {
      final refresh = adapter.refreshableCredential('probe-value');
      if (adapter.authKind == AuthKind.apiKey) {
        expect(refresh, isNull, reason: '${adapter.id} is api-key');
      } else {
        expect(refresh, isNotNull, reason: '${adapter.id} is oauth');
      }
    }
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
