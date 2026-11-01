import 'package:maaso/src/features/applets/presentation/applet_version_history_sheet.dart';
import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_category_taxonomy.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_my_page_adapter.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_controller.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:maaso/src/features/project_build/presentation/project_build_saved_management.dart';

class AppletMyPageAdapterScope extends StatefulWidget {
  const AppletMyPageAdapterScope({
    super.key,
    required this.controller,
    required this.child,
  });
  final WidgetsHubController controller;
  final Widget child;

  @override
  State<AppletMyPageAdapterScope> createState() =>
      _AppletMyPageAdapterScopeState();
}

class _AppletMyPageAdapterScopeState extends State<AppletMyPageAdapterScope>
    implements AppletMyPageTarget {
  AppletMyPageAdapter? _adapter;
  PageAgentAdapterRegistration<AppletMyPageAdapter>? _registration;
  late final String _scopeKey;

  @override
  void initState() {
    super.initState();
    _scopeKey = AppletLocalOwnership.currentScopeKey();
    final ui = appServices.maybeFind<AgentUiControlService>();
    if (ui != null) {
      final adapter = AppletMyPageAdapter(
        coordinator: ui.coordinator,
        target: this,
      );
      _adapter = adapter;
      _registration = ui.adapters.register(adapter);
    }
  }

  @override
  bool get isReady =>
      mounted &&
      _scopeKey == AppletLocalOwnership.currentScopeKey() &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  @override
  List<AgentWidget> get visibleLocalApplets => !isReady
      ? const []
      : widget.controller.widgets
            .where(
              (item) =>
                  item.agentId == 'self' &&
                  isAppletPresentationDiscoverable(item, scopeKey: _scopeKey) &&
                  AppletCategoryTaxonomy.forWidget(item) != AppletCategory.game,
            )
            .toList(growable: false);

  @override
  Future<void> openApplet(
    AgentWidget item, {
    required bool Function() canContinue,
  }) => openAgentWidget(item, canContinue: canContinue);

  @override
  Future<void> openVersionHistory(
    AgentWidget item, {
    required bool Function() canContinue,
  }) async {
    if (item.spec.containsKey('bundleReference')) {
      await showProjectBuildSavedManagement(
        context,
        item,
        canContinue: canContinue,
      );
    } else {
      await showAppletVersionHistory(context, item, canContinue: canContinue);
    }
  }

  @override
  Future<bool> prepareAppletEdit(
    AgentWidget item, {
    required bool Function() canContinue,
  }) => beginAppletEditing(item, canContinue: canContinue);

  @override
  void dispose() {
    _adapter?.detach();
    _registration?.unregister();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
