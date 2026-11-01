import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';

void main() {
  test(
    'pet visibility intents preserve earlier queued window changes',
    () async {
      final gate = Completer<void>();
      final gateway = _BlockedIndependentWindowGateway(petGate: gate);
      final controller = DesktopWindowModeController(gateway: gateway);
      addTearDown(controller.dispose);
      final closing = controller.enterPetMode();
      await Future<void>.delayed(Duration.zero);
      final arriving = controller.showIndependentPet();
      gate.complete();
      await Future.wait([closing, arriving]);
      expect(controller.mode, DesktopWindowMode.pet);
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, ['readBounds', 'enterPetMode']);

      // These are queued while the controller still says pet. Visibility changes
      // must not undo the preceding request to reveal the chat window.
      final revealing = controller.revealAppMode();
      final hidingPet = controller.hidePet();
      final showingPet = controller.showIndependentPet();
      await Future.wait([revealing, hidingPet, showingPet]);
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);
      expect(
        gateway.calls.where((call) => call == 'enterPetMode'),
        hasLength(1),
      );
      expect(
        gateway.calls.where((call) => call.startsWith('enterAppMode')),
        hasLength(1),
      );
    },
  );

  test(
    'queued reveal preserves the latest independent pet visibility',
    () async {
      final controller = DesktopWindowModeController(
        gateway: _FakeIndependentDesktopWindowGateway(),
      );
      addTearDown(controller.dispose);
      await Future.wait([
        controller.showIndependentPet(),
        controller.enterAppMode(),
      ]);
      expect(controller.petVisible, isTrue);
      await Future.wait([controller.hidePet(), controller.revealAppMode()]);
      expect(controller.petVisible, isFalse);
    },
  );

  test(
    'showing an independent pet preserves the visible app bounds and focus',
    () async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      addTearDown(controller.dispose);
      await controller.showIndependentPet();
      await controller.showIndependentPet();
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, isEmpty);
      await controller.enterPetMode();
      gateway.calls.clear();
      await controller.hidePet();
      await controller.showIndependentPet();
      expect(controller.mode, DesktopWindowMode.pet);
      expect(controller.petVisible, isTrue);
      expect(gateway.calls, isEmpty);
    },
  );

  test('unsupported platforms never mutate the window', () async {
    final gateway = _FakeDesktopWindowGateway(isSupported: false);
    final controller = DesktopWindowModeController(gateway: gateway);

    await controller.enterPetMode();
    await controller.enterAppMode();

    expect(controller.mode, DesktopWindowMode.unsupported);
    expect(gateway.calls, isEmpty);
  });

  test('pet mode saves app bounds and app mode restores them', () async {
    const appBounds = DesktopWindowBounds(
      left: 80,
      top: 60,
      width: 1180,
      height: 760,
    );
    final gateway = _FakeDesktopWindowGateway(bounds: appBounds);
    final controller = DesktopWindowModeController(gateway: gateway);

    await controller.enterPetMode();
    await controller.enterAppMode();

    expect(controller.mode, DesktopWindowMode.app);
    expect(controller.lastAppBounds, appBounds);
    expect(gateway.calls, <String>[
      'readBounds',
      'enterPetMode',
      'enterAppMode:$appBounds',
    ]);
  });

  test('repeating the active mode is a no-op', () async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);

    await controller.enterPetMode();
    await controller.enterPetMode();

    expect(gateway.calls.where((call) => call == 'enterPetMode'), hasLength(1));
  });

  test('dragging is forwarded only while pet mode is active', () async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);

    await controller.startDragging();
    await controller.enterPetMode();
    await controller.startDragging();

    expect(
      gateway.calls.where((call) => call == 'startDragging'),
      hasLength(1),
    );
  });

  test('concurrent transitions are serialized in request order', () async {
    final petGate = Completer<void>();
    final gateway = _FakeDesktopWindowGateway(petGate: petGate);
    final controller = DesktopWindowModeController(gateway: gateway);

    final petTransition = controller.enterPetMode();
    final appTransition = controller.enterAppMode();
    await Future<void>.delayed(Duration.zero);

    expect(gateway.calls, <String>['readBounds', 'enterPetMode']);

    petGate.complete();
    await Future.wait(<Future<void>>[petTransition, appTransition]);

    expect(gateway.calls.last, startsWith('enterAppMode:'));
    expect(controller.mode, DesktopWindowMode.app);
  });

  test(
    'independent pet remains visible while the app window is open',
    () async {
      final gateway = _FakeIndependentDesktopWindowGateway();
      final controller = DesktopWindowModeController(gateway: gateway);

      await controller.enterPetMode();
      expect(controller.petVisible, isTrue);
      expect(controller.mode, DesktopWindowMode.pet);

      await controller.enterAppMode();
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isTrue);

      final appTransitions = gateway.calls
          .where((call) => call.startsWith('enterAppMode:'))
          .length;
      await controller.revealAppMode();
      expect(
        gateway.calls.where((call) => call.startsWith('enterAppMode:')).length,
        appTransitions + 1,
      );
      expect(controller.petVisible, isTrue);

      final callsBeforeHide = gateway.calls.length;
      await controller.hidePet();
      expect(controller.petVisible, isFalse);
      expect(gateway.calls, hasLength(callsBeforeHide));

      await controller.enterAuthMode();
      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.petVisible, isFalse);
      expect(gateway.calls.last, startsWith('enterAppMode:'));
    },
  );

  test(
    'failed transition restores the prior mode and clears busy state',
    () async {
      final gateway = _FakeDesktopWindowGateway(failPetMode: true);
      final controller = DesktopWindowModeController(gateway: gateway);

      await expectLater(controller.enterPetMode(), throwsStateError);

      expect(controller.mode, DesktopWindowMode.app);
      expect(controller.isTransitioning, isFalse);
      expect(gateway.calls.last, startsWith('enterAppMode:'));
    },
  );
}

class _FakeDesktopWindowGateway implements DesktopWindowGateway {
  _FakeDesktopWindowGateway({
    this.isSupported = true,
    this.bounds = const DesktopWindowBounds(
      left: 40,
      top: 30,
      width: 1000,
      height: 700,
    ),
    this.petGate,
    this.failPetMode = false,
  });

  @override
  final bool isSupported;
  DesktopWindowBounds bounds;
  final Completer<void>? petGate;
  final bool failPetMode;
  final List<String> calls = <String>[];

  @override
  Future<DesktopWindowBounds> readBounds() async {
    calls.add('readBounds');
    return bounds;
  }

  @override
  Future<void> enterPetMode() async {
    calls.add('enterPetMode');
    if (failPetMode) throw StateError('pet transition failed');
    await petGate?.future;
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {
    calls.add('enterAppMode:$restoreBounds');
    if (restoreBounds != null) bounds = restoreBounds;
  }

  @override
  Future<void> startDragging() async {
    calls.add('startDragging');
  }
}

class _FakeIndependentDesktopWindowGateway extends _FakeDesktopWindowGateway
    implements IndependentDesktopPetWindowGateway {
  @override
  bool get supportsIndependentPetWindow => true;
}

class _BlockedIndependentWindowGateway extends _FakeDesktopWindowGateway
    implements IndependentDesktopPetWindowGateway {
  _BlockedIndependentWindowGateway({super.petGate});

  @override
  bool get supportsIndependentPetWindow => true;
}
