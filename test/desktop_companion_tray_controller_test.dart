import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';

void main() {
  test(
    'closing Mac chat hides the app and leaves its ready pet visible',
    () async {
      final windowGateway = _FakeIndependentWindowGateway();
      final controller = DesktopWindowModeController(gateway: windowGateway);
      addTearDown(controller.dispose);
      final trayGateway = _FakeTrayGateway();
      final tray = DesktopCompanionTrayController(
        windowController: controller,
        gateway: trayGateway,
        requestShowPet: controller.showIndependentPet,
      );
      await controller.showIndependentPet();
      expect(controller.mode, DesktopWindowMode.app);
      await tray.handleWindowCloseRequested();
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);
      expect(windowGateway.calls, isEmpty);
      expect(trayGateway.calls, ['hide']);
    },
  );

  test('closing the full app shrinks it into desktop pet mode', () async {
    final windowGateway = _FakeWindowGateway();
    final windowController = DesktopWindowModeController(
      gateway: windowGateway,
    );
    final trayGateway = _FakeTrayGateway();
    final trayController = DesktopCompanionTrayController(
      windowController: windowController,
      gateway: trayGateway,
    );

    await trayController.initialize();
    await trayGateway.onWindowCloseRequested!();

    expect(windowController.mode, DesktopWindowMode.pet);
    expect(windowGateway.calls, contains('enterPetMode'));
    expect(trayGateway.calls, isNot(contains('hide')));
  });

  test('closing an already compact pet hides it without quitting', () async {
    final windowController = DesktopWindowModeController(
      gateway: _FakeWindowGateway(),
    );
    final trayGateway = _FakeTrayGateway();
    final trayController = DesktopCompanionTrayController(
      windowController: windowController,
      gateway: trayGateway,
    );
    await windowController.enterPetMode();

    await trayController.handleWindowCloseRequested();

    expect(trayGateway.calls, contains('hide'));
    expect(trayGateway.calls, isNot(contains('quit')));
  });

  test(
    'tray commands switch modes, reveal the window, and explicitly quit',
    () async {
      final windowController = DesktopWindowModeController(
        gateway: _FakeWindowGateway(),
      );
      final trayGateway = _FakeTrayGateway();
      final trayController = DesktopCompanionTrayController(
        windowController: windowController,
        gateway: trayGateway,
      );

      await trayController.handleCommand(DesktopCompanionTrayCommand.showPet);
      await trayController.handleCommand(DesktopCompanionTrayCommand.showApp);
      await trayController.handleCommand(DesktopCompanionTrayCommand.quit);

      expect(windowController.mode, DesktopWindowMode.app);
      expect(trayGateway.calls, <String>[
        'showAndFocus',
        'showAndFocus',
        'quit',
      ]);
    },
  );

  test(
    'independent tray summons the pet without reopening the app window',
    () async {
      final windowController = DesktopWindowModeController(
        gateway: _FakeIndependentWindowGateway(),
      );
      final trayGateway = _FakeTrayGateway();
      final trayController = DesktopCompanionTrayController(
        windowController: windowController,
        gateway: trayGateway,
      );

      await trayController.handleIconActivated();

      expect(windowController.mode, DesktopWindowMode.pet);
      expect(windowController.petVisible, isTrue);
      expect(trayGateway.calls, isNot(contains('showAndFocus')));

      await trayController.handleCommand(DesktopCompanionTrayCommand.showApp);
      expect(windowController.mode, DesktopWindowMode.app);
      expect(windowController.petVisible, isTrue);
    },
  );

  test('tray cannot hide authentication behind an unavailable pet', () async {
    final windowController = DesktopWindowModeController(
      gateway: _FakeIndependentWindowGateway(),
    );
    final trayGateway = _FakeTrayGateway();
    final trayController = DesktopCompanionTrayController(
      windowController: windowController,
      gateway: trayGateway,
      canShowPet: () => false,
    );

    await trayController.handleIconActivated();
    await trayController.handleCommand(DesktopCompanionTrayCommand.showPet);

    expect(windowController.mode, DesktopWindowMode.app);
    expect(windowController.petVisible, isFalse);
    expect(trayGateway.calls, <String>['showAndFocus', 'showAndFocus']);
  });

  test(
    'closing authentication hides chat without presenting an absent pet',
    () async {
      final windowController = DesktopWindowModeController(
        gateway: _FakeIndependentWindowGateway(),
      );
      final trayGateway = _FakeTrayGateway();
      final trayController = DesktopCompanionTrayController(
        windowController: windowController,
        gateway: trayGateway,
        canShowPet: () => false,
      );

      await trayController.handleWindowCloseRequested();

      expect(windowController.mode, DesktopWindowMode.app);
      expect(windowController.petVisible, isFalse);
      expect(trayGateway.calls, <String>['hide']);
    },
  );

  test('every independent pet summon uses the readiness gate', () async {
    final windowController = DesktopWindowModeController(
      gateway: _FakeIndependentWindowGateway(),
    );
    final trayGateway = _FakeTrayGateway();
    var readinessRequests = 0;
    final trayController = DesktopCompanionTrayController(
      windowController: windowController,
      gateway: trayGateway,
      requestShowPet: () async {
        readinessRequests += 1;
      },
    );

    await trayController.handleIconActivated();
    await trayController.handleWindowCloseRequested();
    await trayController.handleCommand(DesktopCompanionTrayCommand.showPet);

    expect(readinessRequests, 2);
    expect(windowController.mode, DesktopWindowMode.app);
    expect(windowController.petVisible, isFalse);
    expect(trayGateway.calls, isNot(contains('showAndFocus')));
  });

  test('independent close never waits for a failing pet summon', () async {
    final windowGateway = _FakeIndependentWindowGateway();
    final windowController = DesktopWindowModeController(
      gateway: windowGateway,
    );
    addTearDown(windowController.dispose);
    final trayGateway = _FakeTrayGateway();
    var attempts = 0;
    final tray = DesktopCompanionTrayController(
      windowController: windowController,
      gateway: trayGateway,
      requestShowPet: () async {
        attempts++;
        throw StateError('sidecar unavailable');
      },
    );

    await tray.handleWindowCloseRequested();

    expect(attempts, 0);
    expect(trayGateway.calls, ['hide']);
    expect(windowGateway.calls, isEmpty);
    expect(windowController.petVisible, isFalse);
  });
}

