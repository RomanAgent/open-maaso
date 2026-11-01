import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';

void main() {
  setUp(() async => appServices.reset());
  tearDown(() async => appServices.reset());

  for (final platform in AppHostPlatform.values) {
    final desktop = {
      AppHostPlatform.macos,
      AppHostPlatform.windows,
      AppHostPlatform.linux,
    }.contains(platform);
    testWidgets('legacy chat entry resolves correctly on ${platform.name}', (
      tester,
    ) async {
      var secondaryChatBuilds = 0;
      final router = createAppRouter(
        initialLocation: AppRoutes.u2aChat,
        platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
        routesOverride: [
          GoRoute(
            path: AppRoutes.home,
            builder: (_, _) => const Text('Home chat'),
          ),
          GoRoute(
            path: AppRoutes.u2aChat,
            builder: (_, _) {
              secondaryChatBuilds++;
              return const Text('Secondary chat');
            },
          ),
        ],
      );
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      expect(
        appNavigation.currentRoute,
        desktop ? AppRoutes.home : AppRoutes.u2aChat,
      );
      expect(secondaryChatBuilds, desktop ? 0 : 1);
      expect(
        find.text(desktop ? 'Home chat' : 'Secondary chat'),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      router.dispose();
    });
  }

  testWidgets('tray chat and old chat links keep the current Home draft', (
    tester,
  ) async {
    var secondaryChatBuilds = 0;
    final router = createAppRouter(
      initialLocation: AppRoutes.home,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.macos,
      ),
      routesOverride: [
        GoRoute(
          path: AppRoutes.home,
          builder: (_, _) => const Scaffold(body: TextField()),
        ),
        GoRoute(
          path: AppRoutes.u2aChat,
          builder: (_, _) {
            secondaryChatBuilds++;
            return const Text('Secondary chat');
          },
        ),
      ],
    );
    final window = DesktopWindowModeController(
      gateway: const UnsupportedDesktopWindowGateway(),
    );
    final tray = DesktopCompanionTrayController(
      windowController: window,
      gateway: const UnsupportedDesktopCompanionTrayGateway(),
    );
    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Home draft');
    await tray.handleCommand(DesktopCompanionTrayCommand.openChat);
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRoutes.home);
    expect(find.text('Home draft'), findsOneWidget);
    router.go(AppRoutes.u2aChat);
    await tester.pumpAndSettle();
    expect(appNavigation.currentRoute, AppRoutes.home);
    expect(secondaryChatBuilds, 0);
    expect(find.text('Home draft'), findsOneWidget);
    expect(router.canPop(), isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await tray.dispose();
    window.dispose();
    router.dispose();
  });
}
