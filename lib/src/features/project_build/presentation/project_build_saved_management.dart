import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';

import '../application/project_build_v2_tasks.dart';
import '../domain/project_build_v2_contract.dart';
import '../domain/project_build_v2_inventory.dart';

/// Existing owned-work management sheet. Opening history is read-only; each
/// server pointer change or deletion needs a separate native user confirmation.
Future<bool> showProjectBuildSavedManagement(
  BuildContext context,
  AgentWidget item, {
  bool Function()? canContinue,
}) async {
  final scope = AppletLocalOwnership.currentScopeKey();
  final tasks = appServices.maybeFind<ProjectBuildV2Tasks>();
  final reference = item.spec['bundleReference'];
  if (!context.mounted ||
      canContinue?.call() == false ||
      !isAppletPresentationDiscoverable(item, scopeKey: scope) ||
      item.spec['rendering'] != 'projectBundle' ||
      reference is! Map ||
      reference['packageSchema'] != 2) {
    return false;
  }
  String projectId;
  try {
    projectId = projectBuildV2Id(reference['projectId'], 'project');
  } catch (_) {
    return false;
  }
  if (tasks == null ||
      tasks.appletScopeKey != scope ||
      !tasks.canManageSavedProjects) {
    showAppGlassNotice(
      title: item.title,
      message: 'project_build.saved.unavailable'.tr,
      icon: Icons.cloud_off_rounded,
    );
    return false;
  }
  return await showAppGlassSheet<bool>(
        context: context,
        builder: (_) => _SavedProjectManagement(
          title: item.title,
          projectId: projectId,
          tasks: tasks,
          appletScope: scope,
        ),
      ) ??
      false;
}

class _SavedProjectManagement extends StatefulWidget {
  const _SavedProjectManagement({
    required this.title,
    required this.projectId,
    required this.tasks,
    required this.appletScope,
  });
  final String title, projectId, appletScope;
  final ProjectBuildV2Tasks tasks;
  @override
  State<_SavedProjectManagement> createState() =>
      _SavedProjectManagementState();
}

class _SavedProjectManagementState extends State<_SavedProjectManagement> {
  ProjectBuildV2OwnedRevisions? _history;
  bool _loading = true, _busy = false;
  bool _dismissed = false;
  String? _issue;
  int _loadEpoch = 0;
  final List<Worker> _scopeWorkers = <Worker>[];
  ModalRoute<bool>? _managementRoute;
  ModalRoute<bool>? _confirmationRoute;
  bool get _current =>
      mounted &&
      !_dismissed &&
      AppletLocalOwnership.currentScopeKey() == widget.appletScope &&
      identical(appServices.maybeFind<ProjectBuildV2Tasks>(), widget.tasks) &&
      widget.tasks.canManageSavedProjects;

  @override
  void initState() {
    super.initState();
    _scopeWorkers.addAll(
      AppletLocalOwnership.watchScope(_closeAfterScopeChange),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_load());
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _managementRoute = ModalRoute.of<bool>(context);
    _closeAfterScopeChange();
  }

