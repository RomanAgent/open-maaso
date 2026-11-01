import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/chat/data/chat_reply_feedback_store.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_actions.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:sembast/sembast_memory.dart' show databaseFactoryMemory;

const _menuKey = ValueKey('message-action-menu');
const _copyKey = ValueKey('message-copy-action');
const _timeKey = ValueKey('message-action-time');
const _goodKey = ValueKey('message-feedback-excellent');
const _poorKey = ValueKey('message-feedback-poor');

ChatMessage _message(String text, {bool user = false, int? id = 1}) =>
    ChatMessage(
      id: id,
      sessionId: 'self',
      senderId: user ? 'user' : 'self',
      receiverId: user ? 'self' : 'user',
      content: text,
      timestamp: DateTime(2026, 9, 15, 14, 8),
      isUserMessage: user,
      deliveryStatus: 'published',
    );

Widget _bubble(ChatMessage message, {bool dim = false}) => MessageBubble(
  key: ValueKey('bubble-${message.id}-${message.isUserMessage}'),
  message: message,
  dim: dim,
);

Finder _surface(String text) => find.ancestor(
  of: find.text(text),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is AppGlassSurface && widget.role == AppGlassSurfaceRole.message,
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  required Widget child,
  Size size = const Size(600, 800),
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          padding: padding,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Directionality(
          textDirection: direction,
          child: Scaffold(body: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _settle(WidgetTester tester) async {
  for (var frame = 0; frame < 9; frame++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> _open(WidgetTester tester, String text) async {
  await tester.tap(find.text(text));
  await _settle(tester);
  expect(find.byKey(_menuKey), findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final clipboardWrites = <String>[];

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboardWrites.add((call.arguments as Map)['text'] as String);
          }
          return null;
        });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await appServices.reset();
  });

  test('message radius agrees with the design anchor', () {
    final tokens =
        jsonDecode(
              File(
                'design-system/maaso-soft-frost/tokens.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(tokens['radius']['message'], MaasoFrostTokens.messageRadius);
    expect(MaasoFrostTokens.messageRadius, 12);
  });

  for (final user in [false, true]) {
    testWidgets('only tapped ${user ? 'user' : 'AI'} messages show actions', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final message = _message('你好', user: user);
      await _mount(tester, child: Center(child: _bubble(message)));
      expect(find.byKey(_menuKey), findsNothing);
      expect(find.byKey(_timeKey), findsNothing);
      expect(find.byKey(_copyKey), findsNothing);
      expect(find.byKey(_goodKey), findsNothing);
      expect(find.byKey(_poorKey), findsNothing);
      expect(find.byKey(const ValueKey('message-metadata-row')), findsNothing);
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
      await _open(tester, message.content);
      expect(find.byKey(_copyKey), findsOneWidget);
      expect(find.text('14:08'), findsOneWidget);
      expect(find.byKey(_goodKey), user ? findsNothing : findsOneWidget);
      expect(find.byKey(_poorKey), user ? findsNothing : findsOneWidget);
      await tester.tap(find.text(message.content));
      await _settle(tester);
      expect(find.byKey(_menuKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final text in ['好', 'OK', '一条普通短句。']) {
    testWidgets('$text keeps a 12px rounded rectangle and stable tap bounds', (
      tester,
    ) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _mount(tester, child: Center(child: _bubble(_message(text))));
      final surface = _surface(text);
      final before = tester.getRect(surface);
      expect(tester.widget<AppGlassSurface>(surface).cornerRadius, 12);
      expect(before.width, greaterThanOrEqualTo(48));
      expect(before.height, greaterThanOrEqualTo(44));
      expect(before.shortestSide, greaterThan(24));
      await _open(tester, text);
      expect(tester.getRect(surface), before);
      await tester.tap(find.text(text));
      await _settle(tester);
      expect(tester.getRect(surface), before);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final user in [false, true]) {
    for (final direction in TextDirection.values) {
      testWidgets(
        '${user ? 'user left' : 'Agent right'} actions follow the role in $direction',
        (tester) async {
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final message = _message('Side actions', user: user);
          await _mount(
            tester,
            direction: direction,
            child: Center(child: SizedBox(width: 260, child: _bubble(message))),
          );
          await _open(tester, message.content);
          final menu = tester.getRect(find.byKey(_menuKey));
          final anchor = tester.getRect(find.byType(MessageActionsAnchor));
          if (user) {
            expect(menu.right, closeTo(anchor.left - 8, .1));
          } else {
            expect(menu.left, closeTo(anchor.right + 8, .1));
          }
          expect(menu.height, greaterThan(menu.width));
          for (final key in [
            if (!user) ...[_goodKey, _poorKey],
            _copyKey,
          ]) {
            expect(tester.getSize(find.byKey(key)), const Size(24, 24));
          }
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }
  }

  testWidgets('selected menu follows message relayout without scrolling', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final position = ValueNotifier(const Offset(200, 200));
    addTearDown(position.dispose);
    await _mount(
      tester,
      child: ValueListenableBuilder<Offset>(
        valueListenable: position,
        child: _bubble(_message('A moving reply')),
        builder: (_, offset, child) => Stack(
          children: [
            Positioned(
              left: offset.dx,
              top: offset.dy,
              width: 260,
              child: child!,
            ),
          ],
        ),
      ),
    );
    await _open(tester, 'A moving reply');
    final before = tester.getRect(find.byKey(_menuKey));
    final anchorBefore = tester.getRect(find.byType(MessageActionsAnchor));
    position.value = const Offset(260, 320);
    await _settle(tester);
    final after = tester.getRect(find.byKey(_menuKey));
    final anchorAfter = tester.getRect(find.byType(MessageActionsAnchor));
    expect(anchorAfter.top - anchorBefore.top, 120);
    expect(after.top - before.top, closeTo(120, .01));
    expect(after.left - before.left, closeTo(60, .01));
    expect(after.left, closeTo(anchorAfter.right + 8, .01));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [180.0, 280.0, 390.0]) {
    for (final direction in TextDirection.values) {
      testWidgets('Agent menu fits ${width}px at 2x $direction', (
        tester,
      ) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await _mount(
          tester,
          size: Size(width, 640),
          textScale: 2,
          direction: direction,
          padding: const EdgeInsets.only(top: 24, bottom: 16),
          child: Center(child: _bubble(_message('短消息'))),
        );
        final bubble = tester.getRect(_surface('短消息'));
        await _open(tester, '短消息');
        final menu = tester.getRect(find.byKey(_menuKey));
        expect(menu.left, greaterThanOrEqualTo(8));
        expect(menu.right, lessThanOrEqualTo(width - 8));
        expect(menu.top, greaterThanOrEqualTo(32));
        expect(menu.bottom, lessThanOrEqualTo(640 - 24));
        expect(menu.overlaps(bubble), isFalse);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }

  for (final width in [180.0, 280.0]) {
    for (final user in [false, true]) {
      for (final atBottom in [false, true]) {
        testWidgets(
          '${user ? 'user' : 'Agent'} actions use the ${atBottom ? 'upper' : 'lower'} gap at ${width}px',
          (tester) async {
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final message = _message('较长消息供窄屏菜单定位验证', user: user);
            await _mount(
              tester,
              size: Size(width, 640),
              textScale: 2,
              padding: const EdgeInsets.only(top: 24, bottom: 16),
              child: SafeArea(
                child: Column(
                  children: [
                    if (atBottom) const Spacer(),
                    _bubble(message),
                    if (!atBottom) const Spacer(),
                  ],
                ),
              ),
            );
            await _open(tester, message.content);
            final menu = tester.getRect(find.byKey(_menuKey));
            final anchor = tester.getRect(find.byType(MessageActionsAnchor));
            final bubble = tester.getRect(_surface(message.content));
            expect(menu.left, greaterThanOrEqualTo(8));
            expect(menu.right, lessThanOrEqualTo(width - 8));
            expect(menu.top, greaterThanOrEqualTo(32));
            expect(menu.bottom, lessThanOrEqualTo(616));
            expect(menu.overlaps(bubble), isFalse);
            if (user) {
              expect(menu.left, closeTo(anchor.left.clamp(8, width - 8), .1));
            } else {
              expect(menu.right, closeTo(anchor.right.clamp(8, width - 8), .1));
            }
            if (atBottom) {
              expect(menu.bottom, closeTo(anchor.top - 8, .1));
            } else {
              expect(menu.top, closeTo(anchor.bottom + 8, .1));
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  testWidgets('ordinary full-screen chat keeps assistant left and user right', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
      tester,
      size: const Size(390, 844),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 20),
        children: [
          _bubble(_message('助手回复')),
          _bubble(_message('我的消息', user: true, id: 2)),
        ],
      ),
    );
    final assistant = tester.getRect(_surface('助手回复'));
    final user = tester.getRect(_surface('我的消息'));
    expect(assistant.left, closeTo(12, .1));
    expect(user.right, closeTo(378, .1));
    expect(assistant.center.dx, lessThan(user.center.dx));
    await _open(tester, '助手回复');
    expect(tester.getRect(_surface('助手回复')), assistant);
    expect(tester.getRect(_surface('我的消息')), user);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('outside taps and another message close the previous menu', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
      tester,
      child: ListView(
        children: [
          const SizedBox(height: 100),
          _bubble(_message('First reply')),
          const SizedBox(height: 100),
          _bubble(_message('Second reply', id: 2)),
        ],
      ),
    );
    await _open(tester, 'First reply');
    await tester.tapAt(const Offset(570, 750));
    await _settle(tester);
    expect(find.byKey(_menuKey), findsNothing);
    await _open(tester, 'First reply');
    await _open(tester, 'Second reply');
    await tester.tap(find.byKey(_copyKey));
    await _settle(tester);
    expect(clipboardWrites, ['Second reply']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('scrolling the conversation closes its menu', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await _mount(
      tester,
      child: ListView(
        controller: scroll,
        children: [
          const SizedBox(height: 80),
          _bubble(_message('Scrollable reply')),
          const SizedBox(height: 1800),
        ],
      ),
    );
    await _open(tester, 'Scrollable reply');
    // A scroll update must close the menu even without an outside pointer tap.
    scroll.jumpTo(150);
    await _settle(tester);
    expect(scroll.offset, 150);
    expect(find.byKey(_menuKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Escape closes a focused message menu', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
      tester,
      child: Center(child: _bubble(_message('Escape menu'))),
    );
    await _open(tester, 'Escape menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(tester);
    expect(find.byKey(_menuKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('opening and closing both fade from the top down', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
      tester,
      child: Center(child: _bubble(_message('Animated menu'))),
    );
    double opacity(int index) => tester
        .widget<Opacity>(find.byKey(ValueKey('message-action-opacity-$index')))
        .opacity;
    await tester.tap(find.text('Animated menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(opacity(0), greaterThan(opacity(1)));
    expect(opacity(1), greaterThan(opacity(3)));
    await _settle(tester);
    expect(opacity(3), 1);
    for (final icon in [
      Icons.thumb_up_outlined,
      Icons.thumb_down_outlined,
      Icons.copy_outlined,
    ]) {
      expect(tester.widget<Icon>(find.byIcon(icon)).size, 10);
    }
    await tester.tap(find.text('Animated menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(opacity(0), lessThan(opacity(1)));
    expect(opacity(1), lessThan(opacity(3)));
    expect(find.byKey(_menuKey), findsOneWidget);
    await _settle(tester);
    expect(find.byKey(_menuKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'optional report is selected, fully animated and dismisses before preview',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var reports = 0;
      await _mount(
        tester,
        child: Center(
          child: MessageBubble(
            message: _message('Reportable reply'),
            onReport: () => reports++,
          ),
        ),
      );
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      await _open(tester, 'Reportable reply');
      expect(
        tester
            .widget<Opacity>(
              find.byKey(const ValueKey('message-action-opacity-4')),
            )
            .opacity,
        1,
      );
      final menu = tester.getRect(find.byKey(_menuKey));
      expect(
        menu.contains(
          tester.getCenter(find.byKey(const ValueKey('message-report-action'))),
        ),
        isTrue,
      );
      await tester.tap(find.text('Reportable reply'));
      await _settle(tester);
      expect(find.byKey(_menuKey), findsNothing);
      await _open(tester, 'Reportable reply');
      await tester.tap(find.byKey(const ValueKey('message-report-action')));
      await tester.pump();
      expect(reports, 1);
      expect(find.byKey(_menuKey), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('removing report binding retires the selected menu safely', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final available = ValueNotifier(true);
    addTearDown(available.dispose);
    await _mount(
      tester,
      child: ValueListenableBuilder<bool>(
        valueListenable: available,
        builder: (_, value, _) => Center(
          child: MessageBubble(
            message: _message('Bound reply'),
            onReport: value ? () {} : null,
          ),
        ),
      ),
    );
    await _open(tester, 'Bound reply');
    available.value = false;
    await _settle(tester);
    expect(find.byKey(_menuKey), findsNothing);
    await _open(tester, 'Bound reply');
    expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
    expect(
      find.byKey(const ValueKey('message-action-opacity-4')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('reduced motion opens fully and closes immediately', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Scaffold(body: Center(child: _bubble(_message('Quiet menu')))),
        ),
      ),
    );
    await tester.tap(find.text('Quiet menu'));
    await tester.pump();
    expect(
      tester
          .widget<Opacity>(
            find.byKey(const ValueKey('message-action-opacity-3')),
          )
          .opacity,
      1,
    );
    await tester.tap(find.text('Quiet menu'));
    await tester.pump();
    expect(find.byKey(_menuKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a second message replaces a menu during its close animation', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
      tester,
      child: Column(
        children: [
          const SizedBox(height: 100),
          _bubble(_message('Closing reply')),
          const SizedBox(height: 120),
          _bubble(_message('New reply', id: 2)),
        ],
      ),
    );
    await _open(tester, 'Closing reply');
    await tester.tap(find.text('Closing reply'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.text('New reply'));
    await _settle(tester);
    expect(find.byKey(_menuKey), findsOneWidget);
    await tester.tap(find.byKey(_copyKey));
    await _settle(tester);
    expect(clipboardWrites, ['New reply']);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('copy invokes Clipboard with the exact untrimmed message', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const text = '  中文及 emoji 🙂\nsecond line  ';
    await _mount(tester, child: Center(child: _bubble(_message(text))));
    await _open(tester, text);
    await tester.tap(find.byKey(_copyKey));
    await _settle(tester);
    expect(clipboardWrites, [text]);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
    expect(find.byKey(_menuKey), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('compact actions remain reachable by keyboard', (tester) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _mount(
      tester,
      child: Center(child: _bubble(_message('Keyboard reply'))),
    );
    await _open(tester, 'Keyboard reply');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(find.byKey(_menuKey), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _settle(tester);
    expect(clipboardWrites, ['Keyboard reply']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.byKey(_menuKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final suppressed in [false, true]) {
    testWidgets(
      '${suppressed ? 'suppressed' : 'idle'} window removes overlay actions',
      (tester) async {
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final suppression = ValueNotifier(false);
        addTearDown(suppression.dispose);
        await _mount(
          tester,
          child: Center(
            child: SizedBox(
              width: 260,
              height: 200,
              child: ValueListenableBuilder<bool>(
                valueListenable: suppression,
                child: Center(child: _bubble(_message('Visible window reply'))),
                builder: (_, value, child) =>
                    ChatWindowVisibility(suppressed: value, child: child!),
              ),
            ),
          ),
        );
        await _open(tester, 'Visible window reply');
        if (suppressed) {
          suppression.value = true;
          await tester.pump();
        } else {
          await tester.pump(const Duration(seconds: 30));
        }
        await _settle(tester);
        expect(find.byKey(_menuKey), findsNothing);
        expect(find.byKey(_copyKey), findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets('a replaced row and an in-progress reply cannot retain actions', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final current = ValueNotifier(_message('Original reply'));
    addTearDown(current.dispose);
    await _mount(
      tester,
      child: ValueListenableBuilder<ChatMessage>(
        valueListenable: current,
        builder: (_, message, _) => Center(child: _bubble(message)),
      ),
    );
    await _open(tester, 'Original reply');
    current.value = _message('Replacement reply');
    await _settle(tester);
    expect(find.byKey(_menuKey), findsNothing);
    await _mount(
      tester,
      child: Center(child: _bubble(_message('Streaming reply'), dim: true)),
    );
    await tester.tap(find.text('Streaming reply'), warnIfMissed: false);
    await _settle(tester);
    expect(find.byKey(_menuKey), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'real stored ratings select, replace and cancel through buttons',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final path =
          'message-actions-${DateTime.now().microsecondsSinceEpoch}.db';
      final database = (await tester.runAsync(
        () => DBService().init(factory: databaseFactoryMemory, path: path),
      ))!;
      final scopes = AccountStorageScopeService();
      scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'owner'),
      );
      appServices.put<DBService>(database);
      appServices.put<AccountStorageScopeService>(scopes);
      addTearDown(() async {
        await database.close();
        await databaseFactoryMemory.deleteDatabase(path);
      });
      final reply = _message('A persisted reply', id: null);
      await tester.runAsync(() => database.saveChatMessage(reply));
      final store = ChatReplyFeedbackStore.maybeCurrent()!;
      final target = store.capture(reply)!;
      await _mount(tester, child: Center(child: _bubble(reply)));
      await _open(tester, reply.content);
      bool selected(Key key) =>
          tester.widget<IconButton>(find.byKey(key)).isSelected!;
      expect(
        tester.widget<IconButton>(find.byKey(_goodKey)).onPressed,
        isNotNull,
      );
      expect(selected(_goodKey), isFalse);
      expect(selected(_poorKey), isFalse);
      await tester.tap(find.byKey(_goodKey));
      await _settle(tester);
      expect(selected(_goodKey), isTrue);
      expect(selected(_poorKey), isFalse);
      expect(
        await tester.runAsync(() => store.read(target)),
        ChatReplyFeedback.excellent,
      );
      await tester.tap(find.byKey(_poorKey));
      await _settle(tester);
      expect(selected(_goodKey), isFalse);
      expect(selected(_poorKey), isTrue);
      expect(
        await tester.runAsync(() => store.read(target)),
        ChatReplyFeedback.poor,
      );
      await tester.tap(find.byKey(_poorKey));
      await _settle(tester);
      expect(selected(_goodKey), isFalse);
      expect(selected(_poorKey), isFalse);
      expect(await tester.runAsync(() => store.read(target)), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
