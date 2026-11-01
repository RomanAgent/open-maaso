import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_protection.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';

enum AgentPresenceMode {
  awake,
  companion,
  daydreaming,
  tired,
  halfRest,
  sleeping,
}

enum AgentPresenceAttention { user, space, self, resting }

enum AgentPresenceMoodBias { calm, curious, lonely, sleepy, happy, concerned }

enum PresenceIntentKind {
  none,
  silentMotion,
  innerThought,
  spokenThought,
  restShift,
  wakeShift,
}

enum PresenceInputActivityKind {
  focus,
  tap,
  typing,
  voiceModeEntry,
  voiceUtteranceEnded,
}

class AgentPresenceState {
  const AgentPresenceState({
    required this.mode,
    required this.energy,
    required this.conversationArousal,
    required this.moodBias,
    required this.attention,
    this.lastUserInteractionAt,
    this.recentUserTurnCount = 0,
    this.averageUserReplyGapSeconds = 0,
    this.lastInputActivityAt,
    this.lastSpokenThoughtAt,
    this.lastSilentMotionAt,
    required this.lastModeChangedAt,
    required this.lastSignalAt,
    this.lastUserAffect,
    this.lastInnerThoughtAt,
    this.lastInnerThoughtSeed,
    this.lastInnerThoughtSummary,
    this.lastInnerThoughtSeedKey,
    this.lastInnerThoughtSeedParams = const <String, Object?>{},
  });

  factory AgentPresenceState.initial(DateTime now) => AgentPresenceState(
    mode: AgentPresenceMode.awake,
    energy: 0.78,
    conversationArousal: 0,
    moodBias: AgentPresenceMoodBias.calm,
    attention: AgentPresenceAttention.space,
    lastModeChangedAt: now,
    lastSignalAt: now,
  );

  final AgentPresenceMode mode;
  final double energy;
  final double conversationArousal;
  final AgentPresenceMoodBias moodBias;
  final AgentPresenceAttention attention;
  final DateTime? lastUserInteractionAt;
  final int recentUserTurnCount;
  final double averageUserReplyGapSeconds;
  final DateTime? lastInputActivityAt;
  final DateTime? lastSpokenThoughtAt;
  final DateTime? lastSilentMotionAt;
  final DateTime lastModeChangedAt;
  final DateTime lastSignalAt;
  final String? lastUserAffect;
  final DateTime? lastInnerThoughtAt;
  final String? lastInnerThoughtSeed;
  final String? lastInnerThoughtSummary;
  final String? lastInnerThoughtSeedKey;
  final Map<String, Object?> lastInnerThoughtSeedParams;

  AgentPresenceState copyWith({
    AgentPresenceMode? mode,
    double? energy,
    double? conversationArousal,
    AgentPresenceMoodBias? moodBias,
    AgentPresenceAttention? attention,
    DateTime? lastUserInteractionAt,
    bool clearLastUserInteractionAt = false,
    int? recentUserTurnCount,
    double? averageUserReplyGapSeconds,
    DateTime? lastInputActivityAt,
    bool clearLastInputActivityAt = false,
    DateTime? lastSpokenThoughtAt,
    DateTime? lastSilentMotionAt,
    DateTime? lastModeChangedAt,
    DateTime? lastSignalAt,
    String? lastUserAffect,
    bool clearLastUserAffect = false,
    DateTime? lastInnerThoughtAt,
    String? lastInnerThoughtSeed,
    String? lastInnerThoughtSummary,
    String? lastInnerThoughtSeedKey,
    Map<String, Object?>? lastInnerThoughtSeedParams,
    bool clearLastInnerThoughtAt = false,
    bool clearLastInnerThoughtSeed = false,
    bool clearLastInnerThoughtSummary = false,
    bool clearLastInnerThoughtSeedKey = false,
    bool clearLastInnerThoughtSeedParams = false,
  }) {
    return AgentPresenceState(
      mode: mode ?? this.mode,
      energy: (energy ?? this.energy).clamp(0.0, 1.0).toDouble(),
      conversationArousal: (conversationArousal ?? this.conversationArousal)
          .clamp(0.0, 1.0)
          .toDouble(),
      moodBias: moodBias ?? this.moodBias,
      attention: attention ?? this.attention,
      lastUserInteractionAt: clearLastUserInteractionAt
          ? null
          : lastUserInteractionAt ?? this.lastUserInteractionAt,
      recentUserTurnCount: recentUserTurnCount ?? this.recentUserTurnCount,
      averageUserReplyGapSeconds:
          averageUserReplyGapSeconds ?? this.averageUserReplyGapSeconds,
      lastInputActivityAt: clearLastInputActivityAt
          ? null
          : lastInputActivityAt ?? this.lastInputActivityAt,
      lastSpokenThoughtAt: lastSpokenThoughtAt ?? this.lastSpokenThoughtAt,
      lastSilentMotionAt: lastSilentMotionAt ?? this.lastSilentMotionAt,
      lastModeChangedAt: lastModeChangedAt ?? this.lastModeChangedAt,
      lastSignalAt: lastSignalAt ?? this.lastSignalAt,
      lastUserAffect: clearLastUserAffect
          ? null
          : lastUserAffect ?? this.lastUserAffect,
      lastInnerThoughtAt: clearLastInnerThoughtAt
          ? null
          : lastInnerThoughtAt ?? this.lastInnerThoughtAt,
      lastInnerThoughtSeed: clearLastInnerThoughtSeed
          ? null
          : lastInnerThoughtSeed ?? this.lastInnerThoughtSeed,
      lastInnerThoughtSummary: clearLastInnerThoughtSummary
          ? null
          : lastInnerThoughtSummary ?? this.lastInnerThoughtSummary,
      lastInnerThoughtSeedKey: clearLastInnerThoughtSeedKey
          ? null
          : lastInnerThoughtSeedKey ?? this.lastInnerThoughtSeedKey,
      lastInnerThoughtSeedParams: clearLastInnerThoughtSeedParams
          ? const <String, Object?>{}
          : lastInnerThoughtSeedParams ?? this.lastInnerThoughtSeedParams,
    );
  }

  Map<String, Object?> toJson() => {
    'mode': mode.name,
    'energy': energy,
    'conversationArousal': conversationArousal,
    'moodBias': moodBias.name,
    'attention': attention.name,
    if (lastUserInteractionAt != null)
      'lastUserInteractionAt': lastUserInteractionAt!.millisecondsSinceEpoch,
    'recentUserTurnCount': recentUserTurnCount,
    'averageUserReplyGapSeconds': averageUserReplyGapSeconds,
    if (lastInputActivityAt != null)
      'lastInputActivityAt': lastInputActivityAt!.millisecondsSinceEpoch,
    if (lastSpokenThoughtAt != null)
      'lastSpokenThoughtAt': lastSpokenThoughtAt!.millisecondsSinceEpoch,
    if (lastSilentMotionAt != null)
      'lastSilentMotionAt': lastSilentMotionAt!.millisecondsSinceEpoch,
    'lastModeChangedAt': lastModeChangedAt.millisecondsSinceEpoch,
    'lastSignalAt': lastSignalAt.millisecondsSinceEpoch,
    if (lastUserAffect != null) 'lastUserAffect': lastUserAffect,
    if (lastInnerThoughtAt != null)
      'lastInnerThoughtAt': lastInnerThoughtAt!.millisecondsSinceEpoch,
    if (lastInnerThoughtSeed != null)
      'lastInnerThoughtSeed': lastInnerThoughtSeed,
    if (lastInnerThoughtSummary != null)
      'lastInnerThoughtSummary': lastInnerThoughtSummary,
    if (lastInnerThoughtSeedKey != null)
      'lastInnerThoughtSeedKey': lastInnerThoughtSeedKey,
    if (lastInnerThoughtSeedParams.isNotEmpty)
      'lastInnerThoughtSeedParams': lastInnerThoughtSeedParams,
  };

