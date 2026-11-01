import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

enum WorldPanelVariant { pass, backpack, poster }

/// Borderless White Frost panel for app surfaces.
class WorldPanel extends StatelessWidget {
  const WorldPanel({
    super.key,
    required this.child,
    this.variant = WorldPanelVariant.poster,
    this.padding = const EdgeInsets.all(18),
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.tintOpacity,
  });

  final Widget child;
  final WorldPanelVariant variant;
  final EdgeInsetsGeometry padding;
  final BorderRadius borderRadius;
  final double? tintOpacity;

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final isDark = brightness == Brightness.dark;
    final alpha = (tintOpacity ?? 1).clamp(0.0, 1.0);
    return AppGlassSurface(
      role: AppGlassSurfaceRole.staticSurface,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      cornerRadius: borderRadius.topLeft.x,
      padding: padding,
      tintColor: _fillColor(isDark).withValues(alpha: alpha),
      child: child,
    );
  }

  Color _fillColor(bool isDark) {
    if (isDark) {
      return switch (variant) {
        WorldPanelVariant.pass => MaasoFrostTokens.darkSurface,
        WorldPanelVariant.backpack => MaasoFrostTokens.darkMuted,
        WorldPanelVariant.poster => MaasoFrostTokens.darkSurface,
      };
    }
    return switch (variant) {
      WorldPanelVariant.pass => MaasoFrostTokens.lightSurface,
      WorldPanelVariant.backpack => MaasoFrostTokens.lightMuted,
      WorldPanelVariant.poster => MaasoFrostTokens.lightSurface,
    };
  }
}
