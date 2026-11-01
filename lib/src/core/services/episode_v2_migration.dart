import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:sembast/sembast.dart';

const int _maxJsonInteger = 0x1fffffffffffff;
const int _maxBlockedSourceKeys = 256;
const String _migrationId = 'episodes.unversioned_to_v2';
const String _journalKey = 'episodes.v2';

enum EpisodeV2MigrationPhase {
  disabled,
  shadow,
  running,
  paused,
  completed,
  completedWithIssues;

  bool get isComplete =>
      this == EpisodeV2MigrationPhase.completed ||
      this == EpisodeV2MigrationPhase.completedWithIssues;
}

enum EpisodeV2MigrationFaultPoint { beforeBatchCommit, afterBatchCommit }

typedef EpisodeV2MigrationFaultInjector =
    FutureOr<void> Function(EpisodeV2MigrationFaultPoint point, int revision);

final class EpisodeV2MigrationReport {
  const EpisodeV2MigrationReport({
    required this.phase,
    required this.highWatermarkId,
    required this.lastSourceKey,
    required this.scannedCount,
    required this.legacyCount,
    required this.migratedCount,
    required this.alreadyCurrentCount,
    required this.failureCount,
    required this.blockedSourceKeys,
    required this.revision,
    required this.startedAt,
    required this.updatedAt,
    this.completedAt,
  });

  factory EpisodeV2MigrationReport.disabled(DateTime now) =>
      EpisodeV2MigrationReport(
        phase: EpisodeV2MigrationPhase.disabled,
        highWatermarkId: 0,
        lastSourceKey: 0,
        scannedCount: 0,
        legacyCount: 0,
        migratedCount: 0,
        alreadyCurrentCount: 0,
        failureCount: 0,
        blockedSourceKeys: const <int>[],
        revision: 0,
        startedAt: now.toUtc(),
        updatedAt: now.toUtc(),
      );

  final EpisodeV2MigrationPhase phase;
  final int highWatermarkId;
  final int lastSourceKey;
  final int scannedCount;
  final int legacyCount;
  final int migratedCount;
  final int alreadyCurrentCount;
  final int failureCount;
  final List<int> blockedSourceKeys;
  final int revision;
  final DateTime startedAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  bool get preservesRecordKeys => true;
}

final class EpisodeV2MigrationStep {
  const EpisodeV2MigrationStep(this.report);

  final EpisodeV2MigrationReport report;

  bool get isComplete => report.phase.isComplete;
}

final class EpisodeV2MigrationMapping {
  const EpisodeV2MigrationMapping({
    required this.sourceId,
    required this.targetId,
    required this.sourceDigest,
    required this.targetDigest,
    required this.migratedAt,
  });

  final int sourceId;
  final int targetId;
  final String sourceDigest;
  final String targetDigest;
  final DateTime migratedAt;

  Map<String, Object?> toJson({required String accountScopeDigest}) =>
      <String, Object?>{
        'schemaVersion': 1,
        'migrationId': _migrationId,
        'accountScopeDigest': accountScopeDigest,
        'sourceId': sourceId,
        'targetId': targetId,
        'sourceDigest': sourceDigest,
        'targetDigest': targetDigest,
        'migratedAt': migratedAt.toUtc().millisecondsSinceEpoch,
      };

  factory EpisodeV2MigrationMapping.fromJson(
    Object? source, {
    required int recordId,
    required String accountScopeDigest,
  }) {
    final json = _strictMap(source, 'episode migration mapping');
    const fields = <String>{
      'schemaVersion',
      'migrationId',
      'accountScopeDigest',
      'sourceId',
      'targetId',
      'sourceDigest',
      'targetDigest',
      'migratedAt',
    };
    _requireExactFields(json, fields, 'episode migration mapping');
    final sourceId = _safePositiveInt(json['sourceId'], 'sourceId');
    final targetId = _safePositiveInt(json['targetId'], 'targetId');
    if (json['schemaVersion'] != 1 ||
        json['migrationId'] != _migrationId ||
        json['accountScopeDigest'] != accountScopeDigest ||
        sourceId != recordId ||
        targetId != recordId) {
      throw const FormatException('episode migration mapping is invalid');
    }
    return EpisodeV2MigrationMapping(
      sourceId: sourceId,
      targetId: targetId,
      sourceDigest: _strictDigest(json['sourceDigest'], 'sourceDigest'),
      targetDigest: _strictDigest(json['targetDigest'], 'targetDigest'),
      migratedAt: _strictTimestamp(json['migratedAt'], 'migratedAt'),
    );
  }
}

