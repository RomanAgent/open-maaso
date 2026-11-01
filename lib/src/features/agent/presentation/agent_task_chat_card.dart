import 'dart:async';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_node.dart';
import 'package:maaso/src/features/creator/presentation/creator_image_task_preview.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_task_chat_reference.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart'
    show AgentTaskKind;
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/semantic_task_title.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/applets/presentation/applet_version_history_sheet.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_actions.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'agent_task_presentation.dart';

String taskStageLabel(AgentTaskStage stage) =>
    'home.task.stage.${stage.name}'.tr;

/// The reference is stable; every action captures the concrete execution it
/// displays, then rechecks it at the runtime/persistence boundary.
class AgentTaskChatCard extends StatefulWidget {
  const AgentTaskChatCard({
    super.key,
    required this.reference,
    this.expanded = false,
    this.virtualizedProcess = false,
  });
  final AgentTaskChatReference reference;
  final bool expanded;
  final bool virtualizedProcess;

  @override
  State<AgentTaskChatCard> createState() => _AgentTaskChatCardState();
}

class _AgentTaskChatCardState extends State<AgentTaskChatCard> {
  Timer? _clock;
  bool _acting = false;
  String? _feedback;
  final Set<String> _expandedProcessNodes = {};

  void _syncClock(AgentTaskJob? job) {
    if (job?.isActive != true ||
        job?.stage == AgentTaskStage.previewReady ||
        job?.status == AgentTaskJobStatus.awaitingInput ||
        !TickerMode.valuesOf(context).enabled ||
        !ChatWindowVisibilityScope.visibleOf(context)) {
      _clock?.cancel();
      _clock = null;
      return;
    }
    _clock ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  AgentTaskJob? get _job {
    final reference = widget.reference;
    if (reference.scopeKey != AppletLocalOwnership.currentScopeKey()) {
      return null;
    }
    return appServices.maybeFind<AgentTaskJobStore>()?.latestForTask(
      reference.taskId,
      appletScopeKey: reference.scopeKey,
      agentId: reference.agentId,
    );
  }

  bool _current(AgentTaskJob captured) =>
      mounted &&
      _job?.id == captured.id &&
      _job?.attempt == captured.attempt &&
      _job?.status == captured.status;

  Future<void> _run(AgentTaskJob job, Future<bool> Function() operation) async {
    if (_acting || !_current(job)) return;
    setState(() {
      _acting = true;
      _feedback = null;
    });
    try {
      final accepted = await operation();
      if (mounted && !accepted) {
        setState(() => _feedback = 'home.task.action_unavailable'.tr);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _feedback = 'home.task.action_unavailable'.tr);
      }
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<bool> _control(
    AgentTaskJob job, {
    required bool retry,
    bool preview = false,
  }) async {
    if (job.isServerBacked) {
      if (!_current(job)) return false;
      if (preview && job.isProjectBuildV2) {
        final tasks = appServices.maybeFind<ProjectBuildV2Tasks>();
        return tasks != null &&
            await tasks.preview(job.id, expectedAttempt: job.attempt);
      }
      if (preview) {
        return job.isCreatorImage &&
            await showCreatorImageTaskPreview(context, job);
      }
      final controls = appServices.maybeFind<AgentTaskJobStore>()?.controlsFor(
        job,
      );
      if (controls == null || !controls.canControl(job, retry: retry)) {
        return false;
      }
      return retry
          ? controls.retry(job.id, expectedAttempt: job.attempt)
          : controls.cancel(job.id, expectedAttempt: job.attempt);
    }
    final registry = appServices.maybeFind<AgentRuntimeRegistry>();
    if (registry == null) return false;
    var accepted = false;
    await registry.runAccountOperation(() async {
      if (!_current(job)) return;
      final runtime = registry.get(job.agentId);
      if (runtime == null) return;
      if (preview) {
        accepted = runtime.openBackgroundTaskPreview(
          job.id,
          expectedAttempt: job.attempt,
        );
        if (accepted && widget.expanded && mounted) Navigator.of(context).pop();
      } else if (retry) {
        accepted = runtime.retryBackgroundTaskJob(
          job.id,
          expectedAttempt: job.attempt,
        );
      } else {
        await runtime.cancelBackgroundTaskJob(
          job.id,
          expectedAttempt: job.attempt,
        );
        accepted = true;
      }
      await appServices.find<AgentTaskJobStore>().flush();
    });
    return accepted;
  }

  Future<AgentWidget?> _artifact(AgentTaskJob job) async {
    final database = appServices.maybeFind<DBService>();
    if (database == null || job.widgetId == null) return null;
    final rows = await database.getAllWidgets();
    if (!_current(job)) return null;
    for (final item in rows) {
      if (item.id == job.widgetId &&
          item.agentId == job.agentId &&
          item.spec['surfaceId'] == job.surfaceId &&
          isAppletPresentationDiscoverable(
            item,
            scopeKey: job.appletScopeKey,
          )) {
        return item;
      }
    }
    return null;
  }

  Future<bool> _open(AgentTaskJob job, {bool edit = false}) async {
    final item = await _artifact(job);
    if (item == null) return false;
    if (widget.expanded && mounted) Navigator.of(context).pop();
    if (edit) return beginAppletEditing(item);
    await openAgentWidget(
      item,
      canContinue: () =>
          job.appletScopeKey == AppletLocalOwnership.currentScopeKey(),
    );
    return true;
  }

  Future<bool> _versions(AgentTaskJob job) async {
    final item = await _artifact(job);
    if (item == null || !mounted) return false;
    final navigator = Navigator.of(context);
    if (widget.expanded) navigator.pop();
    await showAppletVersionHistory(
      navigator.context,
      item,
      canContinue: () =>
          job.appletScopeKey == AppletLocalOwnership.currentScopeKey(),
    );
    return true;
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    final job = _job;
    _syncClock(job);
    if (job == null) return Text('home.task.unavailable'.tr);
    final glass = MaasoGlassTheme.of(context);
    final presentation = AgentTaskPresentation(job);
    final seconds = presentation
        .elapsedAt(DateTime.now())
        .inSeconds
        .clamp(0, 2147483647);
    final duration = seconds < 60
        ? '${seconds}s'
        : '${seconds ~/ 60}m ${seconds % 60}s';
    final enabled = !_acting;
    final controls = appServices.find<AgentTaskJobStore>().controlsFor(job);
    final canCancel = job.isServerBacked
        ? controls?.canControl(job, retry: false) == true
        : job.status == AgentTaskJobStatus.running ||
              job.status == AgentTaskJobStatus.awaitingInput;
    final canRetry = job.isServerBacked
        ? controls?.canControl(job, retry: true) == true
        : job.canRetryLocally;
    final stageLabel = presentation.stageLabel;
    final projectTasks = appServices.maybeFind<ProjectBuildV2Tasks>();
    final issueKey = presentation.issueMessageKey;
    final currentDescription = presentation.currentAction;
    final header = <Widget>[
      _TaskStatusLine(job: job, label: presentation.statusLabel),
      const SizedBox(height: 8),
      Text(
        semanticTaskTitle(
          userText: job.userText,
          projectBrief: job.projectBrief,
          fallbackTitle: switch (job.taskKind) {
            AgentTaskKind.gameGeneration => 'home.task.kind.game'.tr,
            AgentTaskKind.surfaceGeneration => 'home.task.kind.surface'.tr,
            _ => 'home.task.kind.default'.tr,
          },
        ),
        maxLines: widget.expanded ? null : 2,
        overflow: widget.expanded ? null : TextOverflow.ellipsis,
        style: TextStyle(
          fontWeight: FontWeight.w700,
          color: glass.foregroundPrimary,
        ),
      ),
      if (!widget.expanded)
        TextButton.icon(
          onPressed: () => showAgentTaskProcess(context, widget.reference),
          icon: const Icon(Icons.more_horiz_rounded, size: 18),
          label: Text('home.task.view_process'.tr),
        ),
      const SizedBox(height: 8),
      Text(
        'home.task.elapsed'.trParams({'duration': duration}),
        style: TextStyle(color: glass.foregroundSecondary, fontSize: 13),
      ),
      Text(
        'home.task.updated_at'.trParams({
          'time': _taskUpdateLabel(context, presentation.lastUpdatedAt),
        }),
        style: TextStyle(color: glass.foregroundSecondary, fontSize: 13),
      ),
      if (!widget.expanded && currentDescription.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                job.status == AgentTaskJobStatus.failed
                    ? 'home.task.last_action'.tr
                    : 'home.task.current_action'.tr,
                style: TextStyle(
                  color: glass.foregroundSecondary,
                  fontSize: 13,
                ),
              ),
              Text(
                _readableNodeText(currentDescription),
                key: const ValueKey('task-current-action'),
                style: TextStyle(color: glass.foregroundPrimary),
              ),
            ],
          ),
        ),
      if (presentation.failureMessageKey case final failureKey?)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: _TaskFailureSummary(
            reason: failureKey.tr,
            recovery: presentation.recoveryMessageKey!.tr,
          ),
        )
      else if (job.stage == AgentTaskStage.previewReady &&
          job.pendingPrompt.isEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text('home.task.preview_ready_message'.tr),
        ),
      if (issueKey != null)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Semantics(
            liveRegion: true,
            child: Text(
              issueKey.tr,
              key: const ValueKey('project-build-task-issue'),
            ),
          ),
        )
      else if (job.projectBuild?.pendingCommand != null ||
          job.projectBuildV2?.pendingCommand != null)
        Text('project_build.task.command_pending'.tr),
      if (job.attempt > 1)
        Text('home.task.attempt'.trParams({'count': '${job.attempt}'})),
      if (job.status == AgentTaskJobStatus.awaitingInput &&
          job.pendingPrompt.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(job.pendingPrompt),
        ),
      if (widget.expanded) ...[
        const SizedBox(height: 12),
        Text(
          presentation.recordSummary,
          style: TextStyle(
            color: glass.foregroundPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'home.task.process_note'.tr,
          style: TextStyle(color: glass.foregroundSecondary, fontSize: 13),
        ),
        const SizedBox(height: 8),
      ],
    ];
    final footer = <Widget>[
      if (job.isCreatorImage && canRetry) Text('creator.task.retry_cost'.tr),
      Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          if ((job.isProjectBuildV2
                  ? projectTasks?.canPreview(job) == true
                  : job.stage == AgentTaskStage.previewReady) ||
              (job.isCreatorImage &&
                  job.serverImage?.snapshot?.artifact != null))
            TextButton(
              onPressed: enabled
                  ? () => _run(
                      job,
                      () => _control(job, retry: false, preview: true),
                    )
                  : null,
              child: Text('home.task.preview_result'.tr),
            ),
          if (job.isProjectBuildV2 && projectTasks?.canAccept(job) == true)
            TextButton(
              onPressed: enabled
                  ? () => _run(
                      job,
                      () => projectTasks!.accept(
                        job.id,
                        expectedAttempt: job.attempt,
                      ),
                    )
                  : null,
              child: Text('project_build.task.save_result'.tr),
            ),
          if (job.isProjectBuildV2 && projectTasks?.canOpen(job) == true)
            TextButton(
              onPressed: enabled
                  ? () => _run(
                      job,
                      () => projectTasks!.open(
                        job.id,
                        expectedAttempt: job.attempt,
                      ),
                    )
                  : null,
              child: Text('home.task.open_result'.tr),
            ),
          if (canCancel)
            TextButton(
              onPressed: enabled
                  ? () => _run(job, () => _control(job, retry: false))
                  : null,
              child: Text('common.cancel'.tr),
            ),
          if (canRetry)
            TextButton(
              onPressed: enabled
                  ? () => _run(job, () => _control(job, retry: true))
                  : null,
              child: Text(
                (!job.isServerBacked &&
                            job.taskKind == AgentTaskKind.gameGeneration
                        ? 'home.task.continue_generation'
                        : 'common.retry')
                    .tr,
              ),
            ),
          if (job.status == AgentTaskJobStatus.completed &&
              job.widgetId != null) ...[
            TextButton(
              onPressed: enabled ? () => _run(job, () => _open(job)) : null,
              child: Text('home.task.open_result'.tr),
            ),
            if (job.taskKind.name != 'gameGeneration')
              TextButton(
                onPressed: enabled
                    ? () => _run(job, () => _open(job, edit: true))
                    : null,
                child: Text('home.task.edit_result'.tr),
              ),
            TextButton(
              onPressed: enabled ? () => _run(job, () => _versions(job)) : null,
              child: Text('home.task.versions'.tr),
            ),
          ],
        ],
      ),
      if (_feedback != null)
        Text(
          _feedback!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ];
    if (widget.expanded && widget.virtualizedProcess) {
      final attempts = appServices.find<AgentTaskJobStore>().jobs.where(
        (row) =>
            row.taskId == job.taskId &&
            row.appletScopeKey == job.appletScopeKey &&
            row.agentId == job.agentId,
      );
      final rows = <_TaskProcessRow>[];
      for (final attempt in attempts) {
        if (job.attempt > 1) rows.add(_TaskProcessRow(attempt: attempt));
        final nodes =
            attempt.projectBuildV2?.nodes ?? const <ProjectBuildV2Node>[];
        final byId = {for (final node in nodes) node.nodeId: node};
        final history = <String, List<AgentTaskProgress>>{};
        for (final event in attempt.progress) {
          if (event.nodeId != null) (history[event.nodeId!] ??= []).add(event);
        }
        final seen = <String>{};
        void appendNode(ProjectBuildV2Node node) {
          var depth = 0, parent = node.parentId;
          while (parent != null) {
            depth++;
            parent = byId[parent]?.parentId;
          }
          final id = 'node:${attempt.id}:${node.nodeId}';
          rows.add(_TaskProcessRow(attempt: attempt, node: node, depth: depth));
          if (_expandedProcessNodes.contains(id)) {
            rows.add(
              _TaskProcessRow(
                attempt: attempt,
                node: node,
                depth: depth,
                details: true,
              ),
            );
            for (final event
                in history[node.nodeId] ?? const <AgentTaskProgress>[]) {
              rows.add(
                _TaskProcessRow(
                  attempt: attempt,
                  event: event,
                  depth: depth + 1,
                  history: true,
                ),
              );
            }
          }
        }

        for (final event in attempt.progress) {
          final node = byId[event.nodeId];
          if (node == null) {
            rows.add(_TaskProcessRow(attempt: attempt, event: event));
          } else if (seen.add(node.nodeId)) {
            appendNode(node);
          }
        }
        for (final node in nodes) {
          if (seen.add(node.nodeId)) appendNode(node);
        }
      }
      final keys = [for (final row in rows) row.key];
      final indexByKey = {
        for (var index = 0; index < keys.length; index++) keys[index]: index,
      };
      return Semantics(
        container: true,
        child: CustomScrollView(
          key: PageStorageKey(
            'task-process-scroll-${widget.reference.scopeKey}-${job.taskId}',
          ),
          scrollCacheExtent: const ScrollCacheExtent.pixels(160),
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: header,
              ),
            ),
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final row = rows[index],
                      event = rows[index].event,
                      node = rows[index].node;
                  if (node != null) {
                    final id = 'node:${row.attempt.id}:${node.nodeId}';
                    if (row.details) {
                      return _ProjectNodeDetails(
                        key: ValueKey(keys[index]),
                        node: node,
                        depth: row.depth,
                        allNodes: row.attempt.projectBuildV2!.nodes,
                      );
                    }
                    final incomplete =
                        const {
                          AgentTaskJobStatus.failed,
                          AgentTaskJobStatus.cancelled,
                          AgentTaskJobStatus.completed,
                        }.contains(row.attempt.status) &&
                        !node.isTerminal;
                    return _ProjectNodeHeading(
                      key: ValueKey(keys[index]),
                      nodeId: '${row.attempt.id}:${node.nodeId}',
                      node: node,
                      depth: row.depth,
                      incomplete: incomplete,
                      expanded: _expandedProcessNodes.contains(id),
                      onToggle: () => setState(() {
                        if (!_expandedProcessNodes.add(id)) {
                          _expandedProcessNodes.remove(id);
                        }
                      }),
                    );
                  }
                  if (event == null) {
                    return Padding(
                      key: ValueKey(keys[index]),
                      padding: const EdgeInsets.only(top: 16, bottom: 4),
                      child: Text(
                        'home.task.attempt'.trParams({
                          'count': '${row.attempt.attempt}',
                        }),
                      ),
                    );
                  }
                  final nodeId = '${row.attempt.id}:${event.sequence}';
                  return Padding(
                    key: ValueKey(keys[index]),
                    padding: EdgeInsets.only(left: row.depth * 12.0),
                    child: _AgentTaskProgressNode(
                      nodeId: nodeId,
                      event: event,
                      stageLabel: event.nodeStatus == null
                          ? stageLabel(event.stage)
                          : 'project_build.node.status.${event.nodeStatus}'.tr,
                      expanded: _expandedProcessNodes.contains(nodeId),
                      onToggle: () => setState(() {
                        if (!_expandedProcessNodes.add(nodeId)) {
                          _expandedProcessNodes.remove(nodeId);
                        }
                      }),
                    ),
                  );
                },
                childCount: rows.length,
                findChildIndexCallback: (key) =>
                    key is ValueKey<String> ? indexByKey[key.value] : null,
              ),
            ),
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: footer,
              ),
            ),
          ],
        ),
      );
    }
    return Semantics(
      container: true,
      child: Column(
        key: ValueKey('task-card-${job.taskId}'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ...header,
          if (widget.expanded) ...[
            const SizedBox(height: 16),
            for (final attempt
                in appServices.find<AgentTaskJobStore>().jobs.where(
                  (row) =>
                      row.taskId == job.taskId &&
                      row.appletScopeKey == job.appletScopeKey &&
                      row.agentId == job.agentId,
                )) ...[
              if (job.attempt > 1)
                Text(
                  'home.task.attempt'.trParams({'count': '${attempt.attempt}'}),
                ),
              for (final event in attempt.progress)
                _AgentTaskProgressNode(
                  key: ValueKey(
                    'task-progress-${attempt.id}:${event.sequence}',
                  ),
                  nodeId: '${attempt.id}:${event.sequence}',
                  event: event,
                  stageLabel: stageLabel(event.stage),
                ),
            ],
          ],
          ...footer,
        ],
      ),
    );
  });
}

