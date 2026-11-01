import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_node.dart';

import 'project_build_task_issue.dart';

/// A view of recorded execution facts. It never derives progress from elapsed
/// time and never renders an exception or provider response as public text.
class AgentTaskPresentation {
  AgentTaskPresentation(this.job);

  final AgentTaskJob job;

  String get typeLabel => job.isCreatorImage
      ? 'home.task.type.image'.tr
      : 'home.task.type.${job.taskKind.name}'.tr;

  String stageLabel(AgentTaskStage stage) => job.isCreatorImage
      ? 'creator.task.stage.${stage.name}'.tr
      : (job.isProjectBuild || job.isProjectBuildV2)
      ? 'project_build.task.stage.${stage.name}'.tr
      : 'home.task.stage.${stage.name}'.tr;

  String get statusLabel => job.serverImage?.applied == true
      ? 'creator.task.applied'.tr
      : stageLabel(job.stage);

  String? get issueMessageKey {
    final issue = job.projectBuildV2?.syncIssue ?? job.projectBuild?.syncIssue;
    if (job.isProjectBuildV2) {
      return projectBuildV2TaskIssueMessageKey(
        syncIssue: issue ?? '',
        snapshotErrorCode: job.projectBuildV2?.snapshot?.errorCode ?? '',
      );
    }
    if (issue?.isNotEmpty == true) {
      if (issue!.startsWith('rejected:')) {
        return 'project_build.task.request_rejected';
      }
      return issue == 'needs_authorization'
          ? 'project_build.task.authorization_required'
          : 'project_build.task.sync_pending';
    }
    final imageIssue = job.serverImage?.syncIssue ?? '';
    if (imageIssue.isEmpty) return null;
    return imageIssue.startsWith('rejected:')
        ? 'creator.task.request_rejected'
        : 'creator.task.sync_pending';
  }

  String? get failureCode {
    if (job.status != AgentTaskJobStatus.failed &&
        job.stage != AgentTaskStage.interrupted) {
      return null;
    }
    final typed = GeneratedTaskFailureCode.fromWireName(job.failureCode);
    if (typed != null) return typed.name;
    final nodeFailure = _failedNodeFailureCode;
    if (nodeFailure != null) return nodeFailure;
    final code =
        job.projectBuildV2?.snapshot?.errorCode ??
        job.projectBuild?.snapshot?.errorCode ??
        job.serverImage?.snapshot?.errorCode ??
        job.error;
    return GeneratedTaskFailureCode.fromLegacyError(code)?.name ??
        _serverFailureCodes[code] ??
        (job.stage == AgentTaskStage.interrupted ? 'interrupted' : 'unknown');
  }

  String? get _failedNodeFailureCode {
    final binding = job.projectBuildV2;
    final snapshot = binding?.snapshot;
    if (binding == null ||
        snapshot == null ||
        snapshot.status != ProjectBuildV2Status.failed ||
        snapshot.attempt != job.attempt ||
        snapshot.agentId != job.agentId) {
      return null;
    }
    // The binding resets nodes on a new run, and this job's progress belongs
    // to one attempt. Use the actual journal order, not array position or text.
    final failedNodes = {
      for (final node in binding.nodes)
        if (node.status == ProjectBuildV2NodeStatus.failed) node.nodeId: node,
    };
    ProjectBuildV2Node? latest;
    for (final event in job.progress.reversed) {
      if (event.nodeStatus == 'failed' &&
          failedNodes.containsKey(event.nodeId)) {
        latest = failedNodes[event.nodeId];
        break;
      }
    }
    latest ??= failedNodes[binding.lastNodeId];
    if (latest == null && failedNodes.length == 1) {
      latest = failedNodes.values.single;
    }
    if (latest == null) return null;
    for (final evidence in latest.evidence.reversed) {
      if (evidence.outcome == 'failed') {
        return _nodeFailureReferences[evidence.reference];
      }
    }
    return null;
  }

  String? get failureMessageKey =>
      failureCode == null ? null : 'home.task.failure.$failureCode';

  String? get recoveryMessageKey =>
      failureCode == null ? null : 'home.task.failure.${failureCode}_action';

  bool get needsAttention =>
      job.status == AgentTaskJobStatus.failed ||
      job.status == AgentTaskJobStatus.awaitingInput ||
      job.stage == AgentTaskStage.previewReady ||
      issueMessageKey != null;

  String get ledgerGroup => needsAttention
      ? 'attention'
      : job.isActive
      ? 'active'
      : 'finished';

