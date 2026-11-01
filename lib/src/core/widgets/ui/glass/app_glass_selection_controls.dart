import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

class AppGlassToggle extends StatelessWidget {
  const AppGlassToggle({
    required this.value,
    required this.onChanged,
    this.semanticLabel,
    this.activeColor,
    this.inactiveColor,
    super.key,
  });

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? semanticLabel;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final enabled = onChanged != null;
    final active = activeColor ?? glass.action;
    final inactive = inactiveColor ?? glass.divider;
    final child = _FrostedToggle(
      value: value,
      enabled: enabled,
      onChanged: onChanged,
      activeColor: active,
      inactiveColor: inactive,
    );

    return Semantics(
      container: true,
      button: true,
      toggled: value,
      enabled: enabled,
      label: semanticLabel,
      onTap: enabled ? () => onChanged!(!value) : null,
      child: ExcludeSemantics(
        child: IgnorePointer(
          ignoring: !enabled,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.46,
            duration: MediaQuery.maybeOf(context)?.disableAnimations ?? false
                ? Duration.zero
                : MaasoGlassTheme.motionFast,
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

class _FrostedToggle extends StatelessWidget {
  const _FrostedToggle({
    required this.value,
    required this.enabled,
    required this.onChanged,
    required this.activeColor,
    required this.inactiveColor,
  });

  final bool value;
  final bool enabled;
  final ValueChanged<bool>? onChanged;
  final Color activeColor;
  final Color inactiveColor;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 64,
      height: MaasoGlassTheme.controlTarget,
      child: Center(
        child: Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
          activeTrackColor: activeColor,
          inactiveTrackColor: inactiveColor,
          thumbColor: const WidgetStatePropertyAll(Colors.white),
          trackOutlineWidth: const WidgetStatePropertyAll(0),
          materialTapTargetSize: MaterialTapTargetSize.padded,
        ),
      ),
    );
  }
}

class AppGlassSlider extends StatelessWidget {
  const AppGlassSlider({
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
    this.width = 280,
    this.onChangeStart,
    this.onChangeEnd,
    this.semanticLabel,
    this.activeColor,
    this.inactiveColor,
    super.key,
  }) : assert(max > min),
       assert(value >= min && value <= max);

  final double value;
  final ValueChanged<double>? onChanged;
  final double min;
  final double max;
  final double width;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final String? semanticLabel;
  final Color? activeColor;
  final Color? inactiveColor;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final enabled = onChanged != null;
    final effectiveWidth = width < MaasoGlassTheme.controlTarget
        ? MaasoGlassTheme.controlTarget
        : width;
    final step = (max - min) / 10;
    final increased = (value + step).clamp(min, max).toDouble();
    final decreased = (value - step).clamp(min, max).toDouble();
    final active = activeColor ?? glass.action;
    final inactive = inactiveColor ?? glass.divider;
    final child = SizedBox(
      width: effectiveWidth,
      height: MaasoGlassTheme.controlTarget,
      child: Slider(
        value: value,
        min: min,
        max: max,
        activeColor: active,
        inactiveColor: inactive,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
      ),
    );

    return Semantics(
      container: true,
      enabled: enabled,
      slider: true,
      label: semanticLabel,
      value: value.toStringAsFixed(2),
      increasedValue: enabled ? increased.toStringAsFixed(2) : null,
      decreasedValue: enabled ? decreased.toStringAsFixed(2) : null,
      onIncrease: enabled ? () => onChanged!(increased) : null,
      onDecrease: enabled ? () => onChanged!(decreased) : null,
      child: ExcludeSemantics(
        child: IgnorePointer(
          ignoring: !enabled,
          child: AnimatedOpacity(
            opacity: enabled ? 1 : 0.46,
            duration: MediaQuery.maybeOf(context)?.disableAnimations ?? false
                ? Duration.zero
                : MaasoGlassTheme.motionFast,
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}
