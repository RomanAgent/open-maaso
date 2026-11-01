import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_composer_morph.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

/// Home's send-origin transition. The editor remains mounted throughout it.
class HomeComposerMorph extends StatefulWidget {
  const HomeComposerMorph({
    super.key,
    required this.voiceMode,
    required this.content,
    required this.sendControl,
    required this.voiceControlBuilder,
    required this.voiceLabel,
    this.textInputBorder = false,
  });
  final bool voiceMode, textInputBorder;
  final Widget content, sendControl;
  final AppGlassVoiceControlBuilder voiceControlBuilder;
  final String voiceLabel;
  static const shellKey = ValueKey('home-composer-shell');
  static const movingControlKey = ValueKey('home-composer-moving-action');
  static const textGroupKey = ValueKey('home-composer-text-group');

  @override
  State<HomeComposerMorph> createState() => _HomeComposerMorphState();
}

class _HomeComposerMorphState extends State<HomeComposerMorph> {
  @override
  Widget build(BuildContext context) {
    final reduced = MediaQuery.disableAnimationsOf(context);
    final glass = MaasoGlassTheme.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => TweenAnimationBuilder<double>(
        tween: Tween(end: widget.voiceMode ? 1 : 0),
        duration: reduced ? Duration.zero : const Duration(milliseconds: 620),
        curve: Curves.easeInOutCubic,
        builder: (context, progress, _) {
          final moving = progress > .001 && progress < .999;
          final width = constraints.maxWidth;
          final targetHeight = lerpDouble(48, 56, progress)!;
          final x = lerpDouble(
            math.max(0, width - 56),
            (width - 56) / 2,
            progress,
          )!;
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.bottomCenter,
            children: [
              // The zero-opacity text and controls are separate from the native
              // decorative sampler; its shape closes through bounded clipping.
              ClipRect(
                child: Align(
                  alignment: Alignment.bottomCenter,
                  heightFactor: 1 - progress,
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: Align(
                          alignment: Alignment.bottomCenter,
                          child: FractionallySizedBox(
                            widthFactor: 1 - progress,
                            heightFactor: 1,
                            child: progress > .999
                                ? const SizedBox.shrink()
                                : ClipRRect(
                                    borderRadius: BorderRadius.circular(20),
                                    child: const AppFrostedInputBackground(
                                      key: HomeComposerMorph.shellKey,
                                      cornerRadius: 20,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                      if (widget.textInputBorder && !widget.voiceMode)
                        Positioned.fill(
                          child: IgnorePointer(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: glass.divider,
                                  width: .5,
                                ),
                              ),
                            ),
                          ),
                        ),
                      IgnorePointer(
                        ignoring: widget.voiceMode || moving,
                        child: ExcludeSemantics(
                          excluding: widget.voiceMode || moving,
                          child: Opacity(
                            opacity: 1 - progress,
                            child: KeyedSubtree(
                              key: HomeComposerMorph.textGroupKey,
                              child: widget.content,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(height: 112, width: width),
              Positioned(
                left: x,
                bottom: 8,
                width: targetHeight,
                height: targetHeight,
                child: SizedBox(
                  key: HomeComposerMorph.movingControlKey,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (progress < .999)
                        IgnorePointer(
                          ignoring: widget.voiceMode || moving,
                          child: ExcludeSemantics(
                            excluding: widget.voiceMode || moving,
                            child: Opacity(
                              opacity: 1 - progress,
                              child: Transform.rotate(
                                angle: -progress * math.pi * 5 / 3,
                                child: widget.sendControl,
                              ),
                            ),
                          ),
                        ),
                      if (progress > .001)
                        IgnorePointer(
                          ignoring: moving,
                          child: ExcludeSemantics(
                            excluding: moving,
                            child: Opacity(
                              opacity: progress,
                              child: SizedBox.square(
                                dimension: targetHeight,
                                child: FittedBox(
                                  child: SizedBox.square(
                                    dimension: 56,
                                    child: widget.voiceControlBuilder(
                                      context,
                                      1,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (progress > .001)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 84,
                  child: ExcludeSemantics(
                    excluding: moving,
                    child: Opacity(
                      opacity: progress,
                      child: Text(
                        widget.voiceLabel,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: glass.foregroundSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
