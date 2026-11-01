import 'package:flutter/material.dart';

import 'package:maaso/src/core/theme/color_constant.dart';

/// Small circular agent avatar used in chat headers, lists, and other
/// compact slots.
///
/// The full 3D character lives behind [AgentAvatarView] on the home
/// page; here we render a lightweight vector badge so the avatar stays
/// consistent across platforms and themes.
class AgentAvatarThumb extends StatelessWidget {
  /// Kept for backward compatibility with stored profile data. The current
  /// visual system uses a vector icon instead of rendering this value.
  final String emoji;
  final double size;
  final Color? backgroundColor;

  const AgentAvatarThumb({
    super.key,
    this.emoji = '',
    this.size = 44,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: backgroundColor ?? ColorConstant.avatarBody,
        shape: BoxShape.circle,
        border: Border.all(color: ColorConstant.textPrimary, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: ColorConstant.textPrimary.withValues(alpha: 0.16),
            offset: const Offset(0, 3),
            blurRadius: 0,
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.smart_toy_rounded,
        size: size * 0.48,
        color: ColorConstant.primaryColor,
      ),
    );
  }
}
