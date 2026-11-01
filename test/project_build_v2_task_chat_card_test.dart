import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';
import 'support/project_build_v2_fixtures.dart';

class _Controls implements AgentServerTaskControls {
  _Controls(this.kind);
  final AgentTaskExecutionKind kind;
  final calls = <String>[];
  bool enabled = true;
  @override
  bool canControl(AgentTaskJob job, {required bool retry}) =>
      enabled &&
      job.executionKind == kind &&
      (retry ? job.status == AgentTaskJobStatus.failed : job.isActive);
  @override
  Future<bool> cancel(String jobId, {required int expectedAttempt}) async {
    calls.add('cancel:$jobId:$expectedAttempt');
    return true;
  }

  @override
  Future<bool> retry(String jobId, {required int expectedAttempt}) async {
    calls.add('retry:$jobId:$expectedAttempt');
    return true;
  }
}

void main() {
  late AgentTaskJobStore store;
  late _Controls imageControls;
  late _Controls projectControls;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    store = appServices.put(AgentTaskJobStore());
    imageControls = _Controls(AgentTaskExecutionKind.creatorImage);
    projectControls = _Controls(AgentTaskExecutionKind.projectBuildV2);
    store.serverControls = imageControls;
    store.registerControls(
      AgentTaskExecutionKind.projectBuildV2,
      projectControls,
    );
  });
  tearDown(() => appServices.reset());

  AgentTaskJob queued() {
    final input = projectBuildV2Input();
    final job = store.startProjectBuildV2(
      agentId: input.agentId,
      userText: input.requirements,
      appletScopeKey: 'device-legacy',
      projectKind: input.projectKind,
      binding: ProjectBuildV2TaskBinding(
        scopeKey: projectBuildV2TestScope,
        createRequestId: input.requestId,
        pendingCommand: ProjectBuildV2TaskPendingCommand(
          operation: ProjectBuildV2TaskOperation.create,
          requestId: input.requestId,
        ),
      ),
    );
    store.updateProjectBuildV2Binding(
      job.id,
      job.projectBuildV2!.copyWith(taskId: projectBuildV2Receipt().taskId),
      expectedScopeKey: 'device-legacy',
    );
    return store.applyProjectBuildV2Event(
      job.id,
      ProjectBuildV2Event.fromJson(projectBuildV2Events().first),
      expectedScopeKey: 'device-legacy',
      agentId: input.agentId,
    );
  }

  Future<void> mount(
    WidgetTester tester,
    AgentTaskJob job, {
    bool expanded = false,
    double width = 375,
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = Size(width, 760);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 760),
            textScaler: TextScaler.linear(scale),
            disableAnimations: true,
            padding: const EdgeInsets.only(top: 32, bottom: 24),
          ),
          child: Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                child: AgentTaskChatCard(
                  reference: store.cardFor(job).taskReference!,
                  expanded: expanded,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'project controls never dispatch to image controls or local runtime',
    (tester) async {
      final job = queued();
      await mount(tester, job);
      expect(find.textContaining('项目任务已排队'), findsOneWidget);
      expect(find.textContaining('图片'), findsNothing);
      expect(find.text('预览作品'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pump();
      expect(projectControls.calls, ['cancel:${job.id}:1']);
      expect(imageControls.calls, isEmpty);
      for (final raw in projectBuildV2Events().skip(1)) {
        store.applyProjectBuildV2Event(
          job.taskId,
          ProjectBuildV2Event.fromJson(raw),
          expectedScopeKey: 'device-legacy',
          agentId: job.agentId,
        );
      }
      await tester.pump();
      expect(find.textContaining('生成失败'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      expect(projectControls.calls.last, 'retry:${job.id}:1');
      expect(imageControls.calls, isEmpty);
      expect(find.textContaining('已完成并保存'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'recovering and rejected requests display safe feedback without raw errors',
    (tester) async {
      final job = queued();
      store.updateProjectBuildV2Binding(
        job.id,
        store
            .byId(job.id)!
            .projectBuildV2!
            .copyWith(syncIssue: 'rejected:PRIVATE_TOKEN'),
        expectedScopeKey: 'device-legacy',
      );
      projectControls.enabled = false;
      await mount(tester, job);
      expect(find.text('这次请求未被接受，已保留原有进度。'), findsOneWidget);
      expect(find.textContaining('PRIVATE_TOKEN'), findsNothing);
      expect(find.text('取消'), findsNothing);
      store.updateProjectBuildV2Binding(
        job.id,
        store
            .byId(job.id)!
            .projectBuildV2!
            .copyWith(syncIssue: 'needs_authorization'),
        expectedScopeKey: 'device-legacy',
      );
      await tester.pump();
      expect(find.text('当前无法继续提交请求，已保留需求和进度。'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets(
      'actual attempt history stays readable at 320px / 2x / $brightness',
      (tester) async {
        final job = queued();
        for (final raw in [
          ...projectBuildV2Events().skip(1),
          projectBuildV2RetryEvent(),
        ]) {
          store.applyProjectBuildV2Event(
            job.taskId,
            ProjectBuildV2Event.fromJson(raw),
            expectedScopeKey: 'device-legacy',
            agentId: job.agentId,
          );
        }
        await mount(
          tester,
          job,
          expanded: true,
          width: 320,
          scale: 2,
          brightness: brightness,
        );
        expect(find.text('服务器已接收需求，等待执行'), findsOneWidget);
        expect(find.text('本次执行未完成'), findsOneWidget);
        expect(find.text('已开始新的尝试，等待执行'), findsOneWidget);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(find.byType(UiKitView), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
