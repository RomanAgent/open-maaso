import 'package:flutter/material.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

class AdventureChrome {
  const AdventureChrome._();

  static const double borderWidth = 0;
  static const Color ink = MaasoFrostTokens.lightTextPrimary;
  static const Color cream = MaasoFrostTokens.lightSurface;
  static const Color shadow = Color(0x0A000000);
  static const Offset shadowOffset = Offset(0, 3);

  static List<BoxShadow> softShadow({
    double opacity = 0.04,
    Offset offset = shadowOffset,
  }) {
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: opacity),
        offset: offset,
        blurRadius: 12,
      ),
    ];
  }

  static BoxBorder border({
    Color color = ColorConstant.divider,
    double width = borderWidth,
  }) {
    return const Border();
  }
}

class AdventurePanel extends StatelessWidget {
  const AdventurePanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.margin = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(24)),
    this.fillColor = AdventureChrome.cream,
    this.borderColor = ColorConstant.divider,
    this.shadowColor = AdventureChrome.shadow,
    this.shadowOffset = AdventureChrome.shadowOffset,
    this.clip = true,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius borderRadius;
  final Color fillColor;
  final Color borderColor;
  final Color shadowColor;
  final Offset shadowOffset;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      role: AppGlassSurfaceRole.staticSurface,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      margin: margin,
      padding: padding,
      cornerRadius: borderRadius.topLeft.x,
      tintColor: _compatibilityTint(context, fillColor),
      clipBehavior: clip ? Clip.antiAlias : Clip.none,
      child: child,
    );
  }
}

class AdventurePressable extends StatefulWidget {
  const AdventurePressable({
    super.key,
    required this.child,
    required this.onTap,
    required this.tooltip,
    this.selected = false,
    this.fillColor = AdventureChrome.cream,
    this.selectedFillColor = ColorConstant.primaryColor,
    this.borderRadius = const BorderRadius.all(Radius.circular(22)),
    this.padding = EdgeInsets.zero,
    this.constraints = const BoxConstraints.tightFor(width: 56, height: 56),
  });

  final Widget child;
  final VoidCallback? onTap;
  final String tooltip;
  final bool selected;
  final Color fillColor;
  final Color selectedFillColor;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry padding;
  final BoxConstraints constraints;

  @override
  State<AdventurePressable> createState() => _AdventurePressableState();
}

class _AdventurePressableState extends State<AdventurePressable> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    final fill = widget.selected ? widget.selectedFillColor : widget.fillColor;
    final constraints = widget.constraints.copyWith(
      minWidth: widget.constraints.minWidth.clamp(
        MaasoFrostTokens.touchMin,
        double.infinity,
      ),
      minHeight: widget.constraints.minHeight.clamp(
        MaasoFrostTokens.touchMin,
        double.infinity,
      ),
      maxWidth: widget.constraints.maxWidth.clamp(
        MaasoFrostTokens.touchMin,
        double.infinity,
      ),
      maxHeight: widget.constraints.maxHeight.clamp(
        MaasoFrostTokens.touchMin,
        double.infinity,
      ),
    );
    final reducedMotion =
        MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    final duration = reducedMotion ? Duration.zero : MaasoGlassTheme.motionFast;
    final content = AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: duration,
      curve: Curves.easeOutCubic,
      child: AppGlassSurface(
        role: AppGlassSurfaceRole.control,
        behavior: AppGlassSurfaceBehavior.automatic,
        cornerRadius: widget.borderRadius.topLeft.x,
        padding: widget.padding,
        tintColor: enabled
            ? _compatibilityTint(context, fill, primary: widget.selected)
            : MaasoGlassTheme.of(context).muted,
        constraints: constraints,
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: constraints,
          child: Center(child: widget.child),
        ),
      ),
    );

    return Tooltip(
      message: widget.tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        selected: widget.selected,
        label: widget.tooltip,
        child: Listener(
          onPointerDown: enabled
              ? (_) => setState(() => _pressed = true)
              : null,
          onPointerUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onPointerCancel: enabled
              ? (_) => setState(() => _pressed = false)
              : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedOpacity(
              opacity: enabled ? 1 : 0.46,
              duration: duration,
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

class AdventureIconButton extends StatelessWidget {
  const AdventureIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.fillColor = AdventureChrome.cream,
    this.selectedFillColor = ColorConstant.primaryColor,
    this.iconColor,
    this.size = 56,
    this.iconSize = 28,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool selected;
  final Color fillColor;
  final Color selectedFillColor;
  final Color? iconColor;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final fg =
        iconColor ?? (selected ? glass.onAction : glass.foregroundPrimary);
    return AppGlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onTap,
      selected: selected,
      color: _compatibilityTint(
        context,
        selected ? selectedFillColor : fillColor,
        primary: selected,
      ),
      foregroundColor: fg,
      size: size,
      iconSize: iconSize,
    );
  }
}

class AdventureTextButton extends StatelessWidget {
  const AdventureTextButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.fillColor = ColorConstant.primaryColor,
    this.foregroundColor = Colors.white,
    this.fullWidth = true,
    this.minHeight = 54,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final Color fillColor;
  final Color foregroundColor;
  final bool fullWidth;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    return AppGlassButton(
      label: label,
      onPressed: onTap,
      icon: icon,
      color: _compatibilityTint(context, fillColor, primary: true),
      foregroundColor: foregroundColor,
      fullWidth: fullWidth,
      minHeight: minHeight,
    );
  }
}

Color? _compatibilityTint(
  BuildContext context,
  Color color, {
  bool primary = false,
}) {
  if (primary) {
    return MaasoGlassTheme.of(context).copyWith(accent: color).action;
  }
  // Legacy neutral defaults inherit the current light or dark frost surface.
  return color == AdventureChrome.cream ? null : color;
}
