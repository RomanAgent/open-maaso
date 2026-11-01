import 'dart:math' as math;

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/episode_store.dart';

class EntangledMemoryService extends AppService {
  final Database _db = appServices.find<DBService>().raw;
  static final _store = StoreRef<String, Map<String, Object?>>(
    'memory_entanglements',
  );

  static const _minEdgeWeight = 0.22;
  static const _maxEdgesPerEpisode = 6;

  EpisodeStore get _episodes => appServices.find<EpisodeStore>();

  Future<void> linkEpisode(Episode episode) async {
    final id = episode.id;
    if (id == null) return;
    final canonical = await _episodes.get(id);
    if (canonical == null || !await _episodes.isRecallEligible(canonical)) {
      return;
    }
    final recent = await _episodes.recallEligibleRecent(limit: 32);
    final candidates = <_CandidateEdge>[];

    for (final other in recent) {
      final otherId = other.id;
      if (otherId == null || otherId == id) continue;
      final relation = _scoreRelation(canonical, other);
      if (relation.weight < _minEdgeWeight) continue;
      candidates.add(_CandidateEdge(otherId, relation));
    }

    candidates.sort((a, b) => b.relation.weight.compareTo(a.relation.weight));
    for (final edge in candidates.take(_maxEdgesPerEpisode)) {
      await _upsertBidirectional(
        id,
        edge.toEpisodeId,
        weight: edge.relation.weight,
        relationType: edge.relation.relationType,
        evidence: edge.relation.evidence,
      );
    }
  }

  /// Removes both directions of every derived edge for a superseded/deleted
  /// Episode. Recall still revalidates targets, so cleanup failure cannot leak
  /// a stale revision; this keeps the bounded graph from accumulating debris.
  Future<void> removeEpisodeLinks(int episodeId) async {
    if (episodeId <= 0) return;
    final records = await _store.find(
      _db,
      finder: Finder(
        filter: Filter.or(<Filter>[
          Filter.equals('fromEpisodeId', episodeId),
          Filter.equals('toEpisodeId', episodeId),
        ]),
      ),
    );
    if (records.isEmpty) return;
    await _store.records(records.map((record) => record.key)).delete(_db);
  }

  Future<List<EntangledMemoryHit>> expand(
    List<Episode> seedEpisodes, {
    int limit = 3,
  }) async {
    final seedIds = seedEpisodes.map((e) => e.id).whereType<int>().toSet();
    if (seedIds.isEmpty) return const [];

    final scored = <int, EntangledMemoryHit>{};
    for (var i = 0; i < seedEpisodes.length; i++) {
      final seed = seedEpisodes[i];
      final seedId = seed.id;
      if (seedId == null) continue;
      if (!await _episodes.isRecallEligible(seed)) continue;
      final seedStrength = 1.0 - (i / math.max(seedEpisodes.length, 1)) * 0.42;
      final records = await _store.find(
        _db,
        finder: Finder(
          filter: Filter.equals('fromEpisodeId', seedId),
          sortOrders: [SortOrder('weight', false)],
          limit: 8,
        ),
      );
      for (final record in records) {
        final edge = MemoryEntanglement.fromJson(record.value);
        final targetId = edge.toEpisodeId;
        if (seedIds.contains(targetId)) continue;
        final target = await _episodes.get(targetId);
        if (target == null) continue;
        if (!await _episodes.isRecallEligible(target)) continue;
        final score = edge.weight * seedStrength;
        final existing = scored[targetId];
        if (existing == null || score > existing.score) {
          scored[targetId] = EntangledMemoryHit(
            episode: target,
            score: score,
            relationType: edge.relationType,
            fromEpisodeId: seedId,
            evidence: edge.evidence,
          );
        }
        // ignore: unawaited_futures
        _markActivated(record.key);
      }
    }

    final hits = scored.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return hits.take(limit).toList(growable: false);
  }

  Future<Map<String, dynamic>> stats() async {
    final count = await _store.count(_db);
    final records = await _store.find(
      _db,
      finder: Finder(sortOrders: [SortOrder('updatedAt', false)], limit: 4),
    );
    return {
      'edgeCount': count,
      'recent': [
        for (final r in records)
          {
            'relation': r.value['relationType']?.toString() ?? '',
            'weight': ((r.value['weight'] as num?)?.toDouble() ?? 0)
                .toStringAsFixed(2),
            'evidence': r.value['evidence']?.toString() ?? '',
          },
      ],
    };
  }

  Future<void> _upsertBidirectional(
    int a,
    int b, {
    required double weight,
    required String relationType,
    required String evidence,
  }) async {
    await _upsert(a, b, weight, relationType, evidence);
    await _upsert(b, a, weight, relationType, evidence);
  }

  Future<void> _upsert(
    int from,
    int to,
    double weight,
    String relationType,
    String evidence,
  ) async {
    final key = '$from:$to';
    final now = DateTime.now().millisecondsSinceEpoch;
    final existing = await _store.record(key).get(_db);
    if (existing != null) {
      final oldWeight = (existing['weight'] as num?)?.toDouble() ?? 0;
      await _store.record(key).put(_db, {
        ...existing,
        'weight': math.max(oldWeight, weight).clamp(0.0, 1.0),
        'relationType': relationType,
        'evidence': evidence,
        'updatedAt': now,
      });
      return;
    }
    await _store
        .record(key)
        .put(
          _db,
          MemoryEntanglement(
            fromEpisodeId: from,
            toEpisodeId: to,
            weight: weight.clamp(0.0, 1.0),
            relationType: relationType,
            evidence: evidence,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ).toJson(),
        );
  }

