import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/governed_memory_projection.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:sembast/sembast.dart';
import 'package:shared_preferences/shared_preferences.dart';

part 'memory_ledger_live_sync.dart';

final class MemoryLedgerEntry {
  const MemoryLedgerEntry({
    required this.episode,
    required this.current,
    required this.isHead,
    required this.lineageId,
    required this.supersededByEpisodeId,
    this.headEpisodeId,
    this.headRevision,
    this.governedProjectionKind,
    this.governedProjectionActive = false,
    this.governedProjectionPayload,
  });

  final Episode episode;
  final bool current;
  final bool isHead;
  final int lineageId;
  final int? supersededByEpisodeId;
  final int? headEpisodeId;
  final int? headRevision;
  final String? governedProjectionKind;
  final bool governedProjectionActive;
  final String? governedProjectionPayload;

  bool get isReviewTarget => isHead || governedProjectionActive;

  int? get expectedHeadEpisodeId =>
      headEpisodeId ?? (isHead ? episode.id : null);

  int? get expectedHeadRevision =>
      headRevision ?? (isHead ? episode.revision : null);
}

final class MemoryLedgerPage {
  const MemoryLedgerPage({
    required this.entries,
    required this.nextBeforeEpisodeId,
  });

  final List<MemoryLedgerEntry> entries;
  final int? nextBeforeEpisodeId;
}

final class MemoryRevisionSummary {
  const MemoryRevisionSummary({
    required this.episode,
    required this.current,
    required this.isHead,
    required this.lineageId,
  });

  final Episode episode;
  final bool current;
  final bool isHead;
  final int lineageId;
}

final class MemoryLedgerDetail {
  const MemoryLedgerDetail({required this.entry, required this.revisions});

  final MemoryLedgerEntry entry;
  final List<MemoryRevisionSummary> revisions;
}

final class MemoryRevisionFieldChange {
  const MemoryRevisionFieldChange({
    required this.field,
    required this.before,
    required this.after,
  });

  final String field;
  final Object? before;
  final Object? after;

  @override
  bool operator ==(Object other) =>
      other is MemoryRevisionFieldChange &&
      other.field == field &&
      other.before == before &&
      other.after == after;

  @override
  int get hashCode => Object.hash(field, before, after);
}

final class MemoryRevisionDiff {
  const MemoryRevisionDiff({
    required this.fromEpisodeId,
    required this.toEpisodeId,
    required this.sameLineage,
    required this.changes,
  });

  final int fromEpisodeId;
  final int toEpisodeId;
  final bool sameLineage;
  final List<MemoryRevisionFieldChange> changes;
}

enum MemorySourceTranscriptStatus { verified, unavailable, integrityFailure }

final class MemorySourceTranscriptResult {
  const MemorySourceTranscriptResult({
    required this.status,
    required this.sourceId,
    this.content,
    this.reason,
  });

  final MemorySourceTranscriptStatus status;
  final String sourceId;
  final String? content;
  final String? reason;
}

final class LegacyMemoryFactsMigrationReport {
  const LegacyMemoryFactsMigrationReport({
    required this.imported,
    required this.alreadyMigrated,
    required this.failed,
    required this.remaining,
    required this.complete,
    this.skippedReason,
  });

  final int imported;
  final int alreadyMigrated;
  final int failed;
  final int remaining;
  final bool complete;
  final String? skippedReason;
}

/// Account-owned read facade and governance entry point for Memory Ledger.
///
/// Canonical Episode payloads remain append-only. Reads use exact integer-key
/// batches and join account-scoped sidecars; all writes delegate to the single
/// [MemoryWriteCoordinator].
final class MemoryLedgerService extends AppService {
  MemoryLedgerService({
    required Database database,
    required MemoryWriteCoordinator coordinator,
    required String accountScopeDigest,
    MemoryBus? memoryBus,
    FeatureRolloutMode Function()? memoryV2Mode,
    DateTime Function()? clock,
  }) : _database = database,
       _coordinator = coordinator,
       _memoryBus = memoryBus,
       _accountScopeDigest = accountScopeDigest,
       _memoryV2ModeOverride = memoryV2Mode,
       _clock = clock ?? DateTime.now {
    if (!_sha256Pattern.hasMatch(accountScopeDigest)) {
      throw ArgumentError.value(
        accountScopeDigest,
        'accountScopeDigest',
        'must be a lowercase SHA-256 digest',
      );
    }
  }

