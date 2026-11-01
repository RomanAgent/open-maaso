import 'dart:convert';

import 'package:sembast/sembast.dart';
import '../domain/project_reference_selection.dart';
import '../domain/project_build_v2_contract.dart';
import '../domain/project_build_v2_reference.dart';
import 'project_build_v2_repository.dart' show ProjectBuildV2DeletionProof;

final class ProjectBuildReferenceAdmission {
  ProjectBuildReferenceAdmission._(
    this.selection,
    this.draft,
    this.uploadRequestIds,
    this.receipts,
    this.frozenRequest,
    this.prepared,
    this.rejectionCode,
  );
  final ProjectReferenceSelection selection;
  final ProjectBuildV2CreateRequest draft;
  final List<String> uploadRequestIds;
  final List<ProjectBuildReferenceReceipt?> receipts;
  final ProjectBuildV2CreateRequest? frozenRequest;
  final bool prepared;
  final String rejectionCode;
  String get requestId => draft.requestId;
  bool get pending => !prepared && rejectionCode.isEmpty;

  factory ProjectBuildReferenceAdmission._parse(
    Map<String, Object?> row,
    String scope,
  ) {
    const keys = {
      'schemaVersion',
      'scopeKey',
      'selection',
      'draft',
      'uploadRequestIds',
      'receipts',
      'frozenRequest',
      'prepared',
      'rejectionCode',
    };
    if (row.length != keys.length ||
        row.keys.any((k) => !keys.contains(k)) ||
        row['schemaVersion'] is! int ||
        row['schemaVersion'] != 1 ||
        row['scopeKey'] != scope ||
        row['prepared'] is! bool ||
        row['uploadRequestIds'] is! List ||
        row['receipts'] is! List ||
        row['rejectionCode'] is! String) {
      throw StateError('project_reference_admission_corrupt');
    }
    final selection = ProjectReferenceSelection.fromJson(row['selection']);
    final draft = ProjectBuildV2CreateRequest.fromJson(
      projectBuildV2Object(row['draft']),
    );
    final ids = (row['uploadRequestIds']! as List).cast<String>();
    final receipts = (row['receipts']! as List)
        .map((r) => r == null ? null : ProjectBuildReferenceReceipt.fromJson(r))
        .toList();
    if (draft.referenceInputs.isNotEmpty ||
        ids.length != selection.references.length ||
        receipts.length != ids.length ||
        ids.toSet().length != ids.length ||
        ids.any((id) => !RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(id)) ||
        !RegExp(
          r'^[A-Za-z0-9_.:-]{0,96}$',
        ).hasMatch(row['rejectionCode']! as String)) {
      throw StateError('project_reference_admission_corrupt');
    }
    for (var i = 0; i < receipts.length; i++) {
      final receipt = receipts[i], image = selection.references[i];
      if (receipt != null &&
          (receipt.originalSha256 != image.sha256 ||
              receipt.mediaType != image.mime ||
              receipt.purpose != image.purpose)) {
        throw StateError('project_reference_receipt_identity');
      }
    }
    final frozen = row['frozenRequest'] == null
        ? null
        : ProjectBuildV2CreateRequest.fromJson(
            projectBuildV2Object(row['frozenRequest']),
          );
    if (frozen != null) {
      if (receipts.any((r) => r == null)) {
        throw StateError('project_reference_admission_corrupt');
      }
      final expected = ProjectBuildV2CreateRequest.fromJson({
        ...draft.toJson(),
        'referenceInputs': receipts.map((r) => r!.input.toJson()).toList(),
      });
      if (jsonEncode(expected.toJson()) != jsonEncode(frozen.toJson())) {
        throw StateError('project_reference_frozen_body_changed');
      }
    }
    if (row['prepared'] == true && frozen == null) {
      throw StateError('project_reference_admission_corrupt');
    }
    return ProjectBuildReferenceAdmission._(
      selection,
      draft,
      List.unmodifiable(ids),
      List.unmodifiable(receipts),
      frozen,
      row['prepared']! as bool,
      row['rejectionCode']! as String,
    );
  }
}

