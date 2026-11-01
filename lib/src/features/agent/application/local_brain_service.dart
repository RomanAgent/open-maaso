import 'dart:math' as math;

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';

import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';

/// Coarse intent label produced by the local brain on every turn.
///
/// Used by [BrainRouter] to decide whether the cloud LLM is needed and what
/// hint to inject when it is.  Intentionally small — five buckets is enough
/// for routing; finer-grained classification belongs to the cloud brain.
enum LocalIntent {
  chitchat, // greetings, small talk, social warmth
  task, // user wants the agent to do something concrete
  knowledge, // information question
  emergency, // urgent / safety
  unknown, // local brain not confident enough to label
}

/// Ultra-small cloud-mode route label.  This is intentionally much smaller
/// than [RoutingDecision]: it answers only "how hard/risky is this turn?"
/// so an on-device model can emit a label instead of a full JSON object.
enum RouteComplexity { simple, medium, complex, unsafe, unknown }

/// Output of one local-brain routing pass.  This is now intentionally
/// heuristic-only: the route must be cheap enough to sit on the hot path.
class RoutingDecision {
  final LocalIntent intent;
  final double confidence;

  /// Semantic emotion label to fire **immediately** (before cloud responds)
  /// so the avatar reacts within ~50ms.  Always populated; "neutral" when
  /// the local brain has nothing better.
  final String emotionPreemit;

  /// Intensity for [emotionPreemit].  0..1.
  final double emotionIntensity;

  /// Whether we still want the cloud brain to handle the substantive reply.
  /// For P2 with a heuristic backend this is always true — chitchat
  /// short-circuit requires an on-device LLM that can speak in-character.
  final bool escalate;

  /// Tools the local brain *guesses* might be needed.  Cloud brain uses this
  /// only as a soft hint — it's free to ignore.
  final List<String> needsTools;

  /// P2.5 chitchat short-circuit: when [escalate] is false the cloud LLM is
  /// skipped entirely and this string is shown to the user as the reply.
  /// Only filled by an LLM backend that can speak in-character — heuristic
  /// always leaves this null.
  final String? draftReply;

  /// Phase 3 fast-router label.  Cloud mode treats this as a soft complexity
  /// hint only; it must never block the main cloud request.
  final RouteComplexity complexity;

  /// Tiny one-line note threaded into the user message so the cloud brain
  /// knows the preemit already fired and skips its own gut-reaction
  /// setEmotion.  Saves a token, avoids the visible "double-flash".
  String get hintLine =>
      '[local-brain: complexity=${complexity.name}, intent=${intent.name}, '
      'preemit=$emotionPreemit'
      '${needsTools.isEmpty ? "" : ", may_need=${needsTools.join(",")}"}]';

  const RoutingDecision({
    required this.intent,
    required this.confidence,
    required this.emotionPreemit,
    this.emotionIntensity = 0.6,
    this.escalate = true,
    this.needsTools = const [],
    this.draftReply,
    this.complexity = RouteComplexity.unknown,
  });

  RoutingDecision copyWith({
    LocalIntent? intent,
    double? confidence,
    String? emotionPreemit,
    double? emotionIntensity,
    bool? escalate,
    List<String>? needsTools,
    String? draftReply,
    RouteComplexity? complexity,
  }) {
    return RoutingDecision(
      intent: intent ?? this.intent,
      confidence: confidence ?? this.confidence,
      emotionPreemit: emotionPreemit ?? this.emotionPreemit,
      emotionIntensity: emotionIntensity ?? this.emotionIntensity,
      escalate: escalate ?? this.escalate,
      needsTools: needsTools ?? this.needsTools,
      draftReply: draftReply ?? this.draftReply,
      complexity: complexity ?? this.complexity,
    );
  }
}

/// Transient local filler emitted while the cloud answer is still racing.
///
/// This is not a chat answer. It must not enter memory or formal history.
class LocalFillerDraft {
  const LocalFillerDraft({required this.emotion, required this.text});

  final String emotion;
  final String text;

  bool get isEmpty => text.trim().isEmpty;
}

