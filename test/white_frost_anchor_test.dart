import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/widgets_hub/presentation/game_frost_chrome.dart';

const _preview = bool.fromEnvironment('MAASO_SAVE_FROST_PREVIEW');
const _boundary = Key('white-frost-preview');

void main() {
  test('runtime color and material values match the durable design anchor', () {
    final anchor =
        jsonDecode(
              File(
                'design-system/maaso-soft-frost/tokens.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(MaasoFrostTokens.themeId, anchor['id']);
    final colors = anchor['color'] as Map<String, dynamic>;
    final expected = <String, Color>{
      'light.canvas': MaasoFrostTokens.lightCanvas,
      'light.surface': MaasoFrostTokens.lightSurface,
      'light.muted': MaasoFrostTokens.lightMuted,
      'light.textPrimary': MaasoFrostTokens.lightTextPrimary,
      'light.textSecondary': MaasoFrostTokens.lightTextSecondary,
      'light.action': MaasoFrostTokens.action,
      'light.composerAction': MaasoFrostTokens.composerAction,
      'light.onAction': MaasoFrostTokens.onAction,
      'light.userMessage': MaasoFrostTokens.lightUserMessage,
      'light.onUserMessage': MaasoFrostTokens.lightOnUserMessage,
      'light.accent': MaasoFrostTokens.lightAccent,
      'light.accentSoft': MaasoFrostTokens.lightAccentSoft,
      'dark.canvas': MaasoFrostTokens.darkCanvas,
      'dark.surface': MaasoFrostTokens.darkSurface,
      'dark.muted': MaasoFrostTokens.darkMuted,
      'dark.textPrimary': MaasoFrostTokens.darkTextPrimary,
      'dark.textSecondary': MaasoFrostTokens.darkTextSecondary,
      'dark.composerAction': MaasoFrostTokens.composerAction,
      'dark.userMessage': MaasoFrostTokens.darkUserMessage,
      'dark.onUserMessage': MaasoFrostTokens.darkOnUserMessage,
      'dark.accent': MaasoFrostTokens.darkAccent,
      'dark.accentSoft': MaasoFrostTokens.darkAccentSoft,
    };
    for (final entry in expected.entries) {
      final path = entry.key.split('.');
      final value =
          (colors[path[0]] as Map<String, dynamic>)[path[1]] as String;
      expect(
        entry.value.toARGB32(),
        int.parse('ff${value.substring(1)}', radix: 16),
        reason: entry.key,
      );
    }
    final material = anchor['material'] as Map<String, dynamic>;
    expect(material['borderWidth'], 0);
    expect(material['frostedChromeBlurSigma'], MaasoFrostTokens.blurSigma);
    expect(material['capsuleFillAlpha'], MaasoFrostTokens.capsuleFillAlpha);
    expect(material['inputFillAlpha'], MaasoFrostTokens.inputFillAlpha);
    final webManifest =
        jsonDecode(File('web/manifest.json').readAsStringSync())
            as Map<String, dynamic>;
    expect(webManifest['background_color'], '#FFFFFF');
    expect(webManifest['theme_color'], '#3B6DE4');
  });

  test(
    'Material fallbacks remain borderless across field and selection states',
    () {
      for (final brightness in Brightness.values) {
        final theme = AppTheme.build(AppPalette.of(brightness, AppAccent.blue));
        expect(
          theme.inputDecorationTheme.enabledBorder!.borderSide,
          BorderSide.none,
        );
        expect(
          theme.inputDecorationTheme.disabledBorder!.borderSide,
          BorderSide.none,
        );
        expect(
          theme.inputDecorationTheme.errorBorder!.borderSide,
          BorderSide.none,
        );
        expect(theme.inputDecorationTheme.focusedBorder!.borderSide.width, 2);
        expect(theme.chipTheme.side, BorderSide.none);
        for (final state in [
          {WidgetState.selected},
          <WidgetState>{},
        ]) {
          expect(
            theme.segmentedButtonTheme.style!.side!.resolve(state),
            BorderSide.none,
          );
          expect(
            theme.outlinedButtonTheme.style!.side!.resolve(state),
            BorderSide.none,
          );
        }
        expect(
          theme.filledButtonTheme.style!.backgroundColor!.resolve({}),
          MaasoFrostTokens.action,
        );
        expect(
          theme.colorScheme.onSurface,
          AppPalette.of(brightness, AppAccent.blue).textPrimary,
        );
        final inverse = theme.colorScheme.inverseSurface.computeLuminance();
        final onInverse = theme.colorScheme.onInverseSurface.computeLuminance();
        expect(
          ((inverse > onInverse ? inverse : onInverse) + .05) /
              ((inverse < onInverse ? inverse : onInverse) + .05),
          greaterThanOrEqualTo(4.5),
        );
      }
    },
  );

  test(
    'production confines frost sampling to approved renderers without retired optics',
    () {
      // The immersive game's fixed action rail shares one bounded sampler;
      // individual controls still use the common surface renderer.
      const approvedSamplers = {
        'lib/src/core/widgets/ui/glass/app_glass_surface.dart': 1,
        'lib/src/features/widgets_hub/presentation/game_frost_chrome.dart': 1,
      };
      final actualSamplers = <String, int>{};
      for (final file
          in Directory('lib')
              .listSync(recursive: true)
              .whereType<File>()
              .where((f) => f.path.endsWith('.dart'))) {
        final source = file.readAsStringSync();
        expect(
          source,
          isNot(contains('package:liquid_glass')),
          reason: file.path,
        );
        expect(
          source,
          isNot(contains('glass_voice_orb.frag')),
          reason: file.path,
        );
        final count = RegExp(
          r'\bBackdropFilter(?:\.grouped)?\s*\(',
        ).allMatches(source).length;
        if (count > 0) actualSamplers[file.path] = count;
      }
      expect(actualSamplers, approvedSamplers);
      expect(
        File('pubspec.yaml').readAsStringSync(),
        isNot(contains('liquid_glass')),
      );
      expect(File('shaders/glass_voice_orb.frag').existsSync(), isFalse);
    },
  );

  testWidgets('game action rail shares frost and respects non-sampling hosts', (
    tester,
  ) async {
    for (final scenario in [
      (
        kind: GlassBackdropKind.flutter,
        allow: true,
        contrast: false,
        access: false,
        filters: 6,
      ),
      (
        kind: GlassBackdropKind.flutter,
        allow: false,
        contrast: false,
        access: false,
        filters: 0,
      ),
      (
        kind: GlassBackdropKind.flutter,
        allow: true,
        contrast: true,
        access: false,
        filters: 0,
      ),
      (
        kind: GlassBackdropKind.flutter,
        allow: true,
        contrast: false,
        access: true,
        filters: 0,
      ),
      (
        kind: GlassBackdropKind.platformView,
        allow: true,
        contrast: false,
        access: false,
        filters: 0,
      ),
      (
        kind: GlassBackdropKind.unityUnderlay,
        allow: true,
        contrast: false,
        access: false,
        filters: 0,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              highContrast: scenario.contrast,
              accessibleNavigation: scenario.access,
            ),
            child: BackdropGroup(
              // An unrelated ancestor must not override a disabled local host.
              child: Center(
                child: MaasoGlassBackdropScope(
                  backdropKind: scenario.kind,
                  renderMode: GlassRenderMode.frosted,
                  allowBlur: scenario.allow,
                  child: GameFrostGroup(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: List.generate(
                        6,
                        (_) => GameFrostIconButton(
                          icon: Icons.favorite_border,
                          tooltip: 'Like',
                          onPressed: () {},
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(BackdropFilter), findsNWidgets(scenario.filters));
      final samplers = tester.renderObjectList<RenderBackdropFilter>(
        find.byType(BackdropFilter),
      );
      if (scenario.filters > 0) {
        expect(
          samplers.map((sampler) => sampler.backdropKey).toSet(),
          hasLength(1),
        );
        expect(samplers.first.backdropKey, isNotNull);
        for (final sampler in samplers) {
          expect(sampler.size, const Size.square(48));
          expect(sampler.parent, isA<RenderClipRRect>());
        }
      }
      expect(find.byType(IconButton), findsNWidgets(6));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('real themed controls share a readable phone layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final search = TextEditingController();
    addTearDown(search.dispose);
    if (_preview) {
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      await tester.runAsync(() async {
        final bytes = ByteData.sublistView(
          await File(
            '/System/Library/Fonts/Supplemental/Arial Unicode.ttf',
          ).readAsBytes(),
        );
        for (final family in ['FrostPreview', 'Ahem', 'Roboto']) {
          await (FontLoader(family)..addFont(Future.value(bytes))).load();
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
    }
    for (final brightness in Brightness.values) {
      final theme = AppTheme.build(AppPalette.of(brightness, AppAccent.blue));
      await tester.pumpWidget(
        MaterialApp(
          theme: _preview
              ? theme.copyWith(
                  textTheme: theme.textTheme.apply(fontFamily: 'FrostPreview'),
                )
              : theme,
          home: RepaintBoundary(
            key: _boundary,
            child: AppSecondaryScaffold(
              header: AppSecondaryHeader(
                title: 'Maaso',
                subtitle: '与你一起，记录每一天',
                onBack: () {},
              ),
              body: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppFrostSegmentedControl<int>(
                      segments: const [
                        AppFrostSegment(value: 0, label: '档案'),
                        AppFrostSegment(value: 1, label: '动态'),
                        AppFrostSegment(value: 2, label: '记忆'),
                      ],
                      selected: 2,
                      onSelected: (_) {},
                    ),
                    const SizedBox(height: 24),
                    Text('值得记住的小事', style: theme.textTheme.titleLarge),
                    const SizedBox(height: 8),
                    Text(
                      '每一次交流，都是我们共同故事的一部分。',
                      style: theme.textTheme.bodySmall,
                    ),
                    const SizedBox(height: 20),
                    AppGlassField(
                      controller: search,
                      hintText: '搜索我们的回忆',
                      prefixIcon: Icons.search_rounded,
                    ),
                    const SizedBox(height: 20),
                    const AppSecondaryCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('第一次一起散步'),
                          SizedBox(height: 8),
                          Text('我们聊起了喜欢的音乐，也计划了下一次出发。'),
                          SizedBox(height: 12),
                          Text('9月14日 · 共同的记忆'),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    AppGlassButton(
                      label: '开始聊天',
                      icon: Icons.chat_bubble_outline_rounded,
                      onPressed: () {},
                    ),
                    const Spacer(),
                    ChatInputBar(controller: controller, onSend: () {}),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byType(BackdropFilter).evaluate().length,
        lessThanOrEqualTo(2),
      );
      if (_preview) {
        await tester.runAsync(() async {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(_boundary),
          );
          final image = await boundary.toImage(pixelRatio: 2);
          final png = (await image.toByteData(format: ui.ImageByteFormat.png))!;
          final file = File(
            'design-system/maaso-soft-frost/runtime-${brightness.name}.png',
          );
          await file.writeAsBytes(png.buffer.asUint8List());
          image.dispose();
        });
      }
    }
    if (_preview) debugDisableShadows = true;
  });
}
