import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_task_binding.dart';
import 'package:maaso/src/features/project_build/data/project_build_repository.dart';
import 'agent_task_persistence.dart';
import 'generated_task_diagnostics.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_node.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'package:maaso/src/features/project_build/domain/project_build_edit_identity.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';

enum AgentTaskStage {
  submitting,
  queued,
  synchronizing,
  generating,
  validating,
  saving,
  awaitingInput,
  previewReady,
  cancelling,
  completed,
  failed,
  cancelled,
  interrupted,
}

enum AgentTaskEvidenceKind { execution, validation, artifact }

enum AgentTaskEvidenceOutcome { started, passed, failed, completed }

/// An allowlisted public fact supplied by the execution boundary. Labels must
/// be authored summaries, never provider responses, exception text or secrets.
class AgentTaskEvidence {
  const AgentTaskEvidence({
    required this.kind,
    required this.outcome,
    required this.label,
    this.count,
    this.reference,
  });

  static const maxLabelLength = 120;
  static const maxReferenceLength = 160;
  static const maxCount = 1000000;
  static final _referencePattern = RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.-]*$');
  static const _jsonKeys = {'kind', 'outcome', 'label', 'count', 'reference'};

  final AgentTaskEvidenceKind kind;
  final AgentTaskEvidenceOutcome outcome;
  final String label;
  final int? count;
  final String? reference;

  bool get isValid =>
      label.trim().isNotEmpty &&
      _validPublicTaskText(label, maxLabelLength) &&
      (count == null || (count! >= 0 && count! <= maxCount)) &&
      (reference == null ||
          (reference!.length <= maxReferenceLength &&
              _referencePattern.hasMatch(reference!)));

  Map<String, Object?> toJson() {
    if (!isValid) throw const FormatException('invalid_task_evidence');
    return {
      'kind': kind.name,
      'outcome': outcome.name,
      'label': label,
      if (count != null) 'count': count,
      if (reference != null) 'reference': reference,
    };
  }

  factory AgentTaskEvidence.fromJson(Map<String, Object?> data) {
    if (data.keys.any((key) => !_jsonKeys.contains(key))) {
      throw const FormatException('unknown_task_evidence_field');
    }
    final result = AgentTaskEvidence(
      kind: AgentTaskEvidenceKind.values.byName(data['kind'] as String),
      outcome: AgentTaskEvidenceOutcome.values.byName(
        data['outcome'] as String,
      ),
      label: data['label'] as String,
      count: data['count'] as int?,
      reference: data['reference'] as String?,
    );
    if (!result.isValid) throw const FormatException('invalid_task_evidence');
    return result;
  }
}

/// Only public lifecycle facts are persisted here, never model reasoning or
/// raw tool responses. The stable sequence also deduplicates restored events.
class AgentTaskProgress {
  const AgentTaskProgress({
    required this.sequence,
    required this.stage,
    required this.at,
    this.description = '',
    this.details = '',
    this.evidence = const [],
    this.nodeId,
    this.nodeRevision,
    this.nodeStatus,
    this.recordId,
  });

  static const maxDescriptionLength = 160;
  static const maxDetailsLength = 2000;
  static const maxEvidenceCount = 8;
  static const _jsonKeys = {
    'sequence',
    'stage',
    'at',
    'description',
    'details',
    'evidence',
    'nodeId',
    'nodeRevision',
    'nodeStatus',
    'recordId',
  };

  final int sequence;
  final AgentTaskStage stage;
  final DateTime at;
  final String description;
  final String details;
  final List<AgentTaskEvidence> evidence;
  final String? nodeId, nodeStatus, recordId;
  final int? nodeRevision;

  bool get hasDetails => details.isNotEmpty || evidence.isNotEmpty;

  bool get isValid =>
      sequence > 0 &&
      ((nodeId == null && nodeRevision == null && nodeStatus == null) ||
          (nodeId != null &&
              RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,63}$').hasMatch(nodeId!) &&
              nodeRevision != null &&
              nodeRevision! > 0 &&
              nodeRevision! <= 9007199254740991 &&
              const {
                'queued',
                'running',
                'succeeded',
                'failed',
                'cancelled',
              }.contains(nodeStatus))) &&
      (recordId == null ||
          (recordId!.length <= 160 &&
              AgentTaskEvidence._referencePattern.hasMatch(recordId!))) &&
      _validPublicTaskText(description, maxDescriptionLength) &&
      _validPublicTaskText(details, maxDetailsLength, multiline: true) &&
      evidence.length <= maxEvidenceCount &&
      evidence.every((item) => item.isValid);

  Map<String, Object?> toJson() {
    if (!isValid) throw const FormatException('invalid_task_progress');
    return {
      'sequence': sequence,
      if (nodeId != null) ...{
        'nodeId': nodeId,
        'nodeRevision': nodeRevision,
        'nodeStatus': nodeStatus,
      },
      if (recordId != null) 'recordId': recordId,
      'stage': stage.name,
      'at': at.toUtc().toIso8601String(),
      if (description.isNotEmpty) 'description': description,
      if (details.isNotEmpty) 'details': details,
      if (evidence.isNotEmpty)
        'evidence': evidence.map((item) => item.toJson()).toList(),
    };
  }

  factory AgentTaskProgress.fromJson(Map<String, Object?> data) {
    if (data.keys.any((key) => !_jsonKeys.contains(key))) {
      throw const FormatException('unknown_task_progress_field');
    }
    if ((data.containsKey('description') && data['description'] is! String) ||
        (data.containsKey('details') && data['details'] is! String) ||
        (data.containsKey('evidence') && data['evidence'] is! List)) {
      throw const FormatException('invalid_task_progress_fields');
    }
    final rawEvidence = data['evidence'] as List? ?? const [];
    if (rawEvidence.length > maxEvidenceCount) {
      throw const FormatException('too_many_task_evidence');
    }
    final result = AgentTaskProgress(
      sequence: data['sequence'] as int,
      stage: AgentTaskStage.values.byName(data['stage'] as String),
      at: DateTime.parse(data['at'] as String),
      description: data['description'] as String? ?? '',
      details: data['details'] as String? ?? '',
      nodeId: data['nodeId'] as String?,
      nodeRevision: data['nodeRevision'] as int?,
      nodeStatus: data['nodeStatus'] as String?,
      recordId: data['recordId'] as String?,
      evidence: List.unmodifiable(
        rawEvidence.map(
          (raw) =>
              AgentTaskEvidence.fromJson(Map<String, Object?>.from(raw as Map)),
        ),
      ),
    );
    if (!result.isValid) throw const FormatException('invalid_task_progress');
    return result;
  }
}

bool _validPublicTaskText(
  String value,
  int maxLength, {
  bool multiline = false,
}) {
  if (value.length > maxLength) return false;
  for (final rune in value.runes) {
    if (multiline && (rune == 10 || rune == 13 || rune == 9)) continue;
    if (rune < 32 ||
        (rune >= 127 && rune <= 159) ||
        (rune >= 0xD800 && rune <= 0xDFFF) ||
        (rune >= 0x202A && rune <= 0x202E) ||
        (rune >= 0x2066 && rune <= 0x2069)) {
      return false;
    }
  }
  return true;
}

enum AgentTaskJobStatus {
  running,
  awaitingInput,
  cancelling,
  completed,
  failed,
  cancelled,
}

enum AgentTaskJobEventType {
  started,
  awaitingInput,
  resumed,
  cancelling,
  completed,
  failed,
  retried,
  cancelled,
  progress,
}

class AgentTaskJobEvent {
  const AgentTaskJobEvent({required this.type, required this.job});

  final AgentTaskJobEventType type;
  final AgentTaskJob job;
}

enum AgentTaskExecutionKind {
  local,
  creatorImage,
  projectBuild,
  projectBuildV2,
}

class AgentTaskJob {
  const AgentTaskJob({
    required this.id,
    required this.agentId,
    required this.taskKind,
    required this.userText,
    this.projectBrief = '',
    required this.status,
    required this.createdAt,
    this.updatedAt,
    this.summary = '',
    this.error = '',
    this.failureCode,
    this.pendingPrompt = '',
    this.appletScopeKey = '',
    this.attempt = 1,
    this.parentJobId,
    this.stage = AgentTaskStage.generating,
    this.progress = const [],
    this.surfaceId,
    this.widgetId,
    this.serverImage,
    this.referenceInput,
    this.projectBuild,
    this.projectBuildV2,
  }) : assert(
         (serverImage == null ||
                 (projectBuild == null && projectBuildV2 == null)) &&
             (projectBuild == null || projectBuildV2 == null),
       );

  final String id;
  final String agentId;
  final AgentTaskKind taskKind;
  final String userText;

  /// Confirmed project requirements, stored as data independently of the
  /// current human command used for routing and host task admission.
  final String projectBrief;
  final AgentTaskJobStatus status;
  final DateTime createdAt;
  final DateTime? updatedAt;
  final String summary;
  final String error;
  final String? failureCode;
  final String pendingPrompt;
  final String appletScopeKey;
  final int attempt;
  final String? parentJobId;
  String get taskId => parentJobId ?? id;
  final AgentTaskStage stage;
  final List<AgentTaskProgress> progress;
  final String? surfaceId;
  final int? widgetId;
  final CreatorImageTaskBinding? serverImage;
  final ProjectReferenceInputSnapshot? referenceInput;
  final ProjectBuildTaskBinding? projectBuild;
  final ProjectBuildV2TaskBinding? projectBuildV2;
  bool get isProjectBuildV2 => projectBuildV2 != null;
  bool get isCreatorImage => serverImage != null;
  bool get isProjectBuild => projectBuild != null;
  AgentTaskExecutionKind get executionKind => isCreatorImage
      ? AgentTaskExecutionKind.creatorImage
      : isProjectBuild
      ? AgentTaskExecutionKind.projectBuild
      : isProjectBuildV2
      ? AgentTaskExecutionKind.projectBuildV2
      : AgentTaskExecutionKind.local;
  bool get isServerBacked => executionKind != AgentTaskExecutionKind.local;

  /// State eligibility for an explicit retry, not ownership or authorization.
  bool get canRetryLocally =>
      !isServerBacked &&
      (status == AgentTaskJobStatus.failed ||
          (status == AgentTaskJobStatus.cancelled &&
              (taskKind == AgentTaskKind.gameGeneration ||
                  taskKind == AgentTaskKind.surfaceGeneration)));
  bool get isActive =>
      (projectBuildV2?.pendingCommand != null &&
          !(projectBuildV2?.syncIssue.startsWith('rejected:') ?? false)) ||
      (serverImage?.pendingCommand != null &&
          !(serverImage?.syncIssue.startsWith('rejected:') ?? false)) ||
      (projectBuild?.pendingCommand != null &&
          !(projectBuild?.syncIssue.startsWith('rejected:') ?? false)) ||
      status == AgentTaskJobStatus.running ||
      status == AgentTaskJobStatus.awaitingInput ||
      status == AgentTaskJobStatus.cancelling;

