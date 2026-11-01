import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/chat/presentation/u2a_chat_page.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_history_edge.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_thinking_bubble.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() async => appServices.reset());

  for (final brightness in Brightness.values) {
    testWidgets(
      'assistant and user messages wrap inside a narrow $brightness window',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(brightness: brightness),
            home: MediaQuery(
              data: MediaQueryData(
                size: const Size(320, 700),
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topRight,
                  child: SizedBox(
                    width: 218,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        MessageBubble(message: _message('你好', user: true)),
                        MessageBubble(
                          message: _message('这一段比较长的回复应该在消息区域内换行。'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final user = find.widgetWithText(MessageBubble, '你好');
        final agent = find.widgetWithText(
          MessageBubble,
          '这一段比较长的回复应该在消息区域内换行。',
        );
        final userSurface = find.descendant(
          of: user,
          matching: find.byType(AppGlassSurface),
        );
        final agentSurface = find.descendant(
          of: agent,
          matching: find.byType(AppGlassSurface),
        );
        final userMaterial = tester.widget<AppGlassSurface>(userSurface);
        final agentMaterial = tester.widget<AppGlassSurface>(agentSurface);
        expect(userMaterial.role, AppGlassSurfaceRole.message);
        expect(agentMaterial.role, AppGlassSurfaceRole.message);
        expect(userMaterial.tintColor!.a, closeTo(.96, .005));
        expect(agentMaterial.tintColor!.a, closeTo(.82, .005));
        expect(tester.getRect(userSurface).right, closeTo(800, 1));
        expect(tester.getRect(agentSurface).width, lessThanOrEqualTo(218));
        final userForeground = brightness == Brightness.dark
            ? MaasoFrostTokens.darkOnUserMessage
            : MaasoFrostTokens.lightOnUserMessage;
        expect(
          tester.widget<Text>(find.text('你好')).style!.color,
          userForeground,
        );
        // Include the translucent fill over a contrasting scene rather than
        // checking only the opaque design token.
        final composite = Color.alphaBlend(
          userMaterial.tintColor!,
          brightness == Brightness.dark ? Colors.black : Colors.white,
        );
        final foregroundLuminance = userForeground.computeLuminance();
        final userBackgroundLuminance = composite.computeLuminance();
        final contrast = foregroundLuminance > userBackgroundLuminance
            ? (foregroundLuminance + .05) / (userBackgroundLuminance + .05)
            : (userBackgroundLuminance + .05) / (foregroundLuminance + .05);
        expect(contrast, greaterThanOrEqualTo(4.5));
        final agentContext = tester.element(agentSurface);
        final glass = MaasoGlassTheme.of(agentContext);
        final worstBackdrop = brightness == Brightness.light
            ? Colors.black
            : Colors.white;
        final agentComposite = Color.alphaBlend(
          agentMaterial.tintColor!,
          worstBackdrop,
        );
        final labelLuminance = messageSecondaryForeground(
          glass,
        ).computeLuminance();
        final backgroundLuminance = agentComposite.computeLuminance();
        final agentContrast = brightness == Brightness.light
            ? (backgroundLuminance + .05) / (labelLuminance + .05)
            : (labelLuminance + .05) / (backgroundLuminance + .05);
        expect(agentContrast, greaterThanOrEqualTo(4.5));
        expect(find.byType(BackdropFilter), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'edge softens only departing Flutter content and preserves a single tappable row',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 260,
              height: 240,
              child: ChatHistoryEdge(
                child: ListView(
                  controller: scroll,
                  addRepaintBoundaries: false,
                  children: [
                    ChatHistoryEdgeItem(
                      child: SizedBox(
                        height: 80,
                        child: TextButton(
                          onPressed: () => presses++,
                          child: const Text('older'),
                        ),
                      ),
                    ),
                    const ChatHistoryEdgeItem(
                      child: SizedBox(
                        height: 700,
                        child: Text('long current reply'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.layers.whereType<ImageFilterLayer>(), isEmpty);
      scroll.jumpTo(50);
      await tester.pump();
      expect(tester.layers.whereType<ImageFilterLayer>(), hasLength(1));
      expect(find.text('older'), findsOneWidget);
      expect(find.byType(BackdropFilter), findsNothing);
      scroll.jumpTo(0);
      await tester.pump();
      await tester.tap(find.text('older'));
      expect(presses, 1);
      expect(tester.layers.whereType<ImageFilterLayer>(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'waiting shows three animated dots with a screen reader label and no text',
    (tester) async {
      final semantics = tester.ensureSemantics();
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ChatThinkingBubble())),
      );
      final bubble = find.byType(ChatThinkingBubble);
      final dots = find.descendant(of: bubble, matching: find.byType(Opacity));
      expect(dots, findsNWidgets(3));
      expect(
        find.descendant(of: bubble, matching: find.byType(Text)),
        findsNothing,
      );
      expect(find.bySemanticsLabel('chat.thinking'.tr), findsOneWidget);
      final initialOpacity = tester
          .widgetList<Opacity>(dots)
          .map((dot) => dot.opacity)
          .toList();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        tester.widgetList<Opacity>(dots).map((dot) => dot.opacity).toList(),
        isNot(equals(initialOpacity)),
      );
      semantics.dispose();
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('thinking dots stay neutral on $brightness frost', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const MediaQuery(
            data: MediaQueryData(disableAnimations: true),
            child: Scaffold(body: ChatThinkingBubble()),
          ),
        ),
      );
      final bubble = find.byType(ChatThinkingBubble);
      final dots = find.descendant(
        of: bubble,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is DecoratedBox &&
              widget.decoration is BoxDecoration &&
              (widget.decoration as BoxDecoration).shape == BoxShape.circle,
        ),
      );
      expect(dots, findsNWidgets(3));
      final expectedColor = brightness == Brightness.dark
          ? MaasoFrostTokens.onAction
          : MaasoFrostTokens.composerAction;
      for (final dot in tester.widgetList<DecoratedBox>(dots)) {
        expect((dot.decoration as BoxDecoration).color, expectedColor);
      }
      final shell = tester.widget<AppGlassSurface>(
        find.descendant(of: bubble, matching: find.byType(AppGlassSurface)),
      );
      expect(shell.role, AppGlassSurfaceRole.message);
      expect(
        shell.tintColor,
        (brightness == Brightness.dark
                ? MaasoFrostTokens.darkSurface
                : MaasoFrostTokens.lightSurface)
            .withValues(alpha: MaasoFrostTokens.messageFillAlpha),
      );
      // Check the dimmest pulse against a contrasting scene under the frost.
      final background = Color.alphaBlend(
        shell.tintColor!,
        brightness == Brightness.dark ? Colors.white : Colors.black,
      );
      final foreground = Color.alphaBlend(
        expectedColor.withValues(alpha: .6),
        background,
      );
      final a = background.computeLuminance();
      final b = foreground.computeLuminance();
      expect(
        ((a > b ? a : b) + .05) / ((a < b ? a : b) + .05),
        greaterThanOrEqualTo(3),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
    });
  }

  testWidgets(
    'reduced motion keeps thinking status readable without a running ticker',
    (tester) async {
      var dismissed = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Scaffold(
              body: ChatThinkingBubble(
                thought: '下一步整理结果',
                onDismissThought: () => dismissed++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.text('下一步整理结果'), findsOneWidget);
      expect(
        tester.getSize(find.byKey(const ValueKey('chat-dismiss-thought'))),
        const Size(48, 48),
      );
      await tester.tap(find.byKey(const ValueKey('chat-dismiss-thought')));
      expect(dismissed, 1);
    },
  );

  testWidgets(
    'standalone chat places thinking inside history and leaves the composer usable',
    (tester) async {
      appServices.put<DBService>(DBService());
      appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
      appServices.put<AgentCoreController>(_QuietCore());
      final chat = appServices.put<U2aChatController>(_QuietChat());
      chat.messages.addAll([
        _message('今天想做些什么？'),
        _message('一起去散步吧', user: true),
      ]);
      chat.isTyping.value = true;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: U2aChatPage()),
        ),
      );
      await tester.pump();
      expect(find.byType(ChatThinkingBubble), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('u2a-chat-scroll-view')),
          matching: find.byType(ChatThinkingBubble),
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(find.byType(ChatThinkingBubble)).bottom,
        lessThan(tester.getRect(find.byType(TextField)).top),
      );
      await tester.enterText(find.byType(TextField), '这条草稿不发送');
      expect(chat.inputController.text, '这条草稿不发送');
      final composer = tester.widget<AppGlassComposerMorph>(
        find.byType(AppGlassComposerMorph),
      );
      expect(composer.floatingGlass, isTrue);
      chat.isTyping.value = false;
      await tester.pump();
      expect(find.byType(ChatThinkingBubble), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'desktop chat hides automatic scrollbars while wheel and drag remain usable',
    (tester) async {
      appServices.put<DBService>(DBService());
      appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
      appServices.put<AgentCoreController>(_QuietCore());
      final chat = appServices.put<U2aChatController>(_QuietChat());
      chat.messages.addAll(
        List.generate(40, (index) => _message('旧消息 $index：保留可以滚动阅读的聊天记录。')),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp(
            theme: ThemeData(
              platform: TargetPlatform.macOS,
              scrollbarTheme: const ScrollbarThemeData(
                thumbVisibility: WidgetStatePropertyAll(true),
              ),
            ),
            home: const U2aChatPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('u2a-chat-scroll-view'));
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(RawScrollbar), findsNothing);
      final start = chat.scrollController.offset;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(list),
          scrollDelta: const Offset(0, 350),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pumpAndSettle();
      expect(chat.scrollController.offset, greaterThan(start + 100));
      final afterWheel = chat.scrollController.offset;
      await tester.drag(list, const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(chat.scrollController.offset, greaterThan(afterWheel + 100));
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(RawScrollbar), findsNothing);
      await tester.enterText(find.byType(TextField), '保留草稿');
      expect(chat.inputController.text, '保留草稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

ChatMessage _message(String content, {bool user = false}) => ChatMessage(
  sessionId: 'self',
  senderId: user ? 'user' : 'self',
  receiverId: user ? 'self' : 'user',
  content: content,
  timestamp: DateUtils.dateOnly(DateTime.now()),
  isUserMessage: user,
);

class _QuietCore extends AgentCoreController {
  @override
  // No account/model boot is needed for a widget boundary test.
  // ignore: must_call_super
  void onInit() {}
}

class _QuietChat extends U2aChatController {
  @override
  // Keep the production state/composer while suppressing database boot reads.
  // ignore: must_call_super
  void onInit() {}
}
