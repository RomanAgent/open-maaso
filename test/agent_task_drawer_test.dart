import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';

void main() {
  late AgentTaskJobStore store;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    store = appServices.put(AgentTaskJobStore());
  });

  tearDown(() async {
    await appServices.reset();
  });

  for (final layout in [
    (size: const Size(375, 812), brightness: Brightness.light, scale: 1.0),
    (size: const Size(320, 760), brightness: Brightness.dark, scale: 2.0),
    (size: const Size(812, 375), brightness: Brightness.light, scale: 1.3),
  ]) {
    testWidgets(
      'chat game process shares the history drawer and covers the bottom at ${layout.size}',
      (tester) async {
        try {
          tester.view.physicalSize = layout.size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.reset);
          final job = store.start(
            agentId: 'self',
            taskKind: AgentTaskKind.gameGeneration,
            userText: '制作一个触屏小游戏',
            appletScopeKey: 'device-legacy',
          );
          final before = job.toJson();
          var composerTaps = 0;
          final rootNavigator = GlobalKey<NavigatorState>();
          final nestedNavigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            MaterialApp(
              navigatorKey: rootNavigator,
              theme: ThemeData(brightness: layout.brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  padding: const EdgeInsets.only(top: 24, bottom: 34),
                  viewPadding: const EdgeInsets.only(top: 24, bottom: 34),
                  textScaler: TextScaler.linear(layout.scale),
                  disableAnimations: true,
                ),
                child: child!,
              ),
              home: Scaffold(
                body: Stack(
                  children: [
                    Positioned.fill(
                      bottom: 120,
                      child: Navigator(
                        key: nestedNavigator,
                        onGenerateRoute: (_) => MaterialPageRoute<void>(
                          builder: (context) => SingleChildScrollView(
                            child: AgentTaskChatCard(
                              reference: store.cardFor(job).taskReference!,
                            ),
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 120,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => composerTaps++,
                        child: const ColoredBox(
                          color: Colors.red,
                          child: Center(child: Text('host composer')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pump();
          final processButton = find.text('home.task.view_process'.tr);
          await tester.ensureVisible(processButton);
          await tester.tap(processButton);
          await tester.pumpAndSettle();

          final process = tester.getRect(find.byType(BottomSheet));
          final processSheet = tester.widget<BottomSheet>(
            find.byType(BottomSheet),
          );
          expect(process.bottom, layout.size.height);
          expect(process.height, lessThan(layout.size.height));
          expect(rootNavigator.currentState!.canPop(), isTrue);
          expect(nestedNavigator.currentState!.canPop(), isFalse);
          expect(
            processSheet.backgroundColor,
            MaasoGlassTheme.of(
              tester.element(find.byType(BottomSheet)),
            ).surface,
          );
          expect(processSheet.backgroundColor!.a, 1);
          // The home-indicator strip is part of the drawer, not the composer.
          await tester.tapAt(
            Offset(layout.size.width / 2, layout.size.height - 4),
          );
          await tester.pump();
          expect(composerTaps, 0);
          expect(find.byType(BottomSheet), findsOneWidget);
          expect(tester.takeException(), isNull);

          await tester.tap(find.byKey(const ValueKey('task-process-history')));
          await tester.pumpAndSettle();
          final history = tester.getRect(find.byType(BottomSheet));
          final historySheet = tester.widget<BottomSheet>(
            find.byType(BottomSheet),
          );
          expect(history, process);
          expect(historySheet.backgroundColor, processSheet.backgroundColor);
          expect(find.text('home.task.history'.tr), findsOneWidget);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(find.byType(UiKitView), findsNothing);

          await tester.tap(
            find.byKey(ValueKey('task-ledger-row-${job.taskId}')),
          );
          await tester.pumpAndSettle();
          expect(tester.getRect(find.byType(BottomSheet)), process);
          await tester.tap(find.text('home.task.collapse'.tr));
          await tester.pumpAndSettle();
          expect(find.byType(BottomSheet), findsNothing);
          expect(rootNavigator.currentState!.canPop(), isFalse);
          expect(store.byId(job.id)!.toJson(), before);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
        }
      },
    );
  }
}
