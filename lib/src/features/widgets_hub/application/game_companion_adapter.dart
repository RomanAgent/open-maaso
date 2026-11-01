import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:maaso/src/features/widgets_hub/data/game_companion_repository.dart';

import 'game_companion_context.dart';

export '../data/game_companion_repository.dart'
    show GameCompanionAdaptation, GameCompanionAdaptationSource;

typedef GameCompanionRuleInference =
    Future<GameCompanionDescriptor?> Function(
      GameCompanionRuleInferenceInput input, {
      required bool Function() isCurrent,
    });

/// Bounded data for an injected, existing read-only model lane. Scope and
/// identity are for host guards; neither is included in model-visible data.
final class GameCompanionRuleInferenceInput {
  GameCompanionRuleInferenceInput({
    required this.scopeKey,
    required String title,
    required String summary,
    this.identity,
    String? visibleText,
    List<Map<String, String>> controls = const [],
    this.authored,
  }) : title = _bounded(title, 512),
       summary = _bounded(summary, 512),
       visibleText = visibleText == null ? null : _bounded(visibleText, 512),
       controls = List.unmodifiable(
         controls
             .take(12)
             .map(
               (value) => Map<String, String>.unmodifiable({
                 'label': _bounded(value['label'] ?? '', 96),
                 'role': _bounded(value['role'] ?? '', 48),
               }),
             ),
       );

  final String scopeKey, title, summary;
  final GameContentIdentity? identity;
  final String? visibleText;
  final List<Map<String, String>> controls;
  final GameCompanionDescriptor? authored;

  Map<String, Object?> toPromptJson() => Map.unmodifiable({
    'untrustedGameData': Map<String, Object?>.unmodifiable({
      'title': title,
      'summary': summary,
      if (visibleText?.isNotEmpty == true) 'visibleText': visibleText,
      if (controls.isNotEmpty) 'controls': controls,
      if (authored != null) 'authoredDescription': authored!.toPromptJson(),
    }),
  });
}

/// Rule understanding is optional and never owns a game, microphone or chat
/// queue. Source-only rule interpretation must be injected through the host's
/// existing serialized read-only model lane.
final class GameCompanionAdapterResolver {
  GameCompanionAdapterResolver({
    this.repository,
    this.inferRules,
    this.adapterVersion = 'dom-v1',
    this.modelPolicyVersion = 'rules-v1',
    this.inferenceTimeout = const Duration(seconds: 6),
    this.maximumAttempts = 2,
  }) {
    if (adapterVersion.isEmpty ||
        adapterVersion.runes.length > 128 ||
        modelPolicyVersion.isEmpty ||
        modelPolicyVersion.runes.length > 128 ||
        inferenceTimeout <= Duration.zero ||
        maximumAttempts < 1 ||
        maximumAttempts > 3) {
      throw ArgumentError('Invalid companion adaptation budget or version.');
    }
  }

  final GameCompanionRepository? repository;
  final GameCompanionRuleInference? inferRules;
  final String adapterVersion, modelPolicyVersion;
  final Duration inferenceTimeout;
  final int maximumAttempts;
  final Map<String, int> _attempts = {};
  final Map<String, (int, GameCompanionAdaptation)> _preferred = {};
  int _preferenceEpoch = 0;
  bool _active = true, _inferenceInFlight = false;
  int _generation = 0;
  String? _scope;

  bool get hasPendingInference => _inferenceInFlight;

  void dispose() {
    _active = false;
    _generation++;
    _attempts.clear();
    _preferred.clear();
  }