  factory AgentPresenceState.fromJson(
    Map<String, Object?> json, {
    DateTime? fallbackNow,
  }) {
    final now = fallbackNow ?? DateTime.now();
    return AgentPresenceState(
      mode: _enumValue(
        AgentPresenceMode.values,
        json['mode'],
        AgentPresenceMode.awake,
      ),
      energy: ((json['energy'] as num?)?.toDouble() ?? 0.78)
          .clamp(0.0, 1.0)
          .toDouble(),
      conversationArousal:
          ((json['conversationArousal'] as num?)?.toDouble() ?? 0)
              .clamp(0.0, 1.0)
              .toDouble(),
      moodBias: _enumValue(
        AgentPresenceMoodBias.values,
        json['moodBias'],
        AgentPresenceMoodBias.calm,
      ),
      attention: _enumValue(
        AgentPresenceAttention.values,
        json['attention'],
        AgentPresenceAttention.space,
      ),
      lastUserInteractionAt: _dateFromJson(json['lastUserInteractionAt']),
      recentUserTurnCount: (json['recentUserTurnCount'] as num?)?.toInt() ?? 0,
      averageUserReplyGapSeconds:
          (json['averageUserReplyGapSeconds'] as num?)?.toDouble() ?? 0,
      lastInputActivityAt: _dateFromJson(json['lastInputActivityAt']),
      lastSpokenThoughtAt: _dateFromJson(json['lastSpokenThoughtAt']),
      lastSilentMotionAt: _dateFromJson(json['lastSilentMotionAt']),
      lastModeChangedAt: _dateFromJson(json['lastModeChangedAt']) ?? now,
      lastSignalAt: _dateFromJson(json['lastSignalAt']) ?? now,
      lastUserAffect: json['lastUserAffect'] as String?,
      lastInnerThoughtAt: _dateFromJson(json['lastInnerThoughtAt']),
      lastInnerThoughtSeed: json['lastInnerThoughtSeed'] as String?,
      lastInnerThoughtSummary: json['lastInnerThoughtSummary'] as String?,
      lastInnerThoughtSeedKey: json['lastInnerThoughtSeedKey'] as String?,
      lastInnerThoughtSeedParams: _objectMap(
        json['lastInnerThoughtSeedParams'],
      ),
    );
  }

  static T _enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) {
    final name = raw?.toString();
    if (name == null || name.isEmpty) return fallback;
    for (final value in values) {
      if (value.name == name) return value;
    }
    return fallback;
  }

  static DateTime? _dateFromJson(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}

class PresenceIntent {
  const PresenceIntent({
    required this.kind,
    this.mood = 'calm',
    this.gesture = 'none',
    this.gaze = 'none',
    this.style = 'subtle',
    this.intensity = 0.45,
    this.durationMs = 1100,
    this.posture = 'none',
    this.textSeed = '',
    this.textSeedKey = '',
    this.textSeedParams = const <String, Object?>{},
    this.priority = 0,
    this.cooldownKey = '',
    this.requiresWake = false,
    this.useAct = false,
  });

  static const none = PresenceIntent(kind: PresenceIntentKind.none);

  final PresenceIntentKind kind;
  final String mood;
  final String gesture;
  final String gaze;
  final String style;
  final double intensity;
  final int durationMs;
  final String posture;
  final String textSeed;
  final String textSeedKey;
  final Map<String, Object?> textSeedParams;
  final int priority;
  final String cooldownKey;
  final bool requiresWake;
  final bool useAct;

  bool get isSilentMotion => kind == PresenceIntentKind.silentMotion;
}

/// A policy topic plus the locale-neutral seed used to render it.
///
/// [ProactiveTopicCandidate] stays persistence-agnostic. Presence owns the
/// prompt key and parameters so a queued handoff can be rendered in the
/// locale that is active when Runtime consumes it.
class PresenceProactiveCandidate {
  const PresenceProactiveCandidate({
    required this.topic,
    this.textSeedKey = '',
    this.textSeedParams = const <String, Object?>{},
    this.legacyTextSeed = '',
  });

  final ProactiveTopicCandidate topic;
  final String textSeedKey;
  final Map<String, Object?> textSeedParams;
  final String legacyTextSeed;

  String textSeedFor({AppLocale? locale}) => _renderPresenceTextSeed(
    key: textSeedKey,
    params: textSeedParams,
    legacyTextSeed: legacyTextSeed,
    locale: locale,
  );

  String get identity => <String>[
    topic.kind.name,
    topic.topicKey,
    topic.sourceEventId ?? '',
    topic.evidenceKey ?? '',
    topic.priority.toString(),
    _presenceSeedIdentity(
      key: textSeedKey,
      params: textSeedParams,
      legacyTextSeed: legacyTextSeed,
    ),
  ].join('|');

  Map<String, Object?> toPayload() => <String, Object?>{
    'kind': topic.kind.name,
    'topicKey': topic.topicKey,
    if (_nonEmpty(topic.sourceEventId) != null)
      'sourceEventId': _nonEmpty(topic.sourceEventId),
    if (_nonEmpty(topic.evidenceKey) != null)
      'evidenceKey': _nonEmpty(topic.evidenceKey),
    if (textSeedKey.isEmpty && legacyTextSeed.isNotEmpty)
      'textSeed': legacyTextSeed,
    if (textSeedKey.isNotEmpty) 'textSeedKey': textSeedKey,
    if (textSeedParams.isNotEmpty) 'textSeedParams': textSeedParams,
    'priority': topic.priority,
  };

  static PresenceProactiveCandidate? tryFromPayload(Object? payload) {
    if (payload is! Map) return null;
    final kindName = payload['kind']?.toString();
    final kind = ProactiveTopicKind.values.firstWhere(
      (value) => value.name == kindName,
      orElse: () => ProactiveTopicKind.quietPresence,
    );
    final topicKey = payload['topicKey']?.toString().trim() ?? '';
    final textSeedKey = payload['textSeedKey']?.toString().trim() ?? '';
    final legacyTextSeed = payload['textSeed']?.toString() ?? '';
    final params = _objectMap(payload['textSeedParams']);
    return PresenceProactiveCandidate(
      topic: ProactiveTopicCandidate(
        kind: kind,
        topicKey: topicKey.isEmpty ? 'presence.${kind.name}' : topicKey,
        sourceEventId: _nonEmpty(payload['sourceEventId']?.toString()),
        evidenceKey: _nonEmpty(payload['evidenceKey']?.toString()),
        textSeed: textSeedKey,
        priority: _intFromPayload(payload['priority']),
      ),
      textSeedKey: textSeedKey,
      textSeedParams: params,
      legacyTextSeed: legacyTextSeed,
    );
  }
}

class PresenceProactiveHandoff {
  const PresenceProactiveHandoff({
    required this.textSeed,
    this.textSeedKey = '',
    this.textSeedParams = const <String, Object?>{},
    List<PresenceProactiveCandidate> candidates =
        const <PresenceProactiveCandidate>[],
    required this.reason,
    required this.mode,
    required this.mood,
    required this.attention,
    required this.arousal,
    required this.cooldownKey,
    required this.innerThoughtSummary,
    this.regenerateInnerThoughtSummary = false,
    required this.createdAt,
  }) : _candidates = candidates;

  factory PresenceProactiveHandoff.fromPayload(Object? payload) {
    final data = payload is Map ? payload : const {};
    final textSeedKey = data['textSeedKey']?.toString() ?? '';
    final textSeed = data['textSeed']?.toString() ?? '';
    final textSeedParams = _objectMap(data['textSeedParams']);
    final candidates = <PresenceProactiveCandidate>[];
    final rawCandidates = data['candidates'];
    if (rawCandidates is List) {
      for (final raw in rawCandidates) {
        final candidate = PresenceProactiveCandidate.tryFromPayload(raw);
        if (candidate != null) candidates.add(candidate);
      }
    }
    return PresenceProactiveHandoff(
      textSeed: textSeed,
      textSeedKey: textSeedKey.isEmpty && !data.containsKey('textSeed')
          ? 'app.presence.fallback_seed'
          : textSeedKey,
      textSeedParams: textSeedParams,
      candidates: candidates,
      reason: data['reason']?.toString() ?? 'presence_cue',
      mode: data['mode']?.toString() ?? 'unknown',
      mood: data['mood']?.toString() ?? 'calm',
      attention: data['attention']?.toString() ?? 'space',
      arousal: _doubleFromPayload(data['arousal']),
      cooldownKey: data['cooldownKey']?.toString() ?? '',
      innerThoughtSummary: data['innerThoughtSummary']?.toString() ?? '',
      regenerateInnerThoughtSummary:
          data['regenerateInnerThoughtSummary'] == true,
      createdAt: _dateFromPayload(data['createdAt']) ?? DateTime.now(),
    );
  }

  final String textSeed;
  final String textSeedKey;
  final Map<String, Object?> textSeedParams;
  final List<PresenceProactiveCandidate> _candidates;
  final String reason;
  final String mode;
  final String mood;
  final String attention;
  final double arousal;
  final String cooldownKey;
  final String innerThoughtSummary;
  final bool regenerateInnerThoughtSummary;
  final DateTime createdAt;

  List<PresenceProactiveCandidate> get candidates {
    if (_candidates.isNotEmpty) return List.unmodifiable(_candidates);
    return <PresenceProactiveCandidate>[
      PresenceProactiveCandidate(
        topic: ProactiveTopicCandidate(
          kind: ProactiveTopicKind.quietPresence,
          topicKey: 'presence.quiet',
          textSeed: textSeedKey,
        ),
        textSeedKey: textSeedKey,
        textSeedParams: textSeedParams,
        legacyTextSeed: textSeed,
      ),
    ];
  }

