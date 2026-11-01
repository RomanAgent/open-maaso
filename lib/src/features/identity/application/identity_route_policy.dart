import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'identity_service.dart';
import 'companion_profile_service.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';

/// Shared by boot, login, and every deep link; no network work in redirects.
abstract final class IdentityRoutePolicy {
  static String initialRoute() {
    final privacy = appServices.maybeFind<PrivacyService>();
    if (privacy?.hasAccount == true && !privacy!.canEnterOnlineFeatures) {
      return AppRouteCatalog.privacy;
    }
    final identity = appServices.maybeFind<IdentityService>();
    return identity == null ||
            (identity.onboardingCompleted && _companionReady) ||
            identity.localCompanionEnabled
        ? AppRouteCatalog.home
        : AppRouteCatalog.onboarding;
  }

  static String? redirect(String path) {
    if (path == AppRouteCatalog.privacy ||
        path == AppRouteCatalog.accountDeletion ||
        path == AppRouteCatalog.peopleSafety) {
      return null;
    }
    final privacy = appServices.maybeFind<PrivacyService>();
    if (privacy?.hasAccount == true &&
        !privacy!.canEnterOnlineFeatures &&
        !_privateRoutes.contains(path) &&
        path != AppRouteCatalog.login &&
        path != AppRouteCatalog.accountStandby &&
        !_accountReadRoutes.contains(path)) {
      return AppRouteCatalog.privacy;
    }
    final identity = appServices.maybeFind<IdentityService>();
    if (identity == null ||
        path == AppRouteCatalog.login ||
        path == AppRouteCatalog.accountStandby ||
        _accountReadRoutes.contains(path)) {
      return null;
    }
    if (identity.onboardingCompleted && _companionReady) return null;
    if (path == AppRouteCatalog.onboarding) return null;
    if (identity.localCompanionEnabled && _privateRoutes.contains(path)) {
      return null;
    }
    return AppRouteCatalog.onboarding;
  }

  // A mounted but unread profile must complete the shared setup flow before
  // admitting a fresh device. Redirects never create defaults or call HTTP.
  static bool get _companionReady =>
      appServices.maybeFind<CompanionProfileService>()?.onboardingCompleted ??
      true;

  // Existing account and purchase details remain reachable while setup is
  // incomplete or privacy choices limit online Agent features. Their own
  // controllers still enforce authentication and mutation capabilities.
  static const _accountReadRoutes = {
    AppRouteCatalog.profile,
    AppRouteCatalog.membership,
  };

  static const _privateRoutes = {
    AppRouteCatalog.home,
    AppRouteCatalog.agentSpace,
    AppRouteCatalog.u2aChat,
    AppRouteCatalog.settings,
    AppRouteCatalog.advancedFeatures,
    AppRouteCatalog.memoryLedger,
    AppRouteCatalog.memoryWall,
  };
}