  AgentTaskJob copyWith({
    String? projectBrief,
    AgentTaskJobStatus? status,
    DateTime? updatedAt,
    String? summary,
    String? error,
    String? failureCode,
    String? pendingPrompt,
    int? attempt,
    String? parentJobId,
    AgentTaskStage? stage,
    List<AgentTaskProgress>? progress,
    String? surfaceId,
    int? widgetId,
    CreatorImageTaskBinding? serverImage,
    ProjectBuildTaskBinding? projectBuild,
    ProjectBuildV2TaskBinding? projectBuildV2,
  }) {
    return AgentTaskJob(
      id: id,
      agentId: agentId,
      taskKind: taskKind,
      userText: userText,
      projectBrief: projectBrief ?? this.projectBrief,
      status: status ?? this.status,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      summary: summary ?? this.summary,
      error: error ?? this.error,
      failureCode: (status ?? this.status) == AgentTaskJobStatus.failed
          ? failureCode ?? this.failureCode
          : null,
      pendingPrompt: pendingPrompt ?? this.pendingPrompt,
      appletScopeKey: appletScopeKey,
      attempt: attempt ?? this.attempt,
      parentJobId: parentJobId ?? this.parentJobId,
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      surfaceId: surfaceId ?? this.surfaceId,
      widgetId: widgetId ?? this.widgetId,
      serverImage: serverImage ?? this.serverImage,
      referenceInput: referenceInput,
      projectBuild: projectBuild ?? this.projectBuild,
      projectBuildV2: projectBuildV2 ?? this.projectBuildV2,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'agentId': agentId,
    'taskKind': taskKind.name,
    'userText': userText,
    if (projectBrief.isNotEmpty) 'projectBrief': projectBrief,
    'status': status.name,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'updatedAt': updatedAt?.toUtc().toIso8601String(),
    'summary': summary,
    'error': error,
    if (failureCode != null) 'failureCode': failureCode,
    'pendingPrompt': pendingPrompt,
    'appletScopeKey': appletScopeKey,
    'attempt': attempt,
    'parentJobId': parentJobId,
    'stage': stage.name,
    'progress': progress.map((event) => event.toJson()).toList(),
    'surfaceId': surfaceId,
    'widgetId': widgetId,
    'executionKind': executionKind.name,
    if (isServerBacked) 'executionLocation': 'server',
    if (serverImage != null) 'serverImage': serverImage!.toJson(),
    if (projectBuild != null) 'projectBuild': projectBuild!.toJson(),
    if (projectBuildV2 != null) 'projectBuildV2': projectBuildV2!.toJson(),
    if (referenceInput != null) 'referenceInput': referenceInput!.toJson(),
  };

  static AgentTaskJob? tryParse(Map<String, Object?> data) {
    try {
      if (data.containsKey('projectBrief') && data['projectBrief'] is! String) {
        return null;
      }
      final id = data['id'] as String;
      final parentId = data['parentJobId'] as String?;
      final scope = data['appletScopeKey'] as String;
      final agent = data['agentId'] as String;
      if (AgentTaskChatReference.tryParse({
            'taskId': parentId ?? id,
            'scopeKey': scope,
            'agentId': agent,
          }) ==
          null) {
        return null;
      }
      final attempt = data['attempt'] as int;
      if (attempt < 1) return null;
      final referenceInput = data['referenceInput'] == null
          ? null
          : ProjectReferenceInputSnapshot.fromJson(data['referenceInput']);
      if (referenceInput != null &&
          (referenceInput.scopeKey != scope ||
              !const {
                'gameGeneration',
                'surfaceGeneration',
              }.contains(data['taskKind']))) {
        return null;
      }
      final location = data['executionLocation'];
      final rawServer = data['serverImage'];
      final rawProject = data['projectBuild'];
      final rawProjectV2 = data['projectBuildV2'];
      final rawKind = data['executionKind'];
      final executionKind = rawKind == null
          ? rawServer is Map
                ? AgentTaskExecutionKind.creatorImage
                : AgentTaskExecutionKind.local
          : AgentTaskExecutionKind.values.byName(rawKind as String);
      if (location != null && location != 'local' && location != 'server') {
        return null;
      }
      if ((location == 'server') !=
              (executionKind != AgentTaskExecutionKind.local) ||
          (executionKind == AgentTaskExecutionKind.creatorImage) !=
              (rawServer is Map) ||
          (executionKind == AgentTaskExecutionKind.projectBuild) !=
              (rawProject is Map) ||
          (rawServer != null && rawServer is! Map) ||
          (rawProject != null && rawProject is! Map) ||
          (executionKind == AgentTaskExecutionKind.projectBuildV2) !=
              (rawProjectV2 is Map) ||
          (rawProjectV2 != null && rawProjectV2 is! Map)) {
        return null;
      }
      final server = rawServer is Map
          ? CreatorImageTaskBinding.fromJson(
              Map<String, Object?>.from(rawServer),
            )
          : null;
      final project = rawProject is Map
          ? ProjectBuildTaskBinding.fromJson(rawProject)
          : null;
      final projectV2 = rawProjectV2 is Map
          ? ProjectBuildV2TaskBinding.fromJson(rawProjectV2)
          : null;
      if (server != null &&
          (referenceInput != null ||
              data['widgetId'] != null ||
              data['surfaceId'] != null ||
              (server.snapshot != null &&
                  (server.snapshot!.agentId != agent ||
                      server.snapshot!.attempt != attempt)))) {
        return null;
      }
      if (project != null &&
          (referenceInput != null ||
              data['widgetId'] != null ||
              data['surfaceId'] != null ||
              !const {
                'gameGeneration',
                'surfaceGeneration',
              }.contains(data['taskKind']) ||
              (project.snapshot != null &&
                  (project.snapshot!.agentId != agent ||
                      project.snapshot!.attempt != attempt ||
                      (project.snapshot!.projectKind ==
                              ProjectBuildKind.game) !=
                          (data['taskKind'] == 'gameGeneration'))) ||
              (project.snapshot == null && attempt != 1))) {
        return null;
      }
      if (projectV2 != null &&
          (referenceInput != null ||
              data['widgetId'] != null ||
              data['surfaceId'] != null ||
              !const {
                'gameGeneration',
                'surfaceGeneration',
              }.contains(data['taskKind']) ||
              (projectV2.snapshot != null &&
                  (projectV2.snapshot!.agentId != agent ||
                      projectV2.snapshot!.attempt != attempt ||
                      (projectV2.snapshot!.projectKind ==
                              ProjectBuildKind.game) !=
                          (data['taskKind'] == 'gameGeneration'))) ||
              (projectV2.snapshot == null &&
                  !projectV2.isLegacyReadOnly &&
                  attempt != 1))) {
        return null;
      }
      final progress = <AgentTaskProgress>[];
      for (final raw in data['progress'] as List? ?? const []) {
        final event = AgentTaskProgress.fromJson(
          Map<String, Object?>.from(raw as Map),
        );
        if (event.sequence != progress.length + 1) return null;
        progress.add(event);
      }
      return AgentTaskJob(
        id: id,
        agentId: agent,
        taskKind: AgentTaskKind.values.byName(data['taskKind'] as String),
        userText: data['userText'] as String,
        projectBrief: data['projectBrief'] as String? ?? '',
        status: AgentTaskJobStatus.values.byName(data['status'] as String),
        createdAt: DateTime.parse(data['createdAt'] as String),
        updatedAt: DateTime.tryParse(data['updatedAt'] as String? ?? ''),
        summary: data['summary'] as String? ?? '',
        error: data['error'] as String? ?? '',
        failureCode: data['status'] == 'failed'
            ? GeneratedTaskFailureCode.fromWireName(
                data['failureCode'] is String
                    ? data['failureCode'] as String
                    : null,
              )?.name
            : null,
        pendingPrompt: data['pendingPrompt'] as String? ?? '',
        appletScopeKey: scope,
        attempt: attempt,
        parentJobId: parentId,
        stage: AgentTaskStage.values.byName(
          data['stage'] as String? ?? 'generating',
        ),
        progress: List.unmodifiable(progress),
        surfaceId: data['surfaceId'] as String?,
        widgetId: data['widgetId'] as int?,
        serverImage: server,
        referenceInput: referenceInput,
        projectBuild: project,
        projectBuildV2: projectV2,
      );
    } catch (_) {
      return null;
    }
  }
}

abstract interface class AgentServerTaskControls {
  bool canControl(AgentTaskJob job, {required bool retry});
  Future<bool> cancel(String jobId, {required int expectedAttempt});
  Future<bool> retry(String jobId, {required int expectedAttempt});
}

class AgentTaskJobStore extends AppService {
  AgentTaskJobStore({
    AgentTaskPersistence? persistence,
    this.requirePreviewAcceptance = false,
  }) : _persistence = persistence;
  final AgentTaskPersistence? _persistence;
  final bool requirePreviewAcceptance;
  final Map<String, Completer<bool>> _previewRequests = {};
  Future<void> _pendingWrites = Future<void>.value();
  final Set<String> _deletedProjectV2Requests = {};
  final Map<String, Set<String>> _deletedLocalTaskIds = {};
  bool isTaskDeleted(String taskId, {required String expectedScopeKey}) =>
      _deletedLocalTaskIds[expectedScopeKey]?.contains(taskId) ?? false;
  String _v2RequestKey(String scope, String request) =>
      jsonEncode([scope, request]);
  Object? _persistenceError;
  bool _sealed = false;
  AgentServerTaskControls? serverControls;
  final Map<AgentTaskExecutionKind, AgentServerTaskControls>
  _executionControls = {};

  void registerControls(
    AgentTaskExecutionKind kind,
    AgentServerTaskControls controls,
  ) {
    if (_sealed || kind == AgentTaskExecutionKind.local) {
      throw StateError('invalid_task_controls');
    }
    final previous = kind == AgentTaskExecutionKind.creatorImage
        ? serverControls
        : _executionControls[kind];
    if (previous != null && !identical(previous, controls)) {
      throw StateError('task_controls_already_registered');
    }
    if (kind == AgentTaskExecutionKind.creatorImage) {
      serverControls = controls;
    } else {
      _executionControls[kind] = controls;
    }
  }

  void unregisterControls(
    AgentTaskExecutionKind kind,
    AgentServerTaskControls controls,
  ) {
    if (kind == AgentTaskExecutionKind.creatorImage) {
      if (identical(serverControls, controls)) serverControls = null;
    } else if (identical(_executionControls[kind], controls)) {
      _executionControls.remove(kind);
    }
  }

  AgentServerTaskControls? controlsFor(AgentTaskJob job) => _sealed
      ? null
      : job.isCreatorImage
      ? serverControls
      : _executionControls[job.executionKind];
  final RxList<AgentTaskJob> jobs = <AgentTaskJob>[].obs;
  final StreamController<AgentTaskJobEvent> _events =
      StreamController<AgentTaskJobEvent>.broadcast(sync: true);

  int _sequence = 0;

  Stream<AgentTaskJobEvent> get events => _events.stream;

