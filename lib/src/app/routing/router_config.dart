import 'package:maaso/src/features/agent_space/presentation/agent_space_page.dart';
import 'package:maaso/src/features/identity/presentation/profile_route_page.dart';
import 'package:maaso/src/features/economy/presentation/membership_page.dart';
import 'package:maaso/src/offline/local_edition_policy.dart';

import 'package:maaso/src/features/privacy/presentation/privacy_page.dart';
import 'package:maaso/src/features/account_deletion/presentation/account_deletion_page.dart';
import 'package:maaso/src/features/account_deletion/application/account_deletion_host.dart';
import 'package:maaso/src/features/people_safety/presentation/people_safety_page.dart';

import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'package:maaso/src/features/identity/presentation/identity_route_page.dart';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:maaso/src/core/capability/app_route_capability_policy.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/features/settings/presentation/agent_settings_page.dart';
import 'package:maaso/src/features/memory/presentation/memory_ledger_page.dart';
import 'package:maaso/src/features/settings/application/agent_settings_route_dependencies.dart';
import 'package:maaso/src/features/applets/presentation/ble_projector/ble_projector_applet.dart';
import 'package:maaso/src/features/dashboard/application/dashboard_route_dependencies.dart';
import 'package:maaso/src/features/dashboard/presentation/dashboard_page.dart';
import 'package:maaso/src/features/home/application/home_route_dependencies.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';
import 'package:maaso/src/features/home/presentation/home_page.dart';
import 'package:maaso/src/features/auth/application/login_route_dependencies.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';
import 'package:maaso/src/features/auth/presentation/account_standby_page.dart';
import 'package:maaso/src/features/auth/presentation/login_page.dart';
import 'package:maaso/src/features/relationship/application/relationship_hub_route_dependencies.dart';
import 'package:maaso/src/features/relationship/presentation/relationship_hub_page.dart';
import 'package:maaso/src/features/store/application/store_hub_route_dependencies.dart';
import 'package:maaso/src/features/store/presentation/store_hub_page.dart';
import 'package:maaso/src/features/widgets_hub/application/widgets_hub_route_dependencies.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart';
import 'package:maaso/src/features/widgets_hub/application/applet_hub_route_intent.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_route_dependencies.dart';
import 'package:maaso/src/features/chat/presentation/u2a_chat_page.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';

export 'package:maaso/src/app/routing/app_route_catalog.dart'
    show AppDestination;

class AppRoutes {
  /// Resolved during bootstrap before the router is created.
  static String initial = AppRouteCatalog.home;

  static const login = AppRouteCatalog.login;
  static const accountStandby = AppRouteCatalog.accountStandby;
  static const onboarding = AppRouteCatalog.onboarding;
  static const identity = AppRouteCatalog.identity;
  static const profile = AppRouteCatalog.profile;
  static const membership = AppRouteCatalog.membership;
  static const privacy = AppRouteCatalog.privacy;
  static const accountDeletion = AppRouteCatalog.accountDeletion;
  static const peopleSafety = AppRouteCatalog.peopleSafety;
  static const home = AppRouteCatalog.home;
  static const u2aChat = AppRouteCatalog.u2aChat;
  static const moments = AppRouteCatalog.moments;
  static const memoryWall = AppRouteCatalog.memoryWall;
  static const memoryLedger = AppRouteCatalog.memoryLedger;
  static const settings = AppRouteCatalog.settings;
  static const advancedFeatures = AppRouteCatalog.advancedFeatures;
  static const skills = AppRouteCatalog.skills;
  static const skillStore = AppRouteCatalog.skillStore;
  static const dashboard = AppRouteCatalog.dashboard;
  static const gameFeed = AppRouteCatalog.gameFeed;
  static const widgetsHub = AppRouteCatalog.widgetsHub;
  static const myApplets = AppRouteCatalog.myApplets;
  static const avatars = AppRouteCatalog.avatars;
  static const agentSpace = AppRouteCatalog.agentSpace;
  static const bleProjector = AppRouteCatalog.bleProjector;

