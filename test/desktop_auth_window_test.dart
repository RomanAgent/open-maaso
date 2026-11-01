import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_window_placement.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';

const _appBounds = DesktopWindowBounds(
  left: 100,
  top: 80,
  width: 1000,
  height: 760,
);
const _authBounds = DesktopWindowBounds(
  left: 523.5,
  top: 126,
  width: 393,
  height: 880,
);

void main() {
  test(
    'phone viewport includes native titlebar and centers on current display',
    () {
      const primary = DesktopWindowBounds(
        left: 0,
        top: 24,
        width: 1440,
        height: 1056,
      );
      const secondary = DesktopWindowBounds(
        left: -1920,
        top: 40,
        width: 1920,
        height: 1200,
      );
      final bounds = DesktopWindowPlacement.authBounds(
        current: const DesktopWindowBounds(
          left: -1700,
          top: 150,
          width: 1000,
          height: 760,
        ),
        visibleDisplays: const [primary, secondary],
        primaryDisplay: primary,
        titleBarHeight: 28,
      );
      expect(bounds.width, 393);
      expect(bounds.height - 28, 852);
      expect(bounds.left + bounds.width / 2, -960);
      expect(bounds.top + bounds.height / 2, 640);
    },
  );

  test('small work area keeps the complete phone viewport on screen', () {
    const display = DesktopWindowBounds(
      left: 10,
      top: 30,
      width: 900,
      height: 680,
    );
    final bounds = DesktopWindowPlacement.authBounds(
      current: _appBounds,
      visibleDisplays: const [display],
      primaryDisplay: display,
      titleBarHeight: 28,
    );
    expect(bounds.height, 656);
    expect(bounds.width / (bounds.height - 28), closeTo(393 / 852, 0.00001));
    expect(bounds.top, 42);
    expect(bounds.top + bounds.height, 698);
    expect(bounds.left, greaterThan(display.left));
  });

  test('normal window restores on its original secondary display', () {
    const secondary = DesktopWindowBounds(
      left: 1440,
      top: 0,
      width: 1920,
      height: 1080,
    );
    const requested = DesktopWindowBounds(
      left: 1500,
      top: 80,
      width: 1000,
      height: 760,
    );
    expect(
      DesktopWindowPlacement.appBounds(
        requested: requested,
        visibleDisplays: const [secondary],
        primaryDisplay: const DesktopWindowBounds(
          left: 0,
          top: 24,
          width: 1440,
          height: 876,
        ),
      ),
      requested,
    );
  });

  test(
    'auth sizing is idempotent and leaving restores exact normal bounds',
    () async {
      final gateway = _AuthGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      addTearDown(controller.dispose);
      await controller.showIndependentPet();
      await controller.setAuthenticationRoute(true);
      await controller.setAuthenticationRoute(true);
      expect(controller.authenticationRoute, isTrue);
      expect(controller.petVisible, isFalse);
      expect(gateway.bounds, _authBounds);
      expect(gateway.calls, ['readBounds', 'auth']);
      expect(controller.lastAppBounds, _appBounds);

      await controller.setAuthenticationRoute(false);
      expect(gateway.bounds, _appBounds);
      expect(controller.authenticationRoute, isFalse);
      expect(controller.mode, DesktopWindowMode.app);
      expect(gateway.calls, ['readBounds', 'auth', 'app']);
    },
  );

  test('login from hidden pet preserves saved app bounds', () async {
    final gateway = _AuthGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.enterPetMode();
    gateway.calls.clear();
    await controller.setAuthenticationRoute(true);
    await controller.setAuthenticationRoute(false);
    expect(gateway.calls, ['auth', 'app']);
    expect(gateway.bounds, _appBounds);
  });

  test(
    'tray reveal preserves active auth sizing through the doorway',
    () async {
      final gateway = _AuthGateway();
      final controller = DesktopWindowModeController(gateway: gateway);
      addTearDown(controller.dispose);
      final tray = DesktopCompanionTrayController(
        windowController: controller,
        gateway: const UnsupportedDesktopCompanionTrayGateway(),
        canShowPet: () => false,
      );
      await controller.setAuthenticationRoute(true);
      await tray.handleCommand(DesktopCompanionTrayCommand.showApp);
      await tray.handleIconActivated();
      expect(gateway.bounds, _authBounds);
      expect(controller.lastAppBounds, _appBounds);
      expect(controller.authenticationRoute, isTrue);
      expect(gateway.calls.where((call) => call == 'app'), isEmpty);
    },
  );

  test('rapid auth and Home requests are serialized', () async {
    final gate = Completer<void>();
    final gateway = _AuthGateway(authGate: gate);
    final controller = DesktopWindowModeController(gateway: gateway);
    addTearDown(controller.dispose);
    final login = controller.setAuthenticationRoute(true);
    await Future<void>.delayed(Duration.zero);
    final home = controller.setAuthenticationRoute(false);
    final loginAgain = controller.setAuthenticationRoute(true);
    expect(gateway.calls, ['readBounds', 'auth']);
    gate.complete();
    await Future.wait([login, home, loginAgain]);
    expect(gateway.calls, ['readBounds', 'auth', 'app', 'readBounds', 'auth']);
    expect(gateway.bounds, _authBounds);
    expect(controller.lastAppBounds, _appBounds);
    await controller.setAuthenticationRoute(false);
    expect(gateway.bounds, _appBounds);
  });

  test('failed auth resize restores app and can be retried', () async {
    final gateway = _AuthGateway()..failAuth = true;
    final controller = DesktopWindowModeController(gateway: gateway);
    addTearDown(controller.dispose);
    await expectLater(
      controller.setAuthenticationRoute(true),
      throwsStateError,
    );
    expect(gateway.bounds, _appBounds);
    expect(controller.authenticationRoute, isFalse);
    expect(controller.isTransitioning, isFalse);
    gateway.failAuth = false;
    await controller.setAuthenticationRoute(true);
    await controller.setAuthenticationRoute(false);
    expect(gateway.bounds, _appBounds);
  });

  testWidgets('initial Login sizes once and Home restores after route exit', (
    tester,
  ) async {
    final gateway = _AuthGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final route = ValueNotifier('/login');
    addTearDown(controller.dispose);
    addTearDown(route.dispose);
    await tester.pumpWidget(_shell(controller, route));
    await tester.pumpAndSettle();
    expect(gateway.calls, ['readBounds', 'auth']);
    route.value = '/login?retry=1';
    await tester.pumpAndSettle();
    expect(gateway.calls, ['readBounds', 'auth']);
    route.value = '/home';
    await tester.pumpAndSettle();
    expect(gateway.bounds, _appBounds);
    expect(gateway.calls, ['readBounds', 'auth', 'app']);
    route.value = '/settings';
    await tester.pumpAndSettle();
    expect(gateway.calls, ['readBounds', 'auth', 'app']);
  });

  testWidgets(
    'Home redirect waits for an in-flight auth resize then restores',
    (tester) async {
      final gate = Completer<void>();
      final gateway = _AuthGateway(authGate: gate);
      final controller = DesktopWindowModeController(gateway: gateway);
      final route = ValueNotifier('/login');
      addTearDown(controller.dispose);
      addTearDown(route.dispose);
      await tester.pumpWidget(_shell(controller, route));
      await tester.pump();
      expect(gateway.calls, ['readBounds', 'auth']);
      route.value = '/home';
      await tester.pump();
      gate.complete();
      await tester.pumpAndSettle();
      expect(controller.authenticationRoute, isFalse);
      expect(gateway.bounds, _appBounds);
      expect(gateway.calls, ['readBounds', 'auth', 'app']);
    },
  );

  testWidgets('unsupported hosts leave Login usable without resize retries', (
    tester,
  ) async {
    final controller = DesktopWindowModeController(
      gateway: const UnsupportedDesktopWindowGateway(),
    );
    final route = ValueNotifier('/login');
    addTearDown(controller.dispose);
    addTearDown(route.dispose);
    await tester.pumpWidget(_shell(controller, route));
    await tester.pumpAndSettle();
    expect(find.text('Login content'), findsOneWidget);
    expect(controller.authenticationRoute, isFalse);
    expect(controller.mode, DesktopWindowMode.unsupported);
    route.value = '/home';
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Widget _shell(
  DesktopWindowModeController controller,
  ValueNotifier<String> route,
) => MaterialApp(
  home: DesktopCompanionShell(
    windowController: controller,
    autoEnterPetMode: false,
    routeListenable: route,
    currentRoute: () => route.value,
    hostGateway: const UnsupportedDesktopCompanionHostGateway(),
    child: const Text('Login content'),
  ),
);

class _AuthGateway
    implements
        DesktopWindowGateway,
        DesktopAuthWindowGateway,
        IndependentDesktopPetWindowGateway {
  _AuthGateway({this.authGate});

  final Completer<void>? authGate;
  final calls = <String>[];
  DesktopWindowBounds bounds = _appBounds;
  bool failAuth = false;

  @override
  bool get isSupported => true;

  @override
  bool get supportsIndependentPetWindow => true;

  @override
  Future<DesktopWindowBounds> readBounds() async {
    calls.add('readBounds');
    return bounds;
  }

  @override
  Future<void> enterAuthMode() async {
    calls.add('auth');
    await authGate?.future;
    bounds = _authBounds;
    if (failAuth) throw StateError('auth sizing failed');
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {
    calls.add('app');
    if (restoreBounds != null) bounds = restoreBounds;
  }

  @override
  Future<void> enterPetMode() async {
    calls.add('pet');
  }

  @override
  Future<void> startDragging() async {}
}
