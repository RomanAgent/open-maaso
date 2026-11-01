import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _HistoryDb database;
  late HomeController home;
  late HomeChatInteraction interaction;
  var sceneTaps = 0;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    sceneTaps = 0;
    database = appServices.put<DBService>(_HistoryDb()) as _HistoryDb;
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_QuietCore());
    home = appServices.put<HomeController>(_QuietHome());
  });

  tearDown(() async => appServices.reset());

  Future<void> mount(
    WidgetTester tester, {
    bool autoHide = true,
    bool compact = true,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          home: Scaffold(
            body: HomeChatInteractionScope(
              child: Builder(
                builder: (context) {
                  interaction = HomeChatInteractionScope.maybeOf(context)!;
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: GestureDetector(
                          key: const ValueKey('test-home-scene'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => sceneTaps++,
                          child: const SizedBox.expand(),
                        ),
                      ),
                      SizedBox(
                        width: 260,
                        height: 240,
                        child: HomeChatHistory(
                          compact: compact,
                          autoHide: autoHide,
                          contentPadding: const EdgeInsets.fromLTRB(
                            0,
                            44,
                            0,
                            4,
                          ),
                          latestButtonBottom: 4,
                          topFadeHeight: 44,
                        ),
                      ),
                      HomeChatActivityRegion(
                        child: TextField(
                          key: const ValueKey('test-home-composer'),
                          controller: home.inputController,
                          focusNode: interaction.focusNode,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(minutes: 2));
    });
  }

  double opacity(WidgetTester tester) => tester
      .widget<AppNativeFrostGroup>(find.byType(AppNativeFrostGroup))
      .opacity;

  Future<void> hide(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 30));
    await settle(tester);
    expect(opacity(tester), 0);
  }

  Future<void> outside(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('test-home-scene')));
    await tester.pump();
    expect(opacity(tester), 0, reason: 'External taps hide immediately.');
  }

  Future<void> wake(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('chat-window-wake-region')));
    await settle(tester);
    expect(opacity(tester), 1);
  }

  testWidgets('outside tap hides history while still reaching the scene', (
    tester,
  ) async {
    await mount(tester);
    expect(opacity(tester), 1);
    await outside(tester);
    expect(sceneTaps, 1);
    expect(find.text('你好，我们继续聊天。').hitTestable(), findsNothing);
    expect(
      find.byKey(const ValueKey('chat-window-wake-region')),
      findsOneWidget,
    );
    await outside(tester);
    expect(sceneTaps, 2);
    await wake(tester);
    expect(find.text('你好，我们继续聊天。').hitTestable(), findsOneWidget);
  });

  testWidgets(
    'new persisted and streaming replies do not wake hidden history',
    (tester) async {
      await mount(tester);
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('home-chat-scroll-view')),
      );
      expect(list.padding, const EdgeInsets.fromLTRB(0, 44, 0, 28));
      final group = tester.widget<AppNativeFrostGroup>(
        find.byType(AppNativeFrostGroup),
      );
      expect(group.enabled, isTrue);
      expect(group.topFadeHeight, 44);
      expect(group.bottomFadeHeight, 24);
      await hide(tester);
      database.messages.add(_message(2, '收到新的回复'));
      home.conversationRevision.value++;
      await settle(tester);
      expect(opacity(tester), 0);
      home.latestBubble.value = '回复正在逐字到来';
      await settle(tester);
      expect(opacity(tester), 0);
      await wake(tester);
      expect(find.text('回复正在逐字到来'), findsOneWidget);
    },
  );

  testWidgets(
    'composer tap reveals history and focused input keeps it visible',
    (tester) async {
      await mount(tester);
      await hide(tester);
      home.inputController.text = '保存的草稿不是点击';
      await settle(tester);
      expect(opacity(tester), 0);
      await tester.tap(find.byKey(const ValueKey('test-home-composer')));
      await settle(tester);
      expect(interaction.hasFocus, isTrue);
      expect(opacity(tester), 1);
      await tester.pump(const Duration(seconds: 90));
      expect(opacity(tester), 1);
      await outside(tester);
      home.inputController.text = '外部隐藏之后的输入变化';
      await settle(tester);
      expect(opacity(tester), 0);
      // The region tap must work even when the input was already focused.
      await tester.tap(find.byKey(const ValueKey('test-home-composer')));
      await settle(tester);
      expect(opacity(tester), 1);
      interaction.focusNode.unfocus();
      await settle(tester);
      await hide(tester);
    },
  );

  testWidgets('thinking and voice hold visible history but cannot reveal it', (
    tester,
  ) async {
    final mic = appServices.put<MicCaptureService>(_QuietMic());
    final asr = appServices.put<PlatformAsrService>(PlatformAsrService());
    await mount(tester);
    for (final state in [
      home.isThinking,
      home.isProcessing,
      home.isSpeaking,
      mic.isRecording,
      asr.isListening,
    ]) {
      await outside(tester);
      state.value = true;
      await settle(tester);
      expect(opacity(tester), 0);
      await wake(tester);
      await tester.pump(const Duration(seconds: 90));
      expect(opacity(tester), 1);
      await outside(tester);
      state.value = false;
      await settle(tester);
      expect(opacity(tester), 0);
    }
  });

  testWidgets(
    'keyboard metrics neither suppress visible history nor wake hidden history',
    (tester) async {
      addTearDown(tester.view.resetViewInsets);
      await mount(tester);
      expect(interaction.hasFocus, isFalse);
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await settle(tester);
      expect(opacity(tester), 1);
      await outside(tester);
      tester.view.resetViewInsets();
      await settle(tester);
      expect(opacity(tester), 0);
      await wake(tester);
    },
  );

  testWidgets(
    'the first hidden-window tap reveals without opening message actions',
    (tester) async {
      await mount(tester);
      final message = find.text('你好，我们继续聊天。');
      final point = tester.getCenter(message);
      await outside(tester);
      await tester.tapAt(point);
      await settle(tester);
      expect(opacity(tester), 1);
      expect(find.byKey(const ValueKey('message-action-menu')), findsNothing);
      await tester.tapAt(point);
      await settle(tester);
      expect(find.byKey(const ValueKey('message-action-menu')), findsOneWidget);
      await outside(tester);
      expect(find.byKey(const ValueKey('message-action-menu')), findsNothing);
    },
  );

  testWidgets(
    'programmatic history scrolling does not reveal dismissed content',
    (tester) async {
      database.messages.addAll(
        List.generate(25, (i) => _message(i + 2, '历史消息 $i')),
      );
      await mount(tester);
      final scroll = tester.state<ScrollableState>(
        find.descendant(
          of: find.byKey(const ValueKey('home-chat-scroll-view')),
          matching: find.byType(Scrollable),
        ),
      );
      expect(scroll.position.maxScrollExtent, greaterThan(0));
      await outside(tester);
      scroll.position.jumpTo(0);
      await settle(tester);
      expect(opacity(tester), 0);
      await wake(tester);
    },
  );

  testWidgets(
    'full-screen chat stays visible with outside taps focus and keyboard',
    (tester) async {
      addTearDown(tester.view.resetViewInsets);
      await mount(tester, autoHide: false, compact: false);
      await tester.tap(find.byKey(const ValueKey('test-home-scene')));
      await tester.pump();
      expect(opacity(tester), 1);
      await tester.tap(find.byKey(const ValueKey('test-home-composer')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await settle(tester);
      expect(interaction.hasFocus, isTrue);
      expect(opacity(tester), 1);
      expect(
        tester
            .widget<AppNativeFrostGroup>(find.byType(AppNativeFrostGroup))
            .enabled,
        isFalse,
      );
      await tester.pump(const Duration(minutes: 2));
      expect(opacity(tester), 1);
      expect(
        find.byKey(const ValueKey('chat-window-wake-region')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'history refresh foreground resume and menu closure stay hidden',
    (tester) async {
      await mount(tester);
      await outside(tester);
      home.conversationRevision.value++;
      await settle(tester);
      expect(opacity(tester), 0);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await settle(tester);
      expect(opacity(tester), 0);
      interaction.setMenuExpanded(true);
      home.latestBubble.value = 'menu still hides new activity';
      await settle(tester);
      expect(opacity(tester), 0);
      interaction.setMenuExpanded(false);
      await settle(tester);
      expect(opacity(tester), 0);
      await wake(tester);
    },
  );

  testWidgets('persistent chat opts out of inactivity hiding by default', (
    tester,
  ) async {
    await mount(tester, autoHide: false, compact: false);
    await tester.pump(const Duration(minutes: 2));
    expect(opacity(tester), 1);
    expect(find.byKey(const ValueKey('chat-window-wake-region')), findsNothing);
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 35; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

ChatMessage _message(int id, String content) => ChatMessage(
  id: id,
  sessionId: 'self',
  senderId: 'self',
  receiverId: 'user',
  content: content,
  timestamp: DateUtils.dateOnly(DateTime.now()).add(Duration(minutes: id)),
);

class _HistoryDb extends DBService {
  final messages = [_message(1, '你好，我们继续聊天。')];

  @override
  Future<List<ChatMessage>> getMessagesInRange(
    String sessionId, {
    required DateTime from,
    required DateTime before,
  }) async => List.of(messages);
}

class _QuietHome extends HomeController {
  @override
  // UI-only fixture; no runtime or hardware startup.
  // ignore: must_call_super
  void onInit() {}
}

class _QuietCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _QuietMic extends MicCaptureService {
  @override
  // Only its existing observable state is used; no capture is started.
  // ignore: must_call_super
  void onInit() {}
}
