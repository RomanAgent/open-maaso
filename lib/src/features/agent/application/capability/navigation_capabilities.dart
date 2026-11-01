import 'package:maaso/src/features/agent/application/capability/capability.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

/// Builds one navigate [Capability] per [AppRouteCatalog.destinations] entry.
/// [navigate] performs the actual route change; [currentRoute] returns the
/// active route name (both injected so this stays independent of go_router).
List<Capability> buildNavigationCapabilities({
  required void Function(String route) navigate,
  required String Function() currentRoute,
  AppLocale? locale,
  AppLocale Function()? localeProvider,
  AppPlatformCapabilities? platformCapabilities,
  AppCapabilitySnapshot? snapshot,
  AppCapabilitySnapshotService? capabilitySnapshots,
}) {
  AppLocale resolvedLocale() =>
      localeProvider?.call() ?? locale ?? AgentPromptCatalog.currentLocale;
  final resolvedCapabilitySnapshots =
      capabilitySnapshots ??
      (snapshot == null
          ? appServices.maybeFind<AppCapabilitySnapshotService>()
          : null);
  final destinations = availableNavigationDestinations(
    platformCapabilities: platformCapabilities,
    snapshot: snapshot,
    capabilitySnapshots: resolvedCapabilitySnapshots,
  );

  return [
    for (final d in destinations)
      Capability(
        id: 'nav.${d.id}',
        kind: CapabilityKind.navigate,
        title: navigationDestinationTitle(d.id, locale: resolvedLocale()),
        description: AgentPromptCatalog.text(
          'navigation.capability.description',
          locale: resolvedLocale(),
          params: {
            'title': navigationDestinationTitle(d.id, locale: resolvedLocale()),
          },
        ),
        titleResolver: () =>
            navigationDestinationTitle(d.id, locale: resolvedLocale()),
        descriptionResolver: () => AgentPromptCatalog.text(
          'navigation.capability.description',
          locale: resolvedLocale(),
          params: {
            'title': navigationDestinationTitle(d.id, locale: resolvedLocale()),
          },
        ),
        keywords: d.allKeywords,
        run: (args) {
          final currentSnapshot =
              resolvedCapabilitySnapshots?.value ?? snapshot;
          if (resolvedCapabilitySnapshots?.isClosed == true ||
              (currentSnapshot != null &&
                  !currentSnapshot.allows(
                    AppCapabilityKey.route(d.id),
                    requireVisible: true,
                  ))) {
            return CapabilityResult.error('capability_unavailable:${d.id}');
          }
          final targetRoute =
              d.variant(args['channel']?.toString())?.route ?? d.route;
          if (currentRoute() == targetRoute) {
            return CapabilityResult.ok(
              AgentPromptCatalog.text(
                'navigation.capability.already_on',
                locale: resolvedLocale(),
                params: {
                  'title': navigationDestinationTitle(
                    d.id,
                    locale: resolvedLocale(),
                  ),
                },
              ),
            );
          }
          navigate(targetRoute);
          return CapabilityResult.ok(
            AgentPromptCatalog.text(
              'navigation.capability.opened',
              locale: resolvedLocale(),
              params: {
                'title': navigationDestinationTitle(
                  d.id,
                  locale: resolvedLocale(),
                ),
              },
            ),
          );
        },
      ),
  ];
}

List<AppDestination> availableNavigationDestinations({
  AppPlatformCapabilities? platformCapabilities,
  AppCapabilitySnapshot? snapshot,
  AppCapabilitySnapshotService? capabilitySnapshots,
}) {
  final resolvedCapabilitySnapshots =
      capabilitySnapshots ??
      (snapshot == null
          ? appServices.maybeFind<AppCapabilitySnapshotService>()
          : null);
  if (resolvedCapabilitySnapshots?.isClosed == true) {
    return const <AppDestination>[];
  }
  final resolvedSnapshot = snapshot ?? resolvedCapabilitySnapshots?.value;
  if (resolvedSnapshot != null) {
    return AppRouteCatalog.destinations
        .where(
          (destination) => resolvedSnapshot.allows(
            AppCapabilityKey.route(destination.id),
            requireVisible: true,
          ),
        )
        .toList(growable: false);
  }
  final capabilities =
      platformCapabilities ?? AppPlatformCapabilities.current();
  return AppRouteCatalog.destinations
      .where(
        (destination) =>
            capabilities.destinationStatus(destination.id).routeAvailable,
      )
      .toList(growable: false);
}

List<String> availableNavigationCommandList({
  AppPlatformCapabilities? platformCapabilities,
  AppCapabilitySnapshot? snapshot,
  AppCapabilitySnapshotService? capabilitySnapshots,
}) => [
  for (final destination in availableNavigationDestinations(
    platformCapabilities: platformCapabilities,
    snapshot: snapshot,
    capabilitySnapshots: capabilitySnapshots,
  ))
    '/${destination.id}',
];

