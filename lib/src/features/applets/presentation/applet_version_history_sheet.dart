import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/surface_web_view.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/application/applet_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';

/// A local history sheet, not a second saved applet or a public write surface.
Future<void> showAppletVersionHistory(
  BuildContext context,
  AgentWidget item, {
  bool Function()? canContinue,
}) async {
  if (canContinue?.call() == false) return;
  final scopeKey = AppletLocalOwnership.currentScopeKey();
  final rows = await appServices.find<DBService>().getAllWidgets();
  final matches = rows.where(
    (row) =>
        row.id == item.id &&
        row.spec['surfaceId'] == item.spec['surfaceId'] &&
        row.agentId == 'self' &&
        isAppletPresentationDiscoverable(row, scopeKey: scopeKey),
  );
  if (canContinue?.call() == false ||
      !context.mounted ||
      scopeKey != AppletLocalOwnership.currentScopeKey() ||
      matches.isEmpty) {
    return;
  }
  await showAppGlassSheet<void>(
    context: context,
    builder: (_) =>
        AppletVersionHistorySheet(item: matches.first, scopeKey: scopeKey),
  );
}

class AppletVersionHistorySheet extends StatefulWidget {
  const AppletVersionHistorySheet({
    super.key,
    required this.item,
    required this.scopeKey,
  });
  final AgentWidget item;
  final String scopeKey;

  @override
  State<AppletVersionHistorySheet> createState() =>
      _AppletVersionHistorySheetState();
}

class _AppletVersionHistorySheetState extends State<AppletVersionHistorySheet> {
  late AgentWidget _item = widget.item;
  SurfaceRuntime? _preview;
  int _previewGeneration = 0;
  bool _revoked = false;
  final List<Worker> _scopeWorkers = [];
  SurfaceVersionSnapshot? _selected;
  SurfaceVersionDraft? _selectedDraft;
  AppletSourceDocument? _selectedRemote;
  List<AgentGameRevisionSummary> _remoteVersions = [];
  int? _remoteHead;
  int? _nextRemoteBefore;
  bool _loadingRemote = false;
  int _remoteGeneration = 0;
  AgentGameCloudService? get _cloud =>
      appServices.maybeFind<AgentGameCloudService>();
  bool _ready = false;
  bool _busy = false;
  String? _error;

  bool get _current =>
      !_revoked && widget.scopeKey == AppletLocalOwnership.currentScopeKey();

  @override
  void initState() {
    super.initState();
    if (AgentGameCloudMetadata.fromSpec(
          _item.spec['cloud'],
        ).gameId.isNotEmpty &&
        _cloud != null) {
      try {
        _remoteVersions = _cloud!.cachedVersions(_item);
      } catch (_) {
        /* Scope check below still applies. */
      }
      unawaited(_loadRemote());
    }
    _scopeWorkers.addAll(
      AppletLocalOwnership.watchScope(() {
        if (_current) return;
        _revoked = true;
        _previewGeneration++;
        _remoteGeneration++;
        final old = _preview;
        _preview = null;
        _selected = null;
        _selectedDraft = null;
        _selectedRemote = null;
        _ready = false;
        if (old != null) _releasePreview(old);
        if (mounted) setState(() {});
      }),
    );
  }

  void _releasePreview(SurfaceRuntime runtime) {
    unawaited(runtime.close().whenComplete(runtime.onClose));
  }

  @override
  void dispose() {
    _previewGeneration++;
    _remoteGeneration++;
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    final old = _preview;
    _preview = null;
    if (old != null) _releasePreview(old);
    super.dispose();
  }

