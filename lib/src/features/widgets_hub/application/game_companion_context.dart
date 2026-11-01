import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;

/// Optional author-provided rules. These are quoted data, never instructions or
/// permissions. A rejected descriptor never rejects its game or DOM snapshot.
final class GameCompanionDescriptor {
  GameCompanionDescriptor._(this._data);

  static const maxBytes = 3 * 1024;
  static const _fields = {
    'version',
    'name',
    'summary',
    'goals',
    'rules',
    'controls',
    'stateSemantics',
    'eventSemantics',
    'hintScope',
  };
  final Map<String, Object?> _data;

  String? get name => _data['name'] as String?;
  String? get summary => _data['summary'] as String?;
  bool get hasContent => _data.length > 1;
  Map<String, Object?> toPromptJson() => _data;

  static GameCompanionDescriptor? tryParse(Object? value) {
    try {
      final data = _freezeMap(value, maxBytes: maxBytes, maxDepth: 5);
      if (data['version'] is! int ||
          data['version'] != 1 ||
          data.keys.any((key) => !_fields.contains(key))) {
        return null;
      }
      for (final key in ['name', 'summary', 'hintScope']) {
        if (data.containsKey(key) && !_text(data[key], 512)) return null;
      }
      for (final key in ['goals', 'rules', 'controls']) {
        if (!data.containsKey(key)) continue;
        final item = data[key];
        if (_text(item, 512)) continue;
        if (item is! List ||
            item.length > 8 ||
            item.any((v) => !_text(v, 256))) {
          return null;
        }
      }
      for (final key in ['stateSemantics', 'eventSemantics']) {
        if (!data.containsKey(key)) continue;
        final item = data[key];
        if (_text(item, 512)) continue;
        if (item is! Map ||
            item.length > 16 ||
            item.entries.any(
              (e) => !_text(e.key, 64) || !_text(e.value, 256),
            )) {
          return null;
        }
      }
      return GameCompanionDescriptor._(data);
    } on Object {
      return null;
    }
  }
}

/// Dedicated MaasoGameVoice wire family. Its revision is independent of the
/// game.state/game.event counter; none of its fields can select a host identity.
final class GameCompanionDomSnapshot {
  GameCompanionDomSnapshot._({
    required this.revision,
    required this.visibleText,
    required this.controls,
    required this.descriptor,
  });

  static const maxWireBytes = 8 * 1024;
  static const maxSnapshotBytes = 6 * 1024;
  final int revision;
  final String? visibleText;
  final List<Map<String, String>> controls;
  final GameCompanionDescriptor? descriptor;

  static GameCompanionDomSnapshot? parseMessage(String source) {
    if (source.length > maxWireBytes ||
        utf8.encode(source).length > maxWireBytes) {
      return null;
    }
    try {
      return fromEnvelope(jsonDecode(source));
    } on Object {
      return null;
    }
  }

  static GameCompanionDomSnapshot? fromEnvelope(Object? value) {
    try {
      // The wire bound also applies to an invalid optional descriptor. Its
      // individual semantic bounds are checked separately so other evidence
      // remains usable when only that descriptor is invalid.
      final envelope = _freezeMap(
        value,
        maxBytes: maxWireBytes,
        maxStringRunes: maxWireBytes,
        maxDepth: 16,
        maxNodes: 1024,
      );
      if (envelope.length != 3 ||
          envelope['kind'] != 'companion.snapshot' ||
          !_revision(envelope['revision']) ||
          envelope['state'] is! Map) {
        return null;
      }
      final state = envelope['state'] as Map<String, Object?>;
      if (state['version'] is! int ||
          state['version'] != 1 ||
          state.keys.any(
            (key) => !const {
              'version',
              'visibleText',
              'controls',
              'descriptor',
            }.contains(key),
          ) ||
          _jsonBytes(state) > maxSnapshotBytes) {
        return null;
      }
      final text = state['visibleText'];
      if (state.containsKey('visibleText') && !_text(text, 512)) return null;
      final rawControls = state['controls'];
      if (state.containsKey('controls') && rawControls is! List) return null;
      final controls = <Map<String, String>>[];
      if (rawControls is List) {
        if (rawControls.length > 12) return null;
        for (final raw in rawControls) {
          if (raw is! Map ||
              raw.length != 2 ||
              !_text(raw['label'], 96) ||
              !_text(raw['role'], 48)) {
            return null;
          }
          controls.add(
            Map.unmodifiable({
              'label': raw['label'] as String,
              'role': raw['role'] as String,
            }),
          );
        }
      }
      return GameCompanionDomSnapshot._(
        revision: envelope['revision'] as int,
        visibleText: text as String?,
        controls: List.unmodifiable(controls),
        descriptor: GameCompanionDescriptor.tryParse(state['descriptor']),
      );
    } on Object {
      return null;
    }
  }