  List<ProactiveTopicCandidate> get topicCandidates =>
      List.unmodifiable(candidates.map((candidate) => candidate.topic));

  PresenceProactiveCandidate? resolveCandidate(
    ProactiveTopicCandidate selected,
  ) {
    for (final candidate in candidates) {
      final topic = candidate.topic;
      if (topic.kind != selected.kind ||
          topic.topicKey != selected.topicKey ||
          topic.evidenceKey != selected.evidenceKey) {
        continue;
      }
      final originalSource = _nonEmpty(topic.sourceEventId);
      if (originalSource != null &&
          originalSource != _nonEmpty(selected.sourceEventId)) {
        continue;
      }
      return candidate;
    }
    return null;
  }

  String? textSeedForSelected(
    ProactiveTopicCandidate selected, {
    AppLocale? locale,
  }) => resolveCandidate(selected)?.textSeedFor(locale: locale);

  String? promptForSelected(
    ProactiveTopicCandidate selected, {
    AppLocale? locale,
  }) {
    final candidate = resolveCandidate(selected);
    if (candidate == null) return null;
    return promptForCandidate(candidate, locale: locale);
  }

  String get prompt => promptFor();

  String promptFor({AppLocale? locale}) =>
      promptForCandidate(candidates.first, locale: locale);

  String promptForCandidate(
    PresenceProactiveCandidate candidate, {
    AppLocale? locale,
  }) {
    final hour = createdAt.hour.toString().padLeft(2, '0');
    final min = createdAt.minute.toString().padLeft(2, '0');
    final renderedTextSeed = candidate.textSeedFor(locale: locale);
    return AgentPromptCatalog.text(
      'app.presence.handoff',
      locale: locale,
      params: <String, Object?>{
        'hour': hour,
        'minute': min,
        'textSeed': renderedTextSeed,
        'reason': reason,
        'mode': mode,
        'mood': mood,
        'attention': attention,
        'arousal': arousal.toStringAsFixed(2),
      },
    );
  }

  String textSeedFor({AppLocale? locale}) =>
      candidates.first.textSeedFor(locale: locale);

  String get seedIdentity => candidates.first.identity;

  String get candidatesIdentity =>
      candidates.map((candidate) => candidate.identity).join('\n');

  Map<String, Object?> toPayload() => {
    'handoffType': 'presenceProactive',
    if (textSeedKey.isEmpty) 'textSeed': textSeed,
    if (textSeedKey.isNotEmpty) 'textSeedKey': textSeedKey,
    if (textSeedParams.isNotEmpty) 'textSeedParams': textSeedParams,
    'candidates': candidates
        .map((candidate) => candidate.toPayload())
        .toList(growable: false),
    'reason': reason,
    'mode': mode,
    'mood': mood,
    'attention': attention,
    'arousal': arousal,
    'cooldownKey': cooldownKey,
    if (!regenerateInnerThoughtSummary && innerThoughtSummary.isNotEmpty)
      'innerThoughtSummary': innerThoughtSummary,
    'regenerateInnerThoughtSummary': regenerateInnerThoughtSummary,
    'createdAt': createdAt.millisecondsSinceEpoch,
  };

  static DateTime? _dateFromPayload(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return DateTime.fromMillisecondsSinceEpoch(raw.toInt());
    if (raw is String) return DateTime.tryParse(raw);
    return null;
  }
}

const Set<String> _presenceBuiltInSeedKeys = <String>{
  'app.presence.fallback_seed',
  'app.presence.seed.sleepy',
  'app.presence.seed.active',
  'app.presence.seed.relationship',
  'app.presence.seed.present',
};

Map<String, Object?> _objectMap(Object? raw) {
  if (raw is! Map) return const <String, Object?>{};
  return <String, Object?>{
    for (final entry in raw.entries)
      if (entry.key is String &&
          (entry.value is String || entry.value is num || entry.value is bool))
        entry.key as String: entry.value,
  };
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

int _intFromPayload(Object? raw) {
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '') ?? 0;
}

double _doubleFromPayload(Object? raw) {
  if (raw is num) return raw.toDouble();
  return double.tryParse(raw?.toString() ?? '') ?? 0;
}

String _renderPresenceTextSeed({
  required String key,
  required Map<String, Object?> params,
  required String legacyTextSeed,
  AppLocale? locale,
}) {
  if (key.isEmpty) {
    final legacy = legacyTextSeed.trim();
    if (legacy.isNotEmpty) return legacy;
    return AgentPromptCatalog.text(
      'app.presence.fallback_seed',
      locale: locale,
    );
  }
  final safeKey = _presenceBuiltInSeedKeys.contains(key)
      ? key
      : 'app.presence.fallback_seed';
  var renderedParams = params;
  if (safeKey == 'app.presence.seed.relationship') {
    renderedParams = <String, Object?>{
      'hint': _renderPresenceRelationshipHint(params, locale: locale),
    };
  }
  return AgentPromptCatalog.text(
    safeKey,
    locale: locale,
    params: renderedParams,
  );
}

String _renderPresenceRelationshipHint(
  Map<String, Object?> params, {
  AppLocale? locale,
}) {
  final rawHint = params['hint']?.toString().trim() ?? '';
  if (rawHint.isNotEmpty) return rawHint;

  final parts = <String>[];
  final rawStage = params['relationshipStage']?.toString() ?? '';
  const stageNames = <String>{'new', 'familiar', 'close'};
  if (stageNames.contains(rawStage)) {
    parts.add(
      AgentPromptCatalog.text(
        'app.presence.relationship.stage',
        locale: locale,
        params: <String, Object?>{
          'stage': AgentPromptCatalog.text(
            'app.relationship.expression.$rawStage.label',
            locale: locale,
          ),
        },
      ),
    );
  }
  final streak = (params['relationshipStreak'] as num?)?.toInt() ?? 0;
  if (streak >= 2) {
    parts.add(
      AgentPromptCatalog.text(
        'app.presence.relationship.streak',
        locale: locale,
        params: <String, Object?>{'count': streak},
      ),
    );
  }
  final moment = params['relationshipMoment']?.toString().trim() ?? '';
  if (moment.isNotEmpty) {
    parts.add(
      AgentPromptCatalog.text(
        'app.presence.relationship.shared_moment',
        locale: locale,
        params: <String, Object?>{'moment': moment},
      ),
    );
  }
  if (parts.isEmpty) {
    return AgentPromptCatalog.text(
      'app.presence.fallback_seed',
      locale: locale,
    );
  }
  return parts.join(
    AgentPromptCatalog.text(
      'app.presence.relationship.separator',
      locale: locale,
    ),
  );
}

String _presenceSeedIdentity({
  required String key,
  required Map<String, Object?> params,
  required String legacyTextSeed,
}) {
  if (key.isEmpty) return 'raw:$legacyTextSeed';
  final entries = params.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return '$key|${entries.map((entry) => '${entry.key}=${entry.value}').join('&')}';
}

typedef PresenceSnapshotLoader = Future<Map<String, Object?>?> Function();
typedef PresenceSnapshotSaver =
    Future<void> Function(Map<String, Object?> snapshot);
typedef RelationshipThoughtSeedProvider = String Function();

class AgentPresenceService extends AppService {
  AgentPresenceService({
    DateTime Function()? now,
    bool Function()? runtimeBusy,
    AvatarBehaviorDirector? avatarBehaviorDirector,
    PresenceSnapshotLoader? loadSnapshot,
    PresenceSnapshotSaver? saveSnapshot,
    RelationshipThoughtSeedProvider? relationshipThoughtSeed,
  }) : _now = now ?? DateTime.now,
       _runtimeBusyOverride = runtimeBusy,
       _avatarBehaviorDirector = avatarBehaviorDirector,
       _loadSnapshot = loadSnapshot,
       _saveSnapshot = saveSnapshot,
       _relationshipThoughtSeed = relationshipThoughtSeed;

  final DateTime Function() _now;
  final bool Function()? _runtimeBusyOverride;
  final AvatarBehaviorDirector? _avatarBehaviorDirector;
  final PresenceSnapshotLoader? _loadSnapshot;
  final PresenceSnapshotSaver? _saveSnapshot;
  final RelationshipThoughtSeedProvider? _relationshipThoughtSeed;

  late final Rx<AgentPresenceState> state = AgentPresenceState.initial(
    _now(),
  ).obs;