  Future<void> _select(
    SurfaceVersionSnapshot version, {
    SurfaceVersionDraft? draft,
    AppletSourceDocument? remote,
  }) async {
    if (_busy || !_current) return;
    final generation = ++_previewGeneration;
    final old = _preview;
    if (old != null) _releasePreview(old);
    final preview = SurfaceRuntime();
    setState(() {
      _selected = version;
      _selectedDraft = draft;
      _selectedRemote = remote;
      _preview = null;
      _ready = false;
      _error = null;
    });
    try {
      final source = appletVersionProject(_item, version).toJson();
      source['id'] = 'preview_${generation}_${version.id}';
      final project = SurfaceProject.fromJson(source);
      SurfaceProjectValidator.validateForShow(project);
      await preview.show(project);
      if (!mounted || !_current || generation != _previewGeneration) {
        _releasePreview(preview);
        return;
      }
      setState(() {
        _preview = preview;
        _ready = !surfaceRequiresFirstFrameValidation(project);
      });
    } catch (_) {
      _releasePreview(preview);
      if (mounted && generation == _previewGeneration) {
        setState(() => _error = 'widgets.version_unavailable'.tr);
      }
    }
  }

  Future<void> _loadRemote({bool more = false}) async {
    final cloud = _cloud;
    if (cloud == null || !_current || _loadingRemote) return;
    final generation = ++_remoteGeneration;
    setState(() => _loadingRemote = true);
    try {
      final page = await cloud.listVersions(
        _item,
        beforeRevision: more ? _nextRemoteBefore : null,
      );
      if (!mounted || !_current || generation != _remoteGeneration) return;
      setState(() {
        _remoteHead = page.currentRevisionNo;
        _nextRemoteBefore = page.nextBeforeRevision;
        final combined = {
          for (final row in _remoteVersions) row.revisionNo: row,
          for (final row in page.items) row.revisionNo: row,
        };
        _remoteVersions = combined.values.toList()
          ..sort((a, b) => b.revisionNo.compareTo(a.revisionNo));
      });
    } catch (_) {
      if (mounted && _current && generation == _remoteGeneration) {
        setState(() => _error = 'widgets.version_cloud_unavailable'.tr);
      }
    } finally {
      if (mounted && generation == _remoteGeneration) {
        setState(() => _loadingRemote = false);
      }
    }
  }

  Future<void> _selectRemote(AgentGameRevisionSummary revision) async {
    if (_busy || !_current || _cloud == null) return;
    final generation = ++_previewGeneration;
    setState(() {
      _ready = false;
      _error = null;
    });
    try {
      final document = await _cloud!.revisionSource(
        _item,
        revision.revisionNo,
        expectedSourceSha256: revision.sourceSha256,
      );
      if (!mounted || !_current || generation != _previewGeneration) return;
      final source = document.toProjectJson();
      await _select(
        SurfaceVersionSnapshot(
          id: 'cloud_${document.revisionNo}',
          number: document.revisionNo,
          source: surfaceVersionSource(
            source,
            title: source['title']?.toString() ?? _item.title,
          ),
          createdAtMillis: revision.createdAt.millisecondsSinceEpoch,
        ),
        remote: document,
      );
    } catch (_) {
      if (mounted && _current && generation == _previewGeneration) {
        setState(() => _error = 'widgets.version_cloud_unavailable'.tr);
      }
    }
  }

