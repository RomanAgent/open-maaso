import 'package:sembast/sembast_memory.dart';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/core/models/chat_attachment.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_composer.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_composer_morph.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_native_text_editor.dart';

import 'helpers/home_native_editor_harness.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Home home;
  late DBService database;
  late HomeNativeEditorHarness native;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-ui-fixture.db',
    );
    appServices.put(database);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_Core());
    home = _Home();
    appServices.put<HomeController>(home);
    native = HomeNativeEditorHarness()..install();
  });
  tearDown(() async {
    native.dispose();
    await appServices.reset();
    await database.close();
  });

  Future<void> mount(
    WidgetTester tester, {
    double scale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(375, 812),
              textScaler: TextScaler.linear(scale),
            ),
            child: Scaffold(
              body: HomeChatInteractionScope(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 347,
                    child: HomeChatComposer(
                      controller: home,
                      hint: 'Say something…',
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
  }

  testWidgets(
    'iOS starts with a dedicated button row and same native editor grows',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mount(tester);
        final nativeState = tester.state(find.byType(HomeNativeTextEditor));
        final shell = tester.getRect(find.byType(HomeComposerMorph));
        final editor = tester.getRect(
          find.byKey(const ValueKey('home-composer-editor')),
        );
        final mic = tester.getRect(
          find.byKey(const ValueKey('home-voice-entry')),
        );
        expect(shell.height, 116);
        expect(editor.bottom, lessThan(mic.top));
        expect(mic.size, const Size(48, 48));
        expect(
          tester.getSize(find.byKey(const ValueKey('home-send'))),
          const Size(48, 48),
        );
        expect(find.byType(TextField), findsNothing);
        await native.enterText(tester, 'line1\nline2\nline3\nline4\nline5 😀');
        await tester.pump();
        expect(
          home.inputController.text,
          'line1\nline2\nline3\nline4\nline5 😀',
        );
        expect(
          tester.getSize(find.byType(HomeComposerMorph)).height,
          greaterThan(shell.height),
        );
        expect(
          tester.state(find.byType(HomeNativeTextEditor)),
          same(nativeState),
        );
        await tester.tap(find.byKey(const ValueKey('home-expand-composer')));
        await tester.pump();
        expect(
          tester.state(find.byType(HomeNativeTextEditor)),
          same(nativeState),
        );
        expect(native.creationCount, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'native editor keeps full width and aligned hint through text and clear',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mount(tester);
        final nativeState = tester.state(find.byType(HomeNativeTextEditor));
        void expectContentWidth(String state) {
          final shell = tester.getRect(find.byType(HomeComposerMorph));
          final editor = tester.getRect(
            find.byKey(const ValueKey('home-composer-editor')),
          );
          expect(editor.width, closeTo(shell.width - 40, .01), reason: state);
          expect(editor.left, closeTo(shell.left + 20, .01), reason: state);
          expect(editor.right, closeTo(shell.right - 20, .01), reason: state);
          expect(
            tester.getRect(find.byType(HomeNativeTextEditor)),
            editor,
            reason: state,
          );
          if (home.inputController.text.isEmpty) {
            expect(
              tester.getTopLeft(find.text('Say something…')).dx,
              closeTo(shell.left + 20, .01),
              reason: state,
            );
          } else {
            expect(find.text('Say something…'), findsNothing, reason: state);
          }
          expect(
            tester.state(find.byType(HomeNativeTextEditor)),
            same(nativeState),
            reason: state,
          );
          expect(native.creationCount, 1, reason: state);
        }

        expectContentWidth('empty draft');
        await native.enterText(tester, 'Text 😀');
        expectContentWidth('typed text');
        await native.enterText(tester, '');
        expectContentWidth('cleared text');
        home.pendingMedia.add(_image('A'));
        await tester.pump();
        await tester.pump();
        expectContentWidth('image with empty text');
        await native.enterText(tester, 'Image and text');
        expectContentWidth('image with typed text');
        await native.enterText(tester, '');
        expectContentWidth('image with cleared text');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'images stay inside composer and boundary keys select then delete',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        home.pendingMedia.addAll([_image('A'), _image('B')]);
        await mount(tester);
        await native.enterText(
          tester,
          '',
          selection: const TextSelection.collapsed(offset: 0),
        );
        final shell = tester.getRect(find.byType(HomeComposerMorph));
        final image = find.byKey(
          ValueKey('home-image-${'b'.padLeft(64, 'b')}'),
        );
        expect(shell.contains(tester.getRect(image).center), isTrue);
        expect(
          find.descendant(of: image, matching: find.byType(IconButton)),
          findsNothing,
        );
        await native.deleteAtBoundary(tester);
        expect(home.pendingMedia.length, 2);
        await native.deleteAtBoundary(tester);
        expect(home.pendingMedia.map((m) => m.attachment.id), [
          'a'.padLeft(64, 'a'),
        ]);
        await native.deleteAtBoundary(tester);
        await native.deleteAtBoundary(tester);
        expect(home.pendingMedia, isEmpty);
        expect(native.creationCount, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'desktop first image selection survives focus and Delete removes it',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        home.pendingMedia.add(_image('A'));
        await mount(tester);
        expect(find.byType(TextField), findsOneWidget);
        expect(home.inputController.selection.isValid, isFalse);
        await tester.tap(find.byKey(ValueKey('home-image-${'a' * 64}')));
        await tester.pumpAndSettle();
        expect(
          tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
          isTrue,
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.delete);
        await tester.pump();
        expect(home.pendingMedia, isEmpty);
        expect(native.creationCount, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets('plus has image, game and applet entries without video', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      await mount(tester);
      await tester.tap(find.byKey(const ValueKey('home-attach-media')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('home-add-image')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-add-game')), findsOneWidget);
      expect(find.byKey(const ValueKey('home-add-applet')), findsOneWidget);
      expect(find.byIcon(Icons.video_library_outlined), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets(
    'outside tap commits and releases native focus without replacing draft/view',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mount(tester);
        await native.enterText(tester, 'Preserve this 😀');
        final interaction = HomeChatInteractionScope.maybeOf(
          tester.element(find.byType(HomeChatComposer)),
        )!;
        expect(interaction.hasFocus, isTrue);
        await tester.tapAt(const Offset(100, 60));
        await tester.pumpAndSettle();
        expect(interaction.hasFocus, isFalse);
        expect(home.inputController.text, 'Preserve this 😀');
        expect(native.creationCount, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'native IME blur after an outside tap does not reveal dismissed chat',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mount(tester);
        await native.enterText(
          tester,
          '正在输入中文',
          composing: const TextRange(start: 0, end: 6),
        );
        final interaction = HomeChatInteractionScope.maybeOf(
          tester.element(find.byType(HomeChatComposer)),
        )!;
        expect(interaction.hasFocus, isTrue);
        expect(home.inputController.value.composing, isNot(TextRange.empty));
        final activityBeforeDismiss = interaction.activityToken;

        // The real bridge receives the blur's same-text, cleared-composition
        // snapshot after the outside pointer has already dismissed the chat.
        await tester.tapAt(const Offset(100, 60));
        await tester.pumpAndSettle();

        expect(interaction.hasFocus, isFalse);
        expect(home.inputController.text, '正在输入中文');
        expect(home.inputController.value.composing, TextRange.empty);
        expect(interaction.activityToken, activityBeforeDismiss);
        expect(interaction.resumeAfterSuppression, isFalse);
        expect(native.creationCount, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'dark scaled editor retains its platform view and measured footprint',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      try {
        await mount(tester);
        final state = tester.state(find.byType(HomeNativeTextEditor));
        await native.enterText(tester, 'Keep 😀');
        await mount(tester, scale: 2, brightness: Brightness.dark);
        expect(tester.state(find.byType(HomeNativeTextEditor)), same(state));
        expect(home.inputController.text, 'Keep 😀');
        final interaction = HomeChatInteractionScope.maybeOf(
          tester.element(find.byType(HomeChatComposer)),
        )!;
        expect(
          interaction.composerExtent,
          tester.getSize(find.byType(HomeComposerMorph)).height,
        );
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );
}

PreparedChatMedia _image(String id) => PreparedChatMedia(
  ChatAttachment(
    id: id.toLowerCase().padLeft(64, id.toLowerCase()),
    kind: 'image',
    byteLength: 1,
  ),
  Uint8List(1),
  'image/jpeg',
);

class _Home extends HomeController {
  @override // ignore: must_call_super
  void onInit() {}
}

class _Core extends AgentCoreController {
  @override // ignore: must_call_super
  void onInit() {}
}