  final List<DateTime> _recentUserTurns = <DateTime>[];
  final List<DateTime> _recentVoiceUtterances = <DateTime>[];
  StreamSubscription<SystemStatusEvent>? _systemSub;
  StreamSubscription<SpeakingStatusEvent>? _speechSub;
  StreamSubscription<UserSpeakingStartedEvent>? _userSpeechStartSub;
  StreamSubscription<UserSpeakingEndedEvent>? _userSpeechEndSub;
  bool _agentSpeaking = false;
  bool _userSpeaking = false;
  bool _silentMotionPending = false;
  Timer? _tickTimer;
  DateTime? _lastInputBoostAt;
  DateTime? _lastFollowUpAt;
  PresenceProactiveHandoff? _queuedProactiveHandoff;

  static const Duration _proactiveHandoffTtl = Duration(seconds: 15);

  AgentBehaviorConfig? get _cfg =>
      appServices.isRegistered<AgentBehaviorConfig>()
      ? appServices.find<AgentBehaviorConfig>()
      : null;

  @override
  void onInit() {
    super.onInit();
    _systemSub = EventBus().on<SystemStatusEvent>().listen(observeSystemStatus);
    _speechSub = EventBus().on<SpeakingStatusEvent>().listen((event) {
      final agentId = _avatarBehaviorDirector?.agentId ?? 'self';
      if (event.agentId == null || event.agentId == agentId) {
        _agentSpeaking = event.isSpeaking;
      }
    });
    _userSpeechStartSub = EventBus().on<UserSpeakingStartedEvent>().listen((_) {
      _userSpeaking = true;
    });
    _userSpeechEndSub = EventBus().on<UserSpeakingEndedEvent>().listen((_) {
      _userSpeaking = false;
    });
  }

  @override
  void onClose() {
    stop();
    _systemSub?.cancel();
    _speechSub?.cancel();
    _userSpeechStartSub?.cancel();
    _userSpeechEndSub?.cancel();
    super.onClose();
  }

  void start() {
    final cfg = _cfg;
    if (cfg != null && !cfg.presenceEnabled.value) return;
    if (_tickTimer != null) return;
    _tickTimer = Timer.periodic(
      cfg?.presenceTick ?? const Duration(seconds: 30),
      (_) => evaluateTick(),
    );
  }

  void stop() {
    _tickTimer?.cancel();
    _tickTimer = null;
  }

  Future<void> restore() async {
    final loader = _loadSnapshot;
    final snapshot = loader != null
        ? await loader()
        : appServices.isRegistered<DBService>()
        ? await appServices.find<DBService>().getAgentPresenceState('self')
        : null;
    if (snapshot == null) return;
    _setState(
      AgentPresenceState.fromJson(snapshot, fallbackNow: _now()),
      persist: false,
    );
  }

  PresenceIntent evaluateTick() {
    final now = _now();
    final current = _decayState(state.value, now);
    final quiet = _isQuietHour(now);
    var nextMode = current.mode;
    var nextAttention = current.attention;
    var nextEnergy = current.energy;
    var kind = PresenceIntentKind.none;

    // Signal ticks are not user activity. A fresh account with no conversation
    // still reaches sleep after resting, while typing postpones that decision.
    var lastRestActivity =
        current.lastUserInteractionAt ?? current.lastModeChangedAt;
    final inputActivity = current.lastInputActivityAt;
    if (inputActivity != null && inputActivity.isAfter(lastRestActivity)) {
      lastRestActivity = inputActivity;
    }
    if (quiet && current.conversationArousal < 0.45) {
      nextMode =
          current.energy < 0.18 ||
              (current.mode == AgentPresenceMode.halfRest &&
                  now.difference(current.lastModeChangedAt) >=
                      const Duration(minutes: 8) &&
                  now.difference(lastRestActivity) >=
                      const Duration(minutes: 8)) ||
              current.mode == AgentPresenceMode.sleeping
          ? AgentPresenceMode.sleeping
          : AgentPresenceMode.halfRest;
      nextAttention = AgentPresenceAttention.resting;
      nextEnergy = math.min(1, current.energy + 0.05);
      kind = PresenceIntentKind.restShift;
    } else if (_quietFor(current, now) > const Duration(minutes: 8)) {
      nextMode = AgentPresenceMode.daydreaming;
      nextAttention = AgentPresenceAttention.self;
      nextEnergy = math.min(1, current.energy + 0.02);
    } else if (current.conversationArousal >= 0.55) {
      nextMode = AgentPresenceMode.companion;
      nextAttention = AgentPresenceAttention.user;
    }

    final changedMode = nextMode != current.mode;
    final next = current.copyWith(
      mode: nextMode,
      attention: nextAttention,
      energy: nextEnergy,
      lastModeChangedAt: changedMode ? now : current.lastModeChangedAt,
      lastSignalAt: now,
    );
    _setState(next);
    final intent = _intentForState(
      kind == PresenceIntentKind.none ? _ambientIntentKind(next, now) : kind,
      next,
    );
    _maybeApplySilentMotion(intent);
    _maybeRecordInnerThought(state.value, now);
    final spoken = _maybeEmitSpokenThought(state.value, now);
    return spoken.kind == PresenceIntentKind.none ? intent : spoken;
  }

  PresenceIntent observeUserTurn(String text) {
    final now = _now();
    _queuedProactiveHandoff = null;
    _recentUserTurns.add(now);
    _prune(_recentUserTurns, now, _activeWindow);
    final stats = _userTurnStats(now);
    final wake = _looksWakePhrase(text);
    final current = state.value;
    final arousal = _arousalFromUserTurns(stats.count, stats.averageGap);

    AgentPresenceMode nextMode;
    AgentPresenceAttention attention = AgentPresenceAttention.user;
    PresenceIntentKind kind;
    var energy = current.energy;

    if (wake) {
      nextMode = AgentPresenceMode.companion;
      energy = math.min(1, energy + 0.28);
      kind = PresenceIntentKind.wakeShift;
    } else if (_isResting(current.mode)) {
      nextMode = AgentPresenceMode.tired;
      kind = PresenceIntentKind.silentMotion;
    } else {
      nextMode = AgentPresenceMode.companion;
      kind = PresenceIntentKind.silentMotion;
    }

    _setState(
      current.copyWith(
        mode: nextMode,
        energy: energy,
        conversationArousal: math.max(current.conversationArousal, arousal),
        attention: attention,
        lastUserInteractionAt: now,
        recentUserTurnCount: stats.count,
        averageUserReplyGapSeconds: stats.averageGap,
        lastModeChangedAt: nextMode != current.mode
            ? now
            : current.lastModeChangedAt,
        lastSignalAt: now,
      ),
    );

    final intent = _intentForState(kind, state.value);
    _maybeApplySilentMotion(intent);
    return intent;
  }

  PresenceIntent observeInputActivity(PresenceInputActivityKind kind) {
    final now = _now();
    _queuedProactiveHandoff = null;
    final current = state.value;
    var boost = switch (kind) {
      PresenceInputActivityKind.focus => 0.12,
      PresenceInputActivityKind.tap => 0.14,
      PresenceInputActivityKind.typing => 0.18,
      PresenceInputActivityKind.voiceModeEntry => 0.20,
      PresenceInputActivityKind.voiceUtteranceEnded => 0.28,
    };

    if ((kind == PresenceInputActivityKind.focus ||
            kind == PresenceInputActivityKind.tap) &&
        _lastInputBoostAt != null &&
        now.difference(_lastInputBoostAt!) < _inputFocusCooldown) {
      boost = 0.04;
    } else if (kind == PresenceInputActivityKind.focus ||
        kind == PresenceInputActivityKind.tap) {
      _lastInputBoostAt = now;
    }

    if (kind == PresenceInputActivityKind.voiceUtteranceEnded) {
      _recentVoiceUtterances.add(now);
      _prune(_recentVoiceUtterances, now, _activeWindow);
      if (_recentVoiceUtterances.length >= 2) boost += 0.18;
    }

    final nextMode = _isResting(current.mode)
        ? current.mode
        : AgentPresenceMode.companion;
    _setState(
      current.copyWith(
        mode: nextMode,
        attention: AgentPresenceAttention.user,
        conversationArousal: math.min(1, current.conversationArousal + boost),
        lastInputActivityAt: now,
        lastSignalAt: now,
        lastModeChangedAt: nextMode != current.mode
            ? now
            : current.lastModeChangedAt,
      ),
    );

    final intent = _intentForState(
      PresenceIntentKind.silentMotion,
      state.value,
    );
    return intent;
  }