final class EpisodeV2MigrationIssue {
  const EpisodeV2MigrationIssue({
    required this.sourceId,
    required this.code,
    required this.sourceDigest,
    required this.detectedAt,
  });

  final int sourceId;
  final String code;
  final String sourceDigest;
  final DateTime detectedAt;

  Map<String, Object?> toJson({required String accountScopeDigest}) =>
      <String, Object?>{
        'schemaVersion': 1,
        'migrationId': _migrationId,
        'accountScopeDigest': accountScopeDigest,
        'sourceId': sourceId,
        'code': code,
        'sourceDigest': sourceDigest,
        'detectedAt': detectedAt.toUtc().millisecondsSinceEpoch,
      };

  factory EpisodeV2MigrationIssue.fromJson(
    Object? source, {
    required int recordId,
    required String accountScopeDigest,
  }) {
    final json = _strictMap(source, 'episode migration issue');
    const fields = <String>{
      'schemaVersion',
      'migrationId',
      'accountScopeDigest',
      'sourceId',
      'code',
      'sourceDigest',
      'detectedAt',
    };
    _requireExactFields(json, fields, 'episode migration issue');
    final sourceId = _safePositiveInt(json['sourceId'], 'sourceId');
    final code = json['code'];
    if (json['schemaVersion'] != 1 ||
        json['migrationId'] != _migrationId ||
        json['accountScopeDigest'] != accountScopeDigest ||
        sourceId != recordId ||
        code is! String ||
        !const <String>{
          'invalid_legacy_episode',
          'invalid_v2_episode',
          'unsupported_episode_schema',
        }.contains(code)) {
      throw const FormatException('episode migration issue is invalid');
    }
    return EpisodeV2MigrationIssue(
      sourceId: sourceId,
      code: code,
      sourceDigest: _strictDigest(json['sourceDigest'], 'sourceDigest'),
      detectedAt: _strictTimestamp(json['detectedAt'], 'detectedAt'),
    );
  }
}

