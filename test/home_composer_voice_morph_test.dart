import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_composer_morph.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_composer_footprint.dart';

void main() {
  testWidgets(
    'send starts at the right, rolls to center, and preserves editor State',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(width: 347, child: _Harness(key: key)),
            ),
          ),
        ),
      );
      final editor = tester.state(find.byType(_Editor));
      final body = tester.getRect(find.byType(HomeComposerMorph));
      final start = tester.getRect(
        find.byKey(HomeComposerMorph.movingControlKey),
      );
      expect(body.height, 124);
      expect(start.size, const Size(48, 48));
      expect(start.right, body.right - 8);
      expect(find.byKey(const ValueKey('send')).hitTestable(), findsOneWidget);
      key.currentState!.toggle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 310));
      expect(
        tester.getSize(find.byType(HomeComposerMorph)).height,
        greaterThanOrEqualTo(112),
      );
      final halfway = tester.getRect(
        find.byKey(HomeComposerMorph.movingControlKey),
      );
      expect(halfway.center.dx, lessThan(start.center.dx));
      expect(halfway.center.dx, greaterThan(body.center.dx));
      expect(find.byKey(const ValueKey('send')).hitTestable(), findsNothing);
      expect(find.byKey(const ValueKey('orb')).hitTestable(), findsNothing);
      await tester.pump(const Duration(milliseconds: 400));
      final finish = tester.getRect(
        find.byKey(HomeComposerMorph.movingControlKey),
      );
      expect(finish.size, const Size(56, 56));
      expect(finish.center.dx, body.center.dx);
      expect(tester.getSize(find.byType(HomeComposerMorph)).height, 112);
      expect(find.byIcon(Icons.keyboard), findsNothing);
      expect(find.byIcon(Icons.pause), findsNothing);
      expect(tester.state(find.byType(_Editor)), same(editor));
      await tester.tap(find.byKey(const ValueKey('orb')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.state(find.byType(_Editor)), same(editor));
      expect(
        tester.getRect(find.byKey(HomeComposerMorph.movingControlKey)),
        start,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reduced motion changes mode immediately and footprint follows content',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      final heights = <double>[];
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(disableAnimations: true),
            child: Center(
              child: SizedBox(
                width: 320,
                child: HomeComposerFootprint(
                  onHeight: heights.add,
                  child: _Harness(key: key),
                ),
              ),
            ),
          ),
        ),
      );
      expect(heights.last, 124);
      key.currentState!.toggle();
      await tester.pump();
      await tester.pump();
      expect(heights.last, 112);
      expect(find.byKey(const ValueKey('orb')).hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Harness extends StatefulWidget {
  const _Harness({super.key});
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool voice = false;
  void toggle() => setState(() => voice = !voice);
  @override
  Widget build(BuildContext context) => HomeComposerMorph(
    voiceMode: voice,
    content: const SizedBox(height: 124, child: _Editor()),
    sendControl: IconButton(
      key: const ValueKey('send'),
      onPressed: () {},
      icon: const Icon(Icons.arrow_upward),
    ),
    voiceControlBuilder: (_, _) => IconButton(
      key: const ValueKey('orb'),
      onPressed: toggle,
      icon: const Icon(Icons.circle),
    ),
    voiceLabel: 'Tap the orb to return to typing',
  );
}

class _Editor extends StatefulWidget {
  const _Editor();
  @override
  State<_Editor> createState() => _EditorState();
}

class _EditorState extends State<_Editor> {
  @override
  Widget build(BuildContext context) => const Text('Draft');
}
