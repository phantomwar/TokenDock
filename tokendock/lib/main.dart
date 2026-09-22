import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/app_state.dart';
import 'app/tray_controller.dart';
import 'app/window_controller.dart';
import 'providers/provider_registry.dart';
import 'storage/database.dart';
import 'storage/secure_secret_store.dart';
import 'ui/settings/connections_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  const windowOptions = WindowOptions(
    size: Size(360, 600),
    minimumSize: Size(300, 400),
    maximumSize: Size(800, 900),
    center: true,
    titleBarStyle: TitleBarStyle.hidden,
    alwaysOnTop: true,
    skipTaskbar: false,
  );
  await windowManager.waitUntilReadyToShow(windowOptions, () async {
    await windowManager.show();
    await windowManager.focus();
  });
  await windowManager.setPreventClose(true);

  final db = await AppDatabase.open();
  final appState = AppState(
    connectionRepository: db.connectionRepository,
    quotaCacheRepository: db.quotaCacheRepository,
    secretStore: const SecureSecretStore(),
    settingsRepository: db.settingsRepository,
    providerRegistry: ProviderRegistry.instance,
    autoStartRefreshTimer: true,
  );

  final windowController = WindowController();
  final navigatorKey = GlobalKey<NavigatorState>();

  final trayController = TrayController(
    windowController,
    onRefreshAll: () => appState.refreshAll(),
    onConnections: () async {
      await windowController.showWidget();
      navigatorKey.currentState?.push(
        MaterialPageRoute<void>(
          builder: (_) => ConnectionsScreen(appState: appState),
        ),
      );
    },
  );
  windowController.onExit = trayController.dispose;
  await trayController.init();

  appState.load().then((_) => appState.refreshAll());

  runApp(TokenDockApp(
    appState: appState,
    windowController: windowController,
    navigatorKey: navigatorKey,
  ));
}
