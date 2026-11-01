import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

typedef AppGlassVoiceControlBuilder =
    Widget Function(BuildContext context, double activation);

class AppGlassComposerMorph extends StatelessWidget {
  const AppGlassComposerMorph({
    required this.voiceMode,
    required this.editorChild,
    required this.submitChild,
    required this.voiceControlBuilder,
    required this.textRadius,
    required this.voiceDiameter,
    this.gap = 8,
    this.floatingGlass = false,
    this.textInputBorder = false,
    super.key,
  });

  static const Key shellKey = ValueKey<String>(
    'app-glass-composer-morph-shell',
  );
  static const Key inputGroupKey = ValueKey<String>(
    'app-glass-composer-morph-input-group',
  );
  static const Key submitScaleKey = ValueKey<String>(
    'app-glass-composer-morph-submit-scale',
  );
  static const Key voiceControlKey = ValueKey<String>(
    'app-glass-composer-morph-voice-control',
  );
  static const Key transitionProgressKey = ValueKey<String>(
    'app-glass-composer-morph-transition-progress',
  );
  static const Key floatingBackdropKey = ValueKey<String>(
    'app-glass-composer-floating-backdrop',
  );
  static const Key textInputBorderKey = ValueKey<String>(
    'app-glass-composer-text-input-border',
  );

  final bool voiceMode;
  final Widget editorChild;
  final Widget submitChild;
  final AppGlassVoiceControlBuilder voiceControlBuilder;
  final double textRadius;
  final double voiceDiameter;
  final double gap;
  final bool floatingGlass;

  /// Page-specific outline for full chat views without an avatar.
  /// The voice control and other frosted surfaces remain borderless.
  final bool textInputBorder;

  @override
  Widget build(BuildContext context) {
    final diameter = voiceDiameter
        .clamp(MaasoGlassTheme.controlTarget, 180.0)
        .toDouble();
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.hasBoundedWidth
            ? constraints.maxWidth
            : diameter + gap + 180;
        return TweenAnimationBuilder<double>(
          tween: Tween<double>(end: voiceMode ? 1 : 0),
          duration: reducedMotion
              ? Duration.zero
              : MaasoGlassTheme.motionEmphasized,
          curve: Curves.linear,
          builder: (context, progress, _) {
            final eased = Curves.easeInOutCubic.transform(progress);
            final inputStartWidth = math.max(0.0, width - diameter - gap);
            final inputWidth = lerpDouble(inputStartWidth, 0, eased)!;
            final inputLeft = lerpDouble(0, width / 2, eased)!;
            final voiceStartLeft = math.max(0.0, width - diameter);
            final voiceLeft = lerpDouble(
              voiceStartLeft,
              (width - diameter) / 2,
              eased,
            )!;
            final submitScale = 1 - eased;
            final submitLeft = math.max(-diameter / 2, inputWidth - diameter);
            final editorWidth = math.max(0.0, inputStartWidth - diameter);
            return SizedBox(
              key: transitionProgressKey,
              width: width,
              height: diameter,
              child: Stack(
                clipBehavior: Clip.none,
                children: <Widget>[
                  Positioned(
                    left: inputLeft,
                    width: inputWidth,
                    height: diameter,
                    child: SizedBox(
                      key: inputGroupKey,
                      width: inputWidth,
                      height: diameter,
                      child: Stack(
                        clipBehavior: Clip.hardEdge,
                        children: <Widget>[
                          Positioned.fill(
                            child: eased > 0.999
                                ? const SizedBox.shrink()
                                : floatingGlass
                                ? _FloatingComposerShell(
                                    key: shellKey,
                                    cornerRadius: textRadius,
                                  )
                                : AppGlassSurface(
                                    key: shellKey,
                                    role: AppGlassSurfaceRole.field,
                                    behavior:
                                        AppGlassSurfaceBehavior.staticSurface,
                                    cornerRadius: textRadius,
                                    padding: EdgeInsets.zero,
                                    clipBehavior: Clip.none,
                                    child: const SizedBox.expand(),
                                  ),
                          ),
                          Positioned(
                            left: 0,
                            width: editorWidth,
                            height: diameter,
                            child: IgnorePointer(
                              ignoring: eased > 0.999,
                              child: editorChild,
                            ),
                          ),
                          Positioned(
                            left: submitLeft,
                            width: diameter,
                            height: diameter,
                            child: ExcludeSemantics(
                              excluding: eased > 0.999,
                              child: Transform.scale(
                                key: submitScaleKey,
                                scale: submitScale,
                                child: submitChild,
                              ),
                            ),
                          ),
                          if (textInputBorder && !voiceMode && eased < 0.999)
                            Positioned.fill(
                              child: IgnorePointer(
                                child: DecoratedBox(
                                  key: textInputBorderKey,
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(
                                      textRadius,
                                    ),
                                    border: Border.all(
                                      color: MaasoGlassTheme.of(
                                        context,
                                      ).divider,
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  Positioned(
                    left: voiceLeft,
                    width: diameter,
                    height: diameter,
                    child: KeyedSubtree(
                      key: voiceControlKey,
                      child: IgnorePointer(
                        ignoring: eased > 0.001 && eased < 0.999,
                        child: voiceControlBuilder(context, eased),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// The composer shares the same bounded material as all frosted inputs.
class _FloatingComposerShell extends StatelessWidget {
  const _FloatingComposerShell({required this.cornerRadius, super.key});

  final double cornerRadius;

  @override
  Widget build(BuildContext context) =>
      AppFrostedInputBackground(cornerRadius: cornerRadius);
}
