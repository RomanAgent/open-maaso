import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/utils/creation_intent_language.dart';
import 'package:maaso/src/core/utils/creation_request_normalization.dart';
import 'package:maaso/src/features/applets/domain/applet_request_intent.dart';

enum SurfaceIntentKind {
  none,
  applet,
  game,
  blog,
  guide,
  scene,
  album,
  dashboard,
  answerCard,
}

class SurfaceIntent {
  const SurfaceIntent({
    required this.kind,
    this.reason = '',
    this.confidence = 1.0,
  }) : _resolvedRequest = null;

  const SurfaceIntent._resolved({
    required this.kind,
    required String request,
    required this.confidence,
  }) : reason = 'resolved_creation',
       _resolvedRequest = request;

  /// A host-parsed work type, bound to the exact current human request.
  ///
  /// This is a semantic hint, not permission. The creation authority still
  /// validates affirmative intent and every denial/question/content boundary.
  static SurfaceIntent fromResolvedCreation({
    required String userText,
    required SurfaceIntentKind kind,
    double confidence = 1.0,
  }) {
    final request = _normalizedResolvedRequest(userText);
    if (request.isEmpty ||
        (kind != SurfaceIntentKind.game && kind != SurfaceIntentKind.applet) ||
        !confidence.isFinite ||
        confidence < 0 ||
        confidence > 1) {
      return none;
    }
    return SurfaceIntent._resolved(
      kind: kind,
      request: request,
      confidence: confidence,
    );
  }

  static const none = SurfaceIntent(
    kind: SurfaceIntentKind.none,
    confidence: 0,
  );

  final SurfaceIntentKind kind;
  final String reason;
  final double confidence;
  final String? _resolvedRequest;

  bool matchesResolvedRequest(String text) =>
      _resolvedRequest != null &&
      _resolvedRequest == _normalizedResolvedRequest(text);

  static String _normalizedResolvedRequest(String text) =>
      normalizeCreationRequest(
        text,
      ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

  bool get isSurface => kind != SurfaceIntentKind.none;

  String? get preferredSkill => isSurface ? 'FreeformSurface' : null;

  String get label => kind.name;

  String get promptDirective =>
      promptDirectiveFor(AgentPromptCatalog.currentLocale);

  String promptDirectiveFor(AppLocale locale) {
    if (!isSurface) return '';
    return AgentPromptCatalog.text(
      'runtime.surface_intent.directive',
      locale: locale,
      params: {'kind': kind.name},
    );
  }

  static SurfaceIntent classify(String text) {
    final lower = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (lower.isEmpty) return none;
    if (CreationIntentLanguage.isNegatedCreation(lower) ||
        CreationIntentLanguage.isNegatedRequiredSideEffect(lower)) {
      return none;
    }

    final appletRequest = AppletRequestIntent.classify(lower);
    if (appletRequest.isCreation) {
      return SurfaceIntent(
        kind: appletRequest.contentType == AppletContentType.game
            ? SurfaceIntentKind.game
            : SurfaceIntentKind.applet,
        reason: appletRequest.contentType.name,
      );
    }
    if (_containsAny(lower, const ['blog', '博客', '文章'])) {
      return const SurfaceIntent(kind: SurfaceIntentKind.blog, reason: 'blog');
    }
    if (_containsAny(lower, const [
      'travel guide',
      'trip guide',
      'city guide',
      'guide',
      'itinerary',
      '旅游指南',
      '旅行指南',
      '攻略',
      '行程',
    ])) {
      return const SurfaceIntent(
        kind: SurfaceIntentKind.guide,
        reason: 'guide',
      );
    }
    if (_containsAny(lower, const [
      'scene',
      'interactive scene',
      'environment',
      'world',
      '场景',
      '世界',
      '空间',
    ])) {
      return const SurfaceIntent(
        kind: SurfaceIntentKind.scene,
        reason: 'scene',
      );
    }
    if (_containsAny(lower, const [
      'album',
      'photo album',
      'gallery page',
      '相册',
      '影集',
    ])) {
      return const SurfaceIntent(
        kind: SurfaceIntentKind.album,
        reason: 'album',
      );
    }
    if (_containsAny(lower, const [
      'dashboard',
      'panel',
      'stats',
      'visualize',
      'visualization',
      'chart',
      '看板',
      '面板',
      '可视化',
      '图表',
      '统计',
    ])) {
      return const SurfaceIntent(
        kind: SurfaceIntentKind.dashboard,
        reason: 'dashboard',
      );
    }
    if (_containsAny(lower, const [
      'card',
      'present nicely',
      'display nicely',
      'make it pretty',
      '整理成卡片',
      '做成卡片',
      '卡片',
      '好看地展示',
    ])) {
      return const SurfaceIntent(
        kind: SurfaceIntentKind.answerCard,
        reason: 'answer_card',
      );
    }

    return none;
  }

  static bool _containsAny(String haystack, Iterable<String> needles) {
    for (final needle in needles) {
      if (haystack.contains(needle)) return true;
    }
    return false;
  }
}
