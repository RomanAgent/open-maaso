import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:maaso/src/desktop/application/desktop_application_exit_coordinator.dart';
import 'package:maaso/src/desktop/infrastructure/tray_manager_desktop_companion_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'native Quit waits for teardown and shares one attempt with tray Quit',
    () async {
      final drained = Completer<void>();
      var attempts = 0;
      final coordinator = DesktopApplicationExitCoordinator(
        prepareForExit: () {
          attempts++;
          return drained.future;
        },
      );
      WidgetsBinding.instance.addObserver(coordinator);
      addTearDown(() => WidgetsBinding.instance.removeObserver(coordinator));
      var exited = false;
      final nativeExit = WidgetsBinding.instance.handleRequestAppExit().then((
        value,
      ) {
        exited = true;
        return value;
      });
      final trayExit = coordinator.prepare();
      await Future<void>.delayed(Duration.zero);
      expect(attempts, 1);
      expect(exited, isFalse);
      drained.complete();
      expect(await nativeExit, AppExitResponse.exit);
      await trayExit;
      await coordinator.prepare();
      expect(attempts, 1);
    },
  );

  test('failed release permits explicit Quit and reports failure', () async {
    final failure = StateError('offline');
    final failures = <Object>[];
    final coordinator = DesktopApplicationExitCoordinator(
      prepareForExit: () async => throw failure,
      onPreparationFailure: failures.add,
    );
    expect(await coordinator.didRequestAppExit(), AppExitResponse.exit);
    expect(failures, [failure]);
  });

  test('stalled teardown cannot block Quit indefinitely', () async {
    final drained = Completer<void>();
    final failures = <Object>[];
    final coordinator = DesktopApplicationExitCoordinator(
      prepareForExit: () => drained.future,
      timeout: const Duration(milliseconds: 20),
      onPreparationFailure: failures.add,
    );
    expect(await coordinator.didRequestAppExit(), AppExitResponse.exit);
    expect(failures.single, isA<TimeoutException>());
    // A late completion is still observed, never a second teardown attempt.
    drained.complete();
    await coordinator.prepare();
    expect(failures, hasLength(1));
  });

  test(
    'hides UI before teardown and publishes one terminal exit intent',
    () async {
      final hidden = Completer<void>();
      final drained = Completer<void>();
      final events = <String>[];
      late final DesktopApplicationExitCoordinator coordinator;
      Future<void>? reentrant;
      coordinator = DesktopApplicationExitCoordinator(
        dismissUiBeforeExit: () {
          expect(coordinator.isExiting, isTrue);
          reentrant = coordinator.prepare();
          events.add('hide');
          return hidden.future;
        },
        prepareForExit: () {
          events.add('drain');
          return drained.future;
        },
      );
      expect(coordinator.isExiting, isFalse);
      final preparation = coordinator.prepare();
      final nativeQuit = coordinator.didRequestAppExit();
      expect(identical(preparation, reentrant), isTrue);
      expect(events, ['hide']);
      hidden.complete();
      await Future<void>.delayed(Duration.zero);
      expect(events, ['hide', 'drain']);
      drained.complete();
      await preparation;
      expect(await nativeQuit, AppExitResponse.exit);
      await coordinator.prepare();
      expect(coordinator.isExiting, isTrue);
      expect(events, ['hide', 'drain']);
    },
  );

  test(
    'failed UI dismissal still releases the account before exiting',
    () async {
      final failure = StateError('window bridge unavailable');
      final failures = <Object>[];
      var releases = 0;
      final coordinator = DesktopApplicationExitCoordinator(
        dismissUiBeforeExit: () async => throw failure,
        prepareForExit: () async {
          releases++;
        },
        onPreparationFailure: failures.add,
      );
      expect(await coordinator.didRequestAppExit(), AppExitResponse.exit);
      expect(releases, 1);
      expect(failures, [failure]);
    },
  );

  test(
    'stalled UI dismissal cannot skip or indefinitely delay cleanup',
    () async {
      final hidden = Completer<void>();
      final failures = <Object>[];
      var releases = 0;
      final coordinator = DesktopApplicationExitCoordinator(
        dismissUiBeforeExit: () => hidden.future,
        dismissalTimeout: const Duration(milliseconds: 20),
        prepareForExit: () async {
          releases++;
        },
        onPreparationFailure: failures.add,
      );
      expect(await coordinator.didRequestAppExit(), AppExitResponse.exit);
      expect(releases, 1);
      expect(failures.single, isA<TimeoutException>());
      hidden.complete();
      await coordinator.prepare();
      expect(releases, 1);
    },
  );

  test(
    'native Quit suppresses tray and show callbacks during cleanup',
    () async {
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in ['window_manager', 'tray_manager']) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), (
          call,
        ) async {
          calls.add('$channel.${call.method}');
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(MethodChannel(channel), null),
        );
      }
      final drained = Completer<void>();
      final coordinator = DesktopApplicationExitCoordinator(
        prepareForExit: () => drained.future,
      );
      final gateway = TrayManagerDesktopCompanionGateway(
        exitCoordinator: coordinator,
      );
      var callbacks = 0;
      await gateway.initialize(
        onIconActivated: () async {
          callbacks++;
        },
        onWindowCloseRequested: () async {
          callbacks++;
        },
        onCommand: (_) async {
          callbacks++;
        },
      );
      addTearDown(gateway.dispose);
      calls.clear();
      final quit = coordinator.didRequestAppExit();
      await gateway.showAndFocus();
      gateway.onWindowClose();
      gateway.onTrayIconMouseDown();
      gateway.onTrayIconRightMouseDown();
      gateway.onTrayMenuItemClick(MenuItem(key: 'show-app', label: 'Show app'));
      await Future<void>.delayed(Duration.zero);
      expect(calls, isEmpty);
      expect(callbacks, 0);
      drained.complete();
      expect(await quit, AppExitResponse.exit);
    },
  );

  test('a late show completion cannot focus the window after Quit', () async {
    final shown = Completer<void>();
    final calls = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (
      call,
    ) async {
      calls.add(call.method);
      if (call.method == 'isMinimized') return false;
      if (call.method == 'show') await shown.future;
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      ),
    );
    final coordinator = DesktopApplicationExitCoordinator(
      prepareForExit: () async {},
    );
    final gateway = TrayManagerDesktopCompanionGateway(
      exitCoordinator: coordinator,
    );
    final showing = gateway.showAndFocus();
    await Future<void>.delayed(Duration.zero);
    expect(calls, ['isMinimized', 'show']);
    await coordinator.didRequestAppExit();
    shown.complete();
    await showing;
    expect(calls, ['isMinimized', 'show']);
  });

  test(
    'tray destroys native windows only after fenced teardown completes',
    () async {
      final nativeCalls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in ['window_manager', 'tray_manager']) {
        messenger.setMockMethodCallHandler(MethodChannel(channel), (
          call,
        ) async {
          nativeCalls.add('$channel.${call.method}');
          return null;
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(MethodChannel(channel), null),
        );
      }
      final drained = Completer<void>();
      final gateway = TrayManagerDesktopCompanionGateway(
        exitCoordinator: DesktopApplicationExitCoordinator(
          prepareForExit: () => drained.future,
        ),
      );
      final exit = gateway.quit();
      await Future<void>.delayed(Duration.zero);
      expect(nativeCalls, isEmpty);
      drained.complete();
      await exit;
      expect(nativeCalls, [
        'window_manager.setPreventClose',
        'tray_manager.destroy',
        'window_manager.destroy',
      ]);
      await gateway.quit();
      expect(nativeCalls, hasLength(3));
    },
  );

  test(
    'gateway wires native Quit but keeps red-window close separate',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      for (final channel in ['window_manager', 'tray_manager']) {
        messenger.setMockMethodCallHandler(
          MethodChannel(channel),
          (_) async => null,
        );
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(MethodChannel(channel), null),
        );
      }
      var prepared = 0;
      var windowCloses = 0;
      final gateway = TrayManagerDesktopCompanionGateway(
        exitCoordinator: DesktopApplicationExitCoordinator(
          prepareForExit: () async {
            prepared++;
          },
        ),
      );
      await gateway.initialize(
        onIconActivated: () async {},
        onWindowCloseRequested: () async {
          windowCloses++;
        },
        onCommand: (_) async {},
      );
      addTearDown(gateway.dispose);
      gateway.onWindowClose();
      await Future<void>.delayed(Duration.zero);
      expect(windowCloses, 1);
      expect(prepared, 0);
      expect(
        await WidgetsBinding.instance.handleRequestAppExit(),
        AppExitResponse.exit,
      );
      expect(prepared, 1);
    },
  );
}
