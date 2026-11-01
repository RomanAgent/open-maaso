/// Semantic category for one long-term memory record.
enum EpisodeKind { episode, fact, preference, relationship, plan, reflection }

/// Provenance class for the source material behind an [Episode].
///
/// Unknown provenance is intentionally split so migrated rows can be audited
/// separately from records created by the current runtime before a typed
/// source is available.
enum EpisodeSourceType {
  runtimeUnknown,
  legacyUnknown,
  conversation,
  explicitSave,
  inherited,
  systemObservation;

  bool get requiresSourceRefs => switch (this) {
    EpisodeSourceType.runtimeUnknown ||
    EpisodeSourceType.legacyUnknown => false,
    _ => true,
  };
}

/// Role of the source that produced a provenance reference.
enum EpisodeSourceOrigin { user, agent, system, imported }

/// Human or policy review state for an [Episode] revision.
enum EpisodeReviewState { pending, accepted, rejected, tombstoned }

/// Retention intent. Enforcement is deliberately outside the v2 codec.
enum EpisodeRetentionClass { transient, standard, durable }

/// Bounded reference to durable source material used to derive an [Episode].
final class EpisodeSourceRef {
  EpisodeSourceRef({
    required this.sourceId,
    required this.sessionId,
    required this.origin,
    required this.contentHash,
  }) {
    _validateBoundedIdentifier(
      sourceId,
      field: 'sourceId',
      maxLength: maxIdentifierLength,
    );
    _validateBoundedIdentifier(
      sessionId,
      field: 'sessionId',
      maxLength: maxIdentifierLength,
    );
    if (!_sha256Pattern.hasMatch(contentHash)) {
      throw ArgumentError.value(
        contentHash,
        'contentHash',
        'must be a lowercase SHA-256 digest',
      );
    }
  }

  static const int maxIdentifierLength = 256;
  static final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

  final String sourceId;
  final String sessionId;
  final EpisodeSourceOrigin origin;
  final String contentHash;

  Map<String, Object?> toJson() => <String, Object?>{
    'sourceId': sourceId,
    'sessionId': sessionId,
    'origin': origin.name,
    'contentHash': contentHash,
  };

  factory EpisodeSourceRef.fromJson(Object? source) {
    if (source is! Map) {
      throw const FormatException('episode source ref is invalid');
    }
    late final Map<String, Object?> json;
    try {
      json = Map<String, Object?>.from(source);
    } on Object {
      throw const FormatException('episode source ref keys are invalid');
    }
    const fields = <String>{'sourceId', 'sessionId', 'origin', 'contentHash'};
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('episode source ref schema is invalid');
    }
    final sourceId = json['sourceId'];
    final sessionId = json['sessionId'];
    final contentHash = json['contentHash'];
    if (sourceId is! String || sessionId is! String || contentHash is! String) {
      throw const FormatException('episode source ref values are invalid');
    }
    try {
      return EpisodeSourceRef(
        sourceId: sourceId,
        sessionId: sessionId,
        origin: _enumByName(
          EpisodeSourceOrigin.values,
          json['origin'],
          'origin',
        ),
        contentHash: contentHash,
      );
    } on ArgumentError catch (error) {
      throw FormatException('episode source ref is invalid: $error');
    }
  }
}

