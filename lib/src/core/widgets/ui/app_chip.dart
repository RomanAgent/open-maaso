import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Style-aware selectable chip / pill.  Use for tag rows, preset pickers and
/// segmented choices.  [selected] fills with the brand color.
class AppChip extends StatelessWidget {
  const AppChip({
    super.key,
    required this.label,
    this.onTap,
    this.selected = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onTap;
  final bool selected;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return AppGlassChip(
      label: label,
      onTap: onTap,
      selected: selected,
      icon: icon,
    );
  }
}
