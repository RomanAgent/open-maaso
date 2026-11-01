import 'package:maaso/src/core/utils/creation_intent_language.dart';
import 'package:maaso/src/core/utils/explicit_creation_question_guard.dart';

enum CreationProposalKind { game, utility, unresolved }

/// Project data from an actual Agent offer, accepted by the current human turn.
/// The caller still owns task admission, grants and cancellation boundaries.
final class ConfirmedCreationBrief {
  const ConfirmedCreationBrief({
    required this.kind,
    required this.proposalText,
    required this.confirmationText,
  });

  final CreationProposalKind kind;
  final String proposalText;
  final String confirmationText;
}

/// A single adjacent-turn offer. Never reconstruct this state from chat history,
/// model handoff metadata, recalled memory or caller-augmented user text.
final class CreationProposalSession {
  CreationProposalSession({
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now {
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl', 'must be positive');
    }
  }

  final Duration ttl;
  final DateTime Function() _now;
  _PendingCreationProposal? _pending;

  /// Call only for an actual, successfully delivered ordinary Agent reply.
  /// A newer reply replaces the offer even when it contains no creation offer.
  bool observeAssistantReply(String text, {required String scopeKey}) {
    clear();
    final scope = scopeKey.trim();
    final original = text.trim();
    if (scope.isEmpty || original.isEmpty || _deniesCreation(original)) {
      return false;
    }
    final unquoted = original.replaceAll(_quoted, ' ');
    final offer = _firstPersonOffer.firstMatch(unquoted.toLowerCase());
    if (offer == null) return false;
    final prefix = unquoted.substring(0, offer.start).toLowerCase();
    final reportPrefix = prefix.replaceAll(_politeOfferCondition, ' ');
    final offered = unquoted.substring(offer.start).toLowerCase();
    final object = unquoted
        .substring(offer.end)
        .toLowerCase()
        .split(_clauseBoundary)
        .first
        .trim();
    if (object.isEmpty ||
        _nonInteractiveOutput.hasMatch(object) ||
        _metaDiscussion.hasMatch(prefix) ||
        _reportedOfferPrefix.hasMatch(reportPrefix)) {
      return false;
    }

    // Product types, rather than fixed game names. A game-score utility is
    // still a tool; mixed product words and unnamed outputs await the model.
    final CreationProposalKind kind;
    if (_utilityProduct.hasMatch(object) && _gameProduct.hasMatch(object)) {
      kind = CreationProposalKind.unresolved;
    } else if (_utilityProduct.hasMatch(object)) {
      kind = CreationProposalKind.utility;
    } else if (_gameProduct.hasMatch(unquoted.toLowerCase())) {
      kind = CreationProposalKind.game;
    } else if (_utilityProduct.hasMatch(offered)) {
      kind = CreationProposalKind.utility;
    } else {
      // A user-invented or unnamed output is project data awaiting semantic
      // classification after the human's explicit confirmation. This host
      // hint never requires the Agent to name a known product or game.
      kind = CreationProposalKind.unresolved;
    }
    _pending = _PendingCreationProposal(
      kind: kind,
      text: original,
      scopeKey: scope,
      expiresAt: _now().toUtc().add(ttl),
    );
    return true;
  }

  /// Call on every next human turn, before routing. Any turn consumes adjacency;
  /// only an explicit creation confirmation returns a brief. Bare approval,
  /// continuation, quoted commands, discussion and denied operations never
  /// authorize it. Quoted names/features after the outer command remain data.
  ConfirmedCreationBrief? takeConfirmation(
    String text, {
    required String scopeKey,
  }) {
    final pending = _pending;
    clear();
    final original = text.trim();
    final unquoted = original.replaceAll(_quoted, ' ');
    final normalized = unquoted.toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
    final leadingCommand = normalized.replaceFirst(_confirmationPreamble, '');
    final boundary = _clauseBoundary.firstMatch(leadingCommand);
    final command =
        (boundary == null
                ? leadingCommand
                : leadingCommand.substring(0, boundary.start))
            .trim();
    final commandIsQuestion =
        boundary != null && RegExp(r'[?？]').hasMatch(boundary.group(0)!);
    if (pending == null ||
        scopeKey.trim() != pending.scopeKey ||
        !_now().toUtc().isBefore(pending.expiresAt) ||
        original.isEmpty ||
        _deniesCreation(original) ||
        _metaDiscussion.hasMatch(command) ||
        commandIsQuestion ||
        ExplicitCreationQuestionGuard.blocks(command)) {
      return null;
    }
    if (!_explicitConfirmation.hasMatch(command)) return null;
    return ConfirmedCreationBrief(
      kind: pending.kind,
      proposalText: pending.text,
      confirmationText: original,
    );
  }

  void clear() => _pending = null;

  static bool _deniesCreation(String text) =>
      CreationIntentLanguage.isNegatedCreation(text) ||
      CreationIntentLanguage.isNegatedRequiredSideEffect(text) ||
      text
          .replaceAll(_quoted, ' ')
          .toLowerCase()
          .split(_cancellationClauseBoundary)
          .any((clause) => _rejection.hasMatch(clause.trim())) ||
      _instructionsOnly.hasMatch(text.toLowerCase());

  static final _quoted = RegExp(
    r'''“[^”]*”|"[^"]*"|「[^」]*」|『[^』]*』|`[^`]*`|(?:^|\s)'[^'\n]+'(?=\s|[,.!?;:]|$)''',
  );
  static final _clauseBoundary = RegExp(r'[,，;；。.!！?？\n]+');
  static final _cancellationClauseBoundary = RegExp(
    r'[,，;；。.!！?？\n]+|(?:但是|不过|但)|\bbut\b',
  );
  static final _firstPersonOffer = RegExp(
    r'(?:那|所以|好|行)?我(?:来|可以|会|将|现在|这就|就|先|给你|帮你|为你){0,5}(?:写|做|生成|创建|制作|开发|设计)(?:一个|个|一款|款)?|'
    r"\bi(?:['’]ll|\s+will|\s+can|\s+could|\s+am\s+going\s+to|\s+can\s+help\s+you)?\s+(?:make|build|create|write|develop|design|generate)\b",
  );
  static final _utilityProduct = RegExp(
    r'小程序|工具|应用|网页|页面|计算器|记录器|管理器|统计器|跟踪器|编辑器|'
    r'\b(?:mini[- ]?app|applet|app|application|tool|web\s?pages?|pages?|calculator|tracker|manager|editor|dashboard)\b',
  );
  static final _gameProduct = RegExp(
    r'小游戏|游戏|互动作品|可玩的作品|可玩作品|'
    r'\b(?:game|mini[- ]?game|playable\s+(?:experience|program)|interactive\s+(?:experience|game))\b',
  );
  static final _nonInteractiveOutput = RegExp(
    r'(?:故事|文章|教程|说明|介绍|评测|文案|方案|计划|攻略|指南|文档|报告|伪代码|代码示例|示例代码|图片|插画|视频|诗歌)(?:吧|呀|啊|出来|给你看)?$|'
    r'^(?:一篇|一份|一段|一张|一幅)?(?:文章|教程|攻略|报告|指南|文档|方案|计划|故事|文案|封面)(?:关于|介绍|讲述|分析|来|给|供|用于|以)|'
    r'^(?:(?:an?|the)\s+)?(?:(?!(?:with|including|containing|featuring|that|where|which|and|using)\b)[a-z-]+\s+){0,4}'
    r'(?:story|article|tutorial|instructions|review|plan|guide|documentation|report|pseudocode|code\s+example|picture|video|poem)\b',
  );
  static final _metaDiscussion = RegExp(
    r'翻译|这句话|这句台词|这段话|引用|例如这样说|只是举例|只(?:是|想)?(?:讨论|了解|解释)|'
    r'\b(?:translate|translation|quoted?|wording|phrase|sentence|only\s+(?:discuss|explain|learn))\b',
  );
  static final _reportedOfferPrefix = RegExp(
    r'(?:他|她|它|对方|别人|有人|角色|人物|主人公|剧本|小说|台词)(?:刚才|昨天|曾经|之前)?(?:说|表示|声称|提到|承诺)|'
    r'(?:假设|假如|如果|比如说|举例|例如|示例|比方说|设想)|'
    r'\b(?:said|says|told|saying|mentioned|quote|hypothetical|suppose|imagine|assuming)\b|'
    r'\bfor\s+(?:example|instance)\b',
  );
  static final _politeOfferCondition = RegExp(
    r'(?:如果|假如)你(?:愿意|喜欢|想要|需要)(?:的话)?',
  );
  static final _instructionsOnly = RegExp(
    r'只(?:要|想|需|需要)?(?:讲|说|解释|讨论|说明|给.*(?:方案|教程|代码示例))|先(?:讲|解释|讨论)(?:一下)?(?:思路|方案|原理)|'
    r'\b(?:only|just)\s+(?:explain|discuss|describe|give\s+(?:me\s+)?(?:a\s+)?(?:plan|tutorial|example))\b',
  );
  static final _rejection = RegExp(
    r'^(?:(?:请|麻烦|现在|先|那|还是|暂时|就)\s*)*'
    r'(?:(?:算了|不做了|不要了|不用了|别开始|先别开始|暂不开始)(?:吧|了)?|'
    r'(?:取消|暂停|停止|停下)(?:(?:这次|当前|这个|该)?(?:制作|生成|任务|开发|编写|执行))?(?:吧|了)?)$|'
    r"^(?:please\s+)?(?:(?:cancel|pause|stop)(?:\s+(?:this|the|current))?(?:\s+(?:generation|creation|task|build|work))?|never\s?mind|not\s+now|(?:do\s+not|don['’]t)\s+(?:start|continue|proceed))(?:\s+please)?$",
  );
  static final _confirmationPreamble = RegExp(
    r'^(?:(?:嗯|好|好的|行|可以|yes|ok|okay|sure)[\s，,]+)+',
  );
  static final _explicitConfirmation = RegExp(
    r'^(?:(?:嗯|好|好的|行|可以|那|就)[\s，,]*){0,3}'
    r'(?:(?:按|照|按照)(?:你(?:的|刚才的|说的|建议的|提的)|刚才(?:的|那个)|这个)(?:方案|建议|想法|来|说的)?(?:来)?(?:做|写|生成|创建|制作|开发)(?:吧|出来|即可|就行)?|'
    r'(?:做|写|生成|创建|制作|开发)(?:你(?:说的|提的|建议的|选的)|刚才(?:说的|那个))(?:那个|这个|的)?(?:吧|出来|即可|就行)?)$|'
    r'^(?:(?:yes|ok|okay|sure)[, ]*)?(?:please\s+)?(?:make|build|create|write|develop|generate)\s+(?:the\s+)?(?:one|game|app|tool)\s+(?:you\s+(?:suggested|proposed|recommended|chose)|we\s+discussed)$|'
    r'^(?:(?:yes|ok|okay|sure)[, ]*)?(?:please\s+)?(?:make|build|create|write|develop|generate)\s+(?:it|that|the\s+one)\s+(?:your\s+way|as\s+you\s+(?:suggested|proposed))$',
  );
}

final class _PendingCreationProposal {
  const _PendingCreationProposal({
    required this.kind,
    required this.text,
    required this.scopeKey,
    required this.expiresAt,
  });

  final CreationProposalKind kind;
  final String text;
  final String scopeKey;
  final DateTime expiresAt;
}
