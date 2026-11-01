import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_surface.dart';
import 'package:maaso/src/core/widgets/ui/glass/glass_render_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

import 'voice_orb/glass_voice_orb_state.dart';

export 'voice_orb/glass_voice_orb_state.dart';

class AppGlassVoiceOrb extends StatefulWidget {
  const AppGlassVoiceOrb({
    required this.phase,
    required this.amplitude,
    this.amplitudeStream,
    this.onTap,
    this.reducedMotion,
    this.renderMode,
    this.semanticLabel = 'chat.voice_assistant',
    this.size = 96,
    this.useGlassShell = true,
    this.showProjectedHalo = true,
    this.fillColor,
    super.key,
  });

  static const Key semanticsKey = ValueKey<String>('glass-voice-orb-semantics');
  static const Key waveformKey = ValueKey<String>('frost-voice-waveform');
  static const Key glassShellKey = ValueKey<String>('glass-voice-orb-shell');
  static const Key reducedMotionKey = ValueKey<String>(
    'glass-voice-orb-reduced-motion',
  );

  final VoiceOrbPhase phase;
  final double amplitude;
  final Stream<double>? amplitudeStream;
  final VoidCallback? onTap;
  final bool? reducedMotion;
  final GlassRenderMode? renderMode;
  final String semanticLabel;
  final double size;
  final bool useGlassShell;
  final bool showProjectedHalo;
  final Color? fillColor;

  @override
  State<AppGlassVoiceOrb> createState() => _AppGlassVoiceOrbState();
}

class _AppGlassVoiceOrbState extends State<AppGlassVoiceOrb>
    with SingleTickerProviderStateMixin {
  late final AnimationController _amplitudeMotion;
  StreamSubscription<double>? _amplitudeSubscription;
  late double _amplitudeFrom;
  late double _amplitudeTarget;
  bool _reducedMotion = false;

  @override
  void initState() {
    super.initState();
    final initialAmplitude = normalizeVoiceOrbAmplitude(widget.amplitude);
    _amplitudeFrom = initialAmplitude;
    _amplitudeTarget = initialAmplitude;
    _amplitudeMotion = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
      value: 1,
    );
    _subscribeToAmplitude();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncMotionPreference();
  }

  @override
  void didUpdateWidget(covariant AppGlassVoiceOrb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.amplitudeStream != widget.amplitudeStream) {
      _subscribeToAmplitude();
    }
    if (widget.amplitudeStream == null &&
        oldWidget.amplitude != widget.amplitude) {
      _setAmplitudeTarget(widget.amplitude);
    }
    if (oldWidget.reducedMotion != widget.reducedMotion) {
      _syncMotionPreference();
    }
  }

  void _subscribeToAmplitude() {
    _amplitudeSubscription?.cancel();
    _amplitudeSubscription = widget.amplitudeStream?.listen((value) {
      if (!mounted) return;
      _setAmplitudeTarget(value);
    });
  }

  double get _visualAmplitude => smoothVoiceOrbAmplitude(
    from: _amplitudeFrom,
    to: _amplitudeTarget,
    t: Curves.easeOutCubic.transform(_amplitudeMotion.value),
  );

  void _setAmplitudeTarget(double value) {
    final next = normalizeVoiceOrbAmplitude(value);
    _amplitudeFrom = _visualAmplitude;
    _amplitudeTarget = next;
    if (_reducedMotion) {
      _amplitudeMotion.value = 1;
      return;
    }
    _amplitudeMotion
      ..value = 0
      ..forward();
  }

  void _syncMotionPreference() {
    final next =
        widget.reducedMotion ??
        (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
    _reducedMotion = next;
    if (_reducedMotion) {
      _amplitudeFrom = _amplitudeTarget;
      _amplitudeMotion.value = 1;
    }
  }

  @override
  void dispose() {
    _amplitudeSubscription?.cancel();
    _amplitudeMotion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _amplitudeMotion,
      builder: (context, _) => _buildOrb(context, _visualAmplitude),
    );
  }

  Widget _buildOrb(BuildContext context, double amplitude) {
    final size = widget.size
        .clamp(MaasoGlassTheme.controlTarget, 180.0)
        .toDouble();
    final glass = MaasoGlassTheme.of(context);
    final fill =
        widget.fillColor ??
        MaasoFrostTokens.composerAction.withValues(
          alpha: MaasoFrostTokens.capsuleFillAlpha,
        );
    final waveform = CustomPaint(
      key: AppGlassVoiceOrb.waveformKey,
      painter: _VoiceWaveformPainter(
        phase: widget.phase,
        amplitude: amplitude,
        color: glass.onAction,
      ),
    );
    final visual = widget.useGlassShell
        ? AppGlassSurface(
            key: AppGlassVoiceOrb.glassShellKey,
            role: AppGlassSurfaceRole.orb,
            renderMode: widget.renderMode,
            tintColor: fill,
            cornerRadius: size / 2,
            child: waveform,
          )
        : DecoratedBox(
            key: AppGlassVoiceOrb.glassShellKey,
            decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
            child: waveform,
          );
    final keyedVisual = _reducedMotion
        ? KeyedSubtree(key: AppGlassVoiceOrb.reducedMotionKey, child: visual)
        : visual;
    final phaseLabel = switch (widget.phase) {
      VoiceOrbPhase.listening => 'chat.voice_listening'.tr,
      VoiceOrbPhase.recognizing => 'chat.voice_recognizing'.tr,
      VoiceOrbPhase.thinking => 'chat.voice_thinking'.tr,
      VoiceOrbPhase.speaking => 'chat.voice_speaking'.tr,
    };

    return Semantics(
      key: AppGlassVoiceOrb.semanticsKey,
      button: widget.onTap != null,
      label: widget.semanticLabel.tr,
      hint: phaseLabel,
      value: '${(amplitude * 100).round()}%',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: RepaintBoundary(
          child: SizedBox(
            width: size,
            height: size,
            child: Stack(
              fit: StackFit.expand,
              alignment: Alignment.topCenter,
              children: <Widget>[keyedVisual],
            ),
          ),
        ),
      ),
    );
  }
}

/// Audio-driven marks only: no optical shader, glow, or idle animation.
class _VoiceWaveformPainter extends CustomPainter {
  const _VoiceWaveformPainter({
    required this.phase,
    required this.amplitude,
    required this.color,
  });

  final VoiceOrbPhase phase;
  final double amplitude;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final side = math.min(size.width, size.height);
    final center = size.center(Offset.zero);
    final paint = Paint()..color = color;
    if (phase == VoiceOrbPhase.thinking || phase == VoiceOrbPhase.recognizing) {
      for (var i = 0; i < 3; i++) {
        final radius = side * (phase == VoiceOrbPhase.thinking ? 0.045 : 0.06);
        canvas.drawCircle(
          Offset(center.dx + (i - 1) * side * 0.17, center.dy),
          radius,
          paint,
        );
      }
      return;
    }
    const weights = <double>[0.55, 0.85, 1, 0.75, 0.4];
    for (var i = 0; i < weights.length; i++) {
      final height = side * (0.13 + weights[i] * (0.15 + amplitude * 0.22));
      final rect = Rect.fromCenter(
        center: Offset(center.dx + (i - 2) * side * 0.115, center.dy),
        width: side * 0.077,
        height: height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(side * 0.04)),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VoiceWaveformPainter oldDelegate) =>
      phase != oldDelegate.phase ||
      amplitude != oldDelegate.amplitude ||
      color != oldDelegate.color;
}
