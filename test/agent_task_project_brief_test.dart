import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';

const _authorityRequest = '制作一个小游戏，按用户确认的提案完整实现。';
const _brief = '''
用户确认：好就按你的来做。
制作提案：我给你做个收集光点能改变重力的小游戏，好吗？
角色跟随触屏移动，收集够了进入下一关。
''';

class _MemoryPersistence implements AgentTaskPersistence {
  final rows = <String, Map<String, Object?>>{};

  @override
  Future<List<Map<String, Object?>>> readJobs() async => [
    for (final row in rows.values) Map<String, Object?>.from(row),
  ];

  @override
  Future<void> writeJob(Map<String, Object?> job, ChatMessage card) async {
    rows[job['id'] as String] = Map<String, Object?>.from(
      jsonDecode(jsonEncode(job)) as Map,
    );
  }
}

void main() {
  setUp(() => AppLocalization.updateLocale(const Locale('zh', 'CN')));

  AgentTaskJob start(AgentTaskJobStore store, {String projectBrief = ''}) =>
      store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: _authorityRequest,
        projectBrief: projectBrief,
        appletScopeKey: 'device-legacy',
      );

  test('old snapshots retain their existing JSON and empty brief', () {
    final store = AgentTaskJobStore();
    addTearDown(store.onClose);
    final job = start(store);
    expect(job.projectBrief, isEmpty);
    final oldRow = job.toJson();
    expect(oldRow.containsKey('projectBrief'), isFalse);
    final parsed = AgentTaskJob.tryParse(oldRow)!;
    expect(parsed.projectBrief, isEmpty);
    expect(parsed.toJson(), oldRow);
  });

  test(
    'JSON round trip keeps confirmed project data distinct from authority',
    () {
      final store = AgentTaskJobStore();
      addTearDown(store.onClose);
      final job = start(store, projectBrief: _brief);
      final parsed = AgentTaskJob.tryParse(
        Map<String, Object?>.from(jsonDecode(jsonEncode(job.toJson())) as Map),
      )!;
      expect(parsed.userText, _authorityRequest);
      expect(parsed.projectBrief, _brief);
      expect(parsed.toJson(), job.toJson());
      expect(
        parsed.copyWith(status: AgentTaskJobStatus.failed).projectBrief,
        _brief,
      );
      expect(parsed.copyWith(projectBrief: '').projectBrief, isEmpty);
    },
  );

  test('malformed optional brief fields fail closed', () {
    final store = AgentTaskJobStore();
    addTearDown(store.onClose);
    final row = start(store).toJson();
    for (final bad in <Object?>[
      null,
      true,
      42,
      [],
      {'kind': 'game'},
    ]) {
      expect(AgentTaskJob.tryParse({...row, 'projectBrief': bad}), isNull);
    }
    expect(AgentTaskJob.tryParse({...row, 'projectBrief': ''}), isNotNull);
  });

  test(
    'ordinary lifecycle changes and local retries retain the exact brief',
    () {
      final store = AgentTaskJobStore();
      addTearDown(store.onClose);
      final job = start(store, projectBrief: _brief);
      store.awaitInput(job.id, '请选择');
      expect(store.byId(job.id)!.projectBrief, _brief);
      store.resume(job.id);
      expect(store.byId(job.id)!.projectBrief, _brief);
      store.fail(job.id, 'synthetic_test_error');
      final retry = store.retry(job.id);
      expect(retry.id, isNot(job.id));
      expect(retry.attempt, 2);
      expect(retry.userText, _authorityRequest);
      expect(retry.projectBrief, _brief);
      expect(retry.taskId, job.taskId);
      store.complete(retry.id);
      expect(store.byId(retry.id)!.projectBrief, _brief);
    },
  );

  test(
    'disk checkpoint restore and retry keep the brief after interruption',
    () async {
      final persistence = _MemoryPersistence();
      final original = AgentTaskJobStore(persistence: persistence);
      final job = start(original, projectBrief: _brief);
      await original.flush();
      original.onClose();
      final restored = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(restored.onClose);
      final interrupted = restored.byId(job.id)!;
      expect(interrupted.status, AgentTaskJobStatus.failed);
      expect(interrupted.projectBrief, _brief);
      expect(interrupted.userText, _authorityRequest);
      final retry = restored.retry(interrupted.id);
      await restored.flush();
      final durable = AgentTaskJob.tryParse(persistence.rows[retry.id]!)!;
      expect(durable.projectBrief, _brief);
      expect(durable.userText, _authorityRequest);
    },
  );

  test(
    'local project data uses the existing raw user text storage behavior',
    () {
      final store = AgentTaskJobStore();
      addTearDown(store.onClose);
      final longBrief = '任意交互规则\n${'星星改变重力🌟' * 3000}';
      final row = start(store, projectBrief: longBrief).toJson();
      final parsed = AgentTaskJob.tryParse(row)!;
      expect(parsed.projectBrief, longBrief);
      expect(parsed.userText, _authorityRequest);
    },
  );
}
