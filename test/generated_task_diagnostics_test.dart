import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_persistence.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('only exact public failure codes are accepted', () {
    for (final code in GeneratedTaskFailureCode.values) {
      expect(GeneratedTaskFailureCode.fromWireName(code.name), code);
      expect(
        GeneratedTaskFailureCode.fromLegacyError(
          'generated_task_failure:${code.name}',
        ),
        code,
      );
    }
    expect(
      GeneratedTaskFailureCode.fromWireName('modelTimeout secret'),
      isNull,
    );
    expect(
      GeneratedTaskFailureCode.fromLegacyError('API 429 PRIVATE_KEY'),
      isNull,
    );
    expect(
      GeneratedTaskFailureCode.fromLegacyError('hosted_llm_failure:quota'),
      GeneratedTaskFailureCode.modelQuotaExceeded,
    );
  });

  test(
    'generation admission failures identify a pre-code host failure',
    () async {
      for (final code in const [
        GeneratedTaskFailureCode.generationRequestUnrecognized,
        GeneratedTaskFailureCode.generationAuthorizationUnavailable,
      ]) {
        final key = 'home.task.failure.${code.name}';
        expect(zhCH[key], contains('代码生成尚未开始'));
        expect(enUS[key], contains('Code generation has not started'));
        expect(zhCH['${key}_action'], contains('原始需求已保留'));
        expect(enUS['${key}_action'], contains('original request is retained'));
        final store = AgentTaskJobStore();
        final job = store.start(
          agentId: 'self',
          taskKind: AgentTaskKind.gameGeneration,
          userText: '生成魂斗罗小游戏',
          appletScopeKey: 'device-legacy',
        );
        final failed = store.fail(
          job.id,
          'surface_generation_authority_unavailable',
          failureCode: code.name,
        );
        expect(AgentTaskJob.tryParse(failed.toJson())!.failureCode, code.name);
        final retry = store.retry(job.id);
        expect(retry.taskId, failed.taskId);
        expect(retry.failureCode, isNull);
        await store.deactivateAndDrain();
      }
    },
  );

  test(
    'a public model summary is bounded and contains no control characters',
    () {
      final summary = generatedTaskPublicSummary(
        'A\u0000\u202e note ${'x' * 400}',
      );
      expect(summary, startsWith('A note '));
      expect(summary.runes.length, 240);
      expect(summary, isNot(contains('\u0000')));
      expect(summary, isNot(contains('\u202e')));
    },
  );

  test(
    'failure categories persist while retries start without stale failures',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'typed-task-${DateTime.now().microsecondsSinceEpoch}.db',
      );
      addTearDown(db.close);
      final persistence = SembastAgentTaskPersistence(db);
      final store = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(store.deactivateAndDrain);
      final job = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: 'Create a game',
        appletScopeKey: 'device-legacy',
      );
      final failed = store.fail(
        job.id,
        'PRIVATE diagnostic detail',
        failureCode: GeneratedTaskFailureCode.gameRuntimeTimeout.name,
      );
      final retry = store.retry(job.id);
      expect(retry.failureCode, isNull);
      expect(
        failed.copyWith(status: AgentTaskJobStatus.completed).failureCode,
        isNull,
      );
      await store.flush();
      final reopened = await AgentTaskJobStore(persistence: persistence).init();
      addTearDown(reopened.deactivateAndDrain);
      expect(reopened.byId(job.id)!.failureCode, 'gameRuntimeTimeout');
      expect(reopened.byId(retry.id)!.failureCode, 'interrupted');
      final old = failed.toJson()..remove('failureCode');
      expect(AgentTaskJob.tryParse(old)!.failureCode, isNull);
      for (final bad in <Object?>[
        'PRIVATE fake code',
        1,
        {'secret': true},
      ]) {
        expect(
          AgentTaskJob.tryParse(
            failed.toJson()..['failureCode'] = bad,
          )!.failureCode,
          isNull,
        );
      }
    },
  );

  test(
    'validation hints expose fixed host facts without copying source names',
    () {
      final hint = generatedTaskValidationPublicHint(
        'public webApps must not use network, storage, dynamic code, navigation, or cross-frame APIs; PRIVATE_GENERATED_SOURCE',
        zh: true,
      );
      expect(hint, contains('旧版网页代码检查记录'));
      expect(hint, isNot(contains('离线实现')));
      expect(hint, isNot(contains('PRIVATE_GENERATED_SOURCE')));
      expect(
        generatedTaskValidationPublicHint('PRIVATE_UNKNOWN_CHECK', zh: false),
        contains('project contract checks'),
      );
    },
  );

  test('budget excludes waiting for the user but resumes afterward', () async {
    final budget = GeneratedTaskBudget(const Duration(milliseconds: 100));
    budget.pauseForUser();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(budget.isExpired, isFalse);
    expect(budget.remaining, greaterThan(Duration.zero));
    budget.resume();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(budget.isExpired, isTrue);
    expect(budget.requireRemaining, throwsA(isA<GeneratedTaskFailure>()));
  });

  test(
    'a provider ignoring timeout cannot keep a pure generation pending',
    () async {
      final reply = Completer<String>();
      final budget = GeneratedTaskBudget(const Duration(milliseconds: 50));
      await expectLater(
        budget.modelRequest((_) => reply.future, const Duration(seconds: 10)),
        throwsA(
          isA<GeneratedTaskFailure>().having(
            (failure) => failure.code,
            'category',
            GeneratedTaskFailureCode.taskTimeout,
          ),
        ),
      );
      reply.complete('late source');
    },
  );
}