enum LocalPromptMode {
  /// No cloud model is configured/usable, so the on-device model is the
  /// primary answer brain.
  offlineAnswer,

  /// Cloud is already producing the final answer; local model only improves
  /// responsiveness with reflex/filler output.
  cloudParallel,
}

/// The small, plain-text personalization the on-device chat prompt needs.
///
/// Deliberately NOT the cloud brain's rich context (L0/L1/L2 memory, reflex
/// hint lines, semantic L3 block) — the local model gets its own, much smaller
/// prompt: lightweight identity/profile data plus the host's conversation
/// constraints. See [LlamadartLLMBackend._buildChatSystemPrompt].
class LocalMemoryContext {
  const LocalMemoryContext({
    this.agentName,
    this.userName,
    this.importantSummary = '',
    this.routingHint,
    this.conversationStyle,
  });

  /// The agent's display name (soul/profile nickname) so the on-device prompt
  /// can say `You are <name>` instead of a generic placeholder.
  final String? agentName;

  /// The user's name (master profile), if known — `You're talking to <name>`.
  final String? userName;

  /// Optional short LLM-condensed summary of the user profile + how they've
  /// tuned the agent.  Plain text, a few hundred chars at most.  Empty when no
  /// summary has been generated yet — then it's simply omitted from the prompt.
  final String importantSummary;

  /// Lightweight routing signal used to pick a context-appropriate few-shot
  /// example in the system prompt (e.g. comfort tone vs. "let me think").
  final LocalRoutingHint? routingHint;

  /// Trusted turn-scoped expression constraints, kept separate from untrusted
  /// profile text and its summary truncation budget.
  final ConversationStyleSnapshot? conversationStyle;

  bool get isEmpty =>
      (agentName?.trim().isEmpty ?? true) &&
      (userName?.trim().isEmpty ?? true) &&
      importantSummary.trim().isEmpty &&
      conversationStyle == null;
}

/// Minimal routing snapshot threaded into the local prompt builder.  Mirrors
/// the parts of [RoutingDecision] the few-shot selector cares about.
class LocalRoutingHint {
  const LocalRoutingHint({required this.intent, required this.complexity});

  final LocalIntent intent;
  final RouteComplexity complexity;

  factory LocalRoutingHint.from(RoutingDecision d) =>
      LocalRoutingHint(intent: d.intent, complexity: d.complexity);
}

sealed class LocalChatEvent {
  const LocalChatEvent();
}

class LocalChatDelta extends LocalChatEvent {
  const LocalChatDelta(this.text);
  final String text;
}

class LocalChatDone extends LocalChatEvent {
  const LocalChatDone(this.fullText);
  final String fullText;
}

/// On-device LLM backend.  It is deliberately not on the routing hot path.
abstract class LocalLLMBackend {
  /// Free-form chat reply.  Used as the **answer brain fallback** when no
  /// cloud LLM key is configured — implementations should be willing to
  /// answer questions beyond chitchat, and when a question is beyond their
  /// ability they must still respond gracefully (acknowledge the limit and
  /// suggest the user configure a cloud key) rather than returning null.
  ///
  /// Returns null only when the engine itself failed (not ready, threw,
  /// etc.) — never as a way of saying "I don't know".
  ///
  /// [history] is the most-recent-last list of past messages in the
  /// session.  Implementations may truncate aggressively if the context
  /// window is tight.
  Future<String?> chat(
    String userText,
    List<({String role, String content})> history, {
    AppLocale? locale,
  });

  /// Streaming variant of [chat]. Implementations should yield deltas as soon
  /// as the local model emits them, then one final [LocalChatDone].
  Stream<LocalChatEvent> chatStream(
    String userText,
    List<({String role, String content})> history, {
    required LocalPromptMode mode,
    LocalMemoryContext? memory,
    AppLocale? locale,
  });

  /// One compact JSON action for [LocalAgentRuntime]. This is intentionally
  /// separate from free-form chat so the local model can use a tiny protocol
  /// prompt and a JSON grammar without affecting normal local fallback replies.
  Future<String?> agentAction(List<({String role, String content})> messages);

