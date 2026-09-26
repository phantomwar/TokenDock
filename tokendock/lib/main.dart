import 'dart:io';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/app_state.dart';
import 'app/tray_controller.dart';
import 'app/window_controller.dart';
import 'providers/antigravity/antigravity_local.dart';
import 'providers/provider_registry.dart';
import 'storage/database.dart';
import 'storage/secure_secret_store.dart';
import 'ui/boot_failure.dart';
import 'ui/maintenance.dart';
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

  // A failure here used to escape `main` before `runApp`, killing the process
  // with no window and no message (plan A.5). The cause is logged, never shown:
  // a raw exception can carry SQL or a file path.
  final AppDatabase? database = await openOrSurface<AppDatabase?>(
    open: AppDatabase.open,
    surface: (error) {
      debugPrint('TokenDock: database open failed: $error');
      return null;
    },
  );

  if (database == null) {
    runApp(
      BootFailureApp(
        onRetry: () async {
          await _relaunch();
        },
        onExit: () async {
          await windowManager.destroy();
        },
      ),
    );
    return;
  }

  final secretStore = SecureSecretStore();
  final antigravityLocalRuntime = AntigravityLocalRuntimeConfig();
  final appState = AppState(
    connectionRepository: database.connectionRepository,
    connectionHealthRepository: database.connectionHealthRepository,
    quotaCacheRepository: database.quotaCacheRepository,
    secretStore: secretStore,
    settingsRepository: database.settingsRepository,
    providerRegistry: ProviderRegistry(
      secretStore: secretStore,
      antigravityLocalRuntime: antigravityLocalRuntime,
    ),
    antigravityLocalRuntime: antigravityLocalRuntime,
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

  runApp(
    TokenDockApp(
      appState: appState,
      windowController: windowController,
      navigatorKey: navigatorKey,
    ),
  );
}

/// Restarts the process.
///
/// Retrying the open in place would keep a half-initialised window manager, tray
/// icon and plugin set alive from the failed attempt, and the file handle that
/// caused the failure is the sort of thing a clean process lets go of. A
/// relaunch is the honest retry.
Future<void> _relaunch() async {
  await windowManager.destroy();
  final executable = File(Platform.resolvedExecutable).path;
  Process.run(executable, const <String>[], runInShell: false);
  exit(0);
}
