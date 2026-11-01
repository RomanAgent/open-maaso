import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sembast/sembast.dart';

import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/embedding_service.dart';
import 'package:maaso/src/core/services/episode_v2_migration.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/turn_trace.dart';

enum EpisodeRecallIndexFaultPoint {
  afterHighWatermark,
  beforeCandidateRead,
  beforePublish,
}

typedef EpisodeRecallIndexFaultInjector =
    Future<void> Function(EpisodeRecallIndexFaultPoint point);

/// L2 episode persistence + retrieval.
///
/// Retrieval has two non-blocking paths and picks one per call:
///   1. **Hybrid** — a warmed account-scoped query embedding combines cosine
///      and keyword evidence. Missing episode embeddings stay keyword-eligible
///      and receive bounded background backfill.
///   2. **Keyword** — an uncached query returns immediately while a bounded
///      background queue primes its embedding for a later turn.
///
/// Both paths fold in recency (τ = 14d) and the episode's self-reported
/// salience, so a stale-but-perfect-match doesn't dominate a fresh,
/// slightly-less-similar episode.
class EpisodeStore extends AppService {
  EpisodeStore({
    Database? database,
    String? accountScopeDigest,
    FeatureRolloutMode Function()? memoryV2Mode,
    DateTime Function()? clock,
    int migrationBatchSize = 64,
    EpisodeV2MigrationFaultInjector? migrationFaultInjector,
    EpisodeRecallIndexFaultInjector? recallIndexFaultInjector,
  }) : _database = database,
       _accountScopeDigest = accountScopeDigest,
       _memoryV2ModeOverride = memoryV2Mode,
       _clock = clock ?? DateTime.now,
       _migrationBatchSize = migrationBatchSize,
       _migrationFaultInjector = migrationFaultInjector,
       _recallIndexFaultInjector = recallIndexFaultInjector;

  final Database? _database;
  final String? _accountScopeDigest;
  final FeatureRolloutMode Function()? _memoryV2ModeOverride;
  final DateTime Function() _clock;
  final int _migrationBatchSize;
  final EpisodeV2MigrationFaultInjector? _migrationFaultInjector;
  final EpisodeRecallIndexFaultInjector? _recallIndexFaultInjector;
  Future<void> _mutationTail = Future<void>.value();
  Future<void> _backgroundTail = Future<void>.value();
  Future<EpisodeV2MigrationReport>? _migrationFuture;
  Future<void>? _recallIndexBuild;
  EpisodeV2Migrator? _migrator;
  List<Episode>? _recallCandidateCache;
  final Map<int, Future<List<Episode>>> _recallCandidateLoads =
      <int, Future<List<Episode>>>{};
  int _recallCacheEpoch = 0;
  final LinkedHashMap<String, List<double>> _queryEmbeddingCache =
      LinkedHashMap<String, List<double>>();
  final Set<String> _queryEmbeddingLoads = <String>{};
  final Map<String, Future<void>> _queryEmbeddingTasks = {};
  EmbeddingService? _queryEmbeddingOwner;
  Object? _queryEmbeddingGeneration;
  final Expando<String> _vectorDigests = Expando<String>();
  bool _recallIndexReady = false;
  DateTime? _recallIndexNextExpiryAt;
  bool _migrationPauseRequested = false;
  bool _retiring = false;

  Database get _db => _database ?? appServices.find<DBService>().raw;
  static final _store = intMapStoreFactory.store('episodes');

  static const _tauDays = 14.0;

  /// Hard ceiling for every recall/export/link candidate pass.
  ///
  /// Sembast has no secondary indexes. A persistent materialized store is
  /// therefore maintained at this size, then its governance sidecars are
  /// revalidated in one batch before every consumer.
  static const int recallCandidateLimit = 256;
  static const int _recallIndexBuildBatchSize = 64;
  static const int _recallIndexSchemaVersion = 2;
  static const String _recallIndexStateKey = 'current';
  static const int _queryEmbeddingCacheLimit = 32;
  static const int _queryEmbeddingLoadLimit = 8;
  static const int _maxQueryRunes = 2048;

  /// Cosine threshold below which we treat a match as noise and drop it.
  /// 0.35 is empirical for OpenAI/`text-embedding-3-small` on short Chinese
  /// + English mixed text — high enough to skip "any two short strings look
  /// similar" garbage, low enough not to nuke legitimate near-hits.
  static const _cosineFloor = 0.35;

  /// Persist a new episode.  Embedding is computed in the background so
  /// the write returns immediately; the embedding lands on the row a few
  /// hundred ms later via [_backfillEmbedding].
  Future<int> add(Episode e) => _enqueueMutation(() async {
    final writeV2 = _effectiveMemoryV2Mode() == FeatureRolloutMode.enforce;
    return _persistEpisode(e, writeV2: writeV2);
  });

  /// Persists with the legacy codec using a rollout decision already captured
  /// by the caller. This prevents a mid-write flag change from upgrading an
  /// ungoverned legacy proposal into a v2 accepted row.
  Future<int> addLegacy(Episode e) =>
      _enqueueMutation(() => _persistEpisode(e, writeV2: false));

  Future<int> _persistEpisode(Episode e, {required bool writeV2}) async {
    late int key;
    await _db.transaction((transaction) async {
      key = await _store.add(
        transaction,
        writeV2 ? e.toJson() : e.toLegacyJson(),
      );
      e.id = key;
      await updateRecallIndexInTransaction(transaction, e);
    });
    invalidateRecallCache();
    // Fire-and-forget: embedding work is tracked by [_backgroundTail], so
    // account retirement can drain it without adding latency to this write.
    // ignore: unawaited_futures
    _backfillEmbedding(e);
    return key;
  }