  /// Transient filler for cloud-mode parallel execution. Returns JSON-derived
  /// body language + a very short thinking utterance. Must not write memory.
  Future<LocalFillerDraft?> filler(
    String userText, {
    required RoutingDecision routing,
    bool Function()? shouldCancel,
    AppLocale? locale,
  });

  /// Best-effort cancellation for transient filler generation.
  void cancelTransient();

  /// Cheap check used at startup AND at every call site, since the model
  /// may stop being available (e.g. file deleted, OOM).
  bool get isReady;
}

/// Pluggable route producer. This stays heuristic-only; the local LLM must
/// never sit on the routing hot path.
abstract class LocalBrainBackend {
  /// Stay-under-100ms budget — the whole point of the local brain is that
  /// the avatar reacts before the cloud has even returned its first token.
  Future<RoutingDecision> route(String userText);

  bool get isReady;
}

/// Per-agent runtime entry point.
class LocalBrainService extends AppService {
  final HeuristicLocalBackend _heuristic = HeuristicLocalBackend();

  /// Model-free backchannel composer — the lively floor used when no on-device
  /// LLM is present (the common case).  Held here so its anti-repeat state
  /// ([_lastFillerLine]) survives across turns.
  final FillerComposer _composer = FillerComposer();
  String? _lastFillerLine;

  static const fillerTimeout = Duration(milliseconds: 1800);

  Future<LocalBrainService> init() async {
    return this;
  }

  /// Compose a heuristic (no-LLM) filler draft for the local→cloud bridge.
  /// Always returns a varied, context-matched draft and remembers the line so
  /// consecutive turns don't repeat the same phrase.
  LocalFillerDraft composeHeuristicFiller(
    String userText,
    RoutingDecision routing,
    AppLocale locale,
  ) {
    final draft = _composer.compose(
      userText,
      routing,
      locale,
      avoidLine: _lastFillerLine,
    );
    _lastFillerLine = draft.text;
    return draft;
  }

  Future<RoutingDecision> route(String userText) async {
    final sw = TurnTrace.stopwatch(
      'local_brain.route',
      details: 'chars=${userText.length}',
    );
    final r = await heuristicRoute(userText);
    TurnTrace.done(
      'local_brain.route',
      sw,
      details:
          'backend=heuristic complexity=${r.complexity.name} '
          'intent=${r.intent.name} '
          'confidence=${r.confidence.toStringAsFixed(2)}',
    );
    return r;
  }

  Future<RoutingDecision> heuristicRoute(String userText) {
    return _heuristic.route(userText);
  }

  Future<LocalFillerDraft?> filler(
    String userText, {
    required RoutingDecision routing,
    Duration timeout = fillerTimeout,
    bool Function()? shouldCancel,
    AppLocale? locale,
  }) async {
    if (!appServices.isRegistered<LocalLLMBackend>()) return null;
    final llm = appServices.find<LocalLLMBackend>();
    if (!llm.isReady) return null;
    final sw = TurnTrace.stopwatch(
      'local_brain.filler',
      details: 'chars=${userText.length} complexity=${routing.complexity.name}',
    );
    try {
      final draft = await llm
          .filler(
            userText,
            routing: routing,
            shouldCancel: shouldCancel,
            locale: locale ?? AgentPromptCatalog.currentLocale,
          )
          .timeout(timeout, onTimeout: () => null);
      TurnTrace.done(
        'local_brain.filler',
        sw,
        details:
            'emotion=${draft?.emotion ?? "none"} '
            'chars=${draft?.text.length ?? 0}',
      );
      return draft;
    } catch (e) {
      TurnTrace.event('local_brain.filler.error', details: 'error=$e');
      Log.w('🧠 [LocalBrain] filler threw: $e');
      return null;
    }
  }

  void cancelFiller() {
    if (appServices.isRegistered<LocalLLMBackend>()) {
      appServices.find<LocalLLMBackend>().cancelTransient();
    }
  }

