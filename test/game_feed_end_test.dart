import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_frost_chrome.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';

const _endKey = ValueKey('game-feed-end');
const _railKey = ValueKey('game-swipe-rail');
const _createKey = ValueKey('game-feed-create-game');
const _continuationKey = ValueKey('game-feed-continuation');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    GameScreenshotStore.debugClientFactory = () =>
        MockClient((_) async => http.Response('', 404));
    GameScreenshotPreview.clearCache();
    gameFeedImpressionOverride = (_) {};
  });

  tearDown(() async {
    GameScreenshotStore.debugClientFactory = null;
    GameScreenshotPreview.clearCache();
    gameFeedImpressionOverride = null;
    gameFeedImpressionRecorderOverride = null;
    gameFeedImpressionScopeKeyOverride = null;
    await appServices.reset();
  });

  test(
    'unrequested feeds and successful empty feeds are not the end',
    () async {
      final h = await _harness((_) async => _page());
      for (final sort in GameFeedSort.values) {
        expect(h.controller.hasReachedGameFeedEndFor(sort), isFalse);
        await h.controller.loadGameFeed(sort: sort);
        expect(h.controller.gameFeedItemsFor(sort), isEmpty);
        expect(h.controller.hasReachedGameFeedEndFor(sort), isFalse);
      }
    },
  );

  test(
    'only a completed nonempty page without a cursor reaches the end',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final h = await _harness((_) {
        started.complete();
        return response.future;
      });
      final loading = h.controller.loadGameFeed();
      await started.future;
      expect(
        h.controller.gameFeedLoadingFor(GameFeedSort.recommended).value,
        isTrue,
      );
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
      response.complete(_page(ids: ['first']));
      await loading;
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isTrue,
      );
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.popular),
        isFalse,
      );
    },
  );

  test(
    'pagination failure preserves games and retries the same cursor',
    () async {
      final cursors = <String?>[];
      var failMore = true;
      final h = await _harness((request) async {
        final cursor = request.url.queryParameters['cursor'];
        cursors.add(cursor);
        if (cursor == null) return _page(ids: ['first'], cursor: 'next');
        if (failMore) return http.Response('offline', 503);
        return _page(ids: ['first', 'last']);
      });
      await h.controller.loadGameFeed();
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
      await h.controller.loadGameFeed(loadMore: true);
      expect(h.controller.recommendedGameFeedItems.map((e) => e.id), ['first']);
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
      expect(
        h.controller.gameFeedErrorFor(GameFeedSort.recommended).value,
        isNotNull,
      );
      failMore = false;
      await h.controller.loadGameFeed(loadMore: true);
      expect(cursors, [null, 'next', 'next']);
      expect(h.controller.recommendedGameFeedItems.map((e) => e.id), [
        'first',
        'last',
      ]);
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isTrue,
      );
    },
  );

  test(
    'refresh clears completed status immediately and failure cannot restore it',
    () async {
      final response = Completer<http.Response>();
      var requests = 0;
      final h = await _harness((_) async {
        if (++requests == 1) return _page(ids: ['first']);
        return response.future;
      });
      await h.controller.loadGameFeed();
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isTrue,
      );
      final refreshing = h.controller.loadGameFeed();
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
      response.complete(http.Response('offline', 503));
      await refreshing;
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
      expect(h.controller.recommendedGameFeedItems, isEmpty);
    },
  );

  test(
    'account changes revoke a completed end before the next response',
    () async {
      final h = await _harness((_) async => _page(ids: ['first']));
      await h.controller.loadGameFeed();
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isTrue,
      );
      h.auth.session.value = _session('account-b');
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
      await Future<void>.delayed(Duration.zero);
      expect(h.controller.recommendedGameFeedItems, isEmpty);
    },
  );

  test(
    'late success from an old account cannot complete the new feed',
    () async {
      final response = Completer<http.Response>();
      final started = Completer<void>();
      final h = await _harness((request) {
        if (request.url.queryParameters['type'] != 'game')
          return Future.value(_page());
        started.complete();
        return response.future;
      });
      final loading = h.controller.loadGameFeed();
      await started.future;
      h.auth.session.value = _session('account-b');
      response.complete(_page(ids: ['old-account']));
      await loading;
      expect(h.controller.recommendedGameFeedItems, isEmpty);
      expect(
        h.controller.hasReachedGameFeedEndFor(GameFeedSort.recommended),
        isFalse,
      );
    },
  );

  testWidgets('empty catalog uses empty state, never the creation end page', (
    tester,
  ) async {
    await _widgetHarness(tester, (_) async => _page());
    expect(find.text('game_feed.empty_public'.tr), findsOneWidget);
    expect(find.byKey(_endKey), findsNothing);
    expect(find.byKey(_createKey), findsNothing);
    expect(find.byKey(_railKey), findsNothing);
    expect(
      find.byKey(const ValueKey('game-feed-companion-play')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('companion-play-catalog')), findsNothing);
    expect(find.byKey(const ValueKey('game-feed-back')), findsOneWidget);
  });

  testWidgets(
    'initial loading and failure show progress and retry, not the end',
    (tester) async {
      final response = Completer<http.Response>();
      final h = await tester.runAsync(() => _harness((_) => response.future));
      await tester.pumpWidget(const MaterialApp(home: GameFeedPage()));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.byKey(_endKey), findsNothing);
      response.complete(http.Response('offline', 503));
      await tester.pumpAndSettle();
      expect(
        h!.controller.gameFeedErrorFor(GameFeedSort.recommended).value,
        isNotNull,
      );
      expect(find.byTooltip('common.retry'.tr), findsOneWidget);
      expect(find.byKey(_endKey), findsNothing);
    },
  );

  testWidgets(
    'pagination has a retry page and only a successful retry shows the end',
    (tester) async {
      final more = Completer<http.Response>();
      var retries = 0;
      await _widgetHarness(tester, (request) async {
        if (request.url.queryParameters['cursor'] == null) {
          return _page(ids: ['first'], cursor: 'next');
        }
        if (++retries == 1) return more.future;
        return _page();
      }, settle: false);
      await _jumpTo(tester, 1);
      expect(find.byKey(_continuationKey), findsOneWidget);
      expect(find.byKey(_railKey), findsNothing);
      expect(find.byKey(_endKey), findsNothing);
      more.complete(http.Response('offline', 503));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('common.retry'.tr));
      await tester.pumpAndSettle();
      expect(retries, 2);
      expect(find.byKey(_endKey), findsOneWidget);
      expect(find.byKey(_createKey), findsOneWidget);
      expect(find.byKey(_railKey), findsNothing);
    },
  );

  testWidgets(
    'end page cancels the previous game impression and supports returning',
    (tester) async {
      final views = <String>[];
      gameFeedImpressionOverride = (item) => views.add(item.id);
      await _widgetHarness(tester, (_) async => _page(ids: ['first']));
      await tester.pump(const Duration(milliseconds: 500));
      await _jumpTo(tester, 1);
      await tester.pump(const Duration(seconds: 3));
      expect(views, isEmpty);
      expect(find.byKey(_endKey), findsOneWidget);
      expect(find.byKey(_railKey), findsNothing);
      await _jumpTo(tester, 0);
      await tester.pump(const Duration(seconds: 2));
      expect(views, ['first']);
      await _jumpTo(tester, 1);
      await _jumpTo(tester, 0);
      await tester.pump(const Duration(seconds: 3));
      expect(views, ['first']);
    },
  );

  testWidgets(
    'creation passes one typed intent and pop restores the end position',
    (tester) async {
      await tester.runAsync(() async {
        final h = await _harness((_) async => _page(ids: ['first']));
        await h.controller.loadGameFeed();
      });
      appServices.put(
        GameVoiceCompanionService(
          browsingContext: CompanionBrowsingContextService(),
          commentary: (_, {required isCurrent, required onRevoked}) async =>
              false,
        ),
      );
      final intents = <HomeDraftIntent>[];
      final router = GoRouter(
        navigatorKey: rootNavigatorKey,
        initialLocation: AppRouteCatalog.gameFeed,
        routes: [
          GoRoute(
            path: AppRouteCatalog.gameFeed,
            builder: (_, _) => const GameFeedPage(),
          ),
          GoRoute(
            path: AppRouteCatalog.home,
            builder: (_, state) {
              final intent = state.extra! as HomeDraftIntent;
              if (!intents.contains(intent)) intents.add(intent);
              return const Scaffold(body: Text('Game draft destination'));
            },
          ),
        ],
      );
      appNavigation.configure(router);
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      await tester.pumpAndSettle();
      await _jumpTo(tester, 1);
      final create = tester
          .widget<AppGlassButton>(find.byKey(_createKey))
          .onPressed!;
      create();
      create();
      await tester.pumpAndSettle();
      expect(intents, hasLength(1));
      expect(
        intents.single.consume(
          currentScopeKey: AppletLocalOwnership.currentScopeKey(),
          existingDraft: '',
        ),
        'game_feed.create_game_prompt'.tr,
      );
      expect(router.canPop(), isTrue);
      router.pop();
      await tester.pumpAndSettle();
      expect(find.byKey(_endKey), findsOneWidget);
      expect(find.byKey(_railKey), findsNothing);
      expect(_pager(tester).controller!.page, 1);
      expect(
        tester.widget<AppGlassButton>(find.byKey(_createKey)).onPressed,
        isNotNull,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final scenario in [
    (
      name: 'short-landscape-largest-text',
      size: const Size(667, 320),
      scale: 3.0,
      padding: const EdgeInsets.only(left: 44, right: 44, bottom: 21),
    ),
    (
      name: 'phone',
      size: const Size(375, 812),
      scale: 1.0,
      padding: const EdgeInsets.only(top: 44, bottom: 34),
    ),
    (
      name: 'small-large',
      size: const Size(320, 568),
      scale: 2.0,
      padding: const EdgeInsets.only(top: 24, bottom: 24),
    ),
    (
      name: 'landscape-large',
      size: const Size(812, 375),
      scale: 2.0,
      padding: const EdgeInsets.only(left: 44, right: 44, bottom: 21),
    ),
  ]) {
    testWidgets('rail fits safe areas with 48px actions: ${scenario.name}', (
      tester,
    ) async {
      tester.view.physicalSize = scenario.size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final h = await _harness((_) async => _page(ids: ['first']));
        await h.controller.loadGameFeed();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: scenario.size,
              padding: scenario.padding,
              textScaler: TextScaler.linear(scenario.scale),
              disableAnimations: true,
            ),
            child: const GameFeedPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final rail = find.byKey(_railKey);
      expect(
        find.byKey(const ValueKey('game-companion-controls')),
        findsNothing,
      );
      final buttons = find.descendant(
        of: rail,
        matching: find.byType(GameFrostIconButton),
      );
      expect(buttons, findsNWidgets(4));
      final rects = tester
          .elementList(buttons)
          .map(
            (e) => tester.getRect(
              find.byElementPredicate((candidate) => identical(e, candidate)),
            ),
          )
          .toList();
      for (final rect in rects) {
        expect(rect.size, const Size.square(48));
        expect(
          rect.top,
          greaterThanOrEqualTo(math.max(8, scenario.padding.top)),
        );
        expect(
          rect.bottom,
          lessThanOrEqualTo(
            scenario.size.height - math.max(8, scenario.padding.bottom),
          ),
        );
        expect(
          rect.right,
          lessThanOrEqualTo(scenario.size.width - scenario.padding.right),
        );
      }
      for (var index = 1; index < rects.length; index++) {
        expect(
          rects[index].top - rects[index - 1].bottom,
          greaterThanOrEqualTo(8),
        );
      }
      if (scenario.name == 'phone') {
        final action = tester.getRect(
          find.byKey(const ValueKey('game-feed-like')),
        );
        final pitch = rects[1].top - rects[0].top;
        final railHeight = action.height * 4 + 30;
        final availableHeight =
            scenario.size.height - scenario.padding.vertical;
        final expectedTop =
            scenario.padding.top +
            math.min(
              availableHeight - railHeight,
              (availableHeight - railHeight) / 2 + pitch * 2,
            );
        expect(rects.first.top, closeTo(expectedTop, .5));
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

PageView _pager(WidgetTester tester) =>
    tester.widget<PageView>(find.byType(PageView));

Future<void> _jumpTo(WidgetTester tester, int index) async {
  _pager(tester).controller!.jumpToPage(index);
  await tester.pump();
  await tester.pump();
}

Future<void> _widgetHarness(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) respond, {
  bool settle = true,
}) async {
  await tester.runAsync(() async {
    final h = await _harness(respond);
    await h.controller.loadGameFeed();
  });
  await tester.pumpWidget(const MaterialApp(home: GameFeedPage()));
  await tester.pump();
  if (settle) await tester.pumpAndSettle();
}

Future<({WidgetsHubController controller, AuthSessionService auth})> _harness(
  Future<http.Response> Function(http.Request) respond,
) async {
  appServices.put<SecureStorageService>(_Storage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(AuthSessionService());
  auth.session.value = _session('account-a');
  final locale = appServices.put(LocaleConfigService());
  appServices.put<AppletCatalogService>(
    AppletCatalogService(
      environment: environment,
      auth: auth,
      locale: locale,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/mine')) return _page();
        final response = await respond(request);
        return http.Response(
          response.body.replaceAll(
            'https://example.test',
            environment.baseUri.origin,
          ),
          response.statusCode,
        );
      }),
    ),
  );
  appServices.put<DBService>(_DB());
  final controller = appServices.put(WidgetsHubController());
  await controller.reload();
  return (controller: controller, auth: auth);
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

http.Response _page({List<String> ids = const [], String? cursor}) =>
    http.Response(
      jsonEncode({
        'code': 'OK',
        'data': {
          'schemaVersion': 1,
          'quota': {'used': 0, 'limit': 5},
          if (cursor != null) 'nextCursor': cursor,
          'items': [
            for (final id in ids)
              {
                'id': id,
                'title': 'Game $id',
                'type': 'game',
                'summary': 'A playable game',
                'author': {
                  'agentId': 'aa_0123456789abcdef0123456789abcdef',
                  'displayName': 'Agent',
                  'verified': false,
                },
                'shareUrl': 'https://example.test/g/$id',
                'updatedAt': '2026-09-22T08:00:00Z',
                'likeCount': 12,
              },
          ],
        },
      }),
      200,
    );

class _DB extends DBService {
  @override
  Future<List<AgentWidget>> getAllWidgets() async => [];
}

class _Storage extends SecureStorageService {
  final _values = <String, String>{};
  @override
  Future<String?> read(String key) async => _values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    return true;
  }
}
