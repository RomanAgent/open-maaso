import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/immersive_feed_tab.dart';

void main() {
  for (final width in [320.0, 390.0, 844.0]) {
    testWidgets('media tabs keep labels and hit targets at 2x text, $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(fontFamily: 'sans-serif'),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(width: 56),
                    Expanded(
                      child: Wrap(
                        children: [
                          for (final label in [
                            'For You',
                            'Popular',
                            'My Games',
                          ])
                            ImmersiveFeedTab(
                              label: label,
                              selected: label == 'For You',
                              onPressed: () {},
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      for (final label in ['For You', 'Popular', 'My Games']) {
        expect(find.text(label), findsOneWidget);
      }
      for (final element in find.byType(TextButton).evaluate()) {
        final button = element.widget as TextButton;
        final size = tester.getSize(find.byWidget(button));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        expect(button.style!.textStyle!.resolve({})!.fontFamily, 'sans-serif');
        expect(button.style!.backgroundColor!.resolve({}), Colors.transparent);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('media tab is keyboard operable and exposes selection', (
    tester,
  ) async {
    var selections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ImmersiveFeedTab(
            label: '推荐',
            selected: true,
            onPressed: () => selections++,
          ),
        ),
      ),
    );
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('推荐'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(selections, 1);
    semantics.dispose();
  });
}