  Future<void> _reapply() async {
    final head = _remoteHead;
    if (_busy || !_current || head == null || _cloud == null) return;
    final confirmed = await showAppGlassSheet<bool>(
      context: context,
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'widgets.version_reapply_confirm'.tr,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Text('widgets.version_reapply_explanation'.tr),
          const SizedBox(height: 16),
          AppGlassButton(
            label: 'widgets.version_reapply'.tr,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_current) return;
    setState(() => _busy = true);
    try {
      await _cloud!.reapplyAfterConflict(_item, expectedRemoteRevisionNo: head);
      final rows = await appServices.find<DBService>().getAllWidgets();
      if (!mounted || !_current) return;
      final current = rows.where((row) => row.id == _item.id).firstOrNull;
      if (current != null) {
        setState(() {
          _item = current;
          _error = null;
        });
      }
      await _loadRemote();
    } catch (_) {
      if (mounted && _current) {
        setState(() => _error = 'widgets.version_conflict'.tr);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final version = _selected;
    if (version == null || !_ready || _busy || !_current) return;
    final confirmed = await showAppGlassSheet<bool>(
      context: context,
      builder: (context) => Column(
        key: const ValueKey('applet-version-restore-confirmation'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            (_selectedDraft != null
                    ? 'widgets.version_apply_confirm'
                    : 'widgets.version_restore_confirm')
                .tr,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          Text(
            (_selectedDraft != null
                    ? 'widgets.version_apply_explanation'
                    : 'widgets.version_restore_explanation')
                .tr,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              AppGlassButton(
                key: const ValueKey('applet-version-cancel'),
                label: 'common.cancel'.tr,
                primary: false,
                onPressed: () => Navigator.of(context).pop(false),
              ),
              AppGlassButton(
                key: const ValueKey('applet-version-confirm'),
                label:
                    (_selectedDraft != null
                            ? 'widgets.version_apply'
                            : 'widgets.version_restore')
                        .tr,
                onPressed: () => Navigator.of(context).pop(true),
              ),
            ],
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || !_current || !_ready) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final AgentWidget updated;
      final draft = _selectedDraft;
      final remote = _selectedRemote;
      if (draft != null) {
        updated = await applyAppletVersionDraft(
          item: _item,
          draftId: draft.id,
          scopeKey: widget.scopeKey,
          firstFrameReady: _ready,
        );
      } else if (remote != null) {
        updated = await applyAppletVersionSource(
          item: _item,
          source: version.source,
          scopeKey: widget.scopeKey,
          firstFrameReady: _ready,
          restoredFromCloudRevisionNo: remote.revisionNo,
        );
      } else {
        updated = await restoreAppletVersion(
          item: _item,
          versionId: version.id,
          scopeKey: widget.scopeKey,
          firstFrameReady: _ready,
        );
      }
      if (!mounted || !_current) return;
      setState(() {
        _item = updated;
        _selected = null;
        _selectedDraft = null;
        _selectedRemote = null;
        _ready = false;
      });
      final preview = _preview;
      _preview = null;
      _previewGeneration++;
      if (preview != null) _releasePreview(preview);
    } catch (error) {
      if (mounted && _current) {
        setState(
          () => _error = error.toString().contains('surface_version_conflict')
              ? 'widgets.version_conflict'.tr
              : 'widgets.version_unavailable'.tr,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pendingDraft = SurfaceVersionDraft.tryParse(
      _item.spec['pendingVersionDraft'],
    );
    final cloudMetadata = AgentGameCloudMetadata.fromSpec(_item.spec['cloud']);
    final previewVersionId = _selected?.id;
    final preview = _preview;
    final generation = _previewGeneration;
    final previewProjectId = preview?.activeSurfaceId;
    bool ownsPreview() =>
        mounted &&
        _current &&
        generation == _previewGeneration &&
        identical(_preview, preview) &&
        preview?.activeSurfaceId == previewProjectId &&
        _selected?.id == previewVersionId;
    SurfaceVersionHistory? history;
    try {
      history = SurfaceVersionHistory.read(_item.spec, title: _item.title);
    } catch (_) {
      _error = 'widgets.version_unavailable'.tr;
    }
    if (!_current) {
      return Text(
        'widgets.version_unavailable'.tr,
        key: const ValueKey('applet-version-revoked'),
      );
    }
    return SizedBox(
      key: const ValueKey('applet-version-history'),
      height: MediaQuery.sizeOf(context).height * .78,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ListView(
              children: [
                Text(
                  'widgets.version_history'.tr,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  _item.title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 8),
                Text('widgets.version_local_note'.tr),
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      _error!,
                      key: const ValueKey('applet-version-error'),
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                if (pendingDraft != null)
                  ListTile(
                    key: const ValueKey('applet-version-pending-draft'),
                    title: Text('widgets.version_draft'.tr),
                    subtitle: Text(pendingDraft.title),
                    trailing: const Icon(Icons.visibility_outlined),
                    selected: _selectedDraft?.id == pendingDraft.id,
                    onTap: _busy
                        ? null
                        : () => unawaited(
                            _select(
                              SurfaceVersionSnapshot(
                                id: pendingDraft.id,
                                number: 0,
                                source: pendingDraft.source,
                                createdAtMillis: pendingDraft.createdAtMillis,
                              ),
                              draft: pendingDraft,
                            ),
                          ),
                  ),
                if (cloudMetadata.syncState == AgentGameSyncState.conflict) ...[
                  Text('widgets.version_cloud_conflict'.tr),
                  AppGlassButton(
                    label: 'widgets.version_reapply'.tr,
                    onPressed: _busy || _remoteHead == null
                        ? null
                        : () => unawaited(_reapply()),
                  ),
                ],
                for (final version
                    in history?.versions.reversed ?? <SurfaceVersionSnapshot>[])
                  ListTile(
                    key: ValueKey('applet-version-${version.number}'),
                    selected: _selected?.id == version.id,
                    title: Text('V${version.number}'),
                    subtitle: Text(
                      version.id == history?.current.id
                          ? 'widgets.version_current'.tr
                          : version.restoredFromId != null
                          ? 'widgets.version_restored'.tr
                          : 'widgets.version_saved'.tr,
                    ),
                    trailing: const Icon(Icons.visibility_outlined),
                    onTap: _busy ? null : () => unawaited(_select(version)),
                  ),
                if (cloudMetadata.gameId.isNotEmpty && _cloud != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'widgets.version_cloud_history'.tr,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: 'common.refresh'.tr,
                        onPressed: _loadingRemote
                            ? null
                            : () => unawaited(_loadRemote()),
                        icon: const Icon(Icons.refresh_rounded),
                      ),
                    ],
                  ),
                  for (final revision in _remoteVersions)
                    ListTile(
                      key: ValueKey(
                        'applet-cloud-revision-${revision.revisionNo}',
                      ),
                      title: Text('R${revision.revisionNo}'),
                      subtitle: Text(
                        revision.revisionNo == cloudMetadata.publishedRevisionNo
                            ? 'widgets.published'.tr
                            : 'widgets.version_saved'.tr,
                      ),
                      selected:
                          _selectedRemote?.revisionNo == revision.revisionNo,
                      trailing: const Icon(Icons.visibility_outlined),
                      onTap: _busy
                          ? null
                          : () => unawaited(_selectRemote(revision)),
                    ),
                  if (_nextRemoteBefore != null)
                    TextButton(
                      onPressed: _loadingRemote
                          ? null
                          : () => unawaited(_loadRemote(more: true)),
                      child: Text('widgets.version_load_more'.tr),
                    ),
                  if (_loadingRemote) const LinearProgressIndicator(),
                ],
                if (_selected != null && preview != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'widgets.version_preview'.tr,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: 320,
                    child: SurfaceWebView(
                      key: ValueKey('applet-version-preview-${_selected!.id}'),
                      runtime: preview,
                      onFirstFrameReady: (_) {
                        if (ownsPreview()) {
                          setState(() => _ready = true);
                        }
                      },
                      onWorkerFatal: (_) {
                        if (ownsPreview()) {
                          setState(() {
                            _ready = false;
                            _error = 'widgets.version_unavailable'.tr;
                          });
                        }
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (_selected != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: AppGlassButton(
                key: const ValueKey('applet-version-restore'),
                label: _busy
                    ? 'common.loading'.tr
                    : (_selectedDraft != null
                              ? 'widgets.version_apply'
                              : 'widgets.version_restore')
                          .tr,
                onPressed:
                    !_ready ||
                        _busy ||
                        !_current ||
                        _selected?.id == history?.current.id
                    ? null
                    : () => unawaited(_restore()),
              ),
            ),
        ],
      ),
    );
  }
}