  static const String unscopedLegacyFactsStorageKey = 'agent_long_term_facts';
  static const int maxPageSize = 50;
  static const int maxRevisionDepth = 64;
  static const int maxSourceRunes = 65536;
  static const int maxMigrationBatchSize = 256;
  static const int _readBatchSize = 64;
  static const int _maxPageScan = 256;
  static const int _maxLegacyFacts = 4096;
  static const int _maxSafeStoredInt = 0x1fffffffffffff;
  static const String _legacyFactsSourceKind = 'memory_manager_facts_v1';
  static final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');
  static final RegExp _chatSourcePattern = RegExp(
    r'^chat_message:([1-9][0-9]*)$',
  );
  static final RegExp _importedSourcePattern = RegExp(
    r'^imported:([a-f0-9]{64})$',
  );

  final Database _database;
  final MemoryWriteCoordinator _coordinator;
  final MemoryBus? _memoryBus;
  final String _accountScopeDigest;
  final FeatureRolloutMode Function()? _memoryV2ModeOverride;
  final DateTime Function() _clock;
  final Set<Future<void>> _inFlight = <Future<void>>{};
  bool _retiring = false;

  bool get acceptsRequests => !_retiring && !isClosed;

  static String legacyFactsStorageKey(String storageNamespace) {
    final namespace = storageNamespace.trim();
    if (namespace.isEmpty || namespace.runes.length > 512) {
      throw ArgumentError.value(storageNamespace, 'storageNamespace');
    }
    return '$namespace.preferences.$unscopedLegacyFactsStorageKey';
  }

  Future<MemoryLedgerPage> list({int? beforeEpisodeId, int limit = 20}) =>
      _track(() => _list(beforeEpisodeId: beforeEpisodeId, limit: limit));

  Future<MemoryLedgerDetail?> getDetail(int episodeId) => _track(() async {
    final entry = await _entryFor(episodeId);
    if (entry == null) return null;
    return MemoryLedgerDetail(
      entry: entry,
      revisions: await _revisions(episodeId, limit: maxRevisionDepth),
    );
  });

  Future<List<MemoryRevisionSummary>> revisions(
    int episodeId, {
    int limit = 32,
  }) => _track(() => _revisions(episodeId, limit: limit));

  Future<MemoryRevisionDiff> diff(int fromEpisodeId, int toEpisodeId) =>
      _track(() => _diff(fromEpisodeId, toEpisodeId));

