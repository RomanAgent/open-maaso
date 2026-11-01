import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/theme.dart';
import 'package:maaso/src/core/widgets/ui/app_palette.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/services/glass_ui_service.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  testWidgets(
    'composer moves one voice material while clipping its input group',
    (tester) async {
      await tester.pumpWidget(_motionHost(voiceMode: false));
      await tester.pump();

      final inputGroup = find.byKey(AppGlassComposerMorph.inputGroupKey);
      final toggle = find.byKey(AppGlassComposerMorph.voiceControlKey);
      final initialInputWidth = tester.getSize(inputGroup).width;
      final initialToggleX = tester.getTopLeft(toggle).dx;

      await tester.pumpWidget(_motionHost(voiceMode: true));
      await tester.pump(const Duration(milliseconds: 160));

      final midpointInputWidth = tester.getSize(inputGroup).width;
      final midpointToggleX = tester.getTopLeft(toggle).dx;
      final submitScale = tester
          .widget<Transform>(find.byKey(AppGlassComposerMorph.submitScaleKey))
          .transform
          .storage[0];

      expect(midpointInputWidth, greaterThan(0));
      expect(midpointInputWidth, lessThan(initialInputWidth));
      expect(midpointToggleX, lessThan(initialToggleX));
      expect(submitScale, greaterThan(0));
      expect(submitScale, lessThan(1));
      expect(find.byKey(AppGlassVoiceToggle.materialKey), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 240));
      expect(tester.getSize(inputGroup).width, 0);
      expect(
        tester
            .widget<Transform>(find.byKey(AppGlassComposerMorph.submitScaleKey))
            .transform
            .storage[0],
        0,
      );
      expect(find.byKey(AppGlassVoiceToggle.materialKey), findsOneWidget);
    },
  );

  testWidgets('composer stays valid under bottom-only positioning', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
        home: const Scaffold(
          body: Stack(
            children: <Widget>[
              Positioned(
                left: 16,
                right: 16,
                bottom: 16,
                child: _PositionedComposerHost(),
              ),
            ],
          ),
        ),
      ),
    );

    expect(
      tester.getSize(find.byKey(AppGlassComposerMorph.inputGroupKey)).height,
      48,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('composer snaps to the voice endpoint for reduced motion', (
    tester,
  ) async {
    await tester.pumpWidget(_motionHost(voiceMode: false, reducedMotion: true));
    await tester.pumpWidget(_motionHost(voiceMode: true, reducedMotion: true));
    await tester.pump();

    expect(
      tester.getSize(find.byKey(AppGlassComposerMorph.inputGroupKey)).width,
      0,
    );
    expect(find.byKey(AppGlassComposerMorph.voiceControlKey), findsOneWidget);
  });
}

class _PositionedComposerHost extends StatelessWidget {
  const _PositionedComposerHost();

  @override
  Widget build(BuildContext context) {
    return _composer(voiceMode: false);
  }
}

Widget _motionHost({required bool voiceMode, bool reducedMotion = false}) {
  appServices.put(
    GlassUiService(supportsShaderFilters: () => true, forceFrosted: true),
  );
  return MaterialApp(
    theme: AppTheme.build(AppPalette.of(Brightness.light, AppAccent.blue)),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Center(
        child: SizedBox(width: 320, child: _composer(voiceMode: voiceMode)),
      ),
    ),
  );
}

Widget _composer({required bool voiceMode}) {
  return AppGlassComposerMorph(
    voiceMode: voiceMode,
    textRadius: 23,
    voiceDiameter: 46,
    editorChild: const SizedBox(
      height: 46,
      child: Center(child: Text('Editor')),
    ),
    submitChild: const SizedBox.square(dimension: 46),
    voiceControlBuilder: (context, activation) => AppGlassVoiceToggle(
      activation: activation,
      phase: VoiceOrbPhase.listening,
      amplitude: 0.3,
      reducedMotion: MediaQuery.maybeOf(context)?.disableAnimations ?? false,
      size: 46,
    ),
  );
}
