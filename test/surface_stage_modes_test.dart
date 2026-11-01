import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/widgets/surface_stage.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    WebViewPlatform.instance = _FakeWebViewPlatform();
    appServices.reset();
  });

  tearDown(appServices.reset);

  test('account runtime eagerly registers its owned SurfaceRuntime', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(
      source,
      contains(
        "import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';",
      ),
    );

    final surfaceRuntimeIndex = source.indexOf('putOwned(SurfaceRuntime());');

    expect(surfaceRuntimeIndex, greaterThanOrEqualTo(0));
    expect(source, isNot(contains('CardRuntime')));
    expect(source, isNot(contains('CardBackendService')));
  });

  testWidgets('Home stage never mounts a game SurfaceWebView', (tester) async {
    final runtime = appServices.put(SurfaceRuntime());
    await runtime.show(
      _project(
        kind: SurfaceKind.fullscreen,
        title: 'Dedicated game',
        experienceType: SurfaceExperienceType.game,
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: SurfaceStage())),
    );
    await tester.pump();

    expect(find.byType(SurfaceWebView), findsNothing);
    expect(find.byKey(SurfaceStage.fullscreenHostKey), findsNothing);
  });

  testWidgets('an injected game runtime owns one isolated WebView', (
    tester,
  ) async {
    final globalRuntime = appServices.put(SurfaceRuntime());
    await globalRuntime.show(
      _project(kind: SurfaceKind.card, title: 'Global utility'),
    );
    final scopedRuntime = SurfaceRuntime()..initializeLifecycle();
    addTearDown(scopedRuntime.closeLifecycle);
    await scopedRuntime.show(
      _project(
        kind: SurfaceKind.fullscreen,
        title: 'Scoped game',
        experienceType: SurfaceExperienceType.game,
      ),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: SurfaceWebView(
          runtime: scopedRuntime,
          backgroundColor: Colors.black,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(scopedRuntime.activeProject.value?.title, 'Scoped game');
    expect(globalRuntime.activeProject.value?.title, 'Global utility');
  });

  test('home separates background and foreground surface layers', () {
    final source = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();
    // Match the direct child constructor, independent of const placement or
    // its scene-attempt key. The three ordering assertions remain unchanged.
    final world =
        RegExp(
          r'Positioned\.fill\(\s*child:\s*(?:const\s+)?_HomeWorldBackdrop\(',
        ).firstMatch(source)?.start ??
        -1;
    final background = source.indexOf(
      'SurfaceStage(layer: SurfaceStageLayer.background)',
    );
    final foreground = source.indexOf(
      'SurfaceStage(layer: SurfaceStageLayer.foreground)',
    );

    expect(world, greaterThanOrEqualTo(0));
    expect(background, greaterThanOrEqualTo(0));
    expect(background, greaterThan(world));
    expect(foreground, greaterThan(background));
  });

  testWidgets('card surfaces use a framed header host', (tester) async {
    await _pumpStage(
      tester,
      _project(kind: SurfaceKind.card, title: 'Card UI'),
    );

    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(find.byKey(SurfaceStage.cardFrameKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.headerKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.backButtonKey), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);
    expect(
      tester.widget(find.byKey(SurfaceStage.backButtonKey)),
      isA<ClipOval>(),
    );
    expect(find.text('Card UI'), findsOneWidget);
  });

  testWidgets('fullscreen surfaces use safe controls without card chrome', (
    tester,
  ) async {
    await _pumpStage(
      tester,
      _project(kind: SurfaceKind.fullscreen, title: 'Full UI'),
    );

    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(find.byKey(SurfaceStage.fullscreenHostKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.safeControlsKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.backButtonKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.cardFrameKey), findsNothing);
    expect(find.byKey(SurfaceStage.headerKey), findsNothing);
    expect(find.text('Full UI'), findsNothing);
    expect(find.byKey(const ValueKey('applet-player-like')), findsOneWidget);
    expect(find.byIcon(Icons.close_rounded), findsNothing);
  });

  testWidgets('saved legacy card applets reopen fullscreen without a title', (
    tester,
  ) async {
    final project = _project(kind: SurfaceKind.card, title: 'Saved applet');
    final stage = appServices.put(WidgetStageController());
    stage.present(
      AgentWidget(
        id: 8,
        agentId: 'self',
        title: project.title,
        kind: 'surface',
        spec: {'surfaceId': project.id},
        createdAt: DateTime.utc(2026),
      ),
      nextMode: WidgetStageMode.fullscreen,
    );
    await _pumpStage(tester, project);

    expect(find.byKey(SurfaceStage.fullscreenHostKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.cardFrameKey), findsNothing);
    expect(find.byKey(SurfaceStage.headerKey), findsNothing);
    expect(find.text('Saved applet'), findsNothing);
    expect(find.byKey(SurfaceStage.backButtonKey), findsOneWidget);
    expect(find.byKey(const ValueKey('applet-player-like')), findsOneWidget);
    await tester.tap(find.byKey(SurfaceStage.backButtonKey));
    await tester.pump();
    expect(stage.active.value, isNull);
  });

  testWidgets('closing a home-presented surface clears the widget stage', (
    tester,
  ) async {
    final stage = appServices.put(WidgetStageController());
    final item = _surfaceWidget();
    stage.present(item, nextMode: WidgetStageMode.fullscreen);
    final runtime = appServices.put(SurfaceRuntime());
    await runtime.show(
      _project(kind: SurfaceKind.fullscreen, title: 'Home Surface'),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 1000, height: 800, child: SurfaceStage()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(SurfaceStage.backButtonKey));
    await tester.pump();

    expect(runtime.isVisible.value, isFalse);
    expect(stage.active.value, isNull);
  });

  testWidgets('floating canvas is positioned, transparent, and frameless', (
    tester,
  ) async {
    const placement = SurfacePlacement(x: 0.1, y: 0.2, width: 0.4, height: 0.5);

    await _pumpStage(
      tester,
      _project(
        kind: SurfaceKind.floatingCanvas,
        title: 'Float UI',
        transparent: true,
        placement: placement,
      ),
    );

    expect(find.byType(SurfaceWebView), findsOneWidget);
    expect(find.byKey(SurfaceStage.floatingHostKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.backButtonKey), findsOneWidget);
    expect(find.byKey(SurfaceStage.cardFrameKey), findsNothing);
    expect(find.byKey(SurfaceStage.headerKey), findsNothing);
    expect(find.text('Float UI'), findsNothing);

    final rect = tester.getRect(find.byKey(SurfaceStage.floatingHostKey));
    expect(rect.left, 100);
    expect(rect.top, 160);
    expect(rect.width, 400);
    expect(rect.height, 400);

    final body = tester.widget<SurfaceWebView>(find.byType(SurfaceWebView));
    expect(body.backgroundColor, Colors.transparent);
  });

  testWidgets('overlay and background surfaces stay frameless', (tester) async {
    for (final kind in [
      SurfaceKind.transparentOverlay,
      SurfaceKind.background,
    ]) {
      await _pumpStage(tester, _project(kind: kind, title: kind.name));

      expect(find.byType(SurfaceWebView), findsOneWidget);
      expect(find.byKey(SurfaceStage.cardFrameKey), findsNothing);
      expect(find.byKey(SurfaceStage.headerKey), findsNothing);
      expect(find.text(kind.name), findsNothing);
      if (kind == SurfaceKind.background) {
        expect(find.byKey(SurfaceStage.backButtonKey), findsNothing);
      } else {
        expect(find.byKey(SurfaceStage.backButtonKey), findsOneWidget);
      }
    }
  });

  testWidgets('host can suppress its back button when route chrome owns it', (
    tester,
  ) async {
    final runtime = appServices.put(SurfaceRuntime());
    await runtime.show(
      _project(kind: SurfaceKind.fullscreen, title: 'Route Surface'),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 800,
            child: SurfaceStage(showBackButton: false),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(SurfaceStage.backButtonKey), findsNothing);
  });
}

AgentWidget _surfaceWidget() => AgentWidget(
  id: 7,
  agentId: 'self',
  title: 'Home Surface',
  kind: 'surface',
  spec: {'surfaceId': 'surface_7'},
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

Future<void> _pumpStage(WidgetTester tester, SurfaceProject project) async {
  tester.view.physicalSize = const Size(1000, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final runtime = appServices.put(SurfaceRuntime());
  await runtime.show(project);
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 1000, height: 800, child: SurfaceStage()),
      ),
    ),
  );
  await tester.pump();
}

