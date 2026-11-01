import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Full-height avatar stage for the iOS glass shell.
///
/// This keeps the renderer centered while adding local vector stage cues behind
/// it.
class WorldStage extends StatelessWidget {
  const WorldStage({super.key, required this.child, this.compact = false});

  final Widget child;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(child: child);
  }
}

/// Glass icon button for top-level home HUD actions.
class GameHudButton extends StatelessWidget {
  const GameHudButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.selected = false,
    this.size = 52,
    this.iconSize = 25,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool selected;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return AppGlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onTap,
      selected: selected,
      size: size,
      iconSize: iconSize,
    );
  }
}
