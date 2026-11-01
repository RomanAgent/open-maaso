import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/persistence/scoped_storage_directory_io.dart';

import '../domain/project_bundle_v2.dart';
import '../domain/project_json_canonicalizer.dart';
import '../domain/project_bundle_data_contract.dart';
import '../domain/project_bundle_verification.dart';
import '../domain/project_build_v2_contract.dart';
import 'project_build_v2_repository.dart';

enum ProjectBundleDataRole { preview, installed }

final class ProjectBundleApplicationData {
  ProjectBundleApplicationData._(this.version, this.values);
  final int version;
  final Map<String, Object?> values;
}

/// Byte-verified, account-owned cache entry. This is not an execution grant or
/// a server verification report. The player must obtain its own presentation
/// authority before consuming [bundle].
final class InstalledProjectBundleV2 {
  InstalledProjectBundleV2._(
    this.bundle,
    this.installedAt,
    this._isCurrent,
    this.verificationReport,
    this.scopeKey,
    this.isAccepted,
    this.headVersion,
  );
  final ValidatedProjectBundleV2 bundle;
  final String scopeKey;
  final bool isAccepted;

  /// An observed current-head control version, never part of bundle identity.
  /// Candidate/history handles and legacy heads without a counter expose null.
  final int? headVersion;
  final DateTime installedAt;
  final bool Function() _isCurrent;

  /// Cached signed bytes only; the injected permit verifier must revalidate it.
  final Map<String, Object?>? verificationReport;
  String get candidateDigest => bundle.candidateDigest;
  bool get isScopeCurrent => _isCurrent();
  bool get isCurrent => isScopeCurrent;
}

/// Uses the existing account database and account storage namespace. There is
/// no network client or second database. Logical authored paths never become
/// native paths: blobs are named only by their verified SHA-256.
final class ProjectBundleInstallationStore {
  ProjectBundleInstallationStore({
    required Database database,
    required this.accountScope,
    required Directory applicationSupportRoot,
    required bool Function() isCurrent,
    this.projectBuildScopeKey,
    Future<Set<String>?> Function()? loadOwnedProjectIds,
  }) : _database = database,
       _supportRoot = applicationSupportRoot,
       _isCurrent = isCurrent,
       _loadOwnedProjectIds = loadOwnedProjectIds,
       _ownedHydrated = loadOwnedProjectIds == null;

  final Database _database;
  final String? projectBuildScopeKey;
  final AccountStorageScope accountScope;
  final Directory _supportRoot;
  final bool Function() _isCurrent;
  final Future<Set<String>?> Function()? _loadOwnedProjectIds;
  bool _ownedHydrated;
  int _ownedKnowledgeEpoch = 0;
  Future<void>? _ownedHydration;
  final _pending = <Future<void>>{};
  Future<void> _operationTail = Future.value();
  final _blockedProjects = <String>{};
  final _projectEpochs = <String, int>{};
  final _revocations = StreamController<String>.broadcast(sync: true);
  Stream<String> get onProjectRevoked => _revocations.stream;
  final _withdrawals = StreamController<Set<String>>.broadcast(sync: true);
  Set<String>? _knownOwnedProjects;
  Stream<Set<String>> get onOwnedInventoryChanged => _withdrawals.stream;

  bool canPresentSavedProject(
    String projectId, {
    required String expectedScopeKey,
  }) =>
      isCurrent &&
      _ownedHydrated &&
      expectedScopeKey == scopeKey &&
      !_blockedProjects.contains(projectId) &&
      (_knownOwnedProjects?.contains(projectId) ?? true);

  /// Restore the last committed owner list before any saved presentation.
  /// Null means no prior knowledge, while an empty list remains a withdrawal.
  /// The injected reader is local-only and shares the existing repository DB.
  Future<void> ensurePresentationAuthority({required String expectedScopeKey}) {
    _guard(expectedScopeKey, _generation);
    if (_ownedHydrated) return Future.value();
    return _ownedHydration ??= _run(expectedScopeKey, (generation) async {
      if (_ownedHydrated) return;
      final epoch = _ownedKnowledgeEpoch;
      final ids = await _loadOwnedProjectIds!();
      _guard(expectedScopeKey, generation);
      // A complete live response received during the local read is newer.
      if (epoch == _ownedKnowledgeEpoch && ids != null) {
        for (final id in ids) {
          _checkProject(id);
        }
        _knownOwnedProjects = Set.unmodifiable(ids);
      }
      _ownedHydrated = true;
    }).whenComplete(() => _ownedHydration = null);
  }

  /// Complete owner discovery may retire a visible saved presentation without
  /// claiming a deletion receipt or destroying an unsaved preview/cache.
  void reconcileOwnedPresentations(
    Set<String> projectIds, {
    required String expectedScopeKey,
  }) {
    _guard(expectedScopeKey, _generation);
    for (final project in projectIds) {
      _checkProject(project);
    }
    _knownOwnedProjects = Set.unmodifiable(projectIds);
    _ownedKnowledgeEpoch++;
    _ownedHydrated = true;
    _withdrawals.add(_knownOwnedProjects!);
  }

