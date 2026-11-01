import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/installed_prompt_skill_adapter.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/presentation/skill_evolution_page.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

class SkillStorePage extends AppView<SkillStoreController> {
  const SkillStorePage({super.key, this.sectionNavigation, this.header});

  final Widget? sectionNavigation;
  final Widget? header;

  @override
  Widget build(BuildContext context) {
    return AppSecondaryScaffold(
      contentMaxWidth: 640,
      header:
          header ??
          AppFrostSectionHeader(
            navigation: sectionNavigation,
            header: AppSecondaryHeader(
              title: 'skill_store.title'.tr,
              onBack: appNavigation.pop,
              trailing: AppReactiveBuilder(
                () => AppGlassIconButton(
                  icon: Icons.refresh_rounded,
                  tooltip: 'skill_store.refresh'.tr,
                  onPressed: controller.isLoading.value
                      ? null
                      : () => controller.reload(),
                ),
              ),
            ),
          ),
      body: const _FlatSkillCatalog(),
    );
  }
}

class _FlatSkillCatalog extends StatefulWidget {
  const _FlatSkillCatalog();
  @override
  State<_FlatSkillCatalog> createState() => _FlatSkillCatalogState();
}

class _FlatSkillCatalogState extends State<_FlatSkillCatalog> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool _ranked = false;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _clearSearch() {
    _search.clear();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<SkillStoreController>();
    final glass = MaasoGlassTheme.of(context);
    return AppReactiveBuilder(() {
      final source = _ranked ? controller.rankedSkills : controller.skills;
      final query = _search.text.trim().toLowerCase();
      final visible = source.where((skill) {
        if (query.isEmpty) return true;
        return [
          skill.title,
          skill.summary,
          skill.category.displayName,
          skill.publisherId,
          skill.skillKey,
        ].any((text) => text.toLowerCase().contains(query));
      }).toList();
      final error = controller.error.value;
      final loading = controller.isLoading.value;
      return RefreshIndicator(
        color: ColorConstant.primaryColor,
        onRefresh: controller.reload,
        child: CustomScrollView(
          key: const ValueKey('fallback-skill-catalog-scroll'),
          controller: _scroll,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              sliver: SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    AppGlassField(
                      key: const ValueKey('skill-store-search'),
                      controller: _search,
                      hintText: 'skill_store.search_hint'.tr,
                      labelText: 'skill_store.search_hint'.tr,
                      prefixIcon: Icons.search_rounded,
                      textInputAction: TextInputAction.search,
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => setState(() {}),
                      suffix: query.isEmpty
                          ? null
                          : AppGlassIconButton(
                              key: const ValueKey('skill-store-clear-search'),
                              icon: Icons.close_rounded,
                              tooltip: 'skill_store.clear_search'.tr,
                              onPressed: _clearSearch,
                            ),
                    ),
                    const SizedBox(height: 16),
                    DropdownButtonFormField<bool>(
                      key: const ValueKey('skill-store-sort'),
                      initialValue: _ranked,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: 'skill_store.sort_label'.tr,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: false,
                          child: Text('skill_store.tab.store'.tr),
                        ),
                        DropdownMenuItem(
                          value: true,
                          child: Text('skill_store.tab.ranking'.tr),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _ranked = value);
                      },
                    ),
                  ],
                ),
              ),
            ),
            if (loading && source.isEmpty)
              SliverToBoxAdapter(
                child: AppSecondaryStateView(
                  kind: AppSecondaryStateKind.loading,
                  title:
                      (_ranked
                              ? 'skill_store.ranking_loading'
                              : 'skill_store.loading')
                          .tr,
                ),
              )
            else if (error != null && source.isEmpty)
              SliverToBoxAdapter(
                child: _StoreMessage(
                  icon: Icons.cloud_off_rounded,
                  title: 'skill_store.load_failed'.tr,
                  message: error,
                  actionLabel: 'common.retry'.tr,
                  onAction: controller.reload,
                ),
              )
            else if (source.isEmpty)
              SliverToBoxAdapter(
                child: _StoreMessage(
                  icon: Icons.extension_outlined,
                  title:
                      (_ranked
                              ? 'skill_store.ranking_empty'
                              : 'skill_store.empty')
                          .tr,
                  message:
                      (_ranked
                              ? 'skill_store.ranking_note'
                              : 'skill_store.empty_message')
                          .tr,
                  actionLabel: 'common.refresh'.tr,
                  onAction: controller.reload,
                ),
              )
            else if (visible.isEmpty)
              SliverPadding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    children: [
                      _InlineEmpty(message: 'asset_store.empty'.tr),
                      TextButton(
                        key: const ValueKey('skill-store-empty-clear'),
                        onPressed: _clearSearch,
                        child: Text('skill_store.clear_search'.tr),
                      ),
                    ],
                  ),
                ),
              )
            else ...[
              if (error != null)
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  sliver: SliverToBoxAdapter(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(error),
                        TextButton(
                          onPressed: controller.reload,
                          child: Text('common.retry'.tr),
                        ),
                      ],
                    ),
                  ),
                ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
                sliver: DecoratedSliver(
                  key: const ValueKey('fallback-skill-frost-group'),
                  decoration: BoxDecoration(
                    color: glass.muted,
                    borderRadius: BorderRadius.circular(
                      MaasoGlassTheme.surfaceRadius,
                    ),
                  ),
                  sliver: SliverList.separated(
                    itemCount: visible.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      thickness: .5,
                      indent: 76,
                      endIndent: 16,
                      color: glass.divider,
                    ),
                    itemBuilder: (context, index) => _SkillStoreCard(
                      skill: visible[index],
                      rank: _ranked ? source.indexOf(visible[index]) + 1 : null,
                      groupBorderRadius: BorderRadius.vertical(
                        top: index == 0
                            ? const Radius.circular(
                                MaasoGlassTheme.surfaceRadius,
                              )
                            : Radius.zero,
                        bottom: index == visible.length - 1
                            ? const Radius.circular(
                                MaasoGlassTheme.surfaceRadius,
                              )
                            : Radius.zero,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    });
  }
}

