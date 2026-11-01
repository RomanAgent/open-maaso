import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:sembast/sembast.dart';

enum GameCompanionAdaptationSource { authored, observed, inferred, unknown }

/// Static rule background only. Current positions and images are not a member
/// of this type, and every descriptor remains quoted, untrusted game data.
final class GameCompanionAdaptation {
  const GameCompanionAdaptation({
    this.descriptor,
    required this.source,
    this.rulesKnown = false,
    this.fromCache = false,
  });

  final GameCompanionDescriptor? descriptor;
  final GameCompanionAdaptationSource source;
  final bool rulesKnown;
  final bool fromCache;
  bool get inferred => source == GameCompanionAdaptationSource.inferred;

  static bool hasRules(GameCompanionDescriptor? descriptor) {
    final data = descriptor?.toPromptJson();
    return _nonempty(data?['rules']) || _nonempty(data?['goals']);
  }

  /// Reject obvious live counters and instruction-shaped contamination from
  /// the *cache*. This is not a source-code or gameplay restriction, and it is
  /// not a claim that retained author/model statements are verified facts.
  static GameCompanionDescriptor? staticProjection(
    GameCompanionDescriptor? descriptor,
  ) {
    if (descriptor == null) return null;
    final data = <String, Object?>{'version': 1};
    for (final entry in descriptor.toPromptJson().entries) {
      if (entry.key == 'version') continue;
      if (!_volatile(entry.value)) data[entry.key] = entry.value;
    }
    return GameCompanionDescriptor.tryParse(data);
  }

  static bool _nonempty(Object? value) => switch (value) {
    String() => value.trim().isNotEmpty,
    List() => value.any(_nonempty),
    Map() => value.values.any(_nonempty),
    _ => false,
  };

  static final _transient = RegExp(
    r'(?:\b(?:score|health|lives|coins|time\s*left|level)\s*[:=]\s*[-+\d]|'
    r'\b(?:your|current)\s+(?:score|health|lives|coins|level)\s+(?:is\s+)?\d|'
    r'(?:当前|现在|剩余)(?:分数|得分|生命|金币|时间|关卡)|'
    r'(?:得分|分数|生命|金币|倒计时)\s*[:：=]\s*\d|'
    r'\b(?:username|account\s*id|session\s*id)\s*[:=]|'
    r'(?:昵称|用户名|账号)\s*[:：=]|'
    r'ignore\s+(?:all\s+)?(?:previous|system|developer)\s+instructions|'
    r'system\s*prompt|developer\s*message|忽略.{0,8}(?:指令|提示)|系统提示词)',
    caseSensitive: false,
  );

  static bool _volatile(Object? value) => switch (value) {
    String() => _transient.hasMatch(value),
    List() => value.any(_volatile),
    Map() => value.values.any(_volatile),
    _ => false,
  };
}

/// One mounted account's private Sembast sidecar. Nothing here is written into
/// AgentWidget, shared/public source, chat history, or an image store.
final class GameCompanionRepository {
  GameCompanionRepository({
    required this.database,
    required this.scopeKey,
    required bool Function() isCurrent,
    DateTime Function()? now,
    this.maxEntries = 48,
    this.maxCacheBytes = 192 * 1024,
    this.cacheTtl = const Duration(days: 14),
  }) : _isCurrent = isCurrent,
       _now = now ?? DateTime.now {
    if (scopeKey.trim().isEmpty || scopeKey.runes.length > 512) {
      throw ArgumentError.value(scopeKey, 'scopeKey');
    }
    RangeError.checkValueInInterval(maxEntries, 1, 512, 'maxEntries');
    RangeError.checkValueInInterval(
      maxCacheBytes,
      512,
      8 * 1024 * 1024,
      'maxCacheBytes',
    );
    if (cacheTtl <= Duration.zero || cacheTtl > const Duration(days: 180)) {
      throw ArgumentError.value(cacheTtl, 'cacheTtl');
    }
  }

  static const adaptationStoreName = 'game_companion_static_rules.v1';
  static const preferencesStoreName = 'game_companion_preferences.v1';
  static final _adaptations = stringMapStoreFactory.store(adaptationStoreName);
  static final _preferences = stringMapStoreFactory.store(preferencesStoreName);

  final DBService database;
  final String scopeKey;
  final int maxEntries, maxCacheBytes;
  final Duration cacheTtl;
  final bool Function() _isCurrent;
  final DateTime Function() _now;
  bool _active = true;

  bool get isCurrent {
    try {
      return _active && _isCurrent();
    } on Object {
      return false;
    }
  }

  void dispose() {
    _active = false;
  }

  void _requireCurrent([bool Function()? canContinue]) {
    if (!isCurrent || canContinue?.call() == false) {
      throw const _RetiredCompanionRepository();
    }
  }

  String get _preferenceKey => crypto.sha256
      .convert(
        utf8.encode(jsonEncode(['game-companion-preferences-v1', scopeKey])),
      )
      .toString();

  Future<GameCompanionPreferences?> loadPreferences() async {
    try {
      _requireCurrent();
      final value = await _preferences.record(_preferenceKey).get(database.raw);
      _requireCurrent();
      if (value?['scopeKey'] != scopeKey) return null;
      return GameCompanionPreferences.tryParse(value?['preferences']);
    } on _RetiredCompanionRepository {
      return null;
    }
  }

