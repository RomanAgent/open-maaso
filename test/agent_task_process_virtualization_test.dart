import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';

void main() {
  testWidgets(
    '1000 actual journal rows across attempts build lazily and retain expanded state',
    (tester) async {
      await appServices.reset();
      appServices.testMode = true;
      AppLocalization.updateLocale(const Locale('zh', 'CN'));
      addTearDown(appServices.reset);
      tester.view.physicalSize = const Size(375, 760);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = appServices.put(AgentTaskJobStore());
      final root = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '长项目真实步骤测试',
        appletScopeKey: 'device-legacy',
      );
      List<AgentTaskProgress> entries(int attempt) => List.generate(
        100,
        (index) => AgentTaskProgress(
          sequence: index + 1,
          stage: AgentTaskStage.validating,
          at: DateTime.utc(2026, 9, 28, 0, attempt, index),
          description: '已记录步骤 ${attempt * 100 + index}',
          details: '公开工具摘要 ${attempt * 100 + index}',
        ),
      );
      store.jobs[0] = root.copyWith(
        status: AgentTaskJobStatus.failed,
        stage: AgentTaskStage.failed,
        progress: entries(0),
      );
      for (var attempt = 1; attempt < 10; attempt++) {
        store.jobs.add(
          AgentTaskJob(
            id: 'job_process_$attempt',
            agentId: root.agentId,
            taskKind: root.taskKind,
            userText: root.userText,
            status: attempt == 9
                ? AgentTaskJobStatus.completed
                : AgentTaskJobStatus.failed,
            stage: attempt == 9
                ? AgentTaskStage.completed
                : AgentTaskStage.failed,
            createdAt: root.createdAt,
            appletScopeKey: root.appletScopeKey,
            attempt: attempt + 1,
            parentJobId: root.id,
            progress: entries(attempt),
          ),
        );
      }
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentTaskChatCard(
              reference: store.cardFor(root).taskReference!,
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看生成过程'));
      await tester.pumpAndSettle();
      final nodes = find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_AgentTaskProgressNode',
      );
      expect(nodes.evaluate().length, lessThan(30));
      expect(find.text('已记录步骤 999'), findsNothing);
      await tester.tap(
        find.byKey(ValueKey('task-progress-toggle-${root.id}:1')),
      );
      await tester.pumpAndSettle();
      expect(find.text('公开工具摘要 0'), findsOneWidget);
      final scroll = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      for (
        var attempt = 0;
        attempt < 10 && find.text('已记录步骤 999').evaluate().isEmpty;
        attempt++
      ) {
        scroll.position.jumpTo(scroll.position.maxScrollExtent);
        await tester.pump();
      }
      expect(find.text('已记录步骤 999'), findsOneWidget);
      expect(nodes.evaluate().length, lessThan(30));
      scroll.position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(
        find.text('公开工具摘要 0'),
        findsOneWidget,
        reason: 'virtualization must not discard the user expansion choice',
      );
      final before = scroll.position.pixels, last = store.jobs.last;
      store.jobs[store.jobs.length - 1] = last.copyWith(
        progress: [
          ...last.progress,
          AgentTaskProgress(
            sequence: 101,
            stage: AgentTaskStage.completed,
            at: DateTime.now(),
            description: '新的公开完成回执',
          ),
        ],
      );
      await tester.pump();
      expect(scroll.position.pixels, before);
      expect(find.text('公开工具摘要 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('收起'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
