import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';

/// Reads only the authenticated account's live devices; never uses discovery
/// labels as authority or forwards a remote URL to a renderer.
final class AgentHandoffDeviceDirectory {
  const AgentHandoffDeviceDirectory({
    required this.gateway,
    required this.authority,
    required this.accountContext,
  });

  final AccountRuntimeDiscoveryGateway gateway;
  final AccountDeviceLeaseCoordinator authority;
  final HandoffAccountContext? Function() accountContext;

  /// Canonical account presence, including this device and the execution owner.
  /// Presentation is available on every device and needs no handoff target.
  Future<AccountDevicePresenceListResult> listDevices() async {
    final context = accountContext();
    final local = authority.currentPresence;
    if (context == null || local == null) {
      throw StateError('handoff_account_unavailable');
    }
    final snapshot = await gateway.listActivePresences(
      environment: context.environment,
      accountUuid: context.accountUuid,
      agentId: local.agentId,
    );
    if (accountContext()?.matches(context) != true ||
        authority.currentPresence?.presenceSessionId !=
            local.presenceSessionId) {
      throw StateError('handoff_account_changed');
    }
    return snapshot;
  }

  Future<List<AccountDevicePresenceView>> listTargets() async {
    final local = authority.currentPresence;
    final snapshot = await listDevices();
    return snapshot.presences
        .where(
          (device) =>
              device.presenceSessionId != local?.presenceSessionId &&
              device.runtimeInstanceId != local?.runtimeInstanceId &&
              !device.isCurrentHolder &&
              device.expiresAt.isAfter(snapshot.snapshotAt) &&
              const {
                'macos',
                'windows',
                'ios',
                'android',
              }.contains(device.platform),
        )
        .toList(growable: false);
  }
}