  Future<void> _markActivated(String key) async {
    try {
      await _store.record(key).update(_db, {
        'lastActivatedAt': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (_) {}
  }

  static _RelationScore _scoreRelation(Episode a, Episode b) {
    final entities = _jaccard(
      a.entities.map((e) => e.toLowerCase()).toSet(),
      b.entities.map((e) => e.toLowerCase()).toSet(),
    );
    final tokens = _jaccard(
      _tokenize(a.what).toSet(),
      _tokenize(b.what).toSet(),
    );
    final sameEmotion =
        a.emotion != null && b.emotion != null && a.emotion == b.emotion;
    final ageDays = (a.when.difference(b.when).inMinutes.abs()) / (60 * 24);
    final temporal = ageDays <= 1
        ? 0.18
        : ageDays <= 7
        ? 0.10
        : ageDays <= 30
        ? 0.04
        : 0.0;
    final salience = ((a.salience + b.salience) / 2).clamp(0.0, 1.0) * 0.08;
    final emotion = sameEmotion ? 0.14 : 0.0;
    final weight =
        0.45 * entities + 0.30 * tokens + temporal + emotion + salience;

    final relationType = entities >= 0.25
        ? 'entity'
        : tokens >= 0.18
        ? 'semantic'
        : sameEmotion
        ? 'emotional'
        : 'temporal';
    final evidence = [
      if (entities > 0) 'entities=${entities.toStringAsFixed(2)}',
      if (tokens > 0) 'tokens=${tokens.toStringAsFixed(2)}',
      if (sameEmotion) 'emotion=${a.emotion}',
      if (temporal > 0) 'time=${ageDays.toStringAsFixed(1)}d',
    ].join(', ');

    return _RelationScore(
      weight: weight.clamp(0.0, 1.0),
      relationType: relationType,
      evidence: evidence.isEmpty ? 'salience-link' : evidence,
    );
  }

  static double _jaccard(Set<String> a, Set<String> b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final intersection = a.intersection(b).length;
    final union = a.union(b).length;
    if (union == 0) return 0;
    return intersection / union;
  }

  static List<String> _tokenize(String text) {
    final lower = text.toLowerCase();
    final out = <String>[];
    final buf = StringBuffer();
    for (final r in lower.runes) {
      final c = String.fromCharCode(r);
      final isAlnum = RegExp(r'[a-z0-9]').hasMatch(c);
      final isCjk = r >= 0x3400 && r <= 0x9fff;
      if (isAlnum) {
        buf.write(c);
      } else if (isCjk) {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
        out.add(c);
      } else if (buf.isNotEmpty) {
        out.add(buf.toString());
        buf.clear();
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out
        .where((t) => t.length > 1 || RegExp(r'[㐀-鿿]').hasMatch(t))
        .toList();
  }
}

class MemoryEntanglement {
  const MemoryEntanglement({
    required this.fromEpisodeId,
    required this.toEpisodeId,
    required this.weight,
    required this.relationType,
    required this.evidence,
    required this.createdAt,
    required this.updatedAt,
    this.lastActivatedAt,
  });

  final int fromEpisodeId;
  final int toEpisodeId;
  final double weight;
  final String relationType;
  final String evidence;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? lastActivatedAt;

  Map<String, Object?> toJson() => {
    'fromEpisodeId': fromEpisodeId,
    'toEpisodeId': toEpisodeId,
    'weight': weight,
    'relationType': relationType,
    'evidence': evidence,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (lastActivatedAt != null)
      'lastActivatedAt': lastActivatedAt!.millisecondsSinceEpoch,
  };

  factory MemoryEntanglement.fromJson(Map<String, Object?> json) {
    return MemoryEntanglement(
      fromEpisodeId: (json['fromEpisodeId'] as num?)?.toInt() ?? 0,
      toEpisodeId: (json['toEpisodeId'] as num?)?.toInt() ?? 0,
      weight: (json['weight'] as num?)?.toDouble() ?? 0,
      relationType: json['relationType'] as String? ?? 'unknown',
      evidence: json['evidence'] as String? ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(
        (json['updatedAt'] as num?)?.toInt() ?? 0,
      ),
      lastActivatedAt: json['lastActivatedAt'] == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(
              (json['lastActivatedAt'] as num).toInt(),
            ),
    );
  }
}

class EntangledMemoryHit {
  const EntangledMemoryHit({
    required this.episode,
    required this.score,
    required this.relationType,
    required this.fromEpisodeId,
    required this.evidence,
  });

  final Episode episode;
  final double score;
  final String relationType;
  final int fromEpisodeId;
  final String evidence;
}

class _CandidateEdge {
  const _CandidateEdge(this.toEpisodeId, this.relation);

  final int toEpisodeId;
  final _RelationScore relation;
}

class _RelationScore {
  const _RelationScore({
    required this.weight,
    required this.relationType,
    required this.evidence,
  });

  final double weight;
  final String relationType;
  final String evidence;
}