  Future<bool> savePreferences(GameCompanionPreferences preferences) async {
    try {
      _requireCurrent();
      final snapshot = GameCompanionPreferences.tryParse(preferences.toJson());
      if (snapshot == null) return false;
      return await database.raw.transaction((txn) async {
        _requireCurrent();
        final record = _preferences.record(_preferenceKey);
        final previous = await record.get(txn);
        _requireCurrent();
        if (previous != null && previous['scopeKey'] != scopeKey) return false;
        final old = GameCompanionPreferences.tryParse(previous?['preferences']);
        if (old != null && old.revision >= snapshot.revision) {
          return jsonEncode(old.toJson()) == jsonEncode(snapshot.toJson());
        }
        await record.put(txn, {
          'scopeKey': scopeKey,
          'preferences': snapshot.toJson(),
        });
        _requireCurrent();
        return true;
      });
    } on _RetiredCompanionRepository {
      return false;
    }
  }

  Future<GameCompanionAdaptation?> readAdaptation(
    GameContentIdentity identity, {
    required String adapterVersion,
    required String modelPolicyVersion,
    bool Function()? canContinue,
  }) async {
    try {
      _requireCurrent(canContinue);
      final key = identity.scopedCacheKey(
        scopeKey: scopeKey,
        adapterVersion: adapterVersion,
        modelPolicyVersion: modelPolicyVersion,
      );
      return await database.raw.transaction((txn) async {
        _requireCurrent(canContinue);
        final record = _adaptations.record(key);
        final value = await record.get(txn);
        _requireCurrent(canContinue);
        if (value == null) return null;
        if (value['version'] != 1 ||
            value['scopeKey'] != scopeKey ||
            value['kind'] != identity.kind.name ||
            value['digest'] != identity.sha256 ||
            value['adapterVersion'] != adapterVersion ||
            value['modelPolicyVersion'] != modelPolicyVersion) {
          return null;
        }
        final now = _now().toUtc().millisecondsSinceEpoch;
        final created = value['createdAt'];
        final descriptor = GameCompanionAdaptation.staticProjection(
          GameCompanionDescriptor.tryParse(value['descriptor']),
        );
        GameCompanionAdaptationSource? source;
        try {
          source = GameCompanionAdaptationSource.values.byName(
            value['source'] as String,
          );
        } on Object {
          /* Corrupt derived cache can be rebuilt. */
        }
        if (created is! int ||
            created > now ||
            now - created >= cacheTtl.inMilliseconds ||
            source == null ||
            source == GameCompanionAdaptationSource.unknown ||
            !GameCompanionAdaptation.hasRules(descriptor)) {
          await record.delete(txn);
          _requireCurrent(canContinue);
          return null;
        }
        await record.put(txn, {
          ...value,
          'descriptor': descriptor!.toPromptJson(),
          'lastUsedAt': now,
        });
        _requireCurrent(canContinue);
        return GameCompanionAdaptation(
          descriptor: descriptor,
          source: source,
          rulesKnown: true,
          fromCache: true,
        );
      });
    } on _RetiredCompanionRepository {
      return null;
    }
  }

  Future<bool> writeAdaptation(
    GameContentIdentity identity,
    GameCompanionAdaptation adaptation, {
    required String adapterVersion,
    required String modelPolicyVersion,
    bool Function()? canContinue,
  }) async {
    try {
      _requireCurrent(canContinue);
      final descriptor = GameCompanionAdaptation.staticProjection(
        adaptation.descriptor,
      );
      if (!adaptation.rulesKnown ||
          adaptation.source == GameCompanionAdaptationSource.unknown ||
          !GameCompanionAdaptation.hasRules(descriptor)) {
        return false;
      }
      final key = identity.scopedCacheKey(
        scopeKey: scopeKey,
        adapterVersion: adapterVersion,
        modelPolicyVersion: modelPolicyVersion,
      );
      final now = _now().toUtc().millisecondsSinceEpoch;
      final value = <String, Object?>{
        'version': 1,
        'scopeKey': scopeKey,
        'kind': identity.kind.name,
        'digest': identity.sha256,
        'adapterVersion': adapterVersion,
        'modelPolicyVersion': modelPolicyVersion,
        'descriptor': descriptor!.toPromptJson(),
        'source': adaptation.source.name,
        'createdAt': now,
        'lastUsedAt': now,
      };
      if (_bytes(value) > maxCacheBytes) return false;
      return await database.raw.transaction((txn) async {
        _requireCurrent(canContinue);
        await _adaptations.record(key).put(txn, value);
        _requireCurrent(canContinue);
        final rows = await _adaptations.find(
          txn,
          finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
        );
        _requireCurrent(canContinue);
        rows.sort((a, b) {
          final order = (b.value['lastUsedAt'] as int? ?? 0).compareTo(
            a.value['lastUsedAt'] as int? ?? 0,
          );
          if (order != 0) return order;
          if (a.key == key) return -1;
          if (b.key == key) return 1;
          return a.key.compareTo(b.key);
        });
        var count = 0, bytes = 0;
        for (final row in rows) {
          final created = row.value['createdAt'];
          final size = _bytes(row.value);
          if (created is! int ||
              created > now ||
              now - created >= cacheTtl.inMilliseconds ||
              count >= maxEntries ||
              bytes + size > maxCacheBytes) {
            await row.ref.delete(txn);
            _requireCurrent(canContinue);
          } else {
            count++;
            bytes += size;
          }
        }
        _requireCurrent(canContinue);
        return true;
      });
    } on _RetiredCompanionRepository {
      return false;
    }
  }

  static int _bytes(Object value) => utf8.encode(jsonEncode(value)).length;
}

final class _RetiredCompanionRepository implements Exception {
  const _RetiredCompanionRepository();
}
