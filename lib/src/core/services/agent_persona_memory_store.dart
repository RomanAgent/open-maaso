import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:sembast/sembast.dart';

/// Private, explicit owner choices. These are not inferred conversation facts,
/// public persona metadata, relationship evidence, or model-writable notes.
enum AgentPersonaMemoryKind {
  conversationStyle,
  proactiveContact,
  proactiveCategories,
}

/// The single durable source for the owner's remembered interaction choices.
/// Existing preference services remain the typed, write-before-publish facade.
/// A valid legacy row moves atomically; malformed rows remain recoverable.
final class AgentPersonaMemoryStore {
  AgentPersonaMemoryStore({
    required this.database,
    required this.accountScopeDigest,
    required this.kind,
    this.legacyStoreName,
    this.legacyRecordKey,
    required this.normalizePayload,
  }) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeDigest)) {
      throw ArgumentError('invalid persona memory account');
    }
    if ((legacyStoreName == null) != (legacyRecordKey == null)) {
      throw ArgumentError('legacy persona memory requires store and key');
    }
  }

  static const storeName = 'agent_persona_memories.v1';
  static final _memories = StoreRef<String, Map<String, Object?>>(storeName);

  final Database database;
  final String accountScopeDigest;
  final AgentPersonaMemoryKind kind;
  final String? legacyStoreName;
  final String? legacyRecordKey;
  final Map<String, Object?> Function(Map<String, Object?>) normalizePayload;

  String get recordKey => '$accountScopeDigest:self:${kind.name}';
  StoreRef<String, Map<String, Object?>>? get _legacy => legacyStoreName == null
      ? null
      : StoreRef<String, Map<String, Object?>>(legacyStoreName!);
  String get _source => kind == AgentPersonaMemoryKind.proactiveCategories
      ? 'owner_configuration'
      : 'user_choice';

  Future<Map<String, Object?>?> read() => database.transaction((txn) async {
    final record = await _memories.record(recordKey).get(txn);
    final legacy = _legacy;
    final previous = await legacy?.record(legacyRecordKey!).get(txn);
    if (record != null) {
      final current = _decode(record);
      if (previous != null) {
        try {
          _normalize(previous);
          await legacy!.record(legacyRecordKey!).delete(txn);
        } on FormatException {
          _reportInvalidLegacy();
        }
      }
      return current;
    }
    if (previous == null) return null;
    final Map<String, Object?> payload;
    try {
      payload = _normalize(previous);
    } on FormatException {
      _reportInvalidLegacy();
      rethrow;
    }
    await _memories.record(recordKey).put(txn, _encode(payload));
    await legacy!.record(legacyRecordKey!).delete(txn);
    return payload;
  });

  Future<void> write(Map<String, Object?> payload) async {
    final normalized = _normalize(payload);
    await database.transaction((txn) async {
      await _memories.record(recordKey).put(txn, _encode(normalized));
      final legacy = _legacy;
      final previous = await legacy?.record(legacyRecordKey!).get(txn);
      if (previous == null) return;
      try {
        _normalize(previous);
        await legacy!.record(legacyRecordKey!).delete(txn);
      } on FormatException {
        _reportInvalidLegacy();
      }
    });
  }

  Map<String, Object?> _encode(Map<String, Object?> payload) => {
    'schemaVersion': 1,
    'accountScopeDigest': accountScopeDigest,
    'agentId': 'self',
    'kind': kind.name,
    'source': _source,
    'payload': payload,
  };

  Map<String, Object?> _decode(Map<String, Object?> record) {
    const fields = {
      'schemaVersion',
      'accountScopeDigest',
      'agentId',
      'kind',
      'source',
      'payload',
    };
    if (record.length != fields.length ||
        record.keys.any((key) => !fields.contains(key)) ||
        record['schemaVersion'] != 1 ||
        record['accountScopeDigest'] != accountScopeDigest ||
        record['agentId'] != 'self' ||
        record['kind'] != kind.name ||
        record['source'] != _source ||
        record['payload'] is! Map) {
      throw const FormatException('invalid explicit persona memory');
    }
    try {
      return _normalize(Map<String, Object?>.from(record['payload']! as Map));
    } on Object {
      throw const FormatException('invalid explicit persona memory payload');
    }
  }

  Map<String, Object?> _normalize(Map<String, Object?> value) {
    try {
      return normalizePayload(value);
    } on Object {
      throw const FormatException('invalid explicit persona memory payload');
    }
  }

  void _reportInvalidLegacy() => TurnTrace.event(
    'agent.persona_memory.legacy_invalid',
    details: 'kind=${kind.name} retained=true',
  );
}
