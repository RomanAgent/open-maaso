import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/agent/presentation/project_build_task_issue.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_task_binding.dart';

void main() {
  late AgentTaskJobStore store;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    store = appServices.put(AgentTaskJobStore());
  });
  tearDown(() => appServices.reset());
  AgentTaskJob job({String syncIssue = '', bool visionFailed = false}) {
    var value = store.startProjectBuildV2(
      agentId: 'self',
      userText: '参考图片作品',
      appletScopeKey: 'device-legacy',
      projectKind: ProjectBuildKind.applet,
      binding: ProjectBuildV2TaskBinding(
        scopeKey: 'test|owner',
        createRequestId: 'reference_task_001',
        syncIssue: syncIssue,
        pendingCommand: ProjectBuildV2TaskPendingCommand(
          operation: ProjectBuildV2TaskOperation.create,
          requestId: 'reference_task_001',
        ),
      ),
    );
    if (visionFailed) {
      final fixture = projectBuildV2Object(
        jsonDecode(
          File('tool/fixtures/project_build_wire_v2.json').readAsStringSync(),
        ),
      );
      final events =
          (projectBuildV2Object(fixture['eventsPage'])['events']! as List)
              .map(projectBuildV2Object)
              .toList();
      value = store.updateProjectBuildV2Binding(
        value.id,
        value.projectBuildV2!.copyWith(
          taskId: events.first['taskId']! as String,
        ),
        expectedScopeKey: 'device-legacy',
      );
      for (final event in events.take(2)) {
        value = store.applyProjectBuildV2Event(
          value.taskId,
          ProjectBuildV2Event.fromJson(event),
          expectedScopeKey: 'device-legacy',
          agentId: 'self',
        );
      }
      final failed = {
        ...events[2],
        'type': 'run.failed',
        'snapshot': {
          ...projectBuildV2Object(events[2]['snapshot'])..remove('candidate'),
          'status': 'failed',
          'errorCode': 'vision_unsupported',
        },
      };
      value = store.applyProjectBuildV2Event(
        value.taskId,
        ProjectBuildV2Event.fromJson(failed),
        expectedScopeKey: 'device-legacy',
        agentId: 'self',
      );
    }
    return value;
  }

  Future<void> mount(WidgetTester tester, AgentTaskJob job) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
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
  }

  test(
    'only fixed public keys are returned; unknown provider text stays generic',
    () {
      expect(
        projectBuildV2TaskIssueMessageKey(
          syncIssue: 'rejected:reference_input_missing',
        ),
        'project_build.task.reference_input_missing',
      );
      expect(
        projectBuildV2TaskIssueMessageKey(
          syncIssue: 'reference_upload_unavailable',
        ),
        'project_build.task.reference_upload_unavailable',
      );
      expect(
        projectBuildV2TaskIssueMessageKey(
          syncIssue: '',
          snapshotErrorCode: 'vision_unsupported',
        ),
        'project_build.task.vision_unsupported',
      );
      expect(
        projectBuildV2TaskIssueMessageKey(syncIssue: 'raw_provider_secret_123'),
        'project_build.task.sync_pending',
      );
      expect(
        projectBuildV2TaskIssueMessageKey(
          syncIssue: 'rejected:raw_provider_secret_123',
        ),
        'project_build.task.request_rejected',
      );
      expect(
        projectBuildV2TaskIssueMessageKey(
          syncIssue: '',
          snapshotErrorCode: 'raw_provider_secret_123',
        ),
        isNull,
      );
    },
  );
  for (final issue in [
    'reference_input_missing',
    'rejected:reference_input_missing',
    'reference_upload_unavailable',
  ]) {
    testWidgets(
      'reference issue $issue is explicit without fabricated progress',
      (tester) async {
        final value = job(syncIssue: issue);
        await mount(tester, value);
        expect(
          find.text(
            issue.contains('input_missing')
                ? '参考图片在此设备不可用，请重新选择图片发起制作。'
                : '参考图片上传暂不可用，原任务已保留。',
          ),
          findsOneWidget,
        );
        expect(value.projectBuildV2!.snapshot, isNull);
        expect(value.projectBuildV2!.nodes, isEmpty);
        expect(find.text(issue), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'verified lifecycle failure displays image capability reason without raw provider code',
    (tester) async {
      final value = job(visionFailed: true);
      await mount(tester, value);
      expect(find.text('参考图片生成暂不可用，原任务已保留。'), findsOneWidget);
      expect(find.text('vision_unsupported'), findsNothing);
      expect(value.status, AgentTaskJobStatus.failed);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('unknown provider code never becomes visible prose', (
    tester,
  ) async {
    await mount(tester, job(syncIssue: 'rejected:provider_secret_abc'));
    expect(find.textContaining('provider_secret'), findsNothing);
    expect(find.text('这次请求未被接受，已保留原有进度。'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