  Future<AgentTaskJobStore> init() async {
    final persistence = _persistence;
    if (persistence is AgentTaskProjectDeletionPersistence) {
      final stored = await (persistence as AgentTaskProjectDeletionPersistence)
          .readDeletedLocalTaskIds();
      for (final entry in stored.entries) {
        _deletedLocalTaskIds[entry.key] = {...entry.value};
      }
    }
    final rows =
        await _persistence?.readJobs() ?? const <Map<String, Object?>>[];
    final restored =
        rows
            .map(AgentTaskJob.tryParse)
            .whereType<AgentTaskJob>()
            .where(
              (job) => !isTaskDeleted(
                job.taskId,
                expectedScopeKey: job.appletScopeKey,
              ),
            )
            .map(
              (job) => job.isCreatorImage
                  ? _serverProjection(job)
                  : job.isProjectBuild
                  ? _projectBuildProjection(job)
                  : job.isProjectBuildV2
                  ? _projectBuildV2Projection(job)
                  : job,
            )
            .toList()
          ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    jobs.assignAll(restored);
    for (final job in restored.where((job) => !job.isActive)) {
      _persist(job);
    }
    for (final job in restored.where(
      (job) => job.isActive && job.isServerBacked,
    )) {
      final recovering = job.copyWith(
        stage: AgentTaskStage.synchronizing,
        serverImage: job.serverImage?.copyWith(syncIssue: 'resuming'),
        projectBuild: job.projectBuild?.copyWith(syncIssue: 'resuming'),
        projectBuildV2: job.projectBuildV2?.copyWith(syncIssue: 'resuming'),
      );
      jobs[jobs.indexWhere((row) => row.id == job.id)] = recovering;
      _persist(recovering);
    }
    for (final job in restored.where(
      (job) => job.isActive && !job.isServerBacked,
    )) {
      final recovered = job.copyWith(
        status: AgentTaskJobStatus.failed,
        stage: AgentTaskStage.interrupted,
        updatedAt: DateTime.now(),
        error: 'local_process_interrupted',
        failureCode: GeneratedTaskFailureCode.interrupted.name,
        pendingPrompt: '',
      );
      final next = _withProgress(recovered, AgentTaskStage.interrupted);
      jobs[jobs.indexWhere((row) => row.id == job.id)] = next;
      _persist(next);
    }
    await flush();
    return this;
  }

  Future<Set<String>> purgeProjectBuildV2(
    ProjectBuildV2DeletionProof proof, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  }) async {
    if (_sealed ||
        proof.scopeKey != expectedRepositoryScopeKey ||
        !proof.isScopeCurrent) {
      throw StateError('project_build_scope_changed');
    }
    final persistence = _persistence;
    if (persistence is! AgentTaskProjectDeletionPersistence) {
      throw StateError('project_delete_atomic_persistence_required');
    }
    bool matches(AgentTaskJob job) {
      final b = job.projectBuildV2;
      if (b == null ||
          job.appletScopeKey != expectedScopeKey ||
          b.scopeKey != expectedRepositoryScopeKey) {
        return false;
      }
      final snapshot = b.toJson()['snapshot'];
      return proof.taskIds.contains(b.taskId) ||
          proof.createRequestIds.contains(b.createRequestId) ||
          (snapshot is Map && snapshot['projectId'] == proof.projectId);
    }

    final removed = jobs.where(matches).toList();
    (_deletedLocalTaskIds[expectedScopeKey] ??= {}).addAll(
      removed.map((j) => j.taskId),
    );
    for (final job in removed) {
      _deletedProjectV2Requests.add(
        _v2RequestKey(
          expectedRepositoryScopeKey,
          job.projectBuildV2!.createRequestId,
        ),
      );
    }
    for (final request in proof.createRequestIds) {
      _deletedProjectV2Requests.add(
        _v2RequestKey(expectedRepositoryScopeKey, request),
      );
    }
    await flush();
    final roots = await (persistence as AgentTaskProjectDeletionPersistence)
        .purgeProjectBuildV2(
          proof,
          expectedScopeKey: expectedScopeKey,
          expectedRepositoryScopeKey: expectedRepositoryScopeKey,
        );
    (_deletedLocalTaskIds[expectedScopeKey] ??= {}).addAll(roots);
    jobs.removeWhere(matches);
    return Set.unmodifiable({...roots, ...removed.map((job) => job.taskId)});
  }

  Future<void> flush() async {
    await _pendingWrites;
    final error = _persistenceError;
    if (error != null) {
      throw StateError('task_persistence_failed: ${error.runtimeType}');
    }
  }

  Future<bool> awaitPreview(String id) {
    if (_sealed) return Future.value(false);
    final existing = _previewRequests[id];
    if (existing != null) return existing.future;
    final job = byId(id);
    if (job == null || job.status != AgentTaskJobStatus.running) {
      return Future.value(false);
    }
    if (job.isServerBacked) return Future.value(false);
    final request = Completer<bool>();
    _previewRequests[id] = request;
    awaitInput(id, 'home.task.preview_ready_message'.tr);
    updateStage(id, AgentTaskStage.previewReady);
    return request.future.whenComplete(() => _previewRequests.remove(id));
  }

  bool acceptPreview(String id, {required int expectedAttempt}) {
    final job = byId(id);
    final request = _previewRequests[id];
    if (_sealed ||
        job == null ||
        job.isServerBacked ||
        job.attempt != expectedAttempt ||
        !isCurrentAttempt(job) ||
        job.status != AgentTaskJobStatus.awaitingInput ||
        job.stage != AgentTaskStage.previewReady ||
        request == null ||
        request.isCompleted) {
      return false;
    }
    resume(id);
    request.complete(true);
    return true;
  }

  Future<void> deactivateAndDrain() async {
    _sealed = true;
    serverControls = null;
    _executionControls.clear();
    _closePreviewRequests();
    await flush();
  }

  AgentTaskJob? latestForTask(
    String taskId, {
    required String appletScopeKey,
    required String agentId,
  }) {
    AgentTaskJob? latest;
    for (final job in jobs.reversed) {
      if (job.taskId == taskId &&
          job.appletScopeKey == appletScopeKey &&
          job.agentId == agentId) {
        if (latest == null || job.attempt > latest.attempt) latest = job;
      }
    }
    return latest;
  }

  bool isCurrentAttempt(AgentTaskJob job) =>
      latestForTask(
        job.taskId,
        appletScopeKey: job.appletScopeKey,
        agentId: job.agentId,
      )?.id ==
      job.id;

