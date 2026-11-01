import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/conversation_memory_service.dart';

/// Owns the living user↔agent bond: the [RelationshipState] (days known,
/// streak and legacy score) and the historical [Milestone] timeline.
/// Current expression comes only from accepted, source-valid conversation
/// policy. Timeline pagination, time apart, and legacy points do not grant it.
class RelationshipService extends AppService {
  DBService get _db => appServices.find<DBService>();

  final Rxn<RelationshipState> state = Rxn<RelationshipState>();
  final RxList<Milestone> milestones = <Milestone>[].obs;
  Worker? _conversationMemoryWorker;
  ConversationPolicy _conversationPolicy = ConversationPolicy.fromFacts(
    const [],
    policyVersion: 0,
  );

  RelationshipExpressionStage get effectiveStage =>
      _conversationPolicy.expressionStage;
  int get policyVersion => _conversationPolicy.policyVersion;

  void bindConversationMemory(ConversationMemoryService service) {
    if (isClosed) throw StateError('relationship_service_closed');
    _conversationMemoryWorker?.dispose();
    updateConversationPolicy(service.state.value);
    _conversationMemoryWorker = service.state.listen(updateConversationPolicy);
  }

  /// Called only with the account-scoped memory service's validated projection.
  void updateConversationPolicy(ConversationPolicy policy) {
    if (isClosed) return;
    _conversationPolicy = policy;
    final current = state.value;
    if (current == null) return;
    current.expressionStage = policy.expressionStage;
    current.policyVersion = policy.policyVersion;
    state.refresh();
  }

  @override
  void onClose() {
    _conversationMemoryWorker?.dispose();
    _conversationMemoryWorker = null;
    _conversationPolicy = ConversationPolicy.fromFacts(
      const [],
      policyVersion: 0,
    );
    state.value = null;
    milestones.clear();
    super.onClose();
  }

  // ── stage thresholds (internal score → stage) ──
  static const _scoreBands = <(double, RelationshipStage)>[
    (180, RelationshipStage.attuned),
    (90, RelationshipStage.trusted),
    (40, RelationshipStage.friend),
    (15, RelationshipStage.acquaintance),
    (0, RelationshipStage.stranger),
  ];
  // Day gates — can't reach a stage faster than real time allows.
  static const _minDaysForStage = <RelationshipStage, int>{
    RelationshipStage.attuned: 30,
    RelationshipStage.trusted: 14,
    RelationshipStage.friend: 4,
  };

  static const _dailyInteractionPoints = 1.0;
  static const _autoMilestoneWeight = 2.0;
  static const _lowMoods = {'sad', 'anxious', 'fear', 'angry', 'lonely'};
  static const _autoSalienceThreshold = 0.75;

  Future<RelationshipService> init({DateTime? firstMetFallback}) async {
    var s = await _db.getRelationship();
    s ??= RelationshipState(firstMetAt: firstMetFallback ?? DateTime.now());
    // Idempotent schema migration preserves all historical fields. A stored
    // stage cannot restore expression without validating its governed sources.
    await _db.saveRelationship(s);
    state.value = s;
    updateConversationPolicy(_conversationPolicy);
    milestones.assignAll(await _db.getMilestones());
    return this;
  }

  // ───────────────────────── per-turn interaction ─────────────────────────

  /// Call once per user turn.  Advances streak/active-days, adds the capped
  /// daily interaction point, and checks time-based auto milestones.  Cheap +
  /// idempotent within a day.
  Future<void> recordInteraction() async {
    final s = state.value;
    if (s == null) return;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final last = s.lastActiveDate;
    final lastDay = last == null
        ? null
        : DateTime(last.year, last.month, last.day);

    if (lastDay == today) {
      // Already counted today — interaction score is capped per day.
      return;
    }

    // New active day.
    if (lastDay != null && today.difference(lastDay).inDays == 1) {
      s.currentStreak += 1;
    } else {
      s.currentStreak = 1;
    }
    if (s.currentStreak > s.longestStreak) s.longestStreak = s.currentStreak;
    s.totalActiveDays += 1;
    s.lastActiveDate = today;
    _bump(s, _dailyInteractionPoints);

    await _checkTimeBasedMilestones(s, now);
    await _persist(s);
  }

  // ───────────────────────── milestone creation ─────────────────────────

  /// Legacy/internal history only. Model proposals use the governed ledger.
  Future<Milestone> addMilestone({
    required String type,
    required String title,
    String note = '',
    String? emotion,
    double? weight,
    bool pinned = false,
    DateTime? when,
  }) async {
    final m = Milestone(
      when: when ?? DateTime.now(),
      type: type,
      title: title,
      note: note,
      emotion: emotion,
      weight: weight ?? _weightForType(type),
      pinned: pinned,
    );
    await _db.addMilestone(m);
    milestones.insert(0, m);

    final s = state.value;
    if (s != null) {
      _bump(s, m.weight);
      await _persist(s);
    }
    Log.i('💞 [Relationship] milestone +${m.weight} "${m.title}" ($type)');
    return m;
  }