String _taskUpdateLabel(BuildContext context, DateTime at) {
  final local = at.toLocal();
  return '${MaterialLocalizations.of(context).formatShortDate(local)} ${TimeOfDay.fromDateTime(local).format(context)}';
}

class _TaskStatusLine extends StatelessWidget {
  const _TaskStatusLine({required this.job, required this.label});

  final AgentTaskJob job;
  final String label;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final failure = job.status == AgentTaskJobStatus.failed;
    final attention = AgentTaskPresentation(job).needsAttention;
    final icon = failure
        ? Icons.error_outline_rounded
        : job.status == AgentTaskJobStatus.completed
        ? Icons.task_alt_rounded
        : job.status == AgentTaskJobStatus.cancelled
        ? Icons.cancel_outlined
        : attention
        ? Icons.pause_circle_outline_rounded
        : Icons.schedule_rounded;
    return Semantics(
      liveRegion: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Icon(
              icon,
              size: 20,
              color: failure
                  ? Theme.of(context).colorScheme.error
                  : glass.accent,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${AgentTaskPresentation(job).typeLabel} · $label',
              key: const ValueKey('task-status-label'),
              style: TextStyle(
                color: glass.foregroundPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TaskFailureSummary extends StatelessWidget {
  const _TaskFailureSummary({required this.reason, required this.recovery});

  final String reason, recovery;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Semantics(
      key: const ValueKey('task-failure-summary'),
      liveRegion: true,
      container: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: glass.muted,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(reason, style: TextStyle(color: glass.foregroundPrimary)),
              const SizedBox(height: 4),
              Text(
                recovery,
                style: TextStyle(
                  color: glass.foregroundSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskProcessRow {
  const _TaskProcessRow({
    required this.attempt,
    this.event,
    this.node,
    this.depth = 0,
    this.details = false,
    this.history = false,
  });
  final AgentTaskJob attempt;
  final AgentTaskProgress? event;
  final ProjectBuildV2Node? node;
  final int depth;
  final bool details, history;
  String get key => node != null
      ? 'task-node-${details ? 'details' : 'heading'}-${attempt.id}:${node!.nodeId}'
      : event != null
      ? 'task-${history ? 'node-record' : 'progress'}-${attempt.id}:${event!.sequence}'
      : 'task-attempt-${attempt.id}';
}

// Keep directional formatting control characters visible in public audit text.
String _readableNodeText(String value) => value.replaceAllMapped(
  RegExp(r'[\u202A-\u202E\u2066-\u2069]'),
  (match) => '\\u${match[0]!.runes.single.toRadixString(16).padLeft(4, '0')}',
);

class _ProjectNodeHeading extends StatelessWidget {
  const _ProjectNodeHeading({
    super.key,
    required this.nodeId,
    required this.node,
    required this.depth,
    required this.incomplete,
    required this.expanded,
    required this.onToggle,
  });
  final String nodeId;
  final ProjectBuildV2Node node;
  final int depth;
  final bool incomplete, expanded;
  final VoidCallback onToggle;
  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: depth * 12.0, top: 4, bottom: 4),
      child: Semantics(
        key: ValueKey('task-node-toggle-$nodeId'),
        expanded: expanded,
        child: TextButton(
          onPressed: onToggle,
          style: TextButton.styleFrom(
            foregroundColor: glass.foregroundPrimary,
            minimumSize: const Size(0, 48),
            padding: const EdgeInsets.symmetric(vertical: 8),
            alignment: Alignment.centerLeft,
            splashFactory: NoSplash.splashFactory,
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ExcludeSemantics(
                child: Icon(
                  switch (node.status) {
                    ProjectBuildV2NodeStatus.succeeded =>
                      Icons.check_circle_outline_rounded,
                    ProjectBuildV2NodeStatus.failed =>
                      Icons.error_outline_rounded,
                    ProjectBuildV2NodeStatus.cancelled => Icons.cancel_outlined,
                    _ => Icons.schedule_rounded,
                  },
                  size: 20,
                  color: node.status == ProjectBuildV2NodeStatus.failed
                      ? Theme.of(context).colorScheme.error
                      : glass.foregroundPrimary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _readableNodeText(node.title),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      incomplete
                          ? 'project_build.node.incomplete_terminal'.tr
                          : 'project_build.node.status.${node.status.name}'.tr,
                      style: TextStyle(
                        fontSize: 13,
                        color: glass.foregroundPrimary,
                      ),
                    ),
                    if (node.summary.isNotEmpty && !expanded)
                      Text(
                        _readableNodeText(node.summary),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ExcludeSemantics(
                child: Icon(
                  expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  size: 20,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectNodeDetails extends StatelessWidget {
  const _ProjectNodeDetails({
    super.key,
    required this.node,
    required this.depth,
    required this.allNodes,
  });
  final ProjectBuildV2Node node;
  final int depth;
  final List<ProjectBuildV2Node> allNodes;
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: (depth + 1) * 12.0, bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (node.dependencyIds.isNotEmpty)
          Text(
            'project_build.node.dependencies'.trParams({
              'names': node.dependencyIds
                  .map(
                    (id) => allNodes.singleWhere((n) => n.nodeId == id).title,
                  )
                  .join(', '),
            }),
          ),
        if (node.summary.isNotEmpty) Text(_readableNodeText(node.summary)),
        if (node.details.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(_readableNodeText(node.details)),
          ),
        for (final evidence in node.evidence)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              [
                _readableNodeText(evidence.label),
                'home.task.evidence.${evidence.outcome}'.tr,
                if (evidence.count != null)
                  'home.task.evidence.count'.trParams({
                    'count': '${evidence.count}',
                  }),
              ].join(' · '),
            ),
          ),
      ],
    ),
  );
}

/// A public execution record, not a new material or a second task controller.
/// Its stable attempt/sequence key keeps expansion and keyboard focus intact
/// when a later progress record arrives or the elapsed-time label updates.
class _AgentTaskProgressNode extends StatefulWidget {
  const _AgentTaskProgressNode({
    super.key,
    required this.nodeId,
    required this.event,
    required this.stageLabel,
    this.expanded,
    this.onToggle,
  });

  final String nodeId;
  final AgentTaskProgress event;
  final String stageLabel;
  final bool? expanded;
  final VoidCallback? onToggle;

  @override
  State<_AgentTaskProgressNode> createState() => _AgentTaskProgressNodeState();
}

class _AgentTaskProgressNodeState extends State<_AgentTaskProgressNode> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final event = widget.event;
    final expanded = widget.expanded ?? _expanded;
    final glass = MaasoGlassTheme.of(context);
    final hasDetails = event.details.isNotEmpty || event.evidence.isNotEmpty;
    final title = event.description.isEmpty
        ? widget.stageLabel
        : event.description;
    final time = TimeOfDay.fromDateTime(event.at.toLocal()).format(context);
    final failed =
        event.stage == AgentTaskStage.failed ||
        event.stage == AgentTaskStage.interrupted ||
        event.evidence.any(
          (item) => item.outcome == AgentTaskEvidenceOutcome.failed,
        );
    final recordedSuccess =
        event.stage == AgentTaskStage.completed ||
        event.evidence.any(
          (item) =>
              item.outcome == AgentTaskEvidenceOutcome.passed ||
              item.outcome == AgentTaskEvidenceOutcome.completed,
        );
    final header = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 20,
          child: Padding(
            padding: EdgeInsets.only(top: failed || recordedSuccess ? 2 : 8),
            child: ExcludeSemantics(
              child: Icon(
                failed
                    ? Icons.error_outline_rounded
                    : recordedSuccess
                    ? Icons.check_circle_outline_rounded
                    : Icons.circle,
                size: failed || recordedSuccess ? 20 : 8,
                color: failed
                    ? Theme.of(context).colorScheme.error
                    : glass.foregroundPrimary,
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: TextStyle(color: glass.foregroundPrimary)),
              const SizedBox(height: 4),
              Text(
                event.description.isEmpty
                    ? time
                    : '${widget.stageLabel} · $time',
                style: TextStyle(color: glass.foregroundPrimary, fontSize: 13),
              ),
            ],
          ),
        ),
        if (hasDetails) ...[
          const SizedBox(width: 8),
          ExcludeSemantics(
            child: Icon(
              expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
              size: 20,
            ),
          ),
        ],
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hasDetails)
            Semantics(
              key: ValueKey('task-progress-toggle-${widget.nodeId}'),
              expanded: expanded,
              hint: expanded
                  ? 'home.task.node.collapse'.tr
                  : 'home.task.node.expand'.tr,
              child: TextButton(
                onPressed:
                    widget.onToggle ??
                    () => setState(() => _expanded = !_expanded),
                style: TextButton.styleFrom(
                  foregroundColor: glass.foregroundPrimary,
                  minimumSize: const Size(0, 48),
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  alignment: Alignment.centerLeft,
                  splashFactory: NoSplash.splashFactory,
                ),
                child: header,
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: header,
            ),
          if (hasDetails && expanded)
            Padding(
              key: ValueKey('task-progress-details-${widget.nodeId}'),
              padding: const EdgeInsets.only(left: 20, top: 4, bottom: 8),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (event.details.isNotEmpty)
                    Text(
                      event.details,
                      style: TextStyle(color: glass.foregroundPrimary),
                    ),
                  for (final evidence in event.evidence)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ExcludeSemantics(
                            child: Icon(
                              switch (evidence.outcome) {
                                AgentTaskEvidenceOutcome.started =>
                                  Icons.play_circle_outline_rounded,
                                AgentTaskEvidenceOutcome.passed =>
                                  Icons.check_circle_outline_rounded,
                                AgentTaskEvidenceOutcome.failed =>
                                  Icons.error_outline_rounded,
                                AgentTaskEvidenceOutcome.completed =>
                                  Icons.task_alt_rounded,
                              },
                              size: 20,
                              color:
                                  evidence.outcome ==
                                      AgentTaskEvidenceOutcome.failed
                                  ? Theme.of(context).colorScheme.error
                                  : glass.foregroundPrimary,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  evidence.label,
                                  style: TextStyle(
                                    color: glass.foregroundPrimary,
                                  ),
                                ),
                                Text(
                                  [
                                    'home.task.evidence.${evidence.outcome.name}'
                                        .tr,
                                    if (evidence.count != null)
                                      'home.task.evidence.count'.trParams({
                                        'count': '${evidence.count}',
                                      }),
                                  ].join(' · '),
                                  style: TextStyle(
                                    color: glass.foregroundPrimary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Task details and history share one drawer above the entire Home shell.
/// The sheet owns the safe-area background; only its contents are inset.
Future<T?> _showAgentTaskDrawer<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  MessageActionsAnchor.dismissActive();
  FocusManager.instance.primaryFocus?.unfocus();
  return showModalBottomSheet<T>(
    context: context,
    useRootNavigator: true,
    useSafeArea: true,
    isScrollControlled: true,
    backgroundColor: MaasoGlassTheme.of(context).surface,
    builder: (context) => SizedBox(
      height: MediaQuery.sizeOf(context).height * .65,
      child: SafeArea(top: false, child: builder(context)),
    ),
  );
}

Future<void> showAgentTaskProcess(
  BuildContext context,
  AgentTaskChatReference reference,
) async {
  final openHistory = await _showAgentTaskDrawer<bool>(
    context,
    builder: (context) => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'home.task.process'.tr,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              AppGlassIconButton(
                key: const ValueKey('task-process-history'),
                size: 48,
                icon: Icons.history_rounded,
                tooltip: 'home.task.history'.tr,
                onPressed: () => Navigator.of(context).pop(true),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text('home.task.collapse'.tr),
              ),
            ],
          ),
          Expanded(
            child: AgentTaskChatCard(
              reference: reference,
              expanded: true,
              virtualizedProcess: true,
            ),
          ),
        ],
      ),
    ),
  );
  if (openHistory == true && context.mounted) {
    await showAgentTaskLedger(context);
  }
}

Future<void> showAgentTaskLedger(BuildContext context) async {
  final store = appServices.maybeFind<AgentTaskJobStore>();
  if (store == null) return;
  await _showAgentTaskDrawer<void>(
    context,
    builder: (context) => AppReactiveBuilder(() {
      final scope = AppletLocalOwnership.currentScopeKey();
      final seen = <String>{};
      final jobs = store.jobs.reversed
          .where(
            (job) =>
                job.agentId == 'self' &&
                job.appletScopeKey == scope &&
                seen.add(job.taskId),
          )
          .toList();
      final rows = <({String? group, AgentTaskJob? job})>[];
      for (final group in ['active', 'attention', 'finished']) {
        final members = jobs.where(
          (job) => AgentTaskPresentation(job).ledgerGroup == group,
        );
        if (members.isEmpty) continue;
        rows.add((group: group, job: null));
        rows.addAll(members.map((job) => (group: null, job: job)));
      }
      return Column(
        children: [
          ListTile(
            title: Text('home.task.history'.tr),
            trailing: IconButton(
              tooltip: 'common.close'.tr,
              onPressed: () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ),
          Expanded(
            child: rows.isEmpty
                ? Center(child: Text('home.task.history_empty'.tr))
                : ListView.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      final job = row.job;
                      if (job == null) {
                        return Padding(
                          key: ValueKey('task-ledger-group-${row.group}'),
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Text(
                            'home.task.group.${row.group}'.tr,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        );
                      }
                      final presentation = AgentTaskPresentation(job);
                      final glass = MaasoGlassTheme.of(context);
                      return Padding(
                        key: ValueKey('task-ledger-row-${job.taskId}'),
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                        child: AppGlassSurface(
                          role: AppGlassSurfaceRole.staticSurface,
                          behavior: AppGlassSurfaceBehavior.staticSurface,
                          cornerRadius: 12,
                          child: Material(
                            type: MaterialType.transparency,
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(12),
                              title: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  _TaskStatusLine(
                                    job: job,
                                    label: presentation.statusLabel,
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    semanticTaskTitle(
                                      userText: job.userText,
                                      projectBrief: job.projectBrief,
                                      fallbackTitle: switch (job.taskKind) {
                                        AgentTaskKind.gameGeneration =>
                                          'home.task.kind.game'.tr,
                                        AgentTaskKind.surfaceGeneration =>
                                          'home.task.kind.surface'.tr,
                                        _ => 'home.task.kind.default'.tr,
                                      },
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                              subtitle: Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    if (presentation.failureMessageKey
                                        case final key?)
                                      Text(key.tr)
                                    else if (presentation.issueMessageKey
                                        case final key?)
                                      Text(key.tr)
                                    else if (presentation
                                        .currentAction
                                        .isNotEmpty)
                                      Text(
                                        _readableNodeText(
                                          presentation.currentAction,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'home.task.updated_at'.trParams({
                                        'time': _taskUpdateLabel(
                                          context,
                                          presentation.lastUpdatedAt,
                                        ),
                                      }),
                                      style: TextStyle(
                                        color: glass.foregroundSecondary,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              trailing: const ExcludeSemantics(
                                child: Icon(Icons.chevron_right_rounded),
                              ),
                              onTap: () {
                                final navigator = Navigator.of(context);
                                navigator.pop();
                                showAgentTaskProcess(
                                  navigator.context,
                                  store.cardFor(job).taskReference!,
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      );
    }),
  );
}
