import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

void main() {
  test('secondary palette keeps every page and card surface opaque', () {
    for (final brightness in Brightness.values) {
      final palette = AppSecondaryPalette.resolve(brightness);
      for (final color in <Color>[
        palette.backgroundStart,
        palette.backgroundEnd,
        palette.surface,
        palette.surfaceMuted,
        palette.selectedSurface,
        palette.dangerSurface,
      ]) {
        expect(color.alpha, 255, reason: '$brightness $color');
      }
    }
  });

  for (final brightness in Brightness.values) {
    testWidgets('secondary scaffold paints an opaque $brightness background', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: const AppSecondaryScaffold(
            header: SizedBox(height: 44),
            body: SizedBox.expand(),
          ),
        ),
      );

      final background = tester.widget<DecoratedBox>(
        find.byKey(AppSecondaryScaffold.backgroundKey),
      );
      final decoration = background.decoration as BoxDecoration;
      expect(decoration.gradient, isNull);
      expect(decoration.color?.a, 1);
      expect(
        decoration.color,
        AppSecondaryPalette.resolve(brightness).backgroundStart,
      );
      if (brightness == Brightness.light)
        expect(decoration.color, Colors.white);
    });
  }

  testWidgets('secondary header keeps actions accessible and interactive', (
    tester,
  ) async {
    var backs = 0;
    var actions = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AppSecondaryHeader(
            title: 'Skill Store',
            subtitle: 'Browse public skills',
            onBack: () => backs += 1,
            trailing: AppGlassIconButton(
              icon: Icons.refresh_rounded,
              tooltip: 'Refresh',
              onPressed: () => actions += 1,
            ),
          ),
        ),
      ),
    );

    final back = find.byTooltip('Back');
    expect(tester.getSize(back).width, greaterThanOrEqualTo(48));
    expect(tester.getSize(back).height, greaterThanOrEqualTo(48));

    await tester.tap(back);
    await tester.tap(find.byTooltip('Refresh'));
    expect(backs, 1);
    expect(actions, 1);
  });

  testWidgets('secondary cards render opaque interaction states', (
    tester,
  ) async {
    var disabledTaps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              const AppSecondaryCard(
                key: ValueKey<String>('normal-card'),
                child: Text('normal'),
              ),
              const AppSecondaryCard(
                key: ValueKey<String>('selected-card'),
                tone: AppSecondaryCardTone.selected,
                child: Text('selected'),
              ),
              AppSecondaryCard(
                key: const ValueKey<String>('disabled-card'),
                tone: AppSecondaryCardTone.disabled,
                onTap: () => disabledTaps += 1,
                child: const Text('disabled'),
              ),
              const AppSecondaryCard(
                key: ValueKey<String>('danger-card'),
                tone: AppSecondaryCardTone.danger,
                semanticLabel: 'Danger card',
                child: Text('danger'),
              ),
            ],
          ),
        ),
      ),
    );

    Material cardMaterial(String key) => tester.widget<Material>(
      find
          .descendant(
            of: find.byKey(ValueKey<String>(key)),
            matching: find.byType(Material),
          )
          .first,
    );

    final normal = cardMaterial('normal-card');
    final selected = cardMaterial('selected-card');
    final disabled = cardMaterial('disabled-card');
    final danger = cardMaterial('danger-card');

    for (final material in <Material>[normal, selected, disabled, danger]) {
      expect(material.color?.alpha, 255);
      expect((material.shape as RoundedRectangleBorder).side, BorderSide.none);
    }
    expect(selected.color, isNot(normal.color));
    expect(danger.color, isNot(normal.color));

    await tester.tap(find.text('disabled'));
    expect(disabledTaps, 0);
    expect(find.bySemanticsLabel('Danger card'), findsOneWidget);
  });

  testWidgets('secondary state views cover loading empty and retry states', (
    tester,
  ) async {
    var retries = 0;

    Future<void> pumpState(AppSecondaryStateView state) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: state)),
        ),
      );
    }

    await pumpState(
      const AppSecondaryStateView(
        kind: AppSecondaryStateKind.loading,
        title: 'Loading',
      ),
    );
    expect(find.byType(AppSecondarySkeletonList), findsOneWidget);
    expect(find.byKey(AppSecondarySkeletonList.itemKey), findsNWidgets(3));

    await pumpState(
      const AppSecondaryStateView(
        kind: AppSecondaryStateKind.empty,
        title: 'Nothing here',
      ),
    );
    expect(find.text('Nothing here'), findsOneWidget);

    await pumpState(
      AppSecondaryStateView(
        kind: AppSecondaryStateKind.error,
        title: 'Could not load',
        actionLabel: 'Retry',
        onAction: () => retries += 1,
      ),
    );
    expect(find.text('Could not load'), findsOneWidget);
    await tester.tap(find.text('Retry'));

    await pumpState(
      AppSecondaryStateView(
        kind: AppSecondaryStateKind.offline,
        title: 'Offline',
        actionLabel: 'Try again',
        onAction: () => retries += 1,
      ),
    );
    expect(find.text('Offline'), findsOneWidget);
    await tester.tap(find.text('Try again'));

    expect(retries, 2);
  });
}