  /// Hook from [MemoryBus.writeEpisode]: turn an emotionally significant
  /// episode into an auto-milestone.  Fire-and-forget; never blocks the turn.
  Future<void> maybeAutoMilestoneFromEpisode(Episode e) async {
    // Governed events remain reviewable in the memory ledger. Copying their
    // text into this legacy source-less wall would outlive source deletion.
    if (e.sourceRefs.isNotEmpty ||
        (e.sourceType != EpisodeSourceType.runtimeUnknown &&
            e.sourceType != EpisodeSourceType.legacyUnknown)) {
      return;
    }
    final isLow = e.emotion != null && _lowMoods.contains(e.emotion);
    final isSalient = e.salience >= _autoSalienceThreshold;
    if (!isLow && !isSalient) return;
    // De-dupe: at most one auto milestone per day so a heavy session doesn't
    // flood the wall.
    final today = DateTime.now();
    final alreadyToday = milestones.any(
      (m) =>
          (m.type == 'deep_talk' || m.type == 'low_weathered') &&
          _sameDay(m.when, today),
    );
    if (alreadyToday) return;

    await addMilestone(
      type: isLow ? 'low_weathered' : 'deep_talk',
      title: isLow
          ? 'memory.auto_low_weathered'.tr
          : 'memory.auto_deep_talk'.tr,
      note: e.what,
      emotion: e.emotion,
      weight: _autoMilestoneWeight,
    );
  }

  // ───────────────────────── prompt surface ─────────────────────────

  /// Only the validated stage and factual elapsed history enter prompts.
  /// Legacy milestone text remains on the historical wall, not in generation.
  String summaryForPrompt({AppLocale? locale}) {
    final s = state.value;
    if (s == null) return '';
    final promptLocale = _resolvedPromptLocale(locale);
    final days = s.daysKnown();
    return <String>[
      AgentPromptCatalog.text(
        'app.relationship.summary.header',
        locale: promptLocale,
      ),
      AgentPromptCatalog.text(
        days == 1
            ? 'app.relationship.summary.days_one'
            : 'app.relationship.summary.days_other',
        locale: promptLocale,
        params: <String, Object?>{
          'days': days,
          'stage': effectiveStage.promptLabel(locale: promptLocale),
        },
      ),
    ].join('\n');
  }

  /// Policy revisions invalidate content/boundary changes even at equal counts.
  String promptSignature({AppLocale? locale}) {
    final s = state.value;
    if (s == null) return 'rel:none';
    final promptLocale = _resolvedPromptLocale(locale);
    return 'rel:${promptLocale.code}:${effectiveStage.key}:${s.daysKnown()}:'
        'policy:$policyVersion';
  }

  static AppLocale _resolvedPromptLocale(AppLocale? locale) {
    if (locale == null || locale == AppLocale.system) {
      return AgentPromptCatalog.currentLocale;
    }
    return locale;
  }

  // ───────────────────────── internals ─────────────────────────

  void _bump(RelationshipState s, double points) {
    s.score += points;
    final next = _stageForScore(s.score);
    s.stage = _clampByDays(next, s.daysKnown());
  }

  RelationshipStage _stageForScore(double score) {
    for (final (threshold, stage) in _scoreBands) {
      if (score >= threshold) return stage;
    }
    return RelationshipStage.stranger;
  }

  /// Don't let the stage outrun real elapsed time.
  RelationshipStage _clampByDays(RelationshipStage stage, int days) {
    var s = stage;
    while (s.index > 0) {
      final minDays = _minDaysForStage[s];
      if (minDays == null || days >= minDays) break;
      s = RelationshipStage.values[s.index - 1];
    }
    return s;
  }

  double _weightForType(String type) => switch (type) {
    'low_weathered' => 8.0,
    'goal_done' => 6.0,
    'deep_talk' => 5.0,
    'anniversary' => 4.0,
    'first_meet' => 4.0,
    'inside_joke' => 3.0,
    _ => 2.0,
  };

  Future<void> _checkTimeBasedMilestones(
    RelationshipState s,
    DateTime now,
  ) async {
    // Streak anniversaries.
    const streakMarks = {7, 30, 100};
    if (streakMarks.contains(s.currentStreak) &&
        !_hasMilestone('streak', s.currentStreak.toString())) {
      await addMilestone(
        type: 'streak',
        title: 'memory.streak_title'.trParams({
          'count': s.currentStreak.toString(),
        }),
        note: 'memory.streak_note'.trParams({
          'count': s.currentStreak.toString(),
        }),
        weight: 2.0,
        pinned: true,
      );
    }
    // Days-known anniversaries.
    const dayMarks = {30, 100, 365};
    final days = s.daysKnown(now);
    if (dayMarks.contains(days) &&
        !_hasMilestone('anniversary', days.toString())) {
      await addMilestone(
        type: 'anniversary',
        title: 'memory.anniversary_title'.trParams({'days': days.toString()}),
        note: 'memory.anniversary_note'.trParams({'days': days.toString()}),
        pinned: true,
      );
    }
  }

  bool _hasMilestone(String type, String marker) =>
      milestones.any((m) => m.type == type && m.title.contains(marker));

  Future<void> _persist(RelationshipState s) async {
    state.value = s;
    state.refresh();
    await _db.saveRelationship(s);
  }

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}