final class EpisodeV2Migrator {
  EpisodeV2Migrator({
    required Database database,
    required String accountScopeDigest,
    DateTime Function()? clock,
    int batchSize = 64,
    EpisodeV2MigrationFaultInjector? faultInjector,
  }) : _database = database,
       _accountScopeDigest = accountScopeDigest,
       _clock = clock ?? DateTime.now,
       _batchSize = batchSize,
       _faultInjector = faultInjector {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(accountScopeDigest)) {
      throw ArgumentError.value(
        accountScopeDigest,
        'accountScopeDigest',
        'must be a SHA-256 digest',
      );
    }
    if (batchSize < 1 || batchSize > 256) {
      throw ArgumentError.value(batchSize, 'batchSize', 'must be 1..256');
    }
  }

  static final StoreRef<int, Map<String, Object?>> _episodeStore =
      intMapStoreFactory.store('episodes');
  static final StoreRef<String, Map<String, Object?>> _journalStore =
      StoreRef<String, Map<String, Object?>>('episode_migrations.v1');
  static final StoreRef<int, Map<String, Object?>> _mappingStore =
      intMapStoreFactory.store('episode_v2_mappings.v1');
  static final StoreRef<int, Map<String, Object?>> _issueStore =
      intMapStoreFactory.store('episode_v2_migration_issues.v1');

  final Database _database;
  final String _accountScopeDigest;
  final DateTime Function() _clock;
  final int _batchSize;
  final EpisodeV2MigrationFaultInjector? _faultInjector;

  Future<EpisodeV2MigrationReport> scan({
    int? maxBatches,
    bool Function()? shouldPause,
  }) async {
    _validateMaxBatches(maxBatches);
    final startedAt = _clock().toUtc();
    final highWatermarkId = await _latestEpisodeId(_database);
    var lastSourceKey = 0;
    var scannedCount = 0;
    var legacyCount = 0;
    var alreadyCurrentCount = 0;
    var failureCount = 0;
    final blocked = <int>[];
    var batches = 0;

    while (lastSourceKey < highWatermarkId &&
        !(shouldPause?.call() ?? false) &&
        (maxBatches == null || batches < maxBatches)) {
      final rows = await _episodeStore.find(
        _database,
        finder: Finder(
          filter: Filter.greaterThan(Field.key, lastSourceKey),
          sortOrders: <SortOrder>[SortOrder(Field.key)],
          limit: _batchSize,
        ),
      );
      final bounded = rows
          .where((row) => row.key <= highWatermarkId)
          .toList(growable: false);
      if (bounded.isEmpty) {
        lastSourceKey = highWatermarkId;
        break;
      }
      batches++;
      for (final row in bounded) {
        lastSourceKey = row.key;
        scannedCount++;
        final classification = _classify(row.value);
        switch (classification) {
          case _EpisodeSchemaClassification.legacy:
            legacyCount++;
            break;
          case _EpisodeSchemaClassification.current:
            alreadyCurrentCount++;
            break;
          case _EpisodeSchemaClassification.invalid:
            failureCount++;
            if (blocked.length < _maxBlockedSourceKeys) blocked.add(row.key);
            break;
        }
      }
    }
    final updatedAt = _clock().toUtc();
    return EpisodeV2MigrationReport(
      phase: EpisodeV2MigrationPhase.shadow,
      highWatermarkId: highWatermarkId,
      lastSourceKey: lastSourceKey,
      scannedCount: scannedCount,
      legacyCount: legacyCount,
      migratedCount: 0,
      alreadyCurrentCount: alreadyCurrentCount,
      failureCount: failureCount,
      blockedSourceKeys: List<int>.unmodifiable(blocked),
      revision: 0,
      startedAt: startedAt,
      updatedAt: updatedAt,
    );
  }

  Future<EpisodeV2MigrationStep> migrateNextBatch() async {
    late _Journal committed;
    await _database.transaction((transaction) async {
      final now = _clock().toUtc();
      final journalRecord = _journalStore.record(_journalKey);
      final stored = await journalRecord.get(transaction);
      final latestId = await _latestEpisodeId(transaction);
      var journal = stored == null
          ? _Journal.initial(
              accountScopeDigest: _accountScopeDigest,
              highWatermarkId: latestId,
              now: now,
            )
          : _Journal.fromJson(stored, accountScopeDigest: _accountScopeDigest);

      if (latestId > journal.highWatermarkId) {
        journal = journal.reopen(highWatermarkId: latestId, now: now);
      } else if (journal.phase.isComplete) {
        committed = journal;
        return;
      } else if (journal.phase == EpisodeV2MigrationPhase.paused) {
        journal = journal.copyWith(
          phase: EpisodeV2MigrationPhase.running,
          updatedAt: now,
          revision: journal.revision + 1,
        );
      }

      final rows = await _episodeStore.find(
        transaction,
        finder: Finder(
          filter: Filter.greaterThan(Field.key, journal.lastSourceKey),
          sortOrders: <SortOrder>[SortOrder(Field.key)],
          limit: _batchSize,
        ),
      );
      final bounded = rows
          .where((row) => row.key <= journal.highWatermarkId)
          .toList(growable: false);

      if (bounded.isEmpty) {
        final phase = journal.blockedSourceKeys.isEmpty
            ? EpisodeV2MigrationPhase.completed
            : EpisodeV2MigrationPhase.completedWithIssues;
        journal = journal.copyWith(
          phase: phase,
          lastSourceKey: journal.highWatermarkId,
          completedAt: now,
          updatedAt: now,
          revision: journal.revision + 1,
        );
      } else {
        for (final row in bounded) {
          journal = await _migrateRow(transaction, row, journal, now);
        }
        final reachedHighWatermark =
            journal.lastSourceKey >= journal.highWatermarkId;
        final phase = !reachedHighWatermark
            ? EpisodeV2MigrationPhase.running
            : journal.blockedSourceKeys.isEmpty
            ? EpisodeV2MigrationPhase.completed
            : EpisodeV2MigrationPhase.completedWithIssues;
        journal = journal.copyWith(
          phase: phase,
          completedAt: reachedHighWatermark ? now : null,
          clearCompletedAt: !reachedHighWatermark,
          updatedAt: now,
          revision: journal.revision + 1,
        );
      }

      await journalRecord.put(transaction, journal.toJson());
      await Future<void>.sync(
        () => _faultInjector?.call(
          EpisodeV2MigrationFaultPoint.beforeBatchCommit,
          journal.revision,
        ),
      );
      committed = journal;
    });
    await Future<void>.sync(
      () => _faultInjector?.call(
        EpisodeV2MigrationFaultPoint.afterBatchCommit,
        committed.revision,
      ),
    );
    return EpisodeV2MigrationStep(committed.toReport());
  }

  Future<EpisodeV2MigrationReport?> readReport() async {
    final stored = await _journalStore.record(_journalKey).get(_database);
    if (stored == null) return null;
    return _Journal.fromJson(
      stored,
      accountScopeDigest: _accountScopeDigest,
    ).toReport();
  }

  Future<EpisodeV2MigrationReport?> pause() async {
    late EpisodeV2MigrationReport? report;
    await _database.transaction((transaction) async {
      final record = _journalStore.record(_journalKey);
      final stored = await record.get(transaction);
      if (stored == null) {
        report = null;
        return;
      }
      var journal = _Journal.fromJson(
        stored,
        accountScopeDigest: _accountScopeDigest,
      );
      if (!journal.phase.isComplete &&
          journal.phase != EpisodeV2MigrationPhase.paused) {
        final now = _clock().toUtc();
        journal = journal.copyWith(
          phase: EpisodeV2MigrationPhase.paused,
          updatedAt: now,
          revision: journal.revision + 1,
          clearCompletedAt: true,
        );
        await record.put(transaction, journal.toJson());
      }
      report = journal.toReport();
    });
    return report;
  }

  Future<EpisodeV2MigrationMapping?> mappingFor(int sourceId) async {
    _safePositiveInt(sourceId, 'sourceId');
    final stored = await _mappingStore.record(sourceId).get(_database);
    if (stored == null) return null;
    return EpisodeV2MigrationMapping.fromJson(
      stored,
      recordId: sourceId,
      accountScopeDigest: _accountScopeDigest,
    );
  }

  Future<EpisodeV2MigrationIssue?> issueFor(int sourceId) async {
    _safePositiveInt(sourceId, 'sourceId');
    final stored = await _issueStore.record(sourceId).get(_database);
    if (stored == null) return null;
    return EpisodeV2MigrationIssue.fromJson(
      stored,
      recordId: sourceId,
      accountScopeDigest: _accountScopeDigest,
    );
  }

  Future<_Journal> _migrateRow(
    Transaction transaction,
    RecordSnapshot<int, Map<String, Object?>> row,
    _Journal journal,
    DateTime now,
  ) async {
    final sourceDigest = _canonicalDigest(row.value);
    final classification = _classify(row.value);
    switch (classification) {
      case _EpisodeSchemaClassification.legacy:
        final episode = Episode.fromJson(row.value);
        final migrated = episode.toJson();
        final targetDigest = _canonicalDigest(migrated);
        final mappingRecord = _mappingStore.record(row.key);
        final existingMapping = await mappingRecord.get(transaction);
        if (existingMapping != null) {
          EpisodeV2MigrationMapping.fromJson(
            existingMapping,
            recordId: row.key,
            accountScopeDigest: _accountScopeDigest,
          );
        }
        await _episodeStore.record(row.key).put(transaction, migrated);
        await mappingRecord.put(
          transaction,
          EpisodeV2MigrationMapping(
            sourceId: row.key,
            targetId: row.key,
            sourceDigest: sourceDigest,
            targetDigest: targetDigest,
            migratedAt: now,
          ).toJson(accountScopeDigest: _accountScopeDigest),
        );
        return journal.advance(
          sourceKey: row.key,
          legacy: true,
          migrated: true,
        );
      case _EpisodeSchemaClassification.current:
        return journal.advance(sourceKey: row.key, alreadyCurrent: true);
      case _EpisodeSchemaClassification.invalid:
        final code = _issueCode(row.value);
        final issueRecord = _issueStore.record(row.key);
        final existingIssue = await issueRecord.get(transaction);
        if (existingIssue != null) {
          EpisodeV2MigrationIssue.fromJson(
            existingIssue,
            recordId: row.key,
            accountScopeDigest: _accountScopeDigest,
          );
        }
        await issueRecord.put(
          transaction,
          EpisodeV2MigrationIssue(
            sourceId: row.key,
            code: code,
            sourceDigest: sourceDigest,
            detectedAt: now,
          ).toJson(accountScopeDigest: _accountScopeDigest),
        );
        return journal.advance(sourceKey: row.key, failure: true);
    }
  }

  static _EpisodeSchemaClassification _classify(Map<String, Object?> source) {
    try {
      Episode.fromJson(source);
      if (!source.containsKey('schemaVersion')) {
        return _EpisodeSchemaClassification.legacy;
      }
      return source['schemaVersion'] == Episode.currentSchemaVersion
          ? _EpisodeSchemaClassification.current
          : _EpisodeSchemaClassification.invalid;
    } on FormatException {
      return _EpisodeSchemaClassification.invalid;
    }
  }

  static String _issueCode(Map<String, Object?> source) {
    if (!source.containsKey('schemaVersion')) {
      return 'invalid_legacy_episode';
    }
    if (source['schemaVersion'] == Episode.currentSchemaVersion) {
      return 'invalid_v2_episode';
    }
    return 'unsupported_episode_schema';
  }

  static Future<int> _latestEpisodeId(DatabaseClient client) async {
    final rows = await _episodeStore.find(
      client,
      finder: Finder(
        sortOrders: <SortOrder>[SortOrder(Field.key, false)],
        limit: 1,
      ),
    );
    return rows.isEmpty ? 0 : rows.single.key;
  }
}

