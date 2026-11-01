import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/moments/presentation/widgets/moment_card.dart';
import 'package:maaso/src/features/moments/application/moments_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

class MomentsPage extends AppView<MomentsController> {
  const MomentsPage({super.key, this.sectionNavigation});

  final Widget? sectionNavigation;

  @override
  Widget build(BuildContext context) {
    return AppSecondaryScaffold(
      header: AppFrostSectionHeader(
        navigation: sectionNavigation,
        header: _Header(
          onAdd: controller.simulatePost,
          inRelationshipHub: sectionNavigation != null,
        ),
      ),
      body: AppReactiveBuilder(() {
        if (controller.feedItems.isEmpty) {
          return AppSecondaryStateView(
            kind: AppSecondaryStateKind.empty,
            title: 'moments.empty'.tr,
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: controller.feedItems.length,
          itemBuilder: (_, i) {
            final item = controller.feedItems[i];
            return MomentCard(moment: item.moment);
          },
        );
      }),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onAdd;
  final bool inRelationshipHub;
  const _Header({required this.onAdd, required this.inRelationshipHub});

  @override
  Widget build(BuildContext context) {
    return AppSecondaryHeader(
      title:
          (inRelationshipHub ? 'relationship_hub.title' : 'moments.title').tr,
      onBack: () => appNavigation.pop(),
      trailing: AppGlassIconButton(
        icon: Icons.add_rounded,
        tooltip: 'moments.add'.tr,
        onPressed: onAdd,
        color: ColorConstant.accentColor.withValues(alpha: 0.32),
        size: 44,
        iconSize: 24,
      ),
    );
  }
}
