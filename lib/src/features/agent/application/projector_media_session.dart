import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/projector_intent.dart';

enum ProjectorMediaResolutionKind { none, gallery, onlineImage }

class ProjectorMediaResolution {
  const ProjectorMediaResolution({
    required this.kind,
    this.imageQuery,
    this.reason = '',
  });

  static const none = ProjectorMediaResolution(
    kind: ProjectorMediaResolutionKind.none,
  );

  final ProjectorMediaResolutionKind kind;
  final String? imageQuery;
  final String reason;

  bool get isProjectorFollowUp => kind != ProjectorMediaResolutionKind.none;
  bool get shouldSearch => kind == ProjectorMediaResolutionKind.onlineImage;
  bool get shouldUseGallery => kind == ProjectorMediaResolutionKind.gallery;

  String get promptBlock => promptBlockFor(AgentPromptCatalog.currentLocale);

  String promptBlockFor(AppLocale locale) {
    switch (kind) {
      case ProjectorMediaResolutionKind.gallery:
        return AgentPromptCatalog.text(
          'runtime.projector.gallery',
          locale: locale,
        );
      case ProjectorMediaResolutionKind.onlineImage:
        return AgentPromptCatalog.text(
          'runtime.projector.online_image',
          locale: locale,
          params: {'query': imageQuery ?? ''},
        );
      case ProjectorMediaResolutionKind.none:
        return '';
    }
  }
}

class ProjectorMediaSession {
  ProjectorMediaSession({this.ttl = const Duration(minutes: 5)});

  final Duration ttl;
  DateTime? _awaitingMediaSourceSince;

  bool get isAwaitingMediaSource => _awaitingMediaSourceSince != null;

  void markAwaitingMediaSource({DateTime? now}) {
    _awaitingMediaSourceSince = now ?? DateTime.now();
  }

  void clear() {
    _awaitingMediaSourceSince = null;
  }

  void observeAssistantText(String text, {DateTime? now}) {
    if (isProjectorMediaChoiceContext(text) ||
        _looksLikeMediaChoicePrompt(text)) {
      markAwaitingMediaSource(now: now);
    }
  }

  ProjectorMediaResolution resolveUserText(
    String text, {
    String recentConversation = '',
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    if (_isExpired(at)) clear();
    final active =
        isAwaitingMediaSource ||
        isProjectorMediaChoiceContext(recentConversation);
    if (!active) return ProjectorMediaResolution.none;

    if (isProjectorGalleryChoiceText(text)) {
      clear();
      return const ProjectorMediaResolution(
        kind: ProjectorMediaResolutionKind.gallery,
        reason: 'gallery',
      );
    }
    if (isProjectorOnlineImageChoiceText(text) ||
        isProjectorImageSubjectChoiceText(text)) {
      final resolution = ProjectorMediaResolution(
        kind: ProjectorMediaResolutionKind.onlineImage,
        imageQuery: _onlineQuery(text),
        reason: isProjectorOnlineImageChoiceText(text)
            ? 'online_image'
            : 'bare_subject',
      );
      clear();
      return resolution;
    }
    // The pending media-source question is a one-turn slot, not a device mode.
    // Any unrelated response closes it so later chat cannot inherit stale
    // projector intent merely because the projector remains connected.
    clear();
    return ProjectorMediaResolution.none;
  }

  bool _isExpired(DateTime now) {
    final since = _awaitingMediaSourceSince;
    return since != null && now.difference(since) > ttl;
  }

  String _onlineQuery(String text) {
    final normalized = normalizeProjectorChoiceText(text);
    if (isProjectorOnlineImageChoiceText(text)) {
      return normalized
          .replaceAll(RegExp(r'\b(find|search|look up|google)\b'), '')
          .replaceAll(RegExp(r'\b(online|web|internet)\b'), '')
          .replaceAll(RegExp(r'\b(image|picture|photo|pic)\b'), '')
          .replaceAll(RegExp(r'(帮我|找|搜|搜索|网上|网络|图片|照片|一张|一个)'), '')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();
    }
    return normalized;
  }

  bool _looksLikeMediaChoicePrompt(String text) {
    final lower = text.toLowerCase();
    return textContainsAny(lower, const ['gallery', '相册', '图库']) &&
        textContainsAny(lower, const [
          'online',
          'web',
          'internet',
          '网上',
          '网络',
        ]) &&
        textContainsAny(lower, const ['photo', 'picture', 'image', '照片', '图片']);
  }
}
