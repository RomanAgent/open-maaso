class GeneSkillEntry {
  final String id;
  final String name;
  final String summary;
  final List<String> triggers;
  final String sourceAgent;

  GeneSkillEntry({
    required this.id,
    required this.name,
    required this.summary,
    this.triggers = const [],
    this.sourceAgent = '',
  });

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'summary': summary,
    'triggers': triggers,
    'sourceAgent': sourceAgent,
  };

  factory GeneSkillEntry.fromJson(Map<String, Object?> json) => GeneSkillEntry(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    summary: json['summary'] as String? ?? '',
    triggers:
        (json['triggers'] as List?)?.map((e) => e.toString()).toList() ??
        const [],
    sourceAgent: json['sourceAgent'] as String? ?? '',
  );
}

class AgentGene {
  final String agentToken;
  final String name;
  final String gender;
  final String voiceId;
  final DateTime birthDate;
  final DateTime deathDate;
  final String memoryDigest;
  final List<GeneSkillEntry> skills;
  final List<String> personalityTraits;
  final List<Map<String, Object?>> keyEpisodes;
  final String signature;

  AgentGene({
    required this.agentToken,
    required this.name,
    required this.gender,
    required this.voiceId,
    required this.birthDate,
    required this.deathDate,
    required this.memoryDigest,
    this.skills = const [],
    this.personalityTraits = const [],
    this.keyEpisodes = const [],
    this.signature = '',
  });

  Map<String, Object?> toJson() => {
    'agentToken': agentToken,
    'name': name,
    'gender': gender,
    'voiceId': voiceId,
    'birthDate': birthDate.toIso8601String(),
    'deathDate': deathDate.toIso8601String(),
    'memoryDigest': memoryDigest,
    'skills': skills.map((s) => s.toJson()).toList(),
    'personalityTraits': personalityTraits,
    'keyEpisodes': keyEpisodes,
    'signature': signature,
  };

  factory AgentGene.fromJson(Map<String, Object?> json) => AgentGene(
    agentToken: json['agentToken'] as String? ?? '',
    name: json['name'] as String? ?? '',
    gender: json['gender'] as String? ?? '',
    voiceId: json['voiceId'] as String? ?? '',
    birthDate: _requiredGeneDate(json, 'birthDate'),
    deathDate: _requiredGeneDate(json, 'deathDate'),
    memoryDigest: json['memoryDigest'] as String? ?? '',
    skills:
        (json['skills'] as List?)
            ?.map((e) => GeneSkillEntry.fromJson(e as Map<String, Object?>))
            .toList() ??
        const [],
    personalityTraits:
        (json['personalityTraits'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const [],
    keyEpisodes:
        (json['keyEpisodes'] as List?)
            ?.whereType<Map<String, Object?>>()
            .toList() ??
        const [],
    signature: json['signature'] as String? ?? '',
  );
}

DateTime _requiredGeneDate(Map<String, Object?> json, String field) {
  final raw = json[field];
  if (raw is! String || raw.trim().isEmpty) {
    throw FormatException('AgentGene.$field must be an ISO-8601 string');
  }
  final parsed = DateTime.tryParse(raw);
  if (parsed == null) {
    throw FormatException('AgentGene.$field is not a valid ISO-8601 date');
  }
  return parsed;
}
