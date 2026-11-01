import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_navigation.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';

void main() {
  testWidgets('unresolved initial route keeps the full app visible', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final route = ValueNotifier<String>('');
    addTearDown(controller.dispose);
    addTearDown(route.dispose);

    await _pumpShell(tester, route, controller);

    expect(controller.mode, DesktopWindowMode.app);
    expect(controller.petVisible, isFalse);
    expect(gateway.petAttempts, 0);

    route.value = AppRouteCatalog.home;
    await tester.pumpAndSettle();

    expect(controller.mode, DesktopWindowMode.pet);
    expect(gateway.petAttempts, 1);
  });

  testWidgets('login route always restores the full app window', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final route = ValueNotifier<String>('/home');
    addTearDown(controller.dispose);
    addTearDown(route.dispose);

    await _pumpShell(tester, route, controller);
    expect(controller.mode, DesktopWindowMode.pet);

    route.value = '/login';
    await tester.pumpAndSettle();

    expect(controller.mode, DesktopWindowMode.app);
    expect(gateway.calls, containsAllInOrder(<String>['pet', 'app']));

    route.value = '/home';
    await tester.pumpAndSettle();
    expect(controller.mode, DesktopWindowMode.pet);
  });

  testWidgets('standby route always restores the full app window', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final route = ValueNotifier<String>(AppRouteCatalog.home);
    addTearDown(controller.dispose);
    addTearDown(route.dispose);

    await _pumpShell(tester, route, controller);
    expect(controller.mode, DesktopWindowMode.pet);

    route.value = AppRouteCatalog.accountStandby;
    await tester.pumpAndSettle();

    expect(controller.mode, DesktopWindowMode.app);
    expect(gateway.calls, containsAllInOrder(<String>['pet', 'app']));
  });

  testWidgets('failed automatic pet transition can retry on a later route', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway(failedPetAttempts: 1);
    final controller = DesktopWindowModeController(gateway: gateway);
    final route = ValueNotifier<String>('/home');
    addTearDown(controller.dispose);
    addTearDown(route.dispose);

    await _pumpShell(tester, route, controller);
    expect(controller.mode, DesktopWindowMode.app);
    expect(gateway.petAttempts, 1);

    route.value = '/settings';
    await tester.pumpAndSettle();

    expect(gateway.petAttempts, 2);
    expect(controller.mode, DesktopWindowMode.pet);
  });

  testWidgets('GoRouter login notification restores the full app window', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway();
    final controller = DesktopWindowModeController(gateway: gateway);
    final router = GoRouter(
      initialLocation: '/home',
      routes: <RouteBase>[
        GoRoute(path: '/home', builder: (_, _) => const SizedBox.expand()),
        GoRoute(path: '/login', builder: (_, _) => const SizedBox.expand()),
      ],
    );
    addTearDown(controller.dispose);
    addTearDown(router.dispose);
    appNavigation.configure(router);

    await tester.pumpWidget(
      MaterialApp.router(
        routerConfig: router,
        builder: (_, child) => DesktopCompanionShell(
          windowController: controller,
          child: child ?? const SizedBox.shrink(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(controller.mode, DesktopWindowMode.pet);

    router.go('/login');
    await tester.pumpAndSettle();

    expect(controller.mode, DesktopWindowMode.app);
  });

  testWidgets('failed login app transition waits for a later notification', (
    tester,
  ) async {
    final gateway = _FakeDesktopWindowGateway(failedAppAttempts: 1);
    final controller = DesktopWindowModeController(gateway: gateway);
    final route = ValueNotifier<String>('/home');
    addTearDown(controller.dispose);
    addTearDown(route.dispose);
    await _pumpShell(tester, route, controller);

    route.value = '/login';
    await tester.pumpAndSettle();
    expect(controller.mode, DesktopWindowMode.pet);
    expect(gateway.appAttempts, 1);

    await tester.pump(const Duration(milliseconds: 100));
    expect(gateway.appAttempts, 1);

    route.value = '/login?retry=1';
    await tester.pumpAndSettle();
    expect(gateway.appAttempts, 2);
    expect(controller.mode, DesktopWindowMode.app);
  });
}

Future<void> _pumpShell(
  WidgetTester tester,
  ValueNotifier<String> route,
  DesktopWindowModeController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: DesktopCompanionShell(
        windowController: controller,
        routeListenable: route,
        currentRoute: () => route.value,
        child: const SizedBox.shrink(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _FakeDesktopWindowGateway implements DesktopWindowGateway {
  _FakeDesktopWindowGateway({
    this.failedPetAttempts = 0,
    this.failedAppAttempts = 0,
  });

  final int failedPetAttempts;
  final int failedAppAttempts;
  final List<String> calls = <String>[];
  int petAttempts = 0;
  int appAttempts = 0;

  @override
  bool get isSupported => true;

  @override
  Future<DesktopWindowBounds> readBounds() async =>
      const DesktopWindowBounds(left: 20, top: 20, width: 1000, height: 700);

  @override
  Future<void> enterPetMode() async {
    calls.add('pet');
    petAttempts++;
    if (petAttempts <= failedPetAttempts) {
      throw StateError('pet transition failed');
    }
  }

  @override
  Future<void> enterAppMode({DesktopWindowBounds? restoreBounds}) async {
    calls.add('app');
    appAttempts++;
    if (appAttempts <= failedAppAttempts) {
      throw StateError('app transition failed');
    }
  }

  @override
  Future<void> startDragging() async {}
}
