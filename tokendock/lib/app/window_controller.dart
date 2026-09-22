import 'package:window_manager/window_manager.dart';

/// Controls the native app window: show/hide, always-on-top, close-to-tray.
///
/// Production instances delegate to `windowManager` and register as a
/// [WindowListener] so a native close request hides the window to the tray
/// instead of quitting. Unit tests use [WindowController.forTest], which
/// never touches the real OS window.
class WindowController with WindowListener {
  /// Production controller bound to the real native window.
  WindowController({this.onExit}) {
    _show = () async {
      await windowManager.show();
      await windowManager.focus();
    };
    _hide = windowManager.hide;
    _setAlwaysOnTopDelegate = windowManager.setAlwaysOnTop;
    _quit = windowManager.destroy;
    windowManager.addListener(this);
  }

  /// Test controller with injectable native behavior.
  WindowController.forTest({
    Future<void> Function()? show,
    Future<void> Function()? hide,
    Future<void> Function(bool)? setAlwaysOnTop,
    Future<void> Function()? quit,
    this.onExit,
  }) {
    _show = show ?? () async {};
    _hide = hide ?? () async {};
    _setAlwaysOnTopDelegate = setAlwaysOnTop ?? (_) async {};
    _quit = quit ?? () async {};
  }

  /// Runs during [exitApplication] before the window is destroyed so the
  /// tray icon can be cleaned up first. Wired to `TrayController.dispose`.
  void Function()? onExit;

  late final Future<void> Function() _show;
  late final Future<void> Function() _hide;
  late final Future<void> Function(bool) _setAlwaysOnTopDelegate;
  late final Future<void> Function() _quit;

  bool _isAlwaysOnTop = true;
  bool _isExplicitExit = false;

  /// Current always-on-top state. Defaults to true to match the frameless
  /// [WindowOptions] applied in `main`.
  bool get isAlwaysOnTop => _isAlwaysOnTop;

  /// True once [exitApplication] has run.
  bool get isExplicitExit => _isExplicitExit;

  /// Shows and focuses the native window.
  Future<void> showWidget() => _show();

  /// Hides the native window (hide-to-tray).
  Future<void> hideWidget() => _hide();

  /// Updates always-on-top state and applies it to the native window.
  Future<void> setAlwaysOnTop(bool isAlwaysOnTop) async {
    _isAlwaysOnTop = isAlwaysOnTop;
    await _setAlwaysOnTopDelegate(isAlwaysOnTop);
  }

  /// Hides to the tray instead of quitting. Invoked on native close requests.
  Future<void> handleCloseRequest() => hideWidget();

  /// Marks an explicit exit, runs tray cleanup, then destroys the window.
  Future<void> exitApplication() async {
    _isExplicitExit = true;
    onExit?.call();
    await _quit();
  }

  @override
  void onWindowClose() {
    handleCloseRequest();
  }
}
