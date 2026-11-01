import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Shared iOS-style glass surface used by cards, panels, chips and fields.
/// Existing callers keep this wrapper while the visual system stays centralized.
class AppSurface extends StatelessWidget {
  const AppSurface({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.tintColor,
    this.panelTintOpacity = 0.22,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;

  /// Optional fill colour for the adventure surface.
  final Color? tintColor;

  /// Alpha applied to [tintColor] for the panel fill.
  final double panelTintOpacity;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final tint = tintColor ?? glass.staticTint;
    final alpha = panelTintOpacity.clamp(0.0, 1.0).toDouble();
    return AppGlassSurface(
      role: AppGlassSurfaceRole.staticSurface,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      padding: padding,
      cornerRadius: borderRadius.topLeft.x,
      tintColor: tint.withValues(alpha: alpha),
      child: child,
    );
  }
}