/// Only metadata and fixed command identities live here. Image bytes reuse the
/// account's existing ChatMediaService store, and receipts never advance events.
final class ProjectBuildReferenceAdmissionStore {
  ProjectBuildReferenceAdmissionStore({
    required Database database,
    required this.scopeKey,
    required bool Function() isCurrent,
  }) : _database = database,
       _isCurrent = isCurrent;
  final Database _database;
  final String scopeKey;
  final bool Function() _isCurrent;
  static final _selections = stringMapStoreFactory.store(
    'project_build_reference_selections.v1',
  );
  static final _admissions = stringMapStoreFactory.store(
    'project_build_reference_admissions.v1',
  );
  // The repository's scoped tombstones are also authoritative before a
  // reference admission has become a normal create intent.
  static final _tombstones = stringMapStoreFactory.store(
    'project_build_v2_tombstones',
  );
  String _key(String value) => jsonEncode([scopeKey, value]);
  void _guard() {
    if (!_isCurrent()) throw StateError('project_build_scope_changed');
  }

  Future<T> _transaction<T>(Future<T> Function(Transaction) work) async {
    _guard();
    return _database.transaction((tx) async {
      _guard();
      final result = await work(tx);
      _guard();
      return result;
    });
  }

  Future<bool> _deleted(
    DatabaseClient tx,
    ProjectBuildV2CreateRequest draft,
  ) async =>
      await _tombstones.record(_key('request:${draft.requestId}')).exists(tx) ||
      (draft.projectId != null &&
          await _tombstones
              .record(_key('project:${draft.projectId}'))
              .exists(tx));

  Future<void> _assertActive(
    DatabaseClient tx,
    ProjectBuildV2CreateRequest draft,
  ) async {
    if (await _deleted(tx, draft)) {
      throw StateError('project_build_project_deleted');
    }
    _guard();
  }

