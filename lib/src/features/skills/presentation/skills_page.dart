import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/skills/application/skill_user_groups.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/skills/presentation/skill_store_page.dart';
import 'package:maaso/src/features/skills/application/skills_controller.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

class SkillsPage extends AppView<SkillsController> {
  const SkillsPage({super.key, this.sectionNavigation, this.header});

  final Widget? sectionNavigation;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return AppSecondaryScaffold(
      header:
          header ??
          AppFrostSectionHeader(
            navigation: sectionNavigation,
            header: const _Header(),
          ),
      body: const _WorkshopSkills(),
    );
  }
}

class _WorkshopSkills extends StatefulWidget {
  const _WorkshopSkills();
  @override
  State<_WorkshopSkills> createState() => _WorkshopSkillsState();
}

class _WorkshopSkillsState extends State<_WorkshopSkills> {
  bool _community = false;
  MarketplaceSkillView _communityView = MarketplaceSkillView.installed;
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final stacked =
                  constraints.maxWidth < 360 ||
                  MediaQuery.textScalerOf(context).scale(15) > 20;
              final width = stacked
                  ? constraints.maxWidth
                  : (constraints.maxWidth - 12) / 2;
              return Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  SizedBox(
                    width: _community ? width : constraints.maxWidth,
                    child: DropdownButtonFormField<bool>(
                      key: const ValueKey('workshop-skill-source'),
                      initialValue: _community,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'skills.source_label'.tr,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: false,
                          child: Text('skills.built_in'.tr),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text('skills.community'.tr),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _community = value);
                      },
                    ),
                  ),
                  if (_community)
                    SizedBox(
                      width: width,
                      child: DropdownButtonFormField<MarketplaceSkillView>(
                        key: const ValueKey('workshop-skill-status'),
                        initialValue: _communityView,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: 'skills.status_label'.tr,
                        ),
                        items: [
                          for (final view in MarketplaceSkillView.values)
                            DropdownMenuItem(
                              value: view,
                              child: Text(view.label),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) {
                            setState(() => _communityView = value);
                          }
                        },
                      ),
                    ),
                ],
              );
            },
          ),
        ),
        Expanded(
          child: _community
              ? MarketplaceMySkillsView(view: _communityView)
              : const _InstalledTab(),
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header();

  @override
  Widget build(BuildContext context) {
    return AppSecondaryHeader(
      title: 'skills.my_skills'.tr,
      onBack: () => appNavigation.pop(),
      trailing: AppReactiveBuilder(() {
        final applying = appServices.find<SkillsController>().isApplying.value;
        return AnimatedOpacity(
          opacity: applying ? 1 : 0,
          duration: const Duration(milliseconds: 200),
          child: const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: ColorConstant.primaryColor,
            ),
          ),
        );
      }),
    );
  }
}

class _InstalledTab extends StatelessWidget {
  const _InstalledTab();

  @override
  Widget build(BuildContext context) {
    final c = appServices.find<SkillsController>();
    final snapshots = appServices.maybeFind<AppCapabilitySnapshotService>();
    if (snapshots != null) {
      return ValueListenableBuilder<AppCapabilitySnapshot>(
        valueListenable: snapshots,
        builder: (context, snapshot, child) => _buildInstalled(c, snapshot),
      );
    }
    return _buildInstalled(c, null);
  }

  Widget _buildInstalled(SkillsController c, AppCapabilitySnapshot? snapshot) {
    return AppReactiveBuilder(() {
      final installed = SkillUserGroupCatalog.all
          .where((group) => group.isVisible(snapshot))
          .toList();
      if (installed.isEmpty) {
        return _EmptyState(text: 'skills.empty_installed'.tr);
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          for (final group in installed)
            _SkillGroupCard(
              group: group,
              capabilityAvailable: group.canEnable(snapshot),
            ),
          const SizedBox(height: 16),
          Text('skills.group.internal_note'.tr),
          const _LocalSkillUsageNote(),
        ],
      );
    });
  }
}

class _SkillGroupCard extends StatelessWidget {
  const _SkillGroupCard({
    required this.group,
    required this.capabilityAvailable,
  });

  final SkillUserGroup group;
  final bool capabilityAvailable;

