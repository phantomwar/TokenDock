import 'antigravity/antigravity_local.dart';
import 'antigravity/antigravity_provider.dart';
import 'minimax/minimax_provider.dart';
import 'opencode/opencode_go_provider.dart';
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
      register(OpenCodeGoProvider());
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

/// Why OpenCode **Zen** is not registered, and why **Go** is.
///
/// This file previously claimed both were impossible. That was wrong, and the
/// error is instructive enough to keep written down.
///
/// The claim rested on measuring the model listings with a deliberately invalid
/// bearer token:
///
/// ```text
/// opencode.ai/zen/go/v1/models : 200   (the key is ignored)
/// opencode.ai/zen/v1/models    : 200   (the key is ignored)
/// ```
///
/// Both listings really do ignore the key. But that is a fact about the *wrong
/// endpoint*. A listing is a static catalogue -- there is no reason for it to
/// vary by account, so ignoring the key is correct behaviour, not a defect. From
/// "the listing cannot gate" it does not follow that "nothing can gate". The
/// conclusion generalised from one probe instead of looking for the endpoint that
/// actually meters the account, and the reference implementation
/// (`can1357/oh-my-pi`) has it:
///
/// ```text
/// opencode.ai/zen/go/v1/usage  : 401 invalid key, 403 valid key with no Go plan
/// ```
///
/// So Go is registered, and gates honestly.
///
/// ## Zen is still out, for a different reason
///
/// The reference implementation registers a Go usage provider and **no Zen one**,
/// which is the useful signal: the absence is on their side too, not a limitation
/// of this port.
///
/// The underlying reason is that Go and Zen meter different things. Go is a
/// subscription with three named windows, and there is a per-window figure to
/// fetch. Zen is pay-as-you-go against a console balance -- its own documentation
/// says usage is tracked "in the console", and there is no documented endpoint
/// returning that balance. So a Zen provider here would offer a credential the
/// app cannot verify and a number it cannot obtain.
///
/// ## The cost of registering Go
///
/// `GET /zen/go/v1/usage` is first-party but **undocumented**, and the reference
/// implementation records that its shape "changed once on merge day". That is the
/// price of a working gate and real quota, and it is paid in three places:
/// decoding is all-or-nothing, the parse is pinned by tests against a recorded
/// fixture, and a reshape degrades to "keeps the last known values" rather than
/// to a wrong figure.
///
/// Re-evaluate if OpenCode documents these routes, or if Zen gains a
/// key-enforced, non-billable balance endpoint.
abstract final class OpenCodeSupport {
  const OpenCodeSupport._();

  /// The model listings, which do **not** enforce auth. Recorded so nobody
  /// "verifies" a key by fetching one of these and concluding it is good --
  /// a listing is a static catalogue, so an account-independent answer is correct.
  static final Uri zenModels = Uri.parse('https://opencode.ai/zen/v1/models');
  static final Uri goModels = Uri.parse('https://opencode.ai/zen/go/v1/models');

  /// The vendors' own words on where Zen usage lives.
  static const String usageIsConsoleOnly =
      'You can track your current usage '
      'in the console';
}
