import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/agent/application/capability/capability_registry.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test('AppNavigate refreshes discovery between generation-bound calls', () {
    final service = _snapshotService(AppHostPlatform.macos);
    final navigated = <String>[];
    final skill = AppNavigateSkill(
      registry: _navigationRegistry(navigated),
      capabilitySnapshots: service,
    );

    final advertised = _advertisedPageIds(skill);
    final listedBeforeRefresh = _listedPageIds(skill);
    expect(advertised, contains('advanced_features'));
    expect(listedBeforeRefresh, advertised);

    service.refresh(
      service.context.copyWith(hostPlatform: AppHostPlatform.web),
    );

    expect(_advertisedPageIds(skill), isNot(contains('advanced_features')));
    expect(_listedPageIds(skill), isNot(contains('advanced_features')));
    expect(_openPage(skill, 'advanced_features')['error'], 'unavailable_page');
    expect(navigated, isEmpty);

    service.refresh(
      service.context.copyWith(hostPlatform: AppHostPlatform.macos),
    );
    expect(_advertisedPageIds(skill), contains('advanced_features'));
    expect(_listedPageIds(skill), contains('advanced_features'));
    expect(_openPage(skill, 'advanced_features')['status'], 'ok');
    expect(navigated, <String>[AppRouteCatalog.advancedFeatures]);
    service.closeLifecycle();
  });

  test('AppNavigate fails closed when its skill capability is undeclared', () {
    final service = AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: 0,
      ),
    );
    final navigated = <String>[];
    final skill = AppNavigateSkill(
      registry: _navigationRegistry(navigated),
      capabilitySnapshots: service,
    );

    expect(_advertisedPageIds(skill), isEmpty);
    expect(_listedPageIds(skill), isEmpty);
    expect(_openPage(skill, 'settings')['error'], 'unavailable_page');
    expect(navigated, isEmpty);
    service.closeLifecycle();
  });

  test('AppNavigate hides and denies an unready route', () {
    final service = AppCapabilitySnapshotService(
      resolver: _AgentSpaceUnavailableResolver(),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: 0,
      ),
    );
    final navigated = <String>[];
    final skill = AppNavigateSkill(
      registry: _navigationRegistry(navigated),
      capabilitySnapshots: service,
    );

    expect(_advertisedPageIds(skill), isNot(contains('agent_space')));
    expect(_listedPageIds(skill), isNot(contains('agent_space')));

    final opened = _openPage(skill, 'agent_space');
    expect(opened['error'], 'unavailable_page');
    expect(opened['reasons'], contains('route_dependency_unready'));
    expect(navigated, isEmpty);
    service.closeLifecycle();
  });

  test('AppNavigation rechecks the current snapshot before push', () async {
    final service = appServices.put(_snapshotService(AppHostPlatform.web));
    final navigation = AppNavigation();

    expect(
      navigation.visibleDestinations().map((destination) => destination.id),
      isNot(contains('advanced_features')),
    );
    expect(navigation.canNavigateTo(AppRouteCatalog.advancedFeatures), isFalse);
    expect(navigation.canNavigateTo(AppRouteCatalog.settings), isTrue);

    // A denied push returns before consulting an unconfigured router.
    expect(
      await navigation.push<Object?>(AppRouteCatalog.advancedFeatures),
      isNull,
    );
    navigation.currentExtra = 'preserved';
    expect(
      () =>
          navigation.go(AppRouteCatalog.advancedFeatures, extra: 'blocked-go'),
      returnsNormally,
    );
    expect(navigation.currentExtra, 'preserved');
    expect(
      await navigation.replace<Object?>(
        AppRouteCatalog.advancedFeatures,
        extra: 'blocked-replace',
      ),
      isNull,
    );
    expect(navigation.currentExtra, 'preserved');
    service.closeLifecycle();
    expect(navigation.visibleDestinations(), isEmpty);
    expect(navigation.canNavigateTo(AppRouteCatalog.settings), isFalse);
  });

  test(
    'shared navigation projections and live capability run stay aligned',
    () {
      final service = appServices.put(_snapshotService(AppHostPlatform.macos));
      final navigated = <String>[];
      final destinations = availableNavigationDestinations();
      final capabilities = buildNavigationCapabilities(
        navigate: navigated.add,
        currentRoute: () => AppRouteCatalog.home,
      );
      final commands = availableNavigationCommandList();
      final manifests = navigationManifests();
      final destinationIds = destinations
          .map((destination) => destination.id)
          .toSet();

      expect(
        capabilities.map((capability) => capability.id.substring(4)).toSet(),
        destinationIds,
      );
      expect(
        commands.map((command) => command.substring(1)).toSet(),
        destinationIds,
      );
      expect(
        manifests
            .where((manifest) => manifest.id.split('.').length == 2)
            .map((manifest) => manifest.id.substring(4))
            .toSet(),
        destinationIds,
      );

      final advanced = capabilities.singleWhere(
        (capability) => capability.id == 'nav.advanced_features',
      );
      service.refresh(
        service.context.copyWith(hostPlatform: AppHostPlatform.web),
      );

      expect(
        availableNavigationCommandList(),
        isNot(contains('/advanced_features')),
      );
      expect(resolveAvailableNavigationCommand('/advanced'), isNull);
      expect(
        navigationManifests().map((manifest) => manifest.id),
        isNot(contains('nav.advanced_features')),
      );
      expect(advanced.run(const <String, dynamic>{}).ok, isFalse);
      expect(navigated, isEmpty);
      service.closeLifecycle();
    },
  );

  testWidgets('router refresh redirects when the snapshot changes', (
    tester,
  ) async {
    final service = _snapshotService(AppHostPlatform.macos);
    final router = createAppRouter(
      initialLocation: AppRoutes.advancedFeatures,
      capabilitySnapshots: service,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.macos,
      ),
      routesOverride: <RouteBase>[
        GoRoute(
          path: AppRoutes.advancedFeatures,
          builder: (_, _) => const SizedBox.expand(),
        ),
        GoRoute(
          path: AppRoutes.settings,
          builder: (_, _) => const SizedBox.expand(),
        ),
        GoRoute(
          path: AppRoutes.home,
          builder: (_, _) => const SizedBox.expand(),
        ),
      ],
    );
    addTearDown(router.dispose);
    addTearDown(service.closeLifecycle);

    await tester.pumpWidget(MaterialApp.router(routerConfig: router));
    await tester.pump();
    expect(
      router.routeInformationProvider.value.uri.path,
      AppRoutes.advancedFeatures,
    );

    service.refresh(
      service.context.copyWith(hostPlatform: AppHostPlatform.web),
    );
    await tester.pump();

    expect(router.routeInformationProvider.value.uri.path, AppRoutes.settings);
  });

  test('snapshot redirect is authoritative over the legacy matrix', () {
    final service = _snapshotService(AppHostPlatform.web);

    expect(
      platformCapabilityRedirectForPath(
        AppRoutes.advancedFeatures,
        const AppPlatformCapabilities.forPlatform(AppHostPlatform.macos),
        snapshot: service.value,
      ),
      AppRoutes.settings,
    );
    expect(
      platformCapabilityRedirectForPath(
        AppRoutes.settings,
        const AppPlatformCapabilities.forPlatform(AppHostPlatform.web),
        snapshot: service.value,
      ),
      isNull,
    );
    service.closeLifecycle();
  });
}

