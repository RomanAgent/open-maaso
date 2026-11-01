import 'dart:convert';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:sembast/sembast.dart';

abstract interface class AgentTaskPersistence {
  Future<List<Map<String, Object?>>> readJobs();
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card);
}

/// Server retries replace two local execution records as one durable fact.
/// Single-row legacy adapters remain valid for local jobs, but cannot attest
/// that a server retry has been safely checkpointed.
abstract interface class AgentTaskAttemptPersistence {
  Future<void> writeServerAttempt({
    required Map<String, Object?> retired,
    required Map<String, Object?> next,
    required ChatMessage card,
  });
}

/// A positively acknowledged account-owned deletion erases all attempts and
/// their unique task cards, while retaining a minimal fence against late writes.
abstract interface class AgentTaskProjectDeletionPersistence {
  Future<Map<String, Set<String>>> readDeletedLocalTaskIds();
  Future<Set<String>> purgeProjectBuildV2(
    ProjectBuildV2DeletionProof proof, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  });
}

/// The task snapshot, public event journal and unique conversation reference
/// share a transaction in the already account-scoped application database.
final class SembastAgentTaskPersistence
    implements
        AgentTaskPersistence,
        AgentTaskAttemptPersistence,
        AgentTaskProjectDeletionPersistence {
  SembastAgentTaskPersistence(this.database);
  final DBService database;
  static final _jobs = stringMapStoreFactory.store('agent_task_jobs');
  static final _messages = intMapStoreFactory.store('chat_messages');
  static final _deletedProjects = stringMapStoreFactory.store(
    'agent_task_deleted_projects_v2',
  );

  @override
  Future<List<Map<String, Object?>>> readJobs() async {
    final rows = await _jobs.find(database.raw);
    final widgets = await database.getAllWidgets();
    return rows.map((row) {
      final job = Map<String, Object?>.from(row.value);
      // A local presentation receipt cannot attest to a server image task.
      if (job['executionLocation'] == 'server') return job;
      final scope = job['appletScopeKey'];
      if (scope is! String) return job;
      final committed = widgets
          .where(
            (item) =>
                item.isSurface &&
                item.agentId == job['agentId'] &&
                item.spec['taskJobId'] == job['id'] &&
                isAppletPresentationDiscoverable(item, scopeKey: scope),
          )
          .toList();
      // The widget's committed presentation marker is authoritative even if
      // the process died before the task's completion write reached disk.
      if (committed.length == 1 && job['status'] != 'completed') {
        job['status'] = 'completed';
        job['stage'] = 'completed';
        job['surfaceId'] = committed.single.spec['surfaceId'];
        job['widgetId'] = committed.single.id;
        job['error'] = '';
        job['pendingPrompt'] = '';
        job['updatedAt'] = DateTime.now().toUtc().toIso8601String();
        final progress = job['progress'];
        if (progress is List) {
          job['progress'] = [
            ...progress,
            {
              'sequence': progress.length + 1,
              'stage': 'completed',
              'at': job['updatedAt'],
            },
          ];
        }
      }
      return job;
    }).toList();
  }

  @override
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card) =>
      _writeRows([job], card);

  @override
  Future<void> writeServerAttempt({
    required Map<String, Object?> retired,
    required Map<String, Object?> next,
    required ChatMessage card,
  }) => _writeRows([retired, next], card);

  Future<void> _writeRows(List<Map<String, Object?>> jobs, ChatMessage card) =>
      database.raw.transaction((transaction) async {
        final deleted = await _deletedProjects.find(transaction);
        if (jobs.any(
          (job) =>
              deleted.any((entry) => _matchesDeletedProject(job, entry.value)),
        )) {
          return;
        }
        for (final job in jobs) {
          await _jobs.record(job['id']! as String).put(transaction, job);
        }
        final existing = await _messages.findFirst(
          transaction,
          finder: Finder(
            filter: Filter.equals('idempotencyKey', card.idempotencyKey),
          ),
        );
        if (existing == null) await _messages.add(transaction, card.toJson());
      });
  @override
  Future<Map<String, Set<String>>> readDeletedLocalTaskIds() async {
    final rows = await _deletedProjects.find(database.raw);
    final grouped = <String, Set<String>>{};
    for (final row in rows) {
      final scope = row.value['appletScopeKey'];
      if (scope is! String) {
        throw const FormatException('project_delete_marker_scope');
      }
      final ids = (row.value['localTaskIds'] as List? ?? const [])
          .cast<String>();
      (grouped[scope] ??= {}).addAll(ids);
    }
    return Map.unmodifiable({
      for (final e in grouped.entries) e.key: Set<String>.unmodifiable(e.value),
    });
  }

  @override
  Future<Set<String>> purgeProjectBuildV2(
    ProjectBuildV2DeletionProof proof, {
    required String expectedScopeKey,
    required String expectedRepositoryScopeKey,
  }) async {
    if (proof.scopeKey != expectedRepositoryScopeKey ||
        expectedScopeKey.isEmpty) {
      throw StateError('project_build_scope_changed');
    }
    final marker = <String, Object?>{
      'appletScopeKey': expectedScopeKey,
      'repositoryScopeKey': expectedRepositoryScopeKey,
      'projectId': proof.projectId,
      'taskIds': proof.taskIds,
      'createRequestIds': proof.createRequestIds,
      'headVersion': proof.receipt.headVersion,
    };
    return database.raw.transaction((tx) async {
      if (!proof.isScopeCurrent) {
        throw StateError('project_build_scope_changed');
      }
      final key = jsonEncode([
        expectedScopeKey,
        expectedRepositoryScopeKey,
        proof.projectId,
      ]);
      final previous = await _deletedProjects.record(key).get(tx);
      final roots = <String>{
        ...(previous?['localTaskIds'] as List? ?? const []).cast<String>(),
      };
      final rows = await _jobs.find(tx);
      for (final row in rows) {
        if (!_matchesDeletedProject(row.value, marker)) continue;
        roots.add((row.value['parentJobId'] ?? row.value['id'])! as String);
        await _jobs.record(row.key).delete(tx);
      }
      await _deletedProjects.record(key).put(tx, {
        ...marker,
        'localTaskIds': roots.toList(),
      });
      final messages = await _messages.find(tx);
      for (final row in messages) {
        final ref = row.value['taskReference'];
        if (ref is Map &&
            ref['scopeKey'] == expectedScopeKey &&
            roots.contains(ref['taskId'])) {
          await _messages.record(row.key).delete(tx);
        }
      }
      if (!proof.isScopeCurrent) {
        throw StateError('project_build_scope_changed');
      }
      return Set<String>.unmodifiable(roots);
    });
  }
}

bool _matchesDeletedProject(
  Map<String, Object?> job,
  Map<String, Object?> marker,
) {
  final binding = job['projectBuildV2'];
  if (job['appletScopeKey'] != marker['appletScopeKey'] ||
      binding is! Map ||
      binding['scopeKey'] != marker['repositoryScopeKey']) {
    return false;
  }
  final snapshot = binding['snapshot'];
  return (snapshot is Map && snapshot['projectId'] == marker['projectId']) ||
      (marker['taskIds']! as List).contains(binding['taskId']) ||
      (marker['createRequestIds']! as List).contains(
        binding['createRequestId'],
      );
}