/// L2 long-term episodic memory record.
///
/// One [Episode] represents a single "scene worth remembering" — the agent
/// (or a future consolidation pass) decides what's worth writing. [what] is
/// expected to be a short summary, not the raw transcript.
///
/// [embedding] is filled in asynchronously after persistence. The storage
/// codec is schema-versioned, while [toLegacyJson] remains available for
/// compatibility checks and rollback tooling.
class Episode {
  factory Episode({
    int? id,
    required DateTime when,
    required String what,
    List<String> entities = const [],
    String? emotion,
    double salience = 0.5,
    List<double>? embedding,
    int schemaVersion = currentSchemaVersion,
    String agentId = 'self',
    EpisodeKind kind = EpisodeKind.episode,
    List<EpisodeSourceRef> sourceRefs = const [],
    EpisodeSourceType sourceType = EpisodeSourceType.runtimeUnknown,
    double confidence = 0.5,
    EpisodeReviewState reviewState = EpisodeReviewState.accepted,
    int revision = 1,
    int? supersedesId,
    List<int> contradictionIds = const [],
    DateTime? createdAt,
    DateTime? updatedAt,
    DateTime? lastActivatedAt,
    int activationCount = 0,
    DateTime? expiresAt,
    EpisodeRetentionClass retentionClass = EpisodeRetentionClass.durable,
  }) {
    final resolvedCreatedAt = createdAt ?? when;
    return Episode._(
      id: id,
      when: when,
      what: what,
      entities: entities,
      emotion: emotion,
      salience: salience,
      embedding: embedding,
      schemaVersion: schemaVersion,
      agentId: agentId,
      kind: kind,
      sourceRefs: sourceRefs,
      sourceType: sourceType,
      confidence: confidence,
      reviewState: reviewState,
      revision: revision,
      supersedesId: supersedesId,
      contradictionIds: contradictionIds,
      createdAt: resolvedCreatedAt,
      updatedAt: updatedAt ?? resolvedCreatedAt,
      lastActivatedAt: lastActivatedAt,
      activationCount: activationCount,
      expiresAt: expiresAt,
      retentionClass: retentionClass,
      allowLegacyUnknown: false,
    );
  }

  Episode._({
    required this.id,
    required this.when,
    required this.what,
    required List<String> entities,
    required this.emotion,
    required this.salience,
    required List<double>? embedding,
    required this.schemaVersion,
    required this.agentId,
    required this.kind,
    required List<EpisodeSourceRef> sourceRefs,
    required this.sourceType,
    required this.confidence,
    required this.reviewState,
    required this.revision,
    required this.supersedesId,
    required List<int> contradictionIds,
    required this.createdAt,
    required this.updatedAt,
    required this.lastActivatedAt,
    required this.activationCount,
    required this.expiresAt,
    required this.retentionClass,
    required bool allowLegacyUnknown,
  }) : entities = List<String>.unmodifiable(entities),
       embedding = embedding == null
           ? null
           : List<double>.unmodifiable(embedding),
       sourceRefs = List<EpisodeSourceRef>.unmodifiable(sourceRefs),
       contradictionIds = List<int>.unmodifiable(contradictionIds) {
    _validate(allowLegacyUnknown: allowLegacyUnknown);
  }

  static const int currentSchemaVersion = 2;
  static const int maxSourceRefs = 16;
  static const int maxContradictionIds = 32;
  static const int _maxSafeStoredInt = 0x1fffffffffffff;

  int? id;
  final DateTime when;
  final String what;
  final List<String> entities;
  final String? emotion;
  final double salience;
  List<double>? embedding;

  final int schemaVersion;
  final String agentId;
  final EpisodeKind kind;
  final List<EpisodeSourceRef> sourceRefs;
  final EpisodeSourceType sourceType;
  final double confidence;
  final EpisodeReviewState reviewState;
  final int revision;
  final int? supersedesId;
  final List<int> contradictionIds;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastActivatedAt;
  final int activationCount;
  final DateTime? expiresAt;
  final EpisodeRetentionClass retentionClass;

  /// Canonical v2 storage representation. Database record ids stay in the
  /// Sembast key and are never duplicated in the payload.
  Map<String, Object?> toJson() {
    _validate(allowLegacyUnknown: true);
    return <String, Object?>{
      'schemaVersion': currentSchemaVersion,
      // Kept as a first-class field because EpisodeStore sorts on it.
      'when': when.millisecondsSinceEpoch,
      'what': what,
      'entities': List<String>.of(entities),
      'emotion': emotion,
      'salience': salience,
      'embedding': embedding == null ? null : List<double>.of(embedding!),
      'agentId': agentId,
      'kind': kind.name,
      'sourceRefs': sourceRefs.map((ref) => ref.toJson()).toList(),
      'sourceType': sourceType.name,
      'confidence': confidence,
      'reviewState': reviewState.name,
      'revision': revision,
      'supersedesId': supersedesId,
      'contradictionIds': List<int>.of(contradictionIds),
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
      'lastActivatedAt': lastActivatedAt?.millisecondsSinceEpoch,
      'activationCount': activationCount,
      'expiresAt': expiresAt?.millisecondsSinceEpoch,
      'retentionClass': retentionClass.name,
    };
  }

