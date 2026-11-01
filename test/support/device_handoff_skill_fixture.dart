import 'dart:async';

import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/agent_handoff_device_directory.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/features/agent/application/skills/device_handoff_skill.dart';
import 'package:shared_preferences/shared_preferences.dart';

final handoffTestNow = DateTime.utc(2026, 9, 8, 12);
const handoffTestTarget = 'presence-desktop';

/// Real directory, coordinator and handoff service; only the network and
/// presentation boundary are replaced. Tests exercise proof-owning admission.
class HandoffSkillFixture {
  HandoffSkillFixture._(this.gateway, this.authority) {
    directory = AgentHandoffDeviceDirectory(
      gateway: gateway,
      authority: authority,
      accountContext: () => context,
    );
    service = AgentHandoffService(
      authority: authority,
      gateway: gateway,
      bridge: bridge,
      accountContext: () => context,
      serializeAuthority: _serialize,
      newRequestId: () => 'request-${++requestIds}',
      now: () => handoffTestNow,
    );
    skill = DeviceHandoffSkill(directory: directory);
  }
  final HandoffSkillGateway gateway;
  final AccountDeviceLeaseCoordinator authority;
  final HandoffSkillBridge bridge = HandoffSkillBridge();
  late final AgentHandoffDeviceDirectory directory;
  late final AgentHandoffService service;
  late final DeviceHandoffSkill skill;
  int requestIds = 0;
  HandoffAccountContext? context = const HandoffAccountContext(
    environment: MaasoEnvironment.test,
    accountUuid: 'account-owner',
  );
  static Future<HandoffSkillFixture> create() async {
    SharedPreferences.setMockInitialValues({
      AppInstallationIdentityService.preferencesKey:
          '0123456789abcdef0123456789abcdef',
    });
    final identity = await AppInstallationIdentityService(
      sharedPreferences: await SharedPreferences.getInstance(),
      randomBytes: (length) => List.filled(length, 20),
    ).init();
    final gateway = HandoffSkillGateway();
    var entropy = 30;
    final authority = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: (length) => List.filled(length, ++entropy),
      monotonicNow: () => Duration.zero,
      wallClock: () => handoffTestNow,
    );
    await authority.acquire(
      environment: MaasoEnvironment.test,
      accountUuid: 'account-owner',
      deviceLabel: 'Phone',
      platform: 'ios',
      appVersion: '1',
    );
    return HandoffSkillFixture._(gateway, authority);
  }

  void dispose() => service.dispose();
}

Future<T> _serialize<T>(Future<T> Function() work) => work();

class HandoffSkillBridge implements AgentHandoffRuntimeBridge {
  final calls = <String>[];
  @override
  bool get isAvailable => true;
  @override
  Future<HandoffAvatarIdentity> currentAvatar() async {
    calls.add('identity');
    return HandoffAvatarIdentity(modelId: 'bundled', revision: '1');
  }