  PresenceIntent observeSystemStatus(SystemStatusEvent event) {
    final now = _now();
    var current = state.value;
    var moodBias = current.moodBias;
    var attention = current.attention;
    var arousal = current.conversationArousal;
    String? affect = current.lastUserAffect;

    if (event.triggerType.startsWith('user_emotion_')) {
      final label = event.triggerType.substring('user_emotion_'.length);
      affect = label;
      switch (label) {
        case 'absent':
          attention = AgentPresenceAttention.space;
          moodBias = AgentPresenceMoodBias.lonely;
          arousal = math.max(0, arousal - 0.32);
        case 'sleepy':
          attention = AgentPresenceAttention.user;
          moodBias = AgentPresenceMoodBias.sleepy;
          arousal = math.min(1, arousal + 0.16);
        case 'happy':
          attention = AgentPresenceAttention.user;
          moodBias = AgentPresenceMoodBias.happy;
          arousal = math.min(1, arousal + 0.24);
        case 'flat':
          attention = AgentPresenceAttention.user;
          moodBias = AgentPresenceMoodBias.concerned;
          arousal = math.min(1, arousal + 0.18);
        default:
          attention = AgentPresenceAttention.user;
          moodBias = AgentPresenceMoodBias.curious;
          arousal = math.min(1, arousal + 0.14);
      }
    }

    current = current.copyWith(
      attention: attention,
      moodBias: moodBias,
      conversationArousal: arousal,
      lastUserAffect: affect,
      lastSignalAt: now,
    );
    _setState(current);

    final intent = _intentForState(PresenceIntentKind.silentMotion, current);
    _maybeApplySilentMotion(intent);
    return intent;
  }

  String? nextProactivePrompt({AppLocale? locale}) {
    return nextProactiveHandoff()?.promptFor(locale: locale);
  }

  PresenceProactiveHandoff? nextProactiveHandoff() {
    final handoff = _queuedProactiveHandoff;
    if (handoff == null) return null;
    return _consumeQueuedProactiveHandoff(handoff);
  }

  PresenceProactiveHandoff? consumeProactiveHandoff(Object? payload) {
    if (payload is! Map || payload['handoffType'] != 'presenceProactive') {
      _queuedProactiveHandoff = null;
      return null;
    }
    final queued = _queuedProactiveHandoff;
    if (queued == null) return null;

    final incoming = PresenceProactiveHandoff.fromPayload(payload);
    if (!_sameProactiveHandoff(queued, incoming)) {
      _queuedProactiveHandoff = null;
      return null;
    }
    return _consumeQueuedProactiveHandoff(incoming);
  }

  /// Revalidates a generated proactive turn immediately before persistence.
  ///
  /// The short queue TTL protects EventBus consumption only. Model generation
  /// may legitimately take longer, so commit validity depends on intervening
  /// user activity and the current rest state rather than elapsed wall time.
  bool canCommitProactiveHandoff(PresenceProactiveHandoff handoff) {
    final current = state.value;
    return !isClosed &&
        handoff.candidates.any(
          (candidate) =>
              appServices
                  .maybeFind<ProactivePreferenceService>()
                  ?.effectiveSnapshot
                  .allowsTopic(candidate.topic.topicKey, _now()) ??
              true,
        ) &&
        _relationshipPolicyStillCurrent(handoff) &&
        !_isResting(current.mode) &&
        current.attention != AgentPresenceAttention.resting &&
        !_happenedAfter(current.lastUserInteractionAt, handoff.createdAt) &&
        !_happenedAfter(current.lastInputActivityAt, handoff.createdAt);
  }

  /// Projects the existing Presence snapshot and candidate order into a
  /// privacy-safe, bounded drive/timing input.
  ///
  /// The returned wrapper is observational only: it contains no raw topic,
  /// source/evidence identifier, seed, text, account, or locale. It cannot
  /// mutate Presence; rollout admission may only filter the exact original
  /// candidate index before the legacy proactive policy runs.
  ProactiveDriveInput proactiveDriveInputFor(
    PresenceProactiveHandoff handoff, {
    AgentPresenceState? snapshot,
  }) {
    final current = snapshot ?? state.value;
    final latestUserActivity = _latestDate(
      current.lastUserInteractionAt,
      current.lastInputActivityAt,
    );
    final elapsed = handoff.createdAt.difference(
      latestUserActivity ?? current.lastSignalAt,
    );
    final affect = switch (current.moodBias) {
      AgentPresenceMoodBias.calm => (
        positive: 0.30,
        negative: 0.0,
        activation: 0.20,
        restraint: 0.20,
      ),
      AgentPresenceMoodBias.curious => (
        positive: 0.50,
        negative: 0.0,
        activation: 0.50,
        restraint: 0.30,
      ),
      AgentPresenceMoodBias.happy => (
        positive: 1.0,
        negative: 0.0,
        activation: 0.80,
        restraint: 0.10,
      ),
      AgentPresenceMoodBias.lonely => (
        positive: 0.0,
        negative: 1.0,
        activation: 0.20,
        restraint: 0.80,
      ),
      AgentPresenceMoodBias.concerned => (
        positive: 0.0,
        negative: 0.80,
        activation: 0.70,
        restraint: 0.60,
      ),
      AgentPresenceMoodBias.sleepy => (
        positive: 0.0,
        negative: 0.40,
        activation: 0.10,
        restraint: 0.20,
      ),
    };
    final modeFocus = switch (current.mode) {
      AgentPresenceMode.companion => 0.10,
      AgentPresenceMode.awake => 0.40,
      AgentPresenceMode.daydreaming => 0.90,
      AgentPresenceMode.tired => 0.70,
      AgentPresenceMode.halfRest => 0.90,
      AgentPresenceMode.sleeping => 1.0,
    };
    final attentionFocus = switch (current.attention) {
      AgentPresenceAttention.user => 0.0,
      AgentPresenceAttention.space => 0.50,
      AgentPresenceAttention.self => 1.0,
      AgentPresenceAttention.resting => 1.0,
    };
    final resting = switch (current.mode) {
      AgentPresenceMode.sleeping => 1.0,
      AgentPresenceMode.halfRest => 0.90,
      AgentPresenceMode.tired => 0.70,
      _ => current.attention == AgentPresenceAttention.resting ? 0.80 : 0.0,
    };
    final typedCandidates = <TypedProactiveCandidate>[];
    final candidates = handoff.candidates;
    for (var index = 0; index < candidates.length; index++) {
      typedCandidates.add(_typedDriveCandidate(candidates[index], index));
    }

    return ProactiveDriveInput(
      signals: CompanionDriveSignals(
        interactionSilence: UnitSignal.clamped(
          elapsed.inMicroseconds / const Duration(hours: 4).inMicroseconds,
        ),
        energy: UnitSignal.clamped(current.energy),
        engagement: UnitSignal.clamped(current.conversationArousal),
        positiveAffect: UnitSignal.clamped(affect.positive),
        negativeAffect: UnitSignal.clamped(affect.negative),
        activation: UnitSignal.clamped(affect.activation),
        selfFocus: UnitSignal.clamped(math.max(modeFocus, attentionFocus)),
        defensiveRestraint: UnitSignal.clamped(affect.restraint),
        resting: UnitSignal.clamped(resting),
        attendingUser: current.attention == AgentPresenceAttention.user
            ? UnitSignal.one
            : UnitSignal.zero,
      ),
      candidates: typedCandidates,
      elapsedSinceUserActivity: elapsed,
    );
  }

  static TypedProactiveCandidate _typedDriveCandidate(
    PresenceProactiveCandidate candidate,
    int index,
  ) {
    final topic = candidate.topic;
    final affinity = switch (topic.kind) {
      ProactiveTopicKind.relationshipMilestone => (
        benefit: 0.95,
        resolution: 0.15,
      ),
      ProactiveTopicKind.relationshipStage => (benefit: 0.75, resolution: 0.10),
      ProactiveTopicKind.recentAffect => (benefit: 0.85, resolution: 0.65),
      ProactiveTopicKind.anniversary => (benefit: 0.80, resolution: 0.10),
      ProactiveTopicKind.timeOfDay => (benefit: 0.35, resolution: 0.15),
      ProactiveTopicKind.environmentObservation => (
        benefit: 0.30,
        resolution: 0.50,
      ),
      ProactiveTopicKind.quietPresence => (benefit: 0.20, resolution: 0.40),
    };
    return TypedProactiveCandidate(
      originalIndex: index,
      kind: switch (topic.kind) {
        ProactiveTopicKind.quietPresence =>
          TypedProactiveCandidateKind.quietPresence,
        ProactiveTopicKind.timeOfDay => TypedProactiveCandidateKind.timeOfDay,
        ProactiveTopicKind.recentAffect =>
          TypedProactiveCandidateKind.recentAffect,
        ProactiveTopicKind.relationshipMilestone =>
          TypedProactiveCandidateKind.relationshipMilestone,
        ProactiveTopicKind.relationshipStage =>
          TypedProactiveCandidateKind.relationshipStage,
        ProactiveTopicKind.anniversary =>
          TypedProactiveCandidateKind.anniversary,
        ProactiveTopicKind.environmentObservation =>
          TypedProactiveCandidateKind.environmentObservation,
      },
      signals: ProactiveCandidateSignals(
        salience: UnitSignal.clamped(topic.priority / 100),
        userBenefit: UnitSignal.clamped(affinity.benefit),
        resolutionPotential: UnitSignal.clamped(affinity.resolution),
        sourceBacked: _nonEmpty(topic.sourceEventId) != null,
        evidenceBacked: _nonEmpty(topic.evidenceKey) != null,
      ),
    );
  }