  /// Runs the account-scoped v1→v2 migration under the feature rollout.
  ///
  /// `shadow` only classifies rows. `enforce` upgrades small key-ordered
  /// batches in place and commits the identity mapping plus checkpoint in the
  /// same Sembast transaction. Concurrent callers share one migration run.
  Future<EpisodeV2MigrationReport> migrateLegacyEpisodes({int? maxBatches}) {
    final existing = _migrationFuture;
    if (existing != null) return existing;
    if (_migrationPauseRequested || _retiring || isClosed) {
      return Future<EpisodeV2MigrationReport>.error(
        StateError(
          _retiring || isClosed
              ? 'episode_store_retired'
              : 'episode_migration_paused',
        ),
      );
    }
    final operation = _runMigration(maxBatches: maxBatches);
    _migrationFuture = operation;
    operation.then<void>(
      (_) {
        if (identical(_migrationFuture, operation)) _migrationFuture = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_migrationFuture, operation)) _migrationFuture = null;
      },
    );
    return operation;
  }

  /// Stops migration admission synchronously without fencing normal Episode
  /// writes. An in-flight transaction is allowed to commit its row, mapping,
  /// and checkpoint atomically; the migration then persists `paused` before
  /// returning to the account-runtime drain.
  void requestMigrationPause() {
    _migrationPauseRequested = true;
  }

  Future<EpisodeV2MigrationReport?> readMigrationReport() async {
    await _mutationTail;
    return _requireMigrator().readReport();
  }

  Future<EpisodeV2MigrationMapping?> migrationMappingFor(int sourceId) async {
    await _mutationTail;
    return _requireMigrator().mappingFor(sourceId);
  }

  Future<EpisodeV2MigrationIssue?> migrationIssueFor(int sourceId) async {
    await _mutationTail;
    return _requireMigrator().issueFor(sourceId);
  }

  Future<void> waitForIdle() async {
    final migration = _migrationFuture;
    if (migration != null) await migration;
    while (true) {
      final recallIndexBuild = _recallIndexBuild;
      final recallCandidateLoads = List<Future<List<Episode>>>.of(
        _recallCandidateLoads.values,
      );
      if (recallIndexBuild == null && recallCandidateLoads.isEmpty) break;
      if (recallIndexBuild != null) await recallIndexBuild;
      await Future.wait<List<Episode>>(recallCandidateLoads);
    }
    await _backgroundTail;
    await _mutationTail;
  }

  Future<void> deactivateAndDrain() async {
    requestMigrationPause();
    _clearRecallState();
    if (_retiring) {
      await waitForIdle();
      return;
    }
    _retiring = true;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> drain(Future<void> work) async {
      try {
        await work;
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    final migration = _migrationFuture;
    if (migration != null) {
      await drain(migration.then<void>((_) {}));
    }
    while (true) {
      final recallIndexBuild = _recallIndexBuild;
      final recallCandidateLoads = List<Future<List<Episode>>>.of(
        _recallCandidateLoads.values,
      );
      if (recallIndexBuild == null && recallCandidateLoads.isEmpty) break;
      if (recallIndexBuild != null) await drain(recallIndexBuild);
      for (final load in recallCandidateLoads) {
        await drain(load.then<void>((_) {}));
      }
    }
    await drain(_backgroundTail);
    await drain(_mutationTail);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// Newest-first dump — useful for a future Settings inspector / debug page.
  Future<List<Episode>> recent({int limit = 20}) async {
    final records = await _store.find(
      _db,
      finder: Finder(sortOrders: [SortOrder('when', false)], limit: limit),
    );
    return records.map((r) {
      final ep = Episode.fromJson(r.value);
      ep.id = r.key;
      return ep;
    }).toList();
  }

  Future<Episode?> get(int id) async {
    final json = await _store.record(id).get(_db);
    if (json == null) return null;
    final ep = Episode.fromJson(json);
    ep.id = id;
    return ep;
  }

  /// Whether an Episode may cross the prompt, link, or export boundary.
  ///
  /// `pending` is the wire-compatible quarantine state. Supersession remains
  /// append-only in the Episode row and is represented by a governance sidecar
  /// whose `current=false` value makes an older accepted revision ineligible.
  Future<bool> isRecallEligible(Episode episode, {DateTime? now}) async {
    final eligible = await filterRecallEligible(<Episode>[episode], now: now);
    return eligible.isNotEmpty;
  }

  /// Batch form of the accepted-current boundary.
  ///
  /// Filtering review/expiry before the single sidecar read keeps quarantined
  /// rows out of ranking and prevents the former per-candidate N+1 lookup.
  Future<List<Episode>> filterRecallEligible(
    Iterable<Episode> episodes, {
    DateTime? now,
  }) => _filterRecallEligible(_db, episodes, now: now);

  Future<List<Episode>> _filterRecallEligible(
    DatabaseClient client,
    Iterable<Episode> episodes, {
    DateTime? now,
  }) async {
    final instant = (now ?? _clock()).toUtc();
    final candidates = <Episode>[];
    final ids = <int>[];
    final seenIds = <int>{};
    for (final episode in episodes) {
      if (episode.reviewState != EpisodeReviewState.accepted) continue;
      final expiresAt = episode.expiresAt;
      if (expiresAt != null && !expiresAt.isAfter(instant)) continue;
      final id = episode.id;
      if (id == null || !seenIds.add(id)) continue;
      candidates.add(episode);
      ids.add(id);
    }
    if (candidates.isEmpty) return const <Episode>[];

    final governanceRows = await MemoryGovernanceStores.episodeGovernance
        .records(ids)
        .get(client);
    final expectedDigest = _accountScopeDigest;
    final eligible = <Episode>[];
    for (var index = 0; index < candidates.length; index++) {
      final episode = candidates[index];
      final id = ids[index];
      final governance = governanceRows[index];
      if (governance == null) {
        // Legacy rows and pre-coordinator v2 rows keep their existing accepted
        // behavior. Every coordinator write always has a governance sidecar.
        eligible.add(episode);
        continue;
      }
      if (expectedDigest != null &&
          governance['accountScopeDigest'] != expectedDigest) {
        continue;
      }
      if (governance['episodeId'] == id &&
          governance['current'] == true &&
          governance['reviewState'] == EpisodeReviewState.accepted.name &&
          governance['governedProjectionKind'] == null) {
        eligible.add(episode);
      }
    }
    return List<Episode>.unmodifiable(eligible);
  }

  /// Newest accepted-current rows, used by non-prompt exports such as genes.
  Future<List<Episode>> recallEligibleRecent({int limit = 20}) async {
    if (limit <= 0) return const <Episode>[];
    final eligible = await _eligibleRecallCandidates();
    return eligible.take(limit).toList(growable: false);
  }

  /// Builds or opens the persistent bounded recall index.
  ///
  /// Production schedules this after the first frame. The one-time legacy
  /// bootstrap scans key-ordered batches, keeps only the best 256 eligible
  /// rows in memory, and persists them so later mounts stay bounded.
  Future<void> prepareRecallIndex() => _ensureRecallIndexReady();

  /// Invalidates the durable Episode snapshot and its cheap index-state read.
  /// Query embeddings are account-scoped and remain reusable across ordinary
  /// writes.
  void invalidateRecallCache() {
    _recallCacheEpoch++;
    _recallCandidateCache = null;
    _recallIndexReady = false;
    _recallIndexNextExpiryAt = null;
  }

  Future<List<Episode>> _eligibleRecallCandidates() async {
    final candidates = await _recallCandidates();
    return filterRecallEligible(candidates, now: _clock().toUtc());
  }

  Future<List<Episode>> _recallCandidates() async {
    final nextExpiryAt = _recallIndexNextExpiryAt;
    if (nextExpiryAt != null && !nextExpiryAt.isAfter(_clock().toUtc())) {
      invalidateRecallCache();
    }
    final cached = _recallCandidateCache;
    if (cached != null) return cached;
    final epoch = _recallCacheEpoch;
    final inFlight = _recallCandidateLoads[epoch];
    if (inFlight != null) return inFlight;

    final load = _loadRecallCandidates();
    _recallCandidateLoads[epoch] = load;
    try {
      final loaded = await load;
      if (epoch == _recallCacheEpoch && !_retiring && !isClosed) {
        _recallCandidateCache = loaded;
      }
      return loaded;
    } finally {
      if (identical(_recallCandidateLoads[epoch], load)) {
        _recallCandidateLoads.remove(epoch);
      }
    }
  }

  Future<List<Episode>> _loadRecallCandidates() async {
    await _ensureRecallIndexReady();
    if (_retiring || isClosed) return const <Episode>[];
    final faultInjector = _recallIndexFaultInjector;
    if (faultInjector != null) {
      await faultInjector(EpisodeRecallIndexFaultPoint.beforeCandidateRead);
    }
    if (_retiring || isClosed) return const <Episode>[];
    final indexRecords = await MemoryGovernanceStores.episodeRecallIndex.find(
      _db,
      finder: Finder(
        sortOrders: <SortOrder>[
          SortOrder('when', false),
          SortOrder(Field.key, false),
        ],
        limit: recallCandidateLimit,
      ),
    );
    final validIndexIds = <int>[];
    var malformedRows = 0;
    for (final record in indexRecords) {
      final row = record.value;
      if (row['schemaVersion'] != _recallIndexSchemaVersion ||
          row['accountScopeDigest'] != _recallIndexScope ||
          row['episodeId'] != record.key ||
          row['when'] is! int ||
          (row['expiresAt'] != null && row['expiresAt'] is! int)) {
        malformedRows++;
        continue;
      }
      validIndexIds.add(record.key);
    }
    final episodeRows = await _store.records(validIndexIds).get(_db);
    final candidates = <Episode>[];
    for (var index = 0; index < validIndexIds.length; index++) {
      final row = episodeRows[index];
      if (row == null) {
        malformedRows++;
        continue;
      }
      try {
        final episode = Episode.fromJson(row)..id = validIndexIds[index];
        if (episode.reviewState == EpisodeReviewState.accepted) {
          candidates.add(episode);
        }
      } on Object {
        malformedRows++;
      }
    }
    if (malformedRows > 0) {
      Log.w('episode recall cache skipped malformed_rows=$malformedRows');
    }
    return List<Episode>.unmodifiable(candidates);
  }

  /// Transactional materialized-index update used by the write coordinator.
  ///
  /// The index store itself never exceeds [recallCandidateLimit], so every
  /// steady-state candidate load is structurally bounded. New accepted rows
  /// and removal of superseded heads commit with their governance sidecars.
  Future<void> updateRecallIndexInTransaction(
    DatabaseClient client,
    Episode episode, {
    int? removeEpisodeId,
    DateTime? now,
  }) async {
    if (removeEpisodeId != null) {
      await MemoryGovernanceStores.episodeRecallIndex
          .record(removeEpisodeId)
          .delete(client);
    }
    final id = episode.id;
    if (id != null) {
      final expiresAt = episode.expiresAt;
      final instant = (now ?? _clock()).toUtc();
      final eligibleByPayload =
          episode.reviewState == EpisodeReviewState.accepted &&
          (expiresAt == null || expiresAt.isAfter(instant));
      final record = MemoryGovernanceStores.episodeRecallIndex.record(id);
      if (eligibleByPayload) {
        await record.put(client, _recallIndexRow(episode));
      } else {
        await record.delete(client);
      }
    }
    await _pruneRecallIndex(client);
    await _refreshRecallIndexExpiryState(client);
  }

  Future<void> _ensureRecallIndexReady() {
    if (_recallIndexReady) {
      final nextExpiryAt = _recallIndexNextExpiryAt;
      if (nextExpiryAt == null || nextExpiryAt.isAfter(_clock().toUtc())) {
        return Future<void>.value();
      }
      invalidateRecallCache();
    }
    if (_retiring || isClosed) return Future<void>.value();
    final existing = _recallIndexBuild;
    if (existing != null) return existing;
    final operation = _driveRecallIndexReady();
    _recallIndexBuild = operation;
    operation.then<void>(
      (_) {
        if (identical(_recallIndexBuild, operation)) {
          _recallIndexBuild = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_recallIndexBuild, operation)) {
          _recallIndexBuild = null;
        }
      },
    );
    return operation;
  }

  Future<void> _driveRecallIndexReady() async {
    while (!_retiring && !isClosed) {
      if (_recallIndexReady) {
        final nextExpiryAt = _recallIndexNextExpiryAt;
        if (nextExpiryAt == null || nextExpiryAt.isAfter(_clock().toUtc())) {
          return;
        }
        invalidateRecallCache();
      }
      final buildEpoch = _recallCacheEpoch;
      await _loadOrRebuildRecallIndex(buildEpoch);
      if (_recallIndexReady && buildEpoch == _recallCacheEpoch) return;
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> _loadOrRebuildRecallIndex(int buildEpoch) async {
    final state = await MemoryGovernanceStores.episodeRecallIndexState
        .record(_recallIndexStateKey)
        .get(_db);
    final rawNextExpiryAt = state?['nextExpiryAt'];
    final nextExpiryAt = rawNextExpiryAt is int
        ? DateTime.fromMillisecondsSinceEpoch(rawNextExpiryAt, isUtc: true)
        : null;
    if (state != null &&
        state['schemaVersion'] == _recallIndexSchemaVersion &&
        state['accountScopeDigest'] == _recallIndexScope &&
        state['complete'] == true &&
        (rawNextExpiryAt == null || rawNextExpiryAt is int)) {
      if (nextExpiryAt == null || nextExpiryAt.isAfter(_clock().toUtc())) {
        if (_canPublishRecallIndex(buildEpoch)) {
          _recallIndexReady = true;
          _recallIndexNextExpiryAt = nextExpiryAt;
        }
        return;
      }
    }
    await _rebuildRecallIndex(buildEpoch);
  }

  Future<void> _rebuildRecallIndex(int buildEpoch) async {
    while (!_retiring && !isClosed) {
      final result = await _rebuildRecallIndexAttempt();
      if (result == null) {
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      final faultInjector = _recallIndexFaultInjector;
      if (faultInjector != null) {
        await faultInjector(EpisodeRecallIndexFaultPoint.beforePublish);
      }
      final nextExpiryAt = result.nextExpiryAt;
      if (nextExpiryAt != null && !nextExpiryAt.isAfter(_clock().toUtc())) {
        // The transaction committed at a valid instant, but the earliest row
        // expired before readiness could be published. Rebuild immediately so
        // it cannot keep an older valid row outside the top-256 materialization.
        await Future<void>.delayed(Duration.zero);
        continue;
      }
      if (_canPublishRecallIndex(buildEpoch)) {
        _recallIndexReady = true;
        _recallIndexNextExpiryAt = nextExpiryAt;
      }
      return;
    }
  }

  Future<_RecallIndexBuildResult?> _rebuildRecallIndexAttempt() async {
    final scanInstant = _clock().toUtc();
    final highWatermarkId = await _latestEpisodeId(_db);
    final faultInjector = _recallIndexFaultInjector;
    if (faultInjector != null) {
      await faultInjector(EpisodeRecallIndexFaultPoint.afterHighWatermark);
    }
    var lastSourceKey = 0;
    final best = <Episode>[];
    var malformedRows = 0;
    while (lastSourceKey < highWatermarkId && !_retiring && !isClosed) {
      // Integer Episode keys are append-only. Exact multi-get avoids Finder's
      // full-store sort and avoids repeatedly rescanning old keys for every
      // page; both requested and decoded batch sizes stay at 64.
      final batchEnd = math.min(
        highWatermarkId,
        lastSourceKey + _recallIndexBuildBatchSize,
      );
      final keys = <int>[
        for (var key = lastSourceKey + 1; key <= batchEnd; key++) key,
      ];
      final rows = await _store.records(keys).get(_db);
      final decoded = <Episode>[];
      for (var index = 0; index < keys.length; index++) {
        final row = rows[index];
        if (row == null) continue;
        try {
          final episode = Episode.fromJson(row)..id = keys[index];
          if (episode.reviewState == EpisodeReviewState.accepted) {
            decoded.add(episode);
          }
        } on Object {
          malformedRows++;
        }
      }
      lastSourceKey = batchEnd;
      best.addAll(await _filterRecallEligible(_db, decoded, now: scanInstant));
      _sortAndTrimRecallCandidates(best);
      await Future<void>.delayed(Duration.zero);
    }
    if (_retiring || isClosed) return null;

    var retryRequired = false;
    DateTime? nextExpiryAt;
    await _db.transaction((transaction) async {
      final finalInstant = _clock().toUtc();
      final finalHighWatermarkId = await _latestEpisodeId(transaction);
      final scannedById = <int, Episode>{
        for (final episode in best)
          if (episode.id != null) episode.id!: episode,
      };
      final revalidatedScanned = await _filterRecallEligible(
        transaction,
        scannedById.values,
        now: finalInstant,
      );
      final revalidatedIds = revalidatedScanned
          .map((episode) => episode.id)
          .whereType<int>()
          .toSet();
      if (revalidatedIds.length != scannedById.length ||
          !revalidatedIds.containsAll(scannedById.keys)) {
        // A top candidate expired or lost current authority during the scan.
        // It may already have displaced the older valid row at position 257,
        // so committing a shortened set would make that omission persistent.
        retryRequired = true;
        return;
      }
      best
        ..clear()
        ..addAll(revalidatedScanned);

      // The bounded steady-state index cannot prove completeness for writes
      // that committed after the outer scan captured its watermark: a stable
      // older row may already have been displaced by 256 newer rows that are
      // expired at finalization. Read that append-only tail exactly inside the
      // final transaction, where no write can fall between the tail watermark
      // and the durable `complete` marker.
      var tailLastSourceKey = highWatermarkId;
      while (tailLastSourceKey < finalHighWatermarkId) {
        final batchEnd = math.min(
          finalHighWatermarkId,
          tailLastSourceKey + _recallIndexBuildBatchSize,
        );
        final keys = <int>[
          for (var key = tailLastSourceKey + 1; key <= batchEnd; key++) key,
        ];
        final rows = await _store.records(keys).get(transaction);
        final decoded = <Episode>[];
        for (var index = 0; index < keys.length; index++) {
          final row = rows[index];
          if (row == null) continue;
          try {
            final episode = Episode.fromJson(row)..id = keys[index];
            if (episode.reviewState == EpisodeReviewState.accepted) {
              decoded.add(episode);
            }
          } on Object {
            malformedRows++;
          }
        }
        best.addAll(
          await _filterRecallEligible(transaction, decoded, now: finalInstant),
        );
        _sortAndTrimRecallCandidates(best);
        tailLastSourceKey = batchEnd;
      }

      final eligible = best.toList(growable: true);
      final currentIndex = await MemoryGovernanceStores.episodeRecallIndex.find(
        transaction,
        finder: Finder(limit: recallCandidateLimit),
      );
      nextExpiryAt = _earliestExpiry(eligible);

      if (currentIndex.isNotEmpty) {
        await MemoryGovernanceStores.episodeRecallIndex
            .records(currentIndex.map((record) => record.key))
            .delete(transaction);
      }
      for (final episode in eligible) {
        await MemoryGovernanceStores.episodeRecallIndex
            .record(episode.id!)
            .put(transaction, _recallIndexRow(episode));
      }
      await _pruneRecallIndex(transaction);
      await MemoryGovernanceStores.episodeRecallIndexState
          .record(_recallIndexStateKey)
          .put(transaction, <String, Object?>{
            'schemaVersion': _recallIndexSchemaVersion,
            'accountScopeDigest': _recallIndexScope,
            'complete': true,
            'highWatermarkId': finalHighWatermarkId,
            'nextExpiryAt': nextExpiryAt?.millisecondsSinceEpoch,
            'updatedAt': finalInstant.millisecondsSinceEpoch,
          });
    });
    if (retryRequired) return null;
    if (malformedRows > 0) {
      Log.w('episode recall index skipped malformed_rows=$malformedRows');
    }
    return _RecallIndexBuildResult(nextExpiryAt: nextExpiryAt);
  }

  Future<void> _pruneRecallIndex(DatabaseClient client) async {
    while (true) {
      final overflow = await MemoryGovernanceStores.episodeRecallIndex.find(
        client,
        finder: Finder(
          sortOrders: <SortOrder>[
            SortOrder('when', false),
            SortOrder(Field.key, false),
          ],
          offset: recallCandidateLimit,
          limit: _recallIndexBuildBatchSize,
        ),
      );
      if (overflow.isEmpty) return;
      await MemoryGovernanceStores.episodeRecallIndex
          .records(overflow.map((record) => record.key))
          .delete(client);
    }
  }

  Future<void> _refreshRecallIndexExpiryState(DatabaseClient client) async {
    final stateRecord = MemoryGovernanceStores.episodeRecallIndexState.record(
      _recallIndexStateKey,
    );
    final state = await stateRecord.get(client);
    if (state == null ||
        state['schemaVersion'] != _recallIndexSchemaVersion ||
        state['accountScopeDigest'] != _recallIndexScope ||
        state['complete'] != true) {
      return;
    }
    final rows = await MemoryGovernanceStores.episodeRecallIndex.find(
      client,
      finder: Finder(limit: recallCandidateLimit),
    );
    int? nextExpiryAt;
    for (final row in rows) {
      final rawExpiryAt = row.value['expiresAt'];
      if (rawExpiryAt == null) continue;
      if (rawExpiryAt is! int) {
        await stateRecord.put(client, <String, Object?>{
          ...state,
          'complete': false,
          'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
        });
        return;
      }
      if (nextExpiryAt == null || rawExpiryAt < nextExpiryAt) {
        nextExpiryAt = rawExpiryAt;
      }
    }
    await stateRecord.put(client, <String, Object?>{
      ...state,
      'nextExpiryAt': nextExpiryAt,
      'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
    });
  }

  static Future<int> _latestEpisodeId(DatabaseClient client) async {
    final count = await _store.count(client);
    if (count == 0) return 0;
    // Episodes are append-only. Natural key order plus offset keeps this read
    // constant-memory; an explicit descending SortOrder would collect the
    // entire store before applying limit in Sembast.
    final rows = await _store.find(
      client,
      finder: Finder(offset: count - 1, limit: 1),
    );
    return rows.isEmpty ? 0 : rows.single.key;
  }

  bool _canPublishRecallIndex(int buildEpoch) =>
      buildEpoch == _recallCacheEpoch && !_retiring && !isClosed;

  static void _sortAndTrimRecallCandidates(List<Episode> candidates) {
    candidates.sort((a, b) {
      final byWhen = b.when.compareTo(a.when);
      if (byWhen != 0) return byWhen;
      return (b.id ?? 0).compareTo(a.id ?? 0);
    });
    if (candidates.length > recallCandidateLimit) {
      candidates.removeRange(recallCandidateLimit, candidates.length);
    }
  }

  static DateTime? _earliestExpiry(Iterable<Episode> episodes) {
    DateTime? earliest;
    for (final episode in episodes) {
      final expiresAt = episode.expiresAt?.toUtc();
      if (expiresAt != null &&
          (earliest == null || expiresAt.isBefore(earliest))) {
        earliest = expiresAt;
      }
    }
    return earliest;
  }

  String get _recallIndexScope => _accountScopeDigest ?? 'legacy_unscoped';

  Map<String, Object?> _recallIndexRow(Episode episode) => <String, Object?>{
    'schemaVersion': _recallIndexSchemaVersion,
    'accountScopeDigest': _recallIndexScope,
    'episodeId': episode.id!,
    'when': episode.when.toUtc().millisecondsSinceEpoch,
    'expiresAt': episode.expiresAt?.toUtc().millisecondsSinceEpoch,
  };

  List<double>? _cachedQueryEmbedding(String query) {
    final service = appServices.maybeFind<EmbeddingService>();
    final generation = service?.cacheGeneration;
    if (!identical(service, _queryEmbeddingOwner) ||
        !identical(generation, _queryEmbeddingGeneration)) {
      _queryEmbeddingCache.clear();
      _queryEmbeddingOwner = service;
      _queryEmbeddingGeneration = generation;
    }
    if (service?.isAvailable != true) return null;
    final cached = _queryEmbeddingCache.remove(query);
    if (cached != null) _queryEmbeddingCache[query] = cached;
    return cached;
  }

  void _scheduleQueryEmbedding(String query) {
    if (_retiring ||
        isClosed ||
        _cachedQueryEmbedding(query) != null ||
        !appServices.isRegistered<EmbeddingService>() ||
        _queryEmbeddingLoads.length >= _queryEmbeddingLoadLimit ||
        !_queryEmbeddingLoads.add(query)) {
      return;
    }
    final service = appServices.find<EmbeddingService>();
    if (!service.isAvailable) {
      _queryEmbeddingLoads.remove(query);
      return;
    }
    final generation = service.cacheGeneration;

    Future<void> operation() async {
      try {
        if (_retiring || isClosed) return;
        final vector = await service.embed(query);
        if (vector == null ||
            _retiring ||
            isClosed ||
            !_embeddingContextIsCurrent(service, generation))
          return;
        _queryEmbeddingCache[query] = List<double>.unmodifiable(vector);
        if (_queryEmbeddingCache.length > _queryEmbeddingCacheLimit) {
          _queryEmbeddingCache.remove(_queryEmbeddingCache.keys.first);
        }
      } catch (_) {
        Log.w('episode query embedding prime failed');
      } finally {
        _queryEmbeddingLoads.remove(query);
        _queryEmbeddingTasks.remove(query);
      }
    }

    _queryEmbeddingTasks[query] = _appendBackground(operation);
  }

  Future<void> _appendBackground(Future<void> Function() operation) {
    final previous = _backgroundTail;
    final next = previous.then<void>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _backgroundTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  void _clearRecallState() {
    invalidateRecallCache();
    _queryEmbeddingCache.clear();
    _queryEmbeddingLoads.clear();
    _queryEmbeddingTasks.clear();
    _queryEmbeddingOwner = null;
    _queryEmbeddingGeneration = null;
  }

  /// Admits coordinator-owned accepted rows to the existing tracked embedding
  /// tail without exposing the raw Episode store to the coordinator.
  void scheduleEmbedding(Episode episode) {
    // ignore: unawaited_futures
    _backfillEmbedding(episode);
  }

  Future<List<Episode>> search(String query, {int limit = 5}) async {
    if (limit <= 0) return const <Episode>[];
    final boundedLimit = limit.clamp(1, recallCandidateLimit);
    final normalizedQuery = _boundedQuery(query);
    final candidates = await _eligibleRecallCandidates();
    if (candidates.isEmpty) return const <Episode>[];
    if (normalizedQuery.isEmpty) {
      return candidates.take(boundedLimit).toList(growable: false);
    }

    // Never await a network embedding on the recall hot path. A miss primes
    // the account-scoped cache on the tracked background tail; this turn gets
    // deterministic keyword ranking and later turns get hybrid reranking.
    final queryEmbedding = _cachedQueryEmbedding(normalizedQuery);
    if (queryEmbedding == null) {
      _scheduleQueryEmbedding(normalizedQuery);
      return _keywordSearch(normalizedQuery, boundedLimit, candidates);
    }
    return _semanticSearch(
      normalizedQuery,
      queryEmbedding,
      boundedLimit,
      candidates,
    );
  }

  /// The prompt gate may spend only its remaining budget on a first-query
  /// semantic miss. Existing callers of [search] retain non-blocking behavior.
  /// The query task remains tracked for account drain after a deadline expires.
  Future<List<Episode>> searchForRecall(
    String query, {
    int limit = 5,
    required Duration semanticBudget,
  }) async {
    final watch = Stopwatch()..start();
    final normalized = _boundedQuery(query);
    // Start the query vector alongside the bounded disk/index read. Otherwise
    // a cold store can consume the whole budget before even admitting a fast
    // provider, making a same-turn semantic hit impossible after restart.
    if (limit > 0 && normalized.isNotEmpty && semanticBudget > Duration.zero) {
      _scheduleQueryEmbedding(normalized);
    }
    final initial = await search(query, limit: limit);
    if (_retiring || isClosed) return const [];
    if (initial.isNotEmpty || limit <= 0) return initial;
    if (normalized.isEmpty) return initial;
    if (_cachedQueryEmbedding(normalized) == null) {
      final pending = _queryEmbeddingTasks[normalized];
      if (pending == null) {
        TurnTrace.event('memory.l2.semantic', details: 'status=unavailable');
        return initial;
      }
      // Leave time for the second store read, then the gate's authoritative
      // accepted/current validation. Neither deadline is extended by this wait.
      final remaining =
          semanticBudget - watch.elapsed - const Duration(milliseconds: 5);
      if (remaining <= Duration.zero) return initial;
      try {
        await pending.timeout(remaining);
      } on TimeoutException {
        TurnTrace.event(
          'memory.l2.semantic',
          details: 'status=deadline_fallback',
        );
        return initial;
      }
    }
    if (_retiring || isClosed) return const [];
    if (_cachedQueryEmbedding(normalized) == null) {
      TurnTrace.event('memory.l2.semantic', details: 'status=unavailable');
      return initial;
    }
    TurnTrace.event('memory.l2.semantic', details: 'status=ready');
    return search(normalized, limit: limit);
  }

  // ──────────────────────── Semantic path ────────────────────────

  Future<List<Episode>> _semanticSearch(
    String query,
    List<double> qEmb,
    int limit,
    List<Episode> candidates,
  ) async {
    final service = appServices.maybeFind<EmbeddingService>();
    final generation = _queryEmbeddingGeneration;
    if (service == null ||
        generation == null ||
        !_embeddingContextIsCurrent(service, generation)) {
      return _keywordSearch(query, limit, candidates);
    }
    final spaceId = service.embeddingSpaceId;
    final metadata = await MemoryGovernanceStores.episodeEmbeddingSpaces
        .records(candidates.map((episode) => episode.id!).toList())
        .get(_db);
    if (!_embeddingContextIsCurrent(service, generation)) {
      return _keywordSearch(query, limit, candidates);
    }
    final tokens = _tokenize(query);
    final now = _clock().toUtc();
    final scored = <_Scored>[];
    final needsBackfill = <Episode>[];

    for (var index = 0; index < candidates.length; index++) {
      final ep = candidates[index];
      final bag = _tokenize('${ep.what} ${ep.entities.join(" ")}');
      final hits = tokens.where(bag.contains).length;
      final keyword = tokens.isEmpty ? 0.0 : hits / tokens.length;
      final emb = ep.embedding;
      double? semantic;
      if (emb == null ||
          emb.length != qEmb.length ||
          !_matchesEmbeddingSpace(ep, metadata[index], spaceId)) {
        needsBackfill.add(ep);
      } else {
        semantic = _cosine(qEmb, emb);
      }
      if ((semantic == null || semantic < _cosineFloor) && keyword <= 0) {
        continue;
      }
      final ageMinutes = math.max(0, now.difference(ep.when.toUtc()).inMinutes);
      final ageDays = ageMinutes / (60 * 24);
      final recency = math.exp(-ageDays / _tauDays);
      final semanticScore = semantic != null && semantic >= _cosineFloor
          ? semantic
          : 0.0;
      final score =
          0.45 * semanticScore +
          0.30 * keyword +
          0.15 * recency +
          0.10 * ep.salience;
      scored.add(_Scored(ep, score));
    }

    // Kick the missing ones in the background so the NEXT search has them.
    // Throttled to 3 per call so a fresh install with hundreds of P0
    // episodes doesn't spam the provider on the first turn.
    for (final ep in needsBackfill.take(3)) {
      // ignore: unawaited_futures
      _backfillEmbedding(ep);
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.ep).toList();
  }

  Future<void> _backfillEmbedding(Episode ep) async {
    if (ep.id == null) return;
    if (ep.reviewState != EpisodeReviewState.accepted) return;
    if (!appServices.isRegistered<EmbeddingService>()) return;
    final svc = appServices.find<EmbeddingService>();
    if (!svc.isAvailable) return;
    if (_retiring || isClosed) return;
    final generation = svc.cacheGeneration;
    final spaceId = svc.embeddingSpaceId;
    Future<void> operation() async {
      if (_retiring || isClosed || !_embeddingContextIsCurrent(svc, generation))
        return;
      try {
        if (!await isRecallEligible(ep)) return;
        final existing = await MemoryGovernanceStores.episodeEmbeddingSpaces
            .record(ep.id!)
            .get(_db);
        if (_matchesEmbeddingSpace(ep, existing, spaceId)) return;
        final text = ep.entities.isEmpty
            ? ep.what
            : '${ep.what} — ${ep.entities.join(", ")}';
        final vector = await svc.embed(text);
        if (vector == null ||
            _retiring ||
            isClosed ||
            ep.id == null ||
            !_embeddingContextIsCurrent(svc, generation))
          return;
        await _enqueueMutation(() async {
          if (!_embeddingContextIsCurrent(svc, generation)) return;
          var updated = false;
          await _db.transaction((transaction) async {
            if ((await _filterRecallEligible(transaction, [ep])).isEmpty ||
                !_embeddingContextIsCurrent(svc, generation))
              return;
            await _store.record(ep.id!).update(transaction, <String, Object?>{
              'embedding': vector,
            });
            await MemoryGovernanceStores.episodeEmbeddingSpaces
                .record(ep.id!)
                .put(transaction, {
                  'schemaVersion': 1,
                  'accountScopeDigest': _recallIndexScope,
                  'spaceId': spaceId,
                  'vectorDigest': sha256
                      .convert(utf8.encode(jsonEncode(vector)))
                      .toString(),
                });
            updated = true;
          });
          if (updated) {
            ep.embedding = List<double>.unmodifiable(vector);
            invalidateRecallCache();
          }
        });
      } catch (error) {
        Log.w('episode backfill failed for id=${ep.id}: $error');
      }
    }

    await _appendBackground(operation);
  }

  bool _embeddingContextIsCurrent(
    EmbeddingService service,
    Object generation,
  ) =>
      identical(appServices.maybeFind<EmbeddingService>(), service) &&
      service.isAvailable &&
      identical(service.cacheGeneration, generation);

  bool _matchesEmbeddingSpace(
    Episode episode,
    Map<String, Object?>? metadata,
    String spaceId,
  ) {
    final vector = episode.embedding;
    if (vector == null ||
        metadata == null ||
        metadata['schemaVersion'] != 1 ||
        metadata['accountScopeDigest'] != _recallIndexScope ||
        metadata['spaceId'] != spaceId)
      return false;
    final digest = _vectorDigests[vector] ??= sha256
        .convert(utf8.encode(jsonEncode(vector)))
        .toString();
    return metadata['vectorDigest'] == digest;
  }

  Future<EpisodeV2MigrationReport> _runMigration({int? maxBatches}) async {
    final initialMode = _effectiveMemoryV2Mode();
    if (initialMode == FeatureRolloutMode.off || _retiring || isClosed) {
      return EpisodeV2MigrationReport.disabled(_clock().toUtc());
    }
    final migrator = _requireMigrator();
    if (initialMode == FeatureRolloutMode.shadow) {
      await _mutationTail;
      if (_migrationPauseRequested || _retiring || isClosed) {
        return EpisodeV2MigrationReport.disabled(_clock().toUtc());
      }
      return migrator.scan(
        maxBatches: maxBatches,
        shouldPause: () => _migrationPauseRequested || _retiring || isClosed,
      );
    }

    var completedBatches = 0;
    EpisodeV2MigrationReport? latest;
    while (!isClosed) {
      if (_migrationPauseRequested) {
        final paused = await _appendMutation<EpisodeV2MigrationReport?>(
          migrator.pause,
        );
        return paused ??
            latest ??
            EpisodeV2MigrationReport.disabled(_clock().toUtc());
      }
      if (_effectiveMemoryV2Mode() != FeatureRolloutMode.enforce) {
        final paused = await _appendMutation<EpisodeV2MigrationReport?>(
          migrator.pause,
        );
        return paused ??
            latest ??
            EpisodeV2MigrationReport.disabled(_clock().toUtc());
      }
      final step = await _appendMutation(migrator.migrateNextBatch);
      invalidateRecallCache();
      latest = step.report;
      completedBatches++;
      if (step.isComplete) return step.report;
      if (_migrationPauseRequested) {
        final paused = await _appendMutation<EpisodeV2MigrationReport?>(
          migrator.pause,
        );
        return paused ?? step.report;
      }
      if (maxBatches != null && completedBatches >= maxBatches) {
        final paused = await _appendMutation<EpisodeV2MigrationReport?>(
          migrator.pause,
        );
        return paused ?? step.report;
      }
      await Future<void>.delayed(Duration.zero);
    }
    return await migrator.readReport() ??
        latest ??
        EpisodeV2MigrationReport.disabled(_clock().toUtc());
  }

  EpisodeV2Migrator _requireMigrator() {
    final existing = _migrator;
    if (existing != null) return existing;
    final digest = _accountScopeDigest;
    if (digest == null) {
      throw StateError('episode_migration_scope_missing');
    }
    return _migrator = EpisodeV2Migrator(
      database: _db,
      accountScopeDigest: digest,
      clock: _clock,
      batchSize: _migrationBatchSize,
      faultInjector: _migrationFaultInjector,
    );
  }

  FeatureRolloutMode _effectiveMemoryV2Mode() {
    final override = _memoryV2ModeOverride;
    if (override != null) return override();
    final flags = appServices.maybeFind<MaasoFeatureFlagService>();
    return flags?.effectiveMode(MaasoFeatureFlag.memoryV2) ??
        FeatureRolloutMode.off;
  }

  Future<T> _enqueueMutation<T>(Future<T> Function() operation) {
    if (_retiring || isClosed) {
      return Future<T>.error(StateError('episode_store_retired'));
    }
    return _appendMutation(operation);
  }

  Future<T> _appendMutation<T>(Future<T> Function() operation) {
    final previous = _mutationTail;
    final next = previous.then<T>(
      (_) => operation(),
      onError: (Object _, StackTrace _) => operation(),
    );
    _mutationTail = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  @override
  void onClose() {
    _retiring = true;
    _clearRecallState();
    super.onClose();
  }

  static double _cosine(List<double> a, List<double> b) {
    var dot = 0.0, na = 0.0, nb = 0.0;
    for (var i = 0; i < a.length; i++) {
      final av = a[i], bv = b[i];
      dot += av * bv;
      na += av * av;
      nb += bv * bv;
    }
    if (na == 0 || nb == 0) return 0;
    return dot / (math.sqrt(na) * math.sqrt(nb));
  }

  // ──────────────────────── Keyword fallback ────────────────────────

  Future<List<Episode>> _keywordSearch(
    String query,
    int limit,
    List<Episode> candidates,
  ) async {
    final tokens = _tokenize(query);
    if (tokens.isEmpty) {
      return candidates.take(limit).toList(growable: false);
    }

    final now = _clock().toUtc();
    final scored = <_Scored>[];

    for (final ep in candidates) {
      final bag = _tokenize('${ep.what} ${ep.entities.join(" ")}');
      if (bag.isEmpty) continue;
      final hits = tokens.where(bag.contains).length;
      if (hits == 0) continue;
      final keyword = hits / tokens.length;

      final ageMinutes = math.max(0, now.difference(ep.when.toUtc()).inMinutes);
      final ageDays = ageMinutes / (60 * 24);
      final recency = math.exp(-ageDays / _tauDays);

      final score = 0.55 * keyword + 0.30 * recency + 0.15 * ep.salience;
      scored.add(_Scored(ep, score));
    }

    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.take(limit).map((s) => s.ep).toList();
  }

  /// Lower-case alphanumeric token split.  CJK is preserved per-character —
  /// good enough for keyword overlap.
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
      } else {
        if (buf.isNotEmpty) {
          out.add(buf.toString());
          buf.clear();
        }
      }
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out
        .where((t) => t.length > 1 || RegExp(r'[㐀-鿿]').hasMatch(t))
        .toList();
  }

  static String _boundedQuery(String query) {
    final trimmed = query.trim();
    if (trimmed.runes.length <= _maxQueryRunes) return trimmed;
    return String.fromCharCodes(trimmed.runes.take(_maxQueryRunes));
  }
}

class _Scored {
  final Episode ep;
  final double score;
  const _Scored(this.ep, this.score);
}

final class _RecallIndexBuildResult {
  const _RecallIndexBuildResult({required this.nextExpiryAt});

  final DateTime? nextExpiryAt;
}
