import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

/// Keep public-write failures actionable without displaying arbitrary server
/// payloads or losing the distinction between moderation and transport errors.
String gameCommentFailureMessage(Object error, {required bool chinese}) {
  String text(String zh, String en) => chinese ? zh : en;

  if (error is IdentityException) {
    return switch (error.failure) {
      IdentityFailure.authenticationRequired => text(
        '登录已过期，请重新登录后发送。草稿已保留。',
        'Please sign in again to send. Your draft has been kept.',
      ),
      IdentityFailure.rejected => text(
        '请先完成个人身份设置，再发送评论。草稿已保留。',
        'Complete your identity setup before commenting. Your draft has been kept.',
      ),
      IdentityFailure.contextChanged => text(
        '账号已切换，请关闭评论后重新打开。',
        'Your account changed. Close and reopen comments to continue.',
      ),
      _ => text(
        '暂时无法确认你的身份，请稍后重试。草稿已保留。',
        'Your identity could not be verified. Please try again. Your draft has been kept.',
      ),
    };
  }
  if (error is AppletCatalogRequestException) {
    if (error.code == 'COMMENT_REVIEW_PENDING') {
      return text(
        '评论正在审核，尚未发布。草稿已保留，通过后请重试发送。',
        'Your comment is awaiting review and has not been published. Your draft has been kept; retry after approval.',
      );
    }
    return switch (error.statusCode) {
      401 => text(
        '登录已过期，请重新登录后发送。草稿已保留。',
        'Please sign in again to send. Your draft has been kept.',
      ),
      403 => text(
        '这条评论未获准发布，请检查账号状态和评论内容。草稿已保留。',
        'This comment was not allowed. Check your account status and comment content. Your draft has been kept.',
      ),
      404 => text(
        '游戏或回复的评论已不可用，请刷新后重试。草稿已保留。',
        'The game or comment you are replying to is unavailable. Refresh and try again. Your draft has been kept.',
      ),
      409 => text(
        '评论状态已变化，请刷新后重试。草稿已保留。',
        'The comment state changed. Refresh and try again. Your draft has been kept.',
      ),
      400 || 422 => text(
        '评论内容不符合要求，请使用 1–180 个字符并去掉链接后重试。',
        'Use 1–180 characters and remove links before trying again.',
      ),
      429 => text(
        '评论发送太频繁，请稍后再试。草稿已保留。',
        'You are commenting too quickly. Please try again later. Your draft has been kept.',
      ),
      _ => text(
        '评论服务暂时不可用（HTTP ${error.statusCode}），请稍后重试。草稿已保留。',
        'Comments are temporarily unavailable (HTTP ${error.statusCode}). Please try again later. Your draft has been kept.',
      ),
    };
  }
  if (error is TimeoutException || error is http.ClientException) {
    return text(
      '网络连接失败，请检查网络后重试。草稿已保留。',
      'Could not connect. Check your connection and retry. Your draft has been kept.',
    );
  }
  if (error is StateError && error.message == 'applet_sign_in_required') {
    return text(
      '请先登录再发送评论。草稿已保留。',
      'Sign in before commenting. Your draft has been kept.',
    );
  }
  if (error is FormatException) {
    return text(
      '无法确认评论是否发布，请刷新评论列表后重试。草稿已保留。',
      'Could not confirm whether your comment was published. Refresh comments before retrying. Your draft has been kept.',
    );
  }
  return text(
    '评论未发送成功，请稍后重试。草稿已保留。',
    'Your comment was not sent. Please try again. Your draft has been kept.',
  );
}
