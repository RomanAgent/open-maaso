import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_palette.dart';

enum AppSecondaryCardTone { normal, selected, disabled, danger }

class AppSecondaryCard extends StatelessWidget {
  const AppSecondaryCard({
    super.key,
    required this.child,
    this.onTap,
    this.tone = AppSecondaryCardTone.normal,
    this.padding = const EdgeInsets.all(16),
    this.margin = EdgeInsets.zero,
    this.cornerRadius = 24,
    this.semanticLabel,
  });

  final Widget child;
  final VoidCallback? onTap;
  final AppSecondaryCardTone tone;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double cornerRadius;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final palette = AppSecondaryPalette.of(context);
    final color = switch (tone) {
      AppSecondaryCardTone.normal => palette.surface,
      AppSecondaryCardTone.selected => palette.selectedSurface,
      AppSecondaryCardTone.disabled => palette.surfaceMuted,
      AppSecondaryCardTone.danger => palette.dangerSurface,
    };
    final enabled = tone != AppSecondaryCardTone.disabled;
    final effectiveTap = enabled ? onTap : null;
    final radius = BorderRadius.circular(cornerRadius);

    return Semantics(
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      button: effectiveTap != null,
      enabled: enabled,
      child: Padding(
        padding: margin,
        child: Material(
          color: color,
          elevation: tone == AppSecondaryCardTone.normal ? 1 : 0,
          shadowColor: palette.shadow,
          shape: RoundedRectangleBorder(borderRadius: radius),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: effectiveTap,
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 48),
              child: Padding(padding: padding, child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class AppSecondarySection extends StatelessWidget {
  const AppSecondarySection({
    super.key,
    required this.child,
    this.title,
    this.subtitle,
    this.margin = EdgeInsets.zero,
  });

  final Widget child;
  final String? title;
  final String? subtitle;
  final EdgeInsetsGeometry margin;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: margin,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (title != null) ...<Widget>[
            Text(
              title!,
              style: TextStyle(
                color: glass.foregroundPrimary,
                fontSize: 15,
                height: 1.25,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                subtitle!,
                style: TextStyle(
                  color: glass.foregroundSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 10),
          ],
          child,
        ],
      ),
    );
  }
}

class AppSecondaryListTile extends StatelessWidget {
  const AppSecondaryListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.destructive = false,
    this.showDivider = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final bool destructive;
  final bool showDivider;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final palette = AppSecondaryPalette.of(context);
    final titleColor = destructive
        ? const Color(0xFFD83A34)
        : glass.foregroundPrimary;
    final effectiveTap = enabled ? onTap : null;

    return Semantics(
      button: effectiveTap != null,
      enabled: enabled,
      child: InkWell(
        onTap: effectiveTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 64),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          decoration: BoxDecoration(
            border: showDivider
                ? Border(bottom: BorderSide(color: palette.border))
                : null,
          ),
          child: Row(
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      title,
                      style: TextStyle(
                        color: titleColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (subtitle != null) ...<Widget>[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: TextStyle(
                          color: glass.foregroundSecondary,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...<Widget>[
                const SizedBox(width: 12),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
