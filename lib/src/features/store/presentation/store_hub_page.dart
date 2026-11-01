import 'package:flutter/material.dart';
import 'package:maaso/src/features/store/data/asset_store_service.dart';
import 'package:maaso/src/features/store/presentation/store_asset_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/app_frost_segmented_control.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/store/application/store_page_adapter.dart';

import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/avatars/presentation/avatars_page.dart';
import 'package:maaso/src/features/skills/presentation/skill_store_page.dart';
import 'package:maaso/src/features/skills/presentation/skills_page.dart';

enum StoreHubSection { marketplace, skills, models }

typedef StoreHubSectionBuilder = Widget Function(BuildContext context);

/// The public store and the legacy /skills workshop share asset sections.
/// Only the selected section is mounted; asset execution remains type-specific.
class StoreHubPage extends StatefulWidget {
  const StoreHubPage({
    super.key,
    this.initialSection = StoreHubSection.models,
    @visibleForTesting this.sectionBuilders,
  });

  final StoreHubSection initialSection;

  @visibleForTesting
  final Map<StoreHubSection, StoreHubSectionBuilder>? sectionBuilders;

  @override
  State<StoreHubPage> createState() => _StoreHubPageState();
}

class _StoreHubPageState extends State<StoreHubPage>
    implements StorePageTarget, StoreCatalogTarget {
  final _catalogKey = GlobalKey<StoreAssetCatalogState>();
  @override
  bool get catalogReady => _catalogKey.currentState?.ready == true;
  @override
  List<Map<String, Object?>> get visibleAssets =>
      _catalogKey.currentState?.visibleAssets ?? const [];
  @override
  Future<void> searchAssets(
    String query,
    String sort,
    bool Function() authority,
  ) async => _catalogKey.currentState?.search(query, sort, authority);
  @override
  Future<void> openAsset(
    String id,
    String version,
    bool Function() authority,
  ) async => _catalogKey.currentState?.open(id, version, authority: authority);
  late StoreHubSection _section = widget.initialSection;
  StorePageAdapter? _adapter;
  PageAgentAdapterRegistration<StorePageAdapter>? _registration;
  AccountStorageScopeMount? _mount;
  bool get _workshop => widget.initialSection == StoreHubSection.skills;

  @override
  bool get isWorkshop => _workshop;
  @override
  bool get isReady =>
      mounted &&
      (ModalRoute.of(context)?.isCurrent ?? true) &&
      identical(
        _mount,
        appServices.maybeFind<AccountStorageScopeService>()?.activeMount,
      );
  @override
  String get selectedSection =>
      _section == StoreHubSection.marketplace ? 'skills' : _section.name;
  @override
  void selectSection(String section) {
    if (!isReady || !StorePageAdapter.sections.contains(section)) return;
    setState(
      () => _section = section == 'skills'
          ? (_workshop ? StoreHubSection.skills : StoreHubSection.marketplace)
          : StoreHubSection.values.byName(section),
    );
  }

  @override
  void initState() {
    super.initState();
    _mount = appServices.maybeFind<AccountStorageScopeService>()?.activeMount;
    final ui = appServices.maybeFind<AgentUiControlService>();
    if (ui != null) {
      final adapter = StorePageAdapter(
        route: _workshop
            ? AppRouteCatalog.skills
            : widget.initialSection == StoreHubSection.models
            ? AppRouteCatalog.avatars
            : AppRouteCatalog.skillStore,
        coordinator: ui.coordinator,
        target: this,
      );
      _adapter = adapter;
      _registration = ui.adapters.register(adapter);
    }
  }

  @override
  void dispose() {
    _adapter?.detach();
    _registration?.unregister();
    super.dispose();
  }

  List<StoreHubSection> get _sections => [
    StoreHubSection.models,
    _workshop ? StoreHubSection.skills : StoreHubSection.marketplace,
  ];

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final inset = MediaQuery.sizeOf(context).width < 360 ? 16.0 : 20.0;
    final navigation = Padding(
      padding: EdgeInsets.fromLTRB(
        _workshop ? 16 : inset,
        0,
        _workshop ? 16 : inset,
        12,
      ),
      child: AppFrostSegmentedControl<StoreHubSection>(
        selected: _section,
        blur: true,
        onSelected: (next) {
          if (next != _section) setState(() => _section = next);
        },
        segments: [
          for (final section in _sections)
            AppFrostSegment(
              value: section,
              label: switch (section) {
                StoreHubSection.marketplace => 'store_hub.skills'.tr,
                StoreHubSection.skills => 'skills.my_skills'.tr,
                StoreHubSection.models =>
                  (_workshop ? 'store_hub.my_models' : 'store_hub.models').tr,
              },
              key: ValueKey('store-hub-${section.name}'),
              icon: _workshop
                  ? null
                  : section == StoreHubSection.models
                  ? Icons.person_outline_rounded
                  : Icons.auto_awesome_outlined,
            ),
        ],
      ),
    );
    final headerSections = AppFrostSectionHeader(
      header: _workshop
          ? AppSecondaryHeader(
              title: 'store_hub.workshop'.tr,
              onBack: () =>
                  appNavigation.pop(fallbackRoute: AppRouteCatalog.home),
            )
          : const _StoreNavigationBar(),
      navigation: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_workshop)
            Padding(
              padding: EdgeInsets.fromLTRB(inset, 12, inset, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'store_hub.marketplace'.tr,
                    key: const ValueKey('store-frost-title'),
                    style: TextStyle(
                      fontSize: 28,
                      height: 36 / 28,
                      fontWeight: FontWeight.w600,
                      color: glass.foregroundPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'store_hub.page_subtitle'.tr,
                    style: TextStyle(
                      fontSize: 13,
                      height: 20 / 13,
                      color: glass.foregroundSecondary,
                    ),
                  ),
                ],
              ),
            ),
          navigation,
        ],
      ),
    );
    final media = MediaQuery.of(context);
    final availableHeight =
        (media.size.height - media.viewInsets.bottom - media.padding.vertical)
            .clamp(0.0, double.infinity);
    final header = Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: !_workshop && media.size.height > 0
            ? ConstrainedBox(
                constraints: BoxConstraints(maxHeight: availableHeight * .6),
                child: SingleChildScrollView(child: headerSections),
              )
            : headerSections,
      ),
    );
    return Scaffold(
      backgroundColor: AppSecondaryPalette.of(context).backgroundStart,
      body: KeyedSubtree(
        key: ValueKey<StoreHubSection>(_section),
        child: _buildSection(context, header),
      ),
    );
  }

  Widget _buildSection(BuildContext context, Widget header) {
    final override = widget.sectionBuilders?[_section];
    if (override != null) {
      return AppSecondaryScaffold(header: header, body: override(context));
    }
    if (!_workshop && AssetStoreService.available) {
      return StoreAssetCatalog(
        key: _catalogKey,
        type: switch (_section) {
          StoreHubSection.models => 'model',
          _ => 'skill',
        },
        header: header,
        canContinue: () =>
            mounted &&
            identical(
              _mount,
              appServices.maybeFind<AccountStorageScopeService>()?.activeMount,
            ),
        legacyBuilder: (_) => _buildLegacy(header),
      );
    }
    return _buildLegacy(header);
  }

  Widget _buildLegacy(Widget header) => switch (_section) {
    StoreHubSection.marketplace => SkillStorePage(header: header),
    StoreHubSection.skills => SkillsPage(header: header),
    StoreHubSection.models => AvatarsPage(header: header, ownedOnly: _workshop),
  };
}

class _StoreNavigationBar extends StatelessWidget {
  const _StoreNavigationBar();

  @override
  Widget build(BuildContext context) => Padding(
    key: const ValueKey('store-frost-header'),
    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
    child: Row(
      children: [
        AppGlassIconButton(
          icon: Icons.arrow_back_rounded,
          tooltip: 'common.back'.tr,
          size: 48,
          onPressed: () =>
              appNavigation.pop(fallbackRoute: AppRouteCatalog.home),
        ),
        Expanded(
          child: Text(
            'Maaso',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: MaasoGlassTheme.of(context).foregroundPrimary,
            ),
          ),
        ),
        AppGlassIconButton(
          key: const ValueKey('store-open-workshop'),
          icon: Icons.handyman_outlined,
          tooltip: 'store_hub.workshop'.tr,
          size: 48,
          onPressed: () => appNavigation.push<void>(AppRouteCatalog.skills),
        ),
      ],
    ),
  );
}
