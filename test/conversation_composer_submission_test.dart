import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart' as core;
import 'package:maaso/src/core/widgets/ui/world_composer.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_input_bar.dart'
    as chat;

void main() {
  setUp(() async => appServices.reset());
  tearDown(() async => appServices.reset());

  for (final shared in [true, false]) {
    testWidgets(
      '${shared ? 'core' : 'chat'} busy composer sends nonempty draft and stops only empty input',
      (tester) async {
        final input = TextEditingController();
        var sends = 0;
        var stops = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: shared
                  ? core.ChatInputBar(
                      controller: input,
                      onSend: () => sends++,
                      isThinking: true,
                      onInterrupt: () => stops++,
                    )
                  : chat.ChatInputBar(
                      controller: input,
                      onSend: () => sends++,
                      isThinking: true,
                      onInterrupt: () => stops++,
                    ),
            ),
          ),
        );
        await tester.pump();
        expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
        await tester.tap(find.byType(WorldComposerSendButton));
        expect(stops, 1);
        expect(sends, 0);

        await tester.enterText(find.byType(TextField), 'new question');
        await tester.pump();
        expect(find.byIcon(Icons.arrow_upward), findsOneWidget);
        expect(find.byIcon(Icons.stop_rounded), findsNothing);
        await tester.tap(find.byType(WorldComposerSendButton));
        expect(sends, 1);
        expect(stops, 1);

        input.text = '  ';
        await tester.pump();
        expect(find.byIcon(Icons.stop_rounded), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        input.dispose();
      },
    );
  }

  testWidgets('disabled core composer remains disabled with a busy draft', (
    tester,
  ) async {
    final input = TextEditingController(text: 'cannot send');
    var sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: core.ChatInputBar(
            controller: input,
            onSend: () => sends++,
            isThinking: true,
            enabled: false,
          ),
        ),
      ),
    );
    final button = tester.widget<WorldComposerSendButton>(
      find.byType(WorldComposerSendButton),
    );
    expect(button.enabled, isFalse);
    expect(button.onTap, isNull);
    expect(sends, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    input.dispose();
  });
}
