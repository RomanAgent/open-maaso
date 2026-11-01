import 'package:flutter/material.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';

import '../application/identity_service.dart';
import '../application/identity_setup_controller.dart';
import 'identity_setup_page.dart';
import '../application/companion_profile_service.dart';
import '../application/companion_setup_controller.dart';

/// Controller ownership follows the route, while identity follows the account.
class IdentityRoutePage extends StatefulWidget {
  const IdentityRoutePage({super.key});

  @override
  State<IdentityRoutePage> createState() => _IdentityRoutePageState();
}

class _IdentityRoutePageState extends State<IdentityRoutePage> {
  late final CompanionSetupController? _companion = _createCompanion();
  CompanionSetupController? _createCompanion() {
    final service = appServices.maybeFind<CompanionProfileService>();
    final avatars = appServices.maybeFind<AvatarConfigService>();
    if (service == null || avatars == null) return null;
    return CompanionSetupController(
      service: service,
      avatars: avatars,
      catalog: appServices.maybeFind<AvatarModelCatalogService>(),
    );
  }

  late final _controller = IdentitySetupController(
    service: appServices.find<IdentityService>(),
    onlyMissing: true,
    legacyAgentName: () =>
        appServices.maybeFind<AgentCoreController>()?.profile.value?.nickname ??
        '',
  );

  @override
  void dispose() {
    _controller.onClose();
    _companion?.onClose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IdentitySetupPage(
    controller: _controller,
    companion: _companion,
    route: AppRouteCatalog.onboarding,
    autoComplete: true,
    onChangeAccount: () => appNavigation.go(AppRouteCatalog.login),
    onCompleted: (_) async {
      if (!mounted || !_controller.service.onboardingCompleted) return;
      if (_companion != null && !_companion.completed) return;
      appNavigation.go(AppRouteCatalog.home);
    },
    onContinueLocally: () {
      if (_controller.service.continueLocally()) {
        appNavigation.go(AppRouteCatalog.home);
      }
    },
  );
}
