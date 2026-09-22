import 'package:flutter_test/flutter_test.dart';
import 'package:tokendock/app/window_controller.dart';

void main() {
  test('handleCloseRequest calls hide rather than quit', () async {
    var hideCalls = 0;
    var quitCalls = 0;
    final controller = WindowController.forTest(
      hide: () async {
        hideCalls++;
      },
      quit: () async {
        quitCalls++;
      },
    );

    await controller.handleCloseRequest();

    expect(hideCalls, 1);
    expect(quitCalls, 0);
    expect(controller.isExplicitExit, isFalse);
  });

  test('exitApplication calls quit', () async {
    var quitCalls = 0;
    var exitHookCalls = 0;
    final controller = WindowController.forTest(
      quit: () async {
        quitCalls++;
      },
      onExit: () {
        exitHookCalls++;
      },
    );

    await controller.exitApplication();

    expect(quitCalls, 1);
    expect(exitHookCalls, 1);
    expect(controller.isExplicitExit, isTrue);
  });

  test('showWidget calls show', () async {
    var showCalls = 0;
    final controller = WindowController.forTest(
      show: () async {
        showCalls++;
      },
    );

    await controller.showWidget();

    expect(showCalls, 1);
  });

  test('setAlwaysOnTop updates the state and calls the setter', () async {
    final setterCalls = <bool>[];
    final controller = WindowController.forTest(
      setAlwaysOnTop: (value) async {
        setterCalls.add(value);
      },
    );

    expect(controller.isAlwaysOnTop, isTrue);

    await controller.setAlwaysOnTop(false);

    expect(controller.isAlwaysOnTop, isFalse);
    expect(setterCalls, [false]);

    await controller.setAlwaysOnTop(true);

    expect(controller.isAlwaysOnTop, isTrue);
    expect(setterCalls, [false, true]);
  });
}
