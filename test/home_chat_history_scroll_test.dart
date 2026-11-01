import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';

const _scrollKey = ValueKey('home-chat-scroll-view');
const _latestKey = ValueKey('home-chat-scroll-to-latest');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _HistoryDb database;
  late HomeController home;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    database = _HistoryDb();
    appServices.put<DBService>(database);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_QuietCore());
    home = appServices.put<HomeController>(_QuietHome());
    database.messages.addAll(List.generate(45, _message));
  });

  tearDown(() async => appServices.reset());

  Future<void> mount(
    WidgetTester tester, {
    double bottom = 120,
    bool reducedMotion = false,
    bool desktop = false,
    bool compact = false,
  }) async {
    tester.view.physicalSize = const Size(393, 852);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          theme: desktop
              ? ThemeData(
                  platform: TargetPlatform.macOS,
                  scrollbarTheme: const ScrollbarThemeData(
                    thumbVisibility: WidgetStatePropertyAll(true),
                  ),
                )
              : null,
          home: MediaQuery(
            data: MediaQueryData(
              size: const Size(393, 852),
              disableAnimations: reducedMotion,
            ),
            child: HomeChatHistory(
              compact: compact,
              contentPadding: EdgeInsets.fromLTRB(14, 120, 14, bottom),
              latestButtonBottom: bottom,
              topFadeHeight: 100,
            ),
          ),
        ),
      ),
    );
    await settle(tester);
  }

  testWidgets('initial history ends above the floating composer inset', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester);
    final position = scrollPosition(tester);
    expect(position.extentAfter, lessThan(1));
    expect(find.byKey(_latestKey), findsNothing);
    final latest = tester.getRect(find.text(_message(44).content));
    expect(latest.bottom, lessThan(852 - 120));
    expect(
      tester.getRect(find.byKey(_scrollKey)),
      const Rect.fromLTWH(0, 0, 393, 852),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('compact avatar history never shows a return-to-latest overlay', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, compact: true);
    await tester.drag(find.byKey(_scrollKey), const Offset(0, 460));
    await settle(tester);
    expect(scrollPosition(tester).extentAfter, greaterThan(100));
    expect(find.byKey(_latestKey), findsNothing);
    final readingOffset = scrollPosition(tester).pixels;
    database.messages.add(_message(45));
    home.conversationRevision.value++;
    await settle(tester);
    expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
    expect(find.byKey(_latestKey), findsNothing);
    await tester.drag(find.byKey(_scrollKey), const Offset(0, -200));
    await settle(tester);
    expect(find.byKey(_latestKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reading older messages shows return control and new replies do not move reader',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      await tester.drag(find.byKey(_scrollKey), const Offset(0, 460));
      await settle(tester);
      final readingOffset = scrollPosition(tester).pixels;
      expect(find.byKey(_latestKey), findsOneWidget);
      database.messages.add(_message(45));
      home.conversationRevision.value++;
      await settle(tester);
      expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
      expect(find.byKey(_latestKey), findsOneWidget);
      await tester.tap(find.byKey(_latestKey));
      await settle(tester);
      expect(scrollPosition(tester).extentAfter, lessThan(1));
      expect(find.byKey(_latestKey), findsNothing);
      expect(find.text(_message(45).content), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a gesture during an asynchronous history read wins over following',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      final read = Completer<List<ChatMessage>>();
      database.nextRead = read;
      home.conversationRevision.value++;
      await tester.pump();
      await tester.drag(find.byKey(_scrollKey), const Offset(0, 450));
      await settle(tester);
      final readingOffset = scrollPosition(tester).pixels;
      database.messages.add(_message(45));
      read.complete(List.of(database.messages));
      await settle(tester);
      expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
      expect(find.byKey(_latestKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'new persisted and growing streaming replies follow only at latest',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester);
      database.messages.add(_message(45));
      home.conversationRevision.value++;
      await settle(tester);
      expect(scrollPosition(tester).extentAfter, lessThan(1));
      home.isThinking.value = true;
      home.latestBubble.value = '正在回复。';
      await settle(tester);
      home.latestBubble.value = List.filled(
        12,
        '这一段是持续到来的回复，应该保持最新内容可见。',
      ).join('\n');
      await settle(tester);
      expect(scrollPosition(tester).extentAfter, lessThan(1));
      expect(
        find.byKey(const ValueKey('home-chat-streaming-reply')),
        findsOneWidget,
      );
      await tester.drag(find.byKey(_scrollKey), const Offset(0, 430));
      await settle(tester);
      final readingOffset = scrollPosition(tester).pixels;
      home.latestBubble.value = '${home.latestBubble.value}\n又收到一段回复。';
      await settle(tester);
      expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'keyboard page up keeps its reading position when a new reply arrives',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, desktop: true);
      final tail = scrollPosition(tester).pixels;
      pageUp(tester);
      await settle(tester);
      final readingOffset = scrollPosition(tester).pixels;
      expect(readingOffset, lessThan(tail - 100));
      database.messages.add(_message(45));
      home.conversationRevision.value++;
      await settle(tester);
      expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
      expect(find.byKey(_latestKey), findsOneWidget);
    },
  );

  testWidgets(
    'desktop wheel scrolling stays immersive and survives a new reply',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, desktop: true);
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(RawScrollbar), findsNothing);
      final tail = scrollPosition(tester).pixels;
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(_scrollKey)),
          scrollDelta: const Offset(0, -400),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await settle(tester);
      final readingOffset = scrollPosition(tester).pixels;
      expect(readingOffset, lessThan(tail - 100));
      database.messages.add(_message(45));
      home.conversationRevision.value++;
      await settle(tester);
      expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
      expect(find.byKey(_latestKey), findsOneWidget);
      expect(find.byType(Scrollbar), findsNothing);
      expect(find.byType(RawScrollbar), findsNothing);
    },
  );

  testWidgets('keyboard paging takes over an in-flight return to latest', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await mount(tester, desktop: true);
    await tester.drag(find.byKey(_scrollKey), const Offset(0, 460));
    await settle(tester);
    await tester.tap(find.byKey(_latestKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final returningOffset = scrollPosition(tester).pixels;
    pageUp(tester);
    await settle(tester);
    final readingOffset = scrollPosition(tester).pixels;
    expect(readingOffset, lessThan(returningOffset - 100));
    expect(find.byKey(_latestKey), findsOneWidget);
    home.isThinking.value = true;
    home.latestBubble.value = '新的流式回复不应打断键盘翻页。';
    await settle(tester);
    expect(scrollPosition(tester).pixels, closeTo(readingOffset, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keyboard inset preserves the tail and reduced motion return works',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await mount(tester, reducedMotion: true);
      await mount(tester, bottom: 390, reducedMotion: true);
      expect(scrollPosition(tester).extentAfter, lessThan(1));
      expect(
        tester.getRect(find.text(_message(44).content)).bottom,
        lessThan(852 - 390),
      );
      await tester.drag(find.byKey(_scrollKey), const Offset(0, 410));
      await settle(tester);
      await tester.tap(find.byKey(_latestKey));
      await tester.pump();
      await tester.pump();
      expect(scrollPosition(tester).extentAfter, lessThan(1));
      expect(find.byKey(_latestKey), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

ScrollPosition scrollPosition(WidgetTester tester) =>
    tester.widget<ListView>(find.byKey(_scrollKey)).controller!.position;

void pageUp(WidgetTester tester) {
  // Invoke Flutter's actual keyboard action from within a visible list row.
  Actions.invoke(
    tester.element(find.textContaining('条对话').first),
    const ScrollIntent(
      direction: AxisDirection.up,
      type: ScrollIncrementType.page,
    ),
  );
}

ChatMessage _message(int i) => ChatMessage(
  id: i + 1,
  sessionId: 'self',
  senderId: i.isEven ? 'self' : 'user',
  receiverId: i.isEven ? 'user' : 'self',
  content: '第 $i 条对话：我们聊聊窗外的海景和今天发生的事情。',
  timestamp: DateUtils.dateOnly(DateTime.now()).add(Duration(minutes: i)),
  isUserMessage: i.isOdd,
);

class _HistoryDb extends DBService {
  final messages = <ChatMessage>[];
  Completer<List<ChatMessage>>? nextRead;

  @override
  Future<List<ChatMessage>> getMessagesInRange(
    String sessionId, {
    required DateTime from,
    required DateTime before,
  }) {
    expect(sessionId, 'self');
    expect(from, DateUtils.dateOnly(DateTime.now()));
    expect(before, DateTime(from.year, from.month, from.day + 1));
    final pending = nextRead;
    nextRead = null;
    return pending?.future ?? Future.value(List.of(messages));
  }
}

class _QuietHome extends HomeController {
  @override
  // UI-only fixture; do not start microphones, model boot or runtime turns.
  // ignore: must_call_super
  void onInit() {}
}

class _QuietCore extends AgentCoreController {
  @override
  // UI-only fixture; no avatar boot is needed for the chat history.
  // ignore: must_call_super
  void onInit() {}
}