  /// Local answer-brain fallback used when no cloud key is configured.
  /// Returns null when no on-device LLM is available — caller is then
  /// expected to surface a configure-your-key hint to the user.
  Future<String?> chat(
    String userText,
    List<({String role, String content})> history, {
    AppLocale? locale,
  }) async {
    if (TurnTrace.current == null) {
      return TurnTrace.run(
        'local_brain.chat',
        () => chat(userText, history, locale: locale),
      );
    }
    final sw = TurnTrace.stopwatch(
      'local_brain.chat',
      details: 'chars=${userText.length} history=${history.length}',
    );
    if (!appServices.isRegistered<LocalLLMBackend>()) {
      TurnTrace.done('local_brain.chat', sw, details: 'skip=not_registered');
      return null;
    }
    final llm = appServices.find<LocalLLMBackend>();
    if (!llm.isReady) {
      TurnTrace.done('local_brain.chat', sw, details: 'skip=not_ready');
      return null;
    }
    try {
      final reply = await llm
          .chat(
            userText,
            history,
            locale: locale ?? AgentPromptCatalog.currentLocale,
          )
          .timeout(const Duration(seconds: 12), onTimeout: () => null);
      TurnTrace.done(
        'local_brain.chat',
        sw,
        details: 'reply_chars=${reply?.length ?? 0}',
      );
      return reply;
    } catch (e) {
      TurnTrace.event('local_brain.chat.error', details: 'error=$e');
      Log.w('🧠 [LocalBrain] LLM chat threw: $e');
      return null;
    }
  }

  Stream<LocalChatEvent> chatStream(
    String userText,
    List<({String role, String content})> history, {
    required LocalPromptMode mode,
    LocalMemoryContext? memory,
    AppLocale? locale,
  }) async* {
    if (!appServices.isRegistered<LocalLLMBackend>()) {
      TurnTrace.event(
        'local_brain.chat_stream.skip',
        details: 'not_registered',
      );
      return;
    }
    final llm = appServices.find<LocalLLMBackend>();
    if (!llm.isReady) {
      TurnTrace.event('local_brain.chat_stream.skip', details: 'not_ready');
      return;
    }
    yield* llm.chatStream(
      userText,
      history,
      mode: mode,
      memory: memory,
      locale: locale ?? AgentPromptCatalog.currentLocale,
    );
  }

  Future<String?> agentAction(
    List<({String role, String content})> messages, {
    Duration timeout = const Duration(seconds: 8),
  }) async {
    if (!appServices.isRegistered<LocalLLMBackend>()) {
      TurnTrace.event(
        'local_brain.agent_action.skip',
        details: 'not_registered',
      );
      return null;
    }
    final llm = appServices.find<LocalLLMBackend>();
    if (!llm.isReady) {
      TurnTrace.event('local_brain.agent_action.skip', details: 'not_ready');
      return null;
    }
    try {
      return await llm
          .agentAction(messages)
          .timeout(timeout, onTimeout: () => null);
    } catch (e) {
      TurnTrace.event('local_brain.agent_action.error', details: 'error=$e');
      Log.w('🧠 [LocalBrain] agent action threw: $e');
      return null;
    }
  }
}

// ──────────────────────────── Heuristic backend ────────────────────────────

/// Pure-Dart fallback while an on-device LLM is not yet available.
///
/// Strategy: don't try to draft replies (no model means anything we'd output
/// would be off-brand) — just **classify intent + pick an emotion preemit**
/// using a small bank of bilingual keyword patterns.  That alone makes the
/// avatar feel ~1–3s more responsive because the face changes before the
/// cloud LLM has produced its first byte.
class HeuristicLocalBackend implements LocalBrainBackend {
  @override
  bool get isReady => true;

