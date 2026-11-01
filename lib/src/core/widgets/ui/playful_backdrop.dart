import 'package:flutter/material.dart';

import 'package:maaso/src/core/services/theme_service.dart';

/// Static theme canvas behind the Unity world when its scene is unavailable.
class PlayfulBackdrop extends StatelessWidget {
  const PlayfulBackdrop({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ThemeBuilder(
      builder: (context, palette) {
        return ColoredBox(color: palette.background, child: child);
      },
    );
  }
}
