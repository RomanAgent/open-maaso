import 'package:maaso/src/core/utils/creation_intent_language.dart';
import 'package:maaso/src/core/utils/explicit_creation_question_guard.dart';

enum AppletRequestKind { none, discover, create }

enum AppletContentType { any, applet, game }

/// Deterministic distinction between asking to use an existing Applet and
/// explicitly asking the Agent to build a new one.
class AppletRequestIntent {
  const AppletRequestIntent({required this.kind, required this.contentType});

  static const none = AppletRequestIntent(
    kind: AppletRequestKind.none,
    contentType: AppletContentType.any,
  );

  final AppletRequestKind kind;
  final AppletContentType contentType;

  bool get isDiscovery => kind == AppletRequestKind.discover;
  bool get isCreation => kind == AppletRequestKind.create;

  static AppletRequestIntent classify(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return none;
    if (CreationIntentLanguage.isNegatedCreation(normalized) ||
        CreationIntentLanguage.isNegatedRequiredSideEffect(normalized)) {
      return none;
    }
    if (ExplicitCreationQuestionGuard.blocks(normalized)) return none;

    final hasGame = _containsAny(normalized, const <String>[
      '小游戏',
      '游戏',
      'mini-game',
      'mini game',
      'game',
    ]);
    final hasApplet = _containsAny(normalized, const <String>[
      '小程序',
      'mini-app',
      'mini app',
      'applet',
    ]);
    if (!hasGame && !hasApplet) return none;
    if (_requestsContentAboutApplet(normalized)) return none;

    final product = _creationProduct(normalized)?.group(1);
    final contentType = product != null
        ? (product == '游戏' || product == '小游戏' || product.contains('game')
              ? AppletContentType.game
              : AppletContentType.applet)
        : hasGame
        ? AppletContentType.game
        : AppletContentType.applet;
    if (_hasNamedCreationCommand(normalized) ||
        _containsAny(normalized, const <String>[
          '我要生成',
          '帮我生成',
          '生成游戏',
          '生成小程序',
          '生成一个',
          '生成个',
          '我要做',
          '帮我做',
          '制作游戏',
          '制作小程序',
          '开发游戏',
          '开发小程序',
          '做一个',
          '做个',
          '创建一个',
          '创建个',
          '制作一个',
          '开发一个',
          'generate a',
          'generate an',
          'generate game',
          'generate applet',
          'make me a',
          'make a',
          'create a',
          'create an',
          'build a',
          'build an',
          'develop a',
          'develop an',
        ])) {
      return AppletRequestIntent(
        kind: AppletRequestKind.create,
        contentType: contentType,
      );
    }

    if (_containsAny(normalized, const <String>[
      '想玩',
      '我要玩',
      '玩一个',
      '玩个',
      '找一个',
      '找个',
      '搜索',
      '搜一下',
      '推荐一个',
      '推荐个',
      '有什么',
      'want to play',
      'play a',
      'play an',
      'find a',
      'find an',
      'search for',
      'show me a',
      'recommend a',
      'looking for',
    ])) {
      return AppletRequestIntent(
        kind: AppletRequestKind.discover,
        contentType: contentType,
      );
    }

    return none;
  }

  static bool _containsAny(String value, Iterable<String> candidates) {
    for (final candidate in candidates) {
      if (value.contains(candidate)) return true;
    }
    return false;
  }

  /// Recognizes a user command with any game name or description. The verb
  /// must begin the request; noun phrases about tools/models are not commands.
  static const _englishRequestPrefix =
      r'(?:(?:please|kindly)\s+|(?:can|could|would|will)\s+you\s+(?:please\s+)?|(?:help\s+me|i\s+(?:want|need)(?:\s+you)?\s+to)\s+)?';

  /// Finds the product being created, excluding product words used as
  /// modifiers: "game-score tracking mini app" creates an applet.
  static RegExpMatch? _creationProduct(String value) {
    return RegExp(
          r'^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|(?:可以|能不能)(?:请你)?(?:帮我|给我|替我|帮忙)?|(?:帮我|给我|替我)|我(?:要|想))?(?:新建并)?(?:生成|创建|制作|开发|写|做|设计)[^，。！？；：,.!?;:]*?(小游戏|游戏|小程序)(?=[，。！？；：,.!?;:（(\[\s]|$|吗|要|需要|支持|包含|带|并|同时|使用|采用|具备|有)',
        ).firstMatch(value) ??
        RegExp(
          '^$_englishRequestPrefix'
          r'(?:generate|create|build|make|develop|write|design)\s+[^,.!?;:]*?\b(mini[- ]?game|game|mini[- ]?app|applet)\b(?=\s*(?:$|[,.!?;:])|\s+(?:with|including|containing|featuring|that|and|using|called|named|based|supporting|for)\b)',
        ).firstMatch(value);
  }

