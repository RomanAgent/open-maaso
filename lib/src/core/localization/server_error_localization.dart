import 'package:maaso/src/core/foundation/app_localization.dart';

/// Returns localized user-facing copy for stable server envelope codes.
///
/// Raw server messages remain useful in diagnostics, but must not leak into a
/// localized UI. Unknown codes return `null` so callers can preserve their
/// existing non-server fallback behavior.
String? localizedServerErrorCode(String code) {
  return switch (code.trim().toUpperCase()) {
    'COMMENT_REVIEW_PENDING' =>
      AppLocalization.locale.languageCode == 'zh'
          ? '评论正在审核，草稿已保留。审核通过后请重试发送。'
          : 'Your comment is awaiting review. Your draft is kept; retry sending after approval.',
    'RATE_LIMITED' ||
    'AUTH_TOO_MANY_ATTEMPTS' => 'common.request_rate_limited'.tr,
    'FORBIDDEN' ||
    'SYSTEM_ADMIN_ACCESS_DENIED' => 'common.action_unavailable'.tr,
    'VALIDATION_ERROR' ||
    'NOT_FOUND' ||
    'UNAUTHORIZED' ||
    'CONFLICT' ||
    'UNPROCESSABLE_ENTITY' ||
    'INTERNAL_ERROR' => 'common.request_failed'.tr,
    _ => null,
  };
}
