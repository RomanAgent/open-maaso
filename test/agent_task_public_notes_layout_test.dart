import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';

const _capturePath = String.fromEnvironment('MAASO_TASK_NOTES_PREVIEW_DIR');
const _font = 'MaasoTaskNotesPreview';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (_capturePath.isEmpty) return;
    final file = File('/System/Library/Fonts/Supplemental/Arial Unicode.ttf');
    if (!await file.exists()) {
      throw StateError('Readable preview font unavailable');
    }
    await (FontLoader(_font)..addFont(
          Future.value(ByteData.sublistView(await file.readAsBytes())),
        ))
        .load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      '375px task approach and source completion stay readable at ${scale}x without proof confusion',
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
        final job = store.start(
          agentId: 'self',
          taskKind: AgentTaskKind.gameGeneration,
          userText: '写一个挡板接球、消砖过关、掉落分裂道具的小游戏',
          appletScopeKey: 'device-legacy',
        );
        const approach = '先把接球和消砖连起来，再加入分裂道具与关卡切换，触摸和键盘共用同一套规则。';
        store.recordProgress(
          job.id,
          expectedAttempt: job.attempt,
          stage: AgentTaskStage.generating,
          description: '制作思路',
          details: approach,
        );
        store.recordProgress(
          job.id,
          expectedAttempt: job.attempt,
          stage: AgentTaskStage.generating,
          description: '已写好：挡板接球和消砖碰撞',
          details: '这部分源码已完整接收，接下来继续连接其他部分并检查能否运行。',
          evidence: const [
            AgentTaskEvidence(
              kind: AgentTaskEvidenceKind.artifact,
              outcome: AgentTaskEvidenceOutcome.completed,
              label: '挡板接球和消砖碰撞源码已写好',
            ),
          ],
        );
        final publicNote = store
            .byId(job.id)!
            .progress
            .firstWhere((e) => e.description == '制作思路');
        final written = store.byId(job.id)!.progress.last;
        expect(publicNote.evidence, isEmpty);
        final boundary = GlobalKey();
        final theme = AppTheme.build(
          AppPalette.of(Brightness.light, AppAccent.blue),
        );
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundary,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: _capturePath.isEmpty
                  ? theme
                  : theme.copyWith(
                      textTheme: ThemeData(fontFamily: _font).textTheme,
                      textButtonTheme: TextButtonThemeData(
                        style: theme.textButtonTheme.style!.copyWith(
                          textStyle: WidgetStatePropertyAll(
                            theme.textButtonTheme.style!.textStyle!
                                .resolve({})!
                                .copyWith(fontFamily: _font),
                          ),
                        ),
                      ),
                    ),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 32, 16, 24),
                  child: AgentTaskChatCard(
                    reference: store.cardFor(job).taskReference!,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('生成失败'), findsNothing);
        expect(find.text('已通过'), findsNothing);

        Future<void> capture(String name) async {
          if (_capturePath.isEmpty) return;
          await tester.runAsync(() async {
            final render =
                boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await render.toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            final output = File(
              '$_capturePath/task-notes-$name-${scale.toInt()}x.png',
            );
            await output.parent.create(recursive: true);
            await output.writeAsBytes(bytes!.buffer.asUint8List());
          });
        }

        await capture('card');
        final open = find.text('查看生成过程');
        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        final before = store.byId(job.id);
        Future<void> reveal(Finder target) async {
          if (target.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              target,
              180,
              scrollable: find
                  .descendant(
                    of: find.byType(CustomScrollView),
                    matching: find.byType(Scrollable),
                  )
                  .first,
              maxScrolls: 30,
            );
          }
          await Scrollable.ensureVisible(
            tester.element(target),
            alignment: 0.2,
          );
          await tester.pumpAndSettle();
        }

        final noteToggle = find.byKey(
          ValueKey('task-progress-toggle-${job.id}:${publicNote.sequence}'),
        );
        await reveal(noteToggle);
        await tester.tap(noteToggle);
        await tester.pumpAndSettle();
        expect(find.text(approach), findsOneWidget);
        expect(find.text('已通过'), findsNothing);
        expect(store.byId(job.id), same(before));
        await capture('approach');
        final writtenToggle = find.byKey(
          ValueKey('task-progress-toggle-${job.id}:${written.sequence}'),
        );
        await reveal(writtenToggle);
        await tester.tap(writtenToggle);
        await tester.pumpAndSettle();
        await reveal(find.text('已完成'));
        expect(find.text('已完成'), findsOneWidget);
        expect(find.text('已通过'), findsNothing);
        await reveal(find.text('挡板接球和消砖碰撞源码已写好'));
        expect(find.text('挡板接球和消砖碰撞源码已写好'), findsOneWidget);
        expect(store.byId(job.id)!.status, AgentTaskJobStatus.running);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
        await capture('source-written');
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