  @override
  Widget build(BuildContext context) =>
      AppReactiveBuilder(() => _build(context));

  Widget _build(BuildContext context) {
    final c = appServices.find<SkillsController>();
    final glass = MaasoGlassTheme.of(context);
    final hints = group.specs
        .map((spec) => spec.requirementHint)
        .whereType<String>()
        .toSet();
    final optionals = group.optionalSpecs;
    final enabledCount = optionals.where((spec) => c.isEnabled(spec.id)).length;
    final partiallyEnabled =
        enabledCount > 0 && enabledCount < optionals.length;
    return AppSecondaryCard(
      key: ValueKey('builtin-skill-group-${group.id}'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: glass.surface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(group.icon, color: glass.accentText, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.nameKey.tr,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: glass.foregroundPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  group.descriptionKey.tr,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.5,
                    color: glass.foregroundSecondary,
                  ),
                ),
                _LocalSkillUsage(group: group),
                const SizedBox(height: 8),
                if (group.isCore)
                  _Pill(
                    text: 'skills.core_always_on'.tr,
                    color: glass.accentText,
                  )
                else ...[
                  if (partiallyEnabled)
                    Text('skills.group.partially_enabled'.tr),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Switch.adaptive(
                      key: ValueKey('builtin-skill-group-toggle-${group.id}'),
                      value: enabledCount > 0,
                      activeThumbColor: glass.accent,
                      onChanged: c.isApplying.value
                          ? null
                          : (on) {
                              if (!on || capabilityAvailable) {
                                c.toggleGroup(group.id, on);
                              }
                            },
                    ),
                  ),
                ],
                if (group.configurationRoute case final route?) ...[
                  const SizedBox(height: 8),
                  AppGlassButton(
                    key: ValueKey('builtin-skill-group-configure-${group.id}'),
                    label: 'skills.group.configure'.tr,
                    icon: Icons.chevron_right_rounded,
                    primary: false,
                    onPressed: () => appNavigation.push(route),
                  ),
                ],
                for (final hint in hints) ...[
                  const SizedBox(height: 6),
                  Text(
                    'skills.warning'.trParams({'message': hint.tr}),
                    style: TextStyle(
                      fontSize: 13,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                ],
                if (!capabilityAvailable) ...[
                  const SizedBox(height: 6),
                  Text(
                    'common.action_unavailable'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _LocalSkillUsage extends ConsumerWidget {
  const _LocalSkillUsage({required this.group});

  final SkillUserGroup group;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServiceGraphRevisionProvider);
    final service = ref
        .read(appServicesProvider)
        .maybeFind<SkillUsageService>();
    if (service == null) {
      return const SizedBox.shrink();
    }
    final glass = MaasoGlassTheme.of(context);
    return AppReactiveBuilder(() {
      final loading = service.loading.value;
      final unavailable = service.unavailable.value;
      final String label;
      if (!service.isCurrent || unavailable) {
        label = 'skills.usage_unavailable'.tr;
      } else if (loading) {
        label = 'skills.usage_loading'.tr;
      } else {
        final usage = group.usage(service);
        label = usage.started == 0
            ? 'skills.usage_no_record'.tr
            : 'skills.usage_count'.trParams({'count': '${usage.started}'});
      }
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          label,
          key: ValueKey('builtin-skill-group-usage-${group.id}'),
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: glass.foregroundSecondary,
          ),
        ),
      );
    });
  }
}

class _LocalSkillUsageNote extends ConsumerWidget {
  const _LocalSkillUsageNote();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServiceGraphRevisionProvider);
    if (ref.read(appServicesProvider).maybeFind<SkillUsageService>() == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'skills.usage_note'.tr,
        key: const ValueKey('builtin-skill-usage-note'),
        style: TextStyle(
          fontSize: 13,
          height: 1.5,
          color: MaasoGlassTheme.of(context).foregroundSecondary,
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String text;
  final Color color;
  const _Pill({required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    final foreground = MaasoGlassTheme.of(context).foregroundPrimary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: foreground,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String text;
  const _EmptyState({required this.text});
  @override
  Widget build(BuildContext context) {
    return AppSecondaryStateView(
      kind: AppSecondaryStateKind.empty,
      title: text,
    );
  }
}
