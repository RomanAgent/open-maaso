import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

void main() {
  for (final direction in TextDirection.values) {
    testWidgets('message time stays hidden until selected at 2x $direction', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Directionality(
              textDirection: direction,
              child: Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 218,
                    child: MessageBubble(
                      message: ChatMessage(
                        sessionId: 'self',
                        senderId: 'self',
                        receiverId: 'user',
                        content: '可以看看今天的计划。',
                        timestamp: DateTime(2026, 9, 15, 14, 8),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.text('14:08'), findsNothing);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
      final before = tester.getRect(find.text('可以看看今天的计划。'));
      await tester.tap(find.text('可以看看今天的计划。'));
      await tester.pumpAndSettle();
      expect(find.text('14:08'), findsOneWidget);
      expect(tester.getRect(find.text('可以看看今天的计划。')), before);
      expect(
        tester.getRect(find.byKey(const ValueKey('message-action-menu'))).left,
        greaterThan(before.right),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('message-copy-action'))),
        const Size(24, 24),
      );
      await tester.tapAt(const Offset(8, 8));
      await tester.pumpAndSettle();
      expect(find.text('14:08'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('selected UTC and local messages show the same local time', (
    tester,
  ) async {
    final local = DateTime(2026, 9, 3, 10, 56);
    final clock =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final item in [
                (local.toUtc(), 'UTC reply'),
                (local, 'Local reply'),
              ])
                MessageBubble(
                  message: ChatMessage(
                    sessionId: 'self',
                    senderId: 'user',
                    receiverId: 'self',
                    content: item.$2,
                    timestamp: item.$1,
                    isUserMessage: true,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
    expect(find.text(clock), findsNothing);
    for (final content in ['UTC reply', 'Local reply']) {
      await tester.tap(find.text(content));
      await tester.pumpAndSettle();
      expect(find.text(clock), findsOneWidget);
      expect(
        find.byKey(const ValueKey('message-feedback-excellent')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('message-feedback-poor')), findsNothing);
      await tester.tapAt(const Offset(8, 400));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
  });
}