enum _EpisodeSchemaClassification { legacy, current, invalid }

final class _Journal {
  const _Journal({
    required this.accountScopeDigest,
    required this.phase,
    required this.highWatermarkId,
    required this.lastSourceKey,
    required this.scannedCount,
    required this.legacyCount,
    required this.migratedCount,
    required this.alreadyCurrentCount,
    required this.failureCount,
    required this.blockedSourceKeys,
    required this.revision,
    required this.startedAt,
    required this.updatedAt,
    required this.completedAt,
  });

  factory _Journal.initial({
    required String accountScopeDigest,
    required int highWatermarkId,
    required DateTime now,
  }) => _Journal(
    accountScopeDigest: accountScopeDigest,
    phase: EpisodeV2MigrationPhase.running,
    highWatermarkId: highWatermarkId,
    lastSourceKey: 0,
    scannedCount: 0,
    legacyCount: 0,
    migratedCount: 0,
    alreadyCurrentCount: 0,
    failureCount: 0,
    blockedSourceKeys: const <int>[],
    revision: 0,
    startedAt: now,
    updatedAt: now,
    completedAt: null,
  );

  final String accountScopeDigest;
  final EpisodeV2MigrationPhase phase;
  final int highWatermarkId;
  final int lastSourceKey;
  final int scannedCount;
  final int legacyCount;
  final int migratedCount;
  final int alreadyCurrentCount;
  final int failureCount;
  final List<int> blockedSourceKeys;
  final int revision;
  final DateTime startedAt;
  final DateTime updatedAt;
  final DateTime? completedAt;

