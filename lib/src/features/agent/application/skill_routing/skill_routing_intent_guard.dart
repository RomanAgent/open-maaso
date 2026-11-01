import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/core/utils/explicit_creation_question_guard.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

/// Routing evidence only. The original user text still reaches the model and
/// argument/confirmation boundaries unchanged. Quoted examples and declined
/// operations cannot acquire authority through lexical or policy hints.
class SkillRoutingIntentGuard {
  const SkillRoutingIntentGuard._({
    required this.routingText,
    required this.originalText,
    required this.blockAll,
    required this.blockedSkills,
    required this.positiveSkills,
    required this.focusPositiveOperation,
    required this.hasQuotedData,
    required bool resolvedSurfaceCreation,
  }) : _resolvedSurfaceCreation = resolvedSurfaceCreation;

  final String routingText;
  final String originalText;
  final bool blockAll;
  final Set<String> blockedSkills;
  final Set<String> positiveSkills;
  final bool focusPositiveOperation;
  final bool hasQuotedData;
  final bool _resolvedSurfaceCreation;

  static SkillRoutingIntentGuard analyze(
    String text, {
    SurfaceIntent resolvedCreation = SurfaceIntent.none,
  }) {
    final resolvedSurfaceCreation =
        resolvedCreation.matchesResolvedRequest(text) &&
        SurfaceCreationAuthority.experienceTypeFor(
              text: text,
              interactiveHint: true,
              surfaceIntent: resolvedCreation,
            ) !=
            null;
    final unquoted = text.replaceAll(_quoted, ' ');
    final hasQuotedData = unquoted != text;
    final kept = <String>[];
    final blocked = <String>{};
    final positive = <String>{};
    var nonActionEvidence = false;
    var explicitOperation = false;
    for (final raw in unquoted.toLowerCase().split(_clauseBoundary)) {
      final clause = raw.trim();
      if (clause.isEmpty) continue;
      final positiveMemory = _rememberException.hasMatch(clause);
      final positiveQuiet =
          _quietException.hasMatch(clause) &&
          (!_explanation.hasMatch(clause) || _operation.hasMatch(clause));
      final informationalShape =
          _explanation.hasMatch(clause) || _verbQuestion.hasMatch(clause);
      final freshExplanation =
          informationalShape && _freshInformation.hasMatch(clause);
      final denied =
          !positiveMemory &&
          !positiveQuiet &&
          (_negation.hasMatch(clause) || _notNeeded.hasMatch(clause));
      if (denied) {
        nonActionEvidence = true;
        blocked.addAll(_domains(clause));
        continue;
      }
      final operation =
          positiveMemory ||
          positiveQuiet ||
          freshExplanation ||
          _operation.hasMatch(clause) ||
          _objectOperation.hasMatch(clause) ||
          _translationQuestion.hasMatch(clause);
      final informationalCreation =
          _creationDomain.hasMatch(clause) &&
          !_translationQuestion.hasMatch(clause) &&
          ExplicitCreationQuestionGuard.blocks(clause);
      // Translation is handled by the selected conversation model. Text to
      // translate remains data, so embedded commands cannot activate a host.
      if (_translation.hasMatch(clause) ||
          _translationQuestion.hasMatch(clause)) {
        nonActionEvidence = true;
        kept.add(clause);
        continue;
      }
      // Writing is handled by conversation after the publishing host retired.
      // An arbitrary game still needs the request-bound creation result below;
      // a generic "write" verb alone must not grant the Surface host.
      if (_writing.hasMatch(clause) &&
          !SurfaceIntent.classify(clause).isSurface) {
        nonActionEvidence = true;
        kept.add(clause);
        continue;
      }
      if (!freshExplanation &&
          ((_explanation.hasMatch(clause) && !operation) ||
              _verbQuestion.hasMatch(clause) ||
              informationalCreation)) {
        nonActionEvidence = true;
        continue;
      }
      kept.add(clause);
      if (operation) {
        explicitOperation = true;
        if (freshExplanation) nonActionEvidence = true;
        positive.addAll(
          freshExplanation
              ? const {'WebSearch'}
              : positiveMemory
              ? const {'MemoryControl', 'SetMaster'}
              : positiveQuiet
              ? const {'BehaviorConfig'}
              : _positiveOperationSkills(clause),
        );
      }
    }
    blocked.removeAll(positive);
    return SkillRoutingIntentGuard._(
      routingText: kept.join(' '),
      originalText: SkillLexicalText.normalize(unquoted),
      // A separate human creation command can coexist with a question or
      // discussion clause. Its validated, request-bound type owns the Surface
      // route; lexical abstention must not erase that task afterward. The
      // resolved-creation host restriction below still excludes other tools.
      blockAll:
          nonActionEvidence && !explicitOperation && !resolvedSurfaceCreation,
      blockedSkills: Set.unmodifiable(blocked),
      positiveSkills: Set.unmodifiable(positive),
      focusPositiveOperation:
          (hasQuotedData || nonActionEvidence) && positive.isNotEmpty,
      hasQuotedData: hasQuotedData,
      resolvedSurfaceCreation: resolvedSurfaceCreation,
    );
  }

