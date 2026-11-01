import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';

void main() {
  late AgentTaskJobStore store;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    store = appServices.put(AgentTaskJobStore());
  });
  tearDown(() => appServices.reset());

  AgentTaskJob start({String scope = 'device-legacy'}) => store.start(
    agentId: 'self',
    taskKind: AgentTaskKind.surfaceGeneration,
    userText: '创建一个长标题时钟小程序，支持手机触控',
    appletScopeKey: scope,
  );

  Future<void> mount(
    WidgetTester tester,
    AgentTaskJob job, {
    double scale = 1,
    Brightness brightness = Brightness.light,
    double width = 375,
    bool expanded = false,
    ScrollController? scrollController,
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
            padding: const EdgeInsets.only(top: 32, bottom: 24),
            textScaler: TextScaler.linear(scale),
          ),
          child: Scaffold(
            body: SingleChildScrollView(
              controller: scrollController,
              child: expanded
                  ? AgentTaskChatCard(
                      reference: store.cardFor(job).taskReference!,
                      expanded: true,
                    )
                  : MessageBubble(message: store.cardFor(job)),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('one message card updates in place through failure and retry', (
    tester,
  ) async {
    final first = start();
    await mount(tester, first);
    expect(find.byKey(ValueKey('task-card-${first.id}')), findsOneWidget);
    store.fail(first.id, 'SECRET_RAW_TOOL_LOG');
    await tester.pump();
    expect(find.text('SECRET_RAW_TOOL_LOG'), findsNothing);
    expect(find.text('重试'), findsOneWidget);
    final second = store.retry(first.id);
    await tester.pump();
    expect(find.byKey(ValueKey('task-card-${first.id}')), findsOneWidget);
    expect(find.byKey(ValueKey('task-card-${second.id}')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final language in ['zh', 'en']) {
    testWidgets('failed local game offers continuation in $language', (
      tester,
    ) async {
      AppLocalization.updateLocale(Locale(language));
      final game = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.gameGeneration,
        userText: '创建一个点按计分小游戏',
        appletScopeKey: 'device-legacy',
      );
      store.fail(game.id, 'model_unavailable');
      await mount(tester, game, width: 320, scale: 1.3);
      expect(
        find.text(language == 'zh' ? '继续生成' : 'Continue generating'),
        findsOneWidget,
      );
      expect(find.text(language == 'zh' ? '重试' : 'Retry'), findsNothing);
      expect(store.jobs, hasLength(1));
      expect(store.jobs.single.status, AgentTaskJobStatus.failed);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'cancelled local generation reuses the existing explicit retry action',
    (tester) async {
      final first = start();
      store.cancel(first.id);
      await mount(tester, first);
      expect(find.text('重试'), findsOneWidget);
      expect(
        store.jobs,
        hasLength(1),
        reason: 'showing a card must not resume work',
      );
      expect(store.byId(first.id)!.status, AgentTaskJobStatus.cancelled);
      final next = store.retry(first.id);
      await tester.pump();
      expect(next.taskId, first.taskId);
      expect(find.byKey(ValueKey('task-card-${first.id}')), findsOneWidget);
      expect(find.text('重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('cancelled local skill tasks do not gain a retry action', (
    tester,
  ) async {
    final job = store.start(
      agentId: 'self',
      taskKind: AgentTaskKind.skillTask,
      userText: '执行技能',
      appletScopeKey: 'device-legacy',
    );
    store.cancel(job.id);
    await mount(tester, job);
    expect(find.text('重试'), findsNothing);
    expect(store.jobs, hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('collapsing progress does not cancel a waiting preview', (
    tester,
  ) async {
    final job = start();
    final preview = store.awaitPreview(job.id);
    await mount(tester, job);
    await tester.tap(find.text('查看生成过程'));
    await tester.pumpAndSettle();
    expect(find.text('收起'), findsOneWidget);
    expect(find.text('预览作品'), findsWidgets);
    await tester.tap(find.text('收起'));
    await tester.pumpAndSettle();
    expect(store.byId(job.id)?.stage, AgentTaskStage.previewReady);
    store.cancel(job.id);
    expect(await preview, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('public step details expand without changing task state', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final job = start();
    store.recordProgress(
      job.id,
      expectedAttempt: job.attempt,
      stage: AgentTaskStage.validating,
      description: '检查详情页返回与保存',
      details: '依次打开清单、详情页，返回后确认已保存的数据仍然存在。',
      evidence: const [
        AgentTaskEvidence(
          kind: AgentTaskEvidenceKind.validation,
          outcome: AgentTaskEvidenceOutcome.passed,
          label: '页面返回和数据恢复',
          count: 2,
          reference: 'check_navigation_1',
        ),
      ],
    );
    final progress = store.byId(job.id)!.progress.last;
    final toggle = find.byKey(
      ValueKey('task-progress-toggle-${job.id}:${progress.sequence}'),
    );
    await mount(tester, job);
    expect(find.text(progress.description), findsOneWidget);
    expect(find.text(progress.details), findsNothing);
    await tester.tap(find.text('查看生成过程'));
    await tester.pumpAndSettle();
    expect(find.text(progress.details), findsNothing);
    expect(
      tester
          .getSemantics(toggle)
          .getSemanticsData()
          .flagsCollection
          .isExpanded
          .toBoolOrNull(),
      isFalse,
    );
    expect(tester.getSize(toggle).height, greaterThanOrEqualTo(48));
    final stateBefore = store.byId(job.id);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text(progress.details), findsOneWidget);
    expect(find.text('页面返回和数据恢复'), findsOneWidget);
    expect(find.text('已通过 · 2 项'), findsOneWidget);
    expect(find.text('check_navigation_1'), findsNothing);
    expect(
      tester
          .getSemantics(toggle)
          .getSemanticsData()
          .flagsCollection
          .isExpanded
          .toBoolOrNull(),
      isTrue,
    );
    expect(store.byId(job.id), same(stateBefore));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(UiKitView), findsNothing);
    await tester.tap(toggle);
    await tester.pump();
    expect(find.text(progress.details), findsNothing);
    expect(store.byId(job.id), same(stateBefore));
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('legacy stages stay readable without invented step details', (
    tester,
  ) async {
    final job = start();
    store.fail(job.id, 'SECRET_RAW_TOOL_LOG');
    await mount(tester, job, expanded: true);
    final progress = store.byId(job.id)!.progress;
    for (final event in progress) {
      expect(find.text(taskStageLabel(event.stage)), findsOneWidget);
      expect(
        find.byKey(
          ValueKey('task-progress-toggle-${job.id}:${event.sequence}'),
        ),
        findsNothing,
      );
    }
    expect(find.text('SECRET_RAW_TOOL_LOG'), findsNothing);
    expect(find.text('已通过'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('appending a step preserves expanded content, focus and scroll', (
    tester,
  ) async {
    final job = start();
    for (var i = 0; i < 14; i++) {
      store.recordProgress(
        job.id,
        expectedAttempt: job.attempt,
        stage: AgentTaskStage.generating,
        description: '制作页面 $i',
        details: '页面 $i 的公开执行记录。',
      );
    }
    final first = store
        .byId(job.id)!
        .progress
        .firstWhere((event) => event.description == '制作页面 0');
    final toggle = find.byKey(
      ValueKey('task-progress-toggle-${job.id}:${first.sequence}'),
    );
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await mount(tester, job, expanded: true, scrollController: scroll);
    await tester.tap(toggle);
    await tester.pump();
    final focus = Focus.of(
      tester.element(
        find.descendant(of: toggle, matching: find.byType(Text)).first,
      ),
    );
    focus.requestFocus();
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, same(focus));
    scroll.jumpTo(100);
    await tester.pump();
    final position = scroll.offset;
    store.recordProgress(
      job.id,
      expectedAttempt: job.attempt,
      stage: AgentTaskStage.generating,
      description: '制作最后一页',
      details: '追加的真实步骤。',
    );
    await tester.pump();
    expect(find.text(first.details), findsOneWidget);
    expect(find.text('追加的真实步骤。'), findsNothing);
    expect(FocusManager.instance.primaryFocus, same(focus));
    expect(scroll.offset, position);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('retry keeps separate stable expansion for each attempt', (
    tester,
  ) async {
    final first = start();
    store.recordProgress(
      first.id,
      expectedAttempt: first.attempt,
      stage: AgentTaskStage.validating,
      description: '首次检查',
      details: '返回后页面状态丢失。',
    );
    final oldEvent = store.byId(first.id)!.progress.last;
    await mount(tester, first, expanded: true);
    final oldToggle = find.byKey(
      ValueKey('task-progress-toggle-${first.id}:${oldEvent.sequence}'),
    );
    await tester.tap(oldToggle);
    await tester.pump();
    store.fail(first.id, 'internal error');
    final retry = store.retry(first.id);
    store.recordProgress(
      retry.id,
      expectedAttempt: retry.attempt,
      stage: AgentTaskStage.validating,
      description: '重试检查',
      details: '修复后的新检查记录。',
    );
    await tester.pump();
    expect(find.text(oldEvent.details), findsOneWidget);
    expect(find.text('修复后的新检查记录。'), findsNothing);
    expect(find.text('重试检查'), findsOneWidget);
    expect(find.byKey(ValueKey('task-card-${first.id}')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final brightness in Brightness.values) {
    testWidgets('compact card and process fit large text in $brightness', (
      tester,
    ) async {
      final job = start();
      store.fail(job.id, 'failure');
      await mount(tester, job, scale: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看生成过程'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('rich process fits a narrow 2x text $brightness screen', (
      tester,
    ) async {
      final job = start();
      store.recordProgress(
        job.id,
        expectedAttempt: job.attempt,
        stage: AgentTaskStage.validating,
        description: '正在检查二级详情页面的返回导航与长标题列表的数据保存',
        details: '打开详情并编辑长标题，保存后回到列表，再次打开详情核对内容。',
        evidence: const [
          AgentTaskEvidence(
            kind: AgentTaskEvidenceKind.validation,
            outcome: AgentTaskEvidenceOutcome.failed,
            label: '返回导航中已提交数据的恢复检查',
            count: 12,
          ),
        ],
      );
      final event = store.byId(job.id)!.progress.last;
      store.fail(job.id, 'not public');
      await mount(tester, job, width: 320, scale: 2, brightness: brightness);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('查看生成过程'));
      await tester.pumpAndSettle();
      final toggle = find.byKey(
        ValueKey('task-progress-toggle-${job.id}:${event.sequence}'),
      );
      await tester.ensureVisible(toggle);
      final processScroll = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(Scrollable),
      );
      final visibleToggle = tester
          .getRect(toggle)
          .intersect(tester.getRect(processScroll));
      expect(visibleToggle.height, greaterThanOrEqualTo(48));
      await tester.tapAt(visibleToggle.center);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text(event.details),
        120,
        scrollable: processScroll,
      );
      expect(find.text(event.details), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('未通过 · 12 项'),
        120,
        scrollable: processScroll,
      );
      expect(find.text('未通过 · 12 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('foreign task reference has no title or actions', (tester) async {
    final job = start(scope: 'other-account');
    await mount(tester, job);
    expect(find.text(job.userText), findsNothing);
    expect(find.text('该任务当前不可用'), findsOneWidget);
    expect(find.byType(TextButton), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'completed card can remain mounted without a pending periodic timer',
    (tester) async {
      final job = start();
      await mount(tester, job);
      store.complete(job.id);
      await tester.pump();
      expect(find.textContaining('已保存'), findsOneWidget);
      // Leave the card mounted: flutter_test checks pending timers at test end.
      // An always-running timer on a historical card fails that invariant.
    },
  );

  testWidgets('hidden active card does not schedule a clock', (tester) async {
    final job = start();
    await tester.pumpWidget(
      MaterialApp(
        home: TickerMode(
          enabled: false,
          child: Scaffold(body: MessageBubble(message: store.cardFor(job))),
        ),
      ),
    );
    expect(find.text(job.userText), findsOneWidget);
    // Also intentionally leave this inactive route subtree mounted.
  });

  testWidgets('an idle-faded Home card does not schedule a clock', (
    tester,
  ) async {
    final job = start();
    await tester.pumpWidget(
      MaterialApp(
        home: ChatWindowVisibilityScope(
          visible: false,
          child: Scaffold(body: MessageBubble(message: store.cardFor(job))),
        ),
      ),
    );
    expect(find.text(job.userText), findsOneWidget);
    // Home's idle fade leaves ticker mode enabled, so its own scope must gate.
  });

  testWidgets(
    'chat task process keeps scoped history reachable with one sheet and normal back',
    (tester) async {
      final older = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '此前生成的相册',
        appletScopeKey: 'device-legacy',
      );
      store.fail(older.id, 'failure');
      store.fail(store.retry(older.id).id, 'failure');
      final foreign = store.start(
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '其他账号的任务',
        appletScopeKey: 'foreign-account',
      );
      store.fail(foreign.id, 'failure');
      final current = start();
      store.fail(current.id, 'failure');
      final before = store.jobs.map((job) => job.toJson()).toList();
      await mount(
        tester,
        current,
        width: 320,
        scale: 2,
        brightness: Brightness.dark,
      );
      await tester.tap(find.text('home.task.view_process'.tr));
      await tester.pumpAndSettle();
      final history = find.byKey(const ValueKey('task-process-history'));
      expect(history, findsOneWidget);
      expect(find.byTooltip('home.task.history'.tr), findsOneWidget);
      expect(tester.getSize(history).width, greaterThanOrEqualTo(48));
      expect(tester.getSize(history).height, greaterThanOrEqualTo(48));
      await tester.tap(history);
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(find.text('home.task.history'.tr), findsOneWidget);
      expect(find.text(older.userText), findsOneWidget);
      expect(find.text(foreign.userText), findsNothing);
      await tester.tap(find.text(older.userText));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(
        find.byKey(const ValueKey('task-process-history')),
        findsOneWidget,
      );
      expect(find.text(older.userText), findsOneWidget);
      await tester.tap(find.text('home.task.collapse'.tr));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.text(current.userText), findsOneWidget);
      expect(store.jobs.map((job) => job.toJson()).toList(), before);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'task ledger deduplicates attempts and keeps older failures reachable',
    (tester) async {
      final first = start();
      store.fail(first.id, 'failure');
      store.fail(store.retry(first.id).id, 'failure');
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAgentTaskLedger(context),
                child: const Text('ledger'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('ledger'));
      await tester.pumpAndSettle();
      expect(find.text(first.userText), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
