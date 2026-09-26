import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/app_state.dart';
import 'package:tokendock/ui/widget/token_dock_widget.dart';

/// Audit C-24: `AppState` was a `ChangeNotifier` in name only.
///
/// It `implements ChangeNotifier` and forwarded every call to a private
/// `_StateNotifier` reached through a `static final Expando`, while its
/// loading/empty constructors were `const`. Dart canonicalises const instances,
/// so every loading shell in the process was the *same* `AppState` object, and
/// `_fallbackNotifiers[this]` handed them all one notifier. Disposing one tore
/// down the rest, which surfaces as "A ChangeNotifier was used after being
/// disposed" from whichever surface happened to build a loading shell second.
void main() {
  test('two loading shells are distinct objects', () {
    final first = TokenDockWidget.loading();
    final second = TokenDockWidget.loading();

    expect(
      identical(first.state, second.state),
      isFalse,
      reason:
          'a AppState.loading() is canonicalised by Dart, so both '
          'shells share one instance and therefore one notifier',
    );
  });

  test('disposing one loading shell leaves the other listening', () {
    final first = TokenDockWidget.loading();
    final second = TokenDockWidget.loading();

    var notifications = 0;
    second.state.addListener(() => notifications++);

    first.state.dispose();

    // Must not throw "A ChangeNotifier was used after being disposed".
    second.state.notifyListeners();
    expect(notifications, 1);
  });

  test('AppState is itself the notifier, not a delegate', () {
    final state = AppState.loading();

    expect(
      state,
      isA<ChangeNotifier>(),
      reason:
          'AppState should extend ChangeNotifier so each instance owns its '
          'own listener list',
    );
  });
}