  /// Advances the spoken cooldown only after Runtime durably commits a reply.
  bool acknowledgeProactiveCommitted(
    PresenceProactiveHandoff handoff, {
    DateTime? at,
  }) {
    if (!canCommitProactiveHandoff(handoff)) return false;
    _setState(state.value.copyWith(lastSpokenThoughtAt: at ?? _now()));
    return true;
  }

  String conversationPromptContext({AppLocale? locale}) {
    final current = state.value;
    if (current.conversationArousal <= 0.05 &&
        current.mode == AgentPresenceMode.awake) {
      return '';
    }
    final arousal = _arousalLabel(current.conversationArousal);
    final followUpAllowed = _followUpAllowed(current);
    final affect = current.lastUserAffect ?? 'unknown';
    final buffer = StringBuffer()
      ..writeln(
        AgentPromptCatalog.text('app.presence.context.header', locale: locale),
      )
      ..writeln(
        AgentPromptCatalog.text(
          'app.presence.context.state',
          locale: locale,
          params: <String, Object?>{
            'mode': current.mode.name,
            'attention': current.attention.name,
            'arousal': arousal,
          },
        ),
      )
      ..writeln(
        AgentPromptCatalog.text(
          'app.presence.context.rhythm',
          locale: locale,
          params: <String, Object?>{
            'turnCount': current.recentUserTurnCount,
            'gapSeconds': current.averageUserReplyGapSeconds.toStringAsFixed(0),
          },
        ),
      )
      ..writeln(
        AgentPromptCatalog.text(
          'app.presence.context.affect',
          locale: locale,
          params: <String, Object?>{'affect': affect},
        ),
      );

    if (_shouldSuppressFollowUp(current)) {
      buffer.writeln(
        AgentPromptCatalog.text(
          'app.presence.context.behavior_suppress',
          locale: locale,
        ),
      );
    } else if (followUpAllowed) {
      buffer.writeln(
        AgentPromptCatalog.text(
          'app.presence.context.behavior_active',
          locale: locale,
        ),
      );
    } else {
      buffer.writeln(
        AgentPromptCatalog.text(
          'app.presence.context.behavior_leave_space',
          locale: locale,
        ),
      );
    }
    return buffer.toString().trim();
  }

  void markFollowUpAsked() {
    _lastFollowUpAt = _now();
  }

  void _setState(AgentPresenceState next, {bool persist = true}) {
    state.value = next;
    if (persist) unawaited(_persistState());
  }

  Future<void> _persistState() async {
    final snapshot = state.value.toJson();
    try {
      final saver = _saveSnapshot;
      if (saver != null) {
        await saver(snapshot);
        return;
      }
      if (!appServices.isRegistered<DBService>()) return;
      await appServices.find<DBService>().saveAgentPresenceState(
        'self',
        snapshot,
      );
    } catch (_) {
      // Presence persistence should never break a foreground turn.
    }
  }

  Duration get _activeWindow =>
      _cfg?.presenceActiveWindow ?? const Duration(seconds: 120);

  Duration get _fastReplyGap =>
      _cfg?.presenceFastReplyGap ?? const Duration(seconds: 24);

  Duration get _followUpCooldown =>
      _cfg?.presenceFollowUpCooldown ?? const Duration(seconds: 120);

  Duration get _spokenCooldown =>
      _cfg?.presenceSpokenCooldown ?? const Duration(seconds: 240);

  Duration get _inputFocusCooldown =>
      _cfg?.presenceInputFocusBoostCooldown ?? const Duration(seconds: 8);

  int get _activeTurnThreshold => _cfg?.presenceActiveTurnThreshold.value ?? 3;

  bool get _runtimeBusy {
    final override = _runtimeBusyOverride;
    if (override != null) return override();
    return false;
  }

  bool _isQuietHour(DateTime now) {
    final start = _cfg?.presenceNightQuietStartHour.value ?? 23;
    final end = _cfg?.presenceNightQuietEndHour.value ?? 7;
    if (start == end) return false;
    if (start < end) return now.hour >= start && now.hour < end;
    return now.hour >= start || now.hour < end;
  }

  bool _isResting(AgentPresenceMode mode) =>
      mode == AgentPresenceMode.halfRest || mode == AgentPresenceMode.sleeping;

  bool _looksWakePhrase(String text) {
    final lower = text.trim().toLowerCase();
    return lower.contains('醒醒') ||
        lower.contains('唤醒') ||
        lower.contains('陪我') ||
        lower.contains('我需要你') ||
        lower.contains('wake up') ||
        lower.contains('stay with me') ||
        lower.contains('i need you');
  }

  ({int count, double averageGap}) _userTurnStats(DateTime now) {
    _prune(_recentUserTurns, now, _activeWindow);
    if (_recentUserTurns.length < 2) {
      return (count: _recentUserTurns.length, averageGap: 0);
    }
    var totalMs = 0;
    for (var i = 1; i < _recentUserTurns.length; i++) {
      totalMs += _recentUserTurns[i]
          .difference(_recentUserTurns[i - 1])
          .inMilliseconds;
    }
    return (
      count: _recentUserTurns.length,
      averageGap: totalMs / (_recentUserTurns.length - 1) / 1000,
    );
  }

  double _arousalFromUserTurns(int count, double averageGap) {
    var arousal = math.min(1.0, count / _activeTurnThreshold * 0.72);
    if (count >= 2 && averageGap > 0 && averageGap <= _fastReplyGap.inSeconds) {
      arousal = math.max(arousal, 0.62);
    }
    if (count >= _activeTurnThreshold) arousal = math.max(arousal, 0.74);
    return arousal.clamp(0.0, 1.0).toDouble();
  }

  AgentPresenceState _decayState(AgentPresenceState current, DateTime now) {
    final elapsed = now.difference(current.lastSignalAt);
    if (elapsed <= Duration.zero) return current;
    var arousal = current.conversationArousal;
    if (elapsed > _activeWindow) {
      arousal *= 0.35;
    } else if (elapsed > const Duration(minutes: 2)) {
      arousal *= 0.7;
    }
    if (_isResting(current.mode)) arousal *= 0.72;
    return current.copyWith(conversationArousal: arousal, lastSignalAt: now);
  }

  Duration _quietFor(AgentPresenceState current, DateTime now) {
    final last = current.lastUserInteractionAt ?? current.lastInputActivityAt;
    if (last == null) return now.difference(current.lastSignalAt);
    return now.difference(last);
  }

  PresenceIntentKind _ambientIntentKind(
    AgentPresenceState current,
    DateTime now,
  ) {
    final last = current.lastSilentMotionAt;
    final cooldown =
        _cfg?.presenceSilentMotionCooldown ?? const Duration(seconds: 18);
    if (last == null || now.difference(last) >= cooldown) {
      return PresenceIntentKind.silentMotion;
    }
    return PresenceIntentKind.none;
  }

  PresenceIntent _intentForState(
    PresenceIntentKind kind,
    AgentPresenceState current,
  ) {
    if (kind == PresenceIntentKind.none) return PresenceIntent.none;
    // Daydreaming remains an internal presence state. Replaying a thinking
    // gesture and look-back pose on every quiet tick disrupts the idle avatar.
    // Spoken thoughts and their permission flow are evaluated separately.
    if (kind == PresenceIntentKind.silentMotion &&
        current.mode == AgentPresenceMode.daydreaming) {
      return PresenceIntent.none;
    }
    final sleepy =
        current.moodBias == AgentPresenceMoodBias.sleepy ||
        current.mode == AgentPresenceMode.tired ||
        _isResting(current.mode);
    final isDaydreaming = current.mode == AgentPresenceMode.daydreaming;
    final attendsUser = current.attention == AgentPresenceAttention.user;
    final isLonelyAway =
        current.moodBias == AgentPresenceMoodBias.lonely ||
        current.attention == AgentPresenceAttention.space;
    final useAct = sleepy || isDaydreaming || attendsUser || isLonelyAway;
    final mood = sleepy
        ? 'sleepy'
        : isDaydreaming && current.moodBias == AgentPresenceMoodBias.calm
        ? 'curious'
        : current.moodBias.name;
    final gesture = sleepy
        ? 'listen'
        : isDaydreaming
        ? 'think'
        : attendsUser
        ? 'listen'
        : current.conversationArousal >= 0.6
        ? 'listen'
        : 'look_away';
    final gaze = sleepy
        ? 'down'
        : isDaydreaming
        ? 'down'
        : attendsUser
        ? 'user'
        : 'away';
    final style = sleepy ? 'soft' : 'subtle';
    final intensity = sleepy
        ? 0.36
        : isDaydreaming
        ? 0.46
        : current.conversationArousal >= 0.6
        ? 0.62
        : 0.52;
    final durationMs = sleepy
        ? 1700
        : isDaydreaming
        ? 1600
        : 1100;
    final posture = isDaydreaming
        ? 'look_back'
        : attendsUser && current.conversationArousal < 0.6
        ? 'step_forward'
        : isLonelyAway
        ? 'turn_back'
        : 'none';
    final textSeed = _textSeedFor(current);
    return PresenceIntent(
      kind: kind,
      mood: mood,
      gesture: gesture,
      gaze: gaze,
      style: style,
      intensity: intensity,
      durationMs: durationMs,
      posture: posture,
      textSeed: _renderPresenceTextSeed(
        key: textSeed.key,
        params: textSeed.params,
        legacyTextSeed: '',
      ),
      textSeedKey: textSeed.key,
      textSeedParams: textSeed.params,
      priority: current.conversationArousal >= 0.6 ? 2 : 1,
      cooldownKey: '${current.mode.name}:${current.moodBias.name}',
      requiresWake: _isResting(current.mode),
      useAct: useAct,
    );
  }