  Map<String, Object?> toPromptJson() => Map.unmodifiable({
    'version': 1,
    if (visibleText != null) 'visibleText': visibleText,
    if (controls.isNotEmpty) 'controls': controls,
    if (descriptor != null) 'descriptor': descriptor!.toPromptJson(),
  });
}

/// Constructed by the mounted player, never decoded from authored JSON.
final class GameCompanionSessionKey {
  GameCompanionSessionKey({
    required this.scopeKey,
    required this.playerId,
    required this.documentGeneration,
    required this.sessionGeneration,
  }) {
    _requireText(scopeKey, 512);
    _requireText(playerId, 512);
    _requireRevision(documentGeneration);
    _requireRevision(sessionGeneration);
  }
  final String scopeKey, playerId;
  final int documentGeneration, sessionGeneration;

  @override
  bool operator ==(Object other) =>
      other is GameCompanionSessionKey &&
      scopeKey == other.scopeKey &&
      playerId == other.playerId &&
      documentGeneration == other.documentGeneration &&
      sessionGeneration == other.sessionGeneration;
  @override
  int get hashCode =>
      Object.hash(scopeKey, playerId, documentGeneration, sessionGeneration);
}

enum GameContentIdentityKind {
  ownedSource,
  publishedRenderDocument,
  verifiedBundle,
}

final class GameContentIdentity {
  GameContentIdentity({required this.kind, required String sha256})
    : sha256 = sha256.toLowerCase() {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(this.sha256)) {
      throw ArgumentError('A SHA-256 content digest is required.');
    }
  }
  final GameContentIdentityKind kind;
  final String sha256;

  String scopedCacheKey({
    required String scopeKey,
    required String adapterVersion,
    required String modelPolicyVersion,
  }) {
    _requireText(scopeKey, 512);
    _requireText(adapterVersion, 128);
    _requireText(modelPolicyVersion, 128);
    return crypto.sha256
        .convert(
          utf8.encode(
            jsonEncode([
              'game-companion-adaptation-v1',
              scopeKey,
              kind.name,
              sha256,
              adapterVersion,
              modelPolicyVersion,
            ]),
          ),
        )
        .toString();
  }

  @override
  bool operator ==(Object other) =>
      other is GameContentIdentity &&
      kind == other.kind &&
      sha256 == other.sha256;
  @override
  int get hashCode => Object.hash(kind, sha256);
}

enum GameObservationSource { structured, dom, vision, user }

/// Source says how facts were obtained, not whether author/image text is trusted.
final class GameObservationEvidence {
  GameObservationEvidence({
    required this.id,
    required this.source,
    required DateTime capturedAt,
    required DateTime receivedAt,
    required Map<String, Object?> data,
    this.inferred = false,
    this.summary = '',
  }) : capturedAt = capturedAt.toUtc(),
       receivedAt = receivedAt.toUtc(),
       data = _freezeMap(data, maxBytes: 6 * 1024, maxDepth: 8, maxNodes: 512) {
    _requireText(id, 160);
    if (!_text(summary, 512) || this.receivedAt.isBefore(this.capturedAt)) {
      throw ArgumentError('Invalid observation summary or capture time.');
    }
  }
  final String id, summary;
  final GameObservationSource source;
  final DateTime capturedAt, receivedAt;
  final Map<String, Object?> data;
  final bool inferred;

  bool isFresh({required DateTime now, required Duration maxAge}) =>
      maxAge > Duration.zero &&
      !now.isBefore(capturedAt) &&
      now.difference(capturedAt) < maxAge;

  Map<String, Object?> toPromptJson() => Map.unmodifiable({
    'id': id,
    'source': source.name,
    'inferred': inferred,
    'capturedAt': capturedAt.toIso8601String(),
    'receivedAt': receivedAt.toIso8601String(),
    if (summary.isNotEmpty) 'summary': summary,
    'data': data,
  });
}

enum GameCompanionMomentScope { currentPosition, occurredEvent }