class _FakeWindowGateway implements DesktopWindowGateway {
  final List<String> calls = <String>[];

  @override
  bool get isSupported => true;

  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);

  @override
  Future<void> enterPetMode() async {
    calls.add('enterPetMode');
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {
    calls.add('enterAppMode');
  }

  @override
  Future<void> startDragging() async {}
}

class _FakeIndependentWindowGateway extends _FakeWindowGateway
    implements IndependentDesktopPetWindowGateway {
  @override
  bool get supportsIndependentPetWindow => true;
}

class _FakeTrayGateway implements DesktopCompanionTrayGateway {
  final List<String> calls = <String>[];
  Future<void> Function()? onIconActivated;
  Future<void> Function()? onWindowCloseRequested;
  Future<void> Function(DesktopCompanionTrayCommand command)? onCommand;

  @override
  Future<void> initialize({
    required Future<void> Function() onIconActivated,
    required Future<void> Function() onWindowCloseRequested,
    required Future<void> Function(DesktopCompanionTrayCommand command)
    onCommand,
  }) async {
    this.onIconActivated = onIconActivated;
    this.onWindowCloseRequested = onWindowCloseRequested;
    this.onCommand = onCommand;
  }

  @override
  Future<void> showAndFocus() async {
    calls.add('showAndFocus');
  }

  @override
  Future<void> hide() async {
    calls.add('hide');
  }

  @override
  Future<void> quit() async {
    calls.add('quit');
  }

  @override
  Future<void> dispose() async {
    calls.add('dispose');
  }
}
