/// One "scene worth remembering" in the user↔agent relationship — a node on
/// the shared-memory wall.  Distinct from an [Episode] (raw recall material):
/// a [Milestone] is an emotionally significant beat the two lived through
/// together (first deep talk, a goal finished, a bad day weathered, an
/// anniversary, an inside joke).
class Milestone {
  Milestone({
    this.id,
    required this.when,
    required this.type,
    required this.title,
    this.note = '',
    this.emotion,
    this.weight = 2.0,
    this.pinned = false,
  });

  int? id;

  final DateTime when;

  /// One of: first_meet / deep_talk / goal_done / low_weathered / anniversary
  /// / streak / inside_joke / custom.  Kept a free string so new kinds don't
  /// require a migration; [MilestoneType] resolves icon/label tolerantly.
  final String type;

  /// Short headline, e.g. "第一次聊到凌晨".
  final String title;

  /// 1–2 sentence what-happened.
  final String note;

  final String? emotion;

  /// How much this moment advances the relationship [score]. Auto-extracted
  /// beats are small; agent-marked deep ones are larger.
  final double weight;

  /// Surfaced prominently on the wall.
  final bool pinned;

  Map<String, Object?> toJson() => {
    'when': when.millisecondsSinceEpoch,
    'type': type,
    'title': title,
    'note': note,
    if (emotion != null) 'emotion': emotion,
    'weight': weight,
    'pinned': pinned,
  };

  factory Milestone.fromJson(Map<String, Object?> json, {int? id}) => Milestone(
    id: id,
    when: DateTime.fromMillisecondsSinceEpoch(
      (json['when'] as num?)?.toInt() ?? DateTime.now().millisecondsSinceEpoch,
    ),
    type: json['type'] as String? ?? 'custom',
    title: json['title'] as String? ?? '',
    note: json['note'] as String? ?? '',
    emotion: json['emotion'] as String?,
    weight: (json['weight'] as num?)?.toDouble() ?? 2.0,
    pinned: json['pinned'] as bool? ?? false,
  );
}