  /// Exact pre-v2 payload shape for rollback tooling and compatibility tests.
  Map<String, Object?> toLegacyJson() => <String, Object?>{
    'when': when.millisecondsSinceEpoch,
    'what': what,
    'entities': List<String>.of(entities),
    if (emotion != null) 'emotion': emotion,
    'salience': salience,
    if (embedding != null) 'embedding': List<double>.of(embedding!),
  };

  factory Episode.fromJson(
    Map<String, Object?> json, {
    String legacyAgentId = 'self',
  }) {
    if (!json.containsKey('schemaVersion')) {
      return _decodeLegacy(json, legacyAgentId: legacyAgentId);
    }
    if (json['schemaVersion'] != currentSchemaVersion) {
      throw FormatException(
        'unsupported episode schema version: ${json['schemaVersion']}',
      );
    }
    return _decodeV2(json);
  }

  static Episode _decodeLegacy(
    Map<String, Object?> json, {
    required String legacyAgentId,
  }) {
    const fields = <String>{
      'when',
      'what',
      'entities',
      'emotion',
      'salience',
      'embedding',
    };
    if (json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('legacy episode schema is invalid');
    }
    try {
      final when = json['when'] == null
          ? DateTime.fromMillisecondsSinceEpoch(0)
          : _dateFromMilliseconds(json['when'], 'when');
      final what = json['what'];
      final emotion = json['emotion'];
      if (what != null && what is! String) {
        throw const FormatException('legacy episode what is invalid');
      }
      if (emotion != null && emotion is! String) {
        throw const FormatException('legacy episode emotion is invalid');
      }
      final entities = json['entities'] == null
          ? const <String>[]
          : _legacyStringList(json['entities'], 'entities');
      final salience = json['salience'] == null
          ? 0.5
          : _finiteDouble(json['salience'], 'salience');
      final embedding = json['embedding'] == null
          ? null
          : _doubleList(json['embedding'], 'embedding');
      return Episode._(
        id: null,
        when: when,
        what: what as String? ?? '',
        entities: entities,
        emotion: emotion as String?,
        salience: salience,
        embedding: embedding,
        schemaVersion: currentSchemaVersion,
        agentId: legacyAgentId,
        kind: EpisodeKind.episode,
        sourceRefs: const <EpisodeSourceRef>[],
        sourceType: EpisodeSourceType.legacyUnknown,
        confidence: 0.5,
        reviewState: EpisodeReviewState.accepted,
        revision: 1,
        supersedesId: null,
        contradictionIds: const <int>[],
        createdAt: when,
        updatedAt: when,
        lastActivatedAt: null,
        activationCount: 0,
        expiresAt: null,
        retentionClass: EpisodeRetentionClass.durable,
        allowLegacyUnknown: true,
      );
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('legacy episode is invalid: $error');
    }
  }

