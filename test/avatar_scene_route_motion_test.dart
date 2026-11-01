import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/agent_space/presentation/agent_space_page.dart';

const _sceneKey = ValueKey('scene-overlay');
const _previousKey = ValueKey('previous-page');
const _setupKey = ValueKey('live-setup-page');
const _pageKey = ValueKey('scene-route');

void main() {
  setUp(appServices.reset);
  tearDown(appServices.reset);

  for (final location in <String>[AppRoutes.agentSpace]) {
    testWidgets('$location retains its dependencies, page key and arguments', (
      tester,
    ) async {
      final router = createAppRouter(initialLocation: AppRoutes.home);
      addTearDown(router.dispose);
      late CustomTransitionPage<void> page;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              page = _scenePage(context, router, location);
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(page.key, _pageKey);
      expect(page.opaque, isTrue);
      expect(page.child, isA<AgentSpacePage>());
    });

    for (final platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      for (final reduceMotion in <bool>[false, true]) {
        for (final size in <Size>[const Size(375, 812), const Size(812, 375)]) {
          testWidgets(
            '$location switches one overlay at a time: $platform $reduceMotion $size',
            (tester) async {
              tester.view.devicePixelRatio = 1;
              tester.view.physicalSize = size;
              addTearDown(tester.view.resetDevicePixelRatio);
              addTearDown(tester.view.resetPhysicalSize);
              final router = createAppRouter(initialLocation: AppRoutes.home);
              addTearDown(router.dispose);
              final navigator = GlobalKey<NavigatorState>();
              final capture = GlobalKey();
              late BuildContext pageContext;
              await tester.pumpWidget(
                MaterialApp(
                  navigatorKey: navigator,
                  theme: AppTheme.build(
                    AppPalette.of(
                      size.width < size.height
                          ? Brightness.light
                          : Brightness.dark,
                      AppAccent.blue,
                    ),
                  ).copyWith(platform: platform),
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      disableAnimations: reduceMotion,
                      textScaler: const TextScaler.linear(2),
                    ),
                    child: RepaintBoundary(
                      key: capture,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          // Mobile Unity renders behind the entire navigator.
                          const ColoredBox(color: Colors.green),
                          child!,
                        ],
                      ),
                    ),
                  ),
                  home: Builder(
                    builder: (context) {
                      pageContext = context;
                      return const ColoredBox(
                        key: _previousKey,
                        color: Colors.purple,
                      );
                    },
                  ),
                ),
              );

              final page = _scenePage(pageContext, router, location);
              // Use production route timing, opacity and transition, replacing
              // only the service-backed page with a transparent scene overlay.
              PageRoute<void> sceneRoute() => PageRouteBuilder<void>(
                settings: page,
                opaque: page.opaque,
                transitionDuration: page.transitionDuration,
                reverseTransitionDuration: page.reverseTransitionDuration,
                transitionsBuilder: page.transitionsBuilder,
                pageBuilder: (_, _, _) => const SizedBox.expand(key: _sceneKey),
              );

              for (var visit = 0; visit < 2; visit++) {
                if (visit == 0) {
                  unawaited(navigator.currentState!.push(sceneRoute()));
                } else {
                  unawaited(
                    navigator.currentState!.push(
                      MaterialPageRoute<void>(
                        builder: (_) =>
                            const ColoredBox(key: _setupKey, color: Colors.red),
                      ),
                    ),
                  );
                  await tester.pumpAndSettle();
                  // Replacing a page with Agent Space preserves the same route boundary.
                  unawaited(
                    navigator.currentState!.pushReplacement(sceneRoute()),
                  );
                }
                for (final ms in <int>[0, 16, 80]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(find.byKey(_previousKey), findsNothing);
                  expect(find.byKey(_setupKey), findsNothing);
                  expect(tester.getTopLeft(find.byKey(_sceneKey)), Offset.zero);
                  expect(
                    (await _backgroundPixel(tester, capture)).toARGB32(),
                    Colors.green.toARGB32(),
                  );
                }
                navigator.currentState!.pop();
                for (final ms in <int>[0, 16, 80]) {
                  await tester.pump(Duration(milliseconds: ms));
                  expect(find.byKey(_sceneKey), findsNothing);
                  expect(find.byKey(_previousKey), findsOneWidget);
                  expect(
                    (await _backgroundPixel(tester, capture)).toARGB32(),
                    Colors.purple.toARGB32(),
                  );
                }
              }
              expect(navigator.currentState!.canPop(), isFalse);
              expect(tester.takeException(), isNull);
            },
          );
        }
      }
    }
  }
}

CustomTransitionPage<void> _scenePage(
  BuildContext context,
  GoRouter router,
  String location,
) {
  final route = router.configuration.routes.whereType<GoRoute>().singleWhere(
    (route) => route.path == location,
  );
  final state = GoRouterState(
    router.configuration,
    uri: Uri.parse(location),
    matchedLocation: location,
    path: location,
    fullPath: location,
    pathParameters: const <String, String>{},
    extra: const <String, Object>{'creatorPrompt': 'Wave hello'},
    pageKey: _pageKey,
    topRoute: route,
  );
  return route.pageBuilder!(context, state) as CustomTransitionPage<void>;
}

Future<Color> _backgroundPixel(WidgetTester tester, GlobalKey capture) async {
  return (await tester.runAsync(() async {
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(capture),
    );
    final image = await boundary.toImage();
    try {
      final pixels = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      final offset = (100 * image.width + 20) * 4;
      return Color.fromARGB(
        pixels.getUint8(offset + 3),
        pixels.getUint8(offset),
        pixels.getUint8(offset + 1),
        pixels.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  }))!;
}
