import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
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
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_player_like_button.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'applet discovery uses global rating order and keeps owner records separate',
    () async {
      final requests = <Uri>[];
      final harness = await _harness((request) async {
        requests.add(request.url);
        return _ok(_page());
      });
      await harness.controller.loadApplets();
      final browse = requests.singleWhere((uri) => uri.path == '/v1/applets');
      expect(browse.queryParameters['type'], 'applet');
      expect(browse.queryParameters['query'], '');
      expect(browse.queryParameters['sort'], 'rating');
      expect(harness.controller.appletDiscoveryItems.single.id, 'trip');
      expect(harness.controller.widgets, isEmpty);
    },
  );

  test(
    'repeated taps share one request and update ratings only from server results',
    () async {
      final response = Completer<http.Response>();
      final requestStarted = Completer<void>();
      final requests = <http.Request>[];
      final harness = await _harness((request) async {
        if (request.url.path.endsWith('/likes/status')) {
          requests.add(request);
          requestStarted.complete();
          return response.future;
        }
        return _ok(_page());
      });
      await harness.controller.loadApplets();
      final first = harness.controller.toggleAppletLike('trip');
      await requestStarted.future;
      await harness.controller.toggleAppletLike('trip');
      expect(requests, hasLength(1));
      expect(harness.controller.appletDiscoveryItems.single.likeCount, 4);
      expect(harness.controller.isAppletLikeInFlight('trip'), isTrue);
      response.complete(_ok(_engagement()));
      await first;
      expect(harness.controller.appletDiscoveryItems.single.likeCount, 5);
      expect(harness.controller.appletEngagement['trip']!.likedByMe, isTrue);
      expect(harness.controller.isAppletLikeInFlight('trip'), isFalse);
    },
  );

  test(
    'scope changes discard in-flight likes from the previous account',
    () async {
      final response = Completer<http.Response>();
      final requestStarted = Completer<void>();
      final harness = await _harness((request) async {
        if (request.url.path.endsWith('/likes/status')) {
          requestStarted.complete();
          return response.future;
        }
        return _ok(_page());
      });
      final liking = harness.controller.toggleAppletLike('trip');
      await requestStarted.future;
      harness.auth.session.value = _session('account-b');
      response.complete(_ok(_engagement()));
      await liking;
      expect(harness.controller.appletEngagement, isEmpty);
      expect(harness.controller.appletLikeInFlightIds, isEmpty);
    },
  );

  testWidgets(
    'official player likes use durable official engagement and refresh the hub score',
    (tester) async {
      var liked = false;
      final mutations = <http.Request>[];
      final harness = (await tester.runAsync(
        () => _harness((request) async {
          if (request.url.path.contains('/official-applets/')) {
            if (request.method == 'POST') {
              mutations.add(request);
              liked = (jsonDecode(request.body) as Map)['liked'] == true;
            }
            return _ok({
              ..._engagement(),
              'id': 'ble_yoturetoys_projector',
              'likeCount': liked ? 5 : 4,
              'likedByMe': liked,
            });
          }
          return _ok(_page());
        }),
      ))!;
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: AppletPlayerLikeButton(
              appletId: 'ble_yoturetoys_projector',
              official: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('applet-player-like')));
      await tester.pumpAndSettle();
      expect(mutations, hasLength(1));
      expect(
        mutations.single.url.path,
        '/v1/official-applets/ble_yoturetoys_projector/likes/status',
      );
      expect(find.byIcon(Icons.thumb_up_rounded), findsOneWidget);
      expect(
        harness
            .controller
            .appletEngagement['ble_yoturetoys_projector']!
            .likeCount,
        5,
      );
      await tester.tap(find.byKey(const ValueKey('applet-player-like')));
      await tester.pumpAndSettle();
      expect(mutations, hasLength(2));
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
      expect(
        harness
            .controller
            .appletEngagement['ble_yoturetoys_projector']!
            .likeCount,
        4,
      );
    },
  );

  testWidgets(
    'reopened published applet loads an existing like before toggling',
    (tester) async {
      final mutations = <bool>[];
      var liked = true;
      await tester.runAsync(
        () => _harness((request) async {
          if (request.url.path == '/v1/applets/trip/engagement' ||
              request.url.path == '/v1/applets/trip/likes/status') {
            if (request.method == 'POST') {
              liked = (jsonDecode(request.body) as Map)['liked'] == true;
              mutations.add(liked);
            }
            return _ok({..._engagement(), 'likedByMe': liked});
          }
          return _ok(_page());
        }),
      );
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: AppletPlayerLikeButton(appletId: 'trip')),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.thumb_up_rounded), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('applet-player-like')));
      await tester.pumpAndSettle();
      expect(mutations, [false]);
      expect(find.byIcon(Icons.thumb_up_outlined), findsOneWidget);
    },
  );

  testWidgets('unpublished player shows a disabled like button', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AppletPlayerLikeButton())),
    );
    final button = tester.widget<AppGlassIconButton>(
      find.byKey(const ValueKey('applet-player-like')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets(
    'public discovery has one full-width row per applet and orders higher scores first',
    (tester) async {
      appServices.put<DBService>(_DB());
      final controller = appServices.put(WidgetsHubController());
      await controller.reload();
      controller.appletDiscoveryItems.assignAll([
        _item('low', 'Low score', 1),
        _item('high', 'High score', 8),
      ]);
      controller.widgets.assign(
        AgentWidget(
          id: 1,
          agentId: 'self',
          title: 'Private draft',
          kind: 'surface',
          spec: {'surfaceId': 'private'},
          createdAt: DateTime.utc(2026),
        ),
      );
      await tester.pumpWidget(const MaterialApp(home: WidgetsHubPage()));
      await tester.pumpAndSettle();
      final high = tester.getRect(
        find.byKey(const ValueKey('public-applet-high')),
      );
      final low = tester.getRect(
        find.byKey(const ValueKey('public-applet-low')),
      );
      expect(high.left, low.left);
      expect(high.width, low.width);
      expect(high.bottom, lessThan(low.top));
      expect(find.text('Private draft'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.text('widgets.cloud_inventory'.tr), findsNothing);
      expect(find.text('widgets.official'.tr), findsNothing);
      expect(find.text('widgets.official_badge'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<({WidgetsHubController controller, AuthSessionService auth})> _harness(
  Future<http.Response> Function(http.Request) respond,
) async {
  appServices.put<SecureStorageService>(_Storage());
  final environment = appServices.put(AppEnvironmentService());
  await environment.init();
  final auth = appServices.put(
    AuthSessionService(
      httpClient: MockClient((_) async => throw StateError('no auth refresh')),
    ),
  );
  await auth.init();
  auth.session.value = _session('account-a');
  final locale = appServices.put(LocaleConfigService());
  appServices.put<AppletCatalogService>(
    AppletCatalogService(
      environment: environment,
      auth: auth,
      locale: locale,
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/mine')) {
          return _ok({
            'schemaVersion': 1,
            'items': [],
            'quota': {'used': 0, 'limit': 5},
          });
        }
        final response = await respond(request);
        // Keep catalog URLs on the same configured environment as production validation.
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
http.Response _ok(Map<String, Object?> data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);
Map<String, Object?> _page() => {
  'schemaVersion': 1,
  'quota': {'used': 0, 'limit': 5},
  'items': [
    {
      'id': 'trip',
      'title': 'Trip',
      'type': 'applet',
      'summary': 'Travel planner',
      'author': {
        'agentId': 'aa_0123456789abcdef0123456789abcdef',
        'displayName': 'Agent A',
        'verified': false,
      },
      'shareUrl': 'https://example.test/g/trip',
      'updatedAt': '2026-09-16T08:00:00Z',
      'likeCount': 4,
    },
  ],
};
Map<String, Object?> _engagement() => {
  'id': 'trip',
  'viewCount': 7,
  'likeCount': 5,
  'shareCount': 0,
  'commentCount': 0,
  'likedByMe': true,
};
AppletCatalogItem _item(String id, String title, int likes) =>
    AppletCatalogItem(
      id: id,
      title: title,
      type: AppletCatalogType.applet,
      summary: 'Plan a trip',
      likeCount: likes,
      author: const AppletCatalogAuthor(
        agentId: 'aa_0123456789abcdef0123456789abcdef',
        displayName: 'Agent A',
        verified: false,
      ),
      shareUrl: Uri.parse('https://example.test/g/$id'),
      updatedAt: DateTime.utc(2026),
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

  @override
  Future<bool> delete(String key) async {
    _values.remove(key);
    return true;
  }
}
