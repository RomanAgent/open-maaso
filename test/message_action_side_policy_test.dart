import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_actions.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

const _menuKey = ValueKey('message-action-menu');
const _copyKey = ValueKey('message-copy-action');
const _goodKey = ValueKey('message-feedback-excellent');
const _poorKey = ValueKey('message-feedback-poor');

ChatMessage _message({required bool user, String? text}) => ChatMessage(
  id: user ? 2 : 1,
  sessionId: 'self',
  senderId: user ? 'user' : 'self',
  receiverId: user ? 'self' : 'user',
  content: text ?? (user ? '用户消息操作' : 'Agent 消息操作'),
  timestamp: DateTime(2026, 9, 22, 14, 8),
  isUserMessage: user,
  deliveryStatus: 'published',
);

Widget _bubble(ChatMessage message, {MessageActionSidePolicy? sidePolicy}) =>
    sidePolicy == null
    ? MessageBubble(message: message)
    : MessageBubble(message: message, actionSidePolicy: sidePolicy);

Finder _surface(ChatMessage message) => find.ancestor(
  of: find.text(message.content),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is AppGlassSurface && widget.role == AppGlassSurfaceRole.message,
  ),
);

Future<void> _mount(
  WidgetTester tester, {
  required Widget child,
  Size size = const Size(600, 800),
  TextDirection direction = TextDirection.ltr,
  double textScale = 1,
  EdgeInsets padding = EdgeInsets.zero,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
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

Future<void> _open(WidgetTester tester, ChatMessage message) async {
  await tester.tap(find.text(message.content));
  for (var frame = 0; frame < 9; frame++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(find.byKey(_menuKey), findsOneWidget);
}

void _expectRoleActions({required bool user}) {
  expect(find.byKey(_copyKey), findsOneWidget);
  expect(find.byKey(_goodKey), user ? findsNothing : findsOneWidget);
  expect(find.byKey(_poorKey), user ? findsNothing : findsOneWidget);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  for (final user in [false, true]) {
    for (final direction in TextDirection.values) {
      testWidgets(
        'default full chat puts ${user ? 'user left' : 'Agent right'} in $direction',
        (tester) async {
          final message = _message(user: user);
          await _mount(
            tester,
            direction: direction,
            child: Center(child: SizedBox(width: 260, child: _bubble(message))),
          );
          final bubbleBefore = tester.getRect(_surface(message));
          await _open(tester, message);
          final menu = tester.getRect(find.byKey(_menuKey));
          final anchor = tester.getRect(find.byType(MessageActionsAnchor));
          if (user) {
            expect(menu.right, closeTo(anchor.left - 8, .1));
          } else {
            expect(menu.left, closeTo(anchor.right + 8, .1));
          }
          expect(tester.getRect(_surface(message)), bubbleBefore);
          _expectRoleActions(user: user);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );

      testWidgets(
        'avatar policy puts ${user ? 'user' : 'Agent'} actions left in $direction',
        (tester) async {
          final message = _message(user: user);
          await _mount(
            tester,
            direction: direction,
            child: Center(
              child: SizedBox(
                width: 260,
                child: _bubble(
                  message,
                  sidePolicy: MessageActionSidePolicy.left,
                ),
              ),
            ),
          );
          final bubbleBefore = tester.getRect(_surface(message));
          await _open(tester, message);
          final menu = tester.getRect(find.byKey(_menuKey));
          final anchor = tester.getRect(find.byType(MessageActionsAnchor));
          expect(menu.right, closeTo(anchor.left - 8, .1));
          expect(menu.overlaps(bubbleBefore), isFalse);
          expect(tester.getRect(_surface(message)), bubbleBefore);
          _expectRoleActions(user: user);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        },
      );
    }

    for (final width in [180.0, 280.0]) {
      for (final atBottom in [false, true]) {
        testWidgets(
          'avatar ${user ? 'user' : 'Agent'} actions keep left fallback ${atBottom ? 'above' : 'below'} at $width',
          (tester) async {
            final message = _message(user: user, text: '较长消息供人物小窗的窄屏菜单定位验证');
            await _mount(
              tester,
              size: Size(width, 640),
              textScale: 2,
              padding: const EdgeInsets.only(top: 24, bottom: 16),
              child: SafeArea(
                child: Column(
                  children: [
                    if (atBottom) const Spacer(),
                    _bubble(message, sidePolicy: MessageActionSidePolicy.left),
                    if (!atBottom) const Spacer(),
                  ],
                ),
              ),
            );
            await _open(tester, message);
            final menu = tester.getRect(find.byKey(_menuKey));
            final anchor = tester.getRect(find.byType(MessageActionsAnchor));
            final bubble = tester.getRect(_surface(message));
            expect(menu.left, greaterThanOrEqualTo(8));
            expect(menu.right, lessThanOrEqualTo(width - 8));
            expect(menu.top, greaterThanOrEqualTo(32));
            expect(menu.bottom, lessThanOrEqualTo(616));
            expect(menu.overlaps(bubble), isFalse);
            expect(menu.left, closeTo(anchor.left.clamp(8, width - 8), .1));
            if (atBottom) {
              expect(menu.bottom, closeTo(anchor.top - 8, .1));
            } else {
              expect(menu.top, closeTo(anchor.bottom + 8, .1));
            }
            _expectRoleActions(user: user);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }
}
