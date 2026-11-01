import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Style-aware content card (rounded, padded surface).  Use for grouped
/// content blocks — settings rows, info panels, list items.
class AppCard extends StatefulWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.borderRadius = const BorderRadius.all(Radius.circular(26)),
    this.tintColor,
    this.onTap,
    this.panelTintOpacity = 0.32,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? tintColor;
  final VoidCallback? onTap;
  final double panelTintOpacity;

  @override
  State<AppCard> createState() => _AppCardState();
}

class _AppCardState extends State<AppCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius.resolve(Directionality.of(context));
    final glass = MaasoGlassTheme.of(context);
    final tint = widget.tintColor ?? glass.staticTint;
    final surface = AppGlassSurface(
      role: AppGlassSurfaceRole.staticSurface,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      padding: widget.padding,
      cornerRadius: widget.borderRadius.topLeft.x,
      tintColor: tint.withValues(
        alpha: widget.panelTintOpacity.clamp(0.0, 1.0),
      ),
      child: widget.child,
    );
    if (widget.onTap == null) return surface;
    return Semantics(
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        child: AnimatedScale(
          scale: _pressed ? 0.985 : 1,
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOutCubic,
          child: ClipRRect(borderRadius: radius, child: surface),
        ),
      ),
    );
  }
}

/// Thinner, less-rounded surface for chrome pieces — input bars, toolbars,
/// floating pills.  Same styling engine, different default geometry.
class AppPanel extends StatelessWidget {
  const AppPanel({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(999)),
    this.tintColor,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final Color? tintColor;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      role: AppGlassSurfaceRole.chrome,
      behavior: AppGlassSurfaceBehavior.automatic,
      padding: padding,
      cornerRadius: borderRadius.topLeft.x,
      tintColor: tintColor,
      child: child,
    );
  }
}
