import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_navigation.dart';

void main() {
  const backButtonKey = ValueKey<String>('secondary-back-button');

  for (final platform in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.windows,
  ]) {
    testWidgets('${platform.name} top-level secondary route returns to Home', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        final navigation = AppNavigation();
        final router = _testRouter(
          initialLocation: AppRouteCatalog.settings,
          navigation: navigation,
          backButtonKey: backButtonKey,
        );
        addTearDown(router.dispose);
        navigation.configure(router);

        await tester.pumpWidget(MaterialApp.router(routerConfig: router));
        await tester.pumpAndSettle();
        expect(navigation.currentRoute, AppRouteCatalog.settings);

        await tester.tap(find.byKey(backButtonKey));
        await tester.pumpAndSettle();

        expect(navigation.currentRoute, AppRouteCatalog.home);
        expect(find.text('Home'), findsOneWidget);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }

  testWidgets('desktop pushed secondary route still pops its real history', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      final navigation = AppNavigation();
      final router = _testRouter(
        initialLocation: AppRouteCatalog.home,
        navigation: navigation,
        backButtonKey: backButtonKey,
      );
      addTearDown(router.dispose);
      navigation.configure(router);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      unawaited(navigation.push<void>(AppRouteCatalog.settings));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(backButtonKey));
      await tester.pumpAndSettle();

      expect(navigation.currentRoute, AppRouteCatalog.home);
      expect(find.text('Home'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile top-level route keeps existing no-op pop behavior', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final navigation = AppNavigation();
      final router = _testRouter(
        initialLocation: AppRouteCatalog.settings,
        navigation: navigation,
        backButtonKey: backButtonKey,
      );
      addTearDown(router.dispose);
      navigation.configure(router);

      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(backButtonKey));
      await tester.pumpAndSettle();

      expect(navigation.currentRoute, AppRouteCatalog.settings);
      expect(find.text('Settings'), findsOneWidget);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

GoRouter _testRouter({
  required String initialLocation,
  required AppNavigation navigation,
  required Key backButtonKey,
}) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation,
    routes: <RouteBase>[
      GoRoute(
        path: AppRouteCatalog.home,
        builder: (_, _) => const Scaffold(body: Text('Home')),
      ),
      GoRoute(
        path: AppRouteCatalog.settings,
        builder: (_, _) => Scaffold(
          body: TextButton(
            key: backButtonKey,
            onPressed: navigation.pop,
            child: const Text('Settings'),
          ),
        ),
      ),
    ],
  );
}