  static const List<AppDestination> destinations = AppRouteCatalog.destinations;

  static String? resolveCommand(String input) =>
      AppRouteCatalog.resolveCommand(input);

  static List<String> get commandList => AppRouteCatalog.commandList;
}

const List<String> appRoutePaths = <String>[
  AppRoutes.login,
  AppRoutes.accountStandby,
  AppRoutes.onboarding,
  AppRoutes.profile,
  AppRoutes.membership,
  AppRoutes.privacy,
  AppRoutes.accountDeletion,
  AppRoutes.peopleSafety,
  AppRoutes.home,
  AppRoutes.u2aChat,
  AppRoutes.moments,
  AppRoutes.memoryWall,
  AppRoutes.memoryLedger,
  AppRoutes.settings,
  AppRoutes.advancedFeatures,
  AppRoutes.skills,
  AppRoutes.skillStore,
  AppRoutes.dashboard,
  AppRoutes.gameFeed,
  AppRoutes.widgetsHub,
  AppRoutes.myApplets,
  AppRoutes.avatars,
  AppRoutes.agentSpace,
  AppRoutes.bleProjector,
];

GoRouter createAppRouter({
  String? initialLocation,
  @visibleForTesting List<RouteBase>? routesOverride,
  @visibleForTesting AppPlatformCapabilities? platformCapabilities,
  @visibleForTesting AppCapabilitySnapshotService? capabilitySnapshots,
}) {
  ensureAccountDeletionHost();
  final accountLifecycle = appServices
      .maybeFind<AccountSessionLifecycleService>();
  final resolvedCapabilitySnapshots =
      capabilitySnapshots ??
      appServices.maybeFind<AppCapabilitySnapshotService>();
  final resolvedPlatformCapabilities =
      platformCapabilities ?? AppPlatformCapabilities.current();
  final refreshSources = <Listenable>[
    ?accountLifecycle,
    ?resolvedCapabilitySnapshots,
  ];
  final router = GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: initialLocation ?? AppRoutes.initial,
    refreshListenable: switch (refreshSources) {
      [] => null,
      [final single] => single,
      _ => Listenable.merge(refreshSources),
    },
    redirect: (_, state) {
      if (kOpenMaasoLocalEdition && state.uri.path == AppRoutes.membership) {
        return AppRoutes.settings;
      }
      // Retired account editors return to personal information and are no
      // longer advertised or Agent-navigable destinations.
      if (state.uri.path == '/wallet' || state.uri.path == AppRoutes.identity) {
        return AppRoutes.profile;
      }
      final accountRedirect = accountSessionRedirectForPath(state.uri.path);
      if (accountRedirect != null) return accountRedirect;
      final identityRedirect = IdentityRoutePolicy.redirect(state.uri.path);
      if (identityRedirect != null) return identityRedirect;
      final legacyGameLocation = gameFeedLocationForLegacyEntry(state.uri);
      if (legacyGameLocation != null) return legacyGameLocation;
      // Old links and slash commands must not mount a second self-chat
      // controller on desktop, where Home already provides the conversation.
      if (state.uri.path == AppRoutes.u2aChat &&
          switch (resolvedPlatformCapabilities.platform) {
            AppHostPlatform.macos ||
            AppHostPlatform.windows ||
            AppHostPlatform.linux => true,
            _ => false,
          }) {
        return AppRoutes.home;
      }
      return platformCapabilityRedirectForPath(
        state.uri.path,
        resolvedPlatformCapabilities,
        snapshot: resolvedCapabilitySnapshots?.value,
      );
    },
    routes:
        routesOverride ??
        <RouteBase>[
          GoRoute(
            path: AppRoutes.login,
            pageBuilder: (context, state) {
              appNavigation.currentExtra = state.extra;
              return NoTransitionPage<void>(
                key: state.pageKey,
                child: RouteDependenciesScope(
                  dependencies: LoginRouteDependencies(),
                  child: const LoginPage(),
                ),
              );
            },
          ),
          _route(AppRoutes.accountStandby, (_) => const AccountStandbyPage()),
          _route(AppRoutes.privacy, (_) => const PrivacyPage()),
          _route(
            AppRoutes.accountDeletion,
            (_) => const AccountDeletionRoutePage(),
          ),
          _route(
            AppRoutes.peopleSafety,
            (_) => const PeopleSafetyPage(route: AppRouteCatalog.peopleSafety),
          ),
          _route(AppRoutes.onboarding, (_) => const IdentityRoutePage()),
          _route(
            AppRoutes.profile,
            (_) => const ProfileRoutePage(
              route: AppRouteCatalog.profile,
              membershipRoute: AppRouteCatalog.membership,
              localEdition: kOpenMaasoLocalEdition,
            ),
          ),
          _route(
            AppRoutes.membership,
            (_) => const MembershipPage(route: AppRouteCatalog.membership),
          ),
          GoRoute(
            path: AppRoutes.home,
            pageBuilder: (context, state) {
              appNavigation.currentExtra = state.extra;
              return NoTransitionPage<void>(
                key: state.pageKey,
                child: RouteDependenciesScope(
                  dependencies: HomeRouteDependencies(),
                  child: HomePage(
                    draftIntent: state.extra is HomeDraftIntent
                        ? state.extra as HomeDraftIntent
                        : null,
                  ),
                ),
              );
            },
          ),
          _route(
            AppRoutes.u2aChat,
            (_) => const U2aChatPage(),
            U2aChatRouteDependencies.new,
          ),
          _route(
            AppRoutes.moments,
            (_) => const RelationshipHubPage(
              initialSection: RelationshipHubSection.moments,
            ),
            RelationshipHubRouteDependencies.new,
          ),
          _route(
            AppRoutes.memoryWall,
            (state) => RelationshipHubPage(
              initialSection: relationshipSectionForLocation(state.uri),
            ),
            RelationshipHubRouteDependencies.new,
          ),
          _route(AppRoutes.memoryLedger, (_) => const MemoryLedgerScreen()),
          _route(
            AppRoutes.settings,
            (_) => const AgentSettingsPage(),
            AgentSettingsRouteDependencies.new,
          ),
          _route(
            AppRoutes.advancedFeatures,
            (_) => const AgentAdvancedFeaturesPage(),
            AgentSettingsRouteDependencies.new,
          ),
          _route(
            AppRoutes.skills,
            (_) => const StoreHubPage(initialSection: StoreHubSection.skills),
            StoreHubRouteDependencies.new,
          ),
          _route(
            AppRoutes.skillStore,
            (_) =>
                const StoreHubPage(initialSection: StoreHubSection.marketplace),
            StoreHubRouteDependencies.new,
          ),
          _route(
            AppRoutes.dashboard,
            (_) => const DashboardPage(),
            DashboardRouteDependencies.new,
          ),
          _route(
            AppRoutes.gameFeed,
            (_) => const GameFeedPage(),
            WidgetsHubRouteDependencies.new,
          ),
          _route(
            AppRoutes.widgetsHub,
            (_) => const WidgetsHubPage(),
            WidgetsHubRouteDependencies.new,
          ),
          _route(
            AppRoutes.myApplets,
            (_) => const MyAppletsPage(),
            WidgetsHubRouteDependencies.new,
          ),
          _route(
            AppRoutes.avatars,
            (_) => const StoreHubPage(initialSection: StoreHubSection.models),
            StoreHubRouteDependencies.new,
          ),
          _avatarSceneRoute(
            AppRoutes.agentSpace,
            (_) => const AgentSpacePage(),
          ),
          GoRoute(path: '/world', redirect: (_, _) => AppRoutes.agentSpace),
          _route(AppRoutes.bleProjector, (_) => const BleProjectorApplet()),
        ],
    errorBuilder: (context, state) {
      if (state.error != null) {
        debugPrint('[Router] navigation failed: ${state.error}');
      }
      return Scaffold(body: Center(child: Text('routing.not_found'.tr)));
    },
  );
  appNavigation.configure(router);
  return router;
}