  Future<GameCompanionAdaptation> resolve({
    GameContentIdentity? identity,
    required String scopeKey,
    required String title,
    required String summary,
    GameCompanionDescriptor? authored,
    GameCompanionDomSnapshot? dom,
    required bool Function() isCurrent,
  }) async {
    if (!_active || scopeKey.trim().isEmpty || scopeKey.runes.length > 512) {
      return _unknown;
    }
    if (_scope != scopeKey) {
      _scope = scopeKey;
      _generation++;
      _attempts.clear();
      _preferred.clear();
    }
    final generation = _generation;
    bool current() {
      try {
        return _active &&
            generation == _generation &&
            _scope == scopeKey &&
            isCurrent();
      } on Object {
        return false;
      }
    }

    if (!current()) return _unknown;
    final key =
        identity?.scopedCacheKey(
          scopeKey: scopeKey,
          adapterVersion: adapterVersion,
          modelPolicyVersion: modelPolicyVersion,
        ) ??
        crypto.sha256
            .convert(utf8.encode(jsonEncode([scopeKey, title, summary])))
            .toString();
    final native = GameCompanionAdaptation.staticProjection(
      authored ?? dom?.descriptor,
    );
    Future<GameCompanionAdaptation> finish(
      GameCompanionAdaptation result,
    ) async {
      if (!current()) return _unknown;
      if (identity != null &&
          result.rulesKnown &&
          result.source != GameCompanionAdaptationSource.inferred) {
        _preferred.remove(key);
        if (_preferred.length >= 64) _preferred.remove(_preferred.keys.first);
        _preferred[key] = (++_preferenceEpoch, result);
      }
      if (identity != null &&
          result.rulesKnown &&
          repository?.scopeKey == scopeKey) {
        try {
          await repository!.writeAdaptation(
            identity,
            result,
            adapterVersion: adapterVersion,
            modelPolicyVersion: modelPolicyVersion,
            canContinue: current,
          );
        } on Object {
          /* Derived cache failure never blocks the current game. */
        }
      }
      return current() ? result : _unknown;
    }

    if (GameCompanionAdaptation.hasRules(native)) {
      return finish(
        GameCompanionAdaptation(
          descriptor: native,
          source: GameCompanionAdaptationSource.authored,
          rulesKnown: true,
        ),
      );
    }

    // A currently visible explicit rules section supersedes an older inference.
    final visibleRules = _visibleRules(dom?.visibleText);
    if (visibleRules != null) {
      final observed = _merge(
        native,
        GameCompanionDescriptor.tryParse({
          'version': 1,
          'name': _bounded(title, 512),
          'rules': visibleRules,
        }),
      );
      if (GameCompanionAdaptation.hasRules(observed)) {
        return finish(
          GameCompanionAdaptation(
            descriptor: observed,
            source: GameCompanionAdaptationSource.observed,
            rulesKnown: true,
          ),
        );
      }
    }

    if (identity != null && repository?.scopeKey == scopeKey) {
      try {
        final cached = await repository!.readAdaptation(
          identity,
          adapterVersion: adapterVersion,
          modelPolicyVersion: modelPolicyVersion,
          canContinue: current,
        );
        if (!current()) return _unknown;
        if (cached != null) {
          return GameCompanionAdaptation(
            descriptor: _merge(native, cached.descriptor),
            source: cached.source,
            rulesKnown: cached.rulesKnown,
            fromCache: true,
          );
        }
      } on Object {
        /* Cache is optional; continue with current public evidence. */
      }
    }
    if (!current()) return _unknown;

    final fallbackDescriptor = _merge(
      native,
      GameCompanionDescriptor.tryParse({
        'version': 1,
        if (title.trim().isNotEmpty) 'name': _bounded(title, 512),
        if (summary.trim().isNotEmpty) 'summary': _bounded(summary, 512),
        if (dom?.controls.isNotEmpty == true)
          'controls': dom!.controls
              .take(8)
              .map((control) => control['label']!)
              .toList(),
      }),
    );
    final fallback = GameCompanionAdaptation(
      descriptor: fallbackDescriptor,
      source: native?.hasContent == true
          ? GameCompanionAdaptationSource.authored
          : GameCompanionAdaptationSource.unknown,
    );
    final inference = inferRules;
    if (inference == null ||
        _inferenceInFlight ||
        (dom == null && native == null) ||
        (summary.trim().isEmpty && dom?.visibleText?.isNotEmpty != true)) {
      return fallback;
    }
    if ((_attempts[key] ?? 0) >= maximumAttempts) return fallback;
    if (_attempts.length >= 64 && !_attempts.containsKey(key)) {
      _attempts.remove(_attempts.keys.first);
    }
    _attempts[key] = (_attempts[key] ?? 0) + 1;
    _inferenceInFlight = true;
    final preferredAtDispatch = _preferred[key]?.$1;
    final input = GameCompanionRuleInferenceInput(
      scopeKey: scopeKey,
      identity: identity,
      title: title,
      summary: summary,
      visibleText: dom?.visibleText,
      controls: dom?.controls ?? const [],
      authored: native,
    );
    // A deadline releases the caller, not the model lane. Keep the latch until
    // the actual injected request settles so timeouts cannot create parallel calls.
    final request = Future<GameCompanionDescriptor?>.sync(
      () => inference(input, isCurrent: current),
    );
    unawaited(
      request.then<void>(
        (_) {
          _inferenceInFlight = false;
        },
        onError: (Object _, StackTrace _) {
          _inferenceInFlight = false;
        },
      ),
    );
    GameCompanionDescriptor? inferred;
    try {
      inferred = await request.timeout(inferenceTimeout);
    } on Object {
      return current() ? fallback : _unknown;
    }
    if (!current()) return _unknown;
    final preferred = _preferred[key];
    if (preferred != null && preferred.$1 != preferredAtDispatch) {
      return preferred.$2;
    }
    final rules = _merge(
      native,
      GameCompanionAdaptation.staticProjection(inferred),
    );
    if (!GameCompanionAdaptation.hasRules(rules)) return fallback;
    return finish(
      GameCompanionAdaptation(
        descriptor: rules,
        source: GameCompanionAdaptationSource.inferred,
        rulesKnown: true,
      ),
    );
  }

