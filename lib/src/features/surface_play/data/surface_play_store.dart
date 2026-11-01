import 'dart:convert';

import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';

import '../domain/surface_play_protocol.dart';
import 'surface_companion_call_ledger.dart';

abstract interface class SurfacePlayPersistence {
  Future<String?> latestMatchId({
    required String projectId,
    required String revisionId,
  });
  Future<Map<String, Object?>?> load(String matchId);
  Future<void> commit({
    required String matchId,
    required int? expectedCommitRevision,
    required Map<String, Object?> next,
    required bool Function() isAuthorized,
  });
}

abstract interface class SurfacePlayProjectDeletionPersistence {
  Future<void> purgeDeletedProject(
    ProjectBuildV2DeletionProof proof, {
    required String expectedProjectBuildScopeKey,
  });
}

/// The match, per-role event journals and idempotency receipts commit together.
/// No checkpoint or full private state is exposed to authored page JavaScript.
final class SurfacePlayStore
    implements
        SurfacePlayPersistence,
        SurfacePlayProjectDeletionPersistence,
        SurfaceCompanionCallLedgerOwner {
  SurfacePlayStore({
    required DBService database,
    required this.scopeKey,
    String? projectBuildScopeKey,
    required bool Function() isCurrent,
    DateTime Function()? now,
  }) : projectBuildScopeKey = projectBuildScopeKey ?? scopeKey,
       _database = database,
       _isCurrent = isCurrent,
       _now = now {
    if (scopeKey.isEmpty || scopeKey.length > 512) {
      throw ArgumentError('invalid_play_scope');
    }
  }
  final DBService _database;
  final String scopeKey;
  final String projectBuildScopeKey;
  final bool Function() _isCurrent;
  final DateTime Function()? _now;
  @override
  late final SurfaceCompanionCallLedger callLedger = SurfaceCompanionCallLedger(
    database: _database,
    scopeKey: projectBuildScopeKey,
    isCurrent: _isCurrent,
    now: _now,
  );
  static final _matches = stringMapStoreFactory.store(
    'surface_play_matches.v2',
  );
  static final _latest = stringMapStoreFactory.store('surface_play_latest.v2');
  static final _deletedProjects = stringMapStoreFactory.store(
    'surface_play_deleted_projects.v2',
  );
  String _key(String match) => jsonEncode([scopeKey, playIdentifier(match)]);
  void _guard() {
    if (!_isCurrent()) throw StateError('PLAY_SCOPE_CHANGED');
  }

  @override
  Future<String?> latestMatchId({
    required String projectId,
    required String revisionId,
  }) async {
    _guard();
    playIdentifier(projectId);
    playIdentifier(revisionId);
    await _checkProject(_database.raw, projectId);
    final row = await _latest
        .record(jsonEncode([scopeKey, projectId, revisionId]))
        .get(_database.raw);
    _guard();
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey ||
        row['projectId'] != projectId ||
        row['revisionId'] != revisionId) {
      throw const FormatException('invalid_play_latest_identity');
    }
    return playIdentifier(row['matchId']);
  }

  @override
  Future<Map<String, Object?>?> load(String matchId) async {
    _guard();
    final data = await _matches.record(_key(matchId)).get(_database.raw);
    _guard();
    if (data == null) return null;
    await _checkProject(_database.raw, playIdentifier(data['projectId']));
    if (data['scopeKey'] != scopeKey ||
        data['matchId'] != matchId ||
        data['schemaVersion'] != 2) {
      throw const FormatException('invalid_play_checkpoint_identity');
    }
    return playObject(playSnapshot(data, maximumBytes: 4 * 1024 * 1024));
  }

  @override
  Future<void> commit({
    required String matchId,
    required int? expectedCommitRevision,
    required Map<String, Object?> next,
    required bool Function() isAuthorized,
  }) async {
    _guard();
    final frozen = playObject(
      playSnapshot(next, maximumBytes: 4 * 1024 * 1024),
    );
    if (frozen['scopeKey'] != scopeKey ||
        frozen['matchId'] != matchId ||
        frozen['schemaVersion'] != 2 ||
        frozen['commitRevision'] != (expectedCommitRevision ?? -1) + 1) {
      throw const FormatException('invalid_play_checkpoint_identity');
    }
    await _database.raw.transaction((tx) async {
      _guard();
      if (!isAuthorized()) throw StateError('PLAY_COMMIT_REVOKED');
      await _checkProject(tx, playIdentifier(frozen['projectId']));
      final ref = _matches.record(_key(matchId));
      final previous = await ref.get(tx);
      _guard();
      if (!isAuthorized()) throw StateError('PLAY_COMMIT_REVOKED');
      if ((expectedCommitRevision == null) != (previous == null) ||
          (previous != null &&
              previous['commitRevision'] != expectedCommitRevision)) {
        throw StateError('PLAY_COMMIT_CONFLICT');
      }
      await ref.put(tx, frozen);
      if (previous == null || previous['sessionId'] != frozen['sessionId']) {
        await _latest
            .record(
              jsonEncode([scopeKey, frozen['projectId'], frozen['revisionId']]),
            )
            .put(tx, {
              'scopeKey': scopeKey,
              'projectId': frozen['projectId'],
              'revisionId': frozen['revisionId'],
              'matchId': matchId,
            });
      }
      _guard();
      if (!isAuthorized()) throw StateError('PLAY_COMMIT_REVOKED');
    });
    _guard();
  }

  Future<void> _checkProject(DatabaseClient db, String projectId) async {
    if (await _deletedProjects
        .record(jsonEncode([scopeKey, projectId]))
        .exists(db)) {
      throw StateError('PLAY_PROJECT_DELETED');
    }
    _guard();
  }

  @override
  Future<void> purgeDeletedProject(
    ProjectBuildV2DeletionProof proof, {
    required String expectedProjectBuildScopeKey,
  }) async {
    void guard() {
      _guard();
      if (expectedProjectBuildScopeKey != projectBuildScopeKey ||
          proof.scopeKey != projectBuildScopeKey ||
          !proof.isScopeCurrent) {
        throw StateError('PLAY_SCOPE_CHANGED');
      }
    }

    guard();
    await _database.raw.transaction((tx) async {
      guard();
      await _deletedProjects
          .record(jsonEncode([scopeKey, proof.projectId]))
          .put(tx, {
            'scopeKey': scopeKey,
            'projectId': proof.projectId,
            'headVersion': proof.receipt.headVersion,
          });
      final filter = Finder(
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('projectId', proof.projectId),
        ]),
      );
      await _matches.delete(tx, finder: filter);
      await _latest.delete(tx, finder: filter);
      guard();
    });
    guard();
  }
}