  AgentTaskJob updateStage(
    String id,
    AgentTaskStage stage, {
    String? surfaceId,
    int? widgetId,
  }) {
    final current = byId(id);
    if (current == null) throw StateError('unknown task job $id');
    if (_sealed ||
        current.isServerBacked ||
        !current.isActive ||
        (current.stage == stage && surfaceId == null)) {
      return current;
    }
    final next = _withProgress(
      current.copyWith(
        updatedAt: DateTime.now(),
        surfaceId: surfaceId,
        widgetId: widgetId,
      ),
      stage,
    );
    jobs[jobs.indexWhere((job) => job.id == id)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  /// Records one actual, public execution checkpoint. The caller owns the
  /// evidence: no model-authored progress or raw tool output belongs here.
  /// Lifecycle completion and presentation receipts keep their existing paths.
  AgentTaskJob recordProgress(
    String id, {
    required int expectedAttempt,
    required AgentTaskStage stage,
    required String description,
    String details = '',
    List<AgentTaskEvidence> evidence = const [],
  }) {
    final current = byId(id);
    if (current == null) throw StateError('unknown task job $id');
    if (_sealed ||
        current.isServerBacked ||
        current.status != AgentTaskJobStatus.running ||
        current.attempt != expectedAttempt ||
        !isCurrentAttempt(current)) {
      return current;
    }
    final now = DateTime.now();
    final event = AgentTaskProgress(
      sequence: current.progress.length + 1,
      stage: stage,
      at: now,
      description: description,
      details: details,
      evidence: List.unmodifiable(evidence),
    );
    if (!const {
          AgentTaskStage.generating,
          AgentTaskStage.validating,
          AgentTaskStage.saving,
        }.contains(stage) ||
        description.trim().isEmpty ||
        !event.isValid) {
      throw ArgumentError('invalid_public_task_progress');
    }
    if (current.progress.isNotEmpty) {
      final previous = current.progress.last;
      if (previous.stage == event.stage &&
          previous.description == event.description &&
          previous.details == event.details &&
          jsonEncode(previous.evidence.map((item) => item.toJson()).toList()) ==
              jsonEncode(
                event.evidence.map((item) => item.toJson()).toList(),
              )) {
        return current;
      }
    }
    final next = current.copyWith(
      stage: stage,
      updatedAt: now,
      progress: List.unmodifiable([...current.progress, event]),
    );
    jobs[jobs.indexWhere((job) => job.id == id)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  AgentTaskJob start({
    required String agentId,
    required AgentTaskKind taskKind,
    required String userText,
    String projectBrief = '',
    String appletScopeKey = '',
    int attempt = 1,
    String? parentJobId,
    ProjectReferenceInputSnapshot? referenceInput,
  }) {
    if (_sealed) throw StateError('task_store_sealed');
    if (referenceInput != null &&
        (referenceInput.scopeKey != appletScopeKey.trim() ||
            !const {
              AgentTaskKind.gameGeneration,
              AgentTaskKind.surfaceGeneration,
            }.contains(taskKind))) {
      throw const FormatException('project_reference_task_scope_mismatch');
    }
    final now = DateTime.now();
    final job = AgentTaskJob(
      id: 'job_${now.microsecondsSinceEpoch}_${_sequence++}',
      agentId: agentId,
      taskKind: taskKind,
      userText: userText,
      projectBrief: projectBrief,
      status: AgentTaskJobStatus.running,
      createdAt: now,
      appletScopeKey: appletScopeKey.trim(),
      attempt: attempt,
      parentJobId: parentJobId,
      referenceInput: referenceInput,
      progress: [
        AgentTaskProgress(
          sequence: 1,
          stage: AgentTaskStage.generating,
          at: now,
        ),
      ],
    );
    jobs.add(job);
    _emit(AgentTaskJobEventType.started, job);
    return job;
  }

  AgentTaskJob startProjectBuild({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required ProjectBuildKind projectKind,
    required ProjectBuildTaskBinding binding,
  }) {
    if (binding.taskId != null ||
        binding.snapshot != null ||
        binding.pendingCommand?.operation != ProjectBuildTaskOperation.create) {
      throw StateError('project_build_task_requires_new_intent');
    }
    return _createProjectBuildJob(
      agentId: agentId,
      userText: userText,
      appletScopeKey: appletScopeKey,
      projectKind: projectKind,
      binding: binding,
      createdAt: DateTime.now(),
      restoring: false,
    );
  }

  /// Rebuilds a missing list row without treating repository head/receipt as
  /// replayed history. Restore an empty binding, then replay the durable journal.
  AgentTaskJob restoreProjectBuild({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required ProjectBuildKind projectKind,
    required ProjectBuildTaskBinding binding,
    required DateTime createdAt,
  }) {
    if (binding.snapshot != null) {
      throw StateError('project_build_task_requires_replay');
    }
    return _createProjectBuildJob(
      agentId: agentId,
      userText: userText,
      appletScopeKey: appletScopeKey,
      projectKind: projectKind,
      binding: binding,
      createdAt: createdAt,
      restoring: true,
    );
  }

  AgentTaskJob _createProjectBuildJob({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required ProjectBuildKind projectKind,
    required ProjectBuildTaskBinding binding,
    required DateTime createdAt,
    required bool restoring,
  }) {
    if (_sealed || _persistenceError != null) {
      throw StateError('task_store_unavailable');
    }
    ProjectBuildTaskBinding.fromJson(binding.toJson());
    final kind = projectKind == ProjectBuildKind.game
        ? AgentTaskKind.gameGeneration
        : AgentTaskKind.surfaceGeneration;
    for (final existing in jobs) {
      final known = existing.projectBuild;
      if (known?.scopeKey == binding.scopeKey &&
          known?.createRequestId == binding.createRequestId) {
        if (existing.agentId != agentId ||
            existing.appletScopeKey != appletScopeKey ||
            existing.userText != userText ||
            existing.taskKind != kind) {
          throw StateError('project_build_task_identity_conflict');
        }
        return byId(existing.taskId) ??
            (throw StateError('project_build_task_root_missing'));
      }
    }
    final now = DateTime.now();
    final job = AgentTaskJob(
      id: 'job_${now.microsecondsSinceEpoch}_${_sequence++}',
      agentId: agentId,
      taskKind: kind,
      userText: userText,
      status: AgentTaskJobStatus.running,
      createdAt: createdAt,
      appletScopeKey: appletScopeKey,
      projectBuild: binding,
      stage: restoring
          ? AgentTaskStage.synchronizing
          : AgentTaskStage.submitting,
      progress: restoring
          ? const []
          : List.unmodifiable([
              AgentTaskProgress(
                sequence: 1,
                stage: AgentTaskStage.submitting,
                at: now,
              ),
            ]),
    );
    if (AgentTaskJob.tryParse(job.toJson()) == null) {
      throw StateError('project_build_task_invalid');
    }
    jobs.add(job);
    _emit(AgentTaskJobEventType.started, job);
    return job;
  }

  /// Checkpoints transport state only. Snapshot/cursor advancement is exclusive
  /// to applyProjectBuildEvent after the repository journal transaction.
  AgentTaskJob updateProjectBuildBinding(
    String jobId,
    ProjectBuildTaskBinding binding, {
    required String expectedScopeKey,
  }) {
    final current = byId(jobId);
    if (_sealed ||
        _persistenceError != null ||
        current == null ||
        !current.isProjectBuild ||
        current.appletScopeKey != expectedScopeKey ||
        !isCurrentAttempt(current)) {
      throw StateError('project_build_task_scope_changed');
    }
    ProjectBuildTaskBinding.fromJson(binding.toJson());
    final previous = current.projectBuild!;
    if (previous.scopeKey != binding.scopeKey ||
        previous.createRequestId != binding.createRequestId ||
        (previous.taskId != null && previous.taskId != binding.taskId) ||
        ((previous.snapshot == null) != (binding.snapshot == null)) ||
        (previous.snapshot != null &&
            !previous.snapshot!.sameState(binding.snapshot!))) {
      throw StateError('project_build_task_checkpoint_conflict');
    }
    final oldPending = previous.pendingCommand;
    final pending = binding.pendingCommand;
    if (oldPending != null &&
        pending != null &&
        (!oldPending.sameCommand(pending) ||
            (oldPending.acceptedTaskSequence != null &&
                oldPending.acceptedTaskSequence !=
                    pending.acceptedTaskSequence))) {
      throw StateError('project_build_task_pending_conflict');
    }
    if (oldPending != null &&
        pending == null &&
        !binding.syncIssue.startsWith('rejected:') &&
        (oldPending.acceptedTaskSequence == null ||
            oldPending.acceptedTaskSequence! > previous.appliedTaskSequence)) {
      throw StateError('project_build_task_pending_unreconciled');
    }
    if (oldPending == null && pending != null) {
      final known = previous.snapshot;
      if (pending.operation == ProjectBuildTaskOperation.create) {
        // A restored card may precede its durable unacknowledged intent.
        // Rebind only the original create nonce, never invent a new request.
        if (known != null ||
            previous.taskId != null ||
            pending.requestId != previous.createRequestId) {
          throw StateError('project_build_task_command_conflict');
        }
      } else if (known == null ||
          known.runId != pending.expectedRunId ||
          known.statusVersion != pending.expectedStatusVersion ||
          (pending.operation == ProjectBuildTaskOperation.retry
              ? !known.isTerminal
              : !{
                  ProjectBuildStatus.queued,
                  ProjectBuildStatus.running,
                }.contains(known.status))) {
        throw StateError('project_build_task_command_conflict');
      }
    }
    if (jsonEncode(previous.toJson()) == jsonEncode(binding.toJson())) {
      return current;
    }
    final next = _projectBuildProjection(
      current.copyWith(projectBuild: binding),
    );
    jobs[jobs.indexWhere((job) => job.id == current.id)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  /// Repairs only missing audit metadata from the original account repository
  /// body. It neither grants editing permission nor rewrites a command/head.
  AgentTaskJob restoreProjectBuildV2EditIdentity(
    String jobId,
    ProjectBuildV2DurableCreate proof, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  }) {
    final current = byId(jobId);
    if (_sealed ||
        _persistenceError != null ||
        current == null ||
        !current.isProjectBuildV2 ||
        current.appletScopeKey != expectedScopeKey ||
        !isCurrentAttempt(current) ||
        !proof.isScopeCurrent ||
        proof.scopeKey != expectedRepositoryScopeKey ||
        current.projectBuildV2!.scopeKey != expectedRepositoryScopeKey) {
      throw StateError('project_build_task_scope_changed');
    }
    final binding = current.projectBuildV2!, input = proof.input;
    if (binding.isLegacyReadOnly ||
        input.requestId != binding.createRequestId ||
        input.agentId != current.agentId ||
        input.requirements != current.userText ||
        (input.projectKind == ProjectBuildKind.game) !=
            (current.taskKind == AgentTaskKind.gameGeneration)) {
      throw StateError('project_build_task_identity_conflict');
    }
    final identity = ProjectBuildEditIdentity.fromCreate(input);
    if (binding.editIdentity == identity) return current;
    if (binding.editIdentity != null || identity == null) {
      throw StateError('project_build_task_identity_conflict');
    }
    final next = _projectBuildV2Projection(
      current.copyWith(
        projectBuildV2: binding.copyWith(editIdentity: identity),
      ),
    );
    jobs[jobs.indexWhere((job) => job.id == jobId)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  /// Reattaches an already durable repository intent after a projection race
  /// or restart. Its original CAS version/nonce must be replayed, even when the
  /// server journal has since advanced. New requests still use strict admission.
  AgentTaskJob restoreProjectBuildPendingCommand(
    String jobId,
    ProjectBuildPendingRequest request, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  }) {
    final current = byId(jobId);
    if (_sealed ||
        _persistenceError != null ||
        current == null ||
        !current.isProjectBuild ||
        current.appletScopeKey != expectedScopeKey ||
        !isCurrentAttempt(current) ||
        request.scopeKey != expectedRepositoryScopeKey ||
        current.projectBuild!.scopeKey != expectedRepositoryScopeKey) {
      throw StateError('project_build_task_scope_changed');
    }
    final binding = current.projectBuild!;
    final create = request.create;
    late ProjectBuildTaskPendingCommand pending;
    if (create != null) {
      if (create.requestId != binding.createRequestId ||
          create.agentId != current.agentId ||
          create.requirements != current.userText ||
          (create.projectKind == ProjectBuildKind.game) !=
              (current.taskKind == AgentTaskKind.gameGeneration)) {
        throw StateError('project_build_task_pending_identity');
      }
      pending = ProjectBuildTaskPendingCommand(
        operation: ProjectBuildTaskOperation.create,
        requestId: create.requestId,
      );
    } else {
      final command = request.command;
      if (command == null || request.taskId != binding.taskId) {
        throw StateError('project_build_task_pending_identity');
      }
      pending = ProjectBuildTaskPendingCommand(
        operation: command.operation == ProjectBuildOperation.cancel
            ? ProjectBuildTaskOperation.cancel
            : ProjectBuildTaskOperation.retry,
        requestId: command.requestId,
        expectedRunId: command.expectedRunId,
        expectedStatusVersion: command.expectedStatusVersion,
      );
    }
    final previous = binding.pendingCommand;
    if (previous != null) {
      if (!previous.sameCommand(pending)) {
        throw StateError('project_build_task_pending_conflict');
      }
      pending = pending.copyWith(
        acceptedTaskSequence: previous.acceptedTaskSequence,
      );
    }
    final nextBinding = binding.copyWith(pendingCommand: pending);
    if (jsonEncode(nextBinding.toJson()) == jsonEncode(binding.toJson())) {
      return current;
    }
    final next = _projectBuildProjection(
      current.copyWith(projectBuild: nextBinding),
    );
    jobs[jobs.indexWhere((job) => job.id == jobId)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  AgentTaskJob applyProjectBuildEvent(
    String localRootId,
    ProjectBuildEvent event, {
    required String expectedScopeKey,
    required String agentId,
  }) {
    ProjectBuildEvent.fromJson(event.toJson());
    final previous = latestForTask(
      localRootId,
      appletScopeKey: expectedScopeKey,
      agentId: agentId,
    );
    if (_sealed ||
        _persistenceError != null ||
        previous == null ||
        !previous.isProjectBuild ||
        event.snapshot.agentId != agentId ||
        (event.snapshot.projectKind == ProjectBuildKind.game) !=
            (previous.taskKind == AgentTaskKind.gameGeneration)) {
      throw StateError('project_build_task_scope_changed');
    }
    final binding = previous.projectBuild!;
    if (binding.taskId != event.taskId) {
      throw StateError('project_build_task_event_identity');
    }
    final fingerprint =
        'pbe-${event.taskSequence}-${sha256.convert(utf8.encode(jsonEncode(event.toJson())))}';
    if (event.taskSequence <= binding.appliedTaskSequence) {
      final recorded = jobs
          .where(
            (job) =>
                job.taskId == localRootId &&
                job.agentId == agentId &&
                job.appletScopeKey == expectedScopeKey &&
                job.projectBuild?.createRequestId == binding.createRequestId &&
                job.projectBuild?.scopeKey == binding.scopeKey,
          )
          .expand((job) => job.progress)
          .expand((progress) => progress.evidence)
          .where((evidence) => evidence.reference == fingerprint);
      if (recorded.isEmpty) {
        throw StateError('project_build_task_event_conflict');
      }
      return previous;
    }
    final nextBinding = binding.applyEvent(event);
    final newAttempt = event.snapshot.attempt > previous.attempt;
    final persistence = _persistence;
    if (newAttempt &&
        persistence != null &&
        persistence is! AgentTaskAttemptPersistence) {
      throw StateError('server_attempt_atomic_persistence_required');
    }
    var next = newAttempt
        ? AgentTaskJob(
            id: 'job_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
            agentId: agentId,
            taskKind: previous.taskKind,
            userText: previous.userText,
            projectBrief: previous.projectBrief,
            status: AgentTaskJobStatus.running,
            createdAt: event.at.toLocal(),
            appletScopeKey: expectedScopeKey,
            attempt: event.snapshot.attempt,
            parentJobId: previous.taskId,
            projectBuild: nextBinding,
          )
        : previous.copyWith(projectBuild: nextBinding);
    next = _projectBuildProjection(next);
    final stage = _projectBuildStage(event.snapshot.status);
    final description =
        'project_build.task.event.${event.type.replaceAll('.', '_')}'.tr;
    next = next.copyWith(
      progress: List.unmodifiable([
        ...next.progress,
        AgentTaskProgress(
          sequence: next.progress.length + 1,
          stage: stage,
          at: event.at,
          description: description,
          evidence: List.unmodifiable([
            AgentTaskEvidence(
              kind: AgentTaskEvidenceKind.execution,
              outcome: event.snapshot.status == ProjectBuildStatus.failed
                  ? AgentTaskEvidenceOutcome.failed
                  : AgentTaskEvidenceOutcome.completed,
              label: description,
              reference: fingerprint,
            ),
          ]),
        ),
      ]),
    );
    if (newAttempt) {
      final retired = _projectBuildProjection(
        previous.copyWith(
          projectBuild: binding.copyWith(clearPending: true, syncIssue: ''),
        ),
      );
      jobs[jobs.indexWhere((job) => job.id == previous.id)] = retired;
      jobs.add(next);
      if (persistence is AgentTaskAttemptPersistence) {
        final retiredJson = retired.toJson();
        final nextJson = next.toJson();
        final card = cardFor(next);
        _pendingWrites = _pendingWrites.then((_) async {
          if (_persistenceError != null) return;
          try {
            await (persistence as AgentTaskAttemptPersistence)
                .writeServerAttempt(
                  retired: retiredJson,
                  next: nextJson,
                  card: card,
                );
          } catch (error) {
            _persistenceError ??= error;
          }
        });
      }
      if (!_events.isClosed) {
        _events.add(
          AgentTaskJobEvent(type: AgentTaskJobEventType.retried, job: next),
        );
      }
    } else {
      jobs[jobs.indexWhere((job) => job.id == previous.id)] = next;
      _emit(AgentTaskJobEventType.progress, next);
    }
    return next;
  }

  AgentTaskStage _projectBuildStage(ProjectBuildStatus status) =>
      switch (status) {
        ProjectBuildStatus.queued => AgentTaskStage.queued,
        ProjectBuildStatus.running => AgentTaskStage.generating,
        ProjectBuildStatus.cancelling => AgentTaskStage.cancelling,
        ProjectBuildStatus.cancelled => AgentTaskStage.cancelled,
        ProjectBuildStatus.failed => AgentTaskStage.failed,
      };

  AgentTaskJob _projectBuildProjection(AgentTaskJob job) {
    final binding = job.projectBuild!;
    final snapshot = binding.snapshot;
    var status = switch (snapshot?.status) {
      ProjectBuildStatus.failed => AgentTaskJobStatus.failed,
      ProjectBuildStatus.cancelled => AgentTaskJobStatus.cancelled,
      ProjectBuildStatus.cancelling => AgentTaskJobStatus.cancelling,
      _ => AgentTaskJobStatus.running,
    };
    var stage = snapshot == null
        ? binding.taskId == null
              ? AgentTaskStage.submitting
              : AgentTaskStage.synchronizing
        : _projectBuildStage(snapshot.status);
    if (snapshot == null && binding.syncIssue.startsWith('rejected:')) {
      status = AgentTaskJobStatus.failed;
      stage = AgentTaskStage.failed;
    } else if (binding.pendingCommand?.operation ==
            ProjectBuildTaskOperation.cancel &&
        snapshot?.isTerminal != true) {
      status = AgentTaskJobStatus.cancelling;
      stage = AgentTaskStage.cancelling;
    } else if ((binding.syncIssue.isNotEmpty && snapshot?.isTerminal != true) ||
        binding.pendingCommand?.operation == ProjectBuildTaskOperation.retry) {
      stage = AgentTaskStage.synchronizing;
    }
    return job.copyWith(
      status: status,
      stage: stage,
      updatedAt: snapshot?.updatedAt.toLocal() ?? job.updatedAt,
      error: snapshot?.errorCode ?? '',
      pendingPrompt: '',
      summary: '',
    );
  }

  AgentTaskJob startProjectBuildV2({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required ProjectBuildKind projectKind,
    required ProjectBuildV2TaskBinding binding,
  }) {
    if (binding.taskId != null ||
        binding.snapshot != null ||
        binding.pendingCommand?.operation !=
            ProjectBuildV2TaskOperation.create) {
      throw StateError('project_build_task_requires_new_intent');
    }
    return _createProjectBuildV2Job(
      agentId: agentId,
      userText: userText,
      appletScopeKey: appletScopeKey,
      projectKind: projectKind,
      binding: binding,
      createdAt: DateTime.now(),
      restoring: false,
    );
  }

  /// Rebuilds a missing list row without treating repository head/receipt as
  /// replayed history. Restore an empty binding, then replay the durable journal.
  AgentTaskJob restoreProjectBuildV2({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required ProjectBuildKind projectKind,
    required ProjectBuildV2TaskBinding binding,
    required DateTime createdAt,
  }) {
    if (binding.snapshot != null) {
      throw StateError('project_build_task_requires_replay');
    }
    return _createProjectBuildV2Job(
      agentId: agentId,
      userText: userText,
      appletScopeKey: appletScopeKey,
      projectKind: projectKind,
      binding: binding,
      createdAt: createdAt,
      restoring: true,
    );
  }

  AgentTaskJob _createProjectBuildV2Job({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required ProjectBuildKind projectKind,
    required ProjectBuildV2TaskBinding binding,
    required DateTime createdAt,
    required bool restoring,
  }) {
    if (_sealed || _persistenceError != null) {
      throw StateError('task_store_unavailable');
    }
    if (_deletedProjectV2Requests.contains(
      _v2RequestKey(binding.scopeKey, binding.createRequestId),
    )) {
      throw StateError('project_build_project_deleted');
    }
    ProjectBuildV2TaskBinding.fromJson(binding.toJson());
    final kind = projectKind == ProjectBuildKind.game
        ? AgentTaskKind.gameGeneration
        : AgentTaskKind.surfaceGeneration;
    for (final existing in jobs) {
      final known = existing.projectBuildV2;
      if (known?.scopeKey == binding.scopeKey &&
          known?.createRequestId == binding.createRequestId) {
        if (existing.agentId != agentId ||
            existing.appletScopeKey != appletScopeKey ||
            existing.userText != userText ||
            existing.taskKind != kind ||
            known?.referenceSelectionDigest !=
                binding.referenceSelectionDigest ||
            known?.editIdentity != binding.editIdentity) {
          throw StateError('project_build_task_identity_conflict');
        }
        return byId(existing.taskId) ??
            (throw StateError('project_build_task_root_missing'));
      }
    }
    final now = DateTime.now();
    final job = AgentTaskJob(
      id: 'job_${now.microsecondsSinceEpoch}_${_sequence++}',
      agentId: agentId,
      taskKind: kind,
      userText: userText,
      status: AgentTaskJobStatus.running,
      createdAt: createdAt,
      appletScopeKey: appletScopeKey,
      projectBuildV2: binding,
      stage: restoring
          ? AgentTaskStage.synchronizing
          : AgentTaskStage.submitting,
      progress: restoring
          ? const []
          : List.unmodifiable([
              AgentTaskProgress(
                sequence: 1,
                stage: AgentTaskStage.submitting,
                at: now,
              ),
            ]),
    );
    if (AgentTaskJob.tryParse(job.toJson()) == null) {
      throw StateError('project_build_task_invalid');
    }
    jobs.add(job);
    _emit(AgentTaskJobEventType.started, job);
    return job;
  }

  /// Checkpoints transport state only. Snapshot/cursor advancement is exclusive
  /// to applyProjectBuildV2Event after the repository journal transaction.
  AgentTaskJob updateProjectBuildV2Binding(
    String jobId,
    ProjectBuildV2TaskBinding binding, {
    required String expectedScopeKey,
  }) {
    final current = byId(jobId);
    if (_sealed ||
        _persistenceError != null ||
        current == null ||
        !current.isProjectBuildV2 ||
        current.appletScopeKey != expectedScopeKey ||
        !isCurrentAttempt(current)) {
      throw StateError('project_build_task_scope_changed');
    }
    ProjectBuildV2TaskBinding.fromJson(binding.toJson());
    final previous = current.projectBuildV2!;
    if (previous.lastNodeId != binding.lastNodeId ||
        jsonEncode(previous.nodes.map((node) => node.toJson()).toList()) !=
            jsonEncode(binding.nodes.map((node) => node.toJson()).toList()) ||
        previous.scopeKey != binding.scopeKey ||
        previous.createRequestId != binding.createRequestId ||
        previous.referenceSelectionDigest != binding.referenceSelectionDigest ||
        previous.editIdentity != binding.editIdentity ||
        (previous.taskId != null && previous.taskId != binding.taskId) ||
        ((previous.snapshot == null) != (binding.snapshot == null)) ||
        (previous.snapshot != null &&
            !previous.snapshot!.sameState(binding.snapshot!))) {
      throw StateError('project_build_task_checkpoint_conflict');
    }
    final oldPending = previous.pendingCommand;
    final pending = binding.pendingCommand;
    if (oldPending != null &&
        pending != null &&
        (!oldPending.sameCommand(pending) ||
            (oldPending.acceptedTaskSequence != null &&
                oldPending.acceptedTaskSequence !=
                    pending.acceptedTaskSequence))) {
      throw StateError('project_build_task_pending_conflict');
    }
    if (oldPending != null &&
        pending == null &&
        !binding.syncIssue.startsWith('rejected:') &&
        (oldPending.acceptedTaskSequence == null ||
            oldPending.acceptedTaskSequence! > previous.appliedTaskSequence)) {
      throw StateError('project_build_task_pending_unreconciled');
    }
    if (oldPending == null && pending != null) {
      final known = previous.snapshot;
      if (pending.operation == ProjectBuildV2TaskOperation.create) {
        // A restored card may precede its durable unacknowledged intent.
        // Rebind only the original create nonce, never invent a new request.
        if (known != null ||
            previous.taskId != null ||
            pending.requestId != previous.createRequestId) {
          throw StateError('project_build_task_command_conflict');
        }
      } else if (known == null ||
          known.runId != pending.expectedRunId ||
          known.statusVersion != pending.expectedStatusVersion ||
          (pending.operation == ProjectBuildV2TaskOperation.retry
              ? !known.status.retryable
              : pending.operation == ProjectBuildV2TaskOperation.accept
              ? known.status != ProjectBuildV2Status.previewReady ||
                    known.candidate?.candidateDigest !=
                        pending.candidateDigest ||
                    (known.candidate?.baseRevision != pending.baseRevision ||
                        (known.candidate?.baseHeadVersion ?? 0) !=
                            pending.expectedHeadVersion)
              : !{
                  ProjectBuildV2Status.queued,
                  ProjectBuildV2Status.running,
                  ProjectBuildV2Status.previewReady,
                }.contains(known.status))) {
        throw StateError('project_build_task_command_conflict');
      }
    }
    if (jsonEncode(previous.toJson()) == jsonEncode(binding.toJson())) {
      return current;
    }
    final next = _projectBuildV2Projection(
      current.copyWith(projectBuildV2: binding),
    );
    jobs[jobs.indexWhere((job) => job.id == current.id)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  /// Reattaches an already durable repository intent after a projection race
  /// or restart. Its original CAS version/nonce must be replayed, even when the
  /// server journal has since advanced. New requests still use strict admission.
  AgentTaskJob restoreProjectBuildV2PendingCommand(
    String jobId,
    ProjectBuildV2PendingRequest request, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  }) {
    final current = byId(jobId);
    if (_sealed ||
        _persistenceError != null ||
        current == null ||
        !current.isProjectBuildV2 ||
        current.appletScopeKey != expectedScopeKey ||
        !isCurrentAttempt(current) ||
        request.scopeKey != expectedRepositoryScopeKey ||
        current.projectBuildV2!.scopeKey != expectedRepositoryScopeKey) {
      throw StateError('project_build_task_scope_changed');
    }
    final binding = current.projectBuildV2!;
    final create = request.create;
    late ProjectBuildV2TaskPendingCommand pending;
    if (create != null) {
      if (create.requestId != binding.createRequestId ||
          create.agentId != current.agentId ||
          create.requirements != current.userText ||
          (create.projectKind == ProjectBuildKind.game) !=
              (current.taskKind == AgentTaskKind.gameGeneration)) {
        throw StateError('project_build_task_pending_identity');
      }
      pending = ProjectBuildV2TaskPendingCommand(
        operation: ProjectBuildV2TaskOperation.create,
        requestId: create.requestId,
      );
    } else {
      final command = request.command;
      if (command == null || request.taskId != binding.taskId) {
        throw StateError('project_build_task_pending_identity');
      }
      pending = ProjectBuildV2TaskPendingCommand(
        operation: ProjectBuildV2TaskOperation.values.byName(
          command.operation.name,
        ),
        candidateDigest: command.candidateDigest,
        baseRevision: command.baseRevision,
        expectedHeadVersion: command.expectedHeadVersion,
        requestId: command.requestId,
        expectedRunId: command.expectedRunId,
        expectedStatusVersion: command.expectedStatusVersion,
      );
    }
    final previous = binding.pendingCommand;
    if (previous != null) {
      if (!previous.sameCommand(pending)) {
        throw StateError('project_build_task_pending_conflict');
      }
      pending = pending.copyWith(
        acceptedTaskSequence: previous.acceptedTaskSequence,
      );
    }
    final nextBinding = binding.copyWith(pendingCommand: pending);
    if (jsonEncode(nextBinding.toJson()) == jsonEncode(binding.toJson())) {
      return current;
    }
    final next = _projectBuildV2Projection(
      current.copyWith(projectBuildV2: nextBinding),
    );
    jobs[jobs.indexWhere((job) => job.id == jobId)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  AgentTaskJob applyProjectBuildV2Event(
    String localRootId,
    ProjectBuildV2Event event, {
    required String expectedScopeKey,
    required String agentId,
  }) {
    ProjectBuildV2Event.fromJson(event.toJson());
    final previous = latestForTask(
      localRootId,
      appletScopeKey: expectedScopeKey,
      agentId: agentId,
    );
    if (_sealed ||
        _persistenceError != null ||
        previous == null ||
        !previous.isProjectBuildV2) {
      throw StateError('project_build_task_scope_changed');
    }
    final binding = previous.projectBuildV2!;
    if (_deletedProjectV2Requests.contains(
      _v2RequestKey(binding.scopeKey, binding.createRequestId),
    )) {
      throw StateError('project_build_project_deleted');
    }
    if (binding.taskId != event.taskId) {
      throw StateError('project_build_task_event_identity');
    }
    final fingerprint =
        'pbe-${event.taskSequence}-${sha256.convert(utf8.encode(jsonEncode(event.toJson())))}';
    if (event.taskSequence <= binding.appliedTaskSequence) {
      final recorded = jobs
          .where(
            (job) =>
                job.taskId == localRootId &&
                job.agentId == agentId &&
                job.appletScopeKey == expectedScopeKey &&
                job.projectBuildV2?.createRequestId ==
                    binding.createRequestId &&
                job.projectBuildV2?.scopeKey == binding.scopeKey,
          )
          .expand((job) => job.progress)
          .where(
            (progress) =>
                progress.recordId == fingerprint ||
                progress.evidence.any(
                  (evidence) => evidence.reference == fingerprint,
                ),
          );
      if (recorded.isEmpty) {
        throw StateError('project_build_task_event_conflict');
      }
      return previous;
    }
    final nextBinding = binding.applyEvent(event);
    final eventSnapshot = nextBinding.snapshot!;
    if (eventSnapshot.agentId != agentId ||
        (eventSnapshot.projectKind == ProjectBuildKind.game) !=
            (previous.taskKind == AgentTaskKind.gameGeneration)) {
      throw StateError('project_build_task_scope_changed');
    }
    final newAttempt = eventSnapshot.attempt > previous.attempt;
    final persistence = _persistence;
    if (newAttempt &&
        persistence != null &&
        persistence is! AgentTaskAttemptPersistence) {
      throw StateError('server_attempt_atomic_persistence_required');
    }
    var next = newAttempt
        ? AgentTaskJob(
            id: 'job_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
            agentId: agentId,
            taskKind: previous.taskKind,
            userText: previous.userText,
            projectBrief: previous.projectBrief,
            status: AgentTaskJobStatus.running,
            createdAt: event.at.toLocal(),
            appletScopeKey: expectedScopeKey,
            attempt: eventSnapshot.attempt,
            parentJobId: previous.taskId,
            projectBuildV2: nextBinding,
          )
        : previous.copyWith(projectBuildV2: nextBinding);
    next = _projectBuildV2Projection(next);
    final node = event is ProjectBuildV2NodeDelta ? event.node : null;
    final stage = node == null
        ? _projectBuildV2Stage(eventSnapshot.status)
        : _projectBuildV2NodeStage(node.kind);
    final description = node == null
        ? 'project_build.task.event.${event.type.replaceAll('.', '_')}'.tr
        : _projectNodeExcerpt(
            node.title,
            AgentTaskProgress.maxDescriptionLength,
          );
    next = next.copyWith(
      progress: List.unmodifiable([
        ...next.progress,
        AgentTaskProgress(
          sequence: next.progress.length + 1,
          stage: stage,
          at: event.at,
          description: description,
          nodeId: node?.nodeId,
          nodeRevision: node?.revision,
          nodeStatus: node?.status.name,
          recordId: fingerprint,
          details: node == null
              ? ''
              : _projectNodeExcerpt(
                  [
                    node.summary,
                    node.details,
                  ].where((value) => value.isNotEmpty).join('\n\n'),
                  AgentTaskProgress.maxDetailsLength,
                  multiline: true,
                ),
          evidence: node != null
              ? List.unmodifiable(
                  node.evidence.map(
                    (evidence) => AgentTaskEvidence(
                      kind: AgentTaskEvidenceKind.values.byName(evidence.kind),
                      outcome: AgentTaskEvidenceOutcome.values.byName(
                        evidence.outcome,
                      ),
                      label:
                          _projectNodeExcerpt(
                            evidence.label,
                            AgentTaskEvidence.maxLabelLength,
                          ).trim().isEmpty
                          ? 'home.task.evidence.${evidence.outcome}'.tr
                          : _projectNodeExcerpt(
                              evidence.label,
                              AgentTaskEvidence.maxLabelLength,
                            ),
                      count: evidence.count,
                      reference: evidence.reference,
                    ),
                  ),
                )
              : List.unmodifiable([
                  AgentTaskEvidence(
                    kind: AgentTaskEvidenceKind.execution,
                    outcome: eventSnapshot.status == ProjectBuildV2Status.failed
                        ? AgentTaskEvidenceOutcome.failed
                        : AgentTaskEvidenceOutcome.completed,
                    label: description,
                    reference: fingerprint,
                  ),
                ]),
        ),
      ]),
    );
    if (newAttempt) {
      final retired = _projectBuildV2Projection(
        previous.copyWith(
          projectBuildV2: binding.copyWith(clearPending: true, syncIssue: ''),
        ),
      );
      jobs[jobs.indexWhere((job) => job.id == previous.id)] = retired;
      jobs.add(next);
      if (persistence is AgentTaskAttemptPersistence) {
        final retiredJson = retired.toJson();
        final nextJson = next.toJson();
        final card = cardFor(next);
        _pendingWrites = _pendingWrites.then((_) async {
          if (_persistenceError != null) return;
          try {
            await (persistence as AgentTaskAttemptPersistence)
                .writeServerAttempt(
                  retired: retiredJson,
                  next: nextJson,
                  card: card,
                );
          } catch (error) {
            _persistenceError ??= error;
          }
        });
      }
      if (!_events.isClosed) {
        _events.add(
          AgentTaskJobEvent(type: AgentTaskJobEventType.retried, job: next),
        );
      }
    } else {
      jobs[jobs.indexWhere((job) => job.id == previous.id)] = next;
      _emit(AgentTaskJobEventType.progress, next);
    }
    return next;
  }

  AgentTaskStage _projectBuildV2NodeStage(ProjectBuildV2NodeKind kind) =>
      switch (kind) {
        ProjectBuildV2NodeKind.validation => AgentTaskStage.validating,
        ProjectBuildV2NodeKind.delivery => AgentTaskStage.saving,
        _ => AgentTaskStage.generating,
      };

  String _projectNodeExcerpt(
    String value,
    int maxUnits, {
    bool multiline = false,
  }) {
    final result = StringBuffer();
    var units = 0;
    for (final rune in value.runes) {
      final text = String.fromCharCode(rune);
      if (!_validPublicTaskText(text, 2, multiline: multiline)) continue;
      if (units + text.length > maxUnits) break;
      result.write(text);
      units += text.length;
    }
    return result.toString();
  }

  AgentTaskStage _projectBuildV2Stage(ProjectBuildV2Status status) =>
      switch (status) {
        ProjectBuildV2Status.queued => AgentTaskStage.queued,
        ProjectBuildV2Status.running => AgentTaskStage.generating,
        ProjectBuildV2Status.cancelling => AgentTaskStage.cancelling,
        ProjectBuildV2Status.cancelled => AgentTaskStage.cancelled,
        ProjectBuildV2Status.failed => AgentTaskStage.failed,
        ProjectBuildV2Status.previewReady => AgentTaskStage.previewReady,
        ProjectBuildV2Status.completed => AgentTaskStage.completed,
      };

  AgentTaskJob _projectBuildV2Projection(AgentTaskJob job) {
    final binding = job.projectBuildV2!;
    final snapshot = binding.snapshot;
    var status = switch (snapshot?.status) {
      ProjectBuildV2Status.failed => AgentTaskJobStatus.failed,
      ProjectBuildV2Status.previewReady => AgentTaskJobStatus.awaitingInput,
      ProjectBuildV2Status.completed => AgentTaskJobStatus.completed,
      ProjectBuildV2Status.cancelled => AgentTaskJobStatus.cancelled,
      ProjectBuildV2Status.cancelling => AgentTaskJobStatus.cancelling,
      _ => AgentTaskJobStatus.running,
    };
    var stage = snapshot == null
        ? binding.taskId == null
              ? AgentTaskStage.submitting
              : AgentTaskStage.synchronizing
        : _projectBuildV2Stage(snapshot.status);
    if (snapshot?.status == ProjectBuildV2Status.running &&
        binding.lastNodeId != null) {
      stage = _projectBuildV2NodeStage(
        binding.nodes
            .singleWhere((node) => node.nodeId == binding.lastNodeId)
            .kind,
      );
    }
    if (snapshot == null && binding.syncIssue.startsWith('rejected:')) {
      status = AgentTaskJobStatus.failed;
      stage = AgentTaskStage.failed;
    } else if (binding.pendingCommand?.operation ==
            ProjectBuildV2TaskOperation.cancel &&
        snapshot?.isTerminal != true) {
      status = AgentTaskJobStatus.cancelling;
      stage = AgentTaskStage.cancelling;
    } else if (binding.pendingCommand?.operation ==
            ProjectBuildV2TaskOperation.accept &&
        snapshot?.isTerminal != true) {
      stage = AgentTaskStage.saving;
    } else if ((binding.syncIssue.isNotEmpty && snapshot?.isTerminal != true) ||
        binding.pendingCommand?.operation ==
            ProjectBuildV2TaskOperation.retry) {
      stage = AgentTaskStage.synchronizing;
    }
    return job.copyWith(
      status: status,
      stage: stage,
      updatedAt: snapshot?.updatedAt.toLocal() ?? job.updatedAt,
      error: snapshot?.errorCode ?? '',
      pendingPrompt: '',
      summary: '',
    );
  }

  AgentTaskJob startServerImage({
    required String agentId,
    required String userText,
    required String appletScopeKey,
    required CreatorImageTaskBinding binding,
  }) {
    if (_sealed) throw StateError('task_store_sealed');
    CreatorImageTaskBinding.fromJson(binding.toJson());
    if (binding.serverTaskId != null ||
        binding.pendingCommand?.operation != CreatorTaskOperation.create) {
      throw StateError('server_task_requires_new_intent');
    }
    final now = DateTime.now();
    final job = AgentTaskJob(
      id: 'job_${now.microsecondsSinceEpoch}_${_sequence++}',
      agentId: agentId,
      taskKind: AgentTaskKind.skillTask,
      userText: userText,
      status: AgentTaskJobStatus.running,
      createdAt: now,
      appletScopeKey: appletScopeKey,
      stage: AgentTaskStage.submitting,
      serverImage: binding,
      progress: [
        AgentTaskProgress(
          sequence: 1,
          stage: AgentTaskStage.submitting,
          at: now,
        ),
      ],
    );
    jobs.add(job);
    _emit(AgentTaskJobEventType.started, job);
    return job;
  }

  /// Updates only local transport/preview checkpoints. A receipt does not
  /// advance the authoritative server cursor or add invented progress stages.
  AgentTaskJob updateServerBinding(
    String jobId,
    CreatorImageTaskBinding binding, {
    required String expectedScopeKey,
  }) {
    final current = byId(jobId);
    if (_sealed ||
        current == null ||
        !current.isCreatorImage ||
        current.appletScopeKey != expectedScopeKey ||
        !isCurrentAttempt(current)) {
      throw StateError('server_task_scope_changed');
    }
    final previous = current.serverImage!;
    CreatorImageTaskBinding.fromJson(binding.toJson());
    if (!_sameServerIntent(previous, binding) ||
        (previous.serverTaskId != null &&
            previous.serverTaskId != binding.serverTaskId) ||
        ((previous.snapshot == null) != (binding.snapshot == null)) ||
        (previous.snapshot != null &&
            !previous.snapshot!.sameState(binding.snapshot!))) {
      throw StateError('server_task_checkpoint_conflict');
    }
    if (jsonEncode(previous.toJson()) == jsonEncode(binding.toJson())) {
      return current;
    }
    final next = _serverProjection(current.copyWith(serverImage: binding));
    jobs[jobs.indexWhere((job) => job.id == current.id)] = next;
    _emit(AgentTaskJobEventType.progress, next);
    return next;
  }

  /// Applies one contiguous, verified server journal event. Local and server
  /// progress counters are independent; old receipts/events cannot rewind it.
  AgentTaskJob applyServerSnapshot(
    String localRootId,
    CreatorTaskSnapshot snapshot, {
    required String expectedScopeKey,
    required String agentId,
  }) {
    CreatorTaskSnapshot.fromJson(snapshot.toJson());
    final previous = latestForTask(
      localRootId,
      appletScopeKey: expectedScopeKey,
      agentId: agentId,
    );
    if (_sealed ||
        previous == null ||
        !previous.isCreatorImage ||
        snapshot.agentId != agentId) {
      throw StateError('server_task_scope_changed');
    }
    final binding = previous.serverImage!;
    final known = binding.snapshot;
    if (binding.serverTaskId == null ||
        binding.serverTaskId != snapshot.taskId) {
      throw StateError('server_task_identity_changed');
    }
    if (snapshot.sequence < binding.serverSequence) return previous;
    if (snapshot.sequence == binding.serverSequence) {
      if (known == null || !known.sameState(snapshot)) {
        throw StateError('server_task_sequence_conflict');
      }
      return previous;
    }
    if (snapshot.sequence != binding.serverSequence + 1 ||
        snapshot.attempt < previous.attempt ||
        snapshot.attempt > previous.attempt + 1 ||
        (known != null && known.createdAt != snapshot.createdAt)) {
      throw StateError('server_task_journal_gap');
    }
    final newAttempt = snapshot.attempt > previous.attempt;
    if (newAttempt) {
      if (known?.canRetry != true ||
          snapshot.status != CreatorTaskStatus.queued) {
        throw StateError('server_task_attempt_conflict');
      }
    } else if (known != null &&
        (known.attemptId != snapshot.attemptId || known.isTerminal)) {
      throw StateError('server_task_attempt_conflict');
    }
    final pending = binding.pendingCommand;
    final clearPending =
        pending?.operation == CreatorTaskOperation.create ||
        (pending?.operation == CreatorTaskOperation.retry &&
            snapshot.attemptId != pending?.expectedAttemptId) ||
        (pending?.operation == CreatorTaskOperation.cancel &&
            snapshot.isTerminal);
    final nextBinding = binding.copyWith(
      snapshot: snapshot,
      syncIssue: '',
      clearPending: clearPending,
      clearPreview: newAttempt,
      applied: newAttempt ? false : binding.applied,
    );
    var next = newAttempt
        ? AgentTaskJob(
            id: 'job_${DateTime.now().microsecondsSinceEpoch}_${_sequence++}',
            agentId: previous.agentId,
            taskKind: AgentTaskKind.skillTask,
            userText: previous.userText,
            projectBrief: previous.projectBrief,
            status: AgentTaskJobStatus.running,
            createdAt: snapshot.updatedAt.toLocal(),
            appletScopeKey: expectedScopeKey,
            attempt: snapshot.attempt,
            parentJobId: previous.taskId,
            serverImage: nextBinding,
          )
        : previous.copyWith(serverImage: nextBinding);
    next = _serverProjection(next);
    next = _withProgress(next, next.stage);
    if (newAttempt) {
      final persistence = _persistence;
      if (persistence != null && persistence is! AgentTaskAttemptPersistence) {
        throw StateError('server_attempt_atomic_persistence_required');
      }
      final retired = _serverProjection(
        previous.copyWith(
          serverImage: binding.copyWith(clearPending: true, syncIssue: ''),
        ),
      );
      jobs[jobs.indexWhere((job) => job.id == previous.id)] = retired;
      jobs.add(next);
      if (persistence is AgentTaskAttemptPersistence) {
        final retiredJson = retired.toJson();
        final nextJson = next.toJson();
        final card = cardFor(next);
        _pendingWrites = _pendingWrites.then((_) async {
          if (_persistenceError != null) return;
          try {
            await (persistence as AgentTaskAttemptPersistence)
                .writeServerAttempt(
                  retired: retiredJson,
                  next: nextJson,
                  card: card,
                );
          } catch (error) {
            _persistenceError ??= error;
          }
        });
      }
      if (!_events.isClosed) {
        _events.add(
          AgentTaskJobEvent(type: AgentTaskJobEventType.retried, job: next),
        );
      }
    } else {
      jobs[jobs.indexWhere((job) => job.id == previous.id)] = next;
      _emit(AgentTaskJobEventType.progress, next);
    }
    return next;
  }

  bool _sameServerIntent(
    CreatorImageTaskBinding a,
    CreatorImageTaskBinding b,
  ) =>
      a.creatorScopeKey == b.creatorScopeKey &&
      a.draftId == b.draftId &&
      a.draftFingerprint == b.draftFingerprint &&
      a.createRequestId == b.createRequestId &&
      jsonEncode(a.input.toJson()) == jsonEncode(b.input.toJson());

  AgentTaskJob _serverProjection(AgentTaskJob job) {
    final binding = job.serverImage!;
    final snapshot = binding.snapshot;
    var status = switch (snapshot?.status) {
      CreatorTaskStatus.completed => AgentTaskJobStatus.completed,
      CreatorTaskStatus.failed ||
      CreatorTaskStatus.interrupted => AgentTaskJobStatus.failed,
      CreatorTaskStatus.cancelled => AgentTaskJobStatus.cancelled,
      _ => AgentTaskJobStatus.running,
    };
    var stage = switch (snapshot?.status) {
      null => AgentTaskStage.submitting,
      CreatorTaskStatus.queued => AgentTaskStage.queued,
      CreatorTaskStatus.running => AgentTaskStage.generating,
      CreatorTaskStatus.completed => AgentTaskStage.completed,
      CreatorTaskStatus.failed => AgentTaskStage.failed,
      CreatorTaskStatus.cancelled => AgentTaskStage.cancelled,
      CreatorTaskStatus.interrupted => AgentTaskStage.interrupted,
    };
    if (binding.syncIssue.startsWith('rejected:') && snapshot == null) {
      status = AgentTaskJobStatus.failed;
      stage = AgentTaskStage.failed;
    } else if (binding.pendingCommand?.operation ==
            CreatorTaskOperation.cancel &&
        snapshot?.canCancel == true) {
      status = AgentTaskJobStatus.cancelling;
      stage = AgentTaskStage.cancelling;
    } else if ((binding.syncIssue.isNotEmpty && snapshot?.isTerminal != true) ||
        binding.pendingCommand?.operation == CreatorTaskOperation.retry) {
      stage = AgentTaskStage.synchronizing;
    }
    return job.copyWith(
      status: status,
      stage: stage,
      updatedAt: snapshot?.updatedAt.toLocal() ?? job.updatedAt,
      error: snapshot?.errorCode ?? '',
      pendingPrompt: '',
    );
  }

  AgentTaskJob awaitInput(String id, String pendingPrompt) {
    final prompt = pendingPrompt.trim();
    if (prompt.isEmpty) {
      throw ArgumentError.value(
        pendingPrompt,
        'pendingPrompt',
        'must not be empty',
      );
    }
    return _transition(
      id,
      allowedStatuses: const {AgentTaskJobStatus.running},
      eventType: AgentTaskJobEventType.awaitingInput,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.awaitingInput,
        updatedAt: DateTime.now(),
        summary: '',
        error: '',
        pendingPrompt: prompt,
      ),
    );
  }

  AgentTaskJob resume(String id) {
    return _transition(
      id,
      allowedStatuses: const {AgentTaskJobStatus.awaitingInput},
      eventType: AgentTaskJobEventType.resumed,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.running,
        updatedAt: DateTime.now(),
        error: '',
        pendingPrompt: '',
      ),
    );
  }

  AgentTaskJob complete(String id, {String summary = ''}) {
    return _transition(
      id,
      allowedStatuses: const {AgentTaskJobStatus.running},
      eventType: AgentTaskJobEventType.completed,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.completed,
        updatedAt: DateTime.now(),
        summary: summary,
        error: '',
        pendingPrompt: '',
      ),
    );
  }

  /// Completes a generated task after its persisted presentation receipt has
  /// committed. That receipt is the only condition allowed to beat a racing
  /// cancellation request.
  AgentTaskJob completeCommittedPresentation(String id, {String summary = ''}) {
    return _transition(
      id,
      allowedStatuses: const {
        AgentTaskJobStatus.running,
        AgentTaskJobStatus.cancelling,
      },
      eventType: AgentTaskJobEventType.completed,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.completed,
        updatedAt: DateTime.now(),
        summary: summary,
        error: '',
        pendingPrompt: '',
      ),
    );
  }

  AgentTaskJob fail(String id, Object error, {String? failureCode}) {
    return _transition(
      id,
      allowedStatuses: const {
        AgentTaskJobStatus.running,
        AgentTaskJobStatus.cancelling,
      },
      eventType: AgentTaskJobEventType.failed,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.failed,
        updatedAt: DateTime.now(),
        error: error.toString(),
        failureCode:
            GeneratedTaskFailureCode.fromWireName(failureCode)?.name ??
            GeneratedTaskFailureCode.fromLegacyError(error.toString())?.name,
        pendingPrompt: '',
      ),
    );
  }

  AgentTaskJob requestCancel(String id) {
    return _transition(
      id,
      allowedStatuses: const {AgentTaskJobStatus.running},
      eventType: AgentTaskJobEventType.cancelling,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.cancelling,
        updatedAt: DateTime.now(),
        error: '',
        pendingPrompt: '',
      ),
    );
  }

  AgentTaskJob cancel(String id) {
    return _transition(
      id,
      allowedStatuses: const {
        AgentTaskJobStatus.running,
        AgentTaskJobStatus.awaitingInput,
        AgentTaskJobStatus.cancelling,
      },
      eventType: AgentTaskJobEventType.cancelled,
      update: (job) => job.copyWith(
        status: AgentTaskJobStatus.cancelled,
        updatedAt: DateTime.now(),
        error: '',
        pendingPrompt: '',
      ),
    );
  }

  AgentTaskJob retry(String id) {
    if (_sealed) throw StateError('task_store_sealed');
    final previous = byId(id);
    if (previous == null) throw StateError('unknown task job $id');
    if (previous.isServerBacked ||
        !previous.canRetryLocally ||
        !isCurrentAttempt(previous)) {
      return previous;
    }
    final now = DateTime.now();
    final retry = AgentTaskJob(
      id: 'job_${now.microsecondsSinceEpoch}_${_sequence++}',
      agentId: previous.agentId,
      taskKind: previous.taskKind,
      userText: previous.userText,
      projectBrief: previous.projectBrief,
      status: AgentTaskJobStatus.running,
      createdAt: now,
      appletScopeKey: previous.appletScopeKey,
      attempt: previous.attempt + 1,
      parentJobId: previous.parentJobId ?? previous.id,
      referenceInput: previous.referenceInput,
      progress: [
        AgentTaskProgress(
          sequence: 1,
          stage: AgentTaskStage.generating,
          at: now,
        ),
      ],
    );
    jobs.add(retry);
    _emit(AgentTaskJobEventType.retried, retry);
    return retry;
  }

  AgentTaskJob? byId(String id) {
    for (final job in jobs) {
      if (job.id == id) return job;
    }
    return null;
  }

  AgentTaskJob? latestForAgent(
    String agentId, {
    String? appletScopeKey,
    Set<AgentTaskJobStatus>? statuses,
  }) {
    final expectedScope = appletScopeKey?.trim();
    AgentTaskJob? latestMatchingStatus;
    for (final job in jobs.reversed) {
      if (job.agentId != agentId) continue;
      if (job.isServerBacked && !isCurrentAttempt(job)) continue;
      if (expectedScope != null && job.appletScopeKey != expectedScope) {
        continue;
      }
      if (statuses == null) return job;
      if (!statuses.contains(job.status)) continue;
      if (latestMatchingStatus == null ||
          (job.updatedAt ?? job.createdAt).isAfter(
            latestMatchingStatus.updatedAt ?? latestMatchingStatus.createdAt,
          )) {
        latestMatchingStatus = job;
      }
    }
    return latestMatchingStatus;
  }

  String latestStatusText(String agentId, {String? appletScopeKey}) {
    final job = latestForAgent(agentId, appletScopeKey: appletScopeKey);
    if (job == null) return 'home.task.none'.tr;
    return statusText(job);
  }

  String statusText(AgentTaskJob job) {
    if (job.isProjectBuild || job.isProjectBuildV2) {
      return 'project_build.task.stage.${job.stage.name}'.tr;
    }
    if (job.isCreatorImage) {
      final binding = job.serverImage!;
      if (binding.applied) return 'creator.task.applied'.tr;
      return 'creator.task.stage.${job.stage.name}'.tr;
    }
    final kind = _taskKindLabel(job.taskKind);
    return switch (job.status) {
      AgentTaskJobStatus.running => 'home.task.running_message'.trParams({
        'kind': kind,
      }),
      AgentTaskJobStatus.awaitingInput => job.pendingPrompt,
      AgentTaskJobStatus.cancelling => 'home.task.cancelling_message'.trParams({
        'kind': kind,
      }),
      AgentTaskJobStatus.completed => 'home.task.completed_message'.trParams({
        'kind': kind,
        'detail': job.summary.trim().isEmpty ? '' : ' ${job.summary.trim()}',
      }),
      AgentTaskJobStatus.failed => 'home.task.failed_message'.trParams({
        'kind': kind,
        'detail': job.error.trim().isEmpty ? '' : ' ${job.error.trim()}',
      }),
      AgentTaskJobStatus.cancelled => 'home.task.cancelled_message'.trParams({
        'kind': kind,
      }),
    };
  }

  @override
  void onClose() {
    _sealed = true;
    serverControls = null;
    _executionControls.clear();
    _closePreviewRequests();
    _events.close();
    super.onClose();
  }

  AgentTaskJob _transition(
    String id, {
    required Set<AgentTaskJobStatus> allowedStatuses,
    required AgentTaskJobEventType eventType,
    required AgentTaskJob Function(AgentTaskJob) update,
  }) {
    final index = jobs.indexWhere((job) => job.id == id);
    if (index < 0) throw StateError('unknown task job $id');
    final current = jobs[index];
    if (_sealed ||
        current.isServerBacked ||
        !allowedStatuses.contains(current.status)) {
      return current;
    }
    final updated = update(current);
    final next = _withProgress(updated, switch (updated.status) {
      AgentTaskJobStatus.running => AgentTaskStage.generating,
      AgentTaskJobStatus.awaitingInput => AgentTaskStage.awaitingInput,
      AgentTaskJobStatus.cancelling => AgentTaskStage.cancelling,
      AgentTaskJobStatus.completed => AgentTaskStage.completed,
      AgentTaskJobStatus.failed => AgentTaskStage.failed,
      AgentTaskJobStatus.cancelled => AgentTaskStage.cancelled,
    });
    jobs[index] = next;
    if (!next.isActive) {
      final request = _previewRequests[id];
      if (request != null && !request.isCompleted) request.complete(false);
    }
    _emit(eventType, next);
    return next;
  }

  void _emit(AgentTaskJobEventType type, AgentTaskJob job) {
    _persist(job);
    if (_events.isClosed) return;
    _events.add(AgentTaskJobEvent(type: type, job: job));
  }

  AgentTaskJob _withProgress(AgentTaskJob job, AgentTaskStage stage) =>
      job.copyWith(
        stage: stage,
        progress: List.unmodifiable([
          ...job.progress,
          AgentTaskProgress(
            sequence: job.progress.length + 1,
            stage: stage,
            at: job.updatedAt ?? job.createdAt,
          ),
        ]),
      );

  ChatMessage cardFor(AgentTaskJob job) {
    final root = byId(job.taskId) ?? job;
    return ChatMessage(
      sessionId: job.agentId,
      senderId: job.agentId,
      receiverId: 'user',
      content: '',
      timestamp: root.createdAt,
      turnOrigin: ChatMessageTurnOrigins.system,
      idempotencyKey: 'task-card:${job.taskId}',
      taskReference: AgentTaskChatReference(
        taskId: job.taskId,
        scopeKey: job.appletScopeKey,
        agentId: job.agentId,
      ),
    );
  }

  void _closePreviewRequests() {
    for (final request in _previewRequests.values) {
      if (!request.isCompleted) request.complete(false);
    }
    _previewRequests.clear();
  }

  void _persist(AgentTaskJob job) {
    final persistence = _persistence;
    if (persistence == null) return;
    final v2 = job.projectBuildV2;
    if (v2 != null &&
        _deletedProjectV2Requests.contains(
          _v2RequestKey(v2.scopeKey, v2.createRequestId),
        )) {
      return;
    }
    final snapshot = job.toJson();
    final card = cardFor(job);
    _pendingWrites = _pendingWrites.then((_) async {
      if (job.isServerBacked && _persistenceError != null) return;
      try {
        await persistence.writeJob(snapshot, card);
      } catch (error) {
        _persistenceError ??= error;
      }
    });
  }

  String _taskKindLabel(AgentTaskKind kind) {
    return switch (kind) {
      AgentTaskKind.gameGeneration => 'home.task.kind.game'.tr,
      AgentTaskKind.surfaceGeneration => 'home.task.kind.surface'.tr,
      AgentTaskKind.skillTask ||
      AgentTaskKind.none => 'home.task.kind.default'.tr,
    };
  }
}
