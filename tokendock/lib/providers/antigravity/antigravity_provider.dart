import 'antigravity_oauth.dart';

/// Default Antigravity adapter. Local read-only quota remains available via
/// [AntigravityLocalReader] for explicit per-connection opt-in.
class AntigravityProvider extends AntigravityOAuthProvider {
  AntigravityProvider({super.http, super.secretStore});
}
