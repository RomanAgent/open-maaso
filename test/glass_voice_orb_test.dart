import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/voice_orb/glass_voice_orb_state.dart'
    as voice_orb_state;
import 'package:maaso/src/core/services/glass_ui_service.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(() {
    appServices.reset();
  });

  test('voice phase priority is speaking then recognizing then thinking', () {
    expect(
      resolveVoiceOrbPhase(
        playbackActive: true,
        awaitingFinal: true,
        isThinking: true,
      ),
      VoiceOrbPhase.speaking,
    );
    expect(
      resolveVoiceOrbPhase(
        playbackActive: false,
        awaitingFinal: true,
        isThinking: true,
      ),
      VoiceOrbPhase.recognizing,
    );
    expect(
      resolveVoiceOrbPhase(
        playbackActive: false,
        awaitingFinal: false,
        isThinking: true,
      ),
      VoiceOrbPhase.thinking,
    );
    expect(
      resolveVoiceOrbPhase(
        playbackActive: false,
        awaitingFinal: false,
        isThinking: false,
      ),
      VoiceOrbPhase.listening,
    );
  });

  test('voice amplitude is clamped and perceptually normalized', () {
    expect(normalizeVoiceOrbAmplitude(-1), 0);
    expect(normalizeVoiceOrbAmplitude(0), 0);
    expect(normalizeVoiceOrbAmplitude(1), 1);
    expect(normalizeVoiceOrbAmplitude(4), 1);
    expect(normalizeVoiceOrbAmplitude(0.5), greaterThan(0.5));
  });

  test('voice amplitude smoothing interpolates rather than jumps', () {
    expect(smoothVoiceOrbAmplitude(from: 0, to: 1, t: 0), 0);
    expect(
      smoothVoiceOrbAmplitude(from: 0, to: 1, t: 0.5),
      closeTo(0.5, 0.001),
    );
    expect(smoothVoiceOrbAmplitude(from: 0, to: 1, t: 1), 1);
  });

  test('voice orb exports behavior from its focused state unit', () {
    final widgetSource = File(
      'lib/src/core/widgets/ui/glass/app_glass_voice_orb.dart',
    ).readAsStringSync();

    expect(
      voice_orb_state.resolveVoiceOrbPhase(
        playbackActive: false,
        awaitingFinal: true,
        isThinking: true,
      ),
      voice_orb_state.VoiceOrbPhase.recognizing,
    );
    expect(voice_orb_state.normalizeVoiceOrbAmplitude(1), 1);
    expect(
      voice_orb_state.smoothVoiceOrbAmplitude(from: 0, to: 1, t: 0.5),
      0.5,
    );
    expect(
      widgetSource,
      contains("export 'voice_orb/glass_voice_orb_state.dart';"),
    );
    expect(widgetSource, isNot(contains('enum VoiceOrbPhase')));
  });

  testWidgets(
    'voice visual settles without an idle ticker or backdrop filter',
    (tester) async {
      await _pumpOrb(
        tester,
        const AppGlassVoiceOrb(phase: VoiceOrbPhase.listening, amplitude: 0),
      );
      await tester.pumpAndSettle();
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byKey(AppGlassVoiceOrb.waveformKey), findsOneWidget);
      await tester.pump(const Duration(seconds: 8));
      expect(tester.binding.hasScheduledFrame, isFalse);
    },
  );

  testWidgets('each voice phase remains announced across visual changes', (
    tester,
  ) async {
    for (final phase in VoiceOrbPhase.values) {
      await _pumpOrb(
        tester,
        AppGlassVoiceOrb(phase: phase, amplitude: .5, reducedMotion: true),
      );
      final semantics = tester.getSemantics(
        find.byKey(AppGlassVoiceOrb.semanticsKey),
      );
      expect(semantics.hint, isNotEmpty);
      expect(find.byKey(AppGlassVoiceOrb.waveformKey), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'every voice phase uses black frost and white marks in both themes',
    (tester) async {
      for (final brightness in Brightness.values) {
        for (final phase in VoiceOrbPhase.values) {
          await _pumpOrb(
            tester,
            AppGlassVoiceOrb(phase: phase, amplitude: .5, reducedMotion: true),
            brightness: brightness,
            forceFrosted: false,
          );
          final surface = tester.widget<AppGlassSurface>(
            find.descendant(
              of: find.byType(AppGlassVoiceOrb),
              matching: find.byType(AppGlassSurface),
            ),
          );
          expect(surface.role, AppGlassSurfaceRole.orb);
          expect(
            _orbDecoration(tester).color,
            MaasoFrostTokens.composerAction.withValues(
              alpha: MaasoFrostTokens.capsuleFillAlpha,
            ),
          );
          expect(_orbDecoration(tester).border, isNull);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(find.byType(UiKitView), findsNothing);
          final waveform = tester.renderObject(
            find.byKey(AppGlassVoiceOrb.waveformKey),
          );
          expect(
            waveform,
            phase == VoiceOrbPhase.thinking ||
                    phase == VoiceOrbPhase.recognizing
                ? (paints..circle(color: Colors.white))
                : (paints..rrect(color: Colors.white)),
          );
        }
      }
    },
  );

  testWidgets('voice frost keeps native and accessibility fallback coverage', (
    tester,
  ) async {
    final baseFill = MaasoFrostTokens.composerAction.withValues(
      alpha: MaasoFrostTokens.capsuleFillAlpha,
    );
    for (final brightness in Brightness.values) {
      for (final scenario in [
        (highContrast: true, accessibleNavigation: false, forceFrosted: false),
        (highContrast: false, accessibleNavigation: true, forceFrosted: false),
        (highContrast: false, accessibleNavigation: false, forceFrosted: true),
      ]) {
        await _pumpOrb(
          tester,
          const AppGlassVoiceOrb(phase: VoiceOrbPhase.listening, amplitude: .5),
          brightness: brightness,
          highContrast: scenario.highContrast,
          accessibleNavigation: scenario.accessibleNavigation,
          forceFrosted: scenario.forceFrosted,
        );
        expect(
          _orbDecoration(tester).color,
          Color.alphaBlend(
            baseFill,
            brightness == Brightness.light
                ? MaasoFrostTokens.lightSurface
                : MaasoFrostTokens.darkSurface,
          ).withValues(alpha: 1),
        );
        expect(_orbDecoration(tester).border, isNull);
        expect(find.byType(BackdropFilter), findsNothing);
      }
      await _pumpOrb(
        tester,
        const AppGlassVoiceOrb(phase: VoiceOrbPhase.speaking, amplitude: .5),
        brightness: brightness,
        forceFrosted: false,
        backdrop: GlassBackdropKind.unityUnderlay,
      );
      expect(
        _orbDecoration(tester).color,
        MaasoFrostTokens.composerAction.withValues(
          alpha: MaasoFrostTokens.overlayFillAlpha,
        ),
      );
      expect(find.byType(BackdropFilter), findsNothing);
      expect(find.byType(UiKitView), findsNothing);
    }
  });

  testWidgets(
    'amplitude transitions finish and stream replacement retires old input',
    (tester) async {
      final first = StreamController<double>();
      final second = StreamController<double>();
      addTearDown(first.close);
      addTearDown(second.close);
      await _pumpOrb(
        tester,
        AppGlassVoiceOrb(
          phase: VoiceOrbPhase.speaking,
          amplitude: 0,
          amplitudeStream: first.stream,
        ),
      );
      first.add(1);
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        tester.getSemantics(find.byKey(AppGlassVoiceOrb.semanticsKey)).value,
        '100%',
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      await _pumpOrb(
        tester,
        AppGlassVoiceOrb(
          phase: VoiceOrbPhase.speaking,
          amplitude: 0,
          amplitudeStream: second.stream,
          reducedMotion: true,
        ),
      );
      expect(first.hasListener, isFalse);
      second.add(.0);
      await tester.pump();
      await tester.pump();
      expect(
        tester.getSemantics(find.byKey(AppGlassVoiceOrb.semanticsKey)).value,
        '0%',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      expect(second.hasListener, isFalse);
    },
  );

  testWidgets('orb exposes semantics, minimum target, phase layers and tap', (
    tester,
  ) async {
    var taps = 0;
    await _pumpOrb(
      tester,
      AppGlassVoiceOrb(
        phase: VoiceOrbPhase.listening,
        amplitude: 0.4,
        semanticLabel: 'Voice assistant',
        onTap: () => taps += 1,
      ),
    );

    final size = tester.getSize(find.byType(AppGlassVoiceOrb));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
    expect(find.bySemanticsLabel('Voice assistant'), findsOneWidget);
    expect(find.byKey(AppGlassVoiceOrb.glassShellKey), findsOneWidget);
    expect(find.byKey(AppGlassVoiceOrb.waveformKey), findsOneWidget);

    await tester.tap(find.byType(AppGlassVoiceOrb));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('orb can render within a shared composer shell', (tester) async {
    await _pumpOrb(
      tester,
      const AppGlassVoiceOrb(
        phase: VoiceOrbPhase.listening,
        amplitude: 0,
        useGlassShell: false,
      ),
    );

    expect(find.byKey(AppGlassVoiceOrb.glassShellKey), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AppGlassVoiceOrb),
        matching: find.byType(AppGlassSurface),
      ),
      findsNothing,
    );
  });

  testWidgets('reduced motion uses a stable frame and disposes stream input', (
    tester,
  ) async {
    final amplitudes = StreamController<double>();
    addTearDown(amplitudes.close);
    await _pumpOrb(
      tester,
      AppGlassVoiceOrb(
        phase: VoiceOrbPhase.speaking,
        amplitude: 0,
        amplitudeStream: amplitudes.stream,
        reducedMotion: true,
      ),
    );

    expect(find.byKey(AppGlassVoiceOrb.reducedMotionKey), findsOneWidget);
    amplitudes.add(1);
    await tester.pump();
    await tester.pump();
    final semantics = tester.getSemantics(
      find.byKey(AppGlassVoiceOrb.semanticsKey),
    );
    expect(semantics.value, '100%');

    await tester.pumpWidget(const SizedBox.shrink());
    amplitudes.add(0.5);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}

BoxDecoration _orbDecoration(WidgetTester tester) =>
    tester
            .widget<DecoratedBox>(
              find.descendant(
                of: find.byType(AppGlassVoiceOrb),
                matching: find.byKey(AppGlassSurface.frostedLayerKey),
              ),
            )
            .decoration
        as BoxDecoration;

Future<void> _pumpOrb(
  WidgetTester tester,
  Widget orb, {
  Brightness brightness = Brightness.light,
  bool forceFrosted = true,
  bool highContrast = false,
  bool accessibleNavigation = false,
  GlassBackdropKind backdrop = GlassBackdropKind.flutter,
}) async {
  appServices.put(
    GlassUiService(
      supportsShaderFilters: () => true,
      forceFrosted: forceFrosted,
    ),
  );
  appServices.find<GlassUiService>().forceFrosted.value = forceFrosted;
  await tester.pumpWidget(
    MaterialApp(
      themeAnimationDuration: Duration.zero,
      theme: AppTheme.build(AppPalette.of(brightness, AppAccent.blue)),
      home: MediaQuery(
        data: MediaQueryData(
          highContrast: highContrast,
          accessibleNavigation: accessibleNavigation,
        ),
        child: MaasoGlassBackdropScope(
          backdropKind: backdrop,
          renderMode: GlassRenderMode.frosted,
          child: Center(child: orb),
        ),
      ),
    ),
  );
  await tester.pump();
}