  @override
  Future<void> restoreSource(AccountDeviceHandoff h) async =>
      calls.add('restore');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class HandoffSkillGateway
    implements
        AccountDeviceLeaseGateway,
        AccountDeviceHandoffGateway,
        AccountRuntimeDiscoveryGateway {
  late AccountDevicePresenceReceipt presence;
  AccountDeviceLeaseReceipt? lease;
  AccountDeviceHandoff? handoff;
  final commands = <AccountHandoffCommand>[];
  final requestedAccounts = <String>[];
  final requestBodies = <Map<String, Object?>>[];
  int listCalls = 0;
  bool targetVisible = true, failPrepare = false;
  bool snapshotTruncated = false;
  final extraPresences = <AccountDevicePresenceView>[];
  Completer<void>? listGate, prepareGate;

  @override
  Future<AccountDevicePresenceListResult> listActivePresences({
    required MaasoEnvironment environment,
    required String accountUuid,
    String agentId = 'self',
    int limit = 50,
  }) async {
    listCalls++;
    requestedAccounts.add(accountUuid);
    await listGate?.future;
    return AccountDevicePresenceListResult(
      presences: [
        AccountDevicePresenceView(
          agentId: presence.agentId,
          installationId: presence.installationId,
          runtimeInstanceId: presence.runtimeInstanceId,
          presenceSessionId: presence.presenceSessionId,
          deviceLabel: presence.deviceLabel,
          platform: presence.platform,
          appVersion: presence.appVersion,
          openedAt: presence.openedAt,
          lastSeenAt: presence.lastSeenAt,
          expiresAt: presence.expiresAt,
          isCurrentHolder: true,
        ),
        if (targetVisible)
          AccountDevicePresenceView(
            agentId: 'self',
            installationId: 'installation-desktop',
            runtimeInstanceId: 'runtime-desktop',
            presenceSessionId: handoffTestTarget,
            deviceLabel: 'My computer',
            platform: 'macos',
            appVersion: '1',
            openedAt: handoffTestNow,
            lastSeenAt: handoffTestNow,
            expiresAt: handoffTestNow.add(const Duration(minutes: 1)),
            isCurrentHolder: false,
          ),
        ...extraPresences,
      ],
      snapshotAt: handoffTestNow,
      eventSequence: 1,
      truncated: snapshotTruncated,
    );
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async => AccountDeviceLeaseSnapshot(
    state: lease == null
        ? AccountDeviceLeaseRemoteState.inactive
        : AccountDeviceLeaseRemoteState.active,
    lease: lease,
  );
  @override
  Future<AccountDevicePresenceOperationResult> openPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String deviceLabel,
    required String platform,
    required String appVersion,
    required String requestId,
  }) async {
    presence = AccountDevicePresenceReceipt(
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence-phone',
      generation: 1,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      openedAt: handoffTestNow,
      lastSeenAt: handoffTestNow,
      expiresAt: handoffTestNow.add(const Duration(minutes: 1)),
      remainingTtl: const Duration(minutes: 1),
      renewAfter: const Duration(seconds: 20),
    );
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: false,
    );
  }

  @override
  Future<AccountDeviceLeaseOperationResult> acquireLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
    required String installationId,
    required String runtimeInstanceId,
    required String presenceSessionId,
    required String holderProof,
    required String requestId,
  }) async {
    lease = AccountDeviceLeaseReceipt(
      agentId: agentId,
      leaseId: 'lease-phone',
      epoch: 1,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: handoffTestNow.add(const Duration(seconds: 45)),
      remainingTtl: const Duration(seconds: 45),
      renewAfter: const Duration(seconds: 15),
      holder: presence.toHolder(),
    );
    return AccountDeviceLeaseOperationResult(lease: lease!, replayed: false);
  }

  @override
  Future<AccountHandoffResult> currentHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    String? handoffId,
  }) async => AccountHandoffResult(handoff: handoff, replayed: false);
  @override
  Future<AccountHandoffResult> handoffCommand({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountHandoffCommand command,
    required Map<String, Object?> body,
    String? handoffId,
  }) async {
    commands.add(command);
    requestBodies.add(body);
    if (command == AccountHandoffCommand.prepare) {
      await prepareGate?.future;
      if (failPrepare) throw StateError('private provider credential detail');
    }
    handoff = AccountDeviceHandoff(
      handoffId: 'handoff-skill',
      agentId: 'self',
      state: command == AccountHandoffCommand.cancel
          ? AccountHandoffState.cancelled
          : AccountHandoffState.prepared,
      sourceLeaseId: lease!.leaseId,
      sourceEpoch: lease!.epoch,
      sourcePresenceSessionId: presence.presenceSessionId,
      sourceRuntimeInstanceId: presence.runtimeInstanceId,
      targetPresenceSessionId: handoffTestTarget,
      targetRuntimeInstanceId: 'runtime-desktop',
      avatarModel: HandoffAvatarIdentity(modelId: 'bundled', revision: '1'),
      createdAt: handoffTestNow,
      expiresAt: handoffTestNow.add(const Duration(seconds: 60)),
      remainingTtl: const Duration(seconds: 60),
    );
    return AccountHandoffResult(handoff: handoff, replayed: false);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
