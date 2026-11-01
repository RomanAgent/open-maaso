import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_task_diagnostics.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_presentation.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_node.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';

import 'support/project_build_v2_fixtures.dart';

void main() {
  late AgentTaskJobStore store;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    store = appServices.put(AgentTaskJobStore());
  });
  tearDown(() => appServices.reset());

  AgentTaskJob start(String title, {String scope = 'device-legacy'}) =>
      store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: title,
        appletScopeKey: scope,
      );

  AgentTaskJob serverFailure(String reference) {
    final job = start('制作需要模型权限的小游戏');
    final snapshot = ProjectBuildV2Snapshot.fromJson({
      ...projectBuildV2Object(projectBuildV2Events().last['snapshot']),
      'projectKind': 'game',
      'agentId': job.agentId,
      'status': 'failed',
      'errorCode': 'worker_failed',
    });
    final node = ProjectBuildV2Node.fromJson({
      'nodeId': 'generation_step',
      'parentId': null,
      'dependencyIds': [],
      'revision': 1,
      'status': 'failed',
      'kind': 'generation',
      'title': '生成小游戏内容',
      'summary': '当前制作步骤未能完成',
      'details': '已保留本次制作记录',
      'evidence': [
        {
          'kind': 'execution',
          'outcome': 'failed',
          'label': '模型调用结果',
          'reference': reference,
        },
      ],
    });
    final failed = job.copyWith(
      status: AgentTaskJobStatus.failed,
      stage: AgentTaskStage.failed,
      projectBuildV2: ProjectBuildV2TaskBinding(
        scopeKey: projectBuildV2TestScope,
        createRequestId: projectBuildV2Input().requestId,
        taskId: snapshot.taskId,
        snapshot: snapshot,
        nodes: [node],
        lastNodeId: node.nodeId,
      ),
      progress: [
        AgentTaskProgress(
          sequence: 1,
          stage: AgentTaskStage.generating,
          at: snapshot.updatedAt,
          nodeId: node.nodeId,
          nodeRevision: node.revision,
          nodeStatus: 'failed',
        ),
      ],
    );
    store.jobs[store.jobs.indexWhere((entry) => entry.id == job.id)] = failed;
    return failed;
  }

  Future<void> mountServerFailure(WidgetTester tester, AgentTaskJob job) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: AgentTaskChatCard(
              reference: store.cardFor(job).taskReference!,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'coarse worker failure uses current failed-node membership evidence',
    (tester) async {
      final job = serverFailure('membership_required');
      final view = AgentTaskPresentation(job);
      expect(job.projectBuildV2!.snapshot!.errorCode, 'worker_failed');
      expect(view.failureCode, 'modelMembershipRequired');
      expect(
        AgentTaskPresentation(
          job.copyWith(failureCode: 'gameRuntimeFailed'),
        ).failureCode,
        'gameRuntimeFailed',
      );
      expect(
        AgentTaskPresentation(job.copyWith(attempt: 2)).failureCode,
        'unknown',
      );
      await mountServerFailure(tester, job);
      expect(find.text('当前模型需要可用的会员权限。'), findsOneWidget);
      expect(find.text('检查账号权限或切换可用模型后重试。'), findsOneWidget);
      expect(find.text('membership_required'), findsNothing);
      expect(find.text('worker_failed'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'unknown failed-node references stay generic and are never displayed',
    (tester) async {
      final job = serverFailure('SECRET_RAW_PROVIDER_TOKEN');
      expect(AgentTaskPresentation(job).failureCode, 'unknown');
      await mountServerFailure(tester, job);
      expect(find.text('本次生成未能完成，未收到可识别的失败原因。'), findsOneWidget);
      expect(find.textContaining('SECRET_RAW_PROVIDER_TOKEN'), findsNothing);
      expect(find.textContaining('worker_failed'), findsNothing);
      await tester.tap(find.text('查看生成过程'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(
        ValueKey('task-node-toggle-${job.id}:generation_step'),
      );
      await tester.ensureVisible(toggle);
      await tester.tap(toggle);
      await tester.pump();
      expect(find.textContaining('SECRET_RAW_PROVIDER_TOKEN'), findsNothing);
      expect(find.text('模型调用结果 · 未通过'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'recorded waits are excluded after resume and terminal elapsed is capped',
    () {
      final at = DateTime.utc(2026, 10, 7, 1);
      AgentTaskProgress record(
        int sequence,
        AgentTaskStage stage,
        int second,
      ) => AgentTaskProgress(
        sequence: sequence,
        stage: stage,
        at: at.add(Duration(seconds: second)),
      );
      for (final waitStage in [
        AgentTaskStage.previewReady,
        AgentTaskStage.awaitingInput,
      ]) {
        final job = AgentTaskJob(
          id: 'job_elapsed_1',
          agentId: 'self',
          taskKind: AgentTaskKind.gameGeneration,
          userText: '有等待确认的制作任务',
          status: AgentTaskJobStatus.running,
          stage: AgentTaskStage.validating,
          createdAt: at,
          updatedAt: at.add(const Duration(seconds: 70)),
          appletScopeKey: 'device-legacy',
          progress: [
            record(1, AgentTaskStage.generating, 0),
            record(2, waitStage, 10),
            record(3, waitStage, 30),
            record(4, AgentTaskStage.validating, 70),
          ],
        );
        expect(
          AgentTaskPresentation(
            job,
          ).elapsedAt(at.add(const Duration(seconds: 75))),
          const Duration(seconds: 15),
        );
        final waiting = job.copyWith(
          status: AgentTaskJobStatus.awaitingInput,
          stage: waitStage,
          updatedAt: at.add(const Duration(seconds: 30)),
          progress: job.progress.take(3).toList(),
        );
        expect(
          AgentTaskPresentation(
            waiting,
          ).elapsedAt(at.add(const Duration(seconds: 200))),
          const Duration(seconds: 10),
        );
        final completed = job.copyWith(
          status: AgentTaskJobStatus.completed,
          stage: AgentTaskStage.completed,
          updatedAt: at.add(const Duration(seconds: 75)),
          progress: [
            ...job.progress,
            record(5, AgentTaskStage.completed, 75),
            record(6, waitStage, 200),
          ],
        );
        expect(
          AgentTaskPresentation(
            completed,
          ).elapsedAt(at.add(const Duration(seconds: 300))),
          const Duration(seconds: 15),
        );
        final secondWait = job.copyWith(
          progress: [
            ...job.progress,
            record(5, waitStage, 75),
            record(6, AgentTaskStage.saving, 95),
          ],
        );
        expect(
          AgentTaskPresentation(
            secondWait,
          ).elapsedAt(at.add(const Duration(seconds: 97))),
          const Duration(seconds: 17),
        );
      }
    },
  );

  test(
    'legacy missing records and backward timestamps do not invent waits or negative time',
    () {
      final at = DateTime.utc(2026, 10, 7, 1);
      final legacy = AgentTaskJob(
        id: 'job_elapsed_legacy',
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '旧版记录',
        status: AgentTaskJobStatus.running,
        createdAt: at,
        updatedAt: at.add(const Duration(seconds: 10)),
        appletScopeKey: 'device-legacy',
      );
      expect(
        AgentTaskPresentation(
          legacy,
        ).elapsedAt(at.add(const Duration(seconds: 75))),
        const Duration(seconds: 75),
      );
      expect(
        AgentTaskPresentation(
          legacy.copyWith(
            status: AgentTaskJobStatus.awaitingInput,
            stage: AgentTaskStage.previewReady,
          ),
        ).elapsedAt(at.add(const Duration(seconds: 75))),
        const Duration(seconds: 10),
      );
      expect(
        AgentTaskPresentation(
          legacy.copyWith(status: AgentTaskJobStatus.failed),
        ).elapsedAt(at.add(const Duration(seconds: 75))),
        const Duration(seconds: 10),
      );
      expect(
        AgentTaskPresentation(
          legacy,
        ).elapsedAt(at.subtract(const Duration(seconds: 1))),
        Duration.zero,
      );
      expect(
        AgentTaskPresentation(
          legacy.copyWith(
            status: AgentTaskJobStatus.failed,
            updatedAt: at.subtract(const Duration(seconds: 1)),
          ),
        ).elapsedAt(at),
        Duration.zero,
      );
      final disorder = legacy.copyWith(
        progress: [
          AgentTaskProgress(
            sequence: 1,
            stage: AgentTaskStage.generating,
            at: at,
          ),
          AgentTaskProgress(
            sequence: 2,
            stage: AgentTaskStage.previewReady,
            at: at.add(const Duration(seconds: 10)),
          ),
          AgentTaskProgress(
            sequence: 3,
            stage: AgentTaskStage.validating,
            at: at.add(const Duration(seconds: 70)),
          ),
          AgentTaskProgress(
            sequence: 4,
            stage: AgentTaskStage.previewReady,
            at: at.add(const Duration(seconds: 5)),
          ),
          AgentTaskProgress(
            sequence: 5,
            stage: AgentTaskStage.previewReady,
            at: at.add(const Duration(seconds: 200)),
          ),
        ],
      );
      expect(
        AgentTaskPresentation(
          disorder,
        ).elapsedAt(at.add(const Duration(seconds: 75))),
        const Duration(seconds: 15),
      );
    },
  );

  test(
    'every task kind has readable labels for recorded stages in both locales',
    () {
      for (final locale in [
        const Locale('zh', 'CN'),
        const Locale('en', 'US'),
      ]) {
        AppLocalization.updateLocale(locale);
        for (final prefix in [
          'home.task',
          'project_build.task',
          'creator.task',
        ]) {
          for (final stage in AgentTaskStage.values) {
            final key = '$prefix.stage.${stage.name}';
            expect(key.tr, isNot(key), reason: '$locale / $key');
          }
        }
      }
    },
  );

  test(
    'every public failure category has a reason and a recovery in both locales',
    () {
      final job = start('制作五子棋');
      for (final locale in [
        const Locale('zh', 'CN'),
        const Locale('en', 'US'),
      ]) {
        AppLocalization.updateLocale(locale);
        for (final code in GeneratedTaskFailureCode.values) {
          final view = AgentTaskPresentation(
            job.copyWith(
              status: AgentTaskJobStatus.failed,
              stage: AgentTaskStage.failed,
              error: 'PRIVATE_PROVIDER_BODY',
              failureCode: code.name,
            ),
          );
          expect(view.failureCode, code.name);
          expect(view.failureMessageKey!.tr, isNot(view.failureMessageKey));
          expect(view.recoveryMessageKey!.tr, isNot(view.recoveryMessageKey));
          expect(
            view.failureMessageKey!.tr,
            isNot(contains('PRIVATE_PROVIDER_BODY')),
          );
        }
      }
    },
  );

  test(
    'typed failures take precedence and arbitrary legacy text stays generic',
    () {
      final job = start('制作消除游戏');
      final failed = job.copyWith(
        status: AgentTaskJobStatus.failed,
        stage: AgentTaskStage.failed,
        error: 'https://provider.invalid/token SECRET timeout',
        failureCode: GeneratedTaskFailureCode.gameRuntimeFailed.name,
      );
      expect(AgentTaskPresentation(failed).failureCode, 'gameRuntimeFailed');
      expect(
        AgentTaskPresentation(
          failed.copyWith(failureCode: 'unknown_private_code'),
        ).failureCode,
        'unknown',
      );
      expect(
        AgentTaskPresentation(
          job.copyWith(
            status: AgentTaskJobStatus.failed,
            error: 'hosted_llm_failure:authentication',
          ),
        ).failureCode,
        'modelAuthentication',
      );
      expect(AgentTaskPresentation(job).failureMessageKey, isNull);
    },
  );

  test(
    'failure points at the last real action and timestamp, without invented steps',
    () {
      final job = start('制作跑酷');
      final at = DateTime.utc(2026, 10, 7, 1, 2);
      final failed = job.copyWith(
        status: AgentTaskJobStatus.failed,
        stage: AgentTaskStage.failed,
        updatedAt: at,
        progress: [
          AgentTaskProgress(
            sequence: 1,
            stage: AgentTaskStage.generating,
            at: at.subtract(const Duration(seconds: 10)),
            description: '生成跳跃和碰撞代码',
          ),
          AgentTaskProgress(
            sequence: 2,
            stage: AgentTaskStage.failed,
            at: at,
            description: '生成失败',
          ),
        ],
      );
      final view = AgentTaskPresentation(failed);
      expect(view.currentAction, '生成跳跃和碰撞代码');
      expect(view.lastUpdatedAt, at);
      expect(view.recordSummary, '2 条过程记录');
      expect(view.ledgerGroup, 'attention');
      expect(
        AgentTaskPresentation(
          job.copyWith(stage: AgentTaskStage.previewReady),
        ).ledgerGroup,
        'attention',
      );
      expect(AgentTaskPresentation(job).ledgerGroup, 'active');
      expect(
        AgentTaskPresentation(
          job.copyWith(
            status: AgentTaskJobStatus.completed,
            stage: AgentTaskStage.completed,
          ),
        ).ledgerGroup,
        'finished',
      );
    },
  );

  for (final layout in [
    (size: const Size(320, 760), scale: 2.0, brightness: Brightness.dark),
    (size: const Size(375, 812), scale: 1.0, brightness: Brightness.light),
    (size: const Size(812, 375), scale: 1.0, brightness: Brightness.light),
  ]) {
    testWidgets(
      'failure is readable and announced at ${layout.size} / ${layout.scale}x',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final job = start('制作一个带有多个关卡的小游戏');
        store.fail(
          job.id,
          'SECRET_RAW_PROVIDER_TEXT',
          failureCode: 'modelOutputTruncated',
        );
        tester.view.physicalSize = layout.size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: layout.brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: layout.size,
                textScaler: TextScaler.linear(layout.scale),
                disableAnimations: true,
              ),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: AgentTaskChatCard(
                    reference: store.cardFor(job).taskReference!,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        expect(find.textContaining('生成失败'), findsOneWidget);
        expect(find.text('模型返回的代码被截断，作品尚不完整。'), findsOneWidget);
        expect(find.textContaining('SECRET_RAW_PROVIDER_TEXT'), findsNothing);
        expect(find.textContaining('最后更新'), findsOneWidget);
        expect(
          tester
              .getSemantics(find.byKey(const ValueKey('task-failure-summary')))
              .getSemanticsData()
              .flagsCollection
              .isLiveRegion,
          isTrue,
        );
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(UiKitView), findsNothing);
        expect(tester.takeException(), isNull);
        semantics.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'preview is a user decision with a stopped clock and no saved claim',
    (tester) async {
      final job = start('制作待预览的游戏');
      final preview = store.awaitPreview(job.id);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: AgentTaskChatCard(
                reference: store.cardFor(job).taskReference!,
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('已生成，等待预览和保存'), findsOneWidget);
      expect(find.text('已生成草稿，点击预览作品完成运行检查并确认保存。'), findsOneWidget);
      expect(find.textContaining('已保存'), findsNothing);
      final duration = tester.widget<Text>(find.textContaining('耗时')).data;
      await tester.pump(const Duration(seconds: 5));
      expect(tester.widget<Text>(find.textContaining('耗时')).data, duration);
      store.cancel(job.id);
      expect(await preview, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'ledger groups latest attempts with clear failure reasons and scope filtering',
    (tester) async {
      final active = start('正在制作的游戏');
      final failure = start('需要修复的游戏');
      store.fail(failure.id, 'PRIVATE_URL', failureCode: 'gameRuntimeTimeout');
      final saved = start('已保存的游戏');
      store.complete(saved.id);
      start('其他账号的游戏', scope: 'other-account');
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const Scaffold();
            },
          ),
        ),
      );
      final sheet = showAgentTaskLedger(context);
      await tester.pumpAndSettle();
      expect(find.text('进行中'), findsOneWidget);
      expect(find.text('需要处理'), findsOneWidget);
      await tester.ensureVisible(find.text('需要修复的游戏'));
      await tester.pump();
      expect(find.text('小游戏在运行检查中没有按时显示可玩画面。'), findsOneWidget);
      expect(find.text('其他账号的游戏'), findsNothing);
      expect(find.textContaining('PRIVATE_URL'), findsNothing);
      await tester.ensureVisible(
        find.byKey(ValueKey('task-ledger-row-${saved.taskId}')),
      );
      await tester.pump();
      expect(find.text('已结束'), findsOneWidget);
      expect(find.textContaining('已保存'), findsWidgets);
      expect(find.byType(BackdropFilter), findsNothing);
      Navigator.of(context).pop();
      await tester.pumpAndSettle();
      await sheet;
      store.cancel(active.id);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
