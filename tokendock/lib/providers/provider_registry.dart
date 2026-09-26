import 'antigravity/antigravity_local.dart';
import 'antigravity/antigravity_provider.dart';
import 'minimax/minimax_provider.dart';
import 'openrouter/openrouter_provider.dart';
import 'provider_adapter.dart';
import '../storage/secret_store.dart';

class ProviderRegistry {
  ProviderRegistry({
    bool registerDefaults = true,
    SecretStore? secretStore,
    AntigravityLocalRuntimeConfig? antigravityLocalRuntime,
  }) {
    if (registerDefaults) {
      // The default OpenRouter registry entry uses API key authentication.
      // Remote OAuth is the default Antigravity adapter; local read-only mode
      // remains available through AntigravityLocalReader.
      register(OpenRouterProvider());
      register(MiniMaxProvider());
      register(
        AntigravityProvider(
          secretStore: secretStore,
          localRuntime: antigravityLocalRuntime,
        ),
      );
    }
  }

  factory ProviderRegistry.withDefaults() =>
      ProviderRegistry(registerDefaults: true);

  static final ProviderRegistry _instance = ProviderRegistry();
  static ProviderRegistry get instance => _instance;

  final Map<String, ProviderAdapter> _adapters = {};

  void register(ProviderAdapter adapter) {
    _adapters[adapter.id] = adapter;
  }

  ProviderAdapter? get(String id) => _adapters[id];

  List<ProviderAdapter> getAll() => List.unmodifiable(_adapters.values);
}

/// Why OpenCode Zen and OpenCode Go are **not** registered.
///
/// Both were evaluated on 2026-09-26 and both fail the same way, which is worth
/// writing down because it is not obvious from the docs and is expensive to
/// re-derive.
///
/// The obvious probe is the model listing both vendors publish. Measured against
/// both, with a deliberately invalid bearer token:
///
/// ```text
/// opencode.ai/zen/go/v1/models : 200   (the key is ignored)
/// opencode.ai/zen/v1/models    : 200   (the key is ignored)
/// ```
///
/// A credential gate that returns 200 for a garbage key is not a gate. Adding
/// either as a connection would mean shipping test-before-save that always
/// passes, which is worse than not offering the provider: the user would save a
/// broken key believing it had been verified.
///
/// The alternative probe is an inference call, which does enforce auth but
/// spends the user's quota. The reference research is explicit about why that
/// is the wrong trade for a probe -- "cuidado para não queimar quota, preferir
/// `GET /models`-like ao invés de chamada com custo".
///
/// There is a third option that was deliberately not taken. The web console at
/// `opencode.ai/auth` displays balance, auto-reload state and monthly usage, so
/// it must call some API. That API is not in the documentation, and inferring a
/// private endpoint is exactly what this project's non-goals forbid.
///
/// Both vendors also publish no usage figure over any documented API: Zen says
/// "You can track your current usage in the console", and Go publishes per-model
/// monthly *limits* but no consumption. So even with a working gate there would
/// be no honest number to display, which is the same wall MiniMax hits and the
/// reason `MiniMaxProvider` returns an empty quota list rather than a guess.
///
/// Re-evaluate when OpenCode documents either a usage endpoint or a
/// key-enforced, non-billable probe.
abstract final class OpenCodeSupport {
  const OpenCodeSupport._();

  /// The model listings, which do **not** enforce auth. Recorded so nobody
  /// "verifies" a key by fetching one of these and concluding it is good.
  static final Uri zenModels = Uri.parse('https://opencode.ai/zen/v1/models');
  static final Uri goModels = Uri.parse('https://opencode.ai/zen/go/v1/models');

  /// The vendors' own words on where usage lives.
  static const String usageIsConsoleOnly =
      'You can track your current usage '
      'in the console';
}