SurfaceProject _project({
  required SurfaceKind kind,
  required String title,
  bool transparent = false,
  SurfaceExperienceType experienceType = SurfaceExperienceType.utility,
  SurfacePlacement placement = const SurfacePlacement(
    x: 0,
    y: 0,
    width: 1,
    height: 1,
  ),
}) {
  return SurfaceProject(
    id: 'surface_${kind.name}',
    title: title,
    kind: kind,
    rendering: experienceType == SurfaceExperienceType.game
        ? SurfaceRendering.workerCanvas
        : SurfaceRendering.dom,
    html: experienceType == SurfaceExperienceType.game
        ? ''
        : '<main>$title</main>',
    css: '',
    js: experienceType == SurfaceExperienceType.game
        ? 'Game.define({init(){return {};},update(state){return state;},draw(){return [{type:"clear",color:"#000"}];},input(state){return state;}});'
        : '',
    transparent: transparent,
    experienceType: experienceType,
    placement: placement,
    manifest: const SurfaceManifest(),
    backend: const {},
    revisions: const [],
  );
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) {
    return _FakePlatformWebViewController(params);
  }

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) {
    return _FakePlatformWebViewWidget(params);
  }

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) {
    return _FakePlatformNavigationDelegate(params);
  }
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {}

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {}

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {}

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    covariant PlatformNavigationDelegate handler,
  ) async {}
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {}

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {}

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {}
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }
}