  _Journal advance({
    required int sourceKey,
    bool legacy = false,
    bool migrated = false,
    bool alreadyCurrent = false,
    bool failure = false,
  }) {
    if (sourceKey <= lastSourceKey || sourceKey > highWatermarkId) {
      throw StateError('episode migration cursor is not monotonic');
    }
    final blocked = failure
        ? _appendBlocked(blockedSourceKeys, sourceKey)
        : blockedSourceKeys;
    return copyWith(
      lastSourceKey: sourceKey,
      scannedCount: _checkedIncrement(scannedCount),
      legacyCount: legacy ? _checkedIncrement(legacyCount) : legacyCount,
      migratedCount: migrated
          ? _checkedIncrement(migratedCount)
          : migratedCount,
      alreadyCurrentCount: alreadyCurrent
          ? _checkedIncrement(alreadyCurrentCount)
          : alreadyCurrentCount,
      failureCount: failure ? _checkedIncrement(failureCount) : failureCount,
      blockedSourceKeys: blocked,
    );
  }

  _Journal reopen({required int highWatermarkId, required DateTime now}) {
    if (highWatermarkId < this.highWatermarkId ||
        highWatermarkId < lastSourceKey) {
      throw StateError('episode migration watermark regressed');
    }
    return copyWith(
      phase: EpisodeV2MigrationPhase.running,
      highWatermarkId: highWatermarkId,
      updatedAt: now,
      revision: revision + 1,
      clearCompletedAt: true,
    );
  }

