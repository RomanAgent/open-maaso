import 'dart:convert';

import 'package:sembast/sembast.dart';

import '../domain/project_bundle_v2.dart';
import '../domain/project_json_canonicalizer.dart';
import 'project_build_v2_repository.dart';

/// Account-local execution acknowledgements. No application values or source
/// code are copied into pending records. A pending record is never permission
/// to resend a JavaScript command after a timeout or process restart.
final class ProjectAppletActionJournal {
  ProjectAppletActionJournal({
    required Database database,
    required this.scopeKey,
    required this.repositoryScopeKey,
    required this.processId,
    required bool Function() isCurrent,
    this.maximumEntries = 256,
  }) : _database = database,
       _isCurrent = isCurrent {
    if (scopeKey.isEmpty ||
        repositoryScopeKey.isEmpty ||
        processId.isEmpty ||
        maximumEntries < 16 ||
        maximumEntries > 1024) {
      throw ArgumentError('applet_journal_configuration');
    }
  }

  final Database _database;
  final String scopeKey, repositoryScopeKey, processId;
  final bool Function() _isCurrent;
  final int maximumEntries;
  static final _records = stringMapStoreFactory.store(
    'project_applet_actions.v1',
  );
  static final _deleted = stringMapStoreFactory.store(
    'project_applet_action_deletions.v1',
  );
  static const _json = ProjectJsonCanonicalizer(
    maxBytes: 96 * 1024,
    maxDepth: 20,
    maxNodes: 8192,
  );

  void _guard(bool Function() canContinue) {
    if (!_isCurrent() || !canContinue()) {
      throw StateError('applet_control_revoked');
    }
  }

  String _key(String sessionId, String requestId) =>
      jsonEncode([scopeKey, sessionId, requestId]);
  String _projectKey(String id) => jsonEncode([scopeKey, id]);
  Map<String, Object?> _freeze(Map<String, Object?> value) =>
      _json.parse(_json.canonicalize(value))! as Map<String, Object?>;

  Future<Map<String, Object?>?> read(
    String sessionId,
    String requestId, {
    required bool Function() canContinue,
  }) => _database.transaction((tx) async {
    _guard(canContinue);
    final record = _records.record(_key(sessionId, requestId));
    final row = await record.get(tx);
    _guard(canContinue);
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey ||
        row['sessionId'] != sessionId ||
        row['requestId'] != requestId) {
      throw StateError('applet_journal_corrupt');
    }
    if (row['status'] == 'pending' && row['processId'] != processId) {
      final interrupted = <String, Object?>{
        ...row,
        'status': 'interrupted',
        'receipt': {
          'requestId': requestId,
          'actionId': row['actionId'],
          'status': 'interrupted',
          'mayHaveApplied': true,
          'retryPermitted': false,
          'error': 'process_restarted',
          'untrusted': true,
        },
      };
      await record.put(tx, interrupted);
      _guard(canContinue);
      return _freeze(interrupted);
    }
    return _freeze(row);
  });

  Future<({bool created, Map<String, Object?> record})> reserve({
    required String projectId,
    required String candidateDigest,
    required String sessionId,
    required int controlEpoch,
    required String requestId,
    required String actionId,
    required String identityDigest,
    required bool Function() canContinue,
  }) => _database.transaction((tx) async {
    _guard(canContinue);
    if (await _deleted.record(_projectKey(projectId)).exists(tx)) {
      throw StateError('applet_project_deleted');
    }
    final record = _records.record(_key(sessionId, requestId));
    final prior = await record.get(tx);
    _guard(canContinue);
    if (prior != null) {
      if (prior['identityDigest'] != identityDigest ||
          prior['candidateDigest'] != candidateDigest ||
          prior['projectId'] != projectId ||
          prior['controlEpoch'] != controlEpoch) {
        throw StateError('applet_request_id_conflict');
      }
      return (created: false, record: _freeze(prior));
    }
    final rows = await _records.find(
      tx,
      finder: Finder(
        filter: Filter.equals('scopeKey', scopeKey),
        sortOrders: [SortOrder('createdAt')],
      ),
    );
    var count = rows.length;
    for (final row in rows) {
      if (row.value['status'] == 'pending' &&
          row.value['processId'] != processId) {
        await _records.record(row.key).put(tx, {
          ...row.value,
          'status': 'interrupted',
          'receipt': {
            'requestId': row.value['requestId'],
            'actionId': row.value['actionId'],
            'status': 'interrupted',
            'mayHaveApplied': true,
            'error': 'process_restarted',
          },
        });
      }
      if (count >= maximumEntries &&
          (row.value['status'] != 'pending' ||
              row.value['processId'] != processId)) {
        await _records.record(row.key).delete(tx);
        count--;
      }
    }
    if (count >= maximumEntries) throw StateError('applet_journal_limit');
    final value = <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': scopeKey,
      'processId': processId,
      'projectId': projectId,
      'candidateDigest': candidateDigest,
      'sessionId': sessionId,
      'controlEpoch': controlEpoch,
      'requestId': requestId,
      'actionId': actionId,
      'identityDigest': identityDigest,
      'status': 'pending',
      'createdAt': DateTime.now().toUtc().toIso8601String(),
    };
    _guard(canContinue);
    await record.put(tx, value);
    _guard(canContinue);
    return (created: true, record: _freeze(value));
  });

  Future<Map<String, Object?>> settle(
    String sessionId,
    String requestId,
    String identityDigest,
    Map<String, Object?> receipt, {
    required bool Function() canContinue,
  }) => _database.transaction((tx) async {
    _guard(canContinue);
    final record = _records.record(_key(sessionId, requestId));
    final previous = await record.get(tx);
    _guard(canContinue);
    if (previous == null ||
        previous['scopeKey'] != scopeKey ||
        previous['identityDigest'] != identityDigest ||
        receipt['requestId'] != requestId ||
        receipt['actionId'] != previous['actionId']) {
      throw StateError('applet_request_id_conflict');
    }
    if (await _deleted
        .record(_projectKey(previous['projectId']! as String))
        .exists(tx)) {
      throw StateError('applet_project_deleted');
    }
    final frozen = _freeze(receipt);
    final existing = previous['receipt'];
    if (existing != null &&
        projectBundleV2JsonDigest(existing) !=
            projectBundleV2JsonDigest(frozen)) {
      throw StateError('applet_receipt_conflict');
    }
    if (existing == null) {
      await record.put(tx, {
        ...previous,
        'status': frozen['status'],
        'receipt': frozen,
      });
    }
    _guard(canContinue);
    return frozen;
  });

  Future<void> purgeDeletedProject(ProjectBuildV2DeletionProof proof) =>
      _database.transaction((tx) async {
        bool allowed() =>
            proof.isScopeCurrent && proof.scopeKey == repositoryScopeKey;
        _guard(allowed);
        await _deleted.record(_projectKey(proof.projectId)).put(tx, {
          'scopeKey': scopeKey,
          'projectId': proof.projectId,
          'receiptDigest': projectBundleV2JsonDigest(proof.receipt.toJson()),
        });
        await _records.delete(
          tx,
          finder: Finder(
            filter: Filter.and([
              Filter.equals('scopeKey', scopeKey),
              Filter.equals('projectId', proof.projectId),
            ]),
          ),
        );
        _guard(allowed);
      });
}
