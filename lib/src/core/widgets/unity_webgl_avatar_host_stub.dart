import 'package:flutter/widgets.dart';

class UnityWebGLAvatarHost extends StatelessWidget {
  const UnityWebGLAvatarHost({
    super.key,
    required this.fallback,
    required this.viewportActive,
    this.onReady,
  });

  final Widget fallback;
  final bool viewportActive;
  final VoidCallback? onReady;

  @override
  Widget build(BuildContext context) => fallback;
}
