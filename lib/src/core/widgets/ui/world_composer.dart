import 'package:flutter/material.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';

/// Shared bottom composer chrome for text and voice entry points.
class WorldComposerPanel extends StatelessWidget {
  const WorldComposerPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(6, 6, 8, 6),
    this.margin = EdgeInsets.zero,
    this.borderRadius = const BorderRadius.all(Radius.circular(32)),
    this.bottomSafeArea = false,
    this.listening = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final BorderRadius borderRadius;
  final bool bottomSafeArea;
  final bool listening;

  @override
  Widget build(BuildContext context) {
    Widget panel = AppGlassSurface(
      role: AppGlassSurfaceRole.chrome,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      margin: margin,
      padding: padding,
      cornerRadius: borderRadius.topLeft.x,
      tintColor: listening
          ? ColorConstant.primaryColor.withValues(alpha: 0.20)
          : null,
      child: child,
    );
    if (bottomSafeArea) panel = SafeArea(top: false, child: panel);
    return panel;
  }
}

class WorldComposerIconButton extends StatelessWidget {
  const WorldComposerIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.accent,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final color = accent ?? MaasoGlassTheme.of(context).foregroundPrimary;
    return AppGlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onTap,
      size: 48,
      iconSize: 22,
      foregroundColor: color,
    );
  }
}

class WorldComposerSendButton extends StatelessWidget {
  const WorldComposerSendButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.enabled = true,
    this.accent,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool enabled;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    final activeColor = accent ?? MaasoFrostTokens.composerAction;
    final fill = enabled
        ? activeColor.withValues(alpha: MaasoFrostTokens.capsuleFillAlpha)
        : ColorConstant.textSecondary.withValues(alpha: 0.28);
    return AppGlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
      selected: enabled,
      color: fill,
      foregroundColor: Colors.white,
      size: 48,
      iconSize: 22,
    );
  }
}