  bool allows(SkillDescriptor descriptor) {
    if (blockedSkills.contains(descriptor.id)) return false;
    // The human's outer creation command owns authority. Its request-bound
    // semantic type may identify an arbitrary game or app without a product
    // keyword, including quoted project requirements. Those requirements
    // never grant other hosts or bypass a declined/discussed operation.
    if (descriptor.id == 'FreeformSurface' && _resolvedSurfaceCreation) {
      return true;
    }
    if (blockAll) return false;
    // A typed creation result grants only its Surface host. Product help text
    // and preferred-skill hints cannot authorize unrelated host operations.
    if (_resolvedSurfaceCreation &&
        _hostSkills.contains(descriptor.id) &&
        !positiveSkills.contains(descriptor.id)) {
      return false;
    }
    if (focusPositiveOperation &&
        _hostSkills.contains(descriptor.id) &&
        !positiveSkills.contains(descriptor.id)) {
      return false;
    }
    // A policy may have inspected the full user text. Require independent
    // evidence outside quotes before that policy can restore a quoted tool.
    if (hasQuotedData &&
        !positiveSkills.contains(descriptor.id) &&
        ![...descriptor.terms, ...descriptor.positiveExamples].any(
          (phrase) => SkillLexicalText.containsPhrase(routingText, phrase),
        )) {
      return false;
    }
    if (!positiveSkills.contains(descriptor.id) &&
        [...descriptor.negativeTerms, ...descriptor.negativeExamples].any(
          (phrase) => SkillLexicalText.containsPhrase(originalText, phrase),
        )) {
      return false;
    }
    return true;
  }

  static Set<String> _positiveOperationSkills(String clause) {
    if (_webAction.hasMatch(clause)) {
      return _applets.hasMatch(clause) ? {'AppletDiscovery'} : {'WebSearch'};
    }
    if (_navigationAction.hasMatch(clause)) {
      return {'AppControl', 'AppNavigate'};
    }
    if (_disconnect.hasMatch(clause)) return {'Bluetooth'};
    return _domains(clause);
  }

  static Set<String> _domains(String clause) => {
    for (final entry in _domainPatterns.entries)
      if (entry.key.hasMatch(clause)) ...entry.value,
  };

