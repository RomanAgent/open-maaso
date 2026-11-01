import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';
import 'package:maaso/src/features/widgets_hub/presentation/applet_category_widgets.dart';

void main() {
  testWidgets('category filters reflow and expose 48pt targets', (
    tester,
  ) async {
    AppletCategory selected = AppletCategory.all;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 280,
            child: StatefulBuilder(
              builder: (context, setState) => AppletCategoryFilterBar(
                selected: selected,
                onSelected: (next) => setState(() => selected = next),
              ),
            ),
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    final all = find.byKey(const ValueKey<String>('applet-filter-all'));
    final travel = find.byKey(const ValueKey<String>('applet-filter-travel'));
    expect(all, findsOneWidget);
    expect(travel, findsOneWidget);
    expect(tester.getSize(all).height, greaterThanOrEqualTo(48));

    await tester.tap(travel);
    await tester.pump();

    expect(selected, AppletCategory.travel);
    final semantics = tester.getSemantics(travel);
    expect(semantics.flagsCollection.isSelected, Tristate.isTrue);
  });

  testWidgets('category badge renders a stable localized facet', (
    tester,
  ) async {
    final previousLocale = AppLocalization.locale;
    AppLocalization.updateLocale(const Locale('zh'));
    addTearDown(() => AppLocalization.updateLocale(previousLocale));
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AppletCategoryBadge(category: AppletCategory.game),
        ),
      ),
    );

    expect(
      find.byKey(const ValueKey<String>('applet-category-game')),
      findsOneWidget,
    );
    expect(find.text('游戏'), findsOneWidget);
  });

  for (final brightness in Brightness.values) {
    testWidgets('category badges keep accessible $brightness contrast', (
      tester,
    ) async {
      final theme = ThemeData(brightness: brightness);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: AppletCategoryBadge(category: AppletCategory.travel),
          ),
        ),
      );

      final badge = tester.widget<DecoratedBox>(
        find.byKey(const ValueKey<String>('applet-category-travel')),
      );
      final decoration = badge.decoration as BoxDecoration;
      final background = Color.alphaBlend(
        decoration.color!,
        theme.scaffoldBackgroundColor,
      );
      final label = tester.widget<Text>(find.text('Travel'));

      expect(
        _contrastRatio(label.style!.color!, background),
        greaterThanOrEqualTo(4.5),
      );
    });
  }
}

double _contrastRatio(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  final lighter = foregroundLuminance > backgroundLuminance
      ? foregroundLuminance
      : backgroundLuminance;
  final darker = foregroundLuminance > backgroundLuminance
      ? backgroundLuminance
      : foregroundLuminance;
  return (lighter + 0.05) / (darker + 0.05);
}
