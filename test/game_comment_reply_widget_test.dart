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

Map<String, Object> _comment(String id, String text, {String? parent}) => {
  'id': id,
  'text': text,
  'displayName': 'Player',
  'actorId': 'pa_player',
  'actorKind': 'user',
  'createdAt': '2026-09-12T12:00:00Z',
  'parentCommentId': ?parent,
};

void main() {
  testWidgets('manual game reply retains failed draft and reuses request ID', (
    tester,
  ) async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_Storage());
    appServices.put(AppEnvironmentService());
    appServices.put(LocaleConfigService());
    appServices.put(AuthSessionService()).session.value = MaasoAuthSession(
      accountUuid: 'player',
      accessToken: 'test-token',
      refreshToken: 'refresh',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'comment-ui.db',
    );
    appServices.put<DBService>(db);
    final controller = appServices.put(WidgetsHubController());
    await controller.reload();
    final requests = <Map<String, dynamic>>[];
    final catalog = appServices.put(
      AppletCatalogService(
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/comments') &&
              request.method == 'GET') {
            return http.Response(
              jsonEncode({
                'code': 'OK',
                'data': {
                  'items': [_comment('agc_root', 'Root comment')],
                },
              }),
              200,
            );
          }
          if (request.url.path.endsWith('/comments') &&
              request.method == 'POST') {
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (requests.length == 1) {
              return http.Response(
                jsonEncode({'code': 'TEMPORARY_FAILURE'}),
                503,
              );
            }
            return http.Response(
              jsonEncode({
                'code': 'OK',
                'data': _comment('agc_reply', 'My reply', parent: 'agc_root'),
              }),
              200,
            );
          }
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {'items': []},
            }),
            200,
          );
        }),
      ),
    );
    controller.gameFeedItems.assign(
      AppletCatalogItem(
        id: 'game',
        title: 'Game',
        type: AppletCatalogType.game,
        summary: 'Play',
        author: const AppletCatalogAuthor(
          agentId: 'aa_0123456789abcdef0123456789abcdef',
          displayName: 'Agent',
          verified: false,
        ),
        shareUrl: Uri.parse('https://api.example.test/g/game'),
        updatedAt: DateTime.utc(2026, 9, 12),
      ),
    );
    gameFeedImpressionOverride = (_) {};
    addTearDown(() async {
      gameFeedImpressionOverride = null;
      catalog.onClose();
      await appServices.reset();
    });
    await tester.pumpWidget(const MaterialApp(home: GameFeedPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('game-feed-comments')));
    await tester.pumpAndSettle();
    expect(find.text('Root comment'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('game-feed-reply-agc_root')));
    await tester.pump();
    final input = find.descendant(
      of: find.byKey(const ValueKey('game-feed-comments-sheet')),
      matching: find.byType(TextField),
    );
    await tester.enterText(input, 'My reply');
    await tester.tap(find.byKey(const ValueKey('game-feed-comment-send')));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(input).controller!.text, 'My reply');
    expect(requests.length, 1);
    expect(requests.single['parentCommentId'], 'agc_root');
    await tester.tap(find.byKey(const ValueKey('game-feed-comment-send')));
    await tester.pumpAndSettle();
    expect(requests.length, 2);
    expect(requests[1], requests[0]);
    expect(tester.widget<TextField>(input).controller!.text, isEmpty);
    expect(
      controller.gameFeedComments
          .where((comment) => comment.id == 'agc_reply')
          .length,
      1,
    );
    expect(
      controller.gameFeedComments
          .singleWhere((comment) => comment.id == 'agc_reply')
          .parentCommentId,
      'agc_root',
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
