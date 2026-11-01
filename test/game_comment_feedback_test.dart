import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_comment_feedback.dart';

void main() {
  test(
    'moderation pending is distinct from a transport or conflict failure',
    () {
      final error = AppletCatalogRequestException(
        409,
        'COMMENT_REVIEW_PENDING',
      );
      expect(gameCommentFailureMessage(error, chinese: true), contains('正在审核'));
      expect(
        gameCommentFailureMessage(error, chinese: false),
        contains('has not been published'),
      );
      expect(
        gameCommentFailureMessage(
          AppletCatalogRequestException(409, 'CONFLICT'),
          chinese: true,
        ),
        contains('状态已变化'),
      );
    },
  );

  test(
    'identity, session, network and server errors explain the next action',
    () {
      final cases = <Object, String>{
        const IdentityException(IdentityFailure.rejected): '身份设置',
        const IdentityException(IdentityFailure.unavailable): '确认你的身份',
        StateError('applet_sign_in_required'): '先登录',
        TimeoutException('network timeout'): '网络',
        http.ClientException('connection failed'): '网络',
        AppletCatalogRequestException(401, 'UNAUTHORIZED'): '重新登录',
        AppletCatalogRequestException(403, 'FORBIDDEN'): '未获准',
        AppletCatalogRequestException(404, 'NOT_FOUND'): '已不可用',
        AppletCatalogRequestException(400, 'VALIDATION_ERROR'): '1–180',
        AppletCatalogRequestException(429, 'RATE_LIMITED'): '太频繁',
        AppletCatalogRequestException(500, 'INTERNAL_ERROR'): 'HTTP 500',
        const FormatException('invalid_applet_envelope'): '是否发布',
        StateError('applet_comment_not_saved'): '未发送成功',
      };
      for (final entry in cases.entries) {
        expect(
          gameCommentFailureMessage(entry.key, chinese: true),
          contains(entry.value),
        );
        expect(
          gameCommentFailureMessage(entry.key, chinese: false).trim(),
          isNotEmpty,
        );
      }
    },
  );
}
