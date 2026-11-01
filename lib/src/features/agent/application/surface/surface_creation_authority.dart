import 'package:maaso/src/core/utils/creation_intent_language.dart';
import 'package:maaso/src/core/utils/creation_request_normalization.dart';
import 'package:maaso/src/core/utils/explicit_creation_question_guard.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/applets/domain/applet_request_intent.dart';

/// Converts a routing hint into creation authority only for an explicit
/// user-authored request.
///
/// [SurfaceIntent] and the turn policy are deliberately broader than an
/// authorization decision: they also cover content nouns, an already-open
/// surface and prompt-shaping hints. This guard requires an affirmative
/// creation/presentation command and rejects negated creation before a
/// [SurfaceExecutionGrant] can be issued.
final class SurfaceCreationAuthority {
  const SurfaceCreationAuthority._();

  /// Normalizes only a literal user-authored image-reference preamble.
  /// The remaining command still passes every denial/question/creation guard.
  /// Image descriptions and agent.md content must never call this as authority.
  static String normalizeRequest(String text) => normalizeCreationRequest(text);

  /// Whether the current human message can ask a semantic classifier for the
  /// type of work being made. A type result can never supply the user's verb.
  static bool canResolveCreation(String text) {
    final normalized = normalizeRequest(
      text,
    ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    final command = _independentCreationCommand(normalized);
    final questionText = _outerCreationQuestionText(command ?? normalized);
    if (normalized.isEmpty ||
        CreationIntentLanguage.isNegatedCreation(normalized) ||
        CreationIntentLanguage.isNegatedRequiredSideEffect(normalized) ||
        ExplicitCreationQuestionGuard.blocks(questionText) ||
        _isAmbiguousCommandQuestion(questionText) ||
        _isInformationalQuestion(questionText) ||
        command == null) {
      return false;
    }
    final object = _creationObject(command);
    return object != null &&
        object.isNotEmpty &&
        !_isNonInteractiveOutput(object) &&
        !RegExp(
          r'^(?:器|模型(?:输出|返回|生成|产出|预测)|工具(?:支持|包含|用于)|模式(?:包含|支持)|(?:完成|过)的|者(?:如何|正在)|团队(?:正在|演示|制作|开发)|公司(?:演示|展示|制作|正在))|'
          r'^(?:model\s+(?:outputs?|returns?|generates?)|(?:tool|mode|generator)\s+(?:supports?|includes?|provides?)|(?:team|company)\s+(?:is|are|shows?|demonstrates?|develops?))\b',
        ).hasMatch(object);
  }

  /// The explicit product path wins; a request-bound semantic type supplements
  /// only requests whose work type was not already resolved by that path.
  static SurfaceIntent resolveSurfaceIntent({
    required String text,
    SurfaceIntent resolvedSurfaceIntent = SurfaceIntent.none,
  }) {
    final normalized = normalizeRequest(text).toLowerCase();
    final classified = SurfaceIntent.classify(
      _independentCreationCommand(normalized) ?? normalized,
    );
    if (experienceTypeFor(
          text: text,
          interactiveHint: true,
          surfaceIntent: classified,
        ) !=
        null) {
      return classified;
    }
    if (resolvedSurfaceIntent.matchesResolvedRequest(text) &&
        canResolveCreation(text)) {
      return resolvedSurfaceIntent;
    }
    return classified;
  }

  static SurfaceExperienceType? experienceTypeFor({
    required String text,
    required bool interactiveHint,
    required SurfaceIntent surfaceIntent,
  }) {
    if (!interactiveHint) return null;
    final normalized = normalizeRequest(
      text,
    ).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (normalized.isEmpty ||
        CreationIntentLanguage.isNegatedCreation(normalized) ||
        CreationIntentLanguage.isNegatedRequiredSideEffect(normalized)) {
      return null;
    }
    final command = _independentCreationCommand(normalized);
    if (command == null) return null;
    final object = _creationObject(command);
    if (object != null && _isNonInteractiveOutput(object)) return null;
    final questionText = _outerCreationQuestionText(command);
    if (ExplicitCreationQuestionGuard.blocks(questionText)) return null;
    if (_isAmbiguousCommandQuestion(questionText)) return null;
    if (_isInformationalQuestion(questionText)) return null;

    // A score tracker/editor about games creates a tool. The incidental game
    // noun is not an explicit product type and must not override a bound type.
    if (_hasUtilityOutputObject(command)) {
      if (!surfaceIntent.matchesResolvedRequest(text) ||
          !canResolveCreation(text)) {
        return null;
      }
      return switch (surfaceIntent.kind) {
        SurfaceIntentKind.game => SurfaceExperienceType.game,
        SurfaceIntentKind.applet => SurfaceExperienceType.utility,
        _ => null,
      };
    }

    final appletRequest = AppletRequestIntent.classify(command);
    if (appletRequest.isCreation &&
        appletRequest.contentType == AppletContentType.game) {
      return SurfaceExperienceType.game;
    }
    if (_isChineseModalCreationCommand(command) &&
        surfaceIntent.kind == SurfaceIntentKind.game &&
        _containsAny(command, const ['小游戏', '游戏'])) {
      return SurfaceExperienceType.game;
    }

    // Utility creation requires the product noun, not a request for ordinary
    // content such as a travel itinerary, article, chart, or dashboard.
    if (_hasExplicitAppletCreationCommand(command)) {
      return SurfaceExperienceType.utility;
    }
    if (_containsAny(command, const ['game', '游戏']) &&
        surfaceIntent.kind == SurfaceIntentKind.game) {
      return SurfaceExperienceType.game;
    }
    if (surfaceIntent.matchesResolvedRequest(text) &&
        canResolveCreation(text)) {
      return switch (surfaceIntent.kind) {
        SurfaceIntentKind.game => SurfaceExperienceType.game,
        SurfaceIntentKind.applet => SurfaceExperienceType.utility,
        _ => null,
      };
    }
    return null;
  }

  /// A leading question or preference does not erase a separate imperative in
  /// the same human message. This extracts only an unquoted command for local
  /// guards; callers still bind semantic results and pass the complete brief.
  /// Negated creation/persistence/presentation is checked on the full message.
  static String? _independentCreationCommand(String text) {
    if (_hasAffirmativePresentationCommand(text)) return text;
    final visible = _maskQuotedText(text);
    final boundaries = RegExp(r'[,，;；。.!?！？\n]|\b(?:and|then)\s+|(?:然后|接着)');
    for (final boundary in boundaries.allMatches(visible)) {
      final suffix = text.substring(boundary.end).trimLeft();
      if (!_hasAffirmativePresentationCommand(suffix)) continue;
      // Reported speech, examples, translations and plans remain data even
      // when their text contains a standalone-looking imperative.
      final prefix = visible.substring(0, boundary.start).trim();
      if (RegExp(
            r'^(?:(?:请|麻烦)(?:你)?|帮我|给我)?(?:翻译|复述|引用|润色|改写|解释|分析|讨论|评价|举例|假设|例如|比如|示例)|'
            r'^(?:只|仅|先只)(?:是|想|要)?(?:讨论|分析|了解|说明|解释)|'
            r'^(?:如果|假如|要是)(?:我|用户|有人)(?:说|要求|输入|写)|'
            r'(?:他说|她说|用户说|原话|这句话|这个句子|提示词|代码示例|示例代码)|'
            r'^(?:(?:please|kindly|can you|could you|only|just)\s+)?(?:translate|quote|paraphrase|proofread|rewrite|explain|discuss|analy[sz]e|evaluate|suppose|imagine)\b|'
            r'\b(?:for example|example|sentence|phrase|prompt|he said|she said|user said)\b|'
            r'^(?:if|when)\s+(?:(?:a|the)\s+)?(?:user|someone|i|he|she)\s+(?:said|says|say|asks?|writes?|requests?|types?)\b',
          ).hasMatch(prefix) ||
          RegExp(
            r'(?:只|仅|先只)(?:给|要|写|看|讨论|分析|设计)?(?:一(?:个|份))?(?:方案|计划|思路|说明|教程|示例)|'
            r'\b(?:only|just)\s+(?:(?:give|write|show|discuss)\s+(?:me\s+)?)?(?:a\s+)?(?:plan|proposal|explanation|example|tutorial)\b',
          ).hasMatch(text)) {
        return null;
      }
      // A candidate that begins inside a quoted/code region is never a human
      // instruction. Checking the visible prefix also handles unmatched quotes.
      if (_hasAffirmativePresentationCommand(
        visible.substring(boundary.end).trimLeft(),
      )) {
        return suffix;
      }
    }
    return null;
  }

  static String _maskQuotedText(String text) {
    final output = StringBuffer();
    final closing = <int>[];
    const pairs = <int, int>{
      0x22: 0x22, // double quote
      0x27: 0x27, // single quote
      0x60: 0x60, // code tick
      0x201c: 0x201d,
      0x2018: 0x2019,
      0x300c: 0x300d,
      0x300e: 0x300f,
      0x300a: 0x300b,
    };
    bool isWord(int code) =>
        (code >= 0x61 && code <= 0x7a) || (code >= 0x30 && code <= 0x39);
    for (var index = 0; index < text.length; index++) {
      final code = text.codeUnitAt(index);
      final apostrophe =
          code == 0x27 &&
          index > 0 &&
          index + 1 < text.length &&
          isWord(text.codeUnitAt(index - 1)) &&
          isWord(text.codeUnitAt(index + 1));
      if (closing.isNotEmpty) {
        output.write(' ');
        if (code == 0x5c && index + 1 < text.length) {
          output.write(' ');
          index++;
          continue;
        }
        if (!apostrophe && code == closing.last) closing.removeLast();
      } else if (!apostrophe && pairs.containsKey(code)) {
        closing.add(pairs[code]!);
        output.write(' ');
      } else {
        output.writeCharCode(code);
      }
    }
    return output.toString();
  }

  static String? _creationObject(String text) {
    final chinese = RegExp(
      r'^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|(?:可以|能不能)(?:请你)?(?:帮我|给我|替我|帮忙)?|(?:帮我|给我|替我)|我(?:要|想))?'
      r'(?:新建并)?(?:生成|创建|制作|开发|写|做|设计|画一个|整理成|展示成|转成|变成)(.*)$',
    ).firstMatch(text);
    if (chinese != null) return chinese.group(1)!.trim();
    final english = RegExp(
      r'^(?:(?:please|kindly)\s+|(?:can|could|would|will)\s+you\s+(?:please\s+)?|(?:help\s+me|i\s+(?:want|need)(?:\s+you)?\s+to)\s+)?'
      r'(?:generate|create|build|make|design|develop|write|draft|visualize|visualise|render)\b\s+(.+)$',
    ).firstMatch(text);
    return english?.group(1)?.trim();
  }

  /// Question guards inspect the user's outer request. A bounded, explicitly
  /// requested tutorial/help region inside a created product remains content.
  /// Denied creation and denied persistence/presentation are checked against
  /// the complete message before this helper is used to grant authority.
  static String _outerCreationQuestionText(String text) {
    if (!_hasAffirmativePresentationCommand(text)) return text;
    final clauses = text.split(
      RegExp(
        r'[,，;；\n]|\band\s+(?=(?:add|include|provide|show|display)\b)|(?:并且|同时|而且)',
      ),
    );
    bool isProductHelpClause(String clause) {
      final value = clause.trim();
      final helpObject = RegExp(
        r'^(?:(?:请|另外|还|也|再)?(?:附|加入|加上|添加|包含|带有|提供|显示|展示|增加)(?:一(?:个|段|份)|详细(?:的)?|简短(?:的)?)?(?:操作|玩法|游戏|使用|新手|按钮)?(?:说明|教程|指南|提示|指引|帮助)|'
        r'(?:操作说明|玩法说明|教程|操作指南|使用指南|帮助)(?:页面|区域|部分)?(?:要|应当|应该|需要|可以)?(?:告诉|解释|说明|展示|显示)|'
        r'(?:在)?(?:首页|首屏|页面|界面|结束页|帮助页|操作区)(?:上|中|里)?(?:显示|展示|告诉我|解释|说明)(?:.*)(?:操作|玩法|重新开始|重开|下一关))',
      ).hasMatch(value);
      final englishHelp = RegExp(
        r'^(?:(?:add|include|provide|show|display)\s+(?:an?\s+)?(?:short\s+|detailed\s+)?(?:instructions?|tutorial|help|controls?\s+guide)|'
        r'(?:instructions?|tutorial|help\s+(?:page|panel|text))\s+(?:that\s+|which\s+)?(?:should\s+|must\s+|can\s+)?(?:explain|show|describe)|'
        r'(?:the\s+)?(?:home|first|end|help)\s+(?:page|screen|panel)\s+(?:should\s+|must\s+)?(?:show|display|explain))\b',
      ).hasMatch(value);
      return helpObject || englishHelp;
    }

    return [
      for (final (index, clause) in clauses.indexed)
        if (index == 0 || !isProductHelpClause(clause)) clause,
    ].join(', ');
  }

  static bool _hasUtilityOutputObject(String text) {
    if (_hasExplicitAppletCreationCommand(text)) return false;
    final object = _creationObject(
      text,
    )?.split(RegExp(r'[,，;；。.!?！？]')).first.trim();
    if (object == null) return false;
    // A genuine game followed by a feature mentioning an editor stays a game.
    if (RegExp(
      r'(?:小游戏|游戏)(?=支持|包含|带|并|同时|使用|采用|具备|有|$)|\b(?:mini[ -]?game|game)\b\s+(?:with|including|featuring|that|where|and)\b',
    ).hasMatch(object)) {
      return false;
    }
    return RegExp(
      r'(?:工具|记录器|统计器|跟踪器|编辑器|管理器|计算器)(?=$|支持|包含|带|并|同时|可以|能够|用于)|'
      r'\b(?:tool|tracker|editor|manager|calculator|dashboard|monitor)\b',
    ).hasMatch(object);
  }

  static bool _isNonInteractiveOutput(String object) {
    // Check the requested output object, before feature clauses. A game can
    // contain a tutorial/story; a tutorial/story about gameplay is not a game.
    final head = object.split(RegExp(r'[，。！？；：,.!?;:]')).first.trim();
    return RegExp(
          r'(?:文章|故事|教程|说明|介绍|评测|文案|封面|方案|计划|攻略|指南|文档|报告|伪代码|代码示例|示例代码|插画|图片|照片|视频|音频|歌曲|诗歌|小说|歌词|邮件|摘要|总结|翻译)$|'
          r'^(?:一篇|一份|一段|一张|一幅)?(?:文章|教程|攻略|报告|指南|文档|方案|计划|故事|文案|封面)(?:关于|介绍|讲述|分析|来|给|供|用于|以)',
        ).hasMatch(head) ||
        RegExp(
          r'^(?:(?:an?|the)\s+)?(?:(?!(?:with|including|containing|featuring|that|where|which|and|using)\b)[a-z-]+\s+){0,4}(?:guide|article|tutorial|review|explanation|story|cover|manual|plan|walkthrough|documentation|report|pseudocode|illustration|picture|photo|video|audio|song|poem|novel|lyrics|email|summary|translation)\b',
        ).hasMatch(head);
  }

  static bool _hasExplicitAppletCreationCommand(String text) {
    // The applet must be the thing being created. A later mention such as
    // "create an itinerary using an applet" only requests use of existing UI.
    const englishPrefix =
        r'(?:(?:please|kindly)\s+|(?:can|could|would|will)\s+you\s+(?:please\s+)?|(?:help\s+me|i\s+(?:want|need)(?:\s+you)?\s+to)\s+)?';
    if (RegExp(
      '^$englishPrefix(?:generate|create|build|make|design|develop|write)'
      r'(?:\s+(?!(?:using|with|via|through|from|inside|in|for|about|into|of|on|to)\b)[a-z0-9-]+){0,12}?'
      r'\s+(?:mini[ -]app|applet)\b',
    ).hasMatch(text)) {
      return true;
    }
    final chinese = RegExp(
      r'^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|(?:可以|能不能)(?:请你)?(?:帮我|给我|替我)?|(?:帮我|给我|替我)|我(?:要|想))?'
      r'(?:新建并(?:生成|创建|制作|开发)|生成|创建|制作|开发|做|写|设计)([^，。！？；：,.!?;:]{0,48}?)小程序',
    ).firstMatch(text);
    if (chinese == null) return false;
    final objectDescription = chinese.group(1)!;
    return !RegExp(
      r'现有|已有|(?:通过|借助|使用|利用)(?:这个|那个|当前|一个)|(?:行程|计划|文章|内容)(?:来)?用',
    ).hasMatch(objectDescription);
  }

  static bool _isChineseModalCreationCommand(String text) => RegExp(
    r'^(?:可以|能不能)(?:请你)?(?:帮我|给我|替我|帮忙)?(?:生成|创建|制作|开发|做一个|做个)',
  ).hasMatch(text);

  static bool _hasAffirmativePresentationCommand(String text) {
    if (RegExp(r'^新建并(?:生成|创建|制作|开发)').hasMatch(text)) return true;
    const englishVerb =
        r'(?:generate|create|build|make|design|develop|write|draft|visualize|visualise|render)';
    if (RegExp('^(?:(?:please|kindly)\\s+)?$englishVerb\\b').hasMatch(text) ||
        RegExp(
          '^(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?$englishVerb\\b',
        ).hasMatch(text) ||
        RegExp(
          '^(?:help\\s+me|i\\s+(?:want|need)(?:\\s+you)?\\s+to)\\s+$englishVerb\\b',
        ).hasMatch(text) ||
        RegExp(r'^(?:show me an?|turn|convert|present)\b').hasMatch(text)) {
      return true;
    }
    return RegExp(
      r'^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|(?:可以|能不能)(?:请你)?(?:帮我|给我|替我)?|(?:帮我|给我|替我)|我(?:要|想))?(?:生成|创建|制作|开发|做|写|设计|画一个|整理成|展示成|转成|变成|把.+可视化|可视化)',
    ).hasMatch(text);
  }

  static bool _isInformationalQuestion(String text) {
    if (RegExp(r'^(?:what|how|why|when|where|which|who)\b').hasMatch(text)) {
      return true;
    }
    return RegExp(r'^(?:什么是|如何|怎么|为什么|怎样)').hasMatch(text) ||
        RegExp(
          r'(?:要|需要|应该|可以|能|会|得).*(?:什么|多久|多长|怎么|如何|哪些|多少)[?？]?$',
        ).hasMatch(text) ||
        RegExp(
          r'(?:是什么|有什么|有哪些|是多少|有多少|多久|多长|怎么做|如何做|为什么|哪个|哪些)[?？]?$',
        ).hasMatch(text) ||
        RegExp(r'(?:是|有|需不需要|可不可以|能不能|会不会).*(?:吗|么|呢)[?？]?$').hasMatch(text);
  }

  static bool _isAmbiguousCommandQuestion(String text) {
    if (RegExp(
          r'\b(?:or|versus|vs\.?)\b.{0,80}\b(?:which|what)\b.{0,32}\b(?:better|safer|cheaper|faster|easier|best)\b|'
          r'[—–:;,]\s*(?:what|how|why|when|where|which|who)\b',
        ).hasMatch(text) ||
        RegExp(
          r'(?:还是|或者).{0,80}(?:更好|更安全|更便宜|更快|更容易|哪个好|哪种好|怎么选|选哪个|会怎样)',
        ).hasMatch(text)) {
      return true;
    }
    if (!RegExp(r'[?？]\s*$').hasMatch(text)) return false;
    if (RegExp(r'\b(?:what|how|why|when|where|which|who)\b').hasMatch(text) ||
        RegExp(
          r'(?:什么|哪里|哪儿|怎么|如何|为什么|多少|多久|多长|哪个|哪些|难不难|还是|或者.{0,20}(?:更好|更安全|更便宜|会怎样))',
        ).hasMatch(text)) {
      return true;
    }
    final explicitRequest =
        RegExp(
          r'^(?:please|kindly|can you|could you|would you|will you|help me|i (?:want|need)(?: you)? to|show me)\b',
        ).hasMatch(text) ||
        RegExp(r'^(?:请|麻烦|帮我|给我|替我|我要|我想|可以|能不能)').hasMatch(text);
    return !explicitRequest;
  }

  static bool _containsAny(String value, Iterable<String> candidates) {
    for (final candidate in candidates) {
      if (value.contains(candidate)) return true;
    }
    return false;
  }
}