  static Episode _decodeV2(Map<String, Object?> json) {
    const fields = <String>{
      'schemaVersion',
      'when',
      'what',
      'entities',
      'emotion',
      'salience',
      'embedding',
      'agentId',
      'kind',
      'sourceRefs',
      'sourceType',
      'confidence',
      'reviewState',
      'revision',
      'supersedesId',
      'contradictionIds',
      'createdAt',
      'updatedAt',
      'lastActivatedAt',
      'activationCount',
      'expiresAt',
      'retentionClass',
    };
    if (json.length != fields.length ||
        json.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('episode v2 schema is invalid');
    }
    final what = json['what'];
    final agentId = json['agentId'];
    final emotion = json['emotion'];
    if (what is! String ||
        agentId is! String ||
        (emotion != null && emotion is! String)) {
      throw const FormatException('episode v2 string values are invalid');
    }
    try {
      return Episode._(
        id: null,
        when: _dateFromMilliseconds(json['when'], 'when'),
        what: what,
        entities: _strictStringList(json['entities'], 'entities'),
        emotion: emotion as String?,
        salience: _finiteDouble(json['salience'], 'salience'),
        embedding: json['embedding'] == null
            ? null
            : _doubleList(json['embedding'], 'embedding'),
        schemaVersion: currentSchemaVersion,
        agentId: agentId,
        kind: _enumByName(EpisodeKind.values, json['kind'], 'kind'),
        sourceRefs: _sourceRefList(json['sourceRefs']),
        sourceType: _enumByName(
          EpisodeSourceType.values,
          json['sourceType'],
          'sourceType',
        ),
        confidence: _finiteDouble(json['confidence'], 'confidence'),
        reviewState: _enumByName(
          EpisodeReviewState.values,
          json['reviewState'],
          'reviewState',
        ),
        revision: _requiredInt(json['revision'], 'revision'),
        supersedesId: _optionalPositiveInt(
          json['supersedesId'],
          'supersedesId',
        ),
        contradictionIds: _positiveIntList(
          json['contradictionIds'],
          'contradictionIds',
        ),
        createdAt: _dateFromMilliseconds(json['createdAt'], 'createdAt'),
        updatedAt: _dateFromMilliseconds(json['updatedAt'], 'updatedAt'),
        lastActivatedAt: _optionalDateFromMilliseconds(
          json['lastActivatedAt'],
          'lastActivatedAt',
        ),
        activationCount: _requiredInt(
          json['activationCount'],
          'activationCount',
        ),
        expiresAt: _optionalDateFromMilliseconds(
          json['expiresAt'],
          'expiresAt',
        ),
        retentionClass: _enumByName(
          EpisodeRetentionClass.values,
          json['retentionClass'],
          'retentionClass',
        ),
        allowLegacyUnknown: true,
      );
    } on FormatException {
      rethrow;
    } on ArgumentError catch (error) {
      throw FormatException('episode v2 is invalid: $error');
    }
  }

  void _validate({required bool allowLegacyUnknown}) {
    if (schemaVersion != currentSchemaVersion) {
      throw ArgumentError.value(
        schemaVersion,
        'schemaVersion',
        'must be $currentSchemaVersion',
      );
    }
    if (id != null) _validatePositiveInt(id!, 'id');
    _validateBoundedIdentifier(
      agentId,
      field: 'agentId',
      maxLength: EpisodeSourceRef.maxIdentifierLength,
    );
    _validateUnitInterval(salience, 'salience');
    _validateUnitInterval(confidence, 'confidence');
    _validatePositiveInt(revision, 'revision');
    if (supersedesId != null) {
      _validatePositiveInt(supersedesId!, 'supersedesId');
    }
    if (sourceRefs.length > maxSourceRefs) {
      throw ArgumentError.value(
        sourceRefs.length,
        'sourceRefs',
        'must contain at most $maxSourceRefs entries',
      );
    }
    if (contradictionIds.length > maxContradictionIds) {
      throw ArgumentError.value(
        contradictionIds.length,
        'contradictionIds',
        'must contain at most $maxContradictionIds entries',
      );
    }
    final uniqueContradictions = <int>{};
    for (final contradictionId in contradictionIds) {
      _validatePositiveInt(contradictionId, 'contradictionIds');
      if (!uniqueContradictions.add(contradictionId)) {
        throw ArgumentError.value(
          contradictionIds,
          'contradictionIds',
          'must not contain duplicates',
        );
      }
    }
    if (sourceType.requiresSourceRefs && sourceRefs.isEmpty) {
      throw ArgumentError.value(
        sourceType,
        'sourceType',
        'typed provenance requires at least one source ref',
      );
    }
    if (!sourceType.requiresSourceRefs && sourceRefs.isNotEmpty) {
      throw ArgumentError.value(
        sourceRefs,
        'sourceRefs',
        'unknown provenance must not claim typed source refs',
      );
    }
    if (!allowLegacyUnknown && sourceType == EpisodeSourceType.legacyUnknown) {
      throw ArgumentError.value(
        sourceType,
        'sourceType',
        'legacyUnknown is reserved for decoded legacy rows',
      );
    }
    if (updatedAt.isBefore(createdAt)) {
      throw ArgumentError.value(
        updatedAt,
        'updatedAt',
        'must not be before createdAt',
      );
    }
    if (lastActivatedAt?.isBefore(createdAt) ?? false) {
      throw ArgumentError.value(
        lastActivatedAt,
        'lastActivatedAt',
        'must not be before createdAt',
      );
    }
    if (activationCount < 0 || activationCount > _maxSafeStoredInt) {
      throw ArgumentError.value(
        activationCount,
        'activationCount',
        'must be a non-negative safe integer',
      );
    }
    if (expiresAt?.isBefore(createdAt) ?? false) {
      throw ArgumentError.value(
        expiresAt,
        'expiresAt',
        'must not be before createdAt',
      );
    }
    final vector = embedding;
    if (vector != null && vector.any((value) => !value.isFinite)) {
      throw ArgumentError.value(
        vector,
        'embedding',
        'must contain only finite values',
      );
    }
  }