  _Journal copyWith({
    EpisodeV2MigrationPhase? phase,
    int? highWatermarkId,
    int? lastSourceKey,
    int? scannedCount,
    int? legacyCount,
    int? migratedCount,
    int? alreadyCurrentCount,
    int? failureCount,
    List<int>? blockedSourceKeys,
    int? revision,
    DateTime? updatedAt,
    DateTime? completedAt,
    bool clearCompletedAt = false,
  }) => _Journal(
    accountScopeDigest: accountScopeDigest,
    phase: phase ?? this.phase,
    highWatermarkId: highWatermarkId ?? this.highWatermarkId,
    lastSourceKey: lastSourceKey ?? this.lastSourceKey,
    scannedCount: scannedCount ?? this.scannedCount,
    legacyCount: legacyCount ?? this.legacyCount,
    migratedCount: migratedCount ?? this.migratedCount,
    alreadyCurrentCount: alreadyCurrentCount ?? this.alreadyCurrentCount,
    failureCount: failureCount ?? this.failureCount,
    blockedSourceKeys: List<int>.unmodifiable(
      blockedSourceKeys ?? this.blockedSourceKeys,
    ),
    revision: revision ?? this.revision,
    startedAt: startedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    completedAt: clearCompletedAt ? null : completedAt ?? this.completedAt,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'migrationId': _migrationId,
    'accountScopeDigest': accountScopeDigest,
    'sourceStore': 'episodes',
    'targetStore': 'episodes',
    'identityKeyMapping': true,
    'targetEpisodeSchemaVersion': Episode.currentSchemaVersion,
    'phase': phase.name,
    'highWatermarkId': highWatermarkId,
    'lastSourceKey': lastSourceKey,
    'scannedCount': scannedCount,
    'legacyCount': legacyCount,
    'migratedCount': migratedCount,
    'alreadyCurrentCount': alreadyCurrentCount,
    'failureCount': failureCount,
    'blockedSourceKeys': blockedSourceKeys,
    'revision': revision,
    'startedAt': startedAt.toUtc().millisecondsSinceEpoch,
    'updatedAt': updatedAt.toUtc().millisecondsSinceEpoch,
    'completedAt': completedAt?.toUtc().millisecondsSinceEpoch,
  };

