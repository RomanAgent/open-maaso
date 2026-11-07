import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  test('startup registers locale before the localized Applet client', () {
    final source = File('lib/main.dart').readAsStringSync();
    final locale = source.indexOf('LocaleConfigService().init()');
    final applets = source.indexOf('AppletCatalogService(');

    expect(locale, greaterThanOrEqualTo(0));
    expect(applets, greaterThan(locale));
  });

  test('search carries auth, locale, type, cursor, and exact quota', () async {
    late http.Request captured;
    final harness = await _harness(
      clientBuilder: (auth, environment) => MockClient((request) async {
        captured = request;
        return _ok(environment, used: 3, nextCursor: 'cursor-2');
      }),
      locale: AppLocale.zh,
    );

    final page = await harness.service.search(
      query: '  跑酷   游戏  ',
      type: AppletCatalogType.game,
      cursor: 'cursor-1',
    );

    expect(captured.url.path, '/v1/applets');
    expect(captured.url.queryParameters['query'], '跑酷 游戏');
    expect(captured.url.queryParameters['type'], 'game');
    expect(captured.url.queryParameters['cursor'], 'cursor-1');
    expect(captured.url.queryParameters['locale'], 'zh-CN');
    expect(captured.url.queryParameters['include_skill'], 'true');
    expect(captured.headers['authorization'], 'Bearer token-a');
    expect(page.items.single.title, 'Orbit Runner');
    expect(page.quota.used, 3);
    expect(page.quota.limit, 5);
    expect(page.nextCursor, 'cursor-2');
    expect(harness.service.latestType.value, AppletCatalogType.game);
  });

  test(
    'game browse loads an empty-query page without changing search cache',
    () async {
      late http.Request captured;
      final harness = await _harness(
        clientBuilder: (_, environment) => MockClient((request) async {
          captured = request;
          return _ok(environment, used: 2, nextCursor: 'game-cursor-2');
        }),
      );

      final page = await harness.service.browse(
        type: AppletCatalogType.game,
        cursor: 'game-cursor-1',
        limit: 8,
      );

      expect(captured.url.path, '/v1/applets');
      expect(captured.url.queryParameters['query'], '');
      expect(captured.url.queryParameters['type'], 'game');
      expect(captured.url.queryParameters['sort'], 'recommended');
      expect(captured.url.queryParameters['cursor'], 'game-cursor-1');
      expect(captured.url.queryParameters['limit'], '8');
      expect(captured.url.queryParameters['include_skill'], 'true');
      expect(page.nextCursor, 'game-cursor-2');
      expect(harness.service.latestPage.value, isNull);
      expect(harness.service.latestQuery.value, isEmpty);
    },
  );

  test(
    'popular browse and engagement writes use the narrow contract',
    () async {
      final requests = <http.Request>[];
      final harness = await _harness(
        clientBuilder: (_, environment) => MockClient((request) async {
          requests.add(request);
          final path = request.url.path;
          if (path == '/v1/applets') return _ok(environment, used: 1);
          if (path.endsWith('/comments') && request.method == 'GET') {
            return http.Response(
              jsonEncode(<String, Object?>{
                'code': 'OK',
                'data': <String, Object?>{
                  'items': <Object?>[
                    <String, Object?>{
                      'id': 'comment-1',
                      'displayName': 'Agent PAL',
                      'text': 'Great!',
                      'createdAt': '2026-08-13T12:00:00Z',
                    },
                  ],
                },
              }),
              200,
            );
          }
          if (path.endsWith('/comments')) {
            return http.Response(
              jsonEncode(<String, Object?>{
                'code': 'OK',
                'data': <String, Object?>{
                  'id': 'comment-2',
                  'displayName': 'Agent ME',
                  'text': 'Nice!',
                  'createdAt': '2026-08-13T12:01:00Z',
                },
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 'OK',
              'data': <String, Object?>{
                'id': 'applet-1',
                'viewCount': 11,
                'likeCount': 4,
                'shareCount': 3,
                'commentCount': 2,
                'likedByMe': true,
              },
            }),
            200,
          );
        }),
      );
      final contextKey = harness.service.requestContextKey;

      await harness.service.browse(
        type: AppletCatalogType.game,
        sort: AppletCatalogSort.hot,
      );
      await harness.service.setLiked(
        'applet-1',
        true,
        expectedContextKey: contextKey,
      );
      await harness.service.recordView(
        'applet-1',
        eventId: 'view-event-1',
        expectedContextKey: contextKey,
      );
      await harness.service.recordShare(
        'applet-1',
        eventId: 'share-event-1',
        expectedContextKey: contextKey,
      );
      final comments = await harness.service.listComments(
        'applet-1',
        expectedContextKey: contextKey,
      );
      final posted = await harness.service.postComment(
        'applet-1',
        ' Nice! ',
        expectedContextKey: contextKey,
      );

      expect(requests.first.url.queryParameters['sort'], 'hot');
      expect(requests[1].url.path, '/v1/applets/applet-1/likes/status');
      expect(jsonDecode(requests[1].body), <String, Object?>{'liked': true});
      expect(jsonDecode(requests[2].body), <String, Object?>{
        'eventId': 'view-event-1',
      });
      expect(jsonDecode(requests[3].body), <String, Object?>{
        'eventId': 'share-event-1',
      });
      expect(comments.items.single.text, 'Great!');
      expect(posted.text, 'Nice!');
      expect(
        () => harness.service.recordView(
          'applet-1',
          eventId: 'bad event id',
          expectedContextKey: contextKey,
        ),
        throwsFormatException,
      );
    },
  );

  test('game browse drops a response after account context changes', () async {
    final harness = await _harness(
      clientBuilder: (auth, environment) => MockClient((_) async {
        auth.session.value = _session('account-b', 'token-b');
        return _ok(environment, used: 1);
      }),
    );

    await expectLater(
      harness.service.browse(type: AppletCatalogType.game),
      throwsStateError,
    );
    expect(harness.service.latestPage.value, isNull);
  });

  test('account switch during request drops the stale response', () async {
    final harness = await _harness(
      clientBuilder: (auth, environment) => MockClient((_) async {
        auth.session.value = _session('account-b', 'token-b');
        return _ok(environment, used: 1);
      }),
    );

    await expectLater(
      harness.service.search(query: 'runner'),
      throwsStateError,
    );
    expect(harness.service.latestPage.value, isNull);
  });

  test('malformed public item fails closed without caching it', () async {
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((_) async {
        final item = _item(environment)..['prompt'] = 'private prompt';
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{
              'schemaVersion': 1,
              'items': <Object?>[item],
              'quota': <String, Object?>{'used': 1, 'limit': 5},
            },
          }),
          200,
        );
      }),
    );

    await expectLater(
      harness.service.search(query: 'runner'),
      throwsFormatException,
    );
    expect(harness.service.latestPage.value, isNull);
  });

  test('plain-text search errors remain typed request failures', () async {
    final harness = await _harness(
      clientBuilder: (_, _) =>
          MockClient((_) async => http.Response('404 page not found', 404)),
    );

    await expectLater(
      harness.service.search(query: 'runner'),
      throwsA(
        isA<AppletCatalogRequestException>()
            .having((error) => error.statusCode, 'statusCode', 404)
            .having((error) => error.code, 'code', isEmpty),
      ),
    );
  });

  test(
    'missing owner inventory stays typed and cannot block local creation',
    () async {
      var requests = 0;
      final harness = await _harness(
        clientBuilder: (_, _) => MockClient((_) async {
          requests += 1;
          return http.Response('404 page not found', 404);
        }),
      );

      await expectLater(
        harness.service.mine(),
        throwsA(isA<AppletInventoryUnavailableException>()),
      );
      await expectLater(
        harness.service.mine(),
        throwsA(isA<AppletInventoryUnavailableException>()),
      );
      expect(requests, 1);

      harness.auth.session.value = _session('account-b', 'token-b');
      await expectLater(
        harness.service.mine(),
        throwsA(isA<AppletInventoryUnavailableException>()),
      );

      expect(requests, 2);

      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'missing_inventory_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      appServices.put<AppletCatalogService>(harness.service);
      final controller = WidgetsHubController();

      await controller.reload();

      expect(controller.cloudOnlyItems, isEmpty);
      expect(controller.cloudInventoryErrorKey.value, isNull);
      await AppletLocalOwnership.ensureCanCreate(database);
      final scope = AppletLocalOwnership.currentScopeKey();
      final widget = AgentWidget(
        agentId: 'self',
        title: 'Local without inventory',
        kind: 'surface',
        spec: <String, Object?>{
          'surfaceId': 'offline-after-cloud-failure',
          'experienceType': 'utility',
        },
        createdAt: DateTime.utc(2026, 10, 8),
      );
      AppletLocalOwnership.stamp(widget, scopeKey: scope);
      await AppletLocalOwnership.saveNew(
        database,
        widget,
        expectedScopeKey: scope,
      );
      expect(await database.getAllWidgets(), hasLength(1));
      expect(requests, 2);
    },
  );

  test(
    'coalesces concurrent cold probes for missing owner inventory',
    () async {
      var requests = 0;
      final release = Completer<void>();
      final harness = await _harness(
        clientBuilder: (_, _) => MockClient((_) async {
          requests += 1;
          await release.future;
          return http.Response('404 page not found', 404);
        }),
      );

      final first = harness.service.mine();
      final second = harness.service.mine();
      final firstExpectation = expectLater(
        first,
        throwsA(isA<AppletInventoryUnavailableException>()),
      );
      final secondExpectation = expectLater(
        second,
        throwsA(isA<AppletInventoryUnavailableException>()),
      );
      await Future<void>.delayed(Duration.zero);

      expect(requests, 1);
      release.complete();
      await Future.wait(<Future<void>>[firstExpectation, secondExpectation]);
      expect(requests, 1);
    },
  );

  test(
    'structured owner inventory 404 stays typed and is not cached',
    () async {
      var requests = 0;
      final harness = await _harness(
        clientBuilder: (_, _) => MockClient((_) async {
          requests += 1;
          return http.Response(
            jsonEncode(<String, Object>{
              'code': 'NOT_FOUND',
              'message': 'inventory unavailable for this account',
            }),
            404,
          );
        }),
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          harness.service.mine(),
          throwsA(
            isA<AppletCatalogRequestException>()
                .having((error) => error.statusCode, 'statusCode', 404)
                .having((error) => error.code, 'code', 'NOT_FOUND')
                .having((error) => error.routeMissing, 'routeMissing', isFalse),
          ),
        );
      }

      expect(requests, 2);
    },
  );

  test(
    'returning to an owner context performs a fresh inventory probe',
    () async {
      var accountARequests = 0;
      var requests = 0;
      final harness = await _harness(
        clientBuilder: (_, environment) => MockClient((request) async {
          requests += 1;
          if (request.headers['authorization'] == 'Bearer token-b') {
            return _inventoryResponse(environment, deleted: true);
          }
          accountARequests += 1;
          return accountARequests == 1
              ? http.Response('404 page not found', 404)
              : http.Response('server unavailable', 503);
        }),
      );

      await expectLater(
        harness.service.mine(),
        throwsA(isA<AppletInventoryUnavailableException>()),
      );
      harness.auth.session.value = _session('account-b', 'token-b');
      await harness.service.mine();
      harness.auth.session.value = _session('account-a', 'token-a');
      await expectLater(
        harness.service.mine(),
        throwsA(
          isA<AppletCatalogRequestException>().having(
            (error) => error.statusCode,
            'statusCode',
            503,
          ),
        ),
      );

      expect(requests, 3);
      expect(accountARequests, 2);
    },
  );

  test('a delayed stale inventory probe cannot poison a new account', () async {
    var accountARequests = 0;
    var requests = 0;
    final firstAccountAStarted = Completer<void>();
    final releaseFirstAccountA = Completer<void>();
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((request) async {
        requests += 1;
        if (request.headers['authorization'] == 'Bearer token-b') {
          return _inventoryResponse(environment, deleted: true);
        }
        accountARequests += 1;
        if (accountARequests == 1) {
          firstAccountAStarted.complete();
          await releaseFirstAccountA.future;
          return http.Response('404 page not found', 404);
        }
        return _inventoryResponse(environment, deleted: true);
      }),
    );

    final stale = harness.service.mine();
    final staleExpectation = expectLater(stale, throwsStateError);
    await firstAccountAStarted.future;
    harness.auth.session.value = _session('account-b', 'token-b');
    await harness.service.mine();
    releaseFirstAccountA.complete();
    await staleExpectation;

    harness.auth.session.value = _session('account-a', 'token-a');
    await harness.service.mine();

    expect(requests, 3);
    expect(accountARequests, 2);
  });

  test('a later route 404 cannot poison successful owner inventory', () async {
    var requests = 0;
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((_) async {
        requests += 1;
        return requests == 2
            ? http.Response('404 page not found', 404)
            : _inventoryResponse(environment, deleted: true);
      }),
    );

    await harness.service.mine();
    await expectLater(
      harness.service.mine(),
      throwsA(
        isA<AppletCatalogRequestException>().having(
          (error) => error.routeMissing,
          'routeMissing',
          isTrue,
        ),
      ),
    );
    await harness.service.mine();

    expect(requests, 3);
  });

  test(
    'owner inventory server failures stay typed and are not cached',
    () async {
      var requests = 0;
      final harness = await _harness(
        clientBuilder: (_, _) => MockClient((_) async {
          requests += 1;
          return http.Response('server unavailable', 503);
        }),
      );

      for (var attempt = 0; attempt < 2; attempt++) {
        await expectLater(
          harness.service.mine(),
          throwsA(
            isA<AppletCatalogRequestException>().having(
              (error) => error.statusCode,
              'statusCode',
              503,
            ),
          ),
        );
      }

      expect(requests, 2);
    },
  );

  test('quota preflight uses the owner-only exact contract', () async {
    late http.Request captured;
    final harness = await _harness(
      clientBuilder: (_, _) => MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{'used': 4, 'limit': 5},
          }),
          200,
        );
      }),
      locale: AppLocale.zh,
    );

    final quota = await harness.service.quota();

    expect(captured.url.path, '/v1/applets/quota');
    expect(captured.url.queryParameters, isEmpty);
    expect(captured.headers['authorization'], 'Bearer token-a');
    expect(quota.used, 4);
    expect(quota.limit, 5);
  });

  test(
    'server storefront quota stays authoritative after local limits retire',
    () async {
      var requests = 0;
      final harness = await _harness(
        clientBuilder: (_, _) => MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1/applets/quota');
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 'OK',
              'data': <String, Object?>{'used': 5, 'limit': 5},
            }),
            200,
          );
        }),
      );
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'unlimited_local_storefront_quota.db',
      );
      final scope = AppletLocalOwnership.currentScopeKey();
      appServices.put<AppletCatalogService>(harness.service);
      for (var index = 0; index < 8; index++) {
        final widget = AgentWidget(
          agentId: 'self',
          title: 'Local $index',
          kind: 'surface',
          spec: <String, Object?>{
            'surfaceId': 'local-$index',
            'experienceType': 'utility',
          },
          createdAt: DateTime.utc(2026, 10, 8),
        );
        AppletLocalOwnership.stamp(widget, scopeKey: scope);
        await AppletLocalOwnership.saveNew(
          database,
          widget,
          expectedScopeKey: scope,
        );
      }
      expect(requests, 0);
      expect(await database.getAllWidgets(), hasLength(8));
      final quota = await harness.service.quota();
      expect(quota.used, 5);
      expect(quota.limit, 5);
      expect(quota.isFull, isTrue);
      expect(quota.remaining, 0);
      expect(requests, 1);
    },
  );

  test('owner inventory is authenticated, compact, and query-free', () async {
    late http.Request captured;
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((request) async {
        captured = request;
        return http.Response(
          jsonEncode(<String, Object?>{
            'code': 'OK',
            'data': <String, Object?>{
              'schemaVersion': 1,
              'items': <Object?>[
                <String, Object?>{
                  'id': 'ag_0123456789abcdef',
                  'clientSurfaceId': 'surface_7',
                  'title': 'Pocket Weather',
                  'type': 'applet',
                  'summary': 'Forecasts with jokes.',
                  'published': true,
                  'shareUrl': '${environment.baseUri.origin}/g/weather',
                  'updatedAt': '2026-08-08T08:00:00Z',
                },
              ],
              'quota': <String, Object?>{'used': 1, 'limit': 5},
            },
          }),
          200,
        );
      }),
    );

    final inventory = await harness.service.mine();

    expect(captured.url.path, '/v1/applets/mine');
    expect(captured.url.queryParameters, {'include_skill': 'true'});
    expect(captured.headers['authorization'], 'Bearer token-a');
    expect(inventory.items.single.title, 'Pocket Weather');
    expect(inventory.items.single.clientSurfaceId, 'surface_7');
    expect(inventory.quota.used, 1);
  });

  test('Hub pagination preserves the type adopted from Agent search', () async {
    final requests = <http.Request>[];
    var requestCount = 0;
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((request) async {
        requests.add(request);
        requestCount += 1;
        return _ok(
          environment,
          used: 2,
          nextCursor: requestCount == 1 ? 'cursor-2' : null,
        );
      }),
    );
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'applet_hub_type_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    appServices.put<AppletCatalogService>(harness.service);

    await harness.service.search(
      query: 'tower defense',
      type: AppletCatalogType.game,
    );
    final controller = appServices.put(WidgetsHubController());
    await controller.loadMoreSearchResults();

    final searchRequests = requests
        .where((request) => request.url.path == '/v1/applets')
        .toList(growable: false);
    expect(searchRequests, hasLength(2));
    expect(searchRequests[1].url.queryParameters['type'], 'game');
    expect(searchRequests[1].url.queryParameters['cursor'], 'cursor-2');
  });

  test(
    'Hub restarts a pending game browse after account scope changes',
    () async {
      final firstBrowseStarted = Completer<void>();
      final releaseFirstBrowse = Completer<void>();
      final browseRequests = <http.Request>[];
      final harness = await _harness(
        clientBuilder: (_, environment) => MockClient((request) async {
          if (request.url.path == '/v1/applets/mine') {
            return _inventoryResponse(environment, deleted: true);
          }
          browseRequests.add(request);
          if (browseRequests.length == 1) {
            firstBrowseStarted.complete();
            await releaseFirstBrowse.future;
          }
          return _ok(environment, used: 1);
        }),
      );
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'game_scope_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      appServices.put<AppletCatalogService>(harness.service);
      final controller = appServices.put(WidgetsHubController());

      controller.selectSection(AppletHubSection.games);
      await firstBrowseStarted.future;
      expect(controller.isLoadingGameFeed.value, isTrue);

      harness.auth.session.value = _session('account-b', 'token-b');
      for (var attempt = 0; attempt < 20; attempt++) {
        if (browseRequests.length >= 2 && !controller.isLoadingGameFeed.value) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(browseRequests, hasLength(2));
      expect(browseRequests.last.headers['authorization'], 'Bearer token-b');
      expect(controller.isLoadingGameFeed.value, isFalse);
      expect(controller.gameFeedItems, isNotEmpty);

      releaseFirstBrowse.complete();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(controller.isLoadingGameFeed.value, isFalse);
      expect(controller.gameFeedItems, hasLength(1));
    },
  );

  test(
    'engagement queues and like busy markers are isolated by account scope',
    () async {
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final firstResponse = Completer<http.Response>();
      final secondResponse = Completer<http.Response>();
      final harness = await _harness(
        clientBuilder: (_, environment) => MockClient((request) async {
          if (request.url.path == '/v1/applets/mine') {
            return _inventoryResponse(environment, deleted: true);
          }
          if (request.url.path.endsWith('/likes/status')) {
            if (request.headers['authorization'] == 'Bearer token-a') {
              firstStarted.complete();
              return firstResponse.future;
            }
            secondStarted.complete();
            return secondResponse.future;
          }
          return _ok(environment, used: 1);
        }),
      );
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'engagement_scope_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      appServices.put<AppletCatalogService>(harness.service);
      final controller = appServices.put(WidgetsHubController());
      final item = _catalogTestItem('applet-1');
      controller.gameFeedItems.assign(item);

      final first = controller.toggleGameLike(item);
      await firstStarted.future;
      expect(controller.isGameLikeInFlight(item.id), isTrue);

      harness.auth.session.value = _session('account-b', 'token-b');
      await Future<void>.delayed(Duration.zero);
      controller.gameFeedItems.assign(item);
      final second = controller.toggleGameLike(item);
      await secondStarted.future.timeout(const Duration(seconds: 1));
      expect(controller.isGameLikeInFlight(item.id), isTrue);

      firstResponse.complete(_engagementResponse(likeCount: 9));
      await first;
      expect(controller.isGameLikeInFlight(item.id), isTrue);
      expect(controller.gameFeedItems.single.likeCount, isNot(9));

      secondResponse.complete(_engagementResponse(likeCount: 2));
      await second;
      expect(controller.isGameLikeInFlight(item.id), isFalse);
      expect(controller.gameFeedItems.single.likeCount, 2);
    },
  );

  test('comment pagination ignores a stale load-more page', () async {
    final stalePage = Completer<http.Response>();
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((request) async {
        if (request.url.path == '/v1/applets/mine') {
          return _inventoryResponse(environment, deleted: true);
        }
        if (request.url.path.endsWith('/comments')) {
          final id = request.url.pathSegments[2];
          final cursor = request.url.queryParameters['cursor'];
          if (id == 'applet-1' && cursor == 'cursor-2') {
            return stalePage.future;
          }
          return _commentsResponse(
            id == 'applet-1' ? 'comment-a1' : 'comment-b1',
            nextCursor: id == 'applet-1' ? 'cursor-2' : null,
          );
        }
        return _ok(environment, used: 1);
      }),
    );
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'comments_cursor_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    appServices.put<AppletCatalogService>(harness.service);
    final controller = appServices.put(WidgetsHubController());
    final firstItem = _catalogTestItem('applet-1');
    final secondItem = _catalogTestItem('applet-2');

    expect(await controller.loadGameComments(firstItem), isTrue);
    expect(controller.gameFeedCommentsNextCursor.value, 'cursor-2');
    final loadMore = controller.loadGameComments(firstItem, loadMore: true);
    await Future<void>.delayed(Duration.zero);
    expect(await controller.loadGameComments(secondItem), isTrue);
    expect(controller.gameFeedCommentsItemId.value, secondItem.id);

    stalePage.complete(_commentsResponse('comment-a2'));
    expect(await loadMore, isFalse);
    expect(controller.gameFeedComments.map((item) => item.id), <String>[
      'comment-b1',
    ]);
    expect(controller.gameFeedCommentsNextCursor.value, isNull);
    expect(controller.isLoadingMoreGameFeedComments.value, isFalse);
  });

  test(
    'cloud-only inventory deletion is bound to its captured account scope',
    () async {
      var deleted = false;
      final harness = await _harness(
        clientBuilder: (_, environment) => MockClient((request) async {
          if (request.url.path == '/v1/applets/mine') {
            return _inventoryResponse(environment, deleted: deleted);
          }
          return _ok(environment, used: deleted ? 0 : 1);
        }),
      );
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path:
            'applet_cloud_inventory_${DateTime.now().microsecondsSinceEpoch}.db',
      );
      appServices.put<DBService>(database);
      appServices.put<AppletCatalogService>(harness.service);
      var deleteRequests = 0;
      appServices.put(
        AgentGameCloudService(
          database: database,
          httpClient: MockClient((request) async {
            deleteRequests += 1;
            deleted = true;
            return http.Response(
              jsonEncode(<String, Object?>{
                'code': 'OK',
                'data': <String, Object?>{
                  'clientSurfaceId': 'surface_cloud',
                  'deleted': true,
                },
              }),
              200,
            );
          }),
          baseUri: () => harness.environment.baseUri,
          accessToken: () async => harness.auth.session.value!.accessToken,
          accountScope: AppletLocalOwnership.currentScopeKey,
        ),
      );
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      final captured = controller.cloudOnlyItems.single;

      harness.auth.session.value = _session('account-b', 'token-b');
      await expectLater(controller.deleteCloudOnly(captured), throwsStateError);
      expect(deleteRequests, 0);

      harness.auth.session.value = _session('account-a', 'token-a');
      await controller.deleteCloudOnly(captured);
      expect(deleteRequests, 1);
      expect(controller.cloudOnlyItems, isEmpty);
    },
  );

  test('local dismiss and markSeen reject a stale account callback', () async {
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient((request) async {
        if (request.url.path == '/v1/applets/mine') {
          return _inventoryResponse(environment, deleted: true);
        }
        return _ok(environment, used: 0);
      }),
    );
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'applet_local_scope_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    appServices.put<AppletCatalogService>(harness.service);
    final item = AgentWidget(
      agentId: 'self',
      title: 'Private Applet',
      kind: 'surface',
      spec: <String, Object?>{
        'surfaceId': 'surface_private',
        'experienceType': 'utility',
      },
      createdAt: DateTime.utc(2026, 8, 8),
    );
    AppletLocalOwnership.stamp(
      item,
      scopeKey: AppletLocalOwnership.currentScopeKey(),
    );
    await database.saveAgentWidget(item);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    final captured = controller.widgets.single;

    harness.auth.session.value = _session('account-b', 'token-b');
    await expectLater(controller.dismiss(captured), throwsStateError);
    await controller.markSeen(captured);

    final saved = (await database.getAllWidgets()).single;
    expect(saved.seen, isFalse);
    expect(saved.title, 'Private Applet');
  });

  test('returning to an environment resumes its durable delete', () async {
    final harness = await _harness(
      clientBuilder: (_, environment) => MockClient(
        (_) async => _inventoryResponse(environment, deleted: true),
      ),
    );
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path:
          'applet_environment_retry_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(database);
    final testScope = AppletLocalOwnership.currentScopeKey();
    final item = AgentWidget(
      agentId: 'self',
      title: 'Pending delete',
      kind: 'surface',
      spec: <String, Object?>{
        'surfaceId': 'surface_pending',
        'experienceType': 'utility',
        'appletLocal': <String, Object?>{
          'schemaVersion': 1,
          'scopeKey': testScope,
        },
        'cloudDelete': <String, Object?>{
          'schemaVersion': 1,
          'scopeKey': testScope,
          'clientSurfaceId': 'surface_pending',
        },
      },
      createdAt: DateTime.utc(2026, 8, 8),
    );
    await database.saveAgentWidget(item);
    final deleteSeen = Completer<void>();
    var deleteRequests = 0;
    appServices.put(
      AgentGameCloudService(
        database: database,
        httpClient: MockClient((request) async {
          deleteRequests += 1;
          if (!deleteSeen.isCompleted) deleteSeen.complete();
          return http.Response(
            jsonEncode(<String, Object?>{
              'code': 'OK',
              'data': <String, Object?>{
                'clientSurfaceId': 'surface_pending',
                'deleted': true,
              },
            }),
            200,
          );
        }),
      ),
    );

    await harness.environment.setEnvironment(MaasoEnvironment.production);
    await Future<void>.delayed(Duration.zero);
    expect(deleteRequests, 0);

    await harness.environment.setEnvironment(MaasoEnvironment.test);
    await deleteSeen.future.timeout(const Duration(seconds: 1));
    for (var attempt = 0; attempt < 20; attempt++) {
      if ((await database.getAllWidgets()).isEmpty) break;
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(deleteRequests, 1);
    expect(await database.getAllWidgets(), isEmpty);
  });
}