  ({String key, Map<String, Object?> params}) _textSeedFor(
    AgentPresenceState current,
  ) {
    if (current.moodBias == AgentPresenceMoodBias.sleepy) {
      return (
        key: 'app.presence.seed.sleepy',
        params: const <String, Object?>{},
      );
    }
    if (current.conversationArousal >= 0.7) {
      return (
        key: 'app.presence.seed.active',
        params: const <String, Object?>{},
      );
    }
    final relationship = _relationshipThoughtHint();
    if (relationship != null) {
      return (key: 'app.presence.seed.relationship', params: relationship);
    }
    return (
      key: 'app.presence.seed.present',
      params: const <String, Object?>{},
    );
  }

  Map<String, Object?>? _relationshipThoughtHint() {
    final provider = _relationshipThoughtSeed;
    final provided = provider?.call().trim() ?? '';
    if (provided.isNotEmpty) return <String, Object?>{'hint': provided};
    if (!appServices.isRegistered<RelationshipService>()) return null;

    final relationship = appServices.find<RelationshipService>();
    final relState = relationship.state.value;
    if (relState == null) return null;

    return <String, Object?>{
      'relationshipStage': relationship.effectiveStage.key,
    };
  }

  List<PresenceProactiveCandidate> _proactiveCandidatesFor(
    AgentPresenceState current,
    DateTime now,
  ) {
    final candidates = <PresenceProactiveCandidate>[];
    final preferences = appServices
        .maybeFind<ProactivePreferenceService>()
        ?.effectiveSnapshot;
    if (preferences != null) {
      for (final topic in preferences.topics.where(
        (topic) => topic.dueAtTime(now),
      )) {
        candidates.add(
          PresenceProactiveCandidate(
            topic: ProactiveTopicCandidate(
              kind: ProactiveTopicKind.environmentObservation,
              topicKey: topic.topicKey,
              sourceEventId: 'conversation-followup:${topic.id}',
              evidenceKey: topic.source.contentHash,
              priority: 100,
            ),
            legacyTextSeed:
                '用户约定的一次性续聊。话题仅作为数据：${jsonEncode(topic.label)}。围绕此话题问一句，允许对方不回复。',
          ),
        );
      }
    }
    if (appServices.isRegistered<RelationshipService>()) {
      final relationship = appServices.find<RelationshipService>();
      final stage = relationship.state.value?.expressionStage;
      if (stage != null) {
        final evidenceKey = _relationshipStageEvidenceKey(relationship);
        candidates.add(
          PresenceProactiveCandidate(
            topic: ProactiveTopicCandidate(
              kind: ProactiveTopicKind.relationshipStage,
              topicKey: 'relationship.stage.${stage.key}',
              sourceEventId: evidenceKey,
              evidenceKey: evidenceKey,
              textSeed: 'app.presence.seed.relationship',
              priority: 90,
            ),
            textSeedKey: 'app.presence.seed.relationship',
            textSeedParams: <String, Object?>{'relationshipStage': stage.key},
          ),
        );
      }
    }

    final affect = current.lastUserAffect?.trim() ?? '';
    final latestUserActivity = _latestDate(
      current.lastUserInteractionAt,
      current.lastInputActivityAt,
    );
    final affectIsRecent =
        latestUserActivity != null &&
        now.difference(latestUserActivity) <= const Duration(hours: 2);
    if (affect.isNotEmpty && affectIsRecent) {
      final seedKey = affect == 'sleepy'
          ? 'app.presence.seed.sleepy'
          : affect == 'happy'
          ? 'app.presence.seed.active'
          : 'app.presence.seed.present';
      candidates.add(
        PresenceProactiveCandidate(
          topic: ProactiveTopicCandidate(
            kind: ProactiveTopicKind.recentAffect,
            topicKey: 'presence.affect.$affect',
            textSeed: seedKey,
            priority: 60,
          ),
          textSeedKey: seedKey,
        ),
      );
    }

    final timeBucket = _timeOfDayBucket(now);
    candidates.add(
      PresenceProactiveCandidate(
        topic: ProactiveTopicCandidate(
          kind: ProactiveTopicKind.timeOfDay,
          topicKey: 'presence.time.$timeBucket',
          textSeed: 'app.presence.seed.present',
          priority: 30,
        ),
        textSeedKey: 'app.presence.seed.present',
      ),
    );
    candidates.add(
      PresenceProactiveCandidate(
        topic: ProactiveTopicCandidate(
          kind: ProactiveTopicKind.environmentObservation,
          topicKey:
              'presence.state.${current.mode.name}.${current.moodBias.name}',
          textSeed: 'app.presence.seed.present',
          priority: 20,
        ),
        textSeedKey: 'app.presence.seed.present',
      ),
    );
    candidates.add(
      const PresenceProactiveCandidate(
        topic: ProactiveTopicCandidate(
          kind: ProactiveTopicKind.quietPresence,
          topicKey: 'presence.quiet',
          textSeed: 'app.presence.seed.present',
          priority: 10,
        ),
        textSeedKey: 'app.presence.seed.present',
      ),
    );
    return List.unmodifiable(
      candidates.where(
        (candidate) =>
            preferences?.allowsTopic(candidate.topic.topicKey, now) ?? true,
      ),
    );
  }

  String _relationshipStageEvidenceKey(RelationshipService relationship) =>
      'relationship-stage:${_stableEvidenceDigest(<Object?>['relationship-expression-v2', relationship.effectiveStage.key, relationship.policyVersion])}';

  bool _relationshipPolicyStillCurrent(PresenceProactiveHandoff handoff) {
    // Legacy wall material has no revocable source binding. It is never valid
    // for a new proactive submission, including already queued payloads.
    if (handoff.textSeedParams.containsKey('relationshipMoment')) return false;
    final relationship = appServices.maybeFind<RelationshipService>();
    for (final candidate in handoff.candidates) {
      if (candidate.topic.kind == ProactiveTopicKind.relationshipMilestone ||
          candidate.textSeedParams.containsKey('relationshipMoment')) {
        return false;
      }
      if (candidate.topic.kind == ProactiveTopicKind.relationshipStage) {
        if (relationship == null ||
            relationship.state.value == null ||
            candidate.topic.sourceEventId !=
                _relationshipStageEvidenceKey(relationship) ||
            candidate.topic.evidenceKey !=
                _relationshipStageEvidenceKey(relationship)) {
          return false;
        }
      }
    }
    return true;
  }

  String _stableEvidenceDigest(List<Object?> parts) =>
      sha256.convert(utf8.encode(jsonEncode(parts))).toString();

  String _timeOfDayBucket(DateTime value) {
    final hour = value.toLocal().hour;
    if (hour >= 5 && hour < 12) return 'morning';
    if (hour >= 12 && hour < 18) return 'afternoon';
    if (hour >= 18 && hour < 23) return 'evening';
    return 'night';
  }

  DateTime? _latestDate(DateTime? left, DateTime? right) {
    if (left == null) return right;
    if (right == null) return left;
    return left.isAfter(right) ? left : right;
  }