final class GameCompanionMoment {
  GameCompanionMoment({
    required this.id,
    required this.sessionKey,
    required this.roundGeneration,
    this.positionRevision,
    required this.scope,
    required this.kind,
    required this.summary,
    required DateTime observedAt,
    required DateTime expiresAt,
  }) : observedAt = observedAt.toUtc(),
       expiresAt = expiresAt.toUtc() {
    _requireText(id, 160);
    _requireText(kind, 96);
    _requireText(summary, 512);
    _requireRevision(roundGeneration);
    if (positionRevision != null) _requireRevision(positionRevision);
    if (!this.expiresAt.isAfter(this.observedAt) ||
        (scope == GameCompanionMomentScope.currentPosition &&
            positionRevision == null)) {
      throw ArgumentError(
        'A moment needs a lifetime and position-dependent revision.',
      );
    }
  }
  final String id, kind, summary;
  final GameCompanionSessionKey sessionKey;
  final int roundGeneration;

  /// A semantic position revision, not a screenshot/frame or DOM counter.
  final int? positionRevision;
  final GameCompanionMomentScope scope;
  final DateTime observedAt, expiresAt;

  bool isValidFor({
    required GameCompanionSessionKey sessionKey,
    required int roundGeneration,
    required int? positionRevision,
    required DateTime now,
  }) =>
      this.sessionKey == sessionKey &&
      this.roundGeneration == roundGeneration &&
      !now.isBefore(observedAt) &&
      now.isBefore(expiresAt) &&
      (scope == GameCompanionMomentScope.occurredEvent ||
          this.positionRevision == positionRevision);

  Map<String, Object?> toPromptJson() => Map.unmodifiable({
    'id': id,
    'kind': kind,
    'summary': summary,
    'scope': scope.name,
    'roundGeneration': roundGeneration,
    'observedAt': observedAt.toIso8601String(),
    'expiresAt': expiresAt.toIso8601String(),
  });
}

enum GameCompanionTalkativeness { quiet, balanced, chatty }

enum GameCompanionHintPolicy { onRequest, askFirst, smallHints }

/// Host/user preferences. Observation parsers never accept this object.
final class GameCompanionPreferences {
  const GameCompanionPreferences({
    required this.enabled,
    this.talkativeness = GameCompanionTalkativeness.balanced,
    this.hintPolicy = GameCompanionHintPolicy.onRequest,
    this.revision = 0,
  }) : assert(revision >= 0 && revision <= 9007199254740991);
  final bool enabled;
  final GameCompanionTalkativeness talkativeness;
  final GameCompanionHintPolicy hintPolicy;
  final int revision;

  GameCompanionPreferences copyWith({
    bool? enabled,
    GameCompanionTalkativeness? talkativeness,
    GameCompanionHintPolicy? hintPolicy,
  }) {
    if ((enabled ?? this.enabled) == this.enabled &&
        (talkativeness ?? this.talkativeness) == this.talkativeness &&
        (hintPolicy ?? this.hintPolicy) == this.hintPolicy) {
      return this;
    }
    _requireRevision(revision + 1);
    return GameCompanionPreferences(
      enabled: enabled ?? this.enabled,
      talkativeness: talkativeness ?? this.talkativeness,
      hintPolicy: hintPolicy ?? this.hintPolicy,
      revision: revision + 1,
    );
  }

  Map<String, Object?> toPromptJson() => Map.unmodifiable({
    'enabled': enabled,
    'talkativeness': talkativeness.name,
    'hintPolicy': hintPolicy.name,
  });
  Map<String, Object?> toJson() =>
      Map.unmodifiable({'version': 1, ...toPromptJson(), 'revision': revision});

  static GameCompanionPreferences? tryParse(Object? value) {
    if (value is! Map ||
        value.length != 5 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['enabled'] is! bool ||
        !_revision(value['revision'])) {
      return null;
    }
    try {
      return GameCompanionPreferences(
        enabled: value['enabled'] as bool,
        talkativeness: GameCompanionTalkativeness.values.byName(
          value['talkativeness'] as String,
        ),
        hintPolicy: GameCompanionHintPolicy.values.byName(
          value['hintPolicy'] as String,
        ),
        revision: value['revision'] as int,
      );
    } on Object {
      return null;
    }
  }
}

enum GameCompanionDeliveryStage {
  /// A reply published by the app; not proof it was spoken or read.
  published,
  started,
  completed,
  interrupted,
}

enum GameCompanionSpeaker { user, assistant }

final class GameCompanionExchange {
  const GameCompanionExchange._({
    required this.id,
    required this.speaker,
    required this.text,
    required this.at,
    required this.truncated,
    this.delivery,
    this.endedAt,
    this.momentId,
  });
  final String id, text;
  final GameCompanionSpeaker speaker;
  final DateTime at;
  final bool truncated;
  final GameCompanionDeliveryStage? delivery;
  final DateTime? endedAt;
  final String? momentId;

