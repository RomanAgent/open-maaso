import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';

const _windowKey = ValueKey('test-chat-window');

Future<void> _mount(
  WidgetTester tester, {
  bool enabled = true,
  bool keepVisible = false,
  bool suppressed = false,
  bool reducedMotion = false,
  bool explicitWakeOnly = false,
  Object? dismissToken,
  Object? activityToken,
  VoidCallback? onUserInteraction,
  Widget? child,
  Widget? behind,
  ChatWindowPresentationBuilder? presentationBuilder,
}) => tester.pumpWidget(
  MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Scaffold(
        body: Stack(
          children: [
            if (behind != null) Positioned.fill(child: behind),
            Center(
              child: SizedBox(
                width: 260,
                height: 180,
                child: ChatWindowVisibility(
                  key: _windowKey,
                  enabled: enabled,
                  keepVisible: keepVisible,
                  suppressed: suppressed,
                  explicitWakeOnly: explicitWakeOnly,
                  dismissToken: dismissToken,
                  activityToken: activityToken,
                  onUserInteraction: onUserInteraction,
                  presentationBuilder: presentationBuilder,
                  child: child ?? const Center(child: Text('Chat history')),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  ),
);

double _opacity(WidgetTester tester) => tester
    .widget<Opacity>(
      find.descendant(
        of: find.byKey(_windowKey),
        matching: find.byType(Opacity),
      ),
    )
    .opacity;

Future<void> _finishFade(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 240));
}

void main() {
  testWidgets('explicit wake cancels an idle fade before its first tick', (
    tester,
  ) async {
    await _mount(tester, explicitWakeOnly: true);
    await tester.pump(const Duration(seconds: 30));
    // Visibility has changed, but opacity is still at the old target.
    expect(
      find.byKey(const ValueKey('chat-window-wake-region')),
      findsOneWidget,
    );
    await _mount(tester, explicitWakeOnly: true, activityToken: 1);
    await _finishFade(tester);
    expect(_opacity(tester), 1);
    expect(find.byKey(const ValueKey('chat-window-wake-region')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'outside dismissal cancels held message action, not scene touch',
    (tester) async {
      var actions = 0;
      var sceneTaps = 0;
      final child = TextButton(
        onPressed: () => actions++,
        child: const Text('Run action'),
      );
      final behind = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => sceneTaps++,
      );
      await _mount(
        tester,
        explicitWakeOnly: true,
        child: child,
        behind: behind,
      );
      final first = await tester.startGesture(
        tester.getCenter(find.text('Run action')),
        pointer: 31,
      );
      final outside = await tester.startGesture(
        const Offset(20, 20),
        pointer: 32,
      );
      await _mount(
        tester,
        explicitWakeOnly: true,
        dismissToken: 1,
        child: child,
        behind: behind,
      );
      await tester.pump();
      expect(_opacity(tester), 0);
      await outside.up();
      await first.up();
      await tester.pump();
      expect(sceneTaps, 1);
      expect(actions, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('explicit wake ignores playback, automatic scroll and resume', (
    tester,
  ) async {
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    final child = ListView(
      controller: scroll,
      children: List.generate(
        20,
        (index) => SizedBox(height: 48, child: Text('Message $index')),
      ),
    );
    await _mount(tester, explicitWakeOnly: true, child: child);
    await _mount(tester, explicitWakeOnly: true, dismissToken: 1, child: child);
    expect(_opacity(tester), 0);
    await _mount(
      tester,
      explicitWakeOnly: true,
      dismissToken: 1,
      keepVisible: true,
      child: child,
    );
    scroll.jumpTo(80);
    await tester.sendEventToBinding(
      PointerScrollEvent(
        position: tester.getCenter(find.byKey(_windowKey)),
        scrollDelta: const Offset(0, 20),
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _finishFade(tester);
    expect(_opacity(tester), 0);
    await _mount(
      tester,
      explicitWakeOnly: true,
      dismissToken: 1,
      activityToken: 1,
      keepVisible: true,
      child: child,
    );
    await _finishFade(tester);
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 90));
    expect(_opacity(tester), 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'explicit hidden region waits for a tap and protects the first action',
    (tester) async {
      var actions = 0;
      var interactions = 0;
      final child = TextButton(
        onPressed: () => actions++,
        child: const Text('Message action'),
      );
      await _mount(
        tester,
        explicitWakeOnly: true,
        child: child,
        onUserInteraction: () => interactions++,
      );
      await _mount(
        tester,
        explicitWakeOnly: true,
        dismissToken: 1,
        child: child,
        onUserInteraction: () => interactions++,
      );
      await tester.drag(find.byKey(_windowKey), const Offset(0, -60));
      await _finishFade(tester);
      expect(_opacity(tester), 0);
      expect(interactions, 0);
      await tester.tapAt(tester.getCenter(find.byKey(_windowKey)));
      await _finishFade(tester);
      expect(_opacity(tester), 1);
      expect(interactions, 1);
      expect(actions, 0);
      await tester.tap(find.text('Message action'));
      expect(actions, 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('explicit mode restarts idle timer without revealing on resume', (
    tester,
  ) async {
    await _mount(tester, explicitWakeOnly: true);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(seconds: 30));
    await _finishFade(tester);
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('suppression wins over activity and passes taps to the scene', (
    tester,
  ) async {
    var backgroundTaps = 0;
    var messageTaps = 0;
    final behind = GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => backgroundTaps++,
    );
    final child = TextButton(
      onPressed: () => messageTaps++,
      child: const Text('Message action'),
    );
    await _mount(tester, child: child, behind: behind);
    await _mount(
      tester,
      suppressed: true,
      enabled: false,
      keepVisible: true,
      activityToken: 1,
      child: child,
      behind: behind,
    );
    expect(_opacity(tester), 0);
    expect(find.byKey(const ValueKey('chat-window-wake-region')), findsNothing);
    await tester.tapAt(tester.getCenter(find.byKey(_windowKey)));
    expect(backgroundTaps, 1);
    expect(messageTaps, 0);
    await _mount(
      tester,
      suppressed: true,
      keepVisible: true,
      activityToken: 2,
      child: child,
      behind: behind,
    );
    await tester.pump(const Duration(minutes: 2));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(_opacity(tester), 0);
    await _mount(tester, child: child, behind: behind);
    await _finishFade(tester);
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 29));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(seconds: 1));
    await _finishFade(tester);
    expect(_opacity(tester), 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('visibility scope updates reused descendants before fade ends', (
    tester,
  ) async {
    var visible = false;
    final child = Builder(
      builder: (context) {
        visible = ChatWindowVisibilityScope.visibleOf(context);
        return const Text('Message with external actions');
      },
    );
    await _mount(tester, child: child);
    expect(visible, isTrue);
    await tester.pump(const Duration(seconds: 30));
    expect(visible, isFalse);
    await _mount(tester, activityToken: 1, child: child);
    await _finishFade(tester);
    expect(visible, isTrue);
    await _mount(tester, suppressed: true, child: child);
    expect(visible, isFalse);
    expect(_opacity(tester), 0);
    await _mount(tester, child: child);
    expect(visible, isTrue);
    await tester.pumpWidget(MaterialApp(home: child));
    expect(
      visible,
      isTrue,
    ); // Ordinary full-screen chat has no visibility scope.
  });

  testWidgets('initial suppression allocates no wake layer or idle timer', (
    tester,
  ) async {
    await _mount(tester, suppressed: true);
    expect(_opacity(tester), 0);
    await tester.pump(const Duration(minutes: 2));
    expect(tester.binding.hasScheduledFrame, isFalse);
    expect(find.byKey(const ValueKey('chat-window-wake-region')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('suppression cancels a wake animation before its first tick', (
    tester,
  ) async {
    await _mount(tester);
    await tester.pump(const Duration(seconds: 30));
    await _finishFade(tester);
    await _mount(tester, activityToken: 1);
    expect(_opacity(tester), 0);
    await _mount(tester, suppressed: true);
    await _finishFade(tester);
    expect(_opacity(tester), 0);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('starts visible and fades after exactly thirty idle seconds', (
    tester,
  ) async {
    await _mount(tester);
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 29999));
    expect(_opacity(tester), 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(
      find.byKey(const ValueKey('chat-window-wake-region')),
      findsOneWidget,
    );
    await _finishFade(tester);
    expect(_opacity(tester), 0);
    expect(tester.getSize(find.byKey(_windowKey)), const Size(260, 180));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('hidden content has no semantics and the first tap only wakes', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    var reports = 0;
    await _mount(
      tester,
      child: Center(
        child: TextButton(
          onPressed: () => reports++,
          child: const Text('Report reply'),
        ),
      ),
    );
    final target = tester.getCenter(find.text('Report reply'));
    expect(
      tester.semantics.simulatedAccessibilityTraversal(),
      contains(isSemantics(label: 'Report reply', isButton: true)),
    );
    await tester.pump(const Duration(seconds: 30));
    // Actions are blocked as soon as fading out begins, not only at zero alpha.
    expect(
      tester.semantics.simulatedAccessibilityTraversal(),
      isNot(contains(isSemantics(label: 'Report reply', isButton: true))),
    );
    await _finishFade(tester);
    await tester.tapAt(target);
    await _finishFade(tester);
    expect(reports, 0);
    expect(_opacity(tester), 1);
    expect(
      tester.semantics.simulatedAccessibilityTraversal(),
      contains(isSemantics(label: 'Report reply', isButton: true)),
    );
    await tester.tapAt(target);
    expect(reports, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });

  testWidgets(
    'activity and keep-visible changes wake and restart the idle deadline',
    (tester) async {
      await _mount(tester, activityToken: 0);
      await tester.pump(const Duration(seconds: 30));
      await _finishFade(tester);
      expect(_opacity(tester), 0);
      await _mount(tester, activityToken: 1);
      await _finishFade(tester);
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 25));
      await _mount(tester, activityToken: 2, keepVisible: true);
      await tester.pump(const Duration(seconds: 90));
      expect(_opacity(tester), 1);
      await _mount(tester, activityToken: 2);
      await tester.pump(const Duration(seconds: 29));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      await _finishFade(tester);
      expect(_opacity(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'hidden actions relinquish keyboard focus and cannot be invoked',
    (tester) async {
      final focus = FocusNode();
      var reports = 0;
      await _mount(
        tester,
        child: Center(
          child: TextButton(
            focusNode: focus,
            onPressed: () => reports++,
            child: const Text('Report reply'),
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(reports, 1);
      await tester.pump(const Duration(seconds: 30));
      await _finishFade(tester);
      expect(focus.hasFocus, isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(reports, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      focus.dispose();
    },
  );

  testWidgets(
    'a held pointer prevents fading and release starts a fresh deadline',
    (tester) async {
      await _mount(tester);
      final pointer = await tester.startGesture(
        tester.getCenter(find.byKey(_windowKey)),
      );
      await tester.pump(const Duration(seconds: 60));
      expect(_opacity(tester), 1);
      await pointer.up();
      await tester.pump(const Duration(seconds: 29));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      await _finishFade(tester);
      expect(_opacity(tester), 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'scrolling resets idle time and hidden scroll gestures wake without activating actions',
    (tester) async {
      final scroll = ScrollController();
      addTearDown(scroll.dispose);
      await _mount(
        tester,
        child: ListView(
          controller: scroll,
          children: const [SizedBox(height: 1000)],
        ),
      );
      await tester.pump(const Duration(seconds: 25));
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(find.byKey(_windowKey)),
          scrollDelta: const Offset(0, 100),
          kind: PointerDeviceKind.mouse,
        ),
      );
      await tester.pump();
      expect(scroll.offset, 100);
      await tester.pump(const Duration(seconds: 29));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      await _finishFade(tester);
      expect(_opacity(tester), 0);
      final oldOffset = scroll.offset;
      await tester.drag(find.byKey(_windowKey), const Offset(0, -70));
      await _finishFade(tester);
      expect(_opacity(tester), 1);
      expect(scroll.offset, oldOffset);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'custom native presenter receives alpha without an extra Opacity layer',
    (tester) async {
      var alpha = -1.0;
      await _mount(
        tester,
        presentationBuilder: (context, child, opacity) {
          alpha = opacity;
          return child;
        },
      );
      expect(alpha, 1);
      await tester.pump(const Duration(seconds: 30));
      await tester.pump(const Duration(milliseconds: 100));
      expect(alpha, inExclusiveRange(0, 1));
      await _finishFade(tester);
      expect(alpha, 0);
      expect(
        find.descendant(
          of: find.byKey(_windowKey),
          matching: find.byType(Opacity),
        ),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'inactive suspends the deadline and resumed shows a fresh thirty seconds',
    (tester) async {
      await _mount(tester);
      await tester.pump(const Duration(seconds: 20));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await tester.pump(const Duration(minutes: 2));
      expect(_opacity(tester), 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 29));
      expect(_opacity(tester), 1);
      await tester.pump(const Duration(seconds: 1));
      await _finishFade(tester);
      expect(_opacity(tester), 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _finishFade(tester);
      expect(_opacity(tester), 1);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reduced motion changes visibility immediately and disabled mode stays visible',
    (tester) async {
      await _mount(tester, reducedMotion: true);
      await tester.pump(const Duration(seconds: 30));
      expect(_opacity(tester), 0);
      await _mount(tester, reducedMotion: true, activityToken: 1);
      expect(_opacity(tester), 1);
      await _mount(tester, reducedMotion: true, enabled: false);
      await tester.pump(const Duration(minutes: 2));
      expect(_opacity(tester), 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('dispose cancels the idle timer and a running fade', (
    tester,
  ) async {
    await _mount(tester);
    await tester.pump(const Duration(seconds: 30));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
    expect(tester.takeException(), isNull);
    expect(tester.binding.hasScheduledFrame, isFalse);
    await _mount(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(minutes: 2));
    expect(tester.takeException(), isNull);
  });
}