  static bool _hasNamedCreationCommand(String value) {
    final chinese = RegExp(
      r'^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|(?:可以|能不能)(?:请你)?(?:帮我|给我|替我|帮忙)?|(?:帮我|给我|替我)|我(?:要|想))?(?:新建并)?(?:生成|创建|制作|开发|写|做)(?:一个|个|一款|款)?([^，。！？；：,.!?;:]*?)(?:小游戏|游戏)(?:吗)?(?=[，。！？；：,.!?;:（(\[\s]|$|要|需要|支持|包含|带|并|同时|使用|采用|具备|有)',
    ).firstMatch(value);
    if (chinese != null) {
      final description = chinese.group(1)!.trim();
      return !RegExp(
        r'^(?:模型(?:输出|返回|生成|产出|预测)|工具(?:支持|包含|用于)|模式(?:包含|支持)|(?:完成|过)的|器(?:支持|能够|可以|的)|者(?:如何|正在)|团队(?:正在|演示|制作|开发)|公司(?:演示|展示|制作|正在))',
      ).hasMatch(description);
    }
    final english = RegExp(
      '^$_englishRequestPrefix'
      r'(?:generate|create|build|make|develop|write)\s+(?:(?:an?|the)\s+)?([^.!?;:]*?)\b(?:mini[- ]?game|game)\b',
    ).firstMatch(value);
    if (english == null) return false;
    return !RegExp(
      r'^(?:model\s+(?:outputs?|returns?|generates?)|(?:tool|mode|generator)\s+(?:supports?|includes?|provides?)|(?:team|company)\s+(?:is|are|shows?|demonstrates?|develops?))\b',
    ).hasMatch(english.group(1)!.trim());
  }

  static bool _requestsContentAboutApplet(String value) {
    // The requested output may describe a product even when a product noun
    // ends the sentence, e.g. "generate a review of a game-score mini app".
    if (RegExp(
      '^$_englishRequestPrefix'
      r'(?:write|make|create|generate|build|develop|design)\s+[^.!?;:]*?\b(?:guide|article|tutorial|review|explanation|story|cover|manual|plan|walkthrough|documentation)\b[^.!?;:]*?\b(?:to|for|about|on|of)\b[^.!?;:]*?\b(?:mini[- ]?game|game|mini[- ]?app|applet)\b',
    ).hasMatch(value)) {
      final product = _creationProduct(value);
      final content = RegExp(
        r'\b(?:guide|article|tutorial|review|explanation|story|cover|manual|plan|walkthrough|documentation)\b',
      ).firstMatch(value);
      if (product == null ||
          content!.start < product.end - product.group(1)!.length) {
        return true;
      }
    }
    // Use the same request prefix as game creation. A prepositional object in
    // a writing request is content about the game, not the game itself.
    final writing = RegExp(
      '^$_englishRequestPrefix'
      r'write\s+([^.!?;:]*)',
    ).firstMatch(value);
    if (writing != null) {
      final object = writing.group(1)!;
      final product = RegExp(
        r'\b(?:mini[- ]?game|game|mini[- ]?app|applet)\b',
      ).firstMatch(object);
      final relation = RegExp(r'\b(?:to|for|about|on|of)\b').firstMatch(object);
      if (product != null &&
          relation != null &&
          relation.start < product.start) {
        return true;
      }
    }
    // A noun after the game without a feature relation (game documentation,
    // game manual, etc.) is the requested output object, independent of topic.
    final english = RegExp(
      '^$_englishRequestPrefix'
      r'(?:write|make|create|generate|build|develop)\s+[^.!?;:]*?\b(?:mini[- ]?game|game|mini[- ]?app|applet)\b([^.!?;:]*)',
    ).firstMatch(value);
    if (english != null) {
      final product = _creationProduct(value);
      final tail = product == null
          ? english.group(1)!.trim()
          : value.substring(product.end).split(RegExp(r'[.!?;:]')).first.trim();
      if (tail.isNotEmpty &&
          !RegExp(
            r'^(?:with|including|containing|featuring|that|and|using|called|named|based|supporting|than|for)\b',
          ).hasMatch(tail)) {
        return true;
      }
    }
    // Game features may include documentation; retain every positive feature
    // connector used by the creation matcher instead of matching final nouns.
    if (RegExp(
      r'(?:小游戏|游戏|小程序)(?:有|要|需要|带|附带|包含|支持|具备|并|同时|使用|采用)|\b(?:mini[- ]?game|game|mini[- ]?app|applet)\b\s+(?:with|including|containing|featuring|that|and|using)\b',
    ).hasMatch(value)) {
      return false;
    }
    return RegExp(
          r'^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|(?:帮我|给我|替我)|我(?:要|想))?(?:写|做|生成|创建|制作|开发)[^，。！？；：,.!?;:]*?(?:攻略|文章|教程|说明|介绍|评测|文案|故事|封面)(?=[，。！？；：,.!?;:]|$)',
        ).hasMatch(value) ||
        RegExp(
          '^$_englishRequestPrefix'
          r'(?:write|make|create|generate|build)\b[^.!?;:]*\b(?:guide|article|tutorial|review|explanation|story|cover)\b(?=[,.!?;:]|$)',
        ).hasMatch(value);
  }
}
