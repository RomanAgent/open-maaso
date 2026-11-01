import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

void main() {
  testWidgets('press, cancel and rapid selection paint only one capsule', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AppFrostSegmentedControl<int>(
              selected: selected,
              onSelected: (value) => setState(() => selected = value),
              segments: const [
                AppFrostSegment(value: 0, label: 'All', key: ValueKey(0)),
                AppFrostSegment(value: 1, label: 'Games', key: ValueKey(1)),
                AppFrostSegment(value: 2, label: 'Travel', key: ValueKey(2)),
              ],
            ),
          ),
        ),
      ),
    );
    void expectOneCapsule() {
      final paintedCapsules = tester.allRenderObjects
          .whereType<RenderDecoratedBox>()
          .where((box) {
            final decoration = box.decoration;
            return decoration is BoxDecoration &&
                (decoration.color?.a ?? 0) > 0 &&
                (decoration.boxShadow?.any(
                      (shadow) => shadow.blurRadius == 8,
                    ) ??
                    false);
          });
      expect(paintedCapsules, hasLength(1));
      for (var index = 0; index < 3; index++) {
        expect(
          tester
              .getSemantics(find.byKey(ValueKey(index)))
              .flagsCollection
              .isSelected,
          index == selected ? Tristate.isTrue : Tristate.isFalse,
        );
      }
      for (final button in tester.widgetList<TextButton>(
        find.byType(TextButton),
      )) {
        expect(
          button.style!.overlayColor!.resolve({WidgetState.pressed}),
          Colors.transparent,
        );
      }
    }

    expectOneCapsule();
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Games')),
    );
    await tester.pump(const Duration(milliseconds: 80));
    expect(selected, 0);
    expectOneCapsule();
    await gesture.cancel();
    await tester.pump(const Duration(milliseconds: 80));
    expectOneCapsule();
    for (final label in ['Games', 'Travel', 'All', 'Games']) {
      await tester.tap(find.text(label));
      await tester.pump();
      expectOneCapsule();
      await tester.pump(const Duration(milliseconds: 80));
      expectOneCapsule();
    }
  });
  testWidgets('segment measurement and labels inherit the theme font', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'ThemeFont'),
        home: Scaffold(
          body: AppFrostSegmentedControl<int>(
            selected: 0,
            onSelected: (_) {},
            segments: const [
              AppFrostSegment(value: 0, label: '个性'),
              AppFrostSegment(value: 1, label: '共同回忆'),
            ],
          ),
        ),
      ),
    );
    for (final button in tester.widgetList<TextButton>(
      find.byType(TextButton),
    )) {
      expect(button.style!.textStyle!.resolve({})!.fontFamily, 'ThemeFont');
    }
    expect(tester.takeException(), isNull);
  });

  for (final direction in TextDirection.values) {
    testWidgets('keyboard skips disabled segments in $direction', (
      tester,
    ) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: StatefulBuilder(
                builder: (context, setState) => AppFrostSegmentedControl<int>(
                  selected: selected,
                  onSelected: (value) => setState(() => selected = value),
                  segments: const [
                    AppFrostSegment(value: 0, label: 'First', key: ValueKey(0)),
                    AppFrostSegment(
                      value: 1,
                      label: 'Unavailable',
                      key: ValueKey(1),
                      enabled: false,
                    ),
                    AppFrostSegment(value: 2, label: 'Last', key: ValueKey(2)),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      final firstButton = tester.widget<TextButton>(
        find.descendant(
          of: find.byKey(const ValueKey(0)),
          matching: find.byType(TextButton),
        ),
      );
      firstButton.focusNode!.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(
        direction == TextDirection.ltr
            ? LogicalKeyboardKey.arrowRight
            : LogicalKeyboardKey.arrowLeft,
      );
      await tester.pump();
      expect(selected, 2);
      expect(
        tester
            .getSemantics(find.byKey(const ValueKey(2)))
            .flagsCollection
            .isSelected,
        Tristate.isTrue,
      );
      await tester.tap(find.byKey(const ValueKey(1)));
      expect(selected, 2);
    });
  }

  testWidgets('large text reflows with complete labels and 48 dp targets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SizedBox(
              width: 320,
              child: AppFrostSegmentedControl<int>(
                selected: 0,
                onSelected: (_) {},
                segments: const [
                  AppFrostSegment(
                    value: 0,
                    label: 'Personal information',
                    key: ValueKey(0),
                  ),
                  AppFrostSegment(
                    value: 1,
                    label: 'Our shared memories',
                    key: ValueKey(1),
                  ),
                  AppFrostSegment(value: 2, label: 'Moments', key: ValueKey(2)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    for (var index = 0; index < 3; index++) {
      expect(
        tester.getSize(find.byKey(ValueKey(index))).height,
        greaterThanOrEqualTo(48),
      );
    }
    expect(
      tester.getTopLeft(find.byKey(const ValueKey(1))).dy,
      greaterThan(tester.getTopLeft(find.byKey(const ValueKey(0))).dy),
    );
    final labels = tester.widgetList<Text>(find.byType(Text));
    expect(
      labels.every((text) => text.maxLines == null && text.overflow == null),
      isTrue,
    );
  });

  testWidgets('TabController and frosted choices stay in sync', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: DefaultTabController(
          length: 2,
          child: Scaffold(
            body: Column(
              children: [
                AppFrostTabBar(labels: ['Models', 'Actions']),
                Expanded(
                  child: TabBarView(
                    children: [Text('Model body'), Text('Action body')],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Actions'));
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(AppFrostTabBar));
    expect(DefaultTabController.of(context).index, 1);
    DefaultTabController.of(context).animateTo(0);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<AppFrostSegmentedControl<int>>(
            find.byType(AppFrostSegmentedControl<int>),
          )
          .selected,
      0,
    );
    expect(find.text('Model body').hitTestable(), findsOneWidget);
  });

  testWidgets('one borderless rail material is shared by all segments', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppFrostSegmentedControl<int>(
            selected: 0,
            onSelected: (_) {},
            segments: const [
              AppFrostSegment(value: 0, label: 'One'),
              AppFrostSegment(value: 1, label: 'Two'),
            ],
          ),
        ),
      ),
    );
    expect(find.byType(AppGlassSurface), findsOneWidget);
    final selected = tester.widget<DecoratedBox>(
      find.byKey(const ValueKey('app-frost-selected-indicator')),
    );
    expect((selected.decoration as BoxDecoration).border, isNull);
  });
}
