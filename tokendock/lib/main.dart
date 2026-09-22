import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'app/tray_controller.dart';
import 'app/window_controller.dart';

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

  final windowController = WindowController();
  final trayController = TrayController(windowController);
  windowController.onExit = trayController.dispose;
  await trayController.init();

  runApp(const TokenDockApp());
}