  factory _Journal.fromJson(
    Object? source, {
    required String accountScopeDigest,
  }) {
    final json = _strictMap(source, 'episode migration journal');
    const fields = <String>{
      'schemaVersion',
      'migrationId',
      'accountScopeDigest',
      'sourceStore',
      'targetStore',
      'identityKeyMapping',
      'targetEpisodeSchemaVersion',
      'phase',
      'highWatermarkId',
      'lastSourceKey',
      'scannedCount',
      'legacyCount',
      'migratedCount',
      'alreadyCurrentCount',
      'failureCount',
      'blockedSourceKeys',
      'revision',
      'startedAt',
      'updatedAt',
      'completedAt',
    };
    _requireExactFields(json, fields, 'episode migration journal');
    if (json['schemaVersion'] != 1 ||
        json['migrationId'] != _migrationId ||
        json['accountScopeDigest'] != accountScopeDigest ||
        json['sourceStore'] != 'episodes' ||
        json['targetStore'] != 'episodes' ||
        json['identityKeyMapping'] != true ||
        json['targetEpisodeSchemaVersion'] != Episode.currentSchemaVersion) {
      throw const FormatException('episode migration journal is invalid');
    }
    final phase = _parsePhase(json['phase']);
    final highWatermarkId = _safeNonNegativeInt(
      json['highWatermarkId'],
      'highWatermarkId',
    );
    final lastSourceKey = _safeNonNegativeInt(
      json['lastSourceKey'],
      'lastSourceKey',
    );
    final scannedCount = _safeNonNegativeInt(
      json['scannedCount'],
      'scannedCount',
    );
    final legacyCount = _safeNonNegativeInt(json['legacyCount'], 'legacyCount');
    final migratedCount = _safeNonNegativeInt(
      json['migratedCount'],
      'migratedCount',
    );
    final alreadyCurrentCount = _safeNonNegativeInt(
      json['alreadyCurrentCount'],
      'alreadyCurrentCount',
    );
    final failureCount = _safeNonNegativeInt(
      json['failureCount'],
      'failureCount',
    );
    final revision = _safeNonNegativeInt(json['revision'], 'revision');
    final blockedSourceKeys = _strictIdList(
      json['blockedSourceKeys'],
      'blockedSourceKeys',
      maxLength: _maxBlockedSourceKeys,
    );
    final startedAt = _strictTimestamp(json['startedAt'], 'startedAt');
    final updatedAt = _strictTimestamp(json['updatedAt'], 'updatedAt');
    final completedAt = json['completedAt'] == null
        ? null
        : _strictTimestamp(json['completedAt'], 'completedAt');
    if (lastSourceKey > highWatermarkId ||
        legacyCount > scannedCount ||
        migratedCount > legacyCount ||
        alreadyCurrentCount > scannedCount ||
        failureCount > scannedCount ||
        updatedAt.isBefore(startedAt) ||
        (completedAt != null && completedAt.isBefore(startedAt)) ||
        (phase.isComplete) != (completedAt != null) ||
        (phase == EpisodeV2MigrationPhase.completed &&
            blockedSourceKeys.isNotEmpty) ||
        (phase == EpisodeV2MigrationPhase.completedWithIssues &&
            blockedSourceKeys.isEmpty)) {
      throw const FormatException(
        'episode migration journal values are invalid',
      );
    }
    return _Journal(
      accountScopeDigest: accountScopeDigest,
      phase: phase,
      highWatermarkId: highWatermarkId,
      lastSourceKey: lastSourceKey,
      scannedCount: scannedCount,
      legacyCount: legacyCount,
      migratedCount: migratedCount,
      alreadyCurrentCount: alreadyCurrentCount,
      failureCount: failureCount,
      blockedSourceKeys: blockedSourceKeys,
      revision: revision,
      startedAt: startedAt,
      updatedAt: updatedAt,
      completedAt: completedAt,
    );
  }

