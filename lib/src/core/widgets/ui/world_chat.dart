import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

class WorldChatHeader extends StatelessWidget {
  const WorldChatHeader({
    super.key,
    required this.avatar,
    required this.title,
    required this.subtitle,
    required this.onBack,
  });

  final Widget avatar;
  final String title;
  final String subtitle;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppGlassAppBar(
      height: 64,
      margin: const EdgeInsets.fromLTRB(12, 6, 12, 12),
      leading: AppGlassIconButton(
        icon: Icons.arrow_back_ios_new_rounded,
        tooltip: 'common.back'.tr,
        onPressed: onBack,
      ),
      titleWidget: Row(
        children: <Widget>[
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: glass.foregroundPrimary,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: glass.foregroundSecondary,
                    height: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class WorldChatBubble extends StatelessWidget {
  const WorldChatBubble({
    super.key,
    required this.text,
    required this.time,
    required this.isUser,
    this.dim = false,
  });

  final String text;
  final String time;
  final bool isUser;
  final bool dim;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final tint = isUser
        ? glass.accent.withValues(alpha: dim ? 0.10 : 0.18)
        : glass.staticTint.withValues(alpha: dim ? 0.36 : 0.56);
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.74,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 14),
          child: AppGlassSurface(
            role: AppGlassSurfaceRole.staticSurface,
            behavior: AppGlassSurfaceBehavior.staticSurface,
            cornerRadius: 22,
            tintColor: tint,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            child: Column(
              crossAxisAlignment: isUser
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  text,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontSize: 14,
                    height: 1.42,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  time,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class WorldTypingIndicator extends StatefulWidget {
  const WorldTypingIndicator({super.key});

  @override
  State<WorldTypingIndicator> createState() => _WorldTypingIndicatorState();
}

class _WorldTypingIndicatorState extends State<WorldTypingIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 18, bottom: 8),
        child: Semantics(
          liveRegion: true,
          label: 'chat.agent_typing'.tr,
          child: AppGlassSurface(
            role: AppGlassSurfaceRole.staticSurface,
            behavior: AppGlassSurfaceBehavior.staticSurface,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            cornerRadius: 20,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (index) {
                    final phase = (_controller.value + index * 0.22) % 1.0;
                    final scale =
                        0.72 + (math.sin(phase * math.pi * 2) + 1) * 0.14;
                    return Padding(
                      padding: EdgeInsets.only(right: index == 2 ? 0 : 5),
                      child: Transform.scale(
                        scale: scale,
                        child: const SizedBox.square(
                          dimension: 8,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: ColorConstant.primaryColor,
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
