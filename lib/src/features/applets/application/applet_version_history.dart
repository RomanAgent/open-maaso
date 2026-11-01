import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';

SurfaceProject appletVersionProject(
  AgentWidget item,
  SurfaceVersionSnapshot version,
) => SurfaceProject.fromJson({
  ...version.source,
  'id': item.spec['surfaceId'],
  'kind': version.source['surfaceKind'],
  'revisions': const <Object?>[],
});

Future<AgentWidget> applyAppletVersionDraft({
  required AgentWidget item,
  required String draftId,
  required String scopeKey,
  required bool firstFrameReady,
}) async {
  final draft = SurfaceVersionDraft.tryParse(item.spec['pendingVersionDraft']);
  if (draft == null ||
      draft.id != draftId ||
      draft.baseFingerprint !=
          surfaceVersionFingerprint(item.spec, title: item.title)) {
    throw StateError('surface_version_conflict');
  }
  return applyAppletVersionSource(
    item: item,
    source: draft.source,
    scopeKey: scopeKey,
    firstFrameReady: firstFrameReady,
    draftId: draft.id,
  );
}

/// Called only after a visible human preview/apply action. Neither this helper
/// nor draft application is exposed as a model tool or a public write action.
Future<AgentWidget> applyAppletVersionSource({
  required AgentWidget item,
  required Map<String, Object?> source,
  required String scopeKey,
  required bool firstFrameReady,
  String? draftId,
  String? restoredFromId,
  int? restoredFromCloudRevisionNo,
  String note = '',
}) async {
  if (scopeKey != AppletLocalOwnership.currentScopeKey() ||
      item.id == null ||
      item.agentId != 'self' ||
      !isAppletPresentationDiscoverable(item, scopeKey: scopeKey)) {
    throw StateError('applet_edit_target_unavailable');
  }
  final project = SurfaceProject.fromJson({
    ...source,
    'id': item.spec['surfaceId'],
    'kind': source['surfaceKind'],
    'revisions': const <Object?>[],
  });
  SurfaceProjectValidator.validateForShow(project);
  if (surfaceRequiresFirstFrameValidation(project) && !firstFrameReady) {
    throw StateError('surface_version_preview_required');
  }
  if (project.experienceType == SurfaceExperienceType.game) {
    SurfaceProjectValidator.validateForPublicGame(project);
  }
  final history = SurfaceVersionHistory.read(item.spec, title: item.title);
  final baseline = surfaceVersionFingerprint(item.spec, title: item.title);
  if (draftId != null) {
    final draft = SurfaceVersionDraft.tryParse(
      item.spec['pendingVersionDraft'],
    );
    if (draft?.id != draftId ||
        draft?.baseFingerprint != baseline ||
        draft?.sourceSha256 !=
            surfaceSourceSha256(
              surfaceVersionSource(source, title: project.title),
            )) {
      throw StateError('surface_version_conflict');
    }
  }
  final spec = <String, Object?>{
    ...item.spec,
    ...surfaceVersionSource(source, title: project.title),
  };
  spec.remove('pendingVersionDraft');
  final oldRevisions = item.spec['revisions'];
  spec['revisions'] = [
    if (oldRevisions is List) ...oldRevisions,
    {
      ...surfaceVersionSource(item.spec, title: item.title),
      'id': history.current.id,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'createdAtMillis': DateTime.now().millisecondsSinceEpoch,
    },
  ];
  spec['versionHistory'] = history
      .append(
        spec,
        title: project.title,
        restoredFromId: restoredFromId,
        restoredFromCloudRevisionNo: restoredFromCloudRevisionNo,
        note: note,
      )
      .toJson();
  final appliedFingerprint = surfaceVersionFingerprint(
    spec,
    title: project.title,
  );
  final stored = await appServices.find<DBService>().updateGeneratedSurface(
    item.id!,
    title: project.title,
    spec: spec,
    expectedScopeKey: scopeKey,
    expectedSourceFingerprint: baseline,
    validateScope: (current, expected) {
      if (expected != AppletLocalOwnership.currentScopeKey() ||
          current.agentId != 'self' ||
          current.spec['surfaceId'] != item.spec['surfaceId'] ||
          !isAppletPresentationDiscoverable(current, scopeKey: expected)) {
        return false;
      }
      if (draftId == null) return true;
      final currentDraft = SurfaceVersionDraft.tryParse(
        current.spec['pendingVersionDraft'],
      );
      // DBService checks the baseline after the first guard, then calls this
      // guard again on the proposed row inside the same transaction.
      if (currentDraft?.id == draftId &&
          currentDraft?.baseFingerprint == baseline) {
        return true;
      }
      if (!current.spec.containsKey('pendingVersionDraft') &&
          surfaceVersionFingerprint(current.spec, title: current.title) ==
              appliedFingerprint) {
        return true;
      }
      throw StateError('surface_version_conflict');
    },
  );
  final updated = AgentWidget.fromJson({
    ...item.toJson(),
    'title': project.title,
    'spec': stored,
  }, id: item.id);
  acceptAppletEditRevision(updated, baseline);
  scheduleAgentGameCloudSync(updated);
  return updated;
}

/// Applies an explicitly selected, previewed version as a new private version.
/// The database comparison happens inside its transaction, after all awaits.
Future<AgentWidget> restoreAppletVersion({
  required AgentWidget item,
  required String versionId,
  required String scopeKey,
  required bool firstFrameReady,
}) async {
  if (scopeKey != AppletLocalOwnership.currentScopeKey() ||
      item.id == null ||
      item.agentId != 'self' ||
      !isAppletPresentationDiscoverable(item, scopeKey: scopeKey)) {
    throw StateError('applet_edit_target_unavailable');
  }
  final history = SurfaceVersionHistory.read(item.spec, title: item.title);
  final version = history.find(versionId);
  if (version == null) throw StateError('revision_not_found');
  final project = appletVersionProject(item, version);
  SurfaceProjectValidator.validateForShow(project);
  if (surfaceRequiresFirstFrameValidation(project) && !firstFrameReady) {
    throw StateError('surface_version_preview_required');
  }
  final spec = <String, Object?>{...item.spec, ...version.source};
  spec['versionHistory'] = history
      .append(spec, title: project.title, restoredFromId: version.id)
      .toJson();
  // The existing legacy history is preserved; the authoritative ledger already
  // includes both the prior current source and the newly restored source.
  final baseline = surfaceVersionFingerprint(item.spec, title: item.title);
  final stored = await appServices.find<DBService>().updateGeneratedSurface(
    item.id!,
    title: project.title,
    spec: spec,
    expectedSourceFingerprint: baseline,
    expectedScopeKey: scopeKey,
    validateScope: (current, expected) =>
        expected == AppletLocalOwnership.currentScopeKey() &&
        current.agentId == 'self' &&
        current.spec['surfaceId'] == item.spec['surfaceId'] &&
        isAppletPresentationDiscoverable(current, scopeKey: expected),
  );
  final updated = AgentWidget.fromJson({
    ...item.toJson(),
    'title': project.title,
    'spec': stored,
  }, id: item.id);
  acceptAppletEditRevision(updated, baseline);
  scheduleAgentGameCloudSync(updated);
  return updated;
}