  Future<MemorySourceTranscriptResult> sourceTranscript(
    EpisodeSourceRef source,
  ) => _track(() => _sourceTranscript(source));

  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) =>
      _track(() => _coordinator.review(command));

  Future<LegacyMemoryFactsMigrationReport> migrateLegacyFacts({
    required SharedPreferences preferences,
    required String storageNamespace,
    int limit = 64,
  }) => _track(
    () => _migrateLegacyFacts(
      preferences: preferences,
      storageNamespace: storageNamespace,
      limit: limit,
    ),
  );

  Future<void> deactivateAndDrain() async {
    _retiring = true;
    while (_inFlight.isNotEmpty) {
      await Future.wait<void>(List<Future<void>>.of(_inFlight));
    }
  }

  Future<MemoryLedgerPage> _list({
    required int? beforeEpisodeId,
    required int limit,
  }) async {
    _requirePageLimit(limit);
    if (beforeEpisodeId != null && beforeEpisodeId < 2) {
      return const MemoryLedgerPage(
        entries: <MemoryLedgerEntry>[],
        nextBeforeEpisodeId: null,
      );
    }
    final latest = await _latestEpisodeId();
    var nextId = math.min(latest, (beforeEpisodeId ?? latest + 1) - 1);
    final entries = <MemoryLedgerEntry>[];
    var scanned = 0;
    while (nextId > 0 && scanned < _maxPageScan && entries.length < limit) {
      final batchLength = math.min(
        _readBatchSize,
        math.min(nextId, _maxPageScan - scanned),
      );
      final keys = <int>[
        for (var key = nextId; key > nextId - batchLength; key--) key,
      ];
      final rows = await MemoryGovernanceStores.episodes
          .records(keys)
          .get(_database);
      for (var index = 0; index < keys.length; index++) {
        nextId = keys[index] - 1;
        scanned++;
        final row = rows[index];
        if (row == null) continue;
        final entry = await _decodeEntry(keys[index], row);
        if (entry != null) entries.add(entry);
        if (entries.length == limit) break;
      }
    }
    final cursor = nextId > 0 ? nextId + 1 : null;
    return MemoryLedgerPage(
      entries: List<MemoryLedgerEntry>.unmodifiable(entries),
      nextBeforeEpisodeId: cursor,
    );
  }

  Future<MemoryLedgerEntry?> _entryFor(int episodeId) async {
    if (episodeId < 1) return null;
    final raw = await MemoryGovernanceStores.episodes
        .record(episodeId)
        .get(_database);
    return raw == null ? null : _decodeEntry(episodeId, raw);
  }

  Future<MemoryLedgerEntry?> _decodeEntry(
    int episodeId,
    Map<String, Object?> raw,
  ) async {
    late final Episode episode;
    try {
      episode = Episode.fromJson(raw)..id = episodeId;
    } on Object {
      return null;
    }
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(episodeId)
        .get(_database);
    if (governance != null &&
        (governance['schemaVersion'] != 1 ||
            governance['accountScopeDigest'] != _accountScopeDigest ||
            governance['episodeId'] != episodeId ||
            governance['reviewState'] != episode.reviewState.name ||
            (governance['governedProjectionKind'] != null &&
                governance['governedProjectionKind'] is! String))) {
      return null;
    }
    if (governance == null &&
        episode.sourceType != EpisodeSourceType.legacyUnknown) {
      return null;
    }
    final lineageId = (governance?['lineageId'] as num?)?.toInt() ?? episodeId;
    final head = await MemoryGovernanceStores.revisionHeads
        .record(lineageId)
        .get(_database);
    final validHead =
        head != null &&
        head['schemaVersion'] == 1 &&
        head['accountScopeDigest'] == _accountScopeDigest &&
        head['lineageId'] == lineageId;
    var isHead = validHead && head['headEpisodeId'] == episodeId;
    if (head == null) {
      isHead = await _isBootstrapHead(episode, governance);
    }
    final governedProjectionKind =
        governance?['governedProjectionKind'] as String?;
    var governedProjectionActive = false;
    String? governedProjectionPayload;
    if (governedProjectionKind != null) {
      if (governance == null || head == null || !validHead) return null;
      try {
        final projection = GovernedMemoryProjectionRecord.fromStored(
          await MemoryGovernanceStores.governedProjections
              .record(episodeId)
              .get(_database),
          expectedEpisodeId: episodeId,
          expectedAccountScopeDigest: _accountScopeDigest,
          expectedKind: governedProjectionKind,
        );
        if (!projection.matchesClaimValueFingerprint(
          governance['claimValueFingerprint'],
        )) {
          throw const FormatException();
        }
        final projectionHead = GovernedMemoryProjectionHeadRecord.fromStored(
          await MemoryGovernanceStores.governedProjectionHeads
              .record(governedProjectionKind)
              .get(_database),
          expectedKind: governedProjectionKind,
          expectedAccountScopeDigest: _accountScopeDigest,
        );
        if (head['revision'] != projectionHead.revision ||
            head['reviewState'] != projectionHead.reviewState.name ||
            head['headEpisodeId'] != projectionHead.headEpisodeId) {
          throw const FormatException();
        }
        governedProjectionActive =
            projectionHead.activeEpisodeId == episodeId &&
            episode.reviewState == EpisodeReviewState.accepted &&
            governance['current'] == true;
        governedProjectionPayload = projection.canonicalPayload;
      } on Object {
        return null;
      }
    }
    return MemoryLedgerEntry(
      episode: episode,
      current: governance == null
          ? episode.reviewState == EpisodeReviewState.accepted
          : governance['current'] == true,
      isHead: isHead,
      lineageId: lineageId,
      supersededByEpisodeId: (governance?['supersededByEpisodeId'] as num?)
          ?.toInt(),
      headEpisodeId: validHead
          ? (head['headEpisodeId'] as num?)?.toInt()
          : isHead
          ? episodeId
          : null,
      headRevision: validHead
          ? (head['revision'] as num?)?.toInt()
          : isHead
          ? episode.revision
          : null,
      governedProjectionKind: governedProjectionKind,
      governedProjectionActive: governedProjectionActive,
      governedProjectionPayload: governedProjectionPayload,
    );
  }

  Future<bool> _isBootstrapHead(
    Episode episode,
    Map<String, Object?>? governance,
  ) async {
    if (governance == null) return episode.supersedesId == null;
    if (episode.reviewState == EpisodeReviewState.accepted) {
      return governance['current'] == true;
    }
    if (episode.reviewState != EpisodeReviewState.pending) return false;
    for (final entry in <(StoreRef<String, Map<String, Object?>>, String)>[
      (MemoryGovernanceStores.exactDedup, 'exactFingerprint'),
      (MemoryGovernanceStores.semanticDedup, 'semanticFingerprint'),
    ]) {
      final fingerprint = governance[entry.$2];
      if (fingerprint is! String) continue;
      final index = await entry.$1.record(fingerprint).get(_database);
      if (index?['accountScopeDigest'] == _accountScopeDigest &&
          index?['episodeId'] == episode.id) {
        return true;
      }
    }
    return false;
  }

  Future<List<MemoryRevisionSummary>> _revisions(
    int episodeId, {
    required int limit,
  }) async {
    if (episodeId < 1) return const <MemoryRevisionSummary>[];
    if (limit < 1 || limit > maxRevisionDepth) {
      throw ArgumentError.value(limit, 'limit');
    }
    final requested = await _entryFor(episodeId);
    if (requested == null) return const <MemoryRevisionSummary>[];
    var headId = episodeId;
    final head = await MemoryGovernanceStores.revisionHeads
        .record(requested.lineageId)
        .get(_database);
    if (head?['schemaVersion'] == 1 &&
        head?['accountScopeDigest'] == _accountScopeDigest &&
        head?['lineageId'] == requested.lineageId &&
        head?['headEpisodeId'] is num) {
      headId = (head!['headEpisodeId'] as num).toInt();
    }
    final revisions = <MemoryRevisionSummary>[];
    final visited = <int>{};
    var currentId = headId;
    while (revisions.length < limit && visited.add(currentId)) {
      final entry = await _entryFor(currentId);
      if (entry == null) break;
      revisions.add(
        MemoryRevisionSummary(
          episode: entry.episode,
          current: entry.current,
          isHead: currentId == headId,
          lineageId: requested.lineageId,
        ),
      );
      final prior = entry.episode.supersedesId;
      if (prior == null) break;
      currentId = prior;
    }
    return List<MemoryRevisionSummary>.unmodifiable(revisions);
  }

  Future<MemoryRevisionDiff> _diff(int fromEpisodeId, int toEpisodeId) async {
    final from = await _entryFor(fromEpisodeId);
    final to = await _entryFor(toEpisodeId);
    if (from == null || to == null) {
      return MemoryRevisionDiff(
        fromEpisodeId: fromEpisodeId,
        toEpisodeId: toEpisodeId,
        sameLineage: false,
        changes: const <MemoryRevisionFieldChange>[],
      );
    }
    final fromLineageId = await _trustedLineageId(from);
    final toLineageId = await _trustedLineageId(to);
    final sameLineage = fromLineageId != null && fromLineageId == toLineageId;
    if (!sameLineage) {
      return MemoryRevisionDiff(
        fromEpisodeId: fromEpisodeId,
        toEpisodeId: toEpisodeId,
        sameLineage: false,
        changes: const <MemoryRevisionFieldChange>[],
      );
    }
    final changes = <MemoryRevisionFieldChange>[];
    void compare(String field, Object? before, Object? after) {
      final beforeValue = before is List ? jsonEncode(before) : before;
      final afterValue = after is List ? jsonEncode(after) : after;
      if (beforeValue != afterValue) {
        changes.add(
          MemoryRevisionFieldChange(field: field, before: before, after: after),
        );
      }
    }

    compare('what', from.episode.what, to.episode.what);
    compare(
      'when',
      from.episode.when.toUtc().toIso8601String(),
      to.episode.when.toUtc().toIso8601String(),
    );
    compare('entities', from.episode.entities, to.episode.entities);
    compare('emotion', from.episode.emotion, to.episode.emotion);
    compare('salience', from.episode.salience, to.episode.salience);
    compare(
      'reviewState',
      from.episode.reviewState.name,
      to.episode.reviewState.name,
    );
    compare(
      'expiresAt',
      from.episode.expiresAt?.toUtc().toIso8601String(),
      to.episode.expiresAt?.toUtc().toIso8601String(),
    );
    compare(
      'retentionClass',
      from.episode.retentionClass.name,
      to.episode.retentionClass.name,
    );
    compare(
      'sourceRefs',
      from.episode.sourceRefs.map((source) => source.toJson()).toList(),
      to.episode.sourceRefs.map((source) => source.toJson()).toList(),
    );
    return MemoryRevisionDiff(
      fromEpisodeId: fromEpisodeId,
      toEpisodeId: toEpisodeId,
      sameLineage: true,
      changes: List<MemoryRevisionFieldChange>.unmodifiable(changes),
    );
  }

  Future<int?> _lineageRoot(Episode episode) async {
    var current = episode;
    final visited = <int>{episode.id!};
    for (var depth = 0; depth < maxRevisionDepth; depth++) {
      final prior = current.supersedesId;
      if (prior == null) return current.id;
      if (!visited.add(prior)) return null;
      final entry = await _entryFor(prior);
      if (entry == null) return null;
      current = entry.episode;
    }
    return null;
  }

  Future<int?> _trustedLineageId(MemoryLedgerEntry entry) async {
    final episodeId = entry.episode.id;
    if (episodeId == null) return null;
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(episodeId)
        .get(_database);
    if (governance == null) {
      return entry.episode.sourceType == EpisodeSourceType.legacyUnknown
          ? _lineageRoot(entry.episode)
          : null;
    }
    if (governance['schemaVersion'] != 1 ||
        governance['accountScopeDigest'] != _accountScopeDigest ||
        governance['episodeId'] != episodeId ||
        governance['reviewState'] != entry.episode.reviewState.name) {
      return null;
    }
    final storedLineageId = governance['lineageId'];
    if (storedLineageId == null) {
      // Rows written before the lineage-head sidecar was introduced remain
      // readable; once governed, both adjacent revisions receive a stable id.
      return _lineageRoot(entry.episode);
    }
    if (storedLineageId is! int ||
        storedLineageId < 1 ||
        storedLineageId > _maxSafeStoredInt) {
      return null;
    }
    return storedLineageId;
  }

  Future<MemorySourceTranscriptResult> _sourceTranscript(
    EpisodeSourceRef source,
  ) async {
    final chatMatch = _chatSourcePattern.firstMatch(source.sourceId);
    if (chatMatch != null &&
        (source.origin == EpisodeSourceOrigin.user ||
            source.origin == EpisodeSourceOrigin.agent)) {
      final recordId = int.parse(chatMatch.group(1)!);
      final raw = await MemoryGovernanceStores.chatMessages
          .record(recordId)
          .get(_database);
      final content = raw?['content'];
      final origin = raw?['turnOrigin'];
      final assistant = source.origin == EpisodeSourceOrigin.agent;
      final sender = raw?['senderId'];
      final validRole = assistant
          ? (sender is String &&
                sender.isNotEmpty &&
                sender != 'user' &&
                raw?['receiverId'] == 'user' &&
                raw?['isUserMessage'] == false &&
                (raw?['deliveryStatus'] == null ||
                    raw?['deliveryStatus'] == 'published'))
          : (sender == 'user' && raw?['isUserMessage'] == true);
      final valid =
          raw != null &&
          raw['sessionId'] == source.sessionId &&
          validRole &&
          origin is String &&
          ChatMessageTurnOrigins.humanAuthored.contains(origin) &&
          content is String &&
          content.isNotEmpty &&
          content.runes.length <= maxSourceRunes &&
          _digest(content) == source.contentHash;
      return MemorySourceTranscriptResult(
        status: valid
            ? MemorySourceTranscriptStatus.verified
            : MemorySourceTranscriptStatus.integrityFailure,
        sourceId: source.sourceId,
        content: valid ? content : null,
        reason: valid ? null : 'conversation_source_integrity_failure',
      );
    }
    final importedMatch = _importedSourcePattern.firstMatch(source.sourceId);
    if (importedMatch != null &&
        source.origin == EpisodeSourceOrigin.imported) {
      final raw = await MemoryGovernanceStores.sourceMaterial
          .record(source.sourceId)
          .get(_database);
      final content = raw?['canonicalMaterial'];
      final sourceKind = raw?['sourceKind'];
      final sourceIdentity = importedMatch.group(1)!;
      final validSourceKind =
          sourceKind is String &&
          sourceKind.isNotEmpty &&
          sourceKind.trim() == sourceKind &&
          sourceKind.length <= 64;
      final expectedSessionId = validSourceKind
          ? '$sourceKind:${sourceIdentity.substring(0, 32)}'
          : null;
      final valid =
          raw != null &&
          raw['schemaVersion'] == 1 &&
          raw['accountScopeDigest'] == _accountScopeDigest &&
          raw['sourceId'] == source.sourceId &&
          validSourceKind &&
          source.sessionId == expectedSessionId &&
          raw['contentHash'] == source.contentHash &&
          content is String &&
          content.isNotEmpty &&
          content.runes.length <= maxSourceRunes &&
          _digest(content) == source.contentHash;
      return MemorySourceTranscriptResult(
        status: valid
            ? MemorySourceTranscriptStatus.verified
            : MemorySourceTranscriptStatus.integrityFailure,
        sourceId: source.sourceId,
        content: valid ? content : null,
        reason: valid ? null : 'imported_source_integrity_failure',
      );
    }
    return MemorySourceTranscriptResult(
      status: MemorySourceTranscriptStatus.unavailable,
      sourceId: source.sourceId,
      reason: 'source_transcript_unavailable',
    );
  }

  Future<LegacyMemoryFactsMigrationReport> _migrateLegacyFacts({
    required SharedPreferences preferences,
    required String storageNamespace,
    required int limit,
  }) async {
    if (limit < 1 || limit > maxMigrationBatchSize) {
      throw ArgumentError.value(limit, 'limit');
    }
    final storageKey = legacyFactsStorageKey(storageNamespace);
    final facts = preferences.getStringList(storageKey) ?? const <String>[];
    if (_effectiveMode() != FeatureRolloutMode.enforce) {
      return LegacyMemoryFactsMigrationReport(
        imported: 0,
        alreadyMigrated: 0,
        failed: 0,
        remaining: facts.length,
        complete: false,
        skippedReason: 'memory_v2_not_enforced',
      );
    }
    if (facts.length > _maxLegacyFacts) {
      return LegacyMemoryFactsMigrationReport(
        imported: 0,
        alreadyMigrated: 0,
        failed: facts.length,
        remaining: facts.length,
        complete: false,
        skippedReason: 'legacy_fact_list_too_large',
      );
    }
    final sourceListDigest = _digest(jsonEncode(facts));
    final stateKey = _digest(
      'legacy-memory-fact-state-v1:$_accountScopeDigest:$storageKey',
    );
    final stateRecord = MemoryGovernanceStores.legacyFactMigrationState.record(
      stateKey,
    );
    final storedState = await stateRecord.get(_database);
    if (storedState != null &&
        (storedState['schemaVersion'] != 1 ||
            storedState['accountScopeDigest'] != _accountScopeDigest ||
            storedState['stateKey'] != stateKey ||
            storedState['sourceListDigest'] is! String ||
            storedState['phase'] is! String ||
            storedState['nextIndex'] is! int ||
            storedState['cycleFailures'] is! int ||
            storedState['attempt'] is! int)) {
      return LegacyMemoryFactsMigrationReport(
        imported: 0,
        alreadyMigrated: 0,
        failed: 0,
        remaining: facts.length,
        complete: false,
        skippedReason: 'legacy_fact_migration_state_invalid',
      );
    }
    final sameSource = storedState?['sourceListDigest'] == sourceListDigest;
    var phase = sameSource
        ? (storedState?['phase'] as String? ?? 'scan')
        : 'scan';
    var nextIndex = sameSource ? (storedState?['nextIndex'] as int? ?? 0) : 0;
    var cycleFailures = sameSource
        ? (storedState?['cycleFailures'] as int? ?? 0)
        : 0;
    final attempt = (storedState?['attempt'] as int? ?? 0) + 1;
    if ((phase != 'scan' &&
            phase != 'retry' &&
            phase != 'verify' &&
            phase != 'complete') ||
        nextIndex < 0 ||
        nextIndex > facts.length ||
        cycleFailures < 0) {
      return LegacyMemoryFactsMigrationReport(
        imported: 0,
        alreadyMigrated: 0,
        failed: 0,
        remaining: facts.length,
        complete: false,
        skippedReason: 'legacy_fact_migration_state_invalid',
      );
    }
    if (phase == 'complete') {
      // A completed state is a bounded verification checkpoint, not a reason
      // to trust per-fact mappings forever. Rechecking at most [limit] rows per
      // call self-heals a crash or partial store loss via coordinator dedup.
      phase = 'verify';
      nextIndex = 0;
      cycleFailures = 0;
    }
    var imported = 0;
    var alreadyMigrated = 0;
    var failed = 0;
    final endIndex = math.min(facts.length, nextIndex + limit);
    for (var index = nextIndex; index < endIndex; index++) {
      if (_effectiveMode() != FeatureRolloutMode.enforce) {
        await stateRecord.put(_database, <String, Object?>{
          'schemaVersion': 1,
          'accountScopeDigest': _accountScopeDigest,
          'stateKey': stateKey,
          'sourceListDigest': sourceListDigest,
          'phase': phase,
          'nextIndex': nextIndex,
          'cycleFailures': cycleFailures,
          'attempt': attempt,
          'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
        });
        return LegacyMemoryFactsMigrationReport(
          imported: imported,
          alreadyMigrated: alreadyMigrated,
          failed: failed,
          remaining: facts.length - nextIndex,
          complete: false,
          skippedReason: 'memory_v2_not_enforced',
        );
      }
      final fact = facts[index];
      final sourceKey = _digest(
        'legacy-memory-fact-v1:$_accountScopeDigest:$storageKey:$fact',
      );
      final journal = await MemoryGovernanceStores.legacyFactMigrations
          .record(sourceKey)
          .get(_database);
      final factHash = _digest(fact);
      if (journal?['schemaVersion'] == 1 &&
          journal?['accountScopeDigest'] == _accountScopeDigest &&
          journal?['sourceKey'] == sourceKey &&
          journal?['factHash'] == factHash &&
          journal?['complete'] == true &&
          await _validCompletedLegacyFactJournal(
            journal: journal!,
            sourceKey: sourceKey,
            fact: fact,
            factHash: factHash,
          )) {
        alreadyMigrated++;
      } else {
        String? failureReason;
        final normalized = fact.trim();
        if (normalized.isEmpty || fact.runes.length > maxSourceRunes) {
          failureReason = 'legacy_fact_invalid';
        } else {
          try {
            final result = await _bus.writeImportedEpisode(
              Episode(
                when: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
                what: normalized,
                kind: EpisodeKind.fact,
                retentionClass: EpisodeRetentionClass.durable,
              ),
              sourceKind: _legacyFactsSourceKind,
              sourceKey: sourceKey,
              canonicalMaterial: fact,
            );
            final importedResult =
                result.disposition == MemoryWriteDisposition.quarantined &&
                result.created &&
                result.episode?.reviewState == EpisodeReviewState.pending;
            final duplicateResult =
                result.disposition == MemoryWriteDisposition.duplicate &&
                result.episode != null;
            if (importedResult || duplicateResult) {
              await MemoryGovernanceStores.legacyFactMigrations
                  .record(sourceKey)
                  .put(_database, <String, Object?>{
                    'schemaVersion': 1,
                    'accountScopeDigest': _accountScopeDigest,
                    'sourceKey': sourceKey,
                    'factHash': factHash,
                    'index': index,
                    'episodeId': result.episodeId,
                    'reason': null,
                    'attempt': attempt,
                    'complete': true,
                    'migratedAt': _clock().toUtc().millisecondsSinceEpoch,
                  });
              if (importedResult) {
                imported++;
              } else {
                alreadyMigrated++;
              }
            } else {
              failureReason = _boundedMigrationReason(
                result.reason ?? 'import_${result.disposition.name}',
              );
            }
          } on Object catch (error) {
            failureReason = 'import_exception_${error.runtimeType}';
          }
        }
        if (failureReason != null) {
          failed++;
          cycleFailures++;
          await MemoryGovernanceStores.legacyFactMigrations
              .record(sourceKey)
              .put(_database, <String, Object?>{
                'schemaVersion': 1,
                'accountScopeDigest': _accountScopeDigest,
                'sourceKey': sourceKey,
                'factHash': factHash,
                'index': index,
                'episodeId': null,
                'reason': failureReason,
                'attempt': attempt,
                'complete': false,
                'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
              });
        }
      }
      nextIndex = index + 1;
      await stateRecord.put(_database, <String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': _accountScopeDigest,
        'stateKey': stateKey,
        'sourceListDigest': sourceListDigest,
        'phase': phase,
        'nextIndex': nextIndex,
        'cycleFailures': cycleFailures,
        'attempt': attempt,
        'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
      });
    }
    var complete = false;
    var remaining = math.max(0, facts.length - nextIndex);
    if (nextIndex == facts.length) {
      if (cycleFailures == 0) {
        phase = 'complete';
        complete = true;
        remaining = 0;
      } else {
        phase = 'retry';
        nextIndex = 0;
        remaining = cycleFailures;
        cycleFailures = 0;
      }
      await stateRecord.put(_database, <String, Object?>{
        'schemaVersion': 1,
        'accountScopeDigest': _accountScopeDigest,
        'stateKey': stateKey,
        'sourceListDigest': sourceListDigest,
        'phase': phase,
        'nextIndex': nextIndex,
        'cycleFailures': cycleFailures,
        'attempt': attempt,
        'updatedAt': _clock().toUtc().millisecondsSinceEpoch,
      });
    }
    return LegacyMemoryFactsMigrationReport(
      imported: imported,
      alreadyMigrated: alreadyMigrated,
      failed: failed,
      remaining: remaining,
      complete: complete,
    );
  }

  static String _boundedMigrationReason(String reason) {
    final normalized = reason.trim();
    if (normalized.isEmpty) return 'import_rejected';
    return String.fromCharCodes(normalized.runes.take(128));
  }

  Future<bool> _validCompletedLegacyFactJournal({
    required Map<String, Object?> journal,
    required String sourceKey,
    required String fact,
    required String factHash,
  }) async {
    final episodeId = journal['episodeId'];
    if (episodeId is! int || episodeId < 1 || episodeId > _maxSafeStoredInt) {
      return false;
    }
    final episodeRaw = await MemoryGovernanceStores.episodes
        .record(episodeId)
        .get(_database);
    if (episodeRaw == null) return false;
    late final Episode episode;
    try {
      episode = Episode.fromJson(episodeRaw)..id = episodeId;
    } on Object {
      return false;
    }
    final governance = await MemoryGovernanceStores.episodeGovernance
        .record(episodeId)
        .get(_database);
    if (governance == null ||
        governance['schemaVersion'] != 1 ||
        governance['accountScopeDigest'] != _accountScopeDigest ||
        governance['episodeId'] != episodeId ||
        governance['reviewState'] != episode.reviewState.name) {
      return false;
    }
    final sourceIdentity = _digest(
      'imported-source-v1:$_legacyFactsSourceKind:$sourceKey',
    );
    final sourceId = 'imported:$sourceIdentity';
    final expectedSessionId =
        '$_legacyFactsSourceKind:${sourceIdentity.substring(0, 32)}';
    final expectedWhat = fact.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (episode.kind != EpisodeKind.fact ||
        episode.sourceType != EpisodeSourceType.inherited ||
        episode.retentionClass != EpisodeRetentionClass.durable ||
        episode.what != expectedWhat ||
        episode.sourceRefs.length != 1) {
      return false;
    }
    final sourceRef = episode.sourceRefs.single;
    if (sourceRef.sourceId != sourceId ||
        sourceRef.sessionId != expectedSessionId ||
        sourceRef.origin != EpisodeSourceOrigin.imported ||
        sourceRef.contentHash != factHash) {
      return false;
    }
    final sourceMaterial = await MemoryGovernanceStores.sourceMaterial
        .record(sourceId)
        .get(_database);
    return sourceMaterial != null &&
        sourceMaterial['schemaVersion'] == 1 &&
        sourceMaterial['accountScopeDigest'] == _accountScopeDigest &&
        sourceMaterial['sourceId'] == sourceId &&
        sourceMaterial['sourceKind'] == _legacyFactsSourceKind &&
        sourceMaterial['contentHash'] == factHash &&
        sourceMaterial['canonicalMaterial'] == fact;
  }

  MemoryBus get _bus => _memoryBus ?? appServices.find<MemoryBus>();

  FeatureRolloutMode _effectiveMode() {
    final override = _memoryV2ModeOverride;
    if (override != null) return override();
    return appServices.maybeFind<MaasoFeatureFlagService>()?.effectiveMode(
          MaasoFeatureFlag.memoryV2,
        ) ??
        FeatureRolloutMode.off;
  }

  Future<int> _latestEpisodeId() async {
    final count = await MemoryGovernanceStores.episodes.count(_database);
    if (count == 0) return 0;
    final rows = await MemoryGovernanceStores.episodes.find(
      _database,
      finder: Finder(offset: count - 1, limit: 1),
    );
    return rows.isEmpty ? 0 : rows.single.key;
  }

  void _requirePageLimit(int limit) {
    if (limit < 1 || limit > maxPageSize) {
      throw ArgumentError.value(limit, 'limit');
    }
  }

  Future<T> _track<T>(Future<T> Function() operation) {
    if (_retiring || isClosed) {
      return Future<T>.error(StateError('memory_ledger_service_retired'));
    }
    late final Future<T> future;
    late final Future<void> tracked;
    future = Future<T>.sync(operation);
    tracked = future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _inFlight.add(tracked);
    tracked.whenComplete(() => _inFlight.remove(tracked));
    return future;
  }

  @override
  void onClose() {
    _retiring = true;
    super.onClose();
  }
}

String _digest(String value) => sha256.convert(utf8.encode(value)).toString();
