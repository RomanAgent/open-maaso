import 'dart:io';
import 'package:image/image.dart' as image;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'support/creator_task_harness.dart';

void main() {
  late CreatorTaskHarness h;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    h = CreatorTaskHarness();
    await h.init();
    await h.start();
  });
  tearDown(() => h.close());
  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            padding: EdgeInsets.only(top: 32, bottom: 24),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: SafeArea(
              child: SingleChildScrollView(
                child: AgentTaskChatCard(
                  reference: h.jobs.cardFor(h.latest).taskReference!,
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
    'server cancel and cancelled retry work without a local runtime',
    (tester) async {
      expect(appServices.isRegistered<AgentRuntimeRegistry>(), isFalse);
      await mount(tester);
      expect(find.textContaining('图片任务已排队'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('取消'));
        for (
          var i = 0;
          i < 100 &&
              h.latest.serverImage!.snapshot!.status !=
                  CreatorTaskStatus.cancelled;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(
        h.latest.serverImage!.snapshot!.status,
        CreatorTaskStatus.cancelled,
      );
      expect(find.text('重试'), findsOneWidget);
      // The cancellation snapshot can arrive before the control receipt has
      // finished its persistence flush. Only tap once the user can retry.
      final retry = find.widgetWithText(TextButton, '重试');
      for (
        var i = 0;
        i < 100 && tester.widget<TextButton>(retry).onPressed == null;
        i++
      ) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        await tester.pump();
      }
      expect(tester.widget<TextButton>(retry).onPressed, isNotNull);
      await tester.runAsync(() async {
        await tester.tap(find.text('重试'));
        for (var i = 0; i < 100 && h.latest.attempt != 2; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(h.latest.attempt, 2);
      expect(h.server.commands, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets(
    'actual image frame enables explicit use; opening preview alone never applies',
    (tester) async {
      final directory = await tester.runAsync(
        () => Directory.systemTemp.createTemp('creator-preview-ui-'),
      );
      addTearDown(() async {
        if (directory != null) await directory.delete(recursive: true);
      });
      h.assets.localPath = '${directory!.path}/image.png';
      await tester.runAsync(() async {
        await File(
          h.assets.localPath,
        ).writeAsBytes(image.encodePng(image.Image(width: 2, height: 2)));
        await h.finish();
      });
      await mount(tester);
      await tester.runAsync(() async {
        await tester.tap(find.text('预览作品'));
        for (
          var i = 0;
          i < 100 && h.latest.serverImage!.previewAsset == null;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      for (var i = 0; i < 100; i++) {
        await tester.pump();
        final button = find.widgetWithText(FilledButton, '用于这份草稿');
        if (button.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(button).onPressed != null) {
          break;
        }
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(find.byType(Image), findsOneWidget);
      expect(h.latest.serverImage!.applied, isFalse);
      final apply = find.widgetWithText(FilledButton, '用于这份草稿');
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      await tester.runAsync(() async {
        await tester.tap(apply);
        for (var i = 0; i < 100 && !h.latest.serverImage!.applied; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(h.latest.serverImage!.applied, isTrue);
      expect(
        h.server.requests.any(
          (request) => request.url.path.contains('publish'),
        ),
        isFalse,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'large text process uses actual image stages and completion is not applied',
    (tester) async {
      await tester.runAsync(h.finish);
      await mount(tester);
      expect(find.textContaining('图片已生成，等待预览使用'), findsOneWidget);
      expect(find.textContaining('已完成并保存'), findsNothing);
      await tester.tap(find.text('查看生成过程'));
      await tester.pumpAndSettle();
      expect(find.text('服务器正在生成图片'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(h.latest.serverImage!.applied, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
