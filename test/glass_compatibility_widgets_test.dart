import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/adventure_chrome.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/app_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/world_composer.dart';
import 'package:maaso/src/core/widgets/ui/world_panel.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(() {
    appServices.reset();
  });

  test('production widgets cannot import the retired liquid glass package', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));
    for (final file in files) {
      final source = file.readAsStringSync();
      expect(
        source,
        isNot(contains('package:liquid_glass_widgets')),
        reason: file.path,
      );
      expect(
        source,
        isNot(contains('package:liquid_glass_easy')),
        reason: file.path,
      );
    }
  });

  test('legacy shared widgets delegate to the Maaso glass boundary', () {
    final expectations = <String, List<String>>{
      'lib/src/core/widgets/ui/adventure_chrome.dart': <String>[
        'app_glass.dart',
        'AppGlassSurface(',
        'AppGlassIconButton(',
        'AppGlassButton(',
      ],
      'lib/src/core/widgets/ui/app_surface.dart': <String>[
        'app_glass.dart',
        'AppGlassSurface(',
      ],
      'lib/src/core/widgets/ui/app_app_bar.dart': <String>[
        'app_glass.dart',
        'AppGlassAppBar(',
      ],
      'lib/src/core/widgets/ui/app_button.dart': <String>[
        'app_glass.dart',
        'AppGlassButton(',
      ],
      'lib/src/core/widgets/ui/app_text_field.dart': <String>[
        'app_glass.dart',
        'AppGlassField(',
      ],
      'lib/src/core/widgets/ui/app_card.dart': <String>[
        'app_glass.dart',
        'AppGlassSurface(',
      ],
      'lib/src/core/widgets/ui/app_chip.dart': <String>[
        'app_glass.dart',
        'AppGlassChip(',
      ],
      'lib/src/core/widgets/ui/playful_backdrop.dart': <String>['ColoredBox('],
      'lib/src/core/widgets/ui/world_chat.dart': <String>[
        'app_glass.dart',
        'AppGlassAppBar(',
        'AppGlassSurface(',
      ],
      'lib/src/core/widgets/ui/world_panel.dart': <String>[
        'app_glass.dart',
        'AppGlassSurface(',
      ],
      'lib/src/core/widgets/ui/world_composer.dart': <String>[
        'app_glass.dart',
        'AppGlassSurface(',
        'AppGlassIconButton(',
      ],
      'lib/src/core/widgets/ui/world_stage.dart': <String>[
        'app_glass.dart',
        'AppGlassIconButton(',
      ],
      'lib/src/core/widgets/ui/world_portal.dart': <String>[
        'app_glass.dart',
        'AppGlassIconButton(',
      ],
    };

    for (final entry in expectations.entries) {
      final source = File(entry.key).readAsStringSync();
      for (final marker in entry.value) {
        expect(source, contains(marker), reason: '${entry.key}: $marker');
      }
    }
    for (final path in [
      'lib/src/core/widgets/ui/playful_backdrop.dart',
      'lib/src/core/widgets/ui/world_portal.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(source, isNot(contains('LinearGradient(')), reason: path);
      expect(source, isNot(contains('RadialGradient(')), reason: path);
    }
  });

  testWidgets('legacy actions retain opaque readable labels in both themes', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
          home: Scaffold(
            body: AdventureTextButton(label: 'Continue', onTap: () {}),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final fill =
          tester
                  .widget<DecoratedBox>(
                    find.byKey(AppGlassSurface.frostedLayerKey),
                  )
                  .decoration
              as BoxDecoration;
      expect(fill.color!.a, 1);
      expect(fill.border, isNull);
      expect(
        1.05 / (fill.color!.computeLuminance() + .05),
        greaterThanOrEqualTo(4.5),
      );
      expect(AdventureChrome.border(), const Border());
      expect(find.byType(BackdropFilter), findsNothing);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('panel compatibility types render standard glass surfaces', (
    tester,
  ) async {
    appServices.put(
      GlassUiService(supportsShaderFilters: () => true, forceFrosted: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
        home: const Scaffold(
          body: Column(
            children: <Widget>[
              AdventurePanel(child: Text('adventure')),
              AppSurface(child: Text('surface')),
              WorldPanel(child: Text('world')),
              WorldComposerPanel(child: Text('composer')),
            ],
          ),
        ),
      ),
    );

    expect(find.byType(AppGlassSurface), findsNWidgets(4));
    expect(find.byKey(AppGlassSurface.frostedLayerKey), findsNWidgets(4));
  });

  testWidgets('composer keeps standard glass over a PlatformView', (
    tester,
  ) async {
    appServices.put(
      GlassUiService(supportsShaderFilters: () => true, forceFrosted: true),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
        home: const AppGlassScaffold(
          backdropKind: GlassBackdropKind.platformView,
          body: Center(child: WorldComposerPanel(child: Text('composer'))),
        ),
      ),
    );

    expect(find.byKey(AppGlassSurface.frostedLayerKey), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
