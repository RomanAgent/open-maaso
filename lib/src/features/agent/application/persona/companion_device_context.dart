import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_runtime_discovery_service.dart';

/// Presence is observation data, never permission to move or execute an Agent.
/// It is rebuilt for each request rather than added to the stable prompt cache.
String companionDeviceContext(
  String agentId, {
  AccountRuntimeDiscoveryService? discovery,
  DateTime? now,
}) {
  if (agentId != 'self') return '';
  discovery ??= appServices.maybeFind<AccountRuntimeDiscoveryService>();
  final at = now ?? DateTime.now();
  final snapshot = discovery?.snapshot;
  final fresh =
      discovery?.isObserving == true &&
      discovery?.lastError == null &&
      snapshot != null &&
      !snapshot.truncated &&
      at.difference(snapshot.snapshotAt) >= Duration.zero &&
      at.difference(snapshot.snapshotAt) <= const Duration(seconds: 75);
  final active = fresh
      ? snapshot.presences.where(
          (presence) =>
              presence.agentId == 'self' && presence.expiresAt.isAfter(at),
        )
      : null;
  final local = discovery?.thisRuntimePresence;
  final complete = active != null && local != null && active.contains(local);
  final count = complete
      ? active.map((p) => p.installationId).toSet().length
      : null;
  return 'Current account device presence data. The same Agent can be shown on '
      'every device, and each device can switch between avatar and chat. '
      'The count describes observed online devices, not registered devices or '
      'which device exclusively contains you. When the count is null, only this '
      'local device is known; do not claim an exact total.\n'
      '${jsonEncode({'knownLocalDeviceCount': 1, 'observedOnlineDeviceCount': count, 'observationComplete': complete})}';
}
