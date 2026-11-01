import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

class _MemoryStorage extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
  @override
  Future<bool> write(String key, String? value) async => true;
  @override
  Future<bool> delete(String key) async => true;
}

Map<String, Object> _comment({String parent = 'agc_root'}) => {
  'id': 'agc_reply',
  'displayName': 'Player',
  'actorId': 'pa_player',
  'actorKind': 'user',
  'text': 'Reply',
  'parentCommentId': parent,
  'createdAt': '2026-09-12T12:00:00Z',
};
MaasoAuthSession _session(String account) => MaasoAuthSession(
  accountUuid: account,
  accessToken: 'token-$account',
  refreshToken: 'refresh',
  expiresAt: DateTime.now().add(const Duration(days: 1)),
);

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_MemoryStorage());
    appServices.put(AppEnvironmentService());
    appServices.put(LocaleConfigService());
    appServices.put(AuthSessionService()).session.value = _session('first');
  });
  tearDown(() async {
    await appServices.reset();
  });

  test(
    'reply transport carries stable request and parent without actor fields',
    () async {
      Map<String, dynamic>? body;
      final service = AppletCatalogService(
        httpClient: MockClient((request) async {
          expect(request.url.path, '/v1/applets/game/comments');
          expect(request.headers['Authorization'], 'Bearer token-first');
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return http.Response(
            jsonEncode({'code': 'OK', 'data': _comment()}),
            200,
          );
        }),
      );
      final reply = await service.postCommentWithInput(
        'game',
        ' Reply ',
        requestId: 'stable-request',
        parentCommentId: 'agc_root',
        expectedContextKey: service.requestContextKey,
      );
      expect(reply.parentCommentId, 'agc_root');
      expect(body, {
        'text': 'Reply',
        'requestId': 'stable-request',
        'parentCommentId': 'agc_root',
      });
      service.onClose();
    },
  );

  test(
    'wrong server parent and retired-account responses are rejected',
    () async {
      final wrong = AppletCatalogService(
        httpClient: MockClient(
          (_) async => http.Response(
            jsonEncode({'code': 'OK', 'data': _comment(parent: 'agc_other')}),
            200,
          ),
        ),
      );
      await expectLater(
        wrong.postCommentWithInput(
          'game',
          'Reply',
          requestId: 'r',
          parentCommentId: 'agc_root',
          expectedContextKey: wrong.requestContextKey,
        ),
        throwsFormatException,
      );
      wrong.onClose();
      final response = Completer<http.Response>();
      final service = AppletCatalogService(
        httpClient: MockClient((_) => response.future),
      );
      final pending = service.postCommentWithInput(
        'game',
        'Reply',
        requestId: 'r',
        parentCommentId: 'agc_root',
        expectedContextKey: service.requestContextKey,
      );
      await Future<void>.delayed(Duration.zero);
      appServices.find<AuthSessionService>().session.value = _session('next');
      response.complete(
        http.Response(jsonEncode({'code': 'OK', 'data': _comment()}), 200),
      );
      await expectLater(pending, throwsStateError);
      service.onClose();
    },
  );

  test('legacy comments remain valid without parent metadata', () {
    final json = _comment()..remove('parentCommentId');
    expect(AppletComment.fromJson(json).parentCommentId, isNull);
  });
}
