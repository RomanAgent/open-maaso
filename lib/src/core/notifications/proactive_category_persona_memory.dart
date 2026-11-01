import 'dart:convert';

import 'package:maaso/src/core/services/agent_persona_memory_store.dart';
import 'package:sembast/sembast.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Remembered owner configuration, separate from OS permission and consent.
/// Missing fields are application defaults, never invented user choices.
final class ProactiveCategoryPersonaMemory {
  const ProactiveCategoryPersonaMemory({
    this.revision = 0,
    this.greetings,
    this.randomCheckIns,
    this.greetingsSource,
    this.randomCheckInsSource,
  });

  final int revision;
  final bool? greetings;
  final bool? randomCheckIns;
  final String? greetingsSource;
  final String? randomCheckInsSource;

  bool get isEmpty => greetings == null && randomCheckIns == null;

  ProactiveCategoryPersonaMemory withChoice({
    bool? greetings,
    bool? randomCheckIns,
  }) => ProactiveCategoryPersonaMemory(
    revision: revision + 1,
    greetings: greetings ?? this.greetings,
    randomCheckIns: randomCheckIns ?? this.randomCheckIns,
    greetingsSource: greetings == null ? greetingsSource : 'user_choice',
    randomCheckInsSource: randomCheckIns == null
        ? randomCheckInsSource
        : 'user_choice',
  );

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'revision': revision,
    if (greetings != null)
      'greetings': {'enabled': greetings, 'source': greetingsSource},
    if (randomCheckIns != null)
      'randomCheckIns': {
        'enabled': randomCheckIns,
        'source': randomCheckInsSource,
      },
  };

  factory ProactiveCategoryPersonaMemory.fromJson(Map<String, Object?> json) {
    const keys = {'schemaVersion', 'revision', 'greetings', 'randomCheckIns'};
    final revision = json['revision'];
    if (json.keys.any((key) => !keys.contains(key)) ||
        json['schemaVersion'] != 1 ||
        revision is! int ||
        revision < 0 ||
        revision > 0x1fffffffffffff) {
      throw const FormatException('invalid proactive category memory');
    }
    (bool?, String?) choice(String key) {
      if (!json.containsKey(key)) return (null, null);
      final value = json[key];
      if (value is! Map ||
          value.length != 2 ||
          value['enabled'] is! bool ||
          !{'user_choice', 'legacy_configuration'}.contains(value['source'])) {
        throw const FormatException('invalid proactive category choice');
      }
      return (value['enabled'] as bool, value['source'] as String);
    }

    final greetings = choice('greetings');
    final random = choice('randomCheckIns');
    return ProactiveCategoryPersonaMemory(
      revision: revision,
      greetings: greetings.$1,
      greetingsSource: greetings.$2,
      randomCheckIns: random.$1,
      randomCheckInsSource: random.$2,
    );
  }
}

abstract interface class ProactiveCategoryPersonaMemoryStore {
  String get accountScopeDigest;
  Future<ProactiveCategoryPersonaMemory?> read();
  Future<void> write(ProactiveCategoryPersonaMemory value);
}

final class SembastProactiveCategoryPersonaMemoryStore
    implements ProactiveCategoryPersonaMemoryStore {
  SembastProactiveCategoryPersonaMemoryStore({
    required Database database,
    required this.accountScopeDigest,
  }) : _memory = AgentPersonaMemoryStore(
         database: database,
         accountScopeDigest: accountScopeDigest,
         kind: AgentPersonaMemoryKind.proactiveCategories,
         normalizePayload: (value) =>
             ProactiveCategoryPersonaMemory.fromJson(value).toJson(),
       );

  @override
  final String accountScopeDigest;
  final AgentPersonaMemoryStore _memory;

  @override
  Future<ProactiveCategoryPersonaMemory?> read() async {
    final row = await _memory.read();
    return row == null ? null : ProactiveCategoryPersonaMemory.fromJson(row);
  }

  @override
  Future<void> write(ProactiveCategoryPersonaMemory value) =>
      _memory.write(value.toJson());
}