  static void _validatePositiveInt(int value, String field) {
    if (value < 1 || value > _maxSafeStoredInt) {
      throw ArgumentError.value(
        value,
        field,
        'must be a positive safe integer',
      );
    }
  }
}

void _validateUnitInterval(double value, String field) {
  if (!value.isFinite || value < 0 || value > 1) {
    throw ArgumentError.value(value, field, 'must be finite and within 0..1');
  }
}

void _validateBoundedIdentifier(
  String value, {
  required String field,
  required int maxLength,
}) {
  if (value.isEmpty || value.trim() != value || value.length > maxLength) {
    throw ArgumentError.value(
      value,
      field,
      'must be non-empty, trimmed, and at most $maxLength characters',
    );
  }
}

T _enumByName<T extends Enum>(List<T> values, Object? source, String field) {
  if (source is String) {
    for (final value in values) {
      if (value.name == source) return value;
    }
  }
  throw FormatException('$field is invalid');
}

DateTime _dateFromMilliseconds(Object? source, String field) {
  if (source is! int) throw FormatException('$field is invalid');
  try {
    return DateTime.fromMillisecondsSinceEpoch(source);
  } on RangeError {
    throw FormatException('$field is outside the supported date range');
  }
}

DateTime? _optionalDateFromMilliseconds(Object? source, String field) =>
    source == null ? null : _dateFromMilliseconds(source, field);

double _finiteDouble(Object? source, String field) {
  if (source is! num) throw FormatException('$field is invalid');
  final value = source.toDouble();
  if (!value.isFinite) throw FormatException('$field must be finite');
  return value;
}

int _requiredInt(Object? source, String field) {
  if (source is! int) throw FormatException('$field is invalid');
  return source;
}

int? _optionalPositiveInt(Object? source, String field) {
  if (source == null) return null;
  final value = _requiredInt(source, field);
  Episode._validatePositiveInt(value, field);
  return value;
}

List<String> _strictStringList(Object? source, String field) {
  if (source is! List) throw FormatException('$field is invalid');
  final values = <String>[];
  for (final value in source) {
    if (value is! String) throw FormatException('$field is invalid');
    values.add(value);
  }
  return values;
}

List<String> _legacyStringList(Object? source, String field) {
  if (source is! List) throw FormatException('$field is invalid');
  return source.map((value) => value.toString()).toList(growable: false);
}

List<double> _doubleList(Object? source, String field) {
  if (source is! List) throw FormatException('$field is invalid');
  return source
      .map((value) => _finiteDouble(value, field))
      .toList(growable: false);
}

List<int> _positiveIntList(Object? source, String field) {
  if (source is! List) throw FormatException('$field is invalid');
  final values = <int>[];
  for (final value in source) {
    final parsed = _requiredInt(value, field);
    Episode._validatePositiveInt(parsed, field);
    values.add(parsed);
  }
  return values;
}

List<EpisodeSourceRef> _sourceRefList(Object? source) {
  if (source is! List) {
    throw const FormatException('sourceRefs is invalid');
  }
  return source
      .map<EpisodeSourceRef>(EpisodeSourceRef.fromJson)
      .toList(growable: false);
}
