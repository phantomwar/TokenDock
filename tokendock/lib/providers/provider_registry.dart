import 'antigravity/antigravity_provider.dart';
import 'openrouter/openrouter_provider.dart';
import 'provider_adapter.dart';
import '../storage/secret_store.dart';

class ProviderRegistry {
  ProviderRegistry({bool registerDefaults = true, SecretStore? secretStore}) {
    if (registerDefaults) {
      // The default OpenRouter registry entry uses API key authentication.
      // Remote OAuth is the default Antigravity adapter; local read-only mode
      // remains available through AntigravityLocalReader.
      register(OpenRouterProvider());
      register(AntigravityProvider(secretStore: secretStore));
    }
  }

  factory ProviderRegistry.withDefaults() => ProviderRegistry(registerDefaults: true);

  static final ProviderRegistry _instance = ProviderRegistry();
  static ProviderRegistry get instance => _instance;

  final Map<String, ProviderAdapter> _adapters = {};

  void register(ProviderAdapter adapter) {
    _adapters[adapter.id] = adapter;
  }

  ProviderAdapter? get(String id) => _adapters[id];

  List<ProviderAdapter> getAll() => List.unmodifiable(_adapters.values);
}
