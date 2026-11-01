import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';

class StartupRouteService extends AppService {
  Future<String> resolveInitialRoute() async {
    if (appServices.isRegistered<AccountSessionLifecycleService>()) {
      final lifecycle = appServices.find<AccountSessionLifecycleService>();
      final mounted = await lifecycle.restoreAndMount();
      if (mounted) return IdentityRoutePolicy.initialRoute();
      return lifecycle.requiresStandbyRoute
          ? AppRouteCatalog.accountStandby
          : AppRouteCatalog.login;
    }
    if (!appServices.isRegistered<AuthSessionService>()) {
      return AppRouteCatalog.login;
    }
    final authenticated = await appServices
        .find<AuthSessionService>()
        .restoreOrRefresh();
    return authenticated
        ? IdentityRoutePolicy.initialRoute()
        : AppRouteCatalog.login;
  }
}