/// Pins the old device-wide categories to one exact account before copying.
/// The pinned payload survives a crash, and cannot be claimed by another user.
/// A stored true may have come from old defaults, so its provenance stays legacy.
final class ProactiveCategoryPersonaLegacyMigration {
  ProactiveCategoryPersonaLegacyMigration(this.preferences);

  static const journalKey = 'agent_persona_categories.legacy_migration.v1';
  static const legacyKey = 'notification_preferences.v1';
  final SharedPreferences preferences;

  Future<ProactiveCategoryPersonaMemory?> claim(String accountDigest) async {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountDigest)) {
      throw ArgumentError('invalid category memory account');
    }
    final journal = _readJournal();
    if (journal != null) {
      if (journal['accountScopeDigest'] != accountDigest ||
          journal['complete'] == true) {
        return null;
      }
      return ProactiveCategoryPersonaMemory.fromJson(
        Map<String, Object?>.from(journal['payload']! as Map),
      );
    }
    final raw = preferences.getString(legacyKey);
    if (raw == null || raw.isEmpty) return null;
    final decoded = jsonDecode(raw);
    if (decoded is! Map) {
      throw const FormatException('invalid legacy notification categories');
    }
    bool? choice(String key) {
      if (!decoded.containsKey(key)) return null;
      final value = decoded[key];
      if (value is! bool) {
        throw const FormatException('invalid legacy notification category');
      }
      return value;
    }

    final greetings = choice('greetingsEnabled');
    final random = choice('randomCheckInsEnabled');
    final memory = ProactiveCategoryPersonaMemory(
      greetings: greetings,
      randomCheckIns: random,
      greetingsSource: greetings == null ? null : 'legacy_configuration',
      randomCheckInsSource: random == null ? null : 'legacy_configuration',
    );
    if (memory.isEmpty) return null;
    if (!await preferences.setString(
      journalKey,
      jsonEncode({
        'schemaVersion': 1,
        'accountScopeDigest': accountDigest,
        'complete': false,
        'payload': memory.toJson(),
      }),
    )) {
      throw StateError('category_memory_migration_claim_failed');
    }
    return memory;
  }

  Future<bool> completeOwnedClaim(String accountDigest) async {
    final journal = _readJournal();
    if (journal == null || journal['accountScopeDigest'] != accountDigest) {
      return false;
    }
    if (journal['complete'] == true) return true;
    if (!await preferences.setString(
      journalKey,
      jsonEncode({
        'schemaVersion': 1,
        'accountScopeDigest': accountDigest,
        'complete': true,
      }),
    )) {
      throw StateError('category_memory_migration_complete_failed');
    }
    return true;
  }

  Map<String, Object?>? _readJournal() {
    final raw = preferences.getString(journalKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      final keys = {
        'schemaVersion',
        'accountScopeDigest',
        'complete',
        if (value is Map && value['complete'] != true) 'payload',
      };
      if (value is! Map ||
          value.length != keys.length ||
          value.keys.any((key) => !keys.contains(key)) ||
          value['schemaVersion'] != 1 ||
          value['complete'] is! bool ||
          value['accountScopeDigest'] is! String ||
          !RegExp(
            r'^[a-f0-9]{64}$',
          ).hasMatch(value['accountScopeDigest'] as String) ||
          (value['complete'] != true && value['payload'] is! Map)) {
        throw const FormatException('invalid category migration journal');
      }
      final result = Map<String, Object?>.from(value);
      if (result['complete'] != true) {
        ProactiveCategoryPersonaMemory.fromJson(
          Map<String, Object?>.from(result['payload']! as Map),
        );
      }
      return result;
    } on Object {
      throw const FormatException('invalid category migration journal');
    }
  }
}
