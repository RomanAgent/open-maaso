import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';

class AppletCategoryFilterBar extends StatelessWidget {
  const AppletCategoryFilterBar({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final AppletCategory selected;
  final ValueChanged<AppletCategory> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: AppFrostSegmentedControl<AppletCategory>(
        selected: selected,
        onSelected: onSelected,
        blur: false,
        segments: [
          for (final category in AppletCategory.values.where(
            (category) => category != AppletCategory.game,
          ))
            AppFrostSegment(
              value: category,
              label: category.labelKey.tr,
              key: ValueKey<String>('applet-filter-${category.name}'),
            ),
        ],
      ),
    );
  }
}

class AppletCategoryBadge extends StatelessWidget {
  const AppletCategoryBadge({super.key, required this.category});

  final AppletCategory category;

  @override
  Widget build(BuildContext context) {
    final label = category.labelKey.tr;
    final glass = MaasoGlassTheme.of(context);
    final foreground = glass.foregroundPrimary;
    return Semantics(
      label: label,
      child: DecoratedBox(
        key: ValueKey<String>('applet-category-${category.name}'),
        decoration: BoxDecoration(
          color: glass.muted,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: foreground,
              fontWeight: FontWeight.w500,
              height: 1,
            ),
          ),
        ),
      ),
    );
  }
}
