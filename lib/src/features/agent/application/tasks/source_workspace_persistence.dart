import 'package:crypto/crypto.dart';
import 'dart:convert';

import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

import 'generated_task_diagnostics.dart';
import 'source_workspace.dart';

/// Unverified source drafts are separate from playable/saved AgentWidgets.
/// Ownership is supplied by the mounted host, never by model-authored data.
class SourceWorkspacePersistence {
  SourceWorkspacePersistence(this.database);
  final DBService database;
  static final _drafts = stringMapStoreFactory.store(
    'generated_source_workspaces.v1',
  );

  String _key(String scopeKey, String jobId) => sha256
      .convert(utf8.encode('source-workspace-owner.v1\n$scopeKey\n$jobId'))
      .toString();

  Future<SourceWorkspaceSnapshot?> read({
    required String scopeKey,
    required String jobId,
    required String requirementSha256,
    required void Function() requireCurrent,
  }) async {
    requireCurrent();
    final value = await _drafts.record(_key(scopeKey, jobId)).get(database.raw);
    requireCurrent();
    if (value == null) return null;
    if (value['scopeKey'] != scopeKey || value['jobId'] != jobId) {
      throw const GeneratedTaskFailure(GeneratedTaskFailureCode.interrupted);
    }
    try {
      final snapshot = SourceWorkspaceSnapshot.fromJson(value['workspace']);
      if (snapshot.requirementSha256 != requirementSha256) return null;
      return snapshot;
    } on SourceWorkspaceProtocolException {
      throw const GeneratedTaskFailure(GeneratedTaskFailureCode.storageFailed);
    } on FormatException {
      throw const GeneratedTaskFailure(GeneratedTaskFailureCode.storageFailed);
    }
  }

  Future<void> write({
    required String scopeKey,
    required String jobId,
    required int attempt,
    required SourceWorkspaceSnapshot snapshot,
    required void Function() requireCurrent,
  }) async {
    requireCurrent();
    final record = _drafts.record(_key(scopeKey, jobId));
    await database.raw.transaction((transaction) async {
      requireCurrent();
      final previous = await record.get(transaction);
      requireCurrent();
      if (previous != null &&
          ((previous['attempt'] as int? ?? 0) > attempt ||
              previous['scopeKey'] != scopeKey ||
              previous['jobId'] != jobId)) {
        throw const GeneratedTaskFailure(GeneratedTaskFailureCode.interrupted);
      }
      await record.put(transaction, {
        'schemaVersion': 1,
        'scopeKey': scopeKey,
        'jobId': jobId,
        'attempt': attempt,
        'workspace': snapshot.toJson(),
      });
      requireCurrent();
    });
    requireCurrent();
  }
}
