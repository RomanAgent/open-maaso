import 'package:flutter/material.dart';

import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_content.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary_palette.dart';

enum AppSecondaryStateKind { loading, empty, error, offline }

class AppSecondaryStateView extends StatelessWidget {
  const AppSecondaryStateView({
    super.key,
    required this.kind,
    required this.title,
    this.message,
    this.icon,
    this.actionLabel,
    this.onAction,
  });

  final AppSecondaryStateKind kind;
  final String title;
  final String? message;
  final IconData? icon;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    if (kind == AppSecondaryStateKind.loading) {
      return const AppSecondarySkeletonList();
    }
    final glass = MaasoGlassTheme.of(context);
    final resolvedIcon =
        icon ??
        switch (kind) {
          AppSecondaryStateKind.empty => Icons.inbox_outlined,
          AppSecondaryStateKind.error => Icons.error_outline_rounded,
          AppSecondaryStateKind.offline => Icons.cloud_off_rounded,
          AppSecondaryStateKind.loading => Icons.hourglass_empty_rounded,
        };

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AppSecondaryCard(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(resolvedIcon, size: 34, color: glass.foregroundSecondary),
              const SizedBox(height: 12),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: glass.foregroundPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (message != null && message!.trim().isNotEmpty) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
              if (actionLabel != null && onAction != null) ...<Widget>[
                const SizedBox(height: 14),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class AppSecondarySkeletonList extends StatelessWidget {
  const AppSecondarySkeletonList({super.key, this.itemCount = 3});

  static const itemKey = ValueKey<String>('app-secondary-skeleton-item');

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final palette = AppSecondaryPalette.of(context);
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: List<Widget>.generate(
          itemCount,
          (index) => Padding(
            padding: EdgeInsets.only(bottom: index == itemCount - 1 ? 0 : 12),
            child: AppSecondaryCard(
              key: itemKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  _SkeletonBar(color: palette.surfaceMuted, width: 132),
                  const SizedBox(height: 10),
                  _SkeletonBar(color: palette.surfaceMuted),
                  const SizedBox(height: 7),
                  _SkeletonBar(color: palette.surfaceMuted, width: 210),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkeletonBar extends StatelessWidget {
  const _SkeletonBar({required this.color, this.width});

  final Color color;
  final double? width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width ?? double.infinity,
      height: 12,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(6),
      ),
    );
  }
}
