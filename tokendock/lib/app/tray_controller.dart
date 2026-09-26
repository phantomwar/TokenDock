import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';

import 'window_controller.dart';

/// Builds the native tray icon and its context menu using the current
/// object-based `tray_manager` API (`TrayIcon` / `Menu` / `MenuItem`).
///
/// The constructor does no native work; call [init] once from `main` to
/// create the icon. Menu behavior is exposed as public `handle*` methods so
/// it stays verifiable without touching native handles.
class TrayController {
  TrayController(
    this._windowController, {
    this.onRefreshAll,
    this.onConnections,
    this.iconPath = 'assets/tray_icon.ico',
    this.tooltip = 'TokenDock',
    TrayIcon? Function()? trayIconFactory,
    Menu? Function()? menuFactory,
    MenuItem? Function(String label, MenuItemType type)? menuItemFactory,
  })  : _trayIconFactory = trayIconFactory ?? TrayIcon.create,
        _menuFactory = menuFactory ?? Menu.create,
        _menuItemFactory =
            menuItemFactory ?? MenuItem.createWithLabelAndType;

  final WindowController _windowController;

  /// Invoked when the user picks "Refresh All". `null` disables the item.
  final Future<void> Function()? onRefreshAll;

  /// Invoked when the user picks "Connections". `null` disables the item.
  final Future<void> Function()? onConnections;

  /// Flutter asset path of the tray icon, declared in `pubspec.yaml`.
  final String iconPath;

  /// Hover tooltip for the tray icon.
  final String tooltip;

  static const String openLabel = 'Open TokenDock';
  static const String refreshAllLabel = 'Refresh All';
  static const String alwaysOnTopLabel = 'Always on Top';
  static const String connectionsLabel = 'Connections';
  static const String exitLabel = 'Exit';

  final TrayIcon? Function() _trayIconFactory;
  final Menu? Function() _menuFactory;
  final MenuItem? Function(String label, MenuItemType type) _menuItemFactory;

  TrayIcon? _trayIcon;
  Menu? _menu;
  final List<MenuItem> _items = [];
  final Map<MenuItem, int> _itemListenerIds = {};
  int? _trayListenerId;
  MenuItem? _alwaysOnTopItem;
  bool _disposed = false;

  /// Menu labels in display order (`''` marks a separator). Pure Dart so the
  /// required ordering is verifiable without native handles.
  List<String> get menuLabels => [
        openLabel,
        refreshAllLabel,
        '',
        alwaysOnTopLabel,
        connectionsLabel,
        '',
        exitLabel,
      ];

  /// Creates the tray icon, builds the context menu, and shows the icon.
  Future<void> init() async {
    final trayIcon = _trayIconFactory();
    final menu = _menuFactory();
    if (trayIcon == null || menu == null) {
      debugPrint('TrayController: native tray unavailable, skipping init.');
      return;
    }
    _trayIcon = trayIcon;
    _menu = menu;

    trayIcon.icon = ImageAsset.fromAsset(iconPath);
    trayIcon.setTooltip(tooltip);
    trayIcon.setContextMenuTrigger(ContextMenuTrigger.rightClicked);

    _addItem(menu, openLabel, MenuItemType.normal, (_) => handleOpen());
    _addItem(menu, refreshAllLabel, MenuItemType.normal,
        (_) => handleRefreshAll());
    menu.addSeparator();
    _alwaysOnTopItem =
        _addItem(menu, alwaysOnTopLabel, MenuItemType.checkbox,
            (_) => handleToggleAlwaysOnTop());
    _syncAlwaysOnTopState();
    _addItem(menu, connectionsLabel, MenuItemType.normal,
        (_) => handleConnections());
    menu.addSeparator();
    _addItem(menu, exitLabel, MenuItemType.normal, (_) => handleExit());

    trayIcon.setContextMenu(menu);
    _trayListenerId = trayIcon.addListener((event) {
      if (event is TrayIconDoubleClickedEvent) {
        handleTrayDoubleClick();
      }
    });
    trayIcon.setVisible(true);
  }

  MenuItem? _addItem(
    Menu menu,
    String label,
    MenuItemType type,
    void Function(MenuItemClickedEvent event) onClicked,
  ) {
    final item = _menuItemFactory(label, type);
    if (item == null) return null;
    _items.add(item);
    _itemListenerIds[item] = item.addListener((event) {
      if (event is MenuItemClickedEvent) {
        onClicked(event);
      }
    });
    menu.addItem(item);
    return item;
  }

  /// Shows and focuses the app window.
  Future<void> handleOpen() => _windowController.showWidget();

  /// Double-click on the tray icon shows the window.
  Future<void> handleTrayDoubleClick() => _windowController.showWidget();

  /// Refresh hook; the real service lands in a later task.
  Future<void> handleRefreshAll() async {
    await onRefreshAll?.call();
  }

  /// Connections hook; the real UI lands in a later task.
  Future<void> handleConnections() async {
    await onConnections?.call();
  }

  /// Toggles always-on-top and reflects the new state on the checkbox item.
  Future<void> handleToggleAlwaysOnTop() async {
    await _windowController
        .setAlwaysOnTop(!_windowController.isAlwaysOnTop);
    _syncAlwaysOnTopState();
  }

  /// Quits the app via the window controller (runs tray cleanup first).
  Future<void> handleExit() => _windowController.exitApplication();

  void _syncAlwaysOnTopState() {
    _alwaysOnTopItem?.state = _windowController.isAlwaysOnTop
        ? MenuItemState.checked
        : MenuItemState.unchecked;
  }

  /// Removes listeners and releases native handles. Idempotent; safe to call
  /// from `WindowController.onExit` during shutdown.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    final trayIcon = _trayIcon;
    if (_trayListenerId != null && trayIcon != null) {
      trayIcon.removeListener(_trayListenerId!);
      _trayListenerId = null;
    }
    for (final item in _items) {
      final listenerId = _itemListenerIds[item];
      if (listenerId != null) {
        item.removeListener(listenerId);
      }
      item.dispose();
    }
    _itemListenerIds.clear();
    _items.clear();
    _alwaysOnTopItem = null;
    _menu?.dispose();
    _menu = null;
    trayIcon?.dispose();
    _trayIcon = null;
  }
}