AppCapabilitySnapshotService _snapshotService(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
        skillIds: const <String>{'app_navigate'},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

CapabilityRegistry _navigationRegistry(List<String> navigated) =>
    CapabilityRegistry()..registerAll(
      buildNavigationCapabilities(
        navigate: navigated.add,
        currentRoute: () => AppRouteCatalog.home,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.macos,
        ),
      ),
    );

List<dynamic> _advertisedPageIds(AppNavigateSkill skill) =>
    skill.nativeToolSchemas!['openPage']!['properties']['page']['enum'] as List;

List<dynamic> _listedPageIds(AppNavigateSkill skill) {
  final decoded = jsonDecode(skill.methods['listPages']!(const []) as String);
  return (decoded['pages'] as List).map((page) => page['id']).toList();
}

Map<String, dynamic> _openPage(AppNavigateSkill skill, String page) =>
    jsonDecode(
          skill.methods['openPage']!(<Object?>[
                <String, String>{'page': page},
              ])
              as String,
        )
        as Map<String, dynamic>;

final class _AgentSpaceUnavailableResolver
    implements AppCapabilitySnapshotResolver {
  _AgentSpaceUnavailableResolver()
    : _base = AppPlatformCapabilitySnapshotResolver(
        routeIds: AppRouteCatalog.destinations.map(
          (destination) => destination.id,
        ),
        skillIds: const <String>{'app_navigate'},
      );

  final AppCapabilitySnapshotResolver _base;

  @override
  AppCapabilitySnapshotDraft resolve(AppCapabilitySnapshotContext context) {
    final draft = _base.resolve(context);
    final worldKey = AppCapabilityKey.route('agent_space');
    return AppCapabilitySnapshotDraft(
      context: draft.context,
      decisions: <AppCapabilityDecision>[
        for (final decision in draft.decisions.values)
          if (decision.key == worldKey)
            AppCapabilityDecision(
              key: worldKey,
              exposure: AppCapabilityExposure.visible,
              admission: AppCapabilityAdmission.allowed,
              readiness: AppCapabilityReadiness.unavailable,
              reasonCodes: const <String>['route_dependency_unready'],
            )
          else
            decision,
      ],
    );
  }
}