  @override
  Future<RoutingDecision> route(String userText) async {
    final raw = userText.trim();
    final lower = raw.toLowerCase();

    // Emergency cues — explicit safety / panic / urgency markers.
    if (_anyContains(lower, _emergencyCues)) {
      return const RoutingDecision(
        intent: LocalIntent.emergency,
        confidence: 0.9,
        emotionPreemit: 'thinking',
        emotionIntensity: 0.8,
        complexity: RouteComplexity.unsafe,
      );
    }

    // Tool hint extraction first — these implicitly imply task intent.
    final toolGuess = _guessTools(lower);

    // Question / task heuristic.  We no longer flash a cold "thinking" for
    // every hard turn — _preemitForHardTurn reads the venting / surprise /
    // excitement signal so the bridge face matches what the user said.
    final looksQuestion = _isQuestion(raw);
    if (toolGuess.isNotEmpty ||
        looksQuestion ||
        _anyContains(lower, _taskCues)) {
      final preemit = _preemitForHardTurn(lower);
      return RoutingDecision(
        intent: toolGuess.isNotEmpty ? LocalIntent.task : LocalIntent.knowledge,
        confidence: 0.8,
        emotionPreemit: preemit.$1,
        emotionIntensity: preemit.$2,
        needsTools: toolGuess,
        complexity: _estimateComplexity(raw, lower, toolGuess),
      );
    }

    // Emotional / social cues — pick the matching preemit so the avatar
    // mirrors back what the user just said.
    final emotional = _pickEmotionFromText(lower);
    if (emotional != null) {
      return RoutingDecision(
        intent: LocalIntent.chitchat,
        confidence: 0.7,
        emotionPreemit: emotional.$1,
        emotionIntensity: emotional.$2,
        complexity: RouteComplexity.simple,
      );
    }

    // Greeting cues — chitchat with a gentle happy preemit.
    if (_anyContains(lower, _greetingCues)) {
      return const RoutingDecision(
        intent: LocalIntent.chitchat,
        confidence: 0.75,
        emotionPreemit: 'happy',
        emotionIntensity: 0.55,
        complexity: RouteComplexity.simple,
      );
    }

    // Default — unsure, stay neutral so cloud sets the real tone.
    return const RoutingDecision(
      intent: LocalIntent.unknown,
      confidence: 0.3,
      emotionPreemit: 'neutral',
      emotionIntensity: 0.4,
      complexity: RouteComplexity.unknown,
    );
  }

  RouteComplexity _estimateComplexity(
    String raw,
    String lower,
    List<String> toolGuess,
  ) {
    if (_anyContains(lower, _complexCues)) return RouteComplexity.complex;
    if (toolGuess.isNotEmpty) return RouteComplexity.medium;
    if (raw.length > 120) return RouteComplexity.complex;
    if (raw.length > 40) return RouteComplexity.medium;
    return RouteComplexity.medium;
  }

  /// Pre-emit emotion for a "hard" (question / task / tool) turn.  Reads the
  /// venting / surprise / excitement signal so the bridge isn't a monotonous
  /// "thinking" every time; falls back to engaged "thinking".
  (String, double) _preemitForHardTurn(String lower) {
    if (_anyContains(lower, _supportCues)) return ('calm', 0.5);
    if (_anyContains(lower, _surpriseCues)) return ('surprised', 0.6);
    return ('thinking', 0.6);
  }

  /// Picks an emotion + intensity from explicit cue words.  Returns null
  /// when nothing matches so the caller can fall through to other rules.
  (String, double)? _pickEmotionFromText(String lower) {
    for (final cue in _emotionCues) {
      if (_anyContains(lower, cue.triggers)) return (cue.label, cue.intensity);
    }
    return null;
  }

  List<String> _guessTools(String lower) {
    final out = <String>[];
    for (final entry in _toolCues.entries) {
      if (_anyContains(lower, entry.value)) out.add(entry.key);
    }
    return out;
  }

  bool _isQuestion(String raw) {
    if (raw.endsWith('?') || raw.endsWith('？')) return true;
    final lower = raw.toLowerCase();
    return _anyContains(lower, _questionWords);
  }

  static bool _anyContains(String haystack, List<String> needles) {
    for (final n in needles) {
      if (haystack.contains(n)) return true;
    }
    return false;
  }