  /// Called inside the repository's deletion transaction. These IDs become
  /// part of its private proof, so existing and future task cards are fenced.
  Future<List<String>> requestIdsForProject(
    DatabaseClient tx,
    String projectId,
  ) async {
    _guard();
    projectBuildV2Id(projectId, 'project');
    final rows = await _admissions.find(
      tx,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('draft.projectId', projectId),
        ]),
      ),
    );
    final ids = <String>[];
    for (final row in rows) {
      final id = projectBuildV2Object(row.value['draft'])['requestId'];
      if (id is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(id) ||
          row.key != _key(id)) {
        throw StateError('project_reference_admission_corrupt');
      }
      ids.add(id);
    }
    _guard();
    return List.unmodifiable(ids);
  }

  Future<void> assertDispatchable(String requestId) => _transaction((tx) async {
    final row = await _admissions.record(_key(requestId)).get(tx);
    if (row == null) throw StateError('project_reference_admission_missing');
    final known = ProjectBuildReferenceAdmission._parse(row, scopeKey);
    await _assertActive(tx, known.draft);
    if (known.rejectionCode.isNotEmpty) {
      throw StateError('project_reference_rejected');
    }
  });

  Future<void> saveSelection(
    ProjectReferenceSelection selection, {
    required String expectedAppletScopeKey,
  }) => _transaction((tx) async {
    if (selection.scopeKey != expectedAppletScopeKey) {
      throw StateError('project_build_scope_changed');
    }
    final checked = ProjectReferenceSelection.fromJson(selection.toJson());
    final record = _selections.record(_key(checked.sourceIdentityDigest));
    final previous = await record.get(tx);
    final row = {'scopeKey': scopeKey, 'selection': checked.toJson()};
    if (previous != null && jsonEncode(previous) != jsonEncode(row)) {
      throw StateError('project_reference_selection_changed');
    }
    await record.put(tx, row);
  });
  Future<ProjectBuildReferenceAdmission> prepare(
    ProjectBuildV2CreateRequest draft,
    ProjectReferenceSelection selection,
    List<String> uploadRequestIds,
  ) => _transaction((tx) async {
    await _assertActive(tx, draft);
    if (draft.referenceInputs.isNotEmpty) {
      throw StateError('project_reference_already_bound');
    }
    final stored = await _selections
        .record(_key(selection.sourceIdentityDigest))
        .get(tx);
    if (stored == null ||
        stored['scopeKey'] != scopeKey ||
        ProjectReferenceSelection.fromJson(
              stored['selection'],
            ).sourceIdentityDigest !=
            selection.sourceIdentityDigest) {
      throw StateError('project_reference_selection_missing');
    }
    final record = _admissions.record(_key(draft.requestId));
    final previous = await record.get(tx);
    if (previous != null) {
      final known = ProjectBuildReferenceAdmission._parse(previous, scopeKey);
      if (jsonEncode(known.draft.toJson()) != jsonEncode(draft.toJson()) ||
          known.selection.sourceIdentityDigest !=
              selection.sourceIdentityDigest ||
          jsonEncode(known.uploadRequestIds) != jsonEncode(uploadRequestIds)) {
        throw StateError('project_build_idempotency_conflict');
      }
      return known;
    }
    final row = <String, Object?>{
      'schemaVersion': 1,
      'scopeKey': scopeKey,
      'selection': selection.toJson(),
      'draft': draft.toJson(),
      'uploadRequestIds': uploadRequestIds,
      'receipts': List<Object?>.filled(uploadRequestIds.length, null),
      'frozenRequest': null,
      'prepared': false,
      'rejectionCode': '',
    };
    final checked = ProjectBuildReferenceAdmission._parse(row, scopeKey);
    await record.put(tx, row);
    return checked;
  });
  Future<ProjectBuildReferenceAdmission?> read(String requestId) async {
    _guard();
    final row = await _admissions.record(_key(requestId)).get(_database);
    _guard();
    if (row == null) return null;
    final known = ProjectBuildReferenceAdmission._parse(row, scopeKey);
    final deleted = await _deleted(_database, known.draft);
    _guard();
    return deleted ? null : known;
  }

  Future<List<ProjectBuildReferenceAdmission>> pending() async {
    _guard();
    final rows = await _admissions.find(
      _database,
      finder: Finder(
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('prepared', false),
          Filter.equals('rejectionCode', ''),
        ]),
      ),
    );
    _guard();
    final active = <ProjectBuildReferenceAdmission>[];
    for (final row in rows) {
      final known = ProjectBuildReferenceAdmission._parse(row.value, scopeKey);
      if (!await _deleted(_database, known.draft)) active.add(known);
    }
    _guard();
    return List.unmodifiable(active);
  }

  Future<ProjectBuildReferenceAdmission> recordReceipt(
    String requestId,
    int index,
    ProjectBuildReferenceReceipt receipt,
  ) => _transaction((tx) async {
    final record = _admissions.record(_key(requestId));
    final row = await record.get(tx);
    if (row == null) throw StateError('project_reference_admission_missing');
    final known = ProjectBuildReferenceAdmission._parse(row, scopeKey);
    await _assertActive(tx, known.draft);
    if (index < 0 || index >= known.receipts.length) {
      throw StateError('project_reference_index');
    }
    final old = known.receipts[index];
    if (old != null) {
      if (jsonEncode(old.toJson()) != jsonEncode(receipt.toJson())) {
        throw StateError('project_reference_receipt_changed');
      }
      return known;
    }
    if (known.frozenRequest != null ||
        known.prepared ||
        known.rejectionCode.isNotEmpty) {
      throw StateError('project_reference_frozen_body_changed');
    }
    final receipts = known.receipts.map((r) => r?.toJson()).toList();
    receipts[index] = receipt.toJson();
    final next = {...row, 'receipts': receipts};
    final checked = ProjectBuildReferenceAdmission._parse(next, scopeKey);
    await record.put(tx, next);
    return checked;
  });
  Future<ProjectBuildReferenceAdmission> freeze(
    String requestId,
  ) => _transaction((tx) async {
    final record = _admissions.record(_key(requestId));
    final row = await record.get(tx);
    if (row == null) throw StateError('project_reference_admission_missing');
    final known = ProjectBuildReferenceAdmission._parse(row, scopeKey);
    await _assertActive(tx, known.draft);
    if (known.frozenRequest != null) return known;
    if (known.receipts.any((r) => r == null)) {
      throw StateError('project_reference_receipts_missing');
    }
    final body = ProjectBuildV2CreateRequest.fromJson({
      ...known.draft.toJson(),
      'referenceInputs': known.receipts.map((r) => r!.input.toJson()).toList(),
    });
    final next = {...row, 'frozenRequest': body.toJson()};
    final checked = ProjectBuildReferenceAdmission._parse(next, scopeKey);
    await record.put(tx, next);
    return checked;
  });
  Future<void> markPrepared(String requestId) => _transaction((tx) async {
    final record = _admissions.record(_key(requestId));
    final row = await record.get(tx);
    if (row == null) throw StateError('project_reference_admission_missing');
    await _assertActive(
      tx,
      ProjectBuildReferenceAdmission._parse(row, scopeKey).draft,
    );
    final next = {...row, 'prepared': true};
    ProjectBuildReferenceAdmission._parse(next, scopeKey);
    await record.put(tx, next);
  });
  Future<void> reject(String requestId, String code) => _transaction((
    tx,
  ) async {
    if (!RegExp(r'^[A-Za-z0-9_.:-]{1,96}$').hasMatch(code)) {
      throw StateError('project_reference_rejection');
    }
    final record = _admissions.record(_key(requestId));
    final row = await record.get(tx);
    if (row == null) throw StateError('project_reference_admission_missing');
    await _assertActive(
      tx,
      ProjectBuildReferenceAdmission._parse(row, scopeKey).draft,
    );
    await record.put(tx, {...row, 'rejectionCode': code});
  });
  Future<void> purge(ProjectBuildV2DeletionProof proof) => _transaction((
    tx,
  ) async {
    if (proof.scopeKey != scopeKey || !proof.isScopeCurrent) {
      throw StateError('project_build_scope_changed');
    }
    await _tombstones.record(_key('project:${proof.projectId}')).put(tx, {
      'scopeKey': scopeKey,
      'receipt': proof.receipt.toJson(),
    });
    final selectionDigests = <String>{};
    final requests = {
      ...proof.createRequestIds,
      ...await requestIdsForProject(tx, proof.projectId),
    };
    for (final request in requests) {
      final record = _admissions.record(_key(request));
      final row = await record.get(tx);
      if (row != null) {
        final admission = ProjectBuildReferenceAdmission._parse(row, scopeKey);
        selectionDigests.add(admission.selection.sourceIdentityDigest);
      }
      await record.delete(tx);
      await _tombstones.record(_key('request:$request')).put(tx, {
        'scopeKey': scopeKey,
        'projectId': proof.projectId,
      });
    }
    for (final digest in selectionDigests) {
      final remaining = await _admissions.count(
        tx,
        filter: Filter.and([
          Filter.equals('scopeKey', scopeKey),
          Filter.equals('selection.sourceIdentityDigest', digest),
        ]),
      );
      if (remaining == 0) await _selections.record(_key(digest)).delete(tx);
    }
    // Chat media may also belong to an ordinary conversation. Its existing
    // owner handles blob retention; deleting a project does not erase it here.
    if (!proof.isScopeCurrent) throw StateError('project_build_scope_changed');
  });
}