enum MarketplaceSkillView {
  installed,
  drafts,
  published;

  String get label => switch (this) {
    MarketplaceSkillView.installed => 'skill_store.installed_badge'.tr,
    MarketplaceSkillView.drafts => 'skill_store.drafts_section'.tr,
    MarketplaceSkillView.published => 'skill_store.published_section'.tr,
  };
}

class MarketplaceMySkillsView extends AppView<SkillStoreController> {
  const MarketplaceMySkillsView({
    super.key,
    this.view = MarketplaceSkillView.installed,
  });

  final MarketplaceSkillView view;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: AppReactiveBuilder(() {
            final skills = view == MarketplaceSkillView.installed
                ? controller.installedSkills
                : controller.mySkills;
            final empty = view == MarketplaceSkillView.drafts
                ? controller.evolutionDrafts.isEmpty
                : skills.isEmpty;
            if (controller.isLoading.value && empty) {
              return AppSecondaryStateView(
                kind: AppSecondaryStateKind.loading,
                title: 'skill_store.loading'.tr,
              );
            }
            if (controller.error.value != null && empty) {
              return _StoreMessage(
                icon: Icons.cloud_off_rounded,
                title: 'skill_store.load_failed'.tr,
                message: controller.error.value!,
                actionLabel: 'common.retry'.tr,
                onAction: controller.reload,
              );
            }
            return RefreshIndicator(
              color: ColorConstant.primaryColor,
              onRefresh: controller.reload,
              child: ListView(
                key: ValueKey('community-skill-list-${view.name}'),
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
                children: [
                  if (empty)
                    _InlineEmpty(
                      message: switch (view) {
                        MarketplaceSkillView.installed =>
                          'skill_store.installed_empty'.tr,
                        MarketplaceSkillView.drafts =>
                          'skill_store.drafts_empty'.tr,
                        MarketplaceSkillView.published =>
                          'skill_store.published_empty'.tr,
                      },
                    )
                  else if (view == MarketplaceSkillView.drafts)
                    for (final draft in controller.evolutionDrafts)
                      _EvolutionDraftCard(draft: draft)
                  else if (view == MarketplaceSkillView.published)
                    for (final skill in skills) _MySkillCard(skill: skill)
                  else
                    for (final skill in skills) _SkillStoreCard(skill: skill),
                  if (!empty && view == MarketplaceSkillView.installed)
                    Text(
                      'skills.prompt_usage_note'.tr,
                      style: TextStyle(
                        color: MaasoGlassTheme.of(context).foregroundSecondary,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                ],
              ),
            );
          }),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: AppGlassButton(
              key: const ValueKey('workshop-upload-skill'),
              label: 'skill_store.upload_title'.tr,
              icon: Icons.upload_file_rounded,
              primary: false,
              fullWidth: true,
              onPressed: () => showAppGlassSheet<void>(
                context: context,
                builder: (_) =>
                    const _ScrollableSkillSheet(child: _UploadSkillPanel()),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _SkillStoreCard extends AppView<SkillStoreController> {
  const _SkillStoreCard({
    required this.skill,
    this.rank,
    this.groupBorderRadius,
  });

  final MarketplaceSkill skill;
  final int? rank;
  final BorderRadius? groupBorderRadius;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppReactiveBuilder(() {
      final installation = controller.installationFor(skill);
      final installed = installation != null && !installation.isUninstalled;
      final label = installed
          ? installation.isActive
                ? 'skill_store.installed_badge'.tr
                : 'skill_store.disabled_badge'.tr
          : 'skill_store.view_details'.tr;
      final source = skill.publisherId == MarketplaceSkill.officialPublisherId
          ? 'skills.official'.tr
          : 'skills.community'.tr;
      final grouped = groupBorderRadius != null;
      final content = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkillCover(skill: skill, onGroup: grouped),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skill.title,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  skill.summary,
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                if (installed) _CommunitySkillUsage(skill: skill),
                SizedBox(height: grouped ? 12 : 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      '${rank == null ? '' : '#$rank · '}'
                      '$source · ${skill.category.displayName}',
                      style: TextStyle(
                        color: glass.foregroundSecondary,
                        fontSize: 13,
                        height: 1.5,
                      ),
                    ),
                    AppGlassButton(
                      label: label,
                      primary: !grouped && !installed,
                      foregroundColor: grouped ? glass.accentText : null,
                      onPressed: () => _openDetails(context),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      );
      final key = ValueKey('marketplace-skill-${skill.skillVersionId}');
      if (!grouped) {
        return AppSecondaryCard(
          key: key,
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.all(16),
          onTap: () => _openDetails(context),
          child: content,
        );
      }
      return Semantics(
        key: key,
        button: true,
        enabled: true,
        child: Material(
          type: MaterialType.transparency,
          borderRadius: groupBorderRadius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            borderRadius: groupBorderRadius,
            onTap: () => _openDetails(context),
            child: Padding(padding: const EdgeInsets.all(16), child: content),
          ),
        ),
      );
    });
  }

  Future<void> _openDetails(BuildContext context) async {
    await showAppGlassSheet<void>(
      context: context,
      builder: (sheetContext) {
        final glass = MaasoGlassTheme.of(sheetContext);
        return _ScrollableSkillSheet(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      skill.title,
                      style: TextStyle(
                        color: glass.foregroundPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  AppGlassIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'common.close'.tr,
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${skill.category.displayName} · v${skill.versionName} · ${skill.publisherId}',
                style: TextStyle(
                  color: glass.foregroundSecondary,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                skill.summary,
                style: const TextStyle(fontSize: 15, height: 1.5),
              ),
              const SizedBox(height: 16),
              _SkillSocialRow(skill: skill),
              if (skill.permissions.isNotEmpty) ...[
                const SizedBox(height: 16),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final permission in skill.permissions)
                      AppGlassChip(
                        label: permission,
                        icon: Icons.lock_outline_rounded,
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              _InstallationActions(
                skill: skill,
                onInstall: () =>
                    _installSkillFromCard(sheetContext, controller, skill),
              ),
              const SizedBox(height: 8),
              AppGlassButton(
                label: 'skill_store.details_tooltip'.tr,
                icon: Icons.account_tree_outlined,
                primary: false,
                fullWidth: true,
                onPressed: () {
                  Navigator.of(sheetContext).pop();
                  appNavigation.pushPage<void>(
                    () => SkillEvolutionDetailPage(skill: skill),
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

class _CommunitySkillUsage extends ConsumerWidget {
  const _CommunitySkillUsage({required this.skill});

  final MarketplaceSkill skill;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServiceGraphRevisionProvider);
    final service = ref
        .read(appServicesProvider)
        .maybeFind<SkillUsageService>();
    if (service == null) return const SizedBox.shrink();
    final key = promptSkillUsageKey(
      InstalledPromptSkillAdapter.descriptorIdForSkill(skill),
    );
    if (key == null) return const SizedBox.shrink();
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
        final usage = service.forSkill(key);
        label = usage.started == 0
            ? 'skills.prompt_usage_no_record'.tr
            : 'skills.prompt_usage_count'.trParams({
                'count': '${usage.started}',
              });
      }
      return Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          label,
          key: ValueKey('community-skill-usage-${skill.skillVersionId}'),
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

class _SkillCover extends StatelessWidget {
  const _SkillCover({required this.skill, this.onGroup = false});

  final MarketplaceSkill skill;
  final bool onGroup;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final uri = Uri.tryParse(skill.coverAssetUrl.trim());
    final validImage =
        uri != null && uri.scheme == 'https' && uri.host.isNotEmpty;
    final icon = switch (skill.category) {
      SkillCategory.observation => Icons.visibility_outlined,
      SkillCategory.reasoning => Icons.psychology_outlined,
      SkillCategory.collaboration => Icons.hub_outlined,
      SkillCategory.unknown => Icons.extension_outlined,
    };
    final fallback = Icon(icon, color: glass.accentText, size: 24);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        width: 48,
        height: 48,
        child: ColoredBox(
          color: onGroup ? glass.surface : glass.muted,
          child: validImage
              ? Image.network(
                  uri.toString(),
                  fit: BoxFit.cover,
                  excludeFromSemantics: true,
                  errorBuilder: (_, _, _) => fallback,
                )
              : fallback,
        ),
      ),
    );
  }
}

class _SkillSocialRow extends AppView<SkillStoreController> {
  const _SkillSocialRow({required this.skill});

  final MarketplaceSkill skill;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppReactiveBuilder(() {
      final liking = controller.isLiking(skill);
      return Row(
        children: [
          Semantics(
            button: true,
            enabled: !liking,
            label: skill.likedByMe
                ? 'skill_store.unlike_semantics'.trParams({
                    'title': skill.title,
                    'count': '${skill.likeCount}',
                  })
                : 'skill_store.like_semantics'.trParams({
                    'title': skill.title,
                    'count': '${skill.likeCount}',
                  }),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 44, minWidth: 52),
              child: InkWell(
                borderRadius: BorderRadius.circular(99),
                onTap: liking ? null : () => _toggleLike(),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      Icon(
                        skill.likedByMe
                            ? Icons.favorite_rounded
                            : Icons.favorite_border_rounded,
                        color: skill.likedByMe
                            ? Colors.pinkAccent
                            : glass.foregroundSecondary,
                        size: 20,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        '${skill.likeCount}',
                        style: TextStyle(
                          color: glass.foregroundSecondary,
                          fontWeight: FontWeight.w700,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Row(
              children: [
                Icon(
                  Icons.smart_toy_outlined,
                  color: glass.foregroundSecondary,
                  size: 18,
                ),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    'skill_store.active_agents'.trParams({
                      'count': '${skill.activeInstallCount}',
                    }),
                    maxLines: 2,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Future<void> _toggleLike() async {
    try {
      await controller.toggleLike(skill);
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_store.like_failed'.tr,
        message: exception.toString().replaceFirst('Bad state: ', ''),
        icon: Icons.error_outline_rounded,
      );
    }
  }
}

class _InstallationActions extends AppView<SkillStoreController> {
  const _InstallationActions({required this.skill, required this.onInstall});

  final MarketplaceSkill skill;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return AppReactiveBuilder(() {
      final installation = controller.installationFor(skill);
      final installing = controller.isInstalling(skill);
      final changing = controller.isChangingInstallation(skill);
      if (installation == null || installation.isUninstalled) {
        final unavailableReason = _installUnavailableReason(skill);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AppGlassButton(
              label: installing
                  ? 'skill_store.installing'.tr
                  : skill.permissions.isEmpty
                  ? 'skill_store.direct_install'.tr
                  : 'skill_store.confirm_permissions_install'.tr,
              icon: Icons.download_rounded,
              fullWidth: true,
              onPressed: installing || changing || unavailableReason != null
                  ? null
                  : onInstall,
            ),
            if (unavailableReason != null) ...[
              const SizedBox(height: 7),
              Text(
                unavailableReason,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: MaasoGlassTheme.of(context).foregroundSecondary,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ],
        );
      }
      return Row(
        children: [
          Expanded(
            child: AppGlassButton(
              label: changing
                  ? 'skill_store.updating'.tr
                  : installation.isActive
                  ? 'skill_store.disable'.tr
                  : 'skill_store.reenable'.tr,
              icon: installation.isActive
                  ? Icons.pause_circle_outline_rounded
                  : Icons.play_circle_outline_rounded,
              primary: !installation.isActive,
              onPressed: changing
                  ? null
                  : () => _change(
                      installation.isActive
                          ? SkillInstallationStatus.disabled
                          : SkillInstallationStatus.active,
                    ),
            ),
          ),
          const SizedBox(width: 8),
          AppGlassIconButton(
            icon: Icons.delete_outline_rounded,
            tooltip: 'skill_store.uninstall_tooltip'.tr,
            onPressed: changing ? null : () => _confirmUninstall(context),
          ),
        ],
      );
    });
  }

  Future<void> _confirmUninstall(BuildContext context) async {
    final confirmed = await showAppGlassSheet<bool>(
      context: context,
      builder: (sheetContext) {
        final glass = MaasoGlassTheme.of(sheetContext);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'skill_store.uninstall_title'.trParams({'title': skill.title}),
              style: TextStyle(
                color: glass.foregroundPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'skill_store.uninstall_message'.tr,
              style: TextStyle(color: glass.foregroundSecondary, height: 1.45),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: AppGlassButton(
                    label: 'common.cancel'.tr,
                    primary: false,
                    onPressed: () => Navigator.of(sheetContext).pop(false),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AppGlassButton(
                    label: 'skill_store.confirm_uninstall'.tr,
                    icon: Icons.delete_outline_rounded,
                    color: Theme.of(sheetContext).colorScheme.error,
                    onPressed: () => Navigator.of(sheetContext).pop(true),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (confirmed == true) {
      await _change(SkillInstallationStatus.uninstalled);
    }
  }

  Future<void> _change(SkillInstallationStatus status) async {
    try {
      await controller.setInstallationStatus(skill, status);
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_store.status_update_failed'.tr,
        message: exception.toString().replaceFirst('Bad state: ', ''),
        icon: Icons.error_outline_rounded,
      );
    }
  }
}

class _UploadSkillPanel extends StatefulWidget {
  const _UploadSkillPanel();

  @override
  State<_UploadSkillPanel> createState() => _UploadSkillPanelState();
}

class _UploadSkillPanelState extends State<_UploadSkillPanel> {
  final _versionController = TextEditingController(text: '1.0.0');

  @override
  void dispose() {
    _versionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = appServices.find<SkillStoreController>();
    final glass = MaasoGlassTheme.of(context);
    return AppReactiveBuilder(() {
      final package = controller.selectedPackage.value;
      final uploading = controller.isUploading.value;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.upload_file_rounded, color: glass.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'skill_store.upload_title'.tr,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              AppGlassIconButton(
                icon: Icons.close_rounded,
                tooltip: 'common.close'.tr,
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'skill_store.upload_note'.tr,
            style: TextStyle(
              color: glass.foregroundSecondary,
              fontSize: 12,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 12),
          AppFrostSegmentedControl<SkillVisibility>(
            selected: controller.uploadVisibility.value,
            onSelected: uploading
                ? null
                : (visibility) =>
                      controller.uploadVisibility.value = visibility,
            blur: false,
            segments: [
              AppFrostSegment(
                value: SkillVisibility.private,
                label: 'common.private'.tr,
              ),
              AppFrostSegment(
                value: SkillVisibility.public,
                label: 'common.public'.tr,
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _versionController,
            enabled: !uploading,
            style: TextStyle(color: glass.foregroundPrimary),
            decoration: InputDecoration(
              labelText: 'skill_store.version_label'.tr,
              hintText: 'skill_store.version_hint'.tr,
            ),
          ),
          const SizedBox(height: 10),
          AppGlassButton(
            label: package == null
                ? 'skill_store.select_package'.tr
                : 'skill_store.change_package'.tr,
            icon: Icons.attach_file_rounded,
            fullWidth: true,
            onPressed: uploading ? null : controller.choosePackage,
          ),
          if (package != null) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    package.path.split('/').last,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close_rounded),
                  color: glass.foregroundSecondary,
                  tooltip: 'common.remove'.tr,
                  onPressed: uploading ? null : controller.clearPackage,
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          AppGlassButton(
            label: uploading
                ? 'skill_store.uploading'.tr
                : 'skill_store.upload'.tr,
            icon: Icons.verified_outlined,
            fullWidth: true,
            onPressed: package == null || uploading
                ? null
                : () => _submit(controller),
          ),
        ],
      );
    });
  }

  Future<void> _submit(SkillStoreController controller) async {
    try {
      final result = await controller.uploadSelected(
        versionName: _versionController.text,
      );
      AppGlassNotice.show(
        title: result.safetyStatus == SkillSafetyStatus.passed
            ? 'skill_store.check_passed'.tr
            : 'skill_store.check_failed'.tr,
        message: result.safetyStatus == SkillSafetyStatus.passed
            ? (result.visibility == SkillVisibility.public
                  ? 'skill_store.public_published'.tr
                  : 'skill_store.private_saved'.tr)
            : 'skill_store.reupload_note'.tr,
        icon: result.safetyStatus == SkillSafetyStatus.passed
            ? Icons.check_circle_rounded
            : Icons.error_outline_rounded,
      );
    } catch (exception) {
      AppGlassNotice.show(
        title: 'skill_store.upload_failed'.tr,
        message: exception.toString().replaceFirst('Bad state: ', ''),
        icon: Icons.error_outline_rounded,
      );
    }
  }
}

class _MySkillCard extends StatelessWidget {
  const _MySkillCard({required this.skill});

  final MarketplaceSkill skill;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final rejected = skill.isRejected;
    final passed = skill.safetyStatus == SkillSafetyStatus.passed;
    final status = rejected
        ? 'skill_store.check_failed'.tr
        : passed
        ? 'skill_store.check_passed'.tr
        : 'skill_store.checking'.tr;
    final color = rejected
        ? Theme.of(context).colorScheme.error
        : passed
        ? glass.accentText
        : glass.foregroundSecondary;
    return AppSecondaryCard(
      key: ValueKey('published-skill-${skill.skillVersionId}'),
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      onTap: skill.canInstall
          ? () => _SkillStoreCard(skill: skill)._openDetails(context)
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SkillCover(skill: skill),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skill.title,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'skill_store.visibility_status'.trParams({
                    'visibility': skill.visibility == SkillVisibility.public
                        ? 'common.public'.tr
                        : 'common.private'.tr,
                    'status': status,
                  }),
                  style: TextStyle(color: color, fontSize: 13, height: 1.5),
                ),
                Text(
                  'v${skill.versionName}',
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                if (skill.summary.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    skill.summary,
                    style: TextStyle(
                      color: glass.foregroundSecondary,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ],
                if (skill.canInstall) ...[
                  const SizedBox(height: 8),
                  AppGlassButton(
                    label: 'skill_store.view_details'.tr,
                    primary: false,
                    onPressed: () =>
                        _SkillStoreCard(skill: skill)._openDetails(context),
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

class _EvolutionDraftCard extends StatelessWidget {
  const _EvolutionDraftCard({required this.draft});

  final SkillEvolutionDraft draft;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final passed = draft.hasFreshPassingTest;
    return AppSecondaryCard(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      tone: draft.isPublished || passed
          ? AppSecondaryCardTone.selected
          : AppSecondaryCardTone.normal,
      onTap: () => appNavigation.pushPage<void>(
        () => SkillEvolutionEditorPage(draftId: draft.id),
      ),
      semanticLabel: 'skill_store.open_draft_semantics'.trParams({
        'title': draft.title,
      }),
      child: Row(
        children: [
          Icon(
            draft.isPublished
                ? Icons.verified_rounded
                : passed
                ? Icons.fact_check_rounded
                : Icons.fork_right_rounded,
            color: passed || draft.isPublished
                ? ColorConstant.primaryColor
                : glass.foregroundSecondary,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  draft.title,
                  style: TextStyle(
                    color: glass.foregroundPrimary,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  draft.isPublished
                      ? 'skill_store.published_version'.trParams({
                          'version': draft.versionName,
                        })
                      : passed
                      ? 'skill_store.test_passed_publish'.tr
                      : 'skill_store.draft_summary'.trParams({
                          'revision': '${draft.revision}',
                          'count': '${draft.cases.length}',
                        }),
                  style: TextStyle(
                    color: glass.foregroundSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded),
        ],
      ),
    );
  }
}

Future<Set<String>?> _requestPermissions(
  BuildContext context,
  MarketplaceSkill skill,
) async {
  final requested = skill.permissions.toList()..sort();
  if (requested.isEmpty) return <String>{};
  final selected = <String>{};
  return showAppGlassSheet<Set<String>>(
    context: context,
    builder: (sheetContext) => _ScrollableSkillSheet(
      child: StatefulBuilder(
        builder: (context, setSheetState) {
          final allAccepted = selected.length == requested.length;
          final colors = Theme.of(context).colorScheme;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: SizedBox(
                  width: 36,
                  child: Divider(color: colors.onSurfaceVariant),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'skill_store.permission_title'.trParams({
                        'title': skill.title,
                      }),
                      style: TextStyle(
                        color: colors.onSurface,
                        fontWeight: FontWeight.w600,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  AppGlassIconButton(
                    icon: Icons.close_rounded,
                    tooltip: 'common.close'.tr,
                    onPressed: () => Navigator.of(sheetContext).pop(),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                'skill_store.permission_note'.tr,
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 12),
              for (final permission in requested)
                CheckboxListTile(
                  value: selected.contains(permission),
                  contentPadding: EdgeInsets.zero,
                  activeColor: ColorConstant.primaryColor,
                  title: Text(
                    permission,
                    style: TextStyle(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                    ),
                  ),
                  onChanged: (checked) => setSheetState(() {
                    if (checked ?? false) {
                      selected.add(permission);
                    } else {
                      selected.remove(permission);
                    }
                  }),
                ),
              const SizedBox(height: 12),
              AppGlassButton(
                label: 'skill_store.install_progress'.trParams({
                  'selected': '${selected.length}',
                  'total': '${requested.length}',
                }),
                fullWidth: true,
                icon: Icons.verified_user_rounded,
                onPressed: allAccepted
                    ? () => Navigator.of(sheetContext).pop(Set.of(selected))
                    : null,
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _ScrollableSkillSheet extends StatelessWidget {
  const _ScrollableSkillSheet({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final keyboard = media.viewInsets.bottom;
    final availableHeight =
        media.size.height -
        media.padding.top -
        media.padding.bottom -
        keyboard -
        48;
    return Padding(
      padding: EdgeInsets.only(bottom: keyboard),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: availableHeight > 0 ? availableHeight : 0,
        ),
        child: SingleChildScrollView(child: child),
      ),
    );
  }
}

/// The unified asset detail uses the same permission sheet and native installer.
/// Its authority is rechecked after consent, before the installation begins.
Future<void> installStoreAssetSkill(
  BuildContext context,
  MarketplaceSkill skill, {
  required bool Function() canContinue,
}) async {
  if (!canContinue() || !skill.canInstall) return;
  final accepted = await _requestPermissions(context, skill);
  if (accepted == null || !context.mounted || !canContinue()) return;
  await appServices.find<SkillStoreController>().install(skill, accepted);
}

Future<void> _installSkillFromCard(
  BuildContext context,
  SkillStoreController controller,
  MarketplaceSkill skill,
) async {
  debugPrint(
    '[SkillInstall][UI] tapped '
    'version=${skill.skillVersionId} canInstall=${skill.canInstall} '
    'permissions=${skill.permissions.length}',
  );
  final accepted = await _requestPermissions(context, skill);
  if (accepted == null) {
    debugPrint(
      '[SkillInstall][UI] permission confirmation cancelled '
      'version=${skill.skillVersionId}',
    );
    return;
  }
  debugPrint(
    '[SkillInstall][UI] consent ready '
    'version=${skill.skillVersionId} mode='
    '${skill.permissions.isEmpty ? 'direct' : 'confirmed'}',
  );
  try {
    await controller.install(skill, accepted);
    debugPrint('[SkillInstall][UI] success version=${skill.skillVersionId}');
    AppGlassNotice.show(
      title: 'skill_store.installed_title'.tr,
      message: 'skill_store.installed_message'.trParams({'title': skill.title}),
      icon: Icons.check_circle_rounded,
    );
  } catch (exception) {
    debugPrint(
      '[SkillInstall][UI] failed '
      'version=${skill.skillVersionId} error=$exception',
    );
    AppGlassNotice.show(
      title: 'skill_store.install_failed'.tr,
      message: exception.toString().replaceFirst('Bad state: ', ''),
      icon: Icons.error_outline_rounded,
    );
  }
}

String? _installUnavailableReason(MarketplaceSkill skill) {
  if (skill.skillVersionId <= 0) {
    return 'skill_store.missing_version'.tr;
  }
  if (skill.safetyStatus == SkillSafetyStatus.rejected) {
    return 'skill_store.unsafe_version'.tr;
  }
  if (skill.safetyStatus != null &&
      skill.safetyStatus != SkillSafetyStatus.passed) {
    return 'skill_store.check_pending'.tr;
  }
  return null;
}

class _InlineEmpty extends StatelessWidget {
  const _InlineEmpty({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Text(
        message,
        style: TextStyle(
          color: glass.foregroundSecondary,
          fontSize: 13,
          height: 1.5,
        ),
      ),
    );
  }
}

class _StoreMessage extends StatelessWidget {
  const _StoreMessage({
    required this.icon,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String actionLabel;
  final Future<void> Function() onAction;

  @override
  Widget build(BuildContext context) {
    return AppSecondaryStateView(
      kind: icon == Icons.cloud_off_rounded
          ? AppSecondaryStateKind.offline
          : AppSecondaryStateKind.empty,
      icon: icon,
      title: title,
      message: message,
      actionLabel: actionLabel,
      onAction: () => onAction(),
    );
  }
}
