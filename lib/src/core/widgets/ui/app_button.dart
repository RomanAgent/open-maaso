import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Style-aware button. [primary] renders a filled brand-colored CTA; otherwise
/// it renders a neutral iOS glass surface.
class AppButton extends StatelessWidget {
  const AppButton({
    super.key,
    required this.onPressed,
    required this.text,
    this.icon,
    this.color,
    this.primary = true,
    this.fullWidth = true,
  });

  final VoidCallback onPressed;
  final String text;
  final IconData? icon;

  /// Overrides the fill color (defaults to the active iOS accent for [primary]).
  final Color? color;
  final bool primary;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final customTint = color;
    return AppGlassButton(
      label: text,
      icon: icon,
      primary: primary,
      fullWidth: fullWidth,
      color: customTint?.withValues(
        alpha: (customTint.a * 0.62).clamp(0.16, 0.62),
      ),
      onPressed: onPressed,
    );
  }
}