@visibleForTesting
String? accountSessionRedirectForPath(String path, {bool? loginPending}) {
  if (path == AppRoutes.privacy || path == AppRoutes.accountDeletion) {
    return null;
  }
  // Authentication can briefly publish its candidate before the companion
  // graph is mounted. Keep the login canvas in place while that operation is
  // active; the explicit success path reveals Home under the doorway cover.
  if (path == AppRoutes.login &&
      (loginPending ??
          appServices.maybeFind<LoginController>()?.busy == true)) {
    return null;
  }
  final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
  if (lifecycle == null) return null;
  if (lifecycle.isMounted) {
    return path == AppRoutes.accountStandby ? AppRoutes.home : null;
  }
  if (lifecycle.requiresStandbyRoute) {
    return path == AppRoutes.accountStandby ? null : AppRoutes.accountStandby;
  }
  return path == AppRoutes.login ? null : AppRoutes.login;
}

@visibleForTesting
String? platformCapabilityRedirectForPath(
  String path,
  AppPlatformCapabilities capabilities, {
  AppCapabilitySnapshot? snapshot,
}) {
  final decision = routeCapabilityDecisionForLocation(
    path,
    snapshot: snapshot,
    platformCapabilities: capabilities,
  );
  if (decision == null || decision.isAllowed) return null;
  return decision.unavailableRedirect;
}