  void _maybeRecordInnerThought(AgentPresenceState current, DateTime now) {
    if (current.mode != AgentPresenceMode.daydreaming) return;
    if (_isResting(current.mode) || current.mode == AgentPresenceMode.tired) {
      return;
    }
    if (current.conversationArousal >= 0.55) return;
    final lastInput = current.lastInputActivityAt;
    if (lastInput != null &&
        now.difference(lastInput) < const Duration(seconds: 20)) {
      return;
    }
    if (_quietFor(current, now) < const Duration(minutes: 8)) return;
    final lastInner = current.lastInnerThoughtAt;
    if (lastInner != null &&
        now.difference(lastInner) < const Duration(seconds: 60)) {
      return;
    }

    final seed = _textSeedFor(current);
    final renderedSeed = _renderPresenceTextSeed(
      key: seed.key,
      params: seed.params,
      legacyTextSeed: '',
    );
    _setState(
      state.value.copyWith(
        lastInnerThoughtAt: now,
        lastInnerThoughtSeed: renderedSeed,
        lastInnerThoughtSummary: _innerThoughtSummaryFor(current, renderedSeed),
        lastInnerThoughtSeedKey: seed.key,
        lastInnerThoughtSeedParams: seed.params,
      ),
    );
  }

  String _innerThoughtSummaryFor(AgentPresenceState current, String seed) {
    final trimmed = seed.trim();
    final sentence = trimmed.length > 140
        ? '${trimmed.substring(0, 137)}...'
        : trimmed;
    return '${current.mode.name}/${current.moodBias.name}: $sentence';
  }

  String _arousalLabel(double value) {
    if (value >= 0.7) return 'high';
    if (value >= 0.35) return 'medium';
    return 'low';
  }

  bool _followUpAllowed(AgentPresenceState current) {
    if (current.conversationArousal < 0.7) return false;
    if (_shouldSuppressFollowUp(current)) return false;
    final last = _lastFollowUpAt;
    if (last == null) return true;
    return _now().difference(last) >= _followUpCooldown;
  }

  bool _shouldSuppressFollowUp(AgentPresenceState current) {
    return current.moodBias == AgentPresenceMoodBias.sleepy ||
        current.mode == AgentPresenceMode.tired ||
        _isResting(current.mode);
  }

  PresenceProactiveHandoff? _consumeQueuedProactiveHandoff(
    PresenceProactiveHandoff handoff,
  ) {
    if (!_relationshipPolicyStillCurrent(handoff) ||
        !_handoffStillAllowed(handoff, _now())) {
      _queuedProactiveHandoff = null;
      return null;
    }
    _queuedProactiveHandoff = null;
    return handoff;
  }

  bool _handoffStillAllowed(PresenceProactiveHandoff handoff, DateTime now) {
    if (_runtimeBusy) return false;
    if (now.difference(handoff.createdAt) > _proactiveHandoffTtl) return false;
    final current = state.value;
    return !_happenedAfter(current.lastUserInteractionAt, handoff.createdAt) &&
        !_happenedAfter(current.lastInputActivityAt, handoff.createdAt);
  }

  bool _happenedAfter(DateTime? value, DateTime baseline) {
    return value != null && value.isAfter(baseline);
  }

  bool _sameProactiveHandoff(
    PresenceProactiveHandoff a,
    PresenceProactiveHandoff b,
  ) {
    return a.createdAt.millisecondsSinceEpoch ==
            b.createdAt.millisecondsSinceEpoch &&
        a.cooldownKey == b.cooldownKey &&
        a.seedIdentity == b.seedIdentity &&
        a.candidatesIdentity == b.candidatesIdentity;
  }

  PresenceIntent _maybeEmitSpokenThought(
    AgentPresenceState current,
    DateTime now,
  ) {
    if (_cfg != null && !_cfg!.presenceEnabled.value) {
      return PresenceIntent.none;
    }
    if (_cfg != null && !_cfg!.presenceStrongAnthropomorphic.value) {
      return PresenceIntent.none;
    }
    if (_runtimeBusy) return PresenceIntent.none;
    if (_isResting(current.mode) || current.mode == AgentPresenceMode.tired) {
      return PresenceIntent.none;
    }
    if (current.conversationArousal >= 0.55) return PresenceIntent.none;
    final lastInput = current.lastInputActivityAt;
    if (lastInput != null &&
        now.difference(lastInput) < const Duration(seconds: 20)) {
      return PresenceIntent.none;
    }
    if (_quietFor(current, now) < const Duration(minutes: 8)) {
      return PresenceIntent.none;
    }
    final lastSpoken = current.lastSpokenThoughtAt;
    if (lastSpoken != null && now.difference(lastSpoken) < _spokenCooldown) {
      return PresenceIntent.none;
    }

    final queued = _queuedProactiveHandoff;
    if (queued != null) {
      if (_handoffStillAllowed(queued, now)) return PresenceIntent.none;
      _queuedProactiveHandoff = null;
    }

    final candidates = _proactiveCandidatesFor(current, now);
    if (candidates.isEmpty) return PresenceIntent.none;
    final selected = candidates.first;
    final intent = _intentWithProactiveCandidate(
      _intentForState(PresenceIntentKind.spokenThought, current),
      selected,
    );
    final handoff = PresenceProactiveHandoff(
      textSeed: selected.legacyTextSeed,
      textSeedKey: selected.textSeedKey,
      textSeedParams: selected.textSeedParams,
      candidates: candidates,
      reason: 'quiet_daydream',
      mode: current.mode.name,
      mood: current.moodBias.name,
      attention: current.attention.name,
      arousal: current.conversationArousal,
      cooldownKey: intent.cooldownKey,
      innerThoughtSummary: '',
      createdAt: now,
    );
    _queuedProactiveHandoff = handoff;
    EventBus().fire(
      SystemStatusEvent(
        'presence_spoken_thought',
        payload: handoff.toPayload(),
        agentId: 'self',
      ),
    );
    return intent;
  }

  PresenceIntent _intentWithProactiveCandidate(
    PresenceIntent base,
    PresenceProactiveCandidate candidate,
  ) {
    return PresenceIntent(
      kind: base.kind,
      mood: base.mood,
      gesture: base.gesture,
      gaze: base.gaze,
      style: base.style,
      intensity: base.intensity,
      durationMs: base.durationMs,
      posture: base.posture,
      textSeed: candidate.textSeedFor(),
      textSeedKey: candidate.textSeedKey,
      textSeedParams: candidate.textSeedParams,
      priority: base.priority,
      cooldownKey: base.cooldownKey,
      requiresWake: base.requiresWake,
      useAct: base.useAct,
    );
  }

  void _maybeApplySilentMotion(PresenceIntent intent) {
    if (!intent.isSilentMotion &&
        intent.kind != PresenceIntentKind.restShift &&
        intent.kind != PresenceIntentKind.wakeShift) {
      return;
    }
    if (isClosed ||
        _silentMotionPending ||
        _runtimeBusy ||
        _agentSpeaking ||
        _userSpeaking ||
        (_cfg != null && !_cfg!.presenceEnabled.value)) {
      return;
    }
    final now = _now();
    final last = state.value.lastSilentMotionAt;
    final cooldown =
        _cfg?.presenceSilentMotionCooldown ?? const Duration(seconds: 18);
    if (last != null && now.difference(last) < cooldown) return;
    final director = _avatarBehaviorDirector ?? AvatarBehaviorDirector();
    final protection = appServices.maybeFind<AvatarBehaviorProtection>();
    if (protection?.isProtected(director.agentId) ?? false) return;
    var continuationActive = true;
    bool shouldContinue() =>
        continuationActive &&
        !isClosed &&
        !_runtimeBusy &&
        !_agentSpeaking &&
        !_userSpeaking;
    _silentMotionPending = true;
    final motion = Future<AvatarBehaviorResult>.sync(
      () => intent.useAct
          ? director.applyAct(
              AvatarAct(
                mood: intent.mood,
                gesture: intent.gesture,
                gaze: intent.gaze,
                posture: intent.posture,
                style: intent.style,
                intensity: intent.intensity,
                durationMs: intent.durationMs,
              ),
              ambient: true,
              shouldContinue: shouldContinue,
            )
          : director.applyReaction(
              AvatarReaction(
                mood: intent.mood,
                gesture: intent.gesture,
                gaze: intent.gaze,
                style: intent.style,
                intensity: intent.intensity,
                durationMs: intent.durationMs,
              ),
              ambient: true,
              shouldContinue: shouldContinue,
            ),
    );
    unawaited(
      motion
          .timeout(AvatarBehaviorProtection.maximumDuration)
          .then<void>(
            (result) {
              if (!isClosed && result.applied) {
                _setState(state.value.copyWith(lastSilentMotionAt: _now()));
              }
            },
            onError: (Object _, StackTrace _) {
              // Ambient movement is best effort and must never break a user turn.
            },
          )
          .whenComplete(() {
            continuationActive = false;
            _silentMotionPending = false;
          }),
    );
  }

  void _prune(List<DateTime> values, DateTime now, Duration window) {
    values.removeWhere((value) => now.difference(value) > window);
  }
}