  // ─── Cue banks (bilingual: en + zh) ───
  // Chinese coverage matters: without it, zh users fall through to the
  // "unknown/neutral" branch and lose the avatar's <50ms emotion preemit
  // entirely — the very reason the local brain exists.

  static const _emergencyCues = [
    'sos',
    'emergency',
    'help me',
    'urgent',
    '紧急',
    '救命',
    '快帮我',
    '危险',
  ];

  // Personal / venting markers — even inside a question ("好累，该怎么办"),
  // these mean the user wants warmth first, so the bridge goes "calm".
  static const _supportCues = [
    'tired',
    'exhausted',
    'stressed',
    'anxious',
    'overwhelmed',
    'depressed',
    'burned out',
    'burnt out',
    'lonely',
    "i can't",
    'what should i do',
    '累',
    '好累',
    '难受',
    '难过',
    '焦虑',
    '压力',
    '撑不住',
    '撑不下去',
    '崩溃',
    '想哭',
    '委屈',
    'emo',
    '怎么办',
    '该怎么',
  ];

  // Big-news / disbelief markers → a surprised micro-expression on the bridge.
  static const _surpriseCues = [
    'wow',
    'omg',
    'really?',
    'no way',
    'guess what',
    '哇',
    '居然',
    '竟然',
    '真的吗',
    '不会吧',
    '天哪',
    '中奖',
    '太好了',
  ];

  static const _greetingCues = [
    'hi',
    'hello',
    'hey',
    'good morning',
    'good evening',
    'yo',
    '你好',
    '您好',
    '在吗',
    '早安',
    '早上好',
    '晚上好',
    '晚安',
    '嗨',
    '哈喽',
  ];

  static const _taskCues = [
    'remind',
    'schedule',
    'plan',
    'add a',
    'help me',
    'do me',
    '提醒',
    '安排',
    '计划',
    '帮我',
    '帮忙',
    '搞定',
    '处理',
    '完成',
  ];

  static const _complexCues = [
    'code',
    'algorithm',
    'debug',
    'refactor',
    'math',
    'proof',
    'research',
    'latest',
    'news',
    'compare',
    'implement',
    'build',
    '排序算法',
    '算法',
    '代码',
    '调试',
    '重构',
    '数学',
    '证明',
    '研究',
    '最新',
    '新闻',
    '对比',
    '实现',
    '开发',
  ];

  static const _questionWords = [
    'how',
    'what',
    'where',
    'who',
    'why',
    'when',
    'which',
    'can you',
    'do you',
    'is it',
    '什么',
    '怎么',
    '为什么',
    '哪',
    '谁',
    '何时',
    '多少',
    '吗',
    '呢',
    '可以',
    '能不能',
    '是不是',
  ];

  static const List<_EmotionCue> _emotionCues = [
    _EmotionCue('sleeping', 0.6, [
      'good night',
      'sleepy',
      'going to bed',
      '晚安',
      '困了',
      '想睡',
      '睡觉',
    ]),
    _EmotionCue('love', 0.7, [
      'love you',
      'miss u',
      '爱你',
      '想你',
      '喜欢你',
      '抱抱',
      '么么哒',
    ]),
    _EmotionCue('sad', 0.7, ['sad', 'cry', '难过', '伤心', '哭', '不开心', '委屈', '失落']),
    _EmotionCue('angry', 0.65, [
      'angry',
      'mad',
      'annoying',
      '生气',
      '气死',
      '烦死',
      '讨厌',
      '可恶',
    ]),
    _EmotionCue('surprised', 0.6, [
      'wow',
      'really?',
      'omg',
      '哇',
      '真的吗',
      '不会吧',
      '天哪',
      '居然',
    ]),
    _EmotionCue('happy', 0.75, [
      'lol',
      'haha',
      'yay',
      '哈哈',
      '嘿嘿',
      '开心',
      '高兴',
      '太好了',
      '棒',
      '赞',
    ]),
    _EmotionCue('shy', 0.5, ['shy', 'embarrassed', '害羞', '不好意思', '尴尬']),
  ];