  Map<String, Object?> toPromptJson() => Map.unmodifiable({
    'id': id,
    'speaker': speaker.name,
    'text': text,
    'at': at.toIso8601String(),
    if (truncated) 'excerpt': true,
    if (delivery != null) 'delivery': delivery!.name,
    if (endedAt != null) 'endedAt': endedAt!.toIso8601String(),
    if (momentId != null) 'momentId': momentId,
  });
}

/// Ephemeral session history, not a persistent user-memory source. Call only
/// from real human input, app-published replies or correlated speech receipts;
/// never merely on generation or audio enqueue.
final class GameCompanionDialogueBuffer {
  GameCompanionDialogueBuffer({
    this.maxEntries = 12,
    this.maxTextRunes = 600,
    this.maxTotalRunes = 4096,
  }) {
    if (maxEntries < 1 ||
        maxEntries > 32 ||
        maxTextRunes < 1 ||
        maxTextRunes > 1024 ||
        maxTotalRunes < 1 ||
        maxTotalRunes > 8192) {
      throw ArgumentError('Dialogue limits must be positive and bounded.');
    }
  }
  final int maxEntries, maxTextRunes, maxTotalRunes;
  final List<GameCompanionExchange> _entries = [];
  List<GameCompanionExchange> get snapshot => List.unmodifiable(_entries);
  List<String> get recentAssistantTexts => List.unmodifiable(
    _entries
        .where((e) => e.speaker == GameCompanionSpeaker.assistant)
        .map((e) => e.text),
  );
  Set<String> get spokenMomentIds => Set.unmodifiable(
    _entries
        .where(
          (e) =>
              e.speaker == GameCompanionSpeaker.assistant &&
              e.delivery != GameCompanionDeliveryStage.published &&
              e.momentId != null,
        )
        .map((e) => e.momentId!),
  );

  bool recordUser({
    required String id,
    required String text,
    required DateTime at,
  }) {
    if (!_canAdd(id, text)) return false;
    _append(id: id, text: text, at: at, speaker: GameCompanionSpeaker.user);
    return true;
  }

  bool recordSpeech({
    required String id,
    required String text,
    required DateTime at,
    required GameCompanionDeliveryStage stage,
    String? momentId,
  }) {
    if (stage == GameCompanionDeliveryStage.started ||
        stage == GameCompanionDeliveryStage.published) {
      if (!_canAdd(id, text) ||
          (momentId != null && !_nonemptyText(momentId, 160))) {
        return false;
      }
      _append(
        id: id,
        text: text,
        at: at,
        speaker: GameCompanionSpeaker.assistant,
        delivery: stage,
        momentId: momentId,
      );
      return true;
    }
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return false;
    final previous = _entries[index];
    final excerpt = _excerpt(text);
    if (previous.speaker != GameCompanionSpeaker.assistant ||
        previous.delivery != GameCompanionDeliveryStage.started ||
        previous.text != excerpt ||
        previous.momentId != momentId ||
        at.isBefore(previous.at)) {
      return false;
    }
    _entries[index] = GameCompanionExchange._(
      id: previous.id,
      speaker: previous.speaker,
      text: previous.text,
      at: previous.at,
      truncated: previous.truncated,
      delivery: stage,
      endedAt: at.toUtc(),
      momentId: previous.momentId,
    );
    return true;
  }

  bool _canAdd(String id, String text) =>
      _nonemptyText(id, 160) &&
      text.trim().isNotEmpty &&
      !_entries.any((e) => e.id == id);
  String _excerpt(String text) => String.fromCharCodes(
    text.runes.take(
      maxTextRunes < maxTotalRunes ? maxTextRunes : maxTotalRunes,
    ),
  );
  void _append({
    required String id,
    required String text,
    required DateTime at,
    required GameCompanionSpeaker speaker,
    GameCompanionDeliveryStage? delivery,
    String? momentId,
  }) {
    final excerpt = _excerpt(text);
    _entries.add(
      GameCompanionExchange._(
        id: id,
        speaker: speaker,
        text: excerpt,
        at: at.toUtc(),
        truncated: excerpt != text,
        delivery: delivery,
        momentId: momentId,
      ),
    );
    var size = _entries.fold<int>(0, (total, e) => total + e.text.runes.length);
    while (_entries.length > maxEntries || size > maxTotalRunes) {
      size -= _entries.removeAt(0).text.runes.length;
    }
  }

  List<Map<String, Object?>> toPromptJson() =>
      List.unmodifiable(_entries.map((entry) => entry.toPromptJson()));
  void clear() => _entries.clear();
}