  EpisodeV2MigrationReport toReport() => EpisodeV2MigrationReport(
    phase: phase,
    highWatermarkId: highWatermarkId,
    lastSourceKey: lastSourceKey,
    scannedCount: scannedCount,
    legacyCount: legacyCount,
    migratedCount: migratedCount,
    alreadyCurrentCount: alreadyCurrentCount,
    failureCount: failureCount,
    blockedSourceKeys: List<int>.unmodifiable(blockedSourceKeys),
    revision: revision,
    startedAt: startedAt,
    updatedAt: updatedAt,
    completedAt: completedAt,
  );
}

EpisodeV2MigrationPhase _parsePhase(Object? source) => switch (source) {
  'running' => EpisodeV2MigrationPhase.running,
  'paused' => EpisodeV2MigrationPhase.paused,
  'completed' => EpisodeV2MigrationPhase.completed,
  'completedWithIssues' => EpisodeV2MigrationPhase.completedWithIssues,
  _ => throw const FormatException('episode migration phase is invalid'),
};

List<int> _appendBlocked(List<int> source, int value) {
  if (source.contains(value)) return source;
  if (source.length >= _maxBlockedSourceKeys) {
    return source;
  }
  return List<int>.unmodifiable(<int>[...source, value]..sort());
}

Map<String, Object?> _strictMap(Object? source, String label) {
  if (source is! Map) throw FormatException('$label is invalid');
  try {
    return Map<String, Object?>.from(source);
  } on TypeError {
    throw FormatException('$label has invalid keys');
  }
}

void _requireExactFields(
  Map<String, Object?> json,
  Set<String> fields,
  String label,
) {
  if (json.length != fields.length ||
      json.keys.any((key) => !fields.contains(key))) {
    throw FormatException('$label fields are invalid');
  }
}

int _safePositiveInt(Object? source, String field) {
  final value = _safeNonNegativeInt(source, field);
  if (value == 0) throw FormatException('$field must be positive');
  return value;
}

int _safeNonNegativeInt(Object? source, String field) {
  if (source is! int || source < 0 || source > _maxJsonInteger) {
    throw FormatException('$field is invalid');
  }
  return source;
}

int _checkedIncrement(int value) {
  if (value >= _maxJsonInteger) {
    throw StateError('episode migration counter overflow');
  }
  return value + 1;
}

DateTime _strictTimestamp(Object? source, String field) {
  final value = _safeNonNegativeInt(source, field);
  try {
    return DateTime.fromMillisecondsSinceEpoch(value, isUtc: true);
  } on RangeError {
    throw FormatException('$field is invalid');
  }
}

List<int> _strictIdList(
  Object? source,
  String field, {
  required int maxLength,
}) {
  if (source is! List || source.length > maxLength) {
    throw FormatException('$field is invalid');
  }
  final values = source
      .map((value) => _safePositiveInt(value, field))
      .toList(growable: false);
  if (values.toSet().length != values.length) {
    throw FormatException('$field contains duplicates');
  }
  final sorted = values.toList()..sort();
  if (!_listEquals(values, sorted)) {
    throw FormatException('$field must be sorted');
  }
  return List<int>.unmodifiable(values);
}

String _strictDigest(Object? source, String field) {
  if (source is! String || !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(source)) {
    throw FormatException('$field is invalid');
  }
  return source;
}

String _canonicalDigest(Map<String, Object?> source) {
  final canonical = _canonicalJsonValue(source);
  return 'sha256:${sha256.convert(utf8.encode(jsonEncode(canonical)))}';
}

Object? _canonicalJsonValue(Object? source) {
  if (source is Map) {
    final keys = source.keys.map((key) {
      if (key is! String) {
        throw const FormatException('episode map key is invalid');
      }
      return key;
    }).toList()..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJsonValue(source[key]),
    };
  }
  if (source is List) {
    return source.map(_canonicalJsonValue).toList(growable: false);
  }
  if (source == null || source is String || source is bool || source is num) {
    return source;
  }
  throw const FormatException('episode value is not JSON-compatible');
}

bool _listEquals(List<int> left, List<int> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index++) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

void _validateMaxBatches(int? value) {
  if (value != null && (value < 1 || value > _maxJsonInteger)) {
    throw ArgumentError.value(value, 'maxBatches', 'must be positive');
  }
}
