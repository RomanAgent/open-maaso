/// Versioned, public-safe personality metadata used by routing and social
/// expression. Private memories and relationship state deliberately do not
/// belong in this object.
class AgentPersonaSpec {
  const AgentPersonaSpec({
    this.schemaVersion = currentSchemaVersion,
    this.professionTitle,
    this.specialties = const <String>[],
    this.interests = const <String>[],
    this.socialStyle = const AgentSocialStyle(),
    this.avoidTopics = const <String>[],
  });

  static const empty = AgentPersonaSpec();
  static const currentSchemaVersion = 1;
  static const promptCapsuleMaxCharacters = 256;
  static const maxRoutingPriorTerms = 6;
  static const maxRoutingTermCharacters = 48;
  static const maxListItems = 12;
  static const maxValueCharacters = 80;

  final int schemaVersion;
  final String? professionTitle;
  final List<String> specialties;
  final List<String> interests;
  final AgentSocialStyle socialStyle;
  final List<String> avoidTopics;

  bool get isNeutral =>
      _optionalText(professionTitle) == null &&
      _normalizedList(specialties).isEmpty &&
      _normalizedList(interests).isEmpty &&
      socialStyle.isDefault &&
      _normalizedList(avoidTopics).isEmpty;

  /// Profession is a weak preference signal, never a capability gate.
  Set<String> get routingPriorTerms {
    final candidates = <String>[
      ?_optionalText(professionTitle),
      ...specialties,
    ];
    return Set<String>.unmodifiable(
      _normalizedList(
        candidates,
        maxItems: maxRoutingPriorTerms,
        maxCharacters: maxRoutingTermCharacters,
      ),
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': schemaVersion,
    'professionTitle': ?_optionalText(professionTitle),
    'specialties': _normalizedList(specialties),
    'interests': _normalizedList(interests),
    'socialStyle': socialStyle.toJson(),
    'avoidTopics': _normalizedList(avoidTopics),
  };

  factory AgentPersonaSpec.fromJson(Object? value) {
    final json = _stringKeyedMap(value);
    if (json == null) return empty;
    final schemaVersion = _schemaVersion(json['schemaVersion']);
    if (schemaVersion != currentSchemaVersion) return empty;
    return AgentPersonaSpec(
      schemaVersion: schemaVersion!,
      professionTitle: _optionalText(json['professionTitle']),
      specialties: _stringList(json['specialties']),
      interests: _stringList(json['interests']),
      socialStyle: AgentSocialStyle.fromJson(json['socialStyle']),
      avoidTopics: _stringList(json['avoidTopics']),
    );
  }

  /// A fixed-budget projection suitable for the first model request.
  ///
  /// It intentionally contains no master profile, relationship milestones,
  /// private memory, installed-skill instructions, or account identifiers.
  String toCapsule({int maxCharacters = promptCapsuleMaxCharacters}) {
    if (maxCharacters < 64) {
      throw ArgumentError.value(
        maxCharacters,
        'maxCharacters',
        'must be at least 64',
      );
    }
    if (isNeutral) return '';
    final normalizedSpecialties = _normalizedList(specialties);
    final normalizedInterests = _normalizedList(interests);
    final normalizedAvoidTopics = _normalizedList(avoidTopics);
    final parts = <String>[
      if (_optionalText(professionTitle) case final value?)
        'profession=${_capsuleValue(value)}',
      if (normalizedSpecialties.isNotEmpty)
        'specialties=${normalizedSpecialties.take(5).map(_capsuleValue).join(',')}',
      if (normalizedInterests.isNotEmpty)
        'interests=${normalizedInterests.take(4).map(_capsuleValue).join(',')}',
      if (!socialStyle.isDefault) 'social=${socialStyle.toCapsule()}',
      if (normalizedAvoidTopics.isNotEmpty)
        'avoid=${normalizedAvoidTopics.take(3).map(_capsuleValue).join(',')}',
    ];
    final capsule = parts.join('; ');
    if (capsule.length <= maxCharacters) return capsule;
    return _truncate(capsule, maxCharacters).trimRight();
  }

  static String? _optionalText(Object? value) {
    if (value is! String) return null;
    final text = _singleLine(value, maxCharacters: maxValueCharacters);
    return text.isEmpty ? null : text;
  }

  static List<String> _stringList(Object? value) => value is List
      ? _normalizedList(value.whereType<String>())
      : const <String>[];

  static List<String> _normalizedList(
    Iterable<String> values, {
    int maxItems = maxListItems,
    int maxCharacters = maxValueCharacters,
  }) {
    final seen = <String>{};
    final result = <String>[];
    for (final raw in values) {
      final value = _singleLine(raw, maxCharacters: maxCharacters);
      if (value.isEmpty) continue;
      final key = value.toLowerCase();
      if (!seen.add(key)) continue;
      result.add(value);
      if (result.length == maxItems) break;
    }
    return List<String>.unmodifiable(result);
  }

  static Map<String, Object?>? _stringKeyedMap(Object? value) {
    if (value is! Map) return null;
    final result = <String, Object?>{};
    for (final entry in value.entries) {
      final key = entry.key;
      if (key is String) result[key] = entry.value;
    }
    return result;
  }

  static int? _schemaVersion(Object? value) {
    if (value == null) return currentSchemaVersion;
    if (value is! num || !value.isFinite) return null;
    final version = value.toInt();
    return value == version ? version : null;
  }

  static String _capsuleValue(String value) => _singleLine(
    value.replaceAll(RegExp(r'[;=]'), ' '),
    maxCharacters: maxValueCharacters,
  );

  static String _singleLine(
    String value, {
    int maxCharacters = maxValueCharacters,
  }) {
    final normalized = value
        .replaceAll(RegExp(r'[\u0000-\u001F\u007F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.length <= maxCharacters) return normalized;
    return _truncate(normalized, maxCharacters).trimRight();
  }

  static String _truncate(String value, int maxCharacters) {
    var end = maxCharacters;
    final lastCodeUnit = value.codeUnitAt(end - 1);
    if (lastCodeUnit >= 0xD800 && lastCodeUnit <= 0xDBFF) end -= 1;
    return value.substring(0, end);
  }
}

class AgentSocialStyle {
  const AgentSocialStyle({
    this.initiative = 0.45,
    this.humor = 0.45,
    this.slangIntensity = 0.2,
    this.commentFrequency = 0.15,
  });

  final double initiative;
  final double humor;
  final double slangIntensity;
  final double commentFrequency;

  bool get isDefault =>
      _number(initiative, 0.45) == 0.45 &&
      _number(humor, 0.45) == 0.45 &&
      _number(slangIntensity, 0.2) == 0.2 &&
      _number(commentFrequency, 0.15) == 0.15;

  Map<String, Object?> toJson() => <String, Object?>{
    'initiative': _number(initiative, 0.45),
    'humor': _number(humor, 0.45),
    'slangIntensity': _number(slangIntensity, 0.2),
    'commentFrequency': _number(commentFrequency, 0.15),
  };

  factory AgentSocialStyle.fromJson(Object? value) {
    final json = AgentPersonaSpec._stringKeyedMap(value);
    if (json == null) return const AgentSocialStyle();
    return AgentSocialStyle(
      initiative: _number(json['initiative'], 0.45),
      humor: _number(json['humor'], 0.45),
      slangIntensity: _number(json['slangIntensity'], 0.2),
      commentFrequency: _number(json['commentFrequency'], 0.15),
    );
  }

  String toCapsule() => <String>[
    'initiative=${_number(initiative, 0.45).toStringAsFixed(2)}',
    'humor=${_number(humor, 0.45).toStringAsFixed(2)}',
    'slang=${_number(slangIntensity, 0.2).toStringAsFixed(2)}',
    'comments=${_number(commentFrequency, 0.15).toStringAsFixed(2)}',
  ].join(',');

  static double _number(Object? value, double fallback) {
    final number = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    return _unit(number?.isFinite == true ? number! : fallback);
  }

  static double _unit(double value) => value.clamp(0.0, 1.0).toDouble();
}