  String get currentAction {
    final nodes = job.projectBuildV2?.nodes ?? const <ProjectBuildV2Node>[];
    for (final node in nodes.reversed) {
      if (node.status == ProjectBuildV2NodeStatus.running ||
          (job.status == AgentTaskJobStatus.failed &&
              node.status == ProjectBuildV2NodeStatus.failed)) {
        return node.summary.isEmpty ? node.title : node.summary;
      }
    }
    for (final event in job.progress.reversed) {
      if (event.description.isEmpty) continue;
      if (job.status == AgentTaskJobStatus.failed &&
          const {
            AgentTaskStage.failed,
            AgentTaskStage.interrupted,
          }.contains(event.stage)) {
        continue;
      }
      if (job.status == AgentTaskJobStatus.failed || event.stage == job.stage) {
        return event.description;
      }
    }
    return '';
  }

  DateTime get lastUpdatedAt {
    var at = job.updatedAt ?? job.createdAt;
    for (final event in job.progress) {
      if (event.at.isAfter(at)) at = event.at;
    }
    return at;
  }

  /// Reconstructs this attempt's elapsed time from recorded phase boundaries.
  /// Only explicit user-wait intervals are excluded. Missing records do not
  /// permit guessing when a wait started, and terminal time is receipt-capped.
  Duration elapsedAt(DateTime now) {
    final terminal = const {
      AgentTaskJobStatus.completed,
      AgentTaskJobStatus.failed,
      AgentTaskJobStatus.cancelled,
    }.contains(job.status);
    final waitingForUser =
        _isUserWait(job.stage) ||
        job.status == AgentTaskJobStatus.awaitingInput;
    final end = terminal || waitingForUser || !job.isActive
        ? job.updatedAt ?? lastUpdatedAt
        : now;
    if (end.isBefore(job.createdAt)) return Duration.zero;

    var lastRecordedAt = job.createdAt;
    var waitingTime = Duration.zero;
    DateTime? waitingSince;
    for (final event in job.progress) {
      // Journal order is authoritative. A backward or future timestamp cannot
      // create a new interval or extend a task past its end receipt.
      if (event.at.isBefore(lastRecordedAt) || event.at.isAfter(end)) continue;
      lastRecordedAt = event.at;
      if (_isUserWait(event.stage)) {
        waitingSince ??= event.at;
      } else if (waitingSince != null) {
        waitingTime += event.at.difference(waitingSince);
        waitingSince = null;
      }
    }
    if (waitingSince != null) waitingTime += end.difference(waitingSince);
    final elapsed = end.difference(job.createdAt) - waitingTime;
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  static bool _isUserWait(AgentTaskStage stage) =>
      stage == AgentTaskStage.previewReady ||
      stage == AgentTaskStage.awaitingInput;

  String get recordSummary {
    final nodes = job.projectBuildV2?.nodes ?? const <ProjectBuildV2Node>[];
    if (nodes.isNotEmpty) {
      return 'home.task.recorded_nodes'.trParams({
        'completed':
            '${nodes.where((node) => node.status == ProjectBuildV2NodeStatus.succeeded).length}',
        'count': '${nodes.length}',
      });
    }
    return 'home.task.recorded_events'.trParams({
      'count': '${job.progress.length}',
    });
  }

  // Exact known legacy codes only. Never search arbitrary exception text for a
  // keyword: it can contain secrets and is not a reliable diagnosis.
  static const _serverFailureCodes = {
    'model_unavailable': 'modelUnavailable',
    'provider_unavailable': 'modelUnavailable',
    'execution_timeout': 'taskTimeout',
    'model_timeout': 'modelTimeout',
    'provider_timeout': 'modelTimeout',
    'model_output_truncated': 'modelOutputTruncated',
    'response_invalid': 'responseInvalid',
    'surface_validation_failed': 'surfaceValidationFailed',
    'validation_failed': 'surfaceValidationFailed',
    'game_runtime_timeout': 'gameRuntimeTimeout',
    'game_runtime_failed': 'gameRuntimeFailed',
    'storage_failed': 'storageFailed',
    'quota_exceeded': 'quotaExceeded',
    'quota_unavailable': 'quotaUnavailable',
    'action_unavailable': 'actionUnavailable',
    'missing_artifact': 'missingArtifact',
  };

  // Only platform-owned, failed evidence references classify a server error.
  // Budget and repair exhaustion are not user balance or provider quota errors.
  static const _nodeFailureReferences = {
    'model_quota_exhausted': 'modelQuotaExceeded',
    'model_budget_unavailable': 'modelUnavailable',
    'model_policy_unavailable': 'modelUnavailable',
    'membership_required': 'modelMembershipRequired',
    'model_access_unavailable': 'modelAuthentication',
    'storage_unavailable': 'storageFailed',
    'execution_timeout': 'taskTimeout',
    'provider_unavailable': 'modelUnavailable',
  };
}
