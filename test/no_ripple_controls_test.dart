import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_controls.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_content.dart';
import 'package:maaso/src/features/agent/application/surface/surface_authoring_theme.dart';

void main() {
  test(
    'new Surface controls disable touch ink while retaining keyboard focus',
    () {
      final anchor =
          jsonDecode(
                File(
                  'design-system/maaso-soft-frost/tokens.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(anchor['interaction']['inkRipple'], isFalse);
      expect(anchor['interaction']['browserTapHighlight'], isFalse);
      final css = SurfaceAuthoringTheme.cssSnapshot();
      expect(css, contains('-webkit-tap-highlight-color:transparent'));
      expect(css, contains(':focus-visible{outline:3px solid'));
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('Material and shared controls have no ripple in $brightness', (
      tester,
    ) async {
      final theme = AppTheme.build(AppPalette.of(brightness, AppAccent.blue));
      final tapped = <String>[];
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Wrap(
              children: <Widget>[
                FilledButton(
                  key: const Key('filled'),
                  onPressed: () => tapped.add('filled'),
                  child: const Text('Filled'),
                ),
                ElevatedButton(
                  key: const Key('elevated'),
                  onPressed: () => tapped.add('elevated'),
                  child: const Text('Elevated'),
                ),
                TextButton(
                  key: const Key('text'),
                  focusNode: focus,
                  onPressed: () => tapped.add('text'),
                  child: const Text('Text'),
                ),
                OutlinedButton(
                  key: const Key('outlined'),
                  onPressed: () => tapped.add('outlined'),
                  child: const Text('Outlined'),
                ),
                IconButton(
                  key: const Key('icon'),
                  onPressed: () => tapped.add('icon'),
                  icon: const Icon(Icons.add),
                ),
                FloatingActionButton(
                  key: const Key('fab'),
                  onPressed: () => tapped.add('fab'),
                  child: const Icon(Icons.add),
                ),
                ActionChip(
                  key: const Key('chip'),
                  onPressed: () => tapped.add('chip'),
                  label: const Text('Chip'),
                ),
                SizedBox(
                  width: 160,
                  child: AppGlassButton(
                    key: const Key('glass'),
                    label: 'Glass',
                    onPressed: () => tapped.add('glass'),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: AppSecondaryCard(
                    key: const Key('card'),
                    onTap: () => tapped.add('card'),
                    child: const Text('Card'),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: AppSecondaryListTile(
                    key: const Key('row'),
                    title: 'Row',
                    onTap: () => tapped.add('row'),
                  ),
                ),
                SizedBox(
                  width: 160,
                  child: AppSecondaryCard(
                    key: const Key('disabled'),
                    tone: AppSecondaryCardTone.disabled,
                    onTap: () => tapped.add('disabled'),
                    child: const Text('Disabled'),
                  ),
                ),
                const SizedBox(
                  width: 240,
                  child: DefaultTabController(
                    length: 2,
                    child: TabBar(
                      tabs: [
                        Tab(text: 'One'),
                        Tab(text: 'Two'),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final inkElements = find
          .byWidgetPredicate((widget) => widget is InkResponse)
          .evaluate();
      expect(inkElements.length, greaterThanOrEqualTo(13));
      for (final element in inkElements) {
        final ink = element.widget as InkResponse;
        expect(
          ink.splashFactory ?? Theme.of(element).splashFactory,
          same(NoSplash.splashFactory),
          reason: element.toStringShort(),
        );
      }
      for (final name in [
        'filled',
        'elevated',
        'text',
        'outlined',
        'icon',
        'fab',
        'chip',
        'glass',
        'card',
        'row',
      ]) {
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(Key(name))),
        );
        await tester.pump(const Duration(milliseconds: 80));
        await gesture.up();
        await tester.pumpAndSettle();
        expect(tapped.last, name);
      }
      await tester.tap(find.byKey(const Key('disabled')));
      await tester.pumpAndSettle();
      expect(tapped, isNot(contains('disabled')));
      focus.requestFocus();
      await tester.pump();
      expect(focus.hasFocus, isTrue);
      expect(theme.focusColor.a, greaterThan(0));
      expect(theme.hoverColor.a, greaterThan(0));
      expect(theme.splashColor.a, 0);
      expect(theme.highlightColor.a, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