/// Existing relationship deep links keep Memories as their default. The
/// personality configuration entry can request its bounded Profile section.
RelationshipHubSection relationshipSectionForLocation(Uri location) {
  final values = location.queryParametersAll['section'];
  if (values == null || values.length != 1) {
    return RelationshipHubSection.memories;
  }
  return switch (values.single) {
    'profile' => RelationshipHubSection.profile,
    'moments' => RelationshipHubSection.moments,
    'memories' => RelationshipHubSection.memories,
    _ => RelationshipHubSection.memories,
  };
}

GoRouter get maasoRouter => appNavigation.isConfigured
    ? appNavigation.router
    : createAppRouter(initialLocation: AppRoutes.initial);

GoRoute _avatarSceneRoute(
  String path,
  Widget Function(GoRouterState state) page, [
  RouteDependencies Function()? dependencies,
]) {
  return GoRoute(
    path: path,
    pageBuilder: (context, state) {
      appNavigation.currentExtra = state.extra;
      // Mobile Unity stays behind the Flutter navigator. Sliding a transparent
      // scene overlay exposes the previous route through its body until the
      // transition ends. Switch the whole overlay together in both directions.
      return NoTransitionPage<void>(
        key: state.pageKey,
        child: dependencies == null
            ? page(state)
            : RouteDependenciesScope(
                dependencies: dependencies(),
                child: page(state),
              ),
      );
    },
  );
}

GoRoute _route(
  String path,
  Widget Function(GoRouterState state) page, [
  RouteDependencies Function()? dependencies,
]) {
  return GoRoute(
    path: path,
    builder: (context, state) {
      appNavigation.currentExtra = state.extra;
      final child = page(state);
      if (dependencies == null) return child;
      return RouteDependenciesScope(dependencies: dependencies(), child: child);
    },
  );
}

/// Accept older Hub game links only through the typed contract.
/// Validation precedes normalization so duplicate or unknown query arguments
/// cannot become a valid opaque open authorization through a redirect.
String? gameFeedLocationForLegacyEntry(Uri location) {
  if (location.path != AppRoutes.widgetsHub) {
    return null;
  }
  final intent = AppletHubRouteIntent.tryParse(location.toString());
  if (intent?.category.name != 'game') return null;
  return intent!.location;
}
