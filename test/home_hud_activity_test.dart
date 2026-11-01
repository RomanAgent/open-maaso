import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';

// Actual pointer dispatch matters: the excluded descendant must be visited
// before the page listener, including when a menu closes the input keyboard.
void main() {
  late HomeChatInteraction interaction;
  late StateSetter update;
  var messageRevision = 0;
  var keyboard = false;
  var keepVisible = false;
  var windowOpacity = 1.0;

  Future<void> mount(WidgetTester tester) async {
    messageRevision = 0;
    keyboard = false;
    keepVisible = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeChatInteractionScope(
            child: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                interaction = HomeChatInteractionScope.maybeOf(context)!;
                return MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    viewInsets: EdgeInsets.only(bottom: keyboard ? 200 : 0),
                  ),
                  child: Column(
                    children: [
                      HomeChatActivityExclusion(
                        child: TextButton(
                          key: const ValueKey('menu'),
                          onPressed: () {
                            interaction.setMenuExpanded(
                              !interaction.menuExpanded,
                            );
                            interaction.focusNode.unfocus();
                          },
                          child: const Text('Menu'),
                        ),
                      ),
                      if (interaction.menuExpanded)
                        HomeChatActivityExclusion(
                          child: TextButton(
                            key: const ValueKey('menu-dismiss'),
                            onPressed: () => interaction.setMenuExpanded(false),
                            child: const Text('Dismiss menu'),
                          ),
                        ),
                      SizedBox(
                        width: 250,
                        height: 180,
                        child: HomeChatActivityRegion(
                          wakeOnPointerDown: false,
                          child: ChatWindowVisibility(
                            suppressed: interaction.menuExpanded,
                            explicitWakeOnly: true,
                            onUserInteraction: interaction.activity,
                            dismissToken: interaction.dismissToken,
                            resumeAfterSuppression:
                                interaction.resumeAfterSuppression,
                            activityToken: interaction.activityToken,
                            keepVisible: keepVisible || interaction.hasFocus,
                            presentationBuilder: (_, child, opacity) {
                              windowOpacity = opacity;
                              return Opacity(opacity: opacity, child: child);
                            },
                            child: Center(
                              child: Text('Conversation $messageRevision'),
                            ),
                          ),
                        ),
                      ),
                      HomeChatActivityRegion(
                        child: TextField(
                          key: const ValueKey('composer'),
                          focusNode: interaction.focusNode,
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('header tap and both menu closing paths never wake idle chat', (
    tester,
  ) async {
    await mount(tester);
    await tester.pump(const Duration(seconds: 30));
    await settle(tester);
    expect(windowOpacity, 0);
    final activity = interaction.activityToken;
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    expect(interaction.activityToken, activity);
    expect(interaction.menuExpanded, isTrue);
    expect(windowOpacity, 0);
    await tester.tap(find.byKey(const ValueKey('menu-dismiss')));
    await settle(tester);
    expect(windowOpacity, 0);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    expect(interaction.activityToken, activity);
    expect(windowOpacity, 0);
    await tester.tap(find.byKey(const ValueKey('chat-window-wake-region')));
    await settle(tester);
    expect(windowOpacity, 1);
  });

  testWidgets('opening menu hides visible chat and blocks arriving replies', (
    tester,
  ) async {
    await mount(tester);
    expect(windowOpacity, 1);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    expect(windowOpacity, 0);
    update(() {
      messageRevision++;
      keepVisible = true;
    });
    await settle(tester);
    expect(windowOpacity, 0);
    expect(find.byKey(const ValueKey('chat-window-wake-region')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    expect(windowOpacity, 0);
    update(() => messageRevision++);
    await settle(tester);
    expect(windowOpacity, 0);
    await tester.tap(find.byKey(const ValueKey('chat-window-wake-region')));
    await settle(tester);
    expect(windowOpacity, 1);
  });

  testWidgets('menu dismissal during keyboard transition stays hidden', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const ValueKey('composer')));
    update(() => keyboard = true);
    await settle(tester);
    expect(interaction.hasFocus, isTrue);
    expect(windowOpacity, 1);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    expect(interaction.hasFocus, isFalse);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    update(() => keyboard = false);
    await settle(tester);
    expect(windowOpacity, 0);
    // A new input session is genuine activity; its ordinary completion restores.
    await tester.tap(find.byKey(const ValueKey('composer')));
    await settle(tester);
    expect(interaction.hasFocus, isTrue);
    expect(interaction.resumeAfterSuppression, isTrue);
    interaction.focusNode.unfocus();
    await settle(tester);
    expect(windowOpacity, 1);
  });

  testWidgets('semantic activation dismisses without requiring a pointer', (
    tester,
  ) async {
    await mount(tester);
    final button = tester.widget<TextButton>(
      find.byKey(const ValueKey('menu')),
    );
    button.onPressed!();
    await settle(tester);
    expect(windowOpacity, 0);
    button.onPressed!();
    await settle(tester);
    expect(windowOpacity, 0);
    expect(interaction.activityToken, 0);
  });

  testWidgets('finishing existing playback does not undo HUD dismissal', (
    tester,
  ) async {
    await mount(tester);
    update(() => keepVisible = true);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('menu')));
    await settle(tester);
    expect(windowOpacity, 0);
    update(() => keepVisible = false);
    await settle(tester);
    expect(windowOpacity, 0);
    update(() => messageRevision++);
    await settle(tester);
    expect(windowOpacity, 0);
    await tester.tap(find.byKey(const ValueKey('chat-window-wake-region')));
    await settle(tester);
    expect(windowOpacity, 1);
  });
}

Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 260));
  await tester.pump(const Duration(milliseconds: 260));
}
