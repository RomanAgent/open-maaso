import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_orb.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_toggle.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

void main() {
  testWidgets('voice toggle accepts taps on static glass', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        child: AppGlassVoiceToggle(
          activation: 0,
          phase: VoiceOrbPhase.listening,
          amplitude: 0,
          size: 46,
          onTap: () => taps += 1,
        ),
      ),
    );

    await tester.tap(find.bySemanticsLabel('Start voice input'));

    expect(taps, 1);
  });

  testWidgets(
    'voice toggle keeps the button glass static until the orb endpoint',
    (tester) async {
      await tester.pumpWidget(
        _host(
          child: const AppGlassVoiceToggle(
            activation: 0,
            phase: VoiceOrbPhase.listening,
            amplitude: 0,
            size: 46,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(AppGlassVoiceToggle.materialKey), findsOneWidget);
      expect(find.byKey(AppGlassVoiceToggle.microphoneKey), findsOneWidget);
      expect(find.byKey(AppGlassVoiceToggle.staticGlassKey), findsOneWidget);
      expect(find.byKey(AppGlassVoiceOrb.waveformKey), findsNothing);
      _expectBlackFrost(tester);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(AppGlassVoiceToggle.microphoneOpacityKey),
            )
            .opacity,
        1,
      );

      await tester.pumpWidget(
        _host(
          child: const AppGlassVoiceToggle(
            activation: 0.5,
            phase: VoiceOrbPhase.listening,
            amplitude: 0.5,
            size: 46,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(AppGlassVoiceToggle.staticGlassKey), findsOneWidget);
      expect(find.byKey(AppGlassVoiceOrb.waveformKey), findsNothing);
      _expectBlackFrost(tester);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(AppGlassVoiceToggle.microphoneOpacityKey),
            )
            .opacity,
        0.5,
      );

      await tester.pumpWidget(
        _host(
          child: const AppGlassVoiceToggle(
            activation: 1,
            phase: VoiceOrbPhase.listening,
            amplitude: 0.5,
            size: 46,
          ),
        ),
      );
      await tester.pump();

      expect(find.byKey(AppGlassVoiceToggle.materialKey), findsOneWidget);
      expect(find.byKey(AppGlassVoiceToggle.staticGlassKey), findsNothing);
      expect(find.byKey(AppGlassVoiceToggle.orbVisualKey), findsOneWidget);
      expect(find.byKey(AppGlassVoiceOrb.waveformKey), findsOneWidget);
      _expectBlackFrost(tester);
      expect(
        tester
            .widget<Opacity>(
              find.byKey(AppGlassVoiceToggle.microphoneOpacityKey),
            )
            .opacity,
        0,
      );
    },
  );
}

void _expectBlackFrost(WidgetTester tester) {
  final decoration =
      tester
              .widget<DecoratedBox>(
                find.descendant(
                  of: find.byType(AppGlassVoiceToggle),
                  matching: find.byKey(AppGlassSurface.frostedLayerKey),
                ),
              )
              .decoration
          as BoxDecoration;
  expect(
    decoration.color,
    MaasoFrostTokens.composerAction.withValues(
      alpha: MaasoFrostTokens.capsuleFillAlpha,
    ),
  );
  expect(decoration.border, isNull);
  expect(find.byType(BackdropFilter), findsNothing);
  expect(tester.getSize(find.byType(AppGlassVoiceToggle)), const Size(48, 48));
}

Widget _host({required Widget child}) {
  return MaterialApp(
    home: MediaQuery(
      data: const MediaQueryData(disableAnimations: true),
      child: Center(child: child),
    ),
  );
}