class _Harness {
  const _Harness({
    required this.service,
    required this.auth,
    required this.environment,
  });

  final AppletCatalogService service;
  final AuthSessionService auth;
  final AppEnvironmentService environment;
}

Future<_Harness> _harness({
  required http.Client Function(
    AuthSessionService auth,
    AppEnvironmentService environment,
  )
  clientBuilder,
  AppLocale locale = AppLocale.en,
}) async {
  appServices.put<SecureStorageService>(_MemorySecureStorage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient((_) async {
        throw UnimplementedError('Applet tests must not refresh auth');
      }),
    ),
  );
  await auth.init();
  auth.session.value = _session('account-a', 'token-a');
  final localeService = appServices.put(LocaleConfigService());
  await localeService.setLocale(locale);
  return _Harness(
    service: AppletCatalogService(
      httpClient: clientBuilder(auth, environment),
      environment: environment,
      auth: auth,
      locale: localeService,
    ),
    auth: auth,
    environment: environment,
  );
}

MaasoAuthSession _session(String account, String token) => MaasoAuthSession(
  accountUuid: account,
  accessToken: token,
  refreshToken: 'refresh-$account',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

http.Response _ok(
  AppEnvironmentService environment, {
  required int used,
  String? nextCursor,
}) => http.Response(
  jsonEncode(<String, Object?>{
    'code': 'OK',
    'data': <String, Object?>{
      'schemaVersion': 1,
      'items': <Object?>[_item(environment)],
      'quota': <String, Object?>{'used': used, 'limit': 5},
      'nextCursor': ?nextCursor,
    },
  }),
  200,
);

Map<String, Object?> _item(AppEnvironmentService environment) =>
    <String, Object?>{
      'id': 'applet-1',
      'title': 'Orbit Runner',
      'type': 'game',
      'summary': 'A tiny orbital runner.',
      'author': <String, Object?>{
        'agentId': 'aa_0123456789abcdef0123456789abcdef',
        'displayName': 'Agent 0123456789ABCDEF',
        'verified': false,
      },
      'shareUrl': '${environment.baseUri.origin}/g/orbit-runner',
      'updatedAt': '2026-08-08T08:00:00Z',
    };

http.Response _inventoryResponse(
  AppEnvironmentService environment, {
  required bool deleted,
}) => http.Response(
  jsonEncode(<String, Object?>{
    'code': 'OK',
    'data': <String, Object?>{
      'schemaVersion': 1,
      'items': <Object?>[
        if (!deleted)
          <String, Object?>{
            'id': 'ag_cloud_inventory',
            'clientSurfaceId': 'surface_cloud',
            'title': 'Cloud-only Applet',
            'type': 'applet',
            'summary': 'Created on another device.',
            'published': true,
            'shareUrl': '${environment.baseUri.origin}/g/cloud-inventory',
            'updatedAt': '2026-08-08T08:00:00Z',
          },
      ],
      'quota': <String, Object?>{'used': deleted ? 0 : 1, 'limit': 5},
    },
  }),
  200,
);

AppletCatalogItem _catalogTestItem(String id) => AppletCatalogItem(
  id: id,
  title: 'Game $id',
  type: AppletCatalogType.game,
  summary: 'Summary',
  author: const AppletCatalogAuthor(
    agentId: 'aa_0123456789abcdef0123456789abcdef',
    displayName: 'Agent PAL',
    verified: false,
  ),
  shareUrl: Uri.parse('https://api-test.futurpals.com.cn/g/$id'),
  updatedAt: DateTime.utc(2026, 8, 13),
);

http.Response _engagementResponse({required int likeCount}) => http.Response(
  jsonEncode(<String, Object?>{
    'code': 'OK',
    'data': <String, Object?>{
      'id': 'applet-1',
      'viewCount': 1,
      'likeCount': likeCount,
      'shareCount': 0,
      'commentCount': 0,
      'likedByMe': true,
    },
  }),
  200,
);

http.Response _commentsResponse(String id, {String? nextCursor}) =>
    http.Response(
      jsonEncode(<String, Object?>{
        'code': 'OK',
        'data': <String, Object?>{
          'items': <Object?>[
            <String, Object?>{
              'id': id,
              'displayName': 'Agent PAL',
              'text': 'Comment $id',
              'createdAt': '2026-08-13T12:00:00Z',
            },
          ],
          'nextCursor': ?nextCursor,
        },
      }),
      200,
    );

class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
