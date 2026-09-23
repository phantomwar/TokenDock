import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_state.dart';
import 'theme.dart';
import 'window_controller.dart';
import '../ui/settings/connections_screen.dart';
import '../ui/widget/token_dock_widget.dart';

/// Intent to trigger a quota refresh across all enabled accounts.
class RefreshIntent extends Intent {
  const RefreshIntent();
}

/// Action invoked on [RefreshIntent] (Ctrl+R / Cmd+R).
///
/// Disabled while an [EditableText] has primary focus so text fields can
/// receive normal typing and editing key events without triggering network
/// refreshes.
class RefreshAction extends Action<RefreshIntent> {
  RefreshAction(this.onRefresh);

  final VoidCallback onRefresh;

  @override
  bool isEnabled(RefreshIntent intent) {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return true;
    final context = focus.context;
    if (context == null) return true;
    if (context.widget is EditableText ||
        context.findAncestorWidgetOfExactType<EditableText>() != null ||
        context.findAncestorStateOfType<EditableTextState>() != null) {
      return false;
    }
    return true;
  }

  @override
  Object? invoke(RefreshIntent intent) {
    if (!isEnabled(intent)) return null;
    onRefresh();
    return null;
  }
}

/// Root widget for the TokenDock application.
///
/// Binds light, dark, and high-contrast theme variants, establishes keyboard
/// shortcuts (such as Ctrl+R for refresh), and wires first-run and header
/// navigation to [ConnectionsScreen].
class TokenDockApp extends StatelessWidget {
  const TokenDockApp({
    super.key,
    this.appState,
    this.windowController,
    this.navigatorKey,
    this.child,
  });

  final AppState? appState;
  final WindowController? windowController;
  final GlobalKey<NavigatorState>? navigatorKey;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final effectiveState = appState ?? const AppState.loading();

    return MaterialApp(
      navigatorKey: navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: TokenDockTheme.lightTheme(),
      darkTheme: TokenDockTheme.darkTheme(),
      highContrastTheme: TokenDockTheme.highContrastTheme(),
      highContrastDarkTheme: TokenDockTheme.highContrastTheme(),
      home: _AppRootShell(
        state: effectiveState,
        child: child,
      ),
    );
  }
}

class _AppRootShell extends StatelessWidget {
  const _AppRootShell({
    required this.state,
    this.child,
  });

  final AppState state;
  final Widget? child;

  void _openConnections(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ConnectionsScreen(appState: state),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyR, control: true):
            RefreshIntent(),
        SingleActivator(LogicalKeyboardKey.keyR, meta: true):
            RefreshIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          RefreshIntent: RefreshAction(() => state.refreshAll()),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            body: child ??
                ListenableBuilder(
                  listenable: state,
                  builder: (context, _) {
                    return TokenDockWidget(
                      state: state,
                      onAddConnection: () => _openConnections(context),
                      onOpenConnections: () => _openConnections(context),
                      onRefreshAll: () => state.refreshAll(),
                    );
                  },
                ),
          ),
        ),
      ),
    );
  }
}