  static final _bundles = stringMapStoreFactory.store(
    'project_bundle_installations.v2',
  );
  static final _heads = stringMapStoreFactory.store(
    'project_bundle_current.v2',
  );
  static final _data = stringMapStoreFactory.store('project_bundle_data.v1');
  static final _staging = stringMapStoreFactory.store(
    'project_bundle_staging.v2',
  );
  static final _deletions = stringMapStoreFactory.store(
    'project_bundle_deleted.v2',
  );
  static const _codec = ProjectBundleV2Codec();
  static const _dataJson = ProjectJsonCanonicalizer(
    maxBytes: 64 * 1024,
    maxDepth: 16,
    maxNodes: 4096,
  );
  bool _sealed = false;
  int _generation = 0;
  String get scopeKey => accountScope.storageNamespace;
  bool get isCurrent => !_sealed && _isCurrent();
  String _key(String value) => jsonEncode([scopeKey, value]);

  void _guard(String expected, int generation) {
    if (!isCurrent || expected != scopeKey || generation != _generation) {
      throw StateError('project_bundle_scope_changed');
    }
  }

  Future<T> _run<T>(String expected, Future<T> Function(int generation) body) {
    final generation = _generation;
    final work = _operationTail
        .then<T>((_) {
          _guard(expected, generation);
          return body(generation);
        })
        .then((value) {
          _guard(expected, generation);
          return value;
        });
    _operationTail = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    late Future<void> tracked;
    tracked = work
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(tracked));
    _pending.add(tracked);
    return work;
  }

  void _guardProject(String projectId) {
    if (_blockedProjects.contains(projectId)) {
      throw StateError('project_bundle_project_deleted');
    }
  }

  Future<void> _assertAvailable(DatabaseClient client, String projectId) async {
    _guardProject(projectId);
    if (await _deletions.record(_key(projectId)).exists(client)) {
      _blockedProjects.add(projectId);
      throw StateError('project_bundle_project_deleted');
    }
    _guardProject(projectId);
  }

  bool _handleCurrent(String projectId, int epoch, int generation) =>
      isCurrent &&
      generation == _generation &&
      !_blockedProjects.contains(projectId) &&
      (_projectEpochs[projectId] ?? 0) == epoch;

  /// A private repository receipt is the only deletion authority. Existing
  /// native handles lose authority synchronously, before cleanup can await I/O.
  /// The tombstone and remaining blob set survive crashes; replay resumes GC.
  Future<void> purgeDeletedProject(
    ProjectBuildV2DeletionProof proof, {
    required String expectedScopeKey,
    required String expectedProjectBuildScopeKey,
  }) {
    _guard(expectedScopeKey, _generation);
    if (projectBuildScopeKey == null ||
        !proof.isScopeCurrent ||
        proof.scopeKey != projectBuildScopeKey ||
        expectedProjectBuildScopeKey != projectBuildScopeKey) {
      throw StateError('project_bundle_delete_authority');
    }
    final projectId = proof.projectId;
    _checkProject(projectId);
    _blockedProjects.add(projectId);
    _projectEpochs[projectId] = (_projectEpochs[projectId] ?? 0) + 1;
    _revocations.add(projectId);
    return _run(expectedScopeKey, (generation) async {
      final receipt = proof.receipt.toJson();
      final identity = projectBundleV2JsonDigest(receipt);
      // The server's deletion authority must survive even if another local
      // cache row is corrupt. Commit the tombstone before inspecting caches.
      await _database.transaction((tx) async {
        _guard(expectedScopeKey, generation);
        if (!proof.isScopeCurrent) {
          throw StateError('project_bundle_delete_authority');
        }
        final deleted = _deletions.record(_key(projectId));
        final previous = await deleted.get(tx);
        if (previous != null) {
          if (previous['scopeKey'] != scopeKey ||
              previous['receiptDigest'] != identity) {
            throw StateError('project_bundle_delete_conflict');
          }
          return;
        }
        final head = await _heads.record(_key(projectId)).get(tx);
        _headDigest(head, projectId);
        if ((_headVersion(head) ?? 0) >= proof.receipt.headVersion) {
          throw StateError('project_bundle_delete_conflict');
        }
        await _heads.record(_key(projectId)).delete(tx);
        await deleted.put(tx, {
          'scopeKey': scopeKey,
          'projectId': projectId,
          'receipt': receipt,
          'receiptDigest': identity,
          'pendingBlobs': <String>[],
          'metadataComplete': false,
          'cleanupComplete': false,
        });
        _guard(expectedScopeKey, generation);
        if (!proof.isScopeCurrent) {
          throw StateError('project_bundle_delete_authority');
        }
      });
      await _database.transaction((tx) async {
        _guard(expectedScopeKey, generation);
        if (!proof.isScopeCurrent) {
          throw StateError('project_bundle_delete_authority');
        }
        final deleted = _deletions.record(_key(projectId));
        final previous = await deleted.get(tx);
        if (previous == null ||
            previous['scopeKey'] != scopeKey ||
            previous['receiptDigest'] != identity) {
          throw StateError('project_bundle_delete_conflict');
        }
        // Rows written by the earlier format already completed metadata
        // removal before creating their tombstone.
        if (previous['metadataComplete'] != false) return;
        final garbage = <String>{};
        for (final collection in [_bundles, _staging]) {
          final rows = await collection.find(
            tx,
            finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
          );
          for (final row in rows) {
            final manifest = collection == _bundles
                ? _storedManifest(
                    row.value,
                    row.value['candidateDigest']! as String,
                  )
                : _stagedManifest(row.value);
            if (manifest.projectId != projectId) continue;
            garbage.addAll(manifest.files.map((file) => file.sha256));
            await collection.record(row.key).delete(tx);
          }
        }
        final dataRows = await _data.find(
          tx,
          finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
        );
        for (final row in dataRows) {
          final key = jsonDecode(row.key);
          if (key is List &&
              key.length == 5 &&
              key[0] == scopeKey &&
              key[1] == projectId &&
              key[2] == 'data.v1') {
            await _data.record(row.key).delete(tx);
          }
        }
        await _heads.record(_key(projectId)).delete(tx);
        await deleted.put(tx, {
          'scopeKey': scopeKey,
          'projectId': projectId,
          'receipt': receipt,
          'receiptDigest': identity,
          'pendingBlobs': garbage.toList()..sort(),
          'metadataComplete': true,
          'cleanupComplete': false,
        });
        _guard(expectedScopeKey, generation);
        if (!proof.isScopeCurrent) {
          throw StateError('project_bundle_delete_authority');
        }
      });
      await _collectDeletedBlobs(
        projectId,
        identity,
        expectedScopeKey,
        generation,
      );
    });
  }

  Future<void> _collectDeletedBlobs(
    String projectId,
    String identity,
    String expected,
    int generation,
  ) => _database.transaction((tx) async {
    _guard(expected, generation);
    final record = _deletions.record(_key(projectId));
    final deleted = await record.get(tx);
    if (deleted == null ||
        deleted['scopeKey'] != scopeKey ||
        deleted['receiptDigest'] != identity ||
        deleted['pendingBlobs'] is! List) {
      throw StateError('project_bundle_delete_corrupt');
    }
    if (deleted['cleanupComplete'] == true) return;
    // The same transaction excludes new staging ledgers while files are
    // removed. A shared blob is retained if any committed or pending package
    // still references it, including a different project's failed staging.
    final retained = <String>{};
    for (final collection in [_bundles, _staging]) {
      final rows = await collection.find(
        tx,
        finder: Finder(filter: Filter.equals('scopeKey', scopeKey)),
      );
      for (final row in rows) {
        final manifest = collection == _bundles
            ? _storedManifest(
                row.value,
                row.value['candidateDigest']! as String,
              )
            : _stagedManifest(row.value);
        retained.addAll(manifest.files.map((file) => file.sha256));
      }
    }
    for (final digest in deleted['pendingBlobs']! as List) {
      if (digest is! String) throw StateError('project_bundle_delete_corrupt');
      _checkDigest(digest);
      if (retained.contains(digest)) continue;
      final file = await _blob(digest, expected, generation);
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      _guard(expected, generation);
      if (type == FileSystemEntityType.file) {
        await file.delete();
      } else if (type != FileSystemEntityType.notFound) {
        throw StateError('project_bundle_unsafe_file');
      }
      _guard(expected, generation);
    }
    await record.put(tx, {
      ...deleted,
      'pendingBlobs': <String>[],
      'cleanupComplete': true,
    });
    _guard(expected, generation);
  });

  ProjectBundleV2Manifest _stagedManifest(Map<String, Object?> row) {
    final manifest = ProjectBundleV2Manifest.fromJson(row['manifest']);
    if (row['scopeKey'] != scopeKey ||
        row['candidateDigest'] != manifest.candidateDigest) {
      throw StateError('project_bundle_staging_corrupt');
    }
    return manifest;
  }

  /// Files become durable before the transaction selects the installed head.
  /// A stale CAS or cancelled mount leaves the prior usable head untouched.
  Future<InstalledProjectBundleV2> stageCandidate(
    ValidatedProjectBundleV2 bundle, {
    required String expectedScopeKey,
    Map<String, Object?>? verificationReport,
  }) => _persistCandidate(
    bundle,
    expectedScopeKey: expectedScopeKey,
    expectedCurrentCandidateDigest: null,
    verificationReport: verificationReport,
    accept: false,
  );

  Future<InstalledProjectBundleV2> install(
    ValidatedProjectBundleV2 bundle, {
    required String expectedScopeKey,
    required String? expectedCurrentCandidateDigest,
    required int? expectedHeadVersion,
    required String expectedProjectBuildScopeKey,
    required ProjectBuildV2OwnedRevision ownedRevision,
    required VerifiedProjectBundlePermit permit,
    required Map<String, Object?> verificationReport,
  }) {
    bool valid() => _ownedAuthority(
      bundle,
      ownedRevision,
      permit,
      verificationReport,
      expectedProjectBuildScopeKey,
    );
    if (!valid()) throw StateError('project_bundle_head_authority');
    return _persistCandidate(
      bundle,
      expectedScopeKey: expectedScopeKey,
      expectedCurrentCandidateDigest: expectedCurrentCandidateDigest,
      expectedHeadVersion: expectedHeadVersion,
      authoritativeHeadVersion: ownedRevision.currentHeadVersion,
      verificationReport: verificationReport,
      accept: true,
      canCommit: valid,
    );
  }

  bool _ownedAuthority(
    ValidatedProjectBundleV2 bundle,
    ProjectBuildV2OwnedRevision proof,
    VerifiedProjectBundlePermit permit,
    Map<String, Object?> report,
    String expectedRepositoryScope,
  ) =>
      projectBuildScopeKey != null &&
      expectedRepositoryScope == projectBuildScopeKey &&
      proof.scopeKey == projectBuildScopeKey &&
      proof.isScopeCurrent &&
      proof.isCurrent &&
      proof.projectId == bundle.manifest.projectId &&
      proof.revisionId == bundle.manifest.revisionId &&
      proof.baseRevision == bundle.manifest.baseRevision &&
      proof.candidateDigest == bundle.candidateDigest &&
      proof.reportDigest == permit.reportDigest &&
      permit.candidateDigest == bundle.candidateDigest &&
      permit.isCurrent &&
      projectBundleV2JsonDigest(report) == permit.reportDigest;

  /// Repairs only missing local control metadata from fresh owned-current
  /// evidence. It cannot change code, data, the pointer, or an old request body.
  Future<InstalledProjectBundleV2> adoptCurrentHead(
    ProjectBuildV2OwnedRevision ownedRevision, {
    required String expectedScopeKey,
    required String expectedProjectBuildScopeKey,
    required VerifiedProjectBundlePermit permit,
    required Map<String, Object?> verificationReport,
  }) => _run(expectedScopeKey, (generation) async {
    final installed = await _open(
      ownedRevision.candidateDigest,
      expectedScopeKey,
      generation,
      reportDigest: permit.reportDigest,
    );
    bool valid() =>
        installed != null &&
        installed.isCurrent &&
        installed.isAccepted &&
        _ownedAuthority(
          installed.bundle,
          ownedRevision,
          permit,
          verificationReport,
          expectedProjectBuildScopeKey,
        );
    if (!valid()) throw StateError('project_bundle_head_authority');
    await _database.transaction((tx) async {
      _guard(expectedScopeKey, generation);
      final record = _heads.record(_key(ownedRevision.projectId));
      final head = await record.get(tx);
      _guard(expectedScopeKey, generation);
      if (!valid() ||
          head == null ||
          _headDigest(head, ownedRevision.projectId) !=
              ownedRevision.candidateDigest ||
          (_headVersion(head) != null &&
              _headVersion(head) != ownedRevision.currentHeadVersion) ||
          (head['reportDigest'] != null &&
              head['reportDigest'] != permit.reportDigest)) {
        throw StateError('project_bundle_install_conflict');
      }
      await record.put(tx, {
        ...head,
        'headVersion': ownedRevision.currentHeadVersion,
        'reportDigest': permit.reportDigest,
      });
      _guard(expectedScopeKey, generation);
      if (!valid()) throw StateError('project_bundle_head_authority');
    });
    return (await _open(
      ownedRevision.candidateDigest,
      expectedScopeKey,
      generation,
      reportDigest: permit.reportDigest,
      headVersion: ownedRevision.currentHeadVersion,
    ))!;
  });

  /// A committed server journal or owned revision chain plus a live signed
  /// report may restore an old revision without replacing the current head.
  Future<InstalledProjectBundleV2> cacheAcceptedHistorical(
    ValidatedProjectBundleV2 bundle, {
    required String expectedScopeKey,
    required String expectedProjectBuildScopeKey,
    ProjectBuildV2Projection? completion,
    ProjectBuildV2OwnedRevision? ownedRevision,
    required VerifiedProjectBundlePermit permit,
    required Map<String, Object?> verificationReport,
  }) {
    if ((completion == null) == (ownedRevision == null)) {
      throw ArgumentError('project_bundle_acceptance_source');
    }
    final snapshot = completion?.snapshot;
    final saved = snapshot?.savedRevision;
    final scope = completion?.scopeKey ?? ownedRevision!.scopeKey;
    final projectId = saved?.projectId ?? ownedRevision?.projectId;
    final revisionId = saved?.revisionId ?? ownedRevision?.revisionId;
    final candidateDigest =
        saved?.candidateDigest ?? ownedRevision?.candidateDigest;
    final reportDigest = saved?.reportDigest ?? ownedRevision?.reportDigest;
    bool valid() =>
        projectBuildScopeKey != null &&
        expectedProjectBuildScopeKey == projectBuildScopeKey &&
        scope == projectBuildScopeKey &&
        (ownedRevision == null || ownedRevision.isScopeCurrent) &&
        (completion == null ||
            (snapshot?.status == ProjectBuildV2Status.completed &&
                completion.appliedTaskSequence ==
                    snapshot!.snapshotTaskSequence &&
                snapshot.projectId == bundle.manifest.projectId)) &&
        projectId == bundle.manifest.projectId &&
        revisionId == bundle.manifest.revisionId &&
        candidateDigest == bundle.candidateDigest &&
        reportDigest == permit.reportDigest &&
        permit.candidateDigest == bundle.candidateDigest &&
        permit.isCurrent;
    if (!valid() ||
        projectBundleV2JsonDigest(verificationReport) != permit.reportDigest) {
      throw StateError('project_bundle_historical_authority');
    }
    return _persistCandidate(
      bundle,
      expectedScopeKey: expectedScopeKey,
      expectedCurrentCandidateDigest: null,
      verificationReport: verificationReport,
      accept: false,
      historicalAcceptance: true,
      canCommit: valid,
    );
  }

  Future<InstalledProjectBundleV2> _persistCandidate(
    ValidatedProjectBundleV2 bundle, {
    required String expectedScopeKey,
    required String? expectedCurrentCandidateDigest,
    int? expectedHeadVersion,
    int? authoritativeHeadVersion,
    Map<String, Object?>? verificationReport,
    required bool accept,
    bool historicalAcceptance = false,
    bool Function()? canCommit,
  }) => _run(expectedScopeKey, (generation) async {
    final projectId = bundle.manifest.projectId;
    final projectEpoch = _projectEpochs[projectId] ?? 0;
    void guard() {
      _guard(expectedScopeKey, generation);
      _guardProject(projectId);
      if (canCommit?.call() == false) {
        throw StateError('project_bundle_historical_authority');
      }
    }

    guard();
    final frozenReport = verificationReport == null
        ? null
        : _freezeReport(verificationReport);
    final reportDigest = frozenReport == null
        ? null
        : projectBundleV2JsonDigest(frozenReport);
    if (expectedCurrentCandidateDigest != null) {
      _checkDigest(expectedCurrentCandidateDigest);
    }
    await _database.transaction((tx) async {
      await _assertAvailable(tx, projectId);
      guard();
      await _staging.record(_key(bundle.candidateDigest)).put(tx, {
        'scopeKey': scopeKey,
        'candidateDigest': bundle.candidateDigest,
        'manifest': bundle.manifest.toJson(),
      });
      guard();
    });
    for (final metadata in bundle.manifest.files) {
      await _writeBlob(
        metadata,
        bundle.files[metadata.path]!,
        expectedScopeKey,
        generation,
      );
    }
    guard();
    final installedAt = DateTime.now().toUtc();
    final result = await _database.transaction((tx) async {
      await _assertAvailable(tx, projectId);
      guard();
      final headRecord = _heads.record(_key(bundle.manifest.projectId));
      final current = accept ? await headRecord.get(tx) : null;
      guard();
      final currentDigest = _headDigest(current, bundle.manifest.projectId);
      final currentVersion = _headVersion(current);
      if (accept) {
        if (current != null && currentVersion == null) {
          throw StateError('project_bundle_legacy_head_read_only');
        }
        final replay =
            currentDigest == bundle.candidateDigest &&
            currentVersion == authoritativeHeadVersion &&
            current?['reportDigest'] == reportDigest;
        if (!replay &&
            (currentDigest != expectedCurrentCandidateDigest ||
                currentVersion != expectedHeadVersion ||
                authoritativeHeadVersion == null ||
                authoritativeHeadVersion <= (currentVersion ?? 0))) {
          throw StateError('project_bundle_install_conflict');
        }
      }
      final bundleRecord = _bundles.record(_key(bundle.candidateDigest));
      final existing = await bundleRecord.get(tx);
      guard();
      if (existing != null) {
        final manifest = _storedManifest(existing, bundle.candidateDigest);
        if (manifest.candidateDigest != bundle.candidateDigest) {
          throw StateError('project_bundle_install_corrupt');
        }
      }
      final reports = existing?['verificationReports'] is Map
          ? Map<String, Object?>.from(existing!['verificationReports']! as Map)
          : <String, Object?>{};
      if (frozenReport != null) {
        if (reports.length >= 32 && !reports.containsKey(reportDigest)) {
          throw StateError('project_bundle_report_limit');
        }
        reports[reportDigest!] = frozenReport;
      }
      if (accept &&
          currentDigest != bundle.candidateDigest &&
          existing?['wasHead'] != true) {
        await _upgradeData(
          tx,
          bundle,
          currentDigest,
          expectedScopeKey,
          generation,
          preserveDestination: existing?['accepted'] == true,
        );
        guard();
      }
      final accepted =
          accept || historicalAcceptance || existing?['accepted'] == true;
      final wasHead = accept || existing?['wasHead'] == true;
      if (existing == null ||
          frozenReport != null ||
          accepted != existing['accepted'] ||
          wasHead != existing['wasHead']) {
        await bundleRecord.put(tx, {
          'scopeKey': scopeKey,
          'candidateDigest': bundle.candidateDigest,
          'manifest': bundle.manifest.toJson(),
          'accepted': accepted,
          'wasHead': wasHead,
          'installedAt':
              existing?['installedAt'] ?? installedAt.toIso8601String(),
          'verificationReports': reports,
          'latestReportDigest': reportDigest ?? existing?['latestReportDigest'],
        });
      }
      guard();
      if (accept &&
          (currentDigest != bundle.candidateDigest ||
              currentVersion != authoritativeHeadVersion)) {
        await headRecord.put(tx, {
          'scopeKey': scopeKey,
          'projectId': bundle.manifest.projectId,
          'candidateDigest': bundle.candidateDigest,
          'headVersion': authoritativeHeadVersion,
          'reportDigest': reportDigest,
          'previousCandidateDigest': currentDigest,
          'updatedAt': installedAt.toIso8601String(),
        });
      }
      guard();
      await _staging.record(_key(bundle.candidateDigest)).delete(tx);
      guard();
      return (
        accepted: accepted,
        installedAt: existing == null
            ? installedAt
            : DateTime.parse(existing['installedAt']! as String),
        report:
            frozenReport ??
            (existing == null ? null : _storedReport(existing, null)),
      );
    });
    guard();
    return InstalledProjectBundleV2._(
      bundle,
      result.installedAt,
      () => _handleCurrent(projectId, projectEpoch, generation),
      result.report,
      scopeKey,
      result.accepted,
      accept ? authoritativeHeadVersion : null,
    );
  });

  Future<InstalledProjectBundleV2?> openCurrent(
    String projectId, {
    required String expectedScopeKey,
  }) => _run(expectedScopeKey, (generation) async {
    _checkProject(projectId);
    await _assertAvailable(_database, projectId);
    final head = await _heads.record(_key(projectId)).get(_database);
    _guard(expectedScopeKey, generation);
    final digest = _headDigest(head, projectId);
    if (digest == null) return null;
    return _open(
      digest,
      expectedScopeKey,
      generation,
      reportDigest: head?['reportDigest'] as String?,
      headVersion: _headVersion(head),
    );
  });

  Future<InstalledProjectBundleV2?> openCandidate(
    String candidateDigest, {
    required String expectedScopeKey,
    String? reportDigest,
  }) => _run(
    expectedScopeKey,
    (generation) => _open(
      candidateDigest,
      expectedScopeKey,
      generation,
      reportDigest: reportDigest,
    ),
  );

  Future<InstalledProjectBundleV2?> _open(
    String digest,
    String expected,
    int generation, {
    String? reportDigest,
    int? headVersion,
  }) async {
    _checkDigest(digest);
    final row = await _bundles.record(_key(digest)).get(_database);
    _guard(expected, generation);
    if (row == null) return null;
    final manifest = _storedManifest(row, digest);
    await _assertAvailable(_database, manifest.projectId);
    final projectEpoch = _projectEpochs[manifest.projectId] ?? 0;
    final files = <ProjectBundleV2File>[];
    for (final metadata in manifest.files) {
      final bytes = await _readBlob(metadata, expected, generation);
      files.add(
        ProjectBundleV2File(
          path: metadata.path,
          mimeType: metadata.mimeType,
          role: metadata.role,
          bytes: bytes,
        ),
      );
    }
    final bundle = _codec.verify(manifest, files);
    _guard(expected, generation);
    _guardProject(manifest.projectId);
    return InstalledProjectBundleV2._(
      bundle,
      DateTime.parse(row['installedAt']! as String),
      () => _handleCurrent(manifest.projectId, projectEpoch, generation),
      _storedReport(row, reportDigest),
      scopeKey,
      row['accepted'] == true,
      headVersion,
    );
  }

  /// Only declared passive asset entries can pass through this resource API.
  Future<List<int>> readAsset(
    String candidateDigest,
    String path, {
    required String expectedScopeKey,
  }) => _run(expectedScopeKey, (generation) async {
    validateProjectBundleV2Path(path);
    final manifest = await _manifest(
      candidateDigest,
      expectedScopeKey,
      generation,
    );
    final metadata = manifest.files
        .where(
          (file) =>
              file.path == path && file.role == ProjectBundleV2FileRole.asset,
        )
        .firstOrNull;
    if (metadata == null) throw StateError('project_bundle_asset_not_declared');
    final bytes = await _readBlob(metadata, expectedScopeKey, generation);
    _guardProject(manifest.projectId);
    return List<int>.unmodifiable(bytes);
  });

  Future<ProjectBundleApplicationData> readApplicationData(
    String candidateDigest, {
    required String expectedScopeKey,
    required ProjectBundleDataRole role,
  }) => _run(expectedScopeKey, (generation) async {
    final manifest = await _manifest(
      candidateDigest,
      expectedScopeKey,
      generation,
    );
    final contract = await _dataContract(
      manifest,
      expectedScopeKey,
      generation,
    );
    final row = await _data.record(_dataKey(manifest, role)).get(_database);
    _guard(expectedScopeKey, generation);
    _guardProject(manifest.projectId);
    final snapshot = _dataSnapshot(row);
    if (snapshot.version > 0) contract?.validateData(snapshot.values);
    return snapshot;
  });

  /// Each installed revision preserves its own snapshot. There is no implicit
  /// migration between revisions; preview uses a separate candidate namespace.
  Future<ProjectBundleApplicationData> saveApplicationData(
    String candidateDigest,
    Map<String, Object?> values, {
    required String expectedScopeKey,
    required ProjectBundleDataRole role,
    required int expectedDataVersion,
    bool Function()? canCommit,
  }) {
    final frozen = _freezeData(values);
    return _run(expectedScopeKey, (generation) async {
      String? projectId;
      void guardWrite() {
        _guard(expectedScopeKey, generation);
        if (projectId != null) _guardProject(projectId);
        if (canCommit?.call() == false) {
          throw StateError('project_bundle_presentation_changed');
        }
      }

      guardWrite();
      if (expectedDataVersion < 0 || expectedDataVersion >= 9007199254740991) {
        throw StateError('project_bundle_data_version');
      }
      final manifest = await _manifest(
        candidateDigest,
        expectedScopeKey,
        generation,
      );
      final contract = await _dataContract(
        manifest,
        expectedScopeKey,
        generation,
      );
      projectId = manifest.projectId;
      contract?.validateData(frozen);
      guardWrite();
      final snapshot = await _database.transaction((tx) async {
        guardWrite();
        final record = _data.record(_dataKey(manifest, role));
        final current = _dataSnapshot(await record.get(tx));
        guardWrite();
        if (current.version != expectedDataVersion) {
          throw StateError('project_bundle_data_conflict');
        }
        final next = ProjectBundleApplicationData._(
          current.version + 1,
          frozen,
        );
        await record.put(tx, {
          'scopeKey': scopeKey,
          'version': next.version,
          'values': next.values,
        });
        guardWrite();
        return next;
      });
      guardWrite();
      return snapshot;
    });
  }

  Future<ProjectBundleDataContract?> _dataContract(
    ProjectBundleV2Manifest manifest,
    String expected,
    int generation,
  ) async {
    final metadata = manifest.files.firstWhere(
      (file) => file.path == 'project.json',
    );
    final bytes = await _readBlob(metadata, expected, generation);
    final project =
        const ProjectJsonCanonicalizer().parseBytes(bytes)!
            as Map<String, Object?>;
    return ProjectBundleDataContract.fromProject(project);
  }

  Future<void> _upgradeData(
    Transaction tx,
    ValidatedProjectBundleV2 bundle,
    String? sourceDigest,
    String expected,
    int generation, {
    required bool preserveDestination,
  }) async {
    if (sourceDigest == null) return;
    final previous = await _bundles.record(_key(sourceDigest)).get(tx);
    _guard(expected, generation);
    if (previous == null || previous['accepted'] != true) {
      throw StateError('project_bundle_install_corrupt');
    }
    final oldManifest = _storedManifest(previous, sourceDigest);
    if (oldManifest.projectId != bundle.manifest.projectId ||
        oldManifest.revisionId == bundle.manifest.revisionId) {
      throw StateError('project_bundle_revision_conflict');
    }
    final source = _dataSnapshot(
      await _data
          .record(_dataKey(oldManifest, ProjectBundleDataRole.installed))
          .get(tx),
    );
    _guard(expected, generation);
    if (source.version == 0) return;
    final oldContract = await _dataContract(oldManifest, expected, generation);
    if (oldContract == null) {
      return; // Unknown legacy formats remain revision-isolated.
    }
    oldContract.validateData(source.values);
    final contract = ProjectBundleDataContract.fromProject(bundle.project);
    if (contract == null) {
      throw const ProjectBundleDataUpgradeException(
        'project_bundle_data_migration_required',
      );
    }
    final destination = _data.record(
      _dataKey(bundle.manifest, ProjectBundleDataRole.installed),
    );
    final destinationRow = await destination.get(tx);
    if (destinationRow != null) {
      if (preserveDestination) {
        contract.validateData(_dataSnapshot(destinationRow).values);
        return;
      }
      throw const ProjectBundleDataUpgradeException(
        'project_bundle_data_target_exists',
      );
    }
    final values = contract.digest == oldContract.digest
        ? source.values
        : contract.migrate(source.values, sourceDigest: oldContract.digest);
    contract.validateData(values);
    final frozen = _freezeData(values);
    _guard(expected, generation);
    await destination.put(tx, {
      'scopeKey': scopeKey,
      'version': 1,
      'values': frozen,
      'copiedFromCandidateDigest': sourceDigest,
      'sourceDataVersion': source.version,
      'sourceDataSchemaDigest': oldContract.digest,
    });
    _guard(expected, generation);
  }

  String _dataKey(
    ProjectBundleV2Manifest manifest,
    ProjectBundleDataRole role,
  ) => jsonEncode([
    scopeKey,
    manifest.projectId,
    'data.v1',
    role.name,
    role == ProjectBundleDataRole.preview
        ? manifest.candidateDigest
        : manifest.revisionId,
  ]);

  ProjectBundleApplicationData _dataSnapshot(Map<String, Object?>? row) {
    if (row == null) return ProjectBundleApplicationData._(0, const {});
    if (row['scopeKey'] != scopeKey ||
        row['version'] is! int ||
        (row['version']! as int) < 1 ||
        (row['version']! as int) > 9007199254740991 ||
        row['values'] is! Map) {
      throw StateError('project_bundle_data_corrupt');
    }
    return ProjectBundleApplicationData._(
      row['version']! as int,
      _freezeData(Map<String, Object?>.from(row['values']! as Map)),
    );
  }

  Map<String, Object?> _freezeData(Map<String, Object?> values) {
    if (values.length > 256 ||
        values.keys.any(
          (key) =>
              key.isEmpty ||
              key.length > 96 ||
              key.runes.any((rune) => rune < 32 || rune == 127),
        )) {
      throw const FormatException('project_bundle_data_limit');
    }
    return _dataJson.parse(_dataJson.canonicalize(values))!
        as Map<String, Object?>;
  }

  Future<ProjectBundleV2Manifest> _manifest(
    String digest,
    String expected,
    int generation,
  ) async {
    _checkDigest(digest);
    final row = await _bundles.record(_key(digest)).get(_database);
    _guard(expected, generation);
    if (row == null) throw StateError('project_bundle_not_installed');
    final manifest = _storedManifest(row, digest);
    await _assertAvailable(_database, manifest.projectId);
    _guard(expected, generation);
    return manifest;
  }

  ProjectBundleV2Manifest _storedManifest(
    Map<String, Object?> row,
    String digest,
  ) {
    if (row['scopeKey'] != scopeKey ||
        row['candidateDigest'] != digest ||
        row['installedAt'] is! String) {
      throw StateError('project_bundle_install_corrupt');
    }
    final manifest = ProjectBundleV2Manifest.fromJson(row['manifest']);
    if (manifest.candidateDigest != digest) {
      throw StateError('project_bundle_install_corrupt');
    }
    return manifest;
  }

  Map<String, Object?> _freezeReport(Map<String, Object?> report) {
    const json = ProjectJsonCanonicalizer(
      maxBytes: 256 * 1024,
      maxNodes: 16384,
    );
    return json.parse(json.canonicalize(report))! as Map<String, Object?>;
  }

  Map<String, Object?>? _storedReport(
    Map<String, Object?> row,
    String? requested,
  ) {
    final digest = requested ?? row['latestReportDigest'];
    if (digest == null) return null;
    if (digest is! String) throw StateError('project_bundle_report_corrupt');
    _checkDigest(digest);
    final reports = row['verificationReports'];
    final raw = reports is Map ? reports[digest] : null;
    if (raw is! Map) throw StateError('project_bundle_report_missing');
    final report = _freezeReport(Map<String, Object?>.from(raw));
    if (projectBundleV2JsonDigest(report) != digest) {
      throw StateError('project_bundle_report_corrupt');
    }
    return report;
  }

  String? _headDigest(Map<String, Object?>? row, String projectId) {
    if (row == null) return null;
    if (row['scopeKey'] != scopeKey ||
        row['projectId'] != projectId ||
        row['candidateDigest'] is! String) {
      throw StateError('project_bundle_install_corrupt');
    }
    final digest = row['candidateDigest']! as String;
    _checkDigest(digest);
    return digest;
  }

  int? _headVersion(Map<String, Object?>? row) {
    final value = row?['headVersion'];
    if (value == null) return null;
    if (value is! int || value < 1 || value > projectBuildV2MaximumSequence) {
      throw StateError('project_bundle_head_corrupt');
    }
    return value;
  }

  Future<File> _blob(String digest, String expected, int generation) async {
    final file = await resolveScopedStorageFile(
      applicationSupportRoot: _supportRoot,
      relativeDirectorySegments: [
        ...accountScope.accountDirectorySegments,
        'project-bundles',
        'v2',
        'blobs',
      ],
      fileName: digest,
    );
    _guard(expected, generation);
    return file;
  }

  Future<List<int>> _readBlob(
    ProjectBundleV2FileMetadata metadata,
    String expected,
    int generation,
  ) async {
    final file = await _blob(metadata.sha256, expected, generation);
    if (!await file.exists()) throw StateError('project_bundle_file_missing');
    _guard(expected, generation);
    final handle = await file.open(mode: FileMode.read);
    try {
      _guard(expected, generation);
      if (await handle.length() != metadata.byteLength) {
        throw StateError('project_bundle_file_corrupt');
      }
      final bytes = <int>[];
      while (bytes.length <= metadata.byteLength) {
        final chunk = await handle.read(
          min(64 * 1024, metadata.byteLength + 1 - bytes.length),
        );
        _guard(expected, generation);
        if (chunk.isEmpty) break;
        bytes.addAll(chunk);
      }
      if (bytes.length != metadata.byteLength ||
          projectBundleV2BytesDigest(bytes) != metadata.sha256) {
        throw StateError('project_bundle_file_corrupt');
      }
      return bytes;
    } finally {
      await handle.close();
    }
  }

  Future<void> _writeBlob(
    ProjectBundleV2FileMetadata metadata,
    List<int> bytes,
    String expected,
    int generation,
  ) async {
    final file = await _blob(metadata.sha256, expected, generation);
    if (await file.exists()) {
      try {
        await _readBlob(metadata, expected, generation);
        return;
      } on StateError catch (error) {
        if (error.message != 'project_bundle_file_corrupt' &&
            error.message != 'project_bundle_file_missing') {
          rethrow;
        }
        // A validated re-download may atomically repair a corrupted regular
        // blob. It never follows/replaces a symlink or changes its identity.
      }
    }
    _guard(expected, generation);
    final nonce = List.generate(
      16,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final temporary = File('${file.parent.path}/pending-$nonce');
    if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw StateError('project_bundle_temp_conflict');
    }
    try {
      _guard(expected, generation);
      await temporary.writeAsBytes(bytes, flush: true);
      _guard(expected, generation);
      final targetType = await FileSystemEntity.type(
        file.path,
        followLinks: false,
      );
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.file) {
        throw StateError('project_bundle_unsafe_file');
      }
      _guard(expected, generation);
      await temporary.rename(file.path);
      _guard(expected, generation);
    } finally {
      if (await FileSystemEntity.type(temporary.path, followLinks: false) !=
          FileSystemEntityType.notFound) {
        await temporary.delete();
      }
    }
  }

  Future<void> deactivateAndDrain() async {
    if (!_sealed) {
      _sealed = true;
      _generation++;
    }
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }
}

void _checkDigest(String value) {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(value)) {
    throw const FormatException('invalid_project_bundle_digest');
  }
}

void _checkProject(String value) {
  if (!RegExp(
    r'^pb_project_[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw const FormatException('invalid_project_bundle_id');
  }
}
