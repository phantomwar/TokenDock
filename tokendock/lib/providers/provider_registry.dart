import 'openrouter/openrouter_provider.dart';
import 'provider_adapter.dart';

class ProviderRegistry {
  ProviderRegistry({bool registerDefaults = true}) {
    if (registerDefaults) {
      register(OpenRouterProvider());
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
