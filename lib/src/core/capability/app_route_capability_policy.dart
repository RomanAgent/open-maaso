import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

/// The evaluated capability gate for one trusted application location.
final class AppRouteCapabilityDecision {
  AppRouteCapabilityDecision({
    required Iterable<AppCapabilityKey> requiredKeys,
    required Iterable<AppCapabilityKey> rejectedKeys,
    required this.unavailableRedirect,
  }) : requiredKeys = Set<AppCapabilityKey>.unmodifiable(requiredKeys),
       rejectedKeys = Set<AppCapabilityKey>.unmodifiable(rejectedKeys);

  final Set<AppCapabilityKey> requiredKeys;
  final Set<AppCapabilityKey> rejectedKeys;
  final String unavailableRedirect;

  bool get isAllowed => rejectedKeys.isEmpty;
}

/// Returns the immutable snapshot keys that guard a trusted app location.
///
/// Public destinations resolve to their `route:*` key. Unknown locations
/// return `null` and are outside this policy.
Set<AppCapabilityKey>? snapshotRouteCapabilityKeysForLocation(String location) {
  final path = Uri.tryParse(location)?.path;
  if (path == null || path.isEmpty) return null;

  for (final destination in AppRouteCatalog.destinations) {
    if (destination.route == path) {
      return Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
        AppCapabilityKey.route(destination.id),
      });
    }
  }

  return null;
}

/// Evaluates the same trusted route map for imperative and declarative gates.
AppRouteCapabilityDecision? routeCapabilityDecisionForLocation(
  String location, {
  required AppPlatformCapabilities platformCapabilities,
  AppCapabilitySnapshot? snapshot,
}) {
  final path = Uri.tryParse(location)?.path;
  if (path == null || path.isEmpty) return null;
  final required = snapshotRouteCapabilityKeysForLocation(location);
  if (required == null) return null;

  final rejected = switch (snapshot) {
    final AppCapabilitySnapshot current =>
      current.rejected(required, requireVisible: true).keys.toSet(),
    null => <AppCapabilityKey>{
      for (final key in required)
        if (!_legacyPlatformAllows(key, platformCapabilities)) key,
    },
  };
  return AppRouteCapabilityDecision(
    requiredKeys: required,
    rejectedKeys: rejected,
    unavailableRedirect: _unavailableRedirectForPath(path),
  );
}

String _unavailableRedirectForPath(String path) {
  if (path == AppRouteCatalog.advancedFeatures) {
    return AppRouteCatalog.settings;
  }
  return AppRouteCatalog.home;
}

bool _legacyPlatformAllows(
  AppCapabilityKey key,
  AppPlatformCapabilities capabilities,
) {
  if (key.namespace == 'route') {
    return capabilities.destinationStatus(key.id).routeAvailable;
  }
  if (key.namespace != 'platform_action') return false;
  for (final action in AppActionCapability.values) {
    if (action.name == key.id) {
      return capabilities.actionStatus(action).available;
    }
  }
  return false;
}
