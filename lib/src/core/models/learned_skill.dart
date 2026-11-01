/// One step inside a learned skill — a JS fragment plus a millisecond
/// delay to wait *before* running it.  The delay is what lets the agent
/// chain things like "wink left, pause, wink right" without needing
/// JS-side async (the runtime doesn't support real Promises).
class LearnedStep {
  final int delayMs;
  final String code;

  const LearnedStep({this.delayMs = 0, required this.code});

  Map<String, Object?> toJson() => {'delay_ms': delayMs, 'code': code};

  factory LearnedStep.fromJson(Map<String, Object?> j) => LearnedStep(
    delayMs: (j['delay_ms'] as num?)?.toInt() ?? 0,
    code: (j['code'] as String?) ?? '',
  );
}

/// A skill the agent has acquired at runtime — either from the user
/// teaching it ("learned to wink both eyes alternately") or, eventually,
/// from a peer agent over the network.  Persisted to sembast so it
/// survives restarts.
class LearnedSkill {
  /// Short, machine-friendly identifier — auto-generated from the name.
  /// e.g. 'wink_both' for 'wink both eyes alternately'.  Used as the
  /// storage key.
  final String id;

  /// Human-readable name shown in prompts + UI ("wink both eyes alternately").
  final String name;

  /// Keywords / phrases the agent should match to fire this skill, e.g.
  /// ["wink both", "blink both eyes", "alternate wink"].  Included in the
  /// system prompt so the LLM knows when to invoke it.
  final List<String> triggers;

  /// Ordered list of (delay, code) steps to execute on invoke().
  final List<LearnedStep> steps;

  /// Free-form description the LLM writes — explains what the skill does
  /// in one sentence.  Surfaces in the system prompt cheatsheet.
  final String summary;

  /// Who taught it: 'user' for direct instruction, or another agent's
  /// userId for peer-shared skills (future P2P phase).
  final String teacherId;

  final DateTime createdAt;

  /// Times this skill has been invoked — useful for the UI to surface
  /// "favorite tricks" and for an LRU eviction policy later.
  int useCount;

  LearnedSkill({
    required this.id,
    required this.name,
    required this.triggers,
    required this.steps,
    required this.summary,
    this.teacherId = 'user',
    DateTime? createdAt,
    this.useCount = 0,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'triggers': triggers,
    'steps': steps.map((s) => s.toJson()).toList(),
    'summary': summary,
    'teacher_id': teacherId,
    'created_at': createdAt.toIso8601String(),
    'use_count': useCount,
  };

  factory LearnedSkill.fromJson(Map<String, Object?> j) => LearnedSkill(
    id: (j['id'] as String?) ?? '',
    name: (j['name'] as String?) ?? '',
    triggers: ((j['triggers'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList(),
    steps: ((j['steps'] as List?) ?? const [])
        .whereType<Map>()
        .map((m) => LearnedStep.fromJson(m.cast<String, Object?>()))
        .toList(),
    summary: (j['summary'] as String?) ?? '',
    teacherId: (j['teacher_id'] as String?) ?? 'user',
    createdAt:
        DateTime.tryParse((j['created_at'] as String?) ?? '') ?? DateTime.now(),
    useCount: (j['use_count'] as num?)?.toInt() ?? 0,
  );
}
