import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_screenshot_preview.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:sembast/sembast_memory.dart';

class _Storage extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<bool> write(String key, String? value) async => true;
  @override
  Future<bool> delete(String key) async => true;
}

MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token-$account',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

http.Response _response(int status, String code, Object? data) => http.Response(
  jsonEncode({'code': code, 'data': data}),
  status,
  headers: {'content-type': 'application/json; charset=utf-8'},
);

void main() {
  late WidgetsHubController controller;
  late AuthSessionService auth;
  late List<Map<String, dynamic>> sent;
  late Future<http.Response> Function(Map<String, dynamic>) sendResponse;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_Storage());
    appServices.put(AppEnvironmentService());
    appServices.put(LocaleConfigService());
    auth = appServices.put(AuthSessionService())
      ..session.value = _session('first');
    appServices.put<DBService>(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'game_comments.db',
      ),
    );
    sent = [];
    sendResponse = (body) async => _response(200, 'OK', {
      'id': 'agc_saved',
      'displayName': 'Roman',
      'actorId': 'player_roman',
      'actorKind': 'user',
      'text': body['text'],
      'createdAt': '2026-09-16T12:00:00Z',
    });
    final catalog = appServices.put(
      AppletCatalogService(
        httpClient: MockClient((request) async {
          if (request.url.path == '/v1/applets/ag_game/comments') {
            if (request.method == 'GET') {
              return _response(200, 'OK', {'items': []});
            }
            expectSync(request.headers['Authorization'], 'Bearer token-first');
            final body = jsonDecode(request.body) as Map<String, dynamic>;
            sent.add(body);
            return sendResponse(body);
          }
          if (request.url.path == '/v1/applets/mine') {
            return _response(200, 'OK', {
              'schemaVersion': 1,
              'items': [],
              'quota': {'used': 0, 'limit': 10},
            });
          }
          return _response(200, 'OK', {
            'schemaVersion': 1,
            'items': [],
            'quota': {'used': 0, 'limit': 10},
          });
        }),
      ),
    );
    addTearDown(catalog.onClose);
    controller = appServices.put(WidgetsHubController());
    await controller.reload();
    controller.recommendedGameFeedItems.assign(
      AppletCatalogItem(
        id: 'ag_game',
        title: 'Game',
        type: AppletCatalogType.game,
        summary: 'A game',
        author: const AppletCatalogAuthor(
          agentId: 'agent_demo',
          displayName: 'Demo',
          verified: false,
        ),
        shareUrl: Uri.parse('https://api-test.futurpals.com.cn/g/demo'),
        updatedAt: DateTime.utc(2026, 9, 16),
      ),
    );
    GameScreenshotStore.debugClientFactory = () =>
        MockClient((_) async => http.Response('', 404));
  });

  tearDown(() async {
    GameScreenshotStore.debugClientFactory = null;
    GameScreenshotPreview.clearCache();
    await appServices.reset();
  });

  Future<void> openComments(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(navigatorKey: rootNavigatorKey, home: const GameFeedPage()),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-feed-comments')));
    await tester.pumpAndSettle();
  }

  final field = find.descendant(
    of: find.byKey(const ValueKey('game-feed-comment-field')),
    matching: find.byType(TextField),
  );
  final send = find.byKey(const ValueKey('game-feed-comment-send'));
  final error = find.byKey(const ValueKey('game-feed-comment-error'));

  testWidgets('sending Chinese comment persists it and clears the draft', (
    tester,
  ) async {
    await openComments(tester);
    await tester.enterText(field, '可以');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(sent, hasLength(1));
    expect(sent.single['text'], '可以');
    expect(sent.single['requestId'], matches(RegExp(r'^[a-f0-9]{32}$')));
    expect(sent.single.containsKey('parentCommentId'), isFalse);
    expect(controller.gameFeedComments.single.text, '可以');
    expect(controller.recommendedGameFeedItems.single.commentCount, 1);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty);
    expect(error, findsNothing);
    expect(find.text('可以'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review failure stays readable and retry reuses its request id', (
    tester,
  ) async {
    final success = sendResponse;
    sendResponse = (_) async => _response(409, 'COMMENT_REVIEW_PENDING', null);
    await openComments(tester);
    await tester.enterText(field, '可以');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(error, findsOneWidget);
    expect(tester.widget<Text>(error).data, contains('awaiting review'));
    expect(tester.widget<TextField>(field).controller!.text, '可以');
    expect(controller.gameFeedComments, isEmpty);
    expect(controller.recommendedGameFeedItems.single.commentCount, 0);
    sendResponse = success;
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(sent, hasLength(2));
    expect(sent.first['requestId'], sent.last['requestId']);
    expect(error, findsNothing);
    expect(controller.gameFeedComments, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unavailable comments explain the failure without losing input', (
    tester,
  ) async {
    sendResponse = (_) async => _response(500, 'INTERNAL_ERROR', null);
    await openComments(tester);
    await tester.enterText(field, '可以');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(error).data,
      contains('temporarily unavailable'),
    );
    expect(tester.widget<TextField>(field).controller!.text, '可以');
    expect(controller.gameFeedComments, isEmpty);
    expect(controller.recommendedGameFeedItems.single.commentCount, 0);
    expect(sent, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a send that returns false does not silently look successful', (
    tester,
  ) async {
    await openComments(tester);
    await appServices.delete<AppletCatalogService>();
    await tester.enterText(field, '可以');
    await tester.tap(send);
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(error).data, contains('was not sent'));
    expect(tester.widget<TextField>(field).controller!.text, '可以');
    expect(sent, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'pending sends cannot duplicate or surface another account error',
    (tester) async {
      final response = Completer<http.Response>();
      sendResponse = (_) => response.future;
      await openComments(tester);
      await tester.enterText(field, '可以');
      final onPressed = tester.widget<IconButton>(send).onPressed!;
      onPressed();
      onPressed();
      await tester.pump();
      expect(sent, hasLength(1));
      auth.session.value = _session('second');
      response.complete(_response(401, 'UNAUTHORIZED', null));
      await tester.pumpAndSettle();
      expect(error, findsNothing);
      expect(controller.gameFeedComments, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
