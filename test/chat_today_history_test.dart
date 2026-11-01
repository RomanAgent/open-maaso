import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/application/local_chat_day.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/features/chat/presentation/u2a_chat_page.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService db;
  final rows = intMapStoreFactory.store('chat_messages');

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'today-chat-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    appServices.put<DBService>(db);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_QuietCore());
  });
  tearDown(() async {
    await appServices.reset();
    await db.close();
  });

  test(
    'range query returns the complete day with mixed ISO forms and preserves all rows',
    () async {
      final day = LocalChatDay.at(DateTime(2026, 9, 15, 12));
      await db.saveChatMessage(
        _message(
          'yesterday',
          day.start.subtract(const Duration(microseconds: 1)),
        ),
      );
      for (var i = 0; i < 151; i++) {
        final message = _message(
          'today $i',
          day.start.add(Duration(minutes: i)),
        );
        final row = message.toJson();
        if (i.isOdd) {
          row['timestamp'] = message.timestamp.toLocal().toIso8601String();
        }
        await rows.add(db.raw, row);
      }
      await db.saveChatMessage(_message('tomorrow', day.end));
      await rows.add(db.raw, {
        ..._message('invalid', day.start).toJson(),
        'timestamp': 'broken',
      });
      await rows.add(
        db.raw,
        {..._message('missing', day.start).toJson()}..remove('timestamp'),
      );
      await rows.add(db.raw, {
        ..._message('other session', day.start).toJson(),
        'sessionId': 'other',
      });
      final before = await rows.find(db.raw);
      final today = await db.getMessagesInRange(
        'self',
        from: day.start,
        before: day.end,
      );
      expect(today, hasLength(151));
      expect(today.first.content, 'today 0');
      expect(today.last.content, 'today 150');
      expect(today.every((message) => day.contains(message.timestamp)), isTrue);
      expect(
        await db.getMessagesInRange('self', from: day.end, before: day.start),
        isEmpty,
      );
      expect(
        (await rows.find(db.raw)).map((row) => row.value),
        before.map((row) => row.value),
      );
      expect(await db.getMessages('self'), hasLength(155));
    },
  );

  testWidgets(
    'Home displays more than 120 current-day rows and no older or future rows',
    (tester) async {
      final now = DateTime(2026, 9, 15, 12);
      final day = LocalChatDay.at(now);
      appServices.put<HomeController>(_QuietHome());
      await tester.runAsync(() async {
        await db.saveChatMessage(
          _message('older', day.start.subtract(const Duration(days: 1))),
        );
        for (var i = 0; i < 151; i++) {
          await db.saveChatMessage(
            _message('today $i', day.start.add(Duration(minutes: i))),
          );
        }
        await db.saveChatMessage(_message('future', day.end));
      });
      await _mount(
        tester,
        HomeChatHistory(
          contentPadding: EdgeInsets.zero,
          latestButtonBottom: 0,
          topFadeHeight: 0,
          clock: () => now,
        ),
      );
      final list = tester.widget<ListView>(
        find.byKey(const ValueKey('home-chat-scroll-view')),
      );
      expect(
        (list.childrenDelegate as SliverChildBuilderDelegate).childCount,
        151,
      );
      list.controller!.jumpTo(0);
      await _settle(tester);
      expect(find.text('today 0'), findsOneWidget);
      expect(find.text('older'), findsNothing);
      expect(find.text('future'), findsNothing);
      expect(
        await tester.runAsync(() => db.getMessages('self')),
        hasLength(153),
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'Home clears yesterday at midnight, does not revive a stale latest reply, and resumes',
    (tester) async {
      var now = DateTime(2026, 9, 15, 23, 59, 59);
      final home = appServices.put<HomeController>(_QuietHome());
      home.latestBubbleAt = now;
      home.latestBubble.value = 'yesterday reply';
      await tester.runAsync(
        () => db.saveChatMessage(_message('yesterday reply', now)),
      );
      await _mount(
        tester,
        HomeChatHistory(
          contentPadding: EdgeInsets.zero,
          latestButtonBottom: 0,
          topFadeHeight: 0,
          clock: () => now,
        ),
      );
      expect(find.text('yesterday reply'), findsOneWidget);
      now = DateTime(2026, 9, 16);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(find.text('yesterday reply'), findsNothing);
      home.latestBubbleAt = now;
      home.latestBubble.value = 'new day notice';
      await _settle(tester);
      expect(find.text('new day notice'), findsOneWidget);
      _pause(tester);
      now = DateTime(2026, 9, 18, 10);
      await tester.runAsync(
        () => db.saveChatMessage(_message('returned today', now)),
      );
      _resume(tester);
      await _settle(tester);
      expect(find.text('returned today'), findsOneWidget);
      expect(find.text('new day notice'), findsNothing);
      expect(await tester.runAsync(() => db.getMessages('self')), hasLength(2));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'returning to a newly mounted Home never re-dates yesterday notice',
    (tester) async {
      final now = DateTime(2026, 9, 16, 10);
      final home = appServices.put<HomeController>(_QuietHome());
      home.latestBubbleAt = DateTime(2026, 9, 15, 22);
      home.latestBubble.value = 'old unpersisted notice';
      await _mount(
        tester,
        HomeChatHistory(
          contentPadding: EdgeInsets.zero,
          latestButtonBottom: 0,
          topFadeHeight: 0,
          clock: () => now,
        ),
      );
      expect(find.text('old unpersisted notice'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'U2a renders only today while retaining model history across midnight and resume',
    (tester) async {
      var now = DateTime(2026, 9, 15, 23, 59, 59);
      await tester.runAsync(() async {
        await db.saveChatMessage(
          _message('yesterday context', DateTime(2026, 9, 14, 12)),
        );
        await db.saveChatMessage(_message('current answer', now));
      });
      final controller = appServices.put<U2aChatController>(
        U2aChatController(clock: () => now),
      );
      await _mount(tester, const U2aChatPage());
      expect(find.text('current answer'), findsOneWidget);
      expect(find.text('yesterday context'), findsNothing);
      expect(
        modelContextTail(
          controller.messages,
          limit: 6,
        ).map((message) => message.content),
        ['yesterday context', 'current answer'],
      );
      now = DateTime(2026, 9, 16);
      await tester.pump(const Duration(seconds: 1));
      await _settle(tester);
      expect(find.text('current answer'), findsNothing);
      expect(controller.messages, hasLength(2));
      _pause(tester);
      now = DateTime(2026, 9, 18, 10);
      await tester.runAsync(
        () => db.saveChatMessage(_message('resumed answer', now)),
      );
      _resume(tester);
      await _settle(tester);
      expect(find.text('resumed answer'), findsOneWidget);
      expect(controller.messages, hasLength(3));
      expect(await tester.runAsync(() => db.getMessages('self')), hasLength(3));
      await tester.pumpWidget(const SizedBox.shrink());
      await appServices.delete<U2aChatController>();
    },
  );

  testWidgets('U2a excludes malformed persisted timestamps from today', (
    tester,
  ) async {
    final now = DateTime.now();
    await tester.runAsync(() async {
      await rows.add(db.raw, {
        ..._message('bad date', now).toJson(),
        'timestamp': 'invalid',
      });
      await db.saveChatMessage(_message('good date', now));
    });
    final controller = appServices.put<U2aChatController>(
      U2aChatController(clock: () => now),
    );
    await _mount(tester, const U2aChatPage());
    expect(controller.messages, hasLength(2));
    expect(find.text('bad date'), findsNothing);
    expect(find.text('good date'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await appServices.delete<U2aChatController>();
  });

  testWidgets('a Home read started yesterday cannot restore expired rows', (
    tester,
  ) async {
    final delayed = _DelayedDb();
    appServices.put<DBService>(delayed, overrideAbstract: true);
    appServices.put<HomeController>(_QuietHome());
    var now = DateTime(2026, 9, 15, 23, 59, 59);
    await _mount(
      tester,
      HomeChatHistory(
        contentPadding: EdgeInsets.zero,
        latestButtonBottom: 0,
        topFadeHeight: 0,
        clock: () => now,
      ),
    );
    now = DateTime(2026, 9, 16);
    await tester.pump(const Duration(seconds: 1));
    delayed.read.complete([
      _message('late old row', DateTime(2026, 9, 15, 22)),
    ]);
    await _settle(tester);
    expect(find.text('late old row'), findsNothing);
    expect(find.text('new day row'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: appProviderContainer,
      child: MaterialApp(home: child),
    ),
  );
  await _settle(tester);
}

void _pause(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void _resume(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
}

ChatMessage _message(String content, DateTime timestamp) => ChatMessage(
  sessionId: 'self',
  senderId: 'self',
  receiverId: 'user',
  content: content,
  timestamp: timestamp,
);

class _QuietCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _QuietHome extends HomeController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _DelayedDb extends DBService {
  final read = Completer<List<ChatMessage>>();
  var calls = 0;
  @override
  Future<List<ChatMessage>> getMessagesInRange(
    String sessionId, {
    required DateTime from,
    required DateTime before,
  }) {
    if (calls++ == 0) return read.future;
    return Future.value([_message('new day row', from)]);
  }
}
