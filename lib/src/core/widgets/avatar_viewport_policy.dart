import 'package:flutter/material.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

class MaasoAvatarViewportPolicy {
  const MaasoAvatarViewportPolicy._();

  static const double baseBottom = 8;
  static const double composerHeight = 64;
  static const double composerGap = 10;
  static const double hudSafeClearance = 76;
  static const double composerSafeGap = -3;

  static double composerBottomFor({
    required EdgeInsets padding,
    required EdgeInsets viewInsets,
  }) {
    final keyboardInset = viewInsets.bottom < 0 ? 0.0 : viewInsets.bottom;
    final bottomSafe = padding.bottom < 0 ? 0.0 : padding.bottom;
    final dockInset = keyboardInset > bottomSafe ? keyboardInset : bottomSafe;
    return baseBottom + dockInset;
  }

  static AvatarViewportSafeArea safeAreaFor({
    required Size size,
    required EdgeInsets padding,
    required EdgeInsets viewInsets,
  }) {
    assert(viewInsets.bottom >= 0);
    final height = size.height <= 0 ? 1.0 : size.height;
    final restingComposerBottom = composerBottomFor(
      padding: padding,
      viewInsets: EdgeInsets.zero,
    );
    final top = ((padding.top + hudSafeClearance) / height)
        .clamp(0.16, 0.20)
        .toDouble();
    final bottom =
        ((restingComposerBottom +
                    composerHeight +
                    composerGap +
                    composerSafeGap) /
                height)
            .clamp(0.12, 0.14)
            .toDouble();
    return AvatarViewportSafeArea(top: top, bottom: bottom);
  }
}