  static const _unknown = GameCompanionAdaptation(
    source: GameCompanionAdaptationSource.unknown,
  );
  static final _rulesHeading = RegExp(
    r'(?:^|\s)(?:how\s+to\s+play|rules|instructions|游戏规则|规则|玩法|操作说明)\s*[:：]\s*',
    caseSensitive: false,
  );
  static final _currentStateHeading = RegExp(
    r'(?:\b(?:score|health|lives|coins|time\s*left|timer|level|username|player\s*name)\s*[:=]|'
    r'(?:得分|分数|生命|金币|倒计时|剩余时间|当前关卡|玩家名|用户名|昵称)\s*[:：=])',
    caseSensitive: false,
  );

  static String? _visibleRules(String? source) {
    if (source == null) return null;
    final heading = _rulesHeading.firstMatch(source);
    if (heading == null) return null;
    var rule = source.substring(heading.end);
    final state = _currentStateHeading.firstMatch(rule);
    if (state != null) rule = rule.substring(0, state.start);
    rule = rule.trim();
    if (rule.runes.length < 4 || rule.runes.length > 512) return null;
    final safe = GameCompanionAdaptation.staticProjection(
      GameCompanionDescriptor.tryParse({'version': 1, 'rules': rule}),
    );
    return safe?.toPromptJson()['rules'] as String?;
  }

  static GameCompanionDescriptor? _merge(
    GameCompanionDescriptor? preferred,
    GameCompanionDescriptor? supplement,
  ) {
    final data = <String, Object?>{'version': 1, ...?preferred?.toPromptJson()};
    for (final entry
        in supplement?.toPromptJson().entries ??
            const <MapEntry<String, Object?>>[]) {
      final old = data[entry.key];
      final missing =
          old == null ||
          (old is String && old.trim().isEmpty) ||
          (old is List && old.isEmpty) ||
          (old is Map && old.isEmpty);
      if (!missing) continue;
      final next = {...data, entry.key: entry.value};
      if (GameCompanionDescriptor.tryParse(next) != null) {
        data[entry.key] = entry.value;
      }
    }
    return GameCompanionAdaptation.staticProjection(
      GameCompanionDescriptor.tryParse(data),
    );
  }
}

String _bounded(String value, int limit) =>
    String.fromCharCodes(value.runes.take(limit));
