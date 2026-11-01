import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_voice_orb.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

class AppGlassVoiceToggle extends StatelessWidget {
  const AppGlassVoiceToggle({
    required this.activation,
    required this.phase,
    required this.amplitude,
    this.amplitudeStream,
    this.onTap,
    this.reducedMotion = false,
    this.size = 48,
    super.key,
  });

  static const materialKey = ValueKey<String>(
    'app-glass-voice-toggle-material',
  );
  static const microphoneKey = ValueKey<String>(
    'app-glass-voice-toggle-microphone',
  );
  static const microphoneOpacityKey = ValueKey<String>(
    'app-glass-voice-toggle-microphone-opacity',
  );
  static const staticGlassKey = ValueKey<String>(
    'app-glass-voice-toggle-static-glass',
  );
  static const orbVisualKey = ValueKey<String>(
    'app-glass-voice-toggle-orb-visual',
  );

  final double activation;
  final VoiceOrbPhase phase;
  final double amplitude;
  final Stream<double>? amplitudeStream;
  final VoidCallback? onTap;
  final bool reducedMotion;
  final double size;

  @override
  Widget build(BuildContext context) {
    final progress = activation.clamp(0.0, 1.0).toDouble();
    final showOrb = progress >= 0.999;
    final diameter = size.clamp(48.0, 180.0).toDouble();
    final orbDiameter = diameter;
    final glass = MaasoGlassTheme.of(context);
    return RepaintBoundary(
      child: SizedBox.square(
        dimension: diameter,
        child: Stack(
          clipBehavior: Clip.none,
          fit: StackFit.expand,
          children: <Widget>[
            KeyedSubtree(
              key: materialKey,
              child: showOrb
                  ? Center(
                      child: SizedBox.square(
                        dimension: orbDiameter,
                        child: KeyedSubtree(
                          key: orbVisualKey,
                          child: AppGlassVoiceOrb(
                            phase: phase,
                            amplitude: amplitude,
                            amplitudeStream: amplitudeStream,
                            reducedMotion: reducedMotion,
                            size: orbDiameter,
                            showProjectedHalo: false,
                            semanticLabel: 'chat.voice_assistant',
                            onTap: onTap,
                          ),
                        ),
                      ),
                    )
                  : Semantics(
                      button: onTap != null,
                      label: 'chat.start_voice_input'.tr,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: onTap,
                        child: AppGlassSurface(
                          key: staticGlassKey,
                          role: AppGlassSurfaceRole.orb,
                          tintColor: MaasoFrostTokens.composerAction.withValues(
                            alpha: MaasoFrostTokens.capsuleFillAlpha,
                          ),
                          behavior: AppGlassSurfaceBehavior.staticSurface,
                          cornerRadius: diameter / 2,
                          padding: EdgeInsets.zero,
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
            ),
            IgnorePointer(
              child: Center(
                child: Opacity(
                  key: microphoneOpacityKey,
                  opacity: 1 - progress,
                  child: Icon(
                    Icons.mic_none_rounded,
                    key: microphoneKey,
                    color: glass.onAction,
                    size: 22,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
