import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';

/// The persistent emotional bond between the user and their maaso agent.
///
/// This is the heart of "我们之间发生过什么" — a single record (keyed `self`)
/// that retains the original interaction history. The legacy score and stage
/// are migration candidates; current expression is derived from governed
/// conversation evidence, never from these counters.
enum RelationshipStage {
  stranger('stranger'),
  acquaintance('acquaintance'),
  friend('friend'),
  trusted('trusted'),
  attuned('attuned');

  const RelationshipStage(this.key);

  final String key;

  String get labelKey => 'relationship_stage.$key';

  /// Backwards-compatible display labels for non-prompt callers.
  String get labelEn => promptLabel(locale: AppLocale.en);

  String get labelZh => promptLabel(locale: AppLocale.zh);

  String promptLabel({AppLocale? locale}) => AgentPromptCatalog.text(
    'app.relationship.stage.$key.label',
    locale: locale,
  );

  /// A short prompt-side hint telling the agent how intimate to be at this
  /// stage — drives address (nickname vs neutral), tone, and how freely it may
  /// bring up shared history.
  String get toneHint => promptToneHint();

  String promptToneHint({AppLocale? locale}) => AgentPromptCatalog.text(
    'app.relationship.stage.$key.tone',
    locale: locale,
  );

  static RelationshipStage fromKey(String? key) =>
      RelationshipStage.values.firstWhere(
        (s) => s.key == key,
        orElse: () => RelationshipStage.stranger,
      );
}

extension RelationshipExpressionStageLabels on RelationshipExpressionStage {
  String promptLabel({AppLocale? locale}) => AgentPromptCatalog.text(
    'app.relationship.expression.$key.label',
    locale: locale,
  );

  String get labelEn => promptLabel(locale: AppLocale.en);
}

class RelationshipState {
  RelationshipState({
    required this.firstMetAt,
    this.score = 0,
    this.stage = RelationshipStage.stranger,
    this.lastActiveDate,
    this.currentStreak = 0,
    this.longestStreak = 0,
    this.totalActiveDays = 0,
  });

  /// When the two first met — defaults to the agent's birthDate.
  final DateTime firstMetAt;

  /// INTERNAL accumulation. Never rendered to user/agent. Drives [stage].
  double score;

  /// Legacy historical candidate. Never authorizes familiarity or teasing.
  RelationshipStage stage;

  /// Recomputed from source-valid conversation memory after every mount.
  /// These derived values are deliberately not restored from the legacy row.
  RelationshipExpressionStage expressionStage =
      RelationshipExpressionStage.newlyMet;
  int policyVersion = 0;

  /// Date (day granularity) of the last interaction — for streak math.
  DateTime? lastActiveDate;

  int currentStreak;
  int longestStreak;
  int totalActiveDays;

  /// Whole days since first meeting (inclusive of today → at least 1).
  int daysKnown([DateTime? now]) {
    final ref = now ?? DateTime.now();
    final diff = DateTime(ref.year, ref.month, ref.day)
        .difference(DateTime(firstMetAt.year, firstMetAt.month, firstMetAt.day))
        .inDays;
    return diff < 0 ? 0 : diff + 1;
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': 2,
    'firstMetAt': firstMetAt.millisecondsSinceEpoch,
    'score': score,
    'stage': stage.key,
    if (lastActiveDate != null)
      'lastActiveDate': lastActiveDate!.millisecondsSinceEpoch,
    'currentStreak': currentStreak,
    'longestStreak': longestStreak,
    'totalActiveDays': totalActiveDays,
  };

  factory RelationshipState.fromJson(Map<String, Object?> json) =>
      RelationshipState(
        firstMetAt: DateTime.fromMillisecondsSinceEpoch(
          (json['firstMetAt'] as num?)?.toInt() ??
              DateTime.now().millisecondsSinceEpoch,
        ),
        score: (json['score'] as num?)?.toDouble() ?? 0,
        stage: RelationshipStage.fromKey(json['stage'] as String?),
        lastActiveDate: json['lastActiveDate'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(
                (json['lastActiveDate'] as num).toInt(),
              ),
        currentStreak: (json['currentStreak'] as num?)?.toInt() ?? 0,
        longestStreak: (json['longestStreak'] as num?)?.toInt() ?? 0,
        totalActiveDays: (json['totalActiveDays'] as num?)?.toInt() ?? 0,
      );
}