  static const Map<String, List<String>> _toolCues = {
    'web_search': [
      'search',
      'google',
      'look up',
      'news',
      '搜索',
      '搜一下',
      '查一下',
      '查查',
      '新闻',
    ],
    'todo': ['todo', 'task list', 'add task', '待办', '任务', '清单'],
    'meme': ['meme', 'gif', '表情包', '斗图'],
    // Generated freeform surface — the agent authors rich UI for games, blogs,
    // albums, journals, dashboards, rooms, canvases, scenes, animations, etc.
    // Keep phrases specific so bare 'play'/'list' don't false-match
    // "display"/"listen".
    'freeform_surface': [
      // games / play
      'play a game', 'play game', 'mini game', 'mini-game', 'tic-tac-toe',
      'tictactoe', 'guess the number', 'guess a number', 'entertain me',
      "i'm bored", 'im bored',
      '玩游戏', '玩个游戏', '玩一局', '陪我玩', '一起玩', '小游戏', '猜数字', '猜数', '井字棋', '无聊',
      // content: blog / journal / album
      'blog',
      'article',
      'post',
      'publish',
      'journal',
      'diary',
      'album',
      'photo',
      'gallery',
      '博客', '文章', '发文', '发布', '日志', '日记', '相册', '照片', '图库', '个人主页',
      // freeform visuals / scenes
      'canvas',
      'drawing board',
      'whiteboard',
      'scene',
      '3d scene',
      'animation',
      'animated',
      'interactive visual',
      'visual object',
      '画布',
      '白板',
      '场景',
      '动画',
      '交互视觉',
      '可交互界面',
      '生成界面',
      // data panels / dashboards
      'dashboard', 'panel', 'stats', 'statistics', 'chart', 'graph',
      'list', 'comparison', 'compare', 'visualize', 'visualization',
      'present nicely', 'display nicely', 'show nicely', 'make it pretty',
      'make it beautiful', 'make this into a card', 'turn this into a card',
      'cardify',
      '面板', '看板', '统计', '图表', '可视化',
      '清单', '列表', '对比', '比较', '好看地展示', '漂亮地展示',
      '整理成卡片', '做成卡片', '转成卡片', '卡片化',
      // interactive spaces / rooms
      'quiz', 'poll', 'leaderboard', 'auction', 'chat room', 'room',
      'mini app', 'mini-program', 'widget',
      '直播间', '房间', '拍卖', '答题', '投票', '排行榜', '聊天室', '卡片', '小程序', '小组件',
    ],
  };
}

class _EmotionCue {
  final String label;
  final double intensity;
  final List<String> triggers;
  const _EmotionCue(this.label, this.intensity, this.triggers);
}

// ──────────────────────────── Filler composer ────────────────────────────

/// Backchannel category — drives both the phrase bank and the micro-emotion.
enum _FillerCategory {
  emotionalSupport,
  question,
  task,
  search,
  code,
  surprise,
  ambiguous,
}

/// Model-free, context-matched backchannel generator.
///
/// Produces the short "filler" (emotion + brief utterance) spoken on the
/// local→cloud bridge WITHOUT any on-device LLM.  This is the lively floor for
/// the ~90% of installs that never download the on-device model; the LLM
/// filler, when present, is the ceiling that overrides it.
///
/// Emotion labels are kept to the set [_BackchannelFiller] already maps
/// (thinking / calm / surprised / excited / confused) so the bridge stays
/// visually consistent.
class FillerComposer {
  final math.Random _rng = math.Random();

  LocalFillerDraft compose(
    String userText,
    RoutingDecision routing,
    AppLocale locale, {
    String? avoidLine,
  }) {
    final category = _categorize(userText.toLowerCase(), routing);
    final banks = locale == AppLocale.zh ? _zhBank : _enBank;
    final bank = banks[category] ?? banks[_FillerCategory.question]!;
    return LocalFillerDraft(
      emotion: _emotionFor(category),
      text: _pick(bank, avoidLine),
    );
  }