  static final _quoted = RegExp(
    r'''“[^”]*”|"[^"]*"|「[^」]*」|『[^』]*』|`[^`]*`|(?:^|\s)'[^'\n]+'(?=\s|[,.!?;:]|$)''',
  );
  static final _clauseBoundary = RegExp(
    r'[,;.!?，；。！？\n]+|\b(?:but|instead|then)\b|(?:而是|然后|改为|但是|但)',
  );
  static final _negation = RegExp(
    r'''^(?:(?:先|暂时|现在|请|麻烦)\s*)*(?:不要|不用|别|不必|不需要|无需)|^(?:please\s+)?(?:(?:i|we)\s+)?(?:do not|don['’]t|no need|not asking|am not asking|i['’]m not asking)\b''',
  );
  static final _notNeeded = RegExp(
    r'\b(?:not needed|not necessary|not required)\b',
  );
  static final _rememberException = RegExp(
    r'''^(?:(?:请|一定|千万)\s*)?(?:别忘|不要忘)|^(?:please\s+)?(?:do not|don['’]t)\s+forget\b''',
  );
  static final _quietException = RegExp(
    r'^(?:(?:请|先|现在|帮我)\s*)*(?:勿扰|进入勿扰|开启勿扰|打开勿扰|别打扰|不要打扰)|^(?:先|现在)?(?:别|不要|不用).{0,12}主动.{0,20}(?:联系|发消息)|^(?:please\s+)?(?:(?:turn on|enable|activate|enter)\s+)?do not disturb\b',
  );
  static final _operation = RegExp(
    r'^(?:(?:帮我|请你|请|麻烦|给我|替我|现在|我想|我要|我需要)\s*)*(?:打开|进入|切换|开启|关闭|设置|恢复|连接|断开|扫描|查询|搜索|查找|计算|算一下|翻译|生成|创建|制作|写|画|拍|提醒|记住|忘掉|移动|走到|导出|显示|列出|添加|加入|删除|取消)|^(?:(?:please|can you|could you|would you|help me|i want you to|i need you to)\s+)*(?:open|enter|navigate|go to|switch|turn|set|restore|resume|connect|disconnect|scan|check|search|look up|find|calculate|evaluate|translate|generate|create|build|make|write|draw|record|remind|remember|forget|move|walk|export|show|list|add|delete|cancel|stop|use)\b',
  );
  static final _objectOperation = RegExp(
    r'^(?:把|将).*(?:翻译|译成|译为|改成|发到|加入|计算|保存|忘掉)',
  );
  static final _translationQuestion = RegExp(r'怎么说|\bhow do i say\b');
  static final _explanation = RegExp(
    r'什么是|是什么意思|含义|原理|定义|有什么区别|历史来源|词源|这个词|这句话|这句.*自然|(?:人物|角色)说|我在写小说|(?:剧本|台词).*(?:这句|听起来|像)|只(?:是|想)?(?:了解|讨论|解释)|\b(?:explain|difference|definition|wording|meaning|means?|phrase|sentence)\b|\b(?:character says|in my novel|sound natural|sounds? like|only learning)\b',
  );
  static final _verbQuestion = RegExp(
    r'^(?:写|生成|创建|制作|录制|拍摄|连接|设置|计算|搜索|打开).*(?:什么|哪些|多久|多长|怎么|如何|是否|吗|呢)[^，,;；]*$',
  );
  static final _creationDomain = RegExp(
    r'写|做|生成|创建|制作|开发|设计|\b(?:write|make|create|generate|build|design|develop|article|blog)\b',
  );
  static final _freshInformation = RegExp(
    r'最新|实时|刚(?:公布|发布)|\b(?:latest|breaking|current|real time)\b',
  );
  static final _translation = RegExp(
    r'^(?:(?:请|帮我|给我|麻烦|现在)\s*)*(?:翻译|译成|译为|(?:把|将).*(?:翻译|译成|译为))|^(?:(?:please|can you|could you|would you|help me|i want you to|i need you to)\s+)*(?:translate\b|translation of\b)',
  );
  static final _webAction = RegExp(r'联网|上网|搜索|查找|\b(?:search|look up|find)\b');
  static final _applets = RegExp(r'小程序|小游戏|现成|\b(?:applet|game)\b');
  static final _navigationAction = RegExp(
    r'^(?:(?:帮我|请|现在)\s*)*(?:打开|进入|前往)|^(?:(?:please|can you|help me)\s+)*(?:open|enter|go to|navigate)\b',
  );
  static final _disconnect = RegExp(r'断开|\bdisconnect\b');
  static final _writing = RegExp(
    r'^(?:(?:帮我|请你|请|麻烦|给我|替我|现在|我想|我要|我需要)\s*)*(?:写|撰写|起草|草拟)|'
    r'^(?:(?:please|can you|could you|would you|will you|help me|i want you to|i need you to)\s+)*(?:write|draft)\b',
  );

  static final Map<RegExp, Set<String>> _domainPatterns = {
    RegExp(r'设置|\bsettings\b'): {'AppControl', 'AppNavigate', 'BehaviorConfig'},
    RegExp(r'蓝牙|投影|\b(?:bluetooth|projector)\b'): {
      'Bluetooth',
      'BleYoturetoys',
    },
    RegExp(r'天气|预报|气温|\b(?:weather|forecast|temperature)\b'): {'WebSearch'},
    RegExp(r'提醒|闹钟|定时|\b(?:reminder|remind|alarm|schedule)\b'): {
      'ScheduledTask',
    },
    RegExp(r'记住|记忆|保存|忘掉|\b(?:memory|remember|forget|store|save)\b'): {
      'MemoryControl',
      'LogEpisode',
      'SetMaster',
    },
    RegExp(r'主动|勿扰|\b(?:proactive|disturb)\b'): {'BehaviorConfig'},
    RegExp(r'小程序|小游戏|面板|\b(?:applet|game|dashboard|surface)\b'): {
      'FreeformSurface',
    },
    RegExp(r'联网|搜索|\b(?:internet|online|search|lookup)\b'): {'WebSearch'},
    RegExp(r'页面|社区|\b(?:page|community|navigate)\b'): {
      'AppControl',
      'AppNavigate',
    },
    RegExp(r'待办|清单|\b(?:todo|checklist)\b'): {'Todo'},
  };
  static const _hostSkills = {
    'AppControl',
    'AppNavigate',
    'SetSoul',
    'SetMaster',
    'SetWorld',
    'LogEpisode',
    'LogMilestone',
    'MemoryControl',
    'FaceControl',
    'Todo',
    'BehaviorConfig',
    'DeviceHandoff',
    'AvatarCamera',
    'ShowCard',
    'FreeformSurface',
    'Http',
    'AlertUser',
    'WebSearch',
    'AppletDiscovery',
    'ScheduledTask',
    'Bluetooth',
    'BleYoturetoys',
  };
}