/// An immutable snapshot shared by automatic commentary and human questions.
/// Session identity stays host-only; older material is explicitly history.
final class GameCompanionContext {
  GameCompanionContext({
    required this.sessionKey,
    required this.roundGeneration,
    required this.preferences,
    this.descriptor,
    Iterable<GameObservationEvidence> evidence = const [],
    Iterable<GameCompanionMoment> recentMoments = const [],
    Iterable<GameCompanionExchange> recentConversation = const [],
  }) : evidence = _tail(evidence, 6),
       recentMoments = _tail(recentMoments, 8),
       recentConversation = _tail(recentConversation, 12) {
    _requireRevision(roundGeneration);
    if (this.recentMoments.any((moment) => moment.sessionKey != sessionKey)) {
      throw ArgumentError('Moments must belong to the same mounted session.');
    }
  }
  static const maxPromptBytes = 16 * 1024;
  final GameCompanionSessionKey sessionKey;
  final int roundGeneration;
  final GameCompanionPreferences preferences;
  final GameCompanionDescriptor? descriptor;
  final List<GameObservationEvidence> evidence;
  final List<GameCompanionMoment> recentMoments;
  final List<GameCompanionExchange> recentConversation;

  Map<String, Object?> toPromptJson() {
    final facts = evidence.map((e) => e.toPromptJson()).toList();
    final moments = recentMoments.map((m) => m.toPromptJson()).toList();
    final dialogue = recentConversation.map((e) => e.toPromptJson()).toList();
    var omitted = false;
    Map<String, Object?> value() => {
      'version': 1,
      'roundGeneration': roundGeneration,
      'preferences': preferences.toPromptJson(),
      if (descriptor != null) 'rules': descriptor!.toPromptJson(),
      'evidence': facts,
      'recentMoments': moments,
      'recentConversation': dialogue,
      if (omitted) 'olderContextOmitted': true,
    };
    while (_jsonBytes(value()) > maxPromptBytes) {
      omitted = true;
      if (facts.length > 1) {
        facts.removeAt(0);
      } else if (dialogue.length > 1) {
        dialogue.removeAt(0);
      } else if (moments.isNotEmpty) {
        moments.removeAt(0);
      } else {
        // Individual item bounds guarantee one fact, descriptor and exchange
        // fit. Keep this fail-closed check if those bounds change in future.
        throw StateError('Companion prompt exceeds its bounded item contract.');
      }
    }
    return _freezeMap(
      value(),
      maxBytes: maxPromptBytes,
      maxDepth: 12,
      maxNodes: 4096,
      maxStringRunes: 8192,
    );
  }
}

bool _text(Object? value, int maxRunes) =>
    value is String && value.runes.length <= maxRunes;
bool _nonemptyText(Object? value, int maxRunes) =>
    _text(value, maxRunes) && (value as String).trim().isNotEmpty;
bool _revision(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
void _requireRevision(Object? value) {
  if (!_revision(value)) throw ArgumentError('Invalid host revision.');
}

void _requireText(String text, int maxRunes) {
  if (!_nonemptyText(text, maxRunes)) {
    throw ArgumentError('Invalid bounded host text.');
  }
}

int _jsonBytes(Object? value) => utf8.encode(jsonEncode(value)).length;
List<T> _tail<T>(Iterable<T> values, int maximum) {
  final list = values.toList(growable: false);
  return List.unmodifiable(
    list.skip(list.length > maximum ? list.length - maximum : 0),
  );
}

Map<String, Object?> _freezeMap(
  Object? value, {
  required int maxBytes,
  int maxStringRunes = 512,
  int maxDepth = 8,
  int maxNodes = 512,
}) {
  var nodes = 0;
  Object? visit(Object? item, int depth) {
    if (++nodes > maxNodes || depth > maxDepth) {
      throw const FormatException('companion_json_bounds');
    }
    if (item == null || item is bool) return item;
    if (item is num && item.isFinite) return item;
    if (item is String && item.runes.length <= maxStringRunes) return item;
    if (item is List) {
      return List<Object?>.unmodifiable(item.map((v) => visit(v, depth + 1)));
    }
    if (item is Map) {
      final result = <String, Object?>{};
      for (final entry in item.entries) {
        if (!_text(entry.key, 64)) {
          throw const FormatException('companion_json_key');
        }
        result[entry.key as String] = visit(entry.value, depth + 1);
      }
      return Map<String, Object?>.unmodifiable(result);
    }
    throw const FormatException('companion_json_type');
  }

  final result = visit(value, 0);
  if (result is! Map<String, Object?> || _jsonBytes(result) > maxBytes) {
    throw const FormatException('companion_json_size');
  }
  return result;
}
