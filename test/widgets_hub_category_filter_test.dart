import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_companion_controls.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_frost_chrome.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:maaso/src/features/widgets_hub/data/game_document_loader.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:sembast/sembast_memory.dart';
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

final List<Uri> _loadedPublicGameUrls = <Uri>[];
final Map<String, void Function(JavaScriptMessage)> _javascriptChannels =
    <String, void Function(JavaScriptMessage)>{};
bool _autoFinishPublicGameLoads = true;
_FakePlatformWebViewController? _lastPublicGameController;
NavigationRequestCallback? _lastPublicGameNavigationRequest;
Completer<void>? _publicGameJavaScriptModeBlocker;

AppCapabilitySnapshotService _surfaceCapabilities(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const {}),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    WebViewPlatform.instance = _FakeWebViewPlatform();
    _loadedPublicGameUrls.clear();
    GameDocumentLoader.debugClientFactory = () => MockClient(
      (request) async => http.Response(
        '<html><head></head><body><canvas></canvas></body></html>',
        200,
        headers: {
          'content-type': 'text/html',
          'content-security-policy':
              "default-src 'none'; script-src 'unsafe-inline'; sandbox allow-scripts",
        },
      ),
    );
    _javascriptChannels.clear();
    _autoFinishPublicGameLoads = true;
    _lastPublicGameController = null;
    _lastPublicGameNavigationRequest = null;
    _publicGameJavaScriptModeBlocker = null;
    GameScreenshotPreview.clearCache();
    GameScreenshotStore.debugClientFactory = () =>
        MockClient((_) async => http.Response('', 404));
    gameFeedFirstFrameWaiterOverride =
        const SurfaceWorkerTestFirstFrameWaiter();
    gameFeedShareCallbackOverride = null;
  });

  tearDown(() async {
    GameDocumentLoader.debugClientFactory = null;
    GameScreenshotStore.debugClientFactory = null;
    GameScreenshotPreview.clearCache();
    gameFeedFirstFrameWaiterOverride = null;
    gameFeedShareCallbackOverride = null;
    gameFeedImpressionOverride = null;
    gameFeedImpressionRecorderOverride = null;
    gameFeedImpressionScopeKeyOverride = null;
    final blocker = _publicGameJavaScriptModeBlocker;
    if (blocker != null && !blocker.isCompleted) blocker.complete();
    _publicGameJavaScriptModeBlocker = null;
    await appServices.reset();
  });

  testWidgets(
    'standalone games keep a full-screen vertical pager and suspend impressions',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'embedded_game_viewport.db',
      );
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.gameFeedItems.assignAll([
        _catalogGame('first', 'First Game'),
        _catalogGame('second', 'Second Game'),
      ]);
      final viewed = <String>[];
      gameFeedImpressionOverride = (item) => viewed.add(item.id);
      var active = true;
      late StateSetter rebuild;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              rebuild = setState;
              return GameFeedPage(playbackEnabled: active);
            },
          ),
        ),
      );
      await tester.pump();
      final pager = find.byType(PageView);
      expect(tester.getRect(pager), const Rect.fromLTWH(0, 0, 390, 844));
      expect(tester.widget<PageView>(pager).scrollDirection, Axis.vertical);
      expect(
        find.byKey(const ValueKey<String>('game-feed-back')),
        findsOneWidget,
      );
      await tester.drag(pager, const Offset(0, -650));
      await tester.pumpAndSettle();
      expect(tester.widget<PageView>(pager).controller!.page, 1);
      rebuild(() => active = false);
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));
      expect(viewed, isEmpty);
      rebuild(() => active = true);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(viewed, ['second']);
      expect(tester.widget<PageView>(pager).controller!.page, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 3));
      expect(viewed, ['second']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'standalone games pause impressions behind routes and in background',
    (tester) async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'game_route_lifecycle.db',
      );
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.gameFeedItems.assign(
        _catalogGame('route-visibility', 'Route Visibility'),
      );
      final viewed = <String>[];
      gameFeedImpressionOverride = (item) => viewed.add(item.id);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const GameFeedPage()),
      );
      await tester.pump();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Cover')),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(viewed, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 3));
      expect(viewed, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(viewed, ['route-visibility']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'feed and Mine bind previews to the actual game revision and source',
    (tester) async {
      final local = _surface('Captured Local', {'experienceType': 'game'})
        ..id = 901;
      appServices.put<DBService>(_FakeWidgetDBService([local]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      final published = _catalogGame('real-preview', 'Published Preview');
      controller.gameFeedItems.assign(published);
      final cloud = ScopedAppletInventoryItem(
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        item: AppletInventoryItem(
          id: 'cloud-preview',
          clientSurfaceId: 'cloud-source',
          title: 'Cloud Preview',
          type: AppletCatalogType.game,
          summary: '',
          published: true,
          shareUrl: Uri.parse('https://api.example.test/g/cloud-preview'),
          updatedAt: DateTime.utc(2026, 9, 15),
        ),
      );
      controller.cloudOnlyItems.assign(cloud);
      await tester.pumpWidget(const MaterialApp(home: GameFeedPage()));
      await tester.pump();
      final preview = tester.widget<GameScreenshotPreview>(
        find.byType(GameScreenshotPreview).first,
      );
      expect(preview.shareUrl, published.shareUrl);
      expect(preview.revision, published.updatedAt.toIso8601String());
      expect(preview.active, isTrue);
      expect(preview.localItem, isNull);
      await tester.tap(find.byKey(const ValueKey('game-feed-tab-mine')));
      await tester.pump();
      final previews = tester.widgetList<GameScreenshotPreview>(
        find.byType(GameScreenshotPreview),
      );
      final localPreview = previews.singleWhere(
        (item) => item.localItem != null,
      );
      expect(localPreview.localItem!.id, 901);
      expect(localPreview.shareUrl, isNull);
      final cloudPreview = previews.singleWhere(
        (item) => item.identity == 'cloud:cloud-preview',
      );
      expect(cloudPreview.shareUrl, cloud.item.shareUrl);
      expect(cloudPreview.revision, cloud.item.updatedAt.toIso8601String());
      expect(cloudPreview.active, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('public game records one view after two settled seconds', (
    tester,
  ) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'game_impression_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.gameFeedItems.assign(_catalogGame('view-once', 'View Once'));
    final viewed = <String>[];
    gameFeedImpressionOverride = (item) => viewed.add(item.id);

    await tester.pumpWidget(const MaterialApp(home: GameFeedPage()));
    await tester.pump(const Duration(seconds: 1));
    expect(viewed, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(viewed, <String>['view-once']);
    await tester.pump(const Duration(seconds: 3));
    expect(viewed, <String>['view-once']);
  });

  test(
    'delete-pending Applets stay hidden while retaining cleanup state',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path:
            'applet_delete_pending_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      final visible = _surface('Visible Applet', const <String, Object?>{});
      final deleting = _surface('Deleting Applet', <String, Object?>{
        'cloudDelete': <String, Object?>{
          'schemaVersion': 1,
          'scopeKey': 'device-legacy',
          'clientSurfaceId': 'surface_Deleting_Applet',
        },
      });
      final pending = _surface('Pending Applet', <String, Object?>{
        appletPresentationPendingKey: true,
      });
      await database.saveAgentWidget(visible);
      await database.saveAgentWidget(deleting);
      await database.saveAgentWidget(pending);
      final controller = appServices.put(WidgetsHubController());

      await controller.reload();

      expect(controller.widgets.map((widget) => widget.title), <String>[
        'Visible Applet',
      ]);
      expect(await database.getAllWidgets(), hasLength(3));
    },
  );

  testWidgets('Hub separates playable Games from functional Applets', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'applet_categories_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    final guide =
        _surface('Kyoto Travel Guide', <String, Object?>{
            'experienceType': 'utility',
          })
          ..icon = '🗺️'
          ..subtitle = 'Saved itineraries and city notes';
    controller.widgets.assignAll(<AgentWidget>[
      _surface('Arcade', <String, Object?>{'experienceType': 'game'}),
      guide,
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: WidgetsHubPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey<String>('applet-hub-tab-games')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('applet-hub-tab-applets')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('applet-functional-list')),
      findsOneWidget,
    );
    expect(find.text('Arcade'), findsNothing);
    expect(find.text('Kyoto Travel Guide'), findsNothing);
    expect(find.byKey(const ValueKey('applet-hub-mine')), findsOneWidget);
    expect(
      find.byKey(const ValueKey('applet-hub-search-field')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey('applet-filter-travel')), findsNothing);
    await tester.pumpWidget(const MaterialApp(home: MyAppletsPage()));
    await tester.pump();
    expect(find.text('Kyoto Travel Guide'), findsOneWidget);
    expect(find.text('🗺️'), findsOneWidget);
    expect(find.text('Saved itineraries and city notes'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('applet-category-travel')),
      findsOneWidget,
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: GameFeedPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.byKey(const ValueKey<String>('game-feed-page')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('game-feed-tab-recommended')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('game-feed-tab-popular')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('game-feed-tab-mine')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('applet-functional-list')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();
    expect(find.text('Arcade'), findsOneWidget);
    expect(find.text('Kyoto Travel Guide'), findsNothing);
    final grid = tester.widget<GridView>(
      find.byKey(const ValueKey<String>('game-feed-owned-grid')),
    );
    final delegate =
        grid.gridDelegate as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.childAspectRatio, closeTo(9 / 16, 0.0001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Game Feed pages vertically with full-screen overlay chrome', (
    tester,
  ) async {
    _registerPublicGameOrigin();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'game_feed_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.gameFeedItems.assignAll(<AppletCatalogItem>[
      _catalogGame('public-one', 'Public One'),
      _catalogGame('public-two', 'Public Two'),
    ]);
    controller.searchQuery.value = 'stale applets search';
    controller.searchResults.assign(
      _catalogGame('stale-search', 'Hidden Search Result'),
    );
    controller.gameLikeInFlightIds.add('device-legacy|public-one');
    _autoFinishPublicGameLoads = false;
    String? sharedTitle;
    String? sharedText;
    gameFeedShareCallbackOverride =
        ({required title, required text, origin}) async {
          sharedTitle = title;
          sharedText = text;
          return true;
        };

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: GameFeedPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Public One'), findsOneWidget);
    expect(find.text('Public Two'), findsNothing);
    expect(find.text('Hidden Search Result'), findsNothing);
    expect(find.byType(PageView), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('game-feed-like')),
      findsOneWidget,
    );
    final likeSemantics = tester.getSemantics(
      find.byKey(const ValueKey<String>('game-feed-like')),
    );
    expect(likeSemantics.flagsCollection.isButton, isTrue);
    expect(likeSemantics.flagsCollection.isEnabled, ui.Tristate.isFalse);
    expect(
      find.byKey(const ValueKey<String>('game-feed-comments')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('game-feed-share')),
      findsOneWidget,
    );
    final badgeText = tester.widget<Text>(
      find
          .descendant(
            of: find.byKey(const ValueKey<String>('applet-category-game')),
            matching: find.byType(Text),
          )
          .first,
    );
    final badge = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey<String>('applet-category-game')),
    );
    final badgeDecoration = badge.decoration as BoxDecoration;
    final foregroundLuminance = badgeText.style!.color!.computeLuminance();
    final backgroundLuminance = badgeDecoration.color!.computeLuminance();
    final lighter = foregroundLuminance > backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    final darker = foregroundLuminance < backgroundLuminance
        ? foregroundLuminance
        : backgroundLuminance;
    expect((lighter + 0.05) / (darker + 0.05), greaterThanOrEqualTo(4.5));
    expect(badgeDecoration.border, isNull);
    expect(_loadedPublicGameUrls, isEmpty);
    expect(
      tester
          .getSemantics(
            find.byKey(const ValueKey<String>('game-feed-cover-public-one')),
          )
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isTrue,
    );
    final interactive = tester.getRect(
      find.byKey(const ValueKey<String>('game-feed-cover-public-one')),
    );
    final page = tester.getRect(
      find.byKey(const ValueKey<String>('game-feed-page')),
    );
    final metadata = tester.getRect(
      find.byKey(const ValueKey<String>('game-feed-metadata-region')),
    );
    expect(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('game-feed-metadata-region')),
        matching: find.byType(IgnorePointer),
      ),
      findsAtLeastNWidgets(1),
    );
    final rail = tester.getRect(
      find.byKey(const ValueKey<String>('game-swipe-rail')),
    );
    expect(interactive, page);
    expect(interactive.overlaps(metadata), isTrue);
    expect(interactive.right, greaterThan(rail.left));

    final javaScriptModeBlocker = Completer<void>();
    _publicGameJavaScriptModeBlocker = javaScriptModeBlocker;
    await tester.tap(
      find.byKey(const ValueKey<String>('game-feed-cover-public-one')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(_loadedPublicGameUrls, isEmpty);
    javaScriptModeBlocker.complete();
    _publicGameJavaScriptModeBlocker = null;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final embedUrl = Uri.parse('https://api.example.test/g/public-one/embed');
    expect(_loadedPublicGameUrls, <Uri>[embedUrl]);
    expect(embedUrl.query, isEmpty);
    expect(embedUrl.fragment, isEmpty);
    expect(
      find.byKey(const ValueKey<String>('public-game-player-host')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('public-game-player-overlay')),
      findsNothing,
    );
    final playerRect = tester.getRect(
      find.byKey(const ValueKey<String>('public-game-player-host')),
    );
    final webViewRect = tester.getRect(
      find.byKey(const ValueKey<String>('public-game-webview')),
    );
    final backRect = tester.getRect(
      find.byKey(const ValueKey<String>('public-game-player-back')),
    );
    expect(playerRect, const Rect.fromLTWH(0, 0, 390, 844));
    expect(webViewRect, playerRect);
    expect(webViewRect.overlaps(backRect), isTrue);
    final decideNavigation = _lastPublicGameNavigationRequest!;
    expect(
      await Future<NavigationDecision>.value(
        decideNavigation(
          NavigationRequest(url: embedUrl.toString(), isMainFrame: true),
        ),
      ),
      NavigationDecision.navigate,
    );
    expect(
      await Future<NavigationDecision>.value(
        decideNavigation(
          const NavigationRequest(url: 'about:srcdoc', isMainFrame: false),
        ),
      ),
      NavigationDecision.navigate,
    );
    for (final blocked in <NavigationRequest>[
      const NavigationRequest(
        url: 'https://api.example.test/g/public-one',
        isMainFrame: true,
      ),
      const NavigationRequest(
        url: 'https://api.example.test/g/public-one/embed',
        isMainFrame: false,
      ),
      const NavigationRequest(
        url: 'https://api.example.test/g/public-one/embed?mode=app',
        isMainFrame: true,
      ),
      const NavigationRequest(
        url: 'https://api.example.test/g/public-one/embed/',
        isMainFrame: true,
      ),
      const NavigationRequest(
        url: 'https://evil.example/g/public-one/embed',
        isMainFrame: true,
      ),
      const NavigationRequest(url: 'about:srcdoc', isMainFrame: true),
      const NavigationRequest(url: 'about:blank', isMainFrame: false),
      const NavigationRequest(
        url: 'data:text/html,%3Cp%3Eblocked%3C%2Fp%3E',
        isMainFrame: false,
      ),
    ]) {
      expect(
        await Future<NavigationDecision>.value(decideNavigation(blocked)),
        NavigationDecision.prevent,
      );
    }
    expect(
      find.byKey(const ValueKey<String>('public-game-loading')),
      findsOneWidget,
    );
    final failedController = _lastPublicGameController!;
    failedController.failPage();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(const ValueKey<String>('public-game-load-error')),
      findsOneWidget,
    );
    failedController.finishPage();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('public-game-load-error')),
      findsOneWidget,
    );
    await tester.tap(find.text('Retry'));
    await tester.pump();
    await tester.pump();
    final retryController = _lastPublicGameController!;
    expect(retryController, isNot(same(failedController)));
    expect(_loadedPublicGameUrls, <Uri>[embedUrl, embedUrl]);
    expect(
      find.byKey(const ValueKey<String>('public-game-loading')),
      findsOneWidget,
    );
    failedController.finishPage();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('public-game-loading')),
      findsOneWidget,
    );
    retryController.finishPage();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.byKey(const ValueKey<String>('public-game-loading')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('public-game-player-back')),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    await tester.tap(find.byKey(const ValueKey<String>('game-feed-share')));
    await tester.pump();
    expect(sharedTitle, 'Public One');
    expect(sharedText, 'Public One\nhttps://api.example.test/g/public-one');
    expect(sharedText, isNot(contains('/embed')));

    await tester.fling(
      find.byKey(const ValueKey<String>('game-swipe-rail')),
      const Offset(0, -220),
      900,
    );
    await tester.pump();

    expect(find.text('Public One'), findsNothing);
    expect(find.text('Public Two'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 10));
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mine starts one game only after its static cover is tapped', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final waiter = _BlockingFirstFrameWaiter();
    gameFeedFirstFrameWaiterOverride = waiter;
    final firstGame =
        _surface('Lazy Arcade', <String, Object?>{'experienceType': 'game'})
          ..id = 73
          ..seen = true;
    final secondGame =
        _surface('Second Arcade', <String, Object?>{'experienceType': 'game'})
          ..id = 74
          ..seen = true;
    appServices.put<DBService>(
      _FakeWidgetDBService(<AgentWidget>[firstGame, secondGame]),
    );
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();

    expect(waiter.beginCount, 0);
    expect(waiter.waitCount, 0);
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('owned-game-cover-73')),
      findsOneWidget,
    );
    expect(
      tester
          .getSemantics(find.byKey(const ValueKey<String>('owned-game-73')))
          .getSemanticsData()
          .hasAction(ui.SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(find.byKey(const ValueKey<String>('owned-game-73')));
    await tester.pump();
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 400));
    expect(waiter.beginCount, 1);
    expect(waiter.waitCount, 1);
    expect(
      find.byKey(const ValueKey<String>('game-player-host')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('owned-game-74')).hitTestable(),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('game-cover-loading')),
      findsOneWidget,
    );
    expect(find.byType(SurfaceWebView), findsNothing);

    waiter.complete();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-rail')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('game-player-controls')), findsOneWidget);
    expect(find.byType(SurfaceWebView), findsOneWidget);

    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(waiter.beginCount, 1);
    expect(waiter.waitCount, 1);
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('owned-game-cover-73')),
      findsOneWidget,
    );
  });

  testWidgets('Home game detail installs and releases Hub route dependencies', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game =
        _surface('Home Gomoku', <String, Object?>{'experienceType': 'game'})
          ..id = 75
          ..seen = false;
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[game]));

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const SizedBox.expand(),
      ),
    );
    await tester.pump();
    expect(appServices.isRegistered<WidgetsHubController>(), isFalse);

    await presentAgentWidgetOnHome(game);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-rail')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('game-player-controls')), findsOneWidget);
    expect(appServices.isRegistered<WidgetsHubController>(), isTrue);
    expect(tester.takeException(), isNull);

    rootNavigatorKey.currentState!.pop();
    await tester.pumpAndSettle();

    expect(appServices.isRegistered<WidgetsHubController>(), isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mine manages games from the cover without starting a player', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game =
        _surface('Delete Me', <String, Object?>{'experienceType': 'game'})
          ..id = 1
          ..seen = true;
    final database = _FakeWidgetDBService(<AgentWidget>[game]);
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    final stored = controller.widgets.single;

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();

    expect(
      find.byKey(ValueKey<String>('owned-game-delete-${stored.id}')),
      findsNothing,
    );
    final more = find.byKey(ValueKey<String>('owned-game-more-${stored.id}'));
    expect(more, findsOneWidget);
    final moreButton = find.descendant(
      of: more,
      matching: find.byType(IconButton),
    );
    final moreSemantics = tester.getSemantics(moreButton);
    expect(moreSemantics.getSemanticsData().tooltip, 'More');
    expect(moreSemantics.flagsCollection.isButton, isTrue);
    expect(
      moreSemantics.getSemanticsData().hasAction(ui.SemanticsAction.tap),
      isTrue,
    );

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('game-player-host')), findsNothing);
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-more-sheet')),
      findsOneWidget,
    );
    final actionSurface = tester.widget<Material>(
      find.byKey(
        const ValueKey<String>('owned-game-detail-more-sheet-surface'),
      ),
    );
    expect((actionSurface.color!.a * 255).round(), 255);
    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-actions-row')),
      findsOneWidget,
    );
    final publishAction = find.byKey(
      const ValueKey<String>('owned-game-detail-publish'),
    );
    final shareAction = find.byKey(
      const ValueKey<String>('owned-game-detail-share'),
    );
    final deleteAction = find.byKey(
      const ValueKey<String>('owned-game-detail-delete'),
    );
    expect(publishAction, findsOneWidget);
    expect(shareAction, findsOneWidget);
    expect(deleteAction, findsOneWidget);
    expect(
      tester.getCenter(publishAction).dx,
      lessThan(tester.getCenter(shareAction).dx),
    );
    expect(
      tester.getCenter(shareAction).dx,
      lessThan(tester.getCenter(deleteAction).dx),
    );
    expect(
      tester.getCenter(publishAction).dy,
      closeTo(tester.getCenter(deleteAction).dy, 1),
    );
    expect(controller.widgets, hasLength(1));

    await tester.tap(deleteAction);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('owned-game-delete-confirmation')),
      findsOneWidget,
    );
    expect(controller.widgets, hasLength(1));

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(controller.widgets, isEmpty);
    expect(await database.getAllWidgets(), isEmpty);
  });

  for (final entry in ['local', 'public', 'cloud']) {
    for (final viewport in [
      (name: 'phone', size: const Size(390, 844), scale: 1.0),
      (name: 'narrow large text', size: const Size(320, 690), scale: 2.0),
      (name: 'landscape large text', size: const Size(844, 390), scale: 2.0),
    ]) {
      testWidgets(
        '$entry gameplay keeps only aligned back and companion controls: ${viewport.name}',
        (tester) async {
          tester.view.physicalSize = viewport.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(() async {
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          });
          _registerPublicGameOrigin();
          final game =
              _surface('Immersive Local', {
                  'experienceType': 'game',
                  'summary': 'Local game description',
                })
                ..id = 98
                ..seen = true;
          appServices.put<DBService>(
            _FakeWidgetDBService(entry == 'local' ? [game] : []),
          );
          final controller = appServices.put(WidgetsHubController());
          await controller.reload();
          if (entry == 'public') {
            controller.gameFeedItems.assign(
              _catalogGame('immersive-public', 'Immersive Public'),
            );
          } else if (entry == 'cloud') {
            controller.cloudOnlyItems.assign(
              ScopedAppletInventoryItem(
                scopeKey: AppletLocalOwnership.currentScopeKey(),
                item: AppletInventoryItem(
                  id: 'immersive-cloud',
                  clientSurfaceId: 'surface_immersive_cloud',
                  title: 'Immersive Cloud',
                  type: AppletCatalogType.game,
                  summary: 'Cloud game description',
                  published: true,
                  shareUrl: Uri.parse(
                    'https://api.example.test/g/immersive-cloud',
                  ),
                  updatedAt: DateTime.utc(2026, 10, 22),
                ),
              ),
            );
          }
          final browsing = appServices.put(CompanionBrowsingContextService());
          final companion = appServices.put<GameVoiceCompanionService>(
            GameVoiceCompanionService(
              browsingContext: browsing,
              commentary: (_, {required isCurrent, required onRevoked}) async =>
                  false,
            ),
          );
          final insets = viewport.size.width > viewport.size.height
              ? const EdgeInsets.fromLTRB(24, 12, 24, 16)
              : const EdgeInsets.fromLTRB(0, 32, 0, 24);
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: rootNavigatorKey,
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: insets,
                  viewPadding: insets,
                  textScaler: TextScaler.linear(viewport.scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: const GameFeedPage(),
            ),
          );
          await tester.pump();
          if (entry != 'public') {
            await tester.tap(find.byKey(const ValueKey('game-feed-tab-mine')));
            await tester.pump();
          }
          expect(
            find.byKey(const ValueKey('game-companion-controls')),
            findsNothing,
            reason: 'Companion settings belong only to the opened player.',
          );
          final coverKey = switch (entry) {
            'local' => 'owned-game-98',
            'public' => 'game-feed-cover-immersive-public',
            _ => 'owned-cloud-game-immersive-cloud',
          };
          final cover = find.byKey(ValueKey(coverKey));
          // Large text wraps the browse tabs above the upper part of a card.
          // Tap the visible lower preview, clear of both tabs and its More button.
          final coverRect = tester.getRect(cover);
          final tapY = (coverRect.bottom - 16)
              .clamp(
                coverRect.top + 16,
                viewport.size.height - insets.bottom - 16,
              )
              .toDouble();
          await tester.tapAt(Offset(coverRect.center.dx, tapY));
          await tester.pumpAndSettle();

          final hostKey = switch (entry) {
            'local' => 'game-player-host',
            'public' => 'public-game-player-host',
            _ => 'owned-cloud-game-detail',
          };
          final backKey = switch (entry) {
            'local' => 'game-player-back',
            'public' => 'public-game-player-back',
            _ => 'owned-cloud-game-player-back',
          };
          final host = find.byKey(ValueKey(hostKey));
          final back = find.byKey(ValueKey(backKey));
          final controls = find.byKey(const ValueKey('game-player-controls'));
          final companionButton = find.byKey(
            const ValueKey('game-companion-controls'),
          );
          expect(host, findsOneWidget);
          expect(controls, findsOneWidget);
          expect(back, findsOneWidget);
          expect(companionButton, findsOneWidget);
          expect(
            find.descendant(
              of: host,
              matching: find.byType(GameFrostIconButton),
            ),
            findsNWidgets(2),
          );
          final backRect = tester.getRect(back);
          final companionRect = tester.getRect(companionButton);
          expect(tester.getRect(host), Offset.zero & viewport.size);
          final gameContent = entry == 'local'
              ? find.byType(SurfaceWebView)
              : find.byKey(const ValueKey('public-game-webview'));
          expect(tester.getRect(gameContent), tester.getRect(host));
          expect(backRect.center.dy, closeTo(companionRect.center.dy, .1));
          expect(backRect.left, greaterThanOrEqualTo(insets.left));
          expect(
            companionRect.right,
            lessThanOrEqualTo(viewport.size.width - insets.right),
          );
          expect(backRect.right, lessThan(companionRect.left));
          for (final rect in [backRect, companionRect]) {
            expect(rect.top, greaterThanOrEqualTo(insets.top));
            expect(rect.width, greaterThanOrEqualTo(48));
            expect(rect.height, greaterThanOrEqualTo(48));
          }
          for (final absent in [
            'owned-game-detail-rail',
            'public-game-detail-rail',
            'owned-cloud-game-detail-rail',
            'public-game-player-overlay',
            'game-feed-metadata-region',
          ]) {
            expect(find.byKey(ValueKey(absent)), findsNothing);
          }
          for (final text in [
            'Immersive Local',
            'Immersive Public',
            'Immersive Cloud',
            'Local game description',
            'Immersive Public summary',
            'Cloud game description',
          ]) {
            expect(find.text(text), findsNothing);
          }
          expect(companion.currentSession, isNotNull);
          expect(companion.currentSession!.spokenRepliesEnabled, isTrue);
          await tester.tap(companionButton);
          await tester.pumpAndSettle();
          expect(find.byType(GameCompanionControlsSheet), findsOneWidget);
          tester
              .widget<SwitchListTile>(
                find.widgetWithText(SwitchListTile, 'game_companion.sound'.tr),
              )
              .onChanged!(false);
          await tester.pump();
          rootNavigatorKey.currentState!.pop();
          await tester.pumpAndSettle();
          expect(companion.currentSession!.spokenRepliesEnabled, isFalse);
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(host, findsNothing);
          expect(companion.currentSession, isNull);
          expect(find.byKey(ValueKey(coverKey)), findsOneWidget);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Mine publish is independent from the native share action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game =
        _surface('Publish Me', <String, Object?>{'experienceType': 'game'})
          ..id = 83
          ..seen = true;
    AppletLocalOwnership.stamp(
      game,
      scopeKey: AppletLocalOwnership.deviceLegacyScope,
    );
    final database = (await tester.runAsync(() async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'mine_publish_action_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      await db.saveAgentWidget(game);
      return db;
    }))!;
    addTearDown(database.close);
    appServices.put<DBService>(database);
    final requestPaths = <String>[];
    var sourceSha = '';
    var nativeShareCalls = 0;
    gameFeedShareCallbackOverride =
        ({required title, required text, origin}) async {
          nativeShareCalls++;
          return true;
        };
    appServices.put<AgentGameCloudService>(
      AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          requestPaths.add(request.url.path);
          if (request.url.path.endsWith('/publish')) {
            return _agentGameOk(<String, Object?>{
              'gameId': 'ag_publish_me',
              'revisionNo': 1,
              'sourceSha256': sourceSha,
              'published': true,
              'shareUrl': '/g/publish-me',
            });
          }
          final requestBody = Map<String, Object?>.from(
            jsonDecode(request.body) as Map,
          );
          final surface = Map<String, Object?>.from(
            requestBody['surface'] as Map,
          );
          sourceSha = canonicalAgentGameSourceSha256(surface);
          return _agentGameOk(<String, Object?>{
            'gameId': 'ag_publish_me',
            'clientSurfaceId': 'surface_Publish_Me',
            'revisionNo': 1,
            'sourceSha256': sourceSha,
            'published': false,
          });
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        accountScope: () => AppletLocalOwnership.deviceLegacyScope,
      ),
    );
    final controller = (await tester.runAsync(() async {
      final value = appServices.put(WidgetsHubController());
      await value.reload();
      return value;
    }))!;

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();
    await tester.tap(
      find.byKey(
        ValueKey<String>('owned-game-more-${controller.widgets.single.id}'),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('owned-game-detail-publish')),
    );
    await tester.pumpAndSettle();

    expect(requestPaths, <String>[
      '/v1/agent-games/by-client/surface_Publish_Me',
      '/v1/agent-games/ag_publish_me/publish',
    ]);
    expect(nativeShareCalls, 0);
    expect(find.text('Game is public'), findsOneWidget);
    final stored = (await tester.runAsync(database.getAllWidgets))!.single;
    expect(
      AppletLocalOwnership.storedScopeKey(stored),
      AppletLocalOwnership.deviceLegacyScope,
    );
    expect(
      AgentGameCloudMetadata.fromSpec(stored.spec['cloud']).isCurrentPublished,
      isTrue,
    );
  });

  testWidgets('Mine shares a published URL without publishing again', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game =
        _surface('Already Public', <String, Object?>{'experienceType': 'game'})
          ..id = 81
          ..seen = true;
    AppletLocalOwnership.stamp(
      game,
      scopeKey: AppletLocalOwnership.deviceLegacyScope,
    );
    game.spec['cloud'] = const AgentGameCloudMetadata(
      gameId: 'ag_already_public',
      revisionNo: 3,
      sourceSha256: 'current-source',
      syncState: AgentGameSyncState.published,
      scopeKey: AppletLocalOwnership.deviceLegacyScope,
      hasPublished: true,
      publishedRevisionNo: 3,
      publishedSourceSha256: 'current-source',
      shareUrl: 'https://api.example.test/g/already-public',
    ).toJson();
    final database = _FakeWidgetDBService(<AgentWidget>[game]);
    appServices.put<DBService>(database);
    var cloudRequests = 0;
    appServices.put<AgentGameCloudService>(
      AgentGameCloudService(
        database: database,
        httpClient: MockClient((_) async {
          cloudRequests++;
          return _agentGameOk(const <String, Object?>{});
        }),
        baseUri: () => Uri.parse('https://api.example.test/'),
        accessToken: () async => 'token-1',
        accountScope: () => AppletLocalOwnership.deviceLegacyScope,
      ),
    );
    var nativeShareCalls = 0;
    String? sharedText;
    gameFeedShareCallbackOverride =
        ({required title, required text, origin}) async {
          nativeShareCalls++;
          sharedText = text;
          return true;
        };
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('owned-game-more-81')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('owned-game-detail-share')),
    );
    await tester.pumpAndSettle();

    expect(cloudRequests, 0);
    expect(nativeShareCalls, 1);
    expect(
      sharedText,
      'Already Public\nhttps://api.example.test/g/already-public',
    );
  });

  testWidgets(
    'Mine publish paints progress and blocks every action while pending',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final game =
          _surface('Slow Publish', <String, Object?>{'experienceType': 'game'})
            ..id = 84
            ..seen = true;
      AppletLocalOwnership.stamp(
        game,
        scopeKey: AppletLocalOwnership.deviceLegacyScope,
      );
      final database = (await tester.runAsync(() async {
        final db = await DBService().init(
          factory: databaseFactoryMemory,
          path:
              'mine_publish_progress_${DateTime.now().microsecondsSinceEpoch}.db',
        );
        await db.saveAgentWidget(game);
        return db;
      }))!;
      addTearDown(database.close);
      appServices.put<DBService>(database);
      final releaseSync = Completer<void>();
      addTearDown(() {
        if (!releaseSync.isCompleted) releaseSync.complete();
      });
      final requestStarted = Completer<void>();
      final requestPaths = <String>[];
      var sourceSha = '';
      var nativeShareCalls = 0;
      gameFeedShareCallbackOverride =
          ({required title, required text, origin}) async {
            nativeShareCalls++;
            return false;
          };
      appServices.put<AgentGameCloudService>(
        AgentGameCloudService(
          database: database,
          httpClient: MockClient((request) async {
            requestPaths.add(request.url.path);
            if (request.url.path.endsWith('/publish')) {
              return _agentGameOk(<String, Object?>{
                'gameId': 'ag_slow_publish',
                'revisionNo': 1,
                'sourceSha256': sourceSha,
                'published': true,
                'shareUrl': '/g/slow-publish',
              });
            }
            if (!requestStarted.isCompleted) requestStarted.complete();
            await releaseSync.future;
            final requestBody = Map<String, Object?>.from(
              jsonDecode(request.body) as Map,
            );
            final surface = Map<String, Object?>.from(
              requestBody['surface'] as Map,
            );
            sourceSha = canonicalAgentGameSourceSha256(surface);
            return _agentGameOk(<String, Object?>{
              'gameId': 'ag_slow_publish',
              'clientSurfaceId': 'surface_Slow_Publish',
              'revisionNo': 1,
              'sourceSha256': sourceSha,
              'published': false,
            });
          }),
          baseUri: () => Uri.parse('https://api.example.test/'),
          accessToken: () async => 'token-1',
          accountScope: () => AppletLocalOwnership.deviceLegacyScope,
        ),
      );
      await tester.runAsync(() async {
        final controller = appServices.put(WidgetsHubController());
        await controller.reload();
      });
      await _openOwnedGameActions(tester, game.id!);

      final publish = find.byKey(
        const ValueKey<String>('owned-game-detail-publish'),
      );
      final share = find.byKey(
        const ValueKey<String>('owned-game-detail-share'),
      );
      final delete = find.byKey(
        const ValueKey<String>('owned-game-detail-delete'),
      );
      await tester.tap(publish);
      for (var frame = 0; frame < 50 && !requestStarted.isCompleted; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(requestStarted.isCompleted, isTrue);
      expect(
        find.byKey(
          const ValueKey<String>('owned-game-detail-publish-progress'),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSemantics(publish).flagsCollection.isEnabled,
        ui.Tristate.isFalse,
      );
      expect(
        tester.getSemantics(share).flagsCollection.isEnabled,
        ui.Tristate.isFalse,
      );
      expect(
        tester.getSemantics(delete).flagsCollection.isEnabled,
        ui.Tristate.isFalse,
      );

      await tester.tap(publish, warnIfMissed: false);
      await tester.tap(share, warnIfMissed: false);
      await tester.tap(delete, warnIfMissed: false);
      await tester.pump();
      expect(requestPaths, hasLength(1));
      expect(nativeShareCalls, 0);
      expect(
        find.byKey(const ValueKey<String>('owned-game-detail-more-sheet')),
        findsOneWidget,
      );

      releaseSync.complete();
      await tester.pumpAndSettle();

      expect(requestPaths, hasLength(2));
      expect(
        find.byKey(
          const ValueKey<String>('owned-game-detail-publish-progress'),
        ),
        findsNothing,
      );
      expect(
        tester.getSemantics(publish).flagsCollection.isEnabled,
        ui.Tristate.isTrue,
      );
      expect(
        tester.getSemantics(share).flagsCollection.isEnabled,
        ui.Tristate.isTrue,
      );
      expect(
        tester.getSemantics(delete).flagsCollection.isEnabled,
        ui.Tristate.isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Mine fast share failure keeps one reduced-motion busy frame', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = _publishedSurface('Fast Share', id: 85);
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[game]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    var nativeShareCalls = 0;
    gameFeedShareCallbackOverride =
        ({required title, required text, origin}) async {
          nativeShareCalls++;
          return false;
        };
    await _openOwnedGameActions(tester, game.id!, disableAnimations: true);

    final publish = find.byKey(
      const ValueKey<String>('owned-game-detail-publish'),
    );
    final share = find.byKey(const ValueKey<String>('owned-game-detail-share'));
    final delete = find.byKey(
      const ValueKey<String>('owned-game-detail-delete'),
    );
    await tester.tap(share);
    await tester.tap(share);
    await tester.pump();

    final progress = find.byKey(
      const ValueKey<String>('owned-game-detail-share-progress'),
    );
    expect(nativeShareCalls, 1);
    expect(progress, findsOneWidget);
    expect(
      find.descendant(
        of: progress,
        matching: find.byIcon(Icons.hourglass_top_rounded),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: progress,
        matching: find.byType(CircularProgressIndicator),
      ),
      findsNothing,
    );
    expect(
      tester.getSemantics(publish).flagsCollection.isEnabled,
      ui.Tristate.isFalse,
    );
    expect(
      tester.getSemantics(share).flagsCollection.isEnabled,
      ui.Tristate.isFalse,
    );
    expect(
      tester.getSemantics(delete).flagsCollection.isEnabled,
      ui.Tristate.isFalse,
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(progress, findsNothing);
    expect(find.text('Sharing unavailable'), findsOneWidget);
    expect(
      tester.getSemantics(share).flagsCollection.isEnabled,
      ui.Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mine action sheet unlocks when its callback throws', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game = _publishedSurface('Throwing Share', id: 86);
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[game]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    await _openOwnedGameActions(tester, game.id!);
    await appServices.delete<WidgetsHubController>(force: true);

    final share = find.byKey(const ValueKey<String>('owned-game-detail-share'));
    await tester.tap(share);
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-share-progress')),
      findsOneWidget,
    );

    await tester.pump();
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-share-progress')),
      findsNothing,
    );
    expect(find.text('Share failed'), findsOneWidget);
    expect(
      tester.getSemantics(share).flagsCollection.isEnabled,
      ui.Tristate.isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Mine accepts safe webApp publishing and explains missing URL', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final game =
        _surface('Legacy Game', <String, Object?>{'experienceType': 'game'})
          ..id = 82
          ..seen = true
          ..spec['rendering'] = 'webApp'
          ..spec['html'] = '''
<main id="game" class="game-shell">
  <button id="play" type="button">Play</button>
  <canvas id="stage" width="320" height="480"></canvas>
</main>
'''
          ..spec['css'] =
              '.game-shell{display:grid;min-height:100vh;background:#10131a;color:white}'
          ..spec['js'] = '''
const play = document.querySelector('#play');
const stage = document.querySelector('#stage');
const context = stage.getContext('2d');
play.addEventListener('click', () => {
  window.requestAnimationFrame(() => context.fillRect(8, 8, 24, 24));
});
''';
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[game]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('owned-game-more-82')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('owned-game-detail-publish')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-publish-progress')),
      findsOneWidget,
    );
    await tester.pump();
    expect(find.text('Publish failed'), findsOneWidget);
    expect(find.text('Publishing not supported'), findsNothing);
    ScaffoldMessenger.of(
      tester.element(find.byType(Scaffold).last),
    ).removeCurrentSnackBar();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('owned-game-detail-share')),
    );
    await tester.pump();

    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-share-progress')),
      findsOneWidget,
    );
    await tester.pump();
    expect(find.text('Publish first'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Mine cloud-only cards open management without starting a player',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'mine_cloud_game_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(
        ScopedAppletInventoryItem(
          scopeKey: 'device-legacy',
          item: AppletInventoryItem(
            id: 'ag_mine_cloud',
            clientSurfaceId: 'surface_mine_cloud',
            title: 'Cloud Mine',
            type: AppletCatalogType.game,
            summary: 'Stored on another device',
            published: false,
            viewCount: 8,
            likeCount: 3,
            commentCount: 2,
            updatedAt: DateTime.utc(2026, 8, 15),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('game-feed-tab-mine')),
      );
      await tester.pump();

      expect(
        find.byKey(const ValueKey<String>('owned-cloud-delete-ag_mine_cloud')),
        findsNothing,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-more-ag_mine_cloud'),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('owned-cloud-game-detail')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('owned-cloud-game-detail-rail')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('public-game-webview')), findsNothing);

      expect(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-detail-more-sheet'),
        ),
        findsOneWidget,
      );
      expect(
        (tester
                    .widget<Material>(
                      find.byKey(
                        const ValueKey<String>(
                          'owned-cloud-game-detail-more-sheet-surface',
                        ),
                      ),
                    )
                    .color!
                    .a *
                255)
            .round(),
        255,
      );
      expect(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-detail-actions-row'),
        ),
        findsOneWidget,
      );
      final publish = find.byKey(
        const ValueKey<String>('owned-cloud-game-detail-publish'),
      );
      final share = find.byKey(
        const ValueKey<String>('owned-cloud-game-detail-share'),
      );
      final delete = find.byKey(
        const ValueKey<String>('owned-cloud-game-detail-delete'),
      );
      expect(publish, findsOneWidget);
      expect(share, findsOneWidget);
      expect(delete, findsOneWidget);
      expect(
        tester.getCenter(publish).dx,
        lessThan(tester.getCenter(share).dx),
      );
      expect(tester.getCenter(share).dx, lessThan(tester.getCenter(delete).dx));
      await tester.tap(publish);
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-detail-publish-progress'),
        ),
        findsOneWidget,
      );
      await tester.pump();
      expect(find.text('Publish on the original device'), findsOneWidget);
      ScaffoldMessenger.of(
        tester.element(find.byType(Scaffold).last),
      ).removeCurrentSnackBar();
      await tester.pump();
      await tester.tap(share);
      await tester.pump();
      expect(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-detail-share-progress'),
        ),
        findsOneWidget,
      );
      await tester.pump();
      expect(find.text('Publish first'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'cloud-only cover management closes when the account scope changes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = _registerScopedAccount('account-a');
      final scopeKey = AppletLocalOwnership.currentScopeKey();
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'mine_cloud_scope_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(
        ScopedAppletInventoryItem(
          scopeKey: scopeKey,
          item: AppletInventoryItem(
            id: 'ag_scoped_cloud',
            clientSurfaceId: 'surface_scoped_cloud',
            title: 'Scoped Cloud Game',
            type: AppletCatalogType.game,
            summary: 'Private owner metadata',
            published: false,
            updatedAt: DateTime.utc(2026, 8, 15),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('game-feed-tab-mine')),
      );
      await tester.pump();
      await tester.tap(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-more-ag_scoped_cloud'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-detail-more-sheet'),
        ),
        findsOneWidget,
      );

      auth.session.value = _authSession('account-b');
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey<String>('owned-cloud-game-detail')),
        findsNothing,
      );
      expect(
        find.byKey(
          const ValueKey<String>('owned-cloud-game-detail-more-sheet'),
        ),
        findsNothing,
      );
      expect(find.text('Scoped Cloud Game'), findsNothing);
    },
  );

  testWidgets('local cover delete confirmation closes on a scope change', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final auth = _registerScopedAccount('account-a');
    final game =
        _surface('Scoped Local Game', <String, Object?>{
            'experienceType': 'game',
          })
          ..id = 72
          ..seen = true;
    AppletLocalOwnership.stamp(
      game,
      scopeKey: AppletLocalOwnership.currentScopeKey(),
    );
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[game]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();

    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey<String>('owned-game-more-72')));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey<String>('owned-game-detail-delete')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey<String>('owned-game-delete-confirmation')),
      findsOneWidget,
    );

    auth.session.value = _authSession('account-b');
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey<String>('owned-game-delete-confirmation')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('owned-game-detail-rail')),
      findsNothing,
    );
    expect(find.text('Scoped Local Game'), findsNothing);
  });

  testWidgets('canonical game metadata stays out of the Applets channel', (
    tester,
  ) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'canonical_game_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assign(
      _surface('Conflicted Game', <String, Object?>{
        'experienceType': 'game',
        'category': 'tools',
      }),
    );

    await tester.pumpWidget(const MaterialApp(home: WidgetsHubPage()));
    await tester.pump();
    expect(find.text('Conflicted Game'), findsNothing);

    controller.selectSection(AppletHubSection.games);
    await tester.pump();
    expect(find.text('Conflicted Game'), findsNothing);
    expect(find.byType(PageView), findsNothing);
  });

  testWidgets('Games closes committed global games but preserves utilities', (
    tester,
  ) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'scoped_game_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final globalRuntime = appServices.put(SurfaceRuntime());
    final healthGate = appServices.put(SurfaceWorkerHealthGate());
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.gameFeedItems.assign(_catalogGame('feed-game', 'Feed Game'));
    healthGate.beginPresentation();

    await globalRuntime.show(
      surfaceProjectFromWidget(
        _surface('Generated Global Game', <String, Object?>{
          'experienceType': 'game',
        }),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: GameFeedChannelTestHost()));
    await tester.pump();
    controller.selectSection(AppletHubSection.games);
    await tester.pump();
    await tester.pump();

    expect(find.text('Feed Game'), findsOneWidget);
    expect(globalRuntime.isVisible.value, isTrue);
    healthGate.cancelPresentation();
    EventBus().fire(WidgetCreatedEvent(41));
    await tester.pump();
    expect(globalRuntime.activeProject.value, isNull);

    await globalRuntime.show(
      SurfaceProject.fromJson(<String, Object?>{
        'id': 'global-utility',
        'title': 'Global utility',
        'kind': 'card',
        'rendering': 'dom',
        'experienceType': 'utility',
        'html': '<main>utility</main>',
        'css': '',
        'js': '',
      }),
    );
    await tester.pump();
    expect(find.text('Feed Game'), findsOneWidget);
    expect(globalRuntime.activeSurfaceId, 'global-utility');

    await globalRuntime.show(
      surfaceProjectFromWidget(
        _surface('Committed Global Game', <String, Object?>{
          'experienceType': 'game',
        }),
      ),
    );
    await tester.pump();
    expect(globalRuntime.isVisible.value, isTrue);
    EventBus().fire(WidgetCreatedEvent(42));
    await tester.pump();
    expect(globalRuntime.isVisible.value, isFalse);
    expect(find.text('Feed Game'), findsOneWidget);
  });

  testWidgets(
    'Applet search stays visible with a My shortcut and no category tabs',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path:
            'applet_search_toggle_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      appServices.put(WidgetsHubController());

      await tester.pumpWidget(const MaterialApp(home: WidgetsHubPage()));
      await tester.pump(const Duration(milliseconds: 400));

      final mine = find.byKey(const ValueKey<String>('applet-hub-mine'));
      expect(mine, findsOneWidget);
      expect(tester.getSize(mine).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(mine).height, greaterThanOrEqualTo(48));
      expect(
        find.byKey(const ValueKey<String>('applet-hub-search-toggle')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('applet-hub-search-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('applet-filter-all')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('game rail swipes static covers without mounting players', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'game_swipe_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assignAll(<AgentWidget>[
      _surface('Game One', <String, Object?>{'experienceType': 'game'}),
      _surface('Game Two', <String, Object?>{'experienceType': 'game'}),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: GameFeedChannelTestHost(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    controller.selectSection(AppletHubSection.games);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Game One'), findsOneWidget);
    expect(find.text('Game Two'), findsNothing);
    final interactive = tester.getRect(
      find.byType(GameScreenshotPreview).first,
    );
    final metadata = tester.getRect(
      find.byKey(const ValueKey<String>('game-feed-metadata-region')),
    );
    final rail = tester.getRect(
      find.byKey(const ValueKey<String>('game-swipe-rail')),
    );
    expect(interactive.overlaps(metadata), isTrue);
    expect(interactive.right, greaterThan(rail.left));

    await tester.fling(
      find.byKey(const ValueKey<String>('game-swipe-rail')),
      const Offset(0, -220),
      900,
    );
    await tester.pumpAndSettle();

    expect(find.text('Game One'), findsNothing);
    expect(find.text('Game Two'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_up_rounded), findsNothing);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsNothing);

    // The main content is also directly swipeable in both directions.
    await tester.fling(find.byType(PageView), const Offset(0, 220), 900);
    await tester.pumpAndSettle();
    expect(find.text('Game One'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(0, -220), 900);
    await tester.pumpAndSettle();
    expect(find.text('Game Two'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Games search hides browse entries and filters local games', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'game_search_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assignAll(<AgentWidget>[
      _surface('Matching Maze', <String, Object?>{'experienceType': 'game'}),
      _surface('Orbit Runner', <String, Object?>{'experienceType': 'game'}),
    ]);
    controller.gameFeedItems.assignAll(<AppletCatalogItem>[
      _catalogGame('browse-game', 'Browse Only'),
    ]);
    controller.searchResults.assignAll(<AppletCatalogItem>[
      _catalogGame('search-game', 'Matching Public Game'),
    ]);
    controller.searchQuery.value = 'matching';
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(const MaterialApp(home: GameFeedChannelTestHost()));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Matching Maze'), findsOneWidget);
    expect(find.text('Orbit Runner'), findsNothing);
    expect(find.text('Browse Only'), findsNothing);
    await tester.fling(
      find.byKey(const ValueKey<String>('game-swipe-rail')),
      const Offset(0, -220),
      900,
    );
    await tester.pumpAndSettle();
    expect(find.text('Matching Public Game'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('search contraction returns the PageView to a valid page', (
    tester,
  ) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'game_search_contract_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assignAll(<AgentWidget>[
      _surface('Only Match', <String, Object?>{'experienceType': 'game'}),
      _surface('Second Game', <String, Object?>{'experienceType': 'game'}),
      _surface('Third Game', <String, Object?>{'experienceType': 'game'}),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: true),
          child: GameFeedChannelTestHost(),
        ),
      ),
    );
    controller.selectSection(AppletHubSection.games);
    await tester.pump();
    final rail = find.byKey(const ValueKey<String>('game-swipe-rail'));
    await tester.fling(rail, const Offset(0, -220), 900);
    await tester.pump();
    await tester.fling(rail, const Offset(0, -220), 900);
    await tester.pump();
    expect(find.text('Third Game'), findsOneWidget);

    controller.searchQuery.value = 'game';
    await tester.pump();
    controller.searchQuery.value = 'only match';
    await tester.pump();
    await tester.pump();

    expect(find.text('Only Match'), findsOneWidget);
    expect(find.text('Third Game'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('public search replacement loads only the tapped cover URL', (
    tester,
  ) async {
    _registerPublicGameOrigin();
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'public_game_replace_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.gameFeedItems.assign(_catalogGame('browse-a', 'Browse A'));
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const GameFeedChannelTestHost(),
      ),
    );
    await tester.pump();
    expect(_loadedPublicGameUrls, isEmpty);

    controller.searchQuery.value = 'Search B';
    controller.searchResults.assign(_catalogGame('search-b', 'Search B'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Search B'), findsOneWidget);
    expect(_loadedPublicGameUrls, isEmpty);
    await tester.tap(
      find.byKey(const ValueKey<String>('game-feed-cover-search-b')),
    );
    await tester.pumpAndSettle();
    expect(_loadedPublicGameUrls.last.path, '/g/search-b/embed');
  });

  testWidgets('invalid local game activation stops at a retry state', (
    tester,
  ) async {
    final invalid = _surface('Invalid Game', <String, Object?>{
      'experienceType': 'game',
      'rendering': 'dom',
      'html': '<main>invalid</main>',
      'js': 'window.invalid=true;',
    });
    invalid.id = 800;
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[invalid]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const GameFeedChannelTestHost(),
      ),
    );
    await tester.pump();
    expect(find.byType(SurfaceWebView), findsNothing);
    await tester.tap(find.byKey(const ValueKey('game-feed-cover-800')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scoped worker fatal replaces the stopped canvas with retry', (
    tester,
  ) async {
    final fatalGame = _surface('Fatal Game', <String, Object?>{
      'experienceType': 'game',
    });
    fatalGame.id = 801;
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[fatalGame]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assign(fatalGame);
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const GameFeedChannelTestHost(),
      ),
    );
    await tester.pump();
    expect(find.byType(SurfaceWebView), findsNothing);
    await tester.tap(find.byKey(const ValueKey('game-feed-cover-801')));
    await tester.pump();
    await tester.pump();
    await tester.pump();
    expect(_javascriptChannels, contains('SurfaceLifecycle'));

    _javascriptChannels['SurfaceLifecycle']!(
      const JavaScriptMessage(
        message:
            '{"version":1,"session":1,"status":"fatal",'
            '"reason":"invalid_draw_commands"}',
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
    expect(find.byType(SurfaceWebView), findsNothing);
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('game-player-host')),
        matching: find.text('Fatal Game'),
      ),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('game-player-controls')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saved worker fatal is rejected before a visible WebView', (
    tester,
  ) async {
    final waiter = _RejectingFirstFrameWaiter();
    gameFeedFirstFrameWaiterOverride = waiter;
    final invalid = _surface('Broken Saved Game', <String, Object?>{
      'experienceType': 'game',
    });
    invalid.id = 802;
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[invalid]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const GameFeedChannelTestHost(),
      ),
    );
    await tester.pump();
    expect(find.byType(SurfaceWebView), findsNothing);
    await tester.tap(find.byKey(const ValueKey('game-feed-cover-802')));
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(waiter.beginCount, 1);
    expect(waiter.waitCount, 1);
    expect(waiter.cancelCount, 1);
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'snapshot change during saved game preflight never commits the Surface',
    (tester) async {
      final waiter = _BlockingFirstFrameWaiter();
      gameFeedFirstFrameWaiterOverride = waiter;
      final snapshots = appServices.put<AppCapabilitySnapshotService>(
        _surfaceCapabilities(AppHostPlatform.macos),
      );
      final pending = _surface('Pending Saved Game', <String, Object?>{
        'experienceType': 'game',
      })..id = 803;
      appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[pending]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.selectedSection.value = AppletHubSection.games;

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const GameFeedChannelTestHost(),
        ),
      );
      await tester.pump();
      expect(find.byType(SurfaceWebView), findsNothing);
      await tester.tap(find.byKey(const ValueKey('game-feed-cover-803')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(waiter.waitCount, 1);

      snapshots.refresh(snapshots.context.copyWith(rolloutGeneration: 1));
      waiter.complete();
      await tester.pump();
      await tester.pump();

      expect(waiter.cancelCount, 1);
      expect(find.byType(SurfaceWebView), findsNothing);
      expect(find.byIcon(Icons.refresh_rounded), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('unsupported host never starts a saved game Surface', (
    tester,
  ) async {
    final waiter = _BlockingFirstFrameWaiter();
    gameFeedFirstFrameWaiterOverride = waiter;
    appServices.put<AppCapabilitySnapshotService>(
      _surfaceCapabilities(AppHostPlatform.web),
    );
    final denied = _surface('Denied Saved Game', <String, Object?>{
      'experienceType': 'game',
    })..id = 804;
    appServices.put<DBService>(_FakeWidgetDBService(<AgentWidget>[denied]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(const MaterialApp(home: GameFeedChannelTestHost()));
    await tester.pump();
    await tester.pump();

    expect(waiter.beginCount, 0);
    expect(waiter.waitCount, 0);
    expect(find.byType(SurfaceWebView), findsNothing);
    expect(find.byKey(const ValueKey('game-feed-cover-804')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cloud-only games show covers without management controls in the feed',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'cloud_game_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assignAll(<ScopedAppletInventoryItem>[
        ScopedAppletInventoryItem(
          scopeKey: 'device-legacy',
          item: AppletInventoryItem(
            id: 'ag_cloud_game',
            clientSurfaceId: 'surface_cloud_game',
            title: 'Cloud Chess',
            type: AppletCatalogType.game,
            summary: 'Private cross-device game',
            published: false,
            updatedAt: DateTime.utc(2026, 8, 12),
          ),
        ),
      ]);
      controller.selectedSection.value = AppletHubSection.games;

      await tester.pumpWidget(
        const MaterialApp(home: GameFeedChannelTestHost()),
      );
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Cloud Chess'), findsWidgets);
      expect(
        find.byKey(const ValueKey<String>('game-feed-cover-ag_cloud_game')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('cloud-game-delete')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('game-interactive-test-host')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Applets page supports landscape and 2x dynamic type', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(844, 390);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'applet_landscape_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assignAll(<AgentWidget>[
      _surface('Landscape Arcade', <String, Object?>{'experienceType': 'game'}),
      _surface('Landscape Guide', <String, Object?>{'category': 'travel'}),
    ]);

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: true,
            textScaler: TextScaler.linear(2),
          ),
          child: MyAppletsPage(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Landscape Arcade'), findsNothing);
    await tester.drag(
      find.byKey(const ValueKey<String>('my-applets-list')),
      const Offset(0, -260),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Landscape Guide'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('applet-category-travel')),
      findsOneWidget,
    );

    controller.selectSection(AppletHubSection.games);
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Landscape Arcade'), findsNothing);
    expect(find.text('Landscape Guide'), findsOneWidget);
    expect(find.byType(PageView), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local game channel supports phone width and 2x dynamic type', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'applet_dynamic_type_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.widgets.assignAll(<AgentWidget>[
      _surface(
        'Portrait Dynamic Type Arcade With A Long Name',
        <String, Object?>{'experienceType': 'game'},
      ),
    ]);
    controller.selectedSection.value = AppletHubSection.games;

    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(
            disableAnimations: true,
            textScaler: TextScaler.linear(2),
          ),
          child: GameFeedChannelTestHost(),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));

    expect(
      find.text('Portrait Dynamic Type Arcade With A Long Name'),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('applet-category-game')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cloud Xiamen itinerary opens its trusted playable page, not management',
    (tester) async {
      appServices.put<DBService>(_FakeWidgetDBService([]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      final trip = _cloudTrip(published: true);
      controller.cloudOnlyItems.assign(trip);
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('widgets.empty'.tr), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      await tester.tap(find.text('厦门行程'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('cloud-applet-player')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('cloud-applet-management')),
        findsNothing,
      );
      expect(_loadedPublicGameUrls, [Uri.parse('${trip.item.shareUrl}/embed')]);
      expect(find.text(trip.item.title), findsNothing);
      expect(find.byKey(const ValueKey('applet-player-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('applet-player-like')), findsOneWidget);
      expect(
        _lastPublicGameNavigationRequest!(
          NavigationRequest(
            url: 'https://outside.example/g/redirect',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.prevent,
      );
      expect(
        _lastPublicGameNavigationRequest!(
          NavigationRequest(
            url: '${trip.item.shareUrl}/embed',
            isMainFrame: true,
          ),
        ),
        NavigationDecision.navigate,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'private cloud Applet explains missing original-device content on tap',
    (tester) async {
      appServices.put<DBService>(_FakeWidgetDBService([]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(_cloudTrip());
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('厦门行程'));
      await tester.pumpAndSettle();
      expect(
        find.text('widgets.cloud_applet_original_device'.tr),
        findsOneWidget,
      );
      expect(_loadedPublicGameUrls, isEmpty);
      expect(
        find.byKey(const ValueKey('cloud-applet-management')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'cloud Applet deletion requires management and confirmation; cancel does not delete',
    (tester) async {
      final database = _FakeWidgetDBService([]);
      appServices.put<DBService>(database);
      final requests = <String>[];
      appServices.put<AgentGameCloudService>(
        AgentGameCloudService(
          database: database,
          httpClient: MockClient((request) async {
            requests.add(request.url.path);
            return _agentGameOk({
              'clientSurfaceId': 'surface_xiamen',
              'deleted': true,
            });
          }),
          baseUri: () => Uri.parse('https://api.example.test/'),
          accessToken: () async => 'token',
          accountScope: () => AppletLocalOwnership.deviceLegacyScope,
        ),
      );
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(_cloudTrip());
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      await tester.longPress(find.text('厦门行程'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('cloud-applet-management')),
        findsOneWidget,
      );
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      expect(find.text('widgets.delete_title'.tr), findsOneWidget);
      expect(requests, isEmpty);
      await tester.tap(find.text('common.cancel'.tr));
      await tester.pumpAndSettle();
      expect(requests, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey('cloud-applet-more-ag_xiamen')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      expect(requests, ['/v1/agent-games/by-client/surface_xiamen/delete']);
      expect(controller.cloudOnlyItems, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('official Applets prevent a contradictory global empty state', (
    tester,
  ) async {
    appServices.put<DBService>(_FakeWidgetDBService([]));
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    await tester.pumpWidget(const MaterialApp(home: WidgetsHubPage()));
    await tester.pumpAndSettle();
    expect(find.text('widgets.official_badge'.tr), findsOneWidget);
    expect(find.text('widgets.empty'.tr), findsNothing);
  });

  testWidgets(
    'cloud Applet prefers a same-id local Surface over the published copy',
    (tester) async {
      appServices.put<AppCapabilitySnapshotService>(
        _surfaceCapabilities(AppHostPlatform.ios),
      );
      final local = _surface('Offline Xiamen itinerary', {
        'surfaceId': 'surface_xiamen',
        'rendering': 'dom',
        'html': '<main><h1>Offline itinerary</h1></main>',
        'css': '',
        'js': '',
      })..id = 999;
      appServices.put<DBService>(_FakeWidgetDBService([local]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(_cloudTrip(published: true));
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('厦门行程'));
      await tester.pumpAndSettle();
      expect(find.byType(SurfaceWebView), findsOneWidget);
      final host = tester.widget<SurfaceWebView>(find.byType(SurfaceWebView));
      expect(host.runtime!.activeProject.value!.id, 'surface_xiamen');
      expect(
        host.runtime!.activeProject.value!.html,
        contains('Offline itinerary'),
      );
      expect(_loadedPublicGameUrls, isEmpty);
      expect(find.byKey(const ValueKey('cloud-applet-player')), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 10));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'account switch during cloud Applet delete confirmation cannot delete',
    (tester) async {
      final auth = _registerScopedAccount('applet-a');
      appServices.put<DBService>(_FakeWidgetDBService([]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(
        _cloudTrip(scopeKey: AppletLocalOwnership.currentScopeKey()),
      );
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('cloud-applet-more-ag_xiamen')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      auth.session.value = _authSession('applet-b');
      await tester.pump();
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      expect(find.text('agent_games.delete_failed_title'.tr), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Applet library excludes the game category and game search results',
    (tester) async {
      appServices.put<DBService>(_FakeWidgetDBService([]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.searchQuery.value = 'game';
      controller.searchResults.assignAll([
        _catalogGame('excluded-game', 'Excluded Game'),
      ]);
      await tester.pumpWidget(const MaterialApp(home: WidgetsHubPage()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('applet-filter-game')), findsNothing);
      expect(find.text('Excluded Game'), findsNothing);
      expect(controller.selectedSection.value, AppletHubSection.applets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local Applet More deletes only after confirmation and shows My empty',
    (tester) async {
      final local = _surface('Kyoto trip', {'category': 'travel'})..id = 1001;
      final database = _FakeWidgetDBService([local]);
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      await tester.tap(
        find.byTooltip('widgets.manage_named'.trParams({'name': local.title})),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      expect(database.widgets, hasLength(1));
      await tester.tap(find.text('widgets.action_delete'.tr));
      await tester.pumpAndSettle();
      expect(database.widgets, isEmpty);
      expect(find.text('widgets.empty'.tr), findsNothing);
      expect(find.text('widgets.mine_empty'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final size in [const Size(390, 844), const Size(844, 390)]) {
    testWidgets(
      'cloud Applet matte card keeps a clear tap target at 2x text $size',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        appServices.put<DBService>(_FakeWidgetDBService([]));
        final controller = appServices.put(WidgetsHubController());
        await controller.reload();
        controller.cloudOnlyItems.assign(_cloudTrip());
        controller.selectCategory(AppletCategory.travel);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: const MyAppletsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final more = find.byKey(const ValueKey('cloud-applet-more-ag_xiamen'));
        await tester.ensureVisible(more);
        expect(tester.getSize(more).shortestSide, greaterThanOrEqualTo(48));
        final cards = tester.widgetList<Material>(
          find.ancestor(of: find.text('厦门行程'), matching: find.byType(Material)),
        );
        final glass = MaasoGlassTheme.of(tester.element(find.text('厦门行程')));
        expect(
          cards.any((card) => card.color == glass.muted && card.elevation == 0),
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final change in [
    'reorder',
    'replace',
    'replace-client',
    'refresh-same',
    'management-replace',
    'account-replace',
  ]) {
    testWidgets(
      'cloud Applet confirmation keeps its captured target through $change',
      (tester) async {
        final auth = _registerScopedAccount('target-a');
        final database = _BlockingCloudReadDB();
        appServices.put<DBService>(database);
        final requests = <String>[];
        appServices.put<AgentGameCloudService>(
          AgentGameCloudService(
            database: database,
            httpClient: MockClient((request) async {
              requests.add(request.url.path);
              final clientId = request.url.pathSegments[3];
              return _agentGameOk({
                'clientSurfaceId': clientId,
                'deleted': true,
              });
            }),
            baseUri: () => Uri.parse('https://api.example.test/'),
            accessToken: () async => 'token',
            accountScope: AppletLocalOwnership.currentScopeKey,
          ),
        );
        final controller = appServices.put(WidgetsHubController());
        await controller.reload();
        ScopedAppletInventoryItem record(
          String id, {
          String? clientId,
          String? title,
        }) => ScopedAppletInventoryItem(
          scopeKey: AppletLocalOwnership.currentScopeKey(),
          item: AppletInventoryItem(
            id: 'ag_$id',
            clientSurfaceId: clientId ?? 'surface_$id',
            title: title ?? 'Travel $id',
            type: AppletCatalogType.applet,
            summary: 'Travel itinerary',
            published: false,
            updatedAt: DateTime.utc(2026, 9, 14),
          ),
        );
        final a = record('a');
        final b = record('b');
        controller.cloudOnlyItems.assignAll(change == 'reorder' ? [a, b] : [a]);
        controller.selectCategory(AppletCategory.travel);
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            home: const MyAppletsPage(),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('cloud-applet-more-ag_a')));
        await tester.pumpAndSettle();
        if (change != 'management-replace') {
          await tester.tap(find.text('widgets.action_delete'.tr));
          await tester.pumpAndSettle();
          expect(
            find.text(
              'game_feed.delete_confirm'.trParams({'name': a.item.title}),
            ),
            findsOneWidget,
          );
        }
        if (change == 'account-replace') {
          database.blockedRead = Completer<List<AgentWidget>>();
          auth.session.value = _authSession('target-b');
          controller.cloudOnlyItems.assign(record('b'));
        } else if (change == 'reorder') {
          controller.cloudOnlyItems.assignAll([b, a]);
        } else if (change == 'refresh-same') {
          controller.cloudOnlyItems.assign(
            record('a', title: 'Updated Travel a'),
          );
        } else if (change == 'replace-client') {
          controller.cloudOnlyItems.assign(
            record('a', clientId: 'surface_changed'),
          );
        } else {
          controller.cloudOnlyItems.assign(b);
        }
        if (database.blockedRead != null) {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        } else {
          await tester.pumpAndSettle();
        }
        if (change == 'account-replace') {
          expect(
            find.byKey(const ValueKey('owned-game-delete-confirmation')),
            findsNothing,
          );
        } else {
          await tester.tap(find.text('widgets.action_delete'.tr));
        }
        if (database.blockedRead != null) {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
        } else {
          await tester.pumpAndSettle();
        }
        expect(
          requests,
          change == 'refresh-same'
              ? ['/v1/agent-games/by-client/surface_a/delete']
              : isEmpty,
        );
        expect(
          find.byKey(const ValueKey('owned-game-delete-confirmation')),
          findsNothing,
        );
        database.blockedRead?.complete([]);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'replacing a cloud card during its local lookup cancels the old open',
    (tester) async {
      final database = _BlockingCloudReadDB();
      appServices.put<DBService>(database);
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.cloudOnlyItems.assign(_cloudTrip(published: true));
      controller.selectCategory(AppletCategory.travel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const MyAppletsPage(),
        ),
      );
      await tester.pumpAndSettle();
      database.blockedRead = Completer<List<AgentWidget>>();
      await tester.tap(find.text('厦门行程'));
      await tester.pump();
      controller.cloudOnlyItems.assign(
        ScopedAppletInventoryItem(
          scopeKey: AppletLocalOwnership.currentScopeKey(),
          item: AppletInventoryItem(
            id: 'ag_new',
            clientSurfaceId: 'surface_new',
            title: 'New itinerary',
            type: AppletCatalogType.applet,
            summary: 'Travel',
            published: true,
            shareUrl: Uri.parse('https://api.example.test/g/new'),
            updatedAt: DateTime.utc(2026, 9, 14),
          ),
        ),
      );
      await tester.pump();
      database.blockedRead!.complete([]);
      await tester.pumpAndSettle();
      expect(_loadedPublicGameUrls, isEmpty);
      expect(find.byKey(const ValueKey('cloud-applet-player')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'game cover taps paint loading before fetching and cannot push twice',
    (tester) async {
      final response = Completer<http.Response>();
      var documents = 0;
      GameDocumentLoader.debugClientFactory = () => MockClient((request) {
        documents++;
        return response.future;
      });
      await _publicGameHarness(tester);
      expect(documents, 0);
      expect(_loadedPublicGameUrls, isEmpty);
      expect(find.byType(SurfaceWebView), findsNothing);
      final cover = find.byKey(const ValueKey('game-feed-cover-lazy-open'));
      final tap = tester
          .widget<InkWell>(
            find.descendant(of: cover, matching: find.byType(InkWell)).first,
          )
          .onTap!;
      tap();
      tap();
      await tester.pump();
      await tester.pump();
      expect(documents, 1);
      expect(find.byKey(const ValueKey('public-game-loading')), findsOneWidget);
      expect(find.byKey(const ValueKey('public-game-webview')), findsNothing);
      response.complete(_gameDocumentResponse());
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(documents, 1);
      expect(_loadedPublicGameUrls, hasLength(1));
      expect(find.byKey(const ValueKey('public-game-webview')), findsOneWidget);
      rootNavigatorKey.currentState!.pop();
      await tester.pumpAndSettle();
    },
  );

  for (final cancellation in [
    'back',
    'environment',
    'background',
    'configuration-back',
  ]) {
    testWidgets(
      'game loading cancels $cancellation without a late WebView document',
      (tester) async {
        final response = Completer<http.Response>();
        final configuration = Completer<void>();
        if (cancellation == 'configuration-back') {
          _publicGameJavaScriptModeBlocker = configuration;
        }
        GameDocumentLoader.debugClientFactory = () =>
            MockClient((request) => response.future);
        await _publicGameHarness(tester);
        await tester.tap(
          find.byKey(const ValueKey('game-feed-cover-lazy-open')),
        );
        await tester.pump();
        await tester.pump();
        if (cancellation == 'configuration-back') {
          response.complete(_gameDocumentResponse());
          await tester.pump();
        }
        if (cancellation == 'environment') {
          appServices.find<AppEnvironmentService>().environment.value =
              MaasoEnvironment.production;
          await tester.pump();
        } else if (cancellation == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.paused,
          );
          await tester.pump();
        } else {
          rootNavigatorKey.currentState!.pop();
          await tester.pump(const Duration(milliseconds: 500));
        }
        if (!response.isCompleted) response.complete(_gameDocumentResponse());
        configuration.complete();
        _publicGameJavaScriptModeBlocker = null;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(_loadedPublicGameUrls, isEmpty);
        expect(find.byKey(const ValueKey('public-game-webview')), findsNothing);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        // The paused ticker cannot finish AnimatedSwitcher's outgoing child.
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(const ValueKey('public-game-loading')), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'game fetch failure stays dark and retry starts exactly one new download',
    (tester) async {
      var requests = 0;
      GameDocumentLoader.debugClientFactory = () => MockClient((request) async {
        requests++;
        return requests == 1
            ? http.Response('offline', 503)
            : _gameDocumentResponse();
      });
      await _publicGameHarness(tester);
      await tester.tap(find.byKey(const ValueKey('game-feed-cover-lazy-open')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(requests, 1);
      expect(_loadedPublicGameUrls, isEmpty);
      final failure = find.byKey(const ValueKey('public-game-load-error'));
      expect(failure, findsOneWidget);
      final background = tester.widget<ColoredBox>(
        find.descendant(of: failure, matching: find.byType(ColoredBox)).first,
      );
      expect(background.color.computeLuminance(), lessThan(.02));
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(requests, 2);
      expect(_loadedPublicGameUrls, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'back during local first-frame validation releases pending runtime',
    (tester) async {
      final waiter = _BlockingFirstFrameWaiter();
      gameFeedFirstFrameWaiterOverride = waiter;
      final game = _surface('Cancel Local', {'experienceType': 'game'})
        ..id = 990;
      appServices.put<DBService>(_FakeWidgetDBService([game]));
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: const GameFeedChannelTestHost(),
        ),
      );
      await tester.pump();
      expect(waiter.beginCount, 0);
      await tester.tap(find.byKey(const ValueKey('game-feed-cover-990')));
      await tester.pump();
      await tester.pump();
      expect(waiter.waitCount, 1);
      expect(find.byType(SurfaceWebView), findsNothing);
      rootNavigatorKey.currentState!.pop();
      await tester.pump(const Duration(milliseconds: 500));
      waiter.complete();
      await tester.pump();
      await tester.pump();
      expect(find.byType(SurfaceWebView), findsNothing);
      expect(waiter.cancelCount, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

AuthSessionService _registerScopedAccount(String accountUuid) {
  appServices.put<SecureStorageService>(SecureStorageService());
  appServices.put(AppEnvironmentService());
  final auth = appServices.put(AuthSessionService());
  auth.session.value = _authSession(accountUuid);
  return auth;
}

MaasoAuthSession _authSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

AgentWidget _surface(String title, Map<String, Object?> metadata) {
  final game = metadata['experienceType'] == 'game';
  return AgentWidget(
    agentId: 'self',
    title: title,
    kind: 'surface',
    spec: <String, Object?>{
      'surfaceId': 'surface_${title.replaceAll(' ', '_')}',
      'surfaceKind': 'card',
      if (game) ...<String, Object?>{
        'rendering': 'workerCanvas',
        'html': '',
        'css': '',
        'js':
            'Game.define({init(){return {};},update(state){return state;},draw(){return [{type:"clear",color:"#000"}];},input(state){return state;}});',
      },
      ...metadata,
    },
    createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  );
}

AgentWidget _publishedSurface(String title, {required int id}) {
  final game = _surface(title, <String, Object?>{'experienceType': 'game'})
    ..id = id
    ..seen = true;
  AppletLocalOwnership.stamp(
    game,
    scopeKey: AppletLocalOwnership.deviceLegacyScope,
  );
  game.spec['cloud'] = AgentGameCloudMetadata(
    gameId: 'ag_$id',
    revisionNo: 1,
    sourceSha256: 'source-$id',
    syncState: AgentGameSyncState.published,
    scopeKey: AppletLocalOwnership.deviceLegacyScope,
    hasPublished: true,
    publishedRevisionNo: 1,
    publishedSourceSha256: 'source-$id',
    shareUrl: 'https://api.example.test/g/$id',
  ).toJson();
  return game;
}

Future<void> _openOwnedGameActions(
  WidgetTester tester,
  int gameId, {
  bool disableAnimations = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(
        navigatorKey: rootNavigatorKey,
        home: const GameFeedPage(),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.byKey(const ValueKey<String>('game-feed-tab-mine')));
  await tester.pump();
  await tester.tap(find.byKey(ValueKey<String>('owned-game-more-$gameId')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('game-player-host')), findsNothing);
  expect(find.byType(SurfaceWebView), findsNothing);
}

AppletCatalogItem _catalogGame(String id, String title) => AppletCatalogItem(
  id: id,
  title: title,
  type: AppletCatalogType.game,
  summary: '$title summary',
  author: const AppletCatalogAuthor(
    agentId: 'aa_0123456789abcdef0123456789abcdef',
    displayName: 'Agent 0123456789ABCDEF',
    verified: false,
  ),
  shareUrl: Uri.parse('https://api.example.test/g/$id'),
  updatedAt: DateTime.utc(2026, 8, 12),
);

http.Response _agentGameOk(Map<String, Object?> data) {
  final responseData = <String, Object?>{...data};
  if (responseData.containsKey('clientSurfaceId')) {
    responseData.putIfAbsent('experienceType', () => 'game');
  }
  return http.Response(
    jsonEncode(<String, Object?>{'code': 'OK', 'data': responseData}),
    200,
    headers: const <String, String>{'content-type': 'application/json'},
  );
}

class _FakeWidgetDBService extends DBService {
  _FakeWidgetDBService(this.widgets);

  final List<AgentWidget> widgets;

  @override
  Future<List<AgentWidget>> getAllWidgets() async =>
      List<AgentWidget>.of(widgets);

  @override
  Future<void> updateWidgetSpecField(int id, String key, Object? value) async {
    final item = widgets.firstWhere((candidate) => candidate.id == id);
    item.spec = <String, Object?>{...item.spec, key: value};
  }

  @override
  Future<void> deleteWidgetValidated(
    int id, {
    required bool Function(AgentWidget current) validate,
  }) async {
    final index = widgets.indexWhere((item) => item.id == id);
    if (index < 0) return;
    final current = widgets[index];
    if (!validate(current)) throw StateError('Widget ownership changed');
    widgets.removeAt(index);
    if (!validate(current)) throw StateError('Widget ownership changed');
  }
}

class _RejectingFirstFrameWaiter implements SurfaceWorkerFirstFrameWaiter {
  int beginCount = 0;
  int waitCount = 0;
  int cancelCount = 0;

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {
    beginCount++;
  }

  @override
  void cancelPresentation() {
    cancelCount++;
  }

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) {
    waitCount++;
    return Future<void>.error(
      const SurfaceWorkerFirstFrameException.fatal(
        SurfaceWorkerFatalReason.invalidDrawCommands,
      ),
    );
  }
}

class _BlockingFirstFrameWaiter implements SurfaceWorkerFirstFrameWaiter {
  final Completer<void> _completion = Completer<void>();
  int beginCount = 0;
  int waitCount = 0;
  int cancelCount = 0;

  void complete() => _completion.complete();

  @override
  void beginPresentation({SurfaceRuntime? runtime}) {
    beginCount++;
  }

  @override
  void cancelPresentation() {
    cancelCount++;
  }

  @override
  Future<void> waitForFirstFrame({
    required int session,
    required String document,
    required Duration timeout,
  }) {
    waitCount++;
    return _completion.future;
  }
}

class _FakeWebViewPlatform extends WebViewPlatform {
  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => _FakePlatformWebViewController(params);

  @override
  PlatformWebViewWidget createPlatformWebViewWidget(
    PlatformWebViewWidgetCreationParams params,
  ) => _FakePlatformWebViewWidget(params);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _FakePlatformNavigationDelegate(params);
}

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController(super.params) : super.implementation();

  _FakePlatformNavigationDelegate? _navigationDelegate;
  Uri? _loadingUri;

  void finishPage() {
    final uri = _loadingUri;
    if (uri != null) _navigationDelegate?.onPageFinished?.call(uri.toString());
  }

  void failPage() {
    final uri = _loadingUri;
    if (uri == null) return;
    _navigationDelegate?.onWebResourceError?.call(
      WebResourceError(
        errorCode: -1,
        description: 'test game load failed',
        isForMainFrame: true,
        url: uri.toString(),
      ),
    );
  }

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    _javascriptChannels[params.name] = params.onMessageReceived;
  }

  @override
  Future<void> loadHtmlString(String html, {String? baseUrl}) async {
    final uri = Uri.tryParse(baseUrl ?? '');
    if (uri == null || !uri.path.startsWith('/g/')) return;
    _loadedPublicGameUrls.add(uri);
    _loadingUri = uri;
    _lastPublicGameController = this;
    await Future<void>.microtask(() {
      _navigationDelegate?.onPageStarted?.call(uri.toString());
      if (_autoFinishPublicGameLoads) finishPage();
    });
  }

  @override
  Future<void> loadRequest(LoadRequestParams params) async {
    _loadedPublicGameUrls.add(params.uri);
    _loadingUri = params.uri;
    if (params.uri.path.startsWith('/g/')) {
      _lastPublicGameController = this;
    }
    await Future<void>.microtask(() {
      _navigationDelegate?.onPageStarted?.call(params.uri.toString());
      if (_autoFinishPublicGameLoads) finishPage();
    });
  }

  @override
  Future<void> runJavaScript(String javaScript) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> setJavaScriptMode(JavaScriptMode javaScriptMode) async {
    final blocker = _publicGameJavaScriptModeBlocker;
    if (blocker != null) await blocker.future;
  }

  @override
  Future<void> setOnConsoleMessage(
    void Function(JavaScriptConsoleMessage consoleMessage) onConsoleMessage,
  ) async {}

  @override
  Future<void> setPlatformNavigationDelegate(
    covariant PlatformNavigationDelegate handler,
  ) async {
    if (handler is _FakePlatformNavigationDelegate) {
      _navigationDelegate = handler;
    }
  }
}

class _FakePlatformNavigationDelegate extends PlatformNavigationDelegate {
  _FakePlatformNavigationDelegate(super.params) : super.implementation();

  PageEventCallback? onPageStarted;
  PageEventCallback? onPageFinished;
  WebResourceErrorCallback? onWebResourceError;

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback onNavigationRequest,
  ) async {
    _lastPublicGameNavigationRequest = onNavigationRequest;
  }

  @override
  Future<void> setOnPageStarted(PageEventCallback onPageStarted) async {
    this.onPageStarted = onPageStarted;
  }

  @override
  Future<void> setOnPageFinished(PageEventCallback onPageFinished) async {
    this.onPageFinished = onPageFinished;
  }

  @override
  Future<void> setOnWebResourceError(
    WebResourceErrorCallback onWebResourceError,
  ) async {
    this.onWebResourceError = onWebResourceError;
  }
}

class _FakePlatformWebViewWidget extends PlatformWebViewWidget {
  _FakePlatformWebViewWidget(super.params) : super.implementation();

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

ScopedAppletInventoryItem _cloudTrip({
  bool published = false,
  String? scopeKey,
}) => ScopedAppletInventoryItem(
  scopeKey: scopeKey ?? AppletLocalOwnership.deviceLegacyScope,
  item: AppletInventoryItem(
    id: 'ag_xiamen',
    clientSurfaceId: 'surface_xiamen',
    title: '厦门行程',
    type: AppletCatalogType.applet,
    summary: '厦门三日旅行计划',
    published: published,
    shareUrl: published ? Uri.parse('https://api.example.test/g/xiamen') : null,
    updatedAt: DateTime.utc(2026, 9, 14),
  ),
);

class _BlockingCloudReadDB extends DBService {
  Completer<List<AgentWidget>>? blockedRead;

  @override
  Future<List<AgentWidget>> getAllWidgets() async =>
      blockedRead?.future ?? <AgentWidget>[];
}

void _registerPublicGameOrigin() {
  appServices.put<SecureStorageService>(SecureStorageService());
  appServices.put<AppEnvironmentService>(_PublicGameEnvironment());
}

class _PublicGameEnvironment extends AppEnvironmentService {
  @override
  Uri get baseUri => Uri.parse(
    environment.value == MaasoEnvironment.test
        ? 'https://api.example.test/'
        : 'https://api-other.example.test/',
  );
}

http.Response _gameDocumentResponse() => http.Response(
  '<html><head></head><body><canvas></canvas></body></html>',
  200,
  headers: {
    'content-type': 'text/html',
    'content-security-policy':
        "default-src 'none'; script-src 'unsafe-inline'; sandbox allow-scripts",
  },
);

Future<void> _publicGameHarness(WidgetTester tester) async {
  _registerPublicGameOrigin();
  final database = await DBService().init(
    factory: databaseFactoryMemory,
    path: 'lazy_loading.db',
  );
  appServices.put<DBService>(database);
  final controller = appServices.put(WidgetsHubController());
  await controller.reload();
  controller.gameFeedItems.assign(_catalogGame('lazy-open', 'Lazy Open'));
  await tester.pumpWidget(
    MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
  );
  await tester.pump();
}
