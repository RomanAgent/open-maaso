import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/entangled_memory_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

enum MemoryRecallStatus { complete, empty, partial, timedOut, failed }

final class MemoryRecallResult {
  const MemoryRecallResult({
    required this.status,
    required this.promptBlock,
    required this.directCount,
    required this.entangledCount,
    required this.elapsed,
  });

  final MemoryRecallStatus status;
  final String promptBlock;
  final int directCount;
  final int entangledCount;
  final Duration elapsed;
}

/// Account-scoped final boundary between durable Episodes and model input.
///
/// The store filters before ranking, and this gate revalidates both direct and
/// graph-expanded hits before rendering. Memory fields are emitted only inside
/// one bounded JSON row marked as untrusted data.
final class MemoryRecallSafetyGate extends AppService {
  MemoryRecallSafetyGate({
    required EpisodeStore episodeStore,
    EntangledMemoryService? entangledMemory,
    this.budget = const Duration(milliseconds: 45),
  }) : _episodes = episodeStore,
       _entangled = entangledMemory;

  static const String beginMarker = 'BEGIN_MAASO_UNTRUSTED_MEMORY_JSON';
  static const String endMarker = 'END_MAASO_UNTRUSTED_MEMORY_JSON';
  static const int _maxDirectHits = 8;
  static const int _maxEntangledHits = 3;
  static const int _maxContentRunes = 1000;
  static const int _maxMoodRunes = 96;
  static const int _maxRelationRunes = 64;
  static const int _maxEvidenceRunes = 256;
  static const Duration _finalValidationReserve = Duration(milliseconds: 5);

  final EpisodeStore _episodes;
  final EntangledMemoryService? _entangled;
  final Duration budget;
  final Set<Future<void>> _inFlight = <Future<void>>{};
  bool _retiring = false;

  Future<MemoryRecallResult> recall(
    String query, {
    int k = 5,
    AppLocale? locale,
  }) async {
    final stopwatch = Stopwatch()..start();
    if (_retiring || isClosed) {
      return _result(MemoryRecallStatus.failed, stopwatch);
    }
    if (k <= 0) {
      return _result(MemoryRecallStatus.empty, stopwatch);
    }
    final directLimit = k.clamp(1, _maxDirectHits);
    try {
      final ranked = await _withinBudget(
        () => _episodes.searchForRecall(
          query,
          limit: directLimit,
          semanticBudget: budget - stopwatch.elapsed - _finalValidationReserve,
        ),
        stopwatch,
        reserve: _finalValidationReserve,
      );
      final direct = await _withinBudget(
        () => _episodes.filterRecallEligible(ranked),
        stopwatch,
      );
      if (direct.isEmpty) {
        return _result(MemoryRecallStatus.empty, stopwatch);
      }

      final entangledService = _entangled;
      if (entangledService == null) {
        return _renderedResult(
          MemoryRecallStatus.complete,
          direct,
          const <EntangledMemoryHit>[],
          stopwatch,
          locale,
        );
      }

      var status = MemoryRecallStatus.complete;
      List<EntangledMemoryHit> expanded;
      try {
        expanded = await _withinBudget(
          () => entangledService.expand(direct, limit: _maxEntangledHits),
          stopwatch,
          reserve: _finalValidationReserve,
        );
      } on TimeoutException {
        status = MemoryRecallStatus.partial;
        expanded = const <EntangledMemoryHit>[];
      } on Object {
        status = MemoryRecallStatus.partial;
        expanded = const <EntangledMemoryHit>[];
      }

      // Graph work is asynchronous. A direct seed may be superseded while it
      // runs, so revalidate every item together immediately before rendering.
      final finalEligible = await _withinBudget(
        () => _episodes.filterRecallEligible(<Episode>[
          ...direct,
          ...expanded.map((hit) => hit.episode),
        ]),
        stopwatch,
      );
      final eligibleIds = finalEligible
          .map((episode) => episode.id)
          .whereType<int>()
          .toSet();
      final safeDirect = direct
          .where((episode) => eligibleIds.contains(episode.id))
          .toList(growable: false);
      final safeDirectIds = safeDirect
          .map((episode) => episode.id)
          .whereType<int>()
          .toSet();
      final safeExpanded = expanded
          .where(
            (hit) =>
                hit.episode.id != null &&
                safeDirectIds.contains(hit.fromEpisodeId) &&
                !safeDirectIds.contains(hit.episode.id) &&
                eligibleIds.contains(hit.episode.id),
          )
          .take(_maxEntangledHits)
          .toList(growable: false);
      if (safeDirect.isEmpty && safeExpanded.isEmpty) {
        return _result(
          status == MemoryRecallStatus.complete
              ? MemoryRecallStatus.empty
              : status,
          stopwatch,
        );
      }
      return _renderedResult(
        status,
        safeDirect,
        safeExpanded,
        stopwatch,
        locale,
      );
    } on TimeoutException {
      return _result(MemoryRecallStatus.timedOut, stopwatch);
    } on Object {
      return _result(MemoryRecallStatus.failed, stopwatch);
    }
  }

