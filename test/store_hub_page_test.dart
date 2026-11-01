import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/store/presentation/store_hub_page.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';

import 'helpers/opaque_hub_navigation_probe.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final reduceMotion in <bool>[false, true]) {
      for (final size in <Size>[const Size(375, 667), const Size(667, 375)]) {
        testWidgets(
          'store tabs stay opaque: $brightness reduced=$reduceMotion $size',
          (tester) => verifyOpaqueHubNavigation(
            tester,
            brightness: brightness,
            reduceMotion: reduceMotion,
            size: size,
            paneNames: const ['models', 'marketplace'],
            destinationKeys: const <String>[
              'store-hub-models',
              'store-hub-marketplace',
            ],
            buildHub: (pane) => StoreHubPage(
              sectionBuilders: {
                for (final section in StoreHubSection.values)
                  section: (_) => pane(section.name),
              },
            ),
          ),
        );
      }
    }
  }

  testWidgets(
    'public store defaults to Models, has two visible sections and a separate workshop',
    (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final builds = <StoreHubSection, int>{};

      Widget section(StoreHubSection value) {
        builds[value] = (builds[value] ?? 0) + 1;
        return Center(child: Text('${value.name}-pane'));
      }

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: StoreHubPage(
              sectionBuilders: {
                for (final value in StoreHubSection.values)
                  value: (_) => section(value),
              },
            ),
          ),
        ),
      );

      expect(StoreHubSection.values, <StoreHubSection>[
        StoreHubSection.marketplace,
        StoreHubSection.skills,
        StoreHubSection.models,
      ]);
      expect(find.text('models-pane'), findsOneWidget);
      expect(find.byKey(const ValueKey('store-hub-skills')), findsNothing);
      expect(find.byKey(const ValueKey('store-hub-actions')), findsNothing);
      expect(find.byKey(const ValueKey('store-open-workshop')), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('store-hub-applets')),
        findsNothing,
      );
      expect(builds[StoreHubSection.models], 1);
      expect(builds[StoreHubSection.marketplace], isNull);
      expect(builds[StoreHubSection.skills], isNull);

      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('store-hub-marketplace')),
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('store-hub-marketplace')),
      );
      await tester.pumpAndSettle();

      expect(find.text('marketplace-pane'), findsOneWidget);
      expect(find.text('models-pane'), findsNothing);
      expect(builds[StoreHubSection.marketplace], 1);
      expect(builds[StoreHubSection.skills], isNull);
      expect(builds[StoreHubSection.models], 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('workshop only mounts the selected Models or Skills pane', (
    tester,
  ) async {
    final builds = <StoreHubSection, int>{};
    Widget section(StoreHubSection value) {
      builds[value] = (builds[value] ?? 0) + 1;
      return Text('${value.name}-pane');
    }

    await tester.pumpWidget(
      MaterialApp(
        home: StoreHubPage(
          initialSection: StoreHubSection.skills,
          sectionBuilders: {
            for (final value in StoreHubSection.values)
              value: (_) => section(value),
          },
        ),
      ),
    );
    expect(find.text('skills-pane'), findsOneWidget);
    expect(builds[StoreHubSection.skills], 1);
    expect(builds[StoreHubSection.models], isNull);
    expect(builds[StoreHubSection.marketplace], isNull);
    expect(find.byKey(const ValueKey('store-open-workshop')), findsNothing);
    expect(find.byKey(const ValueKey('store-hub-marketplace')), findsNothing);
    expect(find.byKey(const ValueKey('store-hub-actions')), findsNothing);
    expect(
      tester.getCenter(find.byKey(const ValueKey('store-hub-models'))).dx,
      lessThan(
        tester.getCenter(find.byKey(const ValueKey('store-hub-skills'))).dx,
      ),
    );
    await tester.tap(find.byKey(const ValueKey('store-hub-models')));
    await tester.pumpAndSettle();
    expect(find.text('models-pane'), findsOneWidget);
    expect(find.text('skills-pane'), findsNothing);
    expect(builds[StoreHubSection.models], 1);
    expect(builds[StoreHubSection.skills], 1);
    expect(builds[StoreHubSection.marketplace], isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('model-first navigation has one tab level and fits large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 568),
            textScaler: TextScaler.linear(2),
          ),
          child: StoreHubPage(
            sectionBuilders: {
              StoreHubSection.models: (_) => const Text('models-pane'),
              StoreHubSection.marketplace: (_) => const Text('skills-pane'),
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('models-pane'), findsOneWidget);
    expect(find.byType(TabBarView), findsNothing);
    final segmented = tester.widget<AppFrostSegmentedControl<StoreHubSection>>(
      find.byType(AppFrostSegmentedControl<StoreHubSection>),
    );
    expect(segmented.segments.map((segment) => segment.value), [
      StoreHubSection.models,
      StoreHubSection.marketplace,
    ]);
    expect(find.byKey(const ValueKey('store-hub-actions')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