String? resolveAvailableNavigationCommand(
  String input, {
  AppPlatformCapabilities? platformCapabilities,
  AppCapabilitySnapshot? snapshot,
  AppCapabilitySnapshotService? capabilitySnapshots,
}) {
  final route = AppRouteCatalog.resolveCommand(input);
  if (route == null || route == AppRouteCatalog.onboarding) return route;
  for (final destination in availableNavigationDestinations(
    platformCapabilities: platformCapabilities,
    snapshot: snapshot,
    capabilitySnapshots: capabilitySnapshots,
  )) {
    if (destination.route == route ||
        destination.variants.any((variant) => variant.route == route)) {
      return route;
    }
  }
  return null;
}

/// Navigation verbs / "where" questions, EN + ZH. Deliberately verb-shaped:
/// destination keywords themselves (设置/聊天/记忆…) are everyday words, so the
/// manifests must only enter local retrieval when the sentence also *sounds*
/// like going somewhere. Heuristic risk-reducer until Phase 2 embedding
/// retrieval; the cloud model needs no gate (its prompt explains when to use
/// the skill).
final RegExp _navIntent = RegExp(
  r'打开|进入|跳转|跳到|切换|带我|去|回|看看|在哪|哪里|哪儿'
  r'|open|go to|goto|take me|show me|jump|navigate|switch to|back to|where',
  caseSensitive: false,
);

/// True when [text] plausibly asks to go somewhere ("打开设置", "回主页",
/// "where is the memory wall") rather than merely mentioning a destination
/// keyword in passing ("我们聊聊天吧", "帮我设置个闹钟").
bool looksLikeNavigationIntent(String text) => _navIntent.hasMatch(text);

/// One on-device manifest per destination, bound to [AppNavigate].openPage via
/// [LocalSkillManifest.fixedArgs]. Retrieval matches on [tags] (the keywords);
/// the planner just calls the manifest with empty args. Callers should gate
/// inclusion on [looksLikeNavigationIntent].
List<LocalSkillManifest> navigationManifests({
  AppLocale? locale,
  AppPlatformCapabilities? platformCapabilities,
  AppCapabilitySnapshot? snapshot,
  AppCapabilitySnapshotService? capabilitySnapshots,
}) {
  final destinations = availableNavigationDestinations(
    platformCapabilities: platformCapabilities,
    snapshot: snapshot,
    capabilitySnapshots: capabilitySnapshots,
  );
  return [
    for (final d in destinations)
      LocalSkillManifest(
        id: 'nav.${d.id}',
        skillName: 'AppNavigate',
        method: 'openPage',
        summary: AgentPromptCatalog.text(
          'navigation.capability.description',
          locale: locale,
          params: {'title': navigationDestinationTitle(d.id, locale: locale)},
        ),
        tags: d.keywords,
        argsSchema: const {},
        fixedArgs: {'page': d.id},
      ),
    for (final d in destinations)
      for (final variant in d.variants)
        LocalSkillManifest(
          id: 'nav.${d.id}.${variant.id}',
          skillName: 'AppNavigate',
          method: 'openPage',
          summary: AgentPromptCatalog.text(
            'navigation.capability.description',
            locale: locale,
            params: {'title': navigationDestinationTitle(d.id, locale: locale)},
          ),
          tags: variant.keywords,
          argsSchema: const {},
          fixedArgs: {'page': d.id, 'channel': variant.id},
        ),
  ];
}

/// Resolves only an exact host-authored navigation manifest to its capability
/// set. Model-authored or malformed lookalikes receive no binding.
Set<AppCapabilityKey>? navigationManifestCapabilityKeys(
  LocalSkillManifest manifest,
) {
  if (manifest.skillName != 'AppNavigate' || manifest.method != 'openPage') {
    return null;
  }
  final page = manifest.fixedArgs['page'];
  if (page is! String || page.trim() != page || page.isEmpty) return null;

  AppDestination? destination;
  for (final candidate in AppRouteCatalog.destinations) {
    if (candidate.id == page) {
      destination = candidate;
      break;
    }
  }
  if (destination == null) return null;

  final rawChannel = manifest.fixedArgs['channel'];
  final channel = rawChannel is String ? rawChannel.trim() : null;
  if (rawChannel != null &&
      (channel == null ||
          channel.isEmpty ||
          rawChannel != channel ||
          destination.variant(channel) == null)) {
    return null;
  }
  if (manifest.fixedArgs.length != (channel == null ? 1 : 2)) return null;
  final expectedId = channel == null ? 'nav.$page' : 'nav.$page.$channel';
  if (manifest.id != expectedId) return null;

  return Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
    AppCapabilityKey.skill('app_navigate'),
    AppCapabilityKey.route(page),
  });
}

String navigationDestinationTitle(String id, {AppLocale? locale}) =>
    AgentPromptCatalog.text('navigation.destination.$id.title', locale: locale);