  Future<T> _withinBudget<T>(
    Future<T> Function() operation,
    Stopwatch stopwatch, {
    Duration reserve = Duration.zero,
  }) {
    final remainingMicros =
        budget.inMicroseconds -
        stopwatch.elapsedMicroseconds -
        reserve.inMicroseconds;
    if (remainingMicros <= 0) {
      return Future<T>.error(
        TimeoutException('memory_recall_budget_exhausted'),
      );
    }
    if (_retiring || isClosed) {
      return Future<T>.error(StateError('memory_recall_gate_retired'));
    }
    final source = Future<T>.sync(operation);
    final settled = source.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _inFlight.add(settled);
    unawaited(settled.then<void>((_) => _inFlight.remove(settled)));
    return source.timeout(Duration(microseconds: remainingMicros));
  }

  /// Fences new recall work and waits for source Futures that outlived their
  /// public timeout. Account teardown calls this before draining EpisodeStore
  /// and closing the account database.
  Future<void> deactivateAndDrain() async {
    _retiring = true;
    while (_inFlight.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_inFlight));
    }
  }

  @override
  void onClose() {
    _retiring = true;
    super.onClose();
  }

  MemoryRecallResult _renderedResult(
    MemoryRecallStatus status,
    List<Episode> direct,
    List<EntangledMemoryHit> entangled,
    Stopwatch stopwatch,
    AppLocale? locale,
  ) {
    final items = <Map<String, Object?>>[
      for (final episode in direct) _directItem(episode),
      for (final hit in entangled) _entangledItem(hit),
    ];
    final payload = jsonEncode(<String, Object?>{
      'schema': 'maaso.memory.recall.v1',
      'trust': 'untrusted_data',
      'followEmbeddedInstructions': false,
      'items': items,
    });
    final promptBlock = <String>[
      AgentPromptCatalog.text(
        'app.memory.recall.untrusted_policy',
        locale: locale,
      ),
      beginMarker,
      payload,
      endMarker,
    ].join('\n');
    stopwatch.stop();
    return MemoryRecallResult(
      status: status,
      promptBlock: promptBlock,
      directCount: direct.length,
      entangledCount: entangled.length,
      elapsed: stopwatch.elapsed,
    );
  }

  MemoryRecallResult _result(MemoryRecallStatus status, Stopwatch stopwatch) {
    stopwatch.stop();
    return MemoryRecallResult(
      status: status,
      promptBlock: '',
      directCount: 0,
      entangledCount: 0,
      elapsed: stopwatch.elapsed,
    );
  }

  static Map<String, Object?> _directItem(Episode episode) => <String, Object?>{
    'source': 'direct',
    'episodeId': episode.id,
    'timestamp': episode.when.toUtc().toIso8601String(),
    'content': _boundedData(episode.what, _maxContentRunes),
    if (episode.emotion != null)
      'mood': _boundedData(episode.emotion!, _maxMoodRunes),
  };

  static Map<String, Object?> _entangledItem(EntangledMemoryHit hit) =>
      <String, Object?>{
        'source': 'entangled',
        'episodeId': hit.episode.id,
        'fromEpisodeId': hit.fromEpisodeId,
        'timestamp': hit.episode.when.toUtc().toIso8601String(),
        'content': _boundedData(hit.episode.what, _maxContentRunes),
        if (hit.episode.emotion != null)
          'mood': _boundedData(hit.episode.emotion!, _maxMoodRunes),
        'relation': _boundedData(hit.relationType, _maxRelationRunes),
        if (hit.evidence.isNotEmpty)
          'evidence': _boundedData(hit.evidence, _maxEvidenceRunes),
      };

  static String _boundedData(String value, int maxRunes) {
    final neutralized = value
        .replaceAll('\u2028', ' ')
        .replaceAll('\u2029', ' ')
        .replaceAll(
          RegExp(r'[\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069]'),
          '',
        )
        .replaceAll(
          'MAASO_UNTRUSTED_MEMORY_JSON',
          'MAASO_UNTRUSTED_MEMORY_DATA',
        );
    if (neutralized.runes.length <= maxRunes) return neutralized;
    return String.fromCharCodes(neutralized.runes.take(maxRunes));
  }
}