  /// Random pick that avoids repeating the immediately-previous line.
  String _pick(List<String> bank, String? avoid) {
    if (bank.length <= 1) return bank.first;
    final pool = avoid == null ? bank : bank.where((l) => l != avoid).toList();
    final use = pool.isEmpty ? bank : pool;
    return use[_rng.nextInt(use.length)];
  }

  _FillerCategory _categorize(String lower, RoutingDecision routing) {
    if (HeuristicLocalBackend._anyContains(
      lower,
      HeuristicLocalBackend._supportCues,
    )) {
      return _FillerCategory.emotionalSupport;
    }
    if (HeuristicLocalBackend._anyContains(
      lower,
      HeuristicLocalBackend._surpriseCues,
    )) {
      return _FillerCategory.surprise;
    }
    final tools = routing.needsTools;
    if (tools.contains('web_search')) {
      return _FillerCategory.search;
    }
    if (HeuristicLocalBackend._anyContains(
      lower,
      HeuristicLocalBackend._complexCues,
    )) {
      return _FillerCategory.code;
    }
    return switch (routing.intent) {
      LocalIntent.task => _FillerCategory.task,
      LocalIntent.knowledge => _FillerCategory.question,
      LocalIntent.emergency => _FillerCategory.emotionalSupport,
      LocalIntent.chitchat || LocalIntent.unknown => _FillerCategory.ambiguous,
    };
  }

  String _emotionFor(_FillerCategory c) => switch (c) {
    _FillerCategory.emotionalSupport => 'calm',
    _FillerCategory.surprise => 'surprised',
    _FillerCategory.task => 'thinking',
    _FillerCategory.search => 'thinking',
    _FillerCategory.code => 'thinking',
    _FillerCategory.question => 'thinking',
    _FillerCategory.ambiguous => 'confused',
  };

  // Chinese ≤ 8 chars, plain text (no emoji — TTS + persona forbid them).
  static const Map<_FillerCategory, List<String>> _zhBank = {
    _FillerCategory.emotionalSupport: ['我在听呢', '嗯，我在', '慢慢说', '我陪着你', '怎么了'],
    _FillerCategory.question: ['让我想想', '我捋一下', '唔，这个嘛', '我想想哈', '等我一下'],
    _FillerCategory.task: ['这个交给我', '我来安排', '我看看怎么弄', '马上给你弄', '收到，这就办'],
    _FillerCategory.search: ['我查一下', '我找找看', '我翻翻看', '让我查查', '稍等我找下'],
    _FillerCategory.code: ['我捋下逻辑', '让我看看', '嗯…这块', '我顺一遍', '稍等我读读'],
    _FillerCategory.surprise: ['哦？真的吗', '等下，认真的', '哇，这个', '不会吧', '让我缓缓'],
    _FillerCategory.ambiguous: ['我看看哈', '唔…想想', '等我一下', '我琢磨下', '稍等一下'],
  };

  // English ≤ 5 words, plain text.
  static const Map<_FillerCategory, List<String>> _enBank = {
    _FillerCategory.emotionalSupport: [
      "I'm here",
      "I'm listening",
      'Take your time',
      "I've got you",
      'Tell me more',
    ],
    _FillerCategory.question: [
      'Let me think',
      'Hmm, one sec',
      'Good question',
      'Let me see',
      'Thinking it over',
    ],
    _FillerCategory.task: [
      'On it',
      "I'll handle this",
      'Let me sort it',
      'Got it, one sec',
      "I'm on it",
    ],
    _FillerCategory.search: [
      'Let me look',
      'Checking now',
      'Let me dig in',
      'Looking it up',
      'One sec, searching',
    ],
    _FillerCategory.code: [
      'Reading the code',
      'Let me trace it',
      'Hmm, this part',
      'Walking through it',
      'Let me check',
    ],
    _FillerCategory.surprise: [
      'Oh? Really?',
      'Wait, really?',
      'Whoa, okay',
      'No way',
      'Let me catch up',
    ],
    _FillerCategory.ambiguous: [
      'Let me see',
      'Hmm, one sec',
      'Hold on',
      'Let me think',
      'Give me a sec',
    ],
  };
}