  void _closeAfterScopeChange() {
    if (!mounted ||
        _dismissed ||
        AppletLocalOwnership.currentScopeKey() == widget.appletScope) {
      return;
    }
    _dismissed = true;
    _loadEpoch++;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A caller can push another page while these sheets are open. Remove
      // only this management flow's routes, even when they are no longer top.
      for (final route in <ModalRoute<dynamic>?>[
        _confirmationRoute,
        _managementRoute,
      ]) {
        if (route != null && route.isActive) {
          route.navigator?.removeRoute(route);
        }
      }
    });
  }

  @override
  void dispose() {
    for (final worker in _scopeWorkers) {
      worker.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current || _busy) return;
    final epoch = ++_loadEpoch;
    setState(() {
      _loading = true;
      _issue = null;
    });
    try {
      final history = await widget.tasks.savedRevisionHistory(widget.projectId);
      if (!_current || epoch != _loadEpoch) return;
      setState(() => _history = history);
    } catch (_) {
      if (_current && epoch == _loadEpoch) {
        setState(() => _issue = 'project_build.saved.load_failed');
      }
    } finally {
      if (mounted && epoch == _loadEpoch) setState(() => _loading = false);
    }
  }

  Future<void> _edit() async {
    final history = _history;
    if (!_current || _busy || history == null || !widget.tasks.canSubmit) {
      return;
    }
    final revision = history.revisions.singleWhere(
      (entry) => entry.revisionId == history.currentRevisionId,
    );
    setState(() => _busy = true);
    try {
      final target = await widget.tasks.prepareEditTarget(
        widget.projectId,
        expectedRevisionId: history.currentRevisionId,
        expectedHeadVersion: history.currentHeadVersion,
        expectedCandidateDigest: revision.candidateDigest,
      );
      if (!mounted ||
          !_current ||
          !widget.tasks.canSubmit ||
          !target.isCurrent) {
        return;
      }
      _dismissed = true;
      Navigator.of(context).pop(false);
      appNavigation.go(
        AppRouteCatalog.home,
        extra: HomeDraftIntent.projectBuildEditing(target),
      );
    } catch (error) {
      if (_current) {
        setState(
          () => _issue =
              error is StateError &&
                  error.message == 'project_build_head_changed'
              ? 'project_build.saved.edit_head_changed'
              : 'project_build.saved.edit_unavailable',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<bool> _confirm({required bool deleting, String? savedAt}) async {
    if (!_current) return false;
    try {
      final confirmed = await showAppGlassSheet<bool>(
        context: context,
        builder: (sheet) {
          _confirmationRoute = ModalRoute.of<bool>(sheet);
          return SingleChildScrollView(
            child: Column(
              key: ValueKey(
                deleting
                    ? 'project-build-delete-confirmation'
                    : 'project-build-rollback-confirmation',
              ),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (deleting
                          ? 'project_build.saved.delete_title'
                          : 'project_build.saved.restore_title')
                      .tr,
                  style: Theme.of(sheet).textTheme.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(
                  (deleting
                          ? 'project_build.saved.delete_message'
                          : 'project_build.saved.restore_message')
                      .trParams({'name': widget.title, 'date': savedAt ?? ''}),
                ),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    AppGlassButton(
                      label: 'common.cancel'.tr,
                      primary: false,
                      onPressed: () => Navigator.of(sheet).pop(false),
                    ),
                    AppGlassButton(
                      key: ValueKey(
                        deleting
                            ? 'project-build-confirm-delete'
                            : 'project-build-confirm-rollback',
                      ),
                      label:
                          (deleting
                                  ? 'project_build.saved.delete'
                                  : 'project_build.saved.restore')
                              .tr,
                      onPressed: () => Navigator.of(sheet).pop(true),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
      return confirmed == true && _current;
    } finally {
      _confirmationRoute = null;
    }
  }

  Future<void> _delete() async {
    final history = _history;
    if (!_current || _busy || history == null) return;
    setState(() => _busy = true);
    try {
      final confirmed = await _confirm(deleting: true);
      if (!confirmed || !_current) return;
      final deleted = await widget.tasks.deleteSavedProject(
        widget.projectId,
        expectedRevision: history.currentRevisionId,
        expectedHeadVersion: history.currentHeadVersion,
      );
      if (!mounted || !_current) return;
      if (deleted) {
        _dismissed = true;
        Navigator.of(context).pop(true);
      } else {
        setState(() => _issue = 'project_build.saved.request_pending');
      }
    } catch (_) {
      if (_current) {
        setState(() => _issue = 'project_build.saved.request_pending');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore(ProjectBuildV2RevisionDescriptor revision) async {
    final history = _history;
    if (!_current ||
        _busy ||
        history == null ||
        revision.revisionId == history.currentRevisionId) {
      return;
    }
    setState(() => _busy = true);
    var refresh = false;
    try {
      final confirmed = await _confirm(
        deleting: false,
        savedAt: _date(revision.createdAt),
      );
      if (!confirmed || !_current) return;
      final restored = await widget.tasks.rollbackSavedProject(
        widget.projectId,
        targetRevision: revision.revisionId,
        expectedHeadVersion: history.currentHeadVersion,
      );
      if (!_current) return;
      refresh = restored;
      if (!restored) {
        setState(() => _issue = 'project_build.saved.request_pending');
      }
    } catch (_) {
      if (_current) {
        setState(() => _issue = 'project_build.saved.request_pending');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (refresh) await _load();
  }

  Future<void> _open(ProjectBuildV2RevisionDescriptor revision) async {
    if (!_current || _busy) return;
    setState(() => _busy = true);
    try {
      final opened = await widget.tasks.openSavedRevision(
        widget.projectId,
        revision.revisionId,
      );
      if (_current && !opened) {
        setState(() => _issue = 'project_build.saved.open_failed');
      }
    } catch (_) {
      if (_current) setState(() => _issue = 'project_build.saved.open_failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _date(DateTime date) =>
      MaterialLocalizations.of(context).formatMediumDate(date.toLocal());

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final history = _history;
    final disabled = _busy || !_current;
    return SizedBox(
      key: const ValueKey('project-build-saved-management'),
      height: math.min(MediaQuery.sizeOf(context).height * .72, 640),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'project_build.saved.history'.tr,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          if (_busy)
            const LinearProgressIndicator(
              key: ValueKey('project-build-management-busy'),
            ),
          if (_issue != null) ...[
            Text(
              _issue!.tr,
              key: const ValueKey('project-build-management-issue'),
            ),
            TextButton(
              onPressed: disabled ? null : _load,
              child: Text('common.retry'.tr),
            ),
          ],
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    children: [
                      for (final revision
                          in history?.revisions.reversed ??
                              const <ProjectBuildV2RevisionDescriptor>[])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'project_build.saved.saved_at'.trParams({
                                  'date': _date(revision.createdAt),
                                }),
                              ),
                              if (revision.revisionId ==
                                  history!.currentRevisionId)
                                Text(
                                  'project_build.saved.current'.tr,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.primary,
                                  ),
                                ),
                              Wrap(
                                spacing: 12,
                                runSpacing: 4,
                                children: [
                                  TextButton(
                                    key: ValueKey(
                                      'project-build-open-${revision.revisionId}',
                                    ),
                                    onPressed: disabled
                                        ? null
                                        : () => _open(revision),
                                    child: Text('project_build.saved.view'.tr),
                                  ),
                                  if (revision.revisionId !=
                                      history.currentRevisionId)
                                    TextButton(
                                      key: ValueKey(
                                        'project-build-restore-${revision.revisionId}',
                                      ),
                                      onPressed: disabled
                                          ? null
                                          : () => _restore(revision),
                                      child: Text(
                                        'project_build.saved.restore'.tr,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
          ),
          const SizedBox(height: 12),
          AppGlassButton(
            key: const ValueKey('project-build-edit'),
            label: 'project_build.saved.edit'.tr,
            icon: Icons.edit_note_rounded,
            onPressed: disabled || history == null || !widget.tasks.canSubmit
                ? null
                : _edit,
          ),
          const SizedBox(height: 12),
          AppGlassButton(
            key: const ValueKey('project-build-delete'),
            label: 'project_build.saved.delete'.tr,
            icon: Icons.delete_outline_rounded,
            primary: false,
            onPressed: disabled || history == null ? null : _delete,
          ),
        ],
      ),
    );
  });
}
