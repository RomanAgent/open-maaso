import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/ui/world_panel.dart';
import 'package:maaso/src/core/services/theme_service.dart';

/// Full-screen shell for an opened generated surface. The surface keeps the
/// whole viewport; only a compact safe-area chrome is layered above it.
class SurfacePortalStage extends StatelessWidget {
  const SurfacePortalStage({
    super.key,
    required this.title,
    required this.child,
    required this.onClose,
    this.trailing,
  });

  final String title;
  final Widget child;
  final VoidCallback onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final topInset = media.padding.top + 8;
    final sideInset = media.size.width < 390 ? 10.0 : 14.0;
    return ThemeBuilder(
      builder: (context, palette) {
        return Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(child: ColoredBox(color: palette.background)),
            Positioned.fill(child: child),
            Positioned(
              top: topInset,
              left: sideInset,
              right: sideInset,
              child: _SurfacePortalChrome(
                title: title,
                onClose: onClose,
                trailing: trailing,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SurfacePortalChrome extends StatelessWidget {
  const _SurfacePortalChrome({
    required this.title,
    required this.onClose,
    this.trailing,
  });

  final String title;
  final VoidCallback onClose;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Row(
      children: [
        ClipOval(
          child: WorldPortalButton(
            icon: Icons.arrow_back_rounded,
            accent: ColorConstant.primaryColor,
            tooltip: 'common.back'.tr,
            onTap: onClose,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: WorldPanel(
            variant: WorldPanelVariant.poster,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            borderRadius: const BorderRadius.all(Radius.circular(22)),
            child: Row(
              children: [
                Icon(
                  Icons.auto_awesome_motion_rounded,
                  size: 18,
                  color: glass.accentText,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: glass.foregroundPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 8),
          ClipOval(child: trailing!),
        ],
      ],
    );
  }
}

/// Poster-style card for generated surfaces, games and curated applets.
class WorldPosterCard extends StatelessWidget {
  const WorldPosterCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.portal,
    this.unseen = false,
    this.compact = false,
    this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget portal;
  final bool unseen;
  final bool compact;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return AppGlassSurface(
      role: AppGlassSurfaceRole.staticSurface,
      behavior: AppGlassSurfaceBehavior.staticSurface,
      cornerRadius: MaasoFrostTokens.cardRadius,
      padding: EdgeInsets.all(compact ? 8 : 14),
      child: compact
          ? _CompactPosterCardContent(
              icon: icon,
              title: title,
              subtitle: subtitle,
              accent: accent,
              portal: portal,
              unseen: unseen,
              badge: badge,
            )
          : _PosterCardContent(
              icon: icon,
              title: title,
              subtitle: subtitle,
              accent: accent,
              portal: portal,
              unseen: unseen,
              badge: badge,
            ),
    );
  }
}

class _PosterCardContent extends StatelessWidget {
  const _PosterCardContent({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.portal,
    required this.unseen,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget portal;
  final bool unseen;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _IconBadge(icon: icon, accent: accent, compact: false),
            const Spacer(),
            ?badge,
            if (unseen) ...[
              if (badge != null) const SizedBox(width: 6),
              _UnseenDot(accent: accent),
            ],
          ],
        ),
        const Spacer(),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 15,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: glass.foregroundPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: glass.foregroundSecondary,
                  fontWeight: FontWeight.w400,
                ),
              ),
            ),
            const SizedBox(width: 8),
            portal,
          ],
        ),
      ],
    );
  }
}

class _CompactPosterCardContent extends StatelessWidget {
  const _CompactPosterCardContent({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.accent,
    required this.portal,
    required this.unseen,
    required this.badge,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final Color accent;
  final Widget portal;
  final bool unseen;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final showIcon = constraints.maxWidth >= 260;
        final lineHeight = scaler.scale(13) * 1.4;
        final showSubtitle =
            !constraints.hasBoundedHeight ||
            constraints.maxHeight >=
                lineHeight * 2 + scaler.scale(12) * 1.4 + 4;
        final titleLines = constraints.hasBoundedHeight && !showSubtitle
            ? (constraints.maxHeight / lineHeight).floor().clamp(1, 2)
            : 2;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (showIcon) ...[
              _IconBadge(icon: icon, accent: accent, compact: true),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: Tooltip(
                message: '$title · $subtitle',
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: titleLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                        color: glass.foregroundPrimary,
                      ),
                    ),
                    if (showSubtitle) ...[
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: glass.foregroundSecondary,
                          fontWeight: FontWeight.w400,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox.square(
              dimension: MaasoFrostTokens.touchMin,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Center(child: portal),
                  if (badge != null)
                    Positioned(top: -4, right: 10, child: badge!),
                  if (unseen)
                    Positioned(
                      top: -2,
                      right: -2,
                      child: _UnseenDot(accent: accent),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class WorldPortalButton extends StatelessWidget {
  const WorldPortalButton({
    super.key,
    required this.icon,
    required this.accent,
    required this.tooltip,
    required this.onTap,
    this.size = MaasoFrostTokens.touchMin,
  });

  final IconData icon;
  final Color accent;
  final String tooltip;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context).copyWith(accent: accent);
    final double dimension = math.max(size, MaasoFrostTokens.touchMin);
    return AppGlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onTap,
      size: dimension,
      iconSize: dimension * 0.46,
      color: glass.accentSoft,
      foregroundColor: glass.accentText,
    );
  }
}

class _IconBadge extends StatelessWidget {
  const _IconBadge({
    required this.icon,
    required this.accent,
    required this.compact,
  });

  final IconData icon;
  final Color accent;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context).copyWith(accent: accent);
    final size = compact ? 42.0 : 50.0;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: glass.accentSoft,
        borderRadius: BorderRadius.circular(MaasoFrostTokens.compactRadius),
      ),
      alignment: Alignment.center,
      child: Icon(icon, color: glass.accentText, size: compact ? 21 : 25),
    );
  }
}

class _UnseenDot extends StatelessWidget {
  const _UnseenDot({required this.accent});

  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: accent,
        // This separator keeps the unread status legible over card content.
        border: Border.all(color: MaasoGlassTheme.of(context).muted, width: 2),
      ),
    );
  }
}
