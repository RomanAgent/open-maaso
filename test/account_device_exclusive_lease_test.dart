import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/services/startup_route_service.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/account_runtime_discovery_service.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _ExclusiveServer server;
  late AppEnvironmentService environment;
  final peers = <_Peer>[];

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put<SecureStorageService>(_MemorySecureStorage());
    environment = appServices.put(AppEnvironmentService());
    await environment.init();
    server = _ExclusiveServer();
  });

  tearDown(() async {
    for (final peer in peers) {
      if (peer.mountGate?.isCompleted == false) peer.mountGate!.complete();
      peer.mountError = null;
      peer.closeError = null;
      peer.closeGate?.complete();
      peer.closeGate = null;
      await peer.lifecycle.signOutAndUnmount();
      peer.lifecycle.closeLifecycle();
      peer.coordinator.close();
    }
    peers.clear();
    await appServices.reset();
  });

  Future<_Peer> peer({
    AccountRuntimeAuthorityMode mode = AccountRuntimeAuthorityMode.off,
    bool exclusive = true,
    bool layered = false,
    int? installationStoreId,
  }) async {
    final result = await _Peer.create(
      peers.length + 1,
      server,
      environment,
      mode: mode,
      exclusive: exclusive,
      layered: layered,
      installationStoreId: installationStoreId,
    );
    peers.add(result);
    return result;
  }

  for (final mode in [
    AccountRuntimeAuthorityMode.off,
    AccountRuntimeAuthorityMode.shadow,
  ]) {
    test('$mode admits one device and keeps the other in standby', () async {
      server.mode = mode;
      final phone = await peer(mode: mode);
      final desktop = await peer(mode: mode);
      expect(await phone.login(), isTrue);
      expect(await desktop.login(), isFalse);
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(phone.mounts, 1);
      expect(desktop.mounts, 0);
      expect(
        desktop.lifecycle.phase.value,
        AccountSessionLifecyclePhase.leaseConflict,
      );
      expect(desktop.lifecycle.requiresStandbyRoute, isTrue);
      expect(phone.lifecycle.usesExclusiveDeviceLease, isTrue);
      expect(phone.lifecycle.effectiveAuthorityMode, mode);
      expect(phone.lifecycle.enforcementActivated, isFalse);
      expect(
        server.lease!.runtimeInstanceId,
        phone.coordinator.currentReceipt!.runtimeInstanceId,
      );
      // Same-scope publication revalidates through the authority heartbeat.
      expect(await phone.lifecycle.mountCurrentSession(), isTrue);
      expect(server.leaseHeartbeats, 1);
      expect(phone.mounts, 1);
      await phone.lifecycle.quiesceForDeviceHandoff();
      expect(phone.fences, 1);
      expect(phone.lifecycle.effectiveAuthorityMode, mode);
    });

    test(
      '$mode standby renews presence and discovery without acquiring',
      () async {
        server.mode = mode;
        final phone = await peer(mode: mode);
        final desktop = await peer(mode: mode);
        await phone.login();
        await desktop.login();
        await _flush();
        expect(phone.discovery.isObserving, isTrue);
        expect(desktop.discovery.isObserving, isTrue);
        final acquisitions = server.acquireCalls;
        final authority = server.lease;
        desktop.presenceTimers.fireShortest();
        await _flush();
        expect(server.presenceHeartbeats, 1);
        expect(server.acquireCalls, acquisitions);
        expect(server.lease, same(authority));
        expect(desktop.coordinator.currentReceipt, isNull);
        expect(phone.presenceTimers.active, isEmpty);
        await desktop.lifecycle.signOutAndUnmount();
        await _flush();
        expect(desktop.discovery.isObserving, isFalse);
        expect(desktop.presenceTimers.active, isEmpty);
      },
    );
  }

  test(
    'owner releases only after drain and next device acquires a new epoch',
    () async {
      final phone = await peer();
      final desktop = await peer();
      await phone.login();
      await desktop.login();
      final epoch = server.lease!.epoch;
      phone.closeGate = Completer<void>();
      final leaving = phone.lifecycle.unmount();
      await _flush();
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(server.lease!.epoch, epoch);
      expect(await desktop.lifecycle.mountCurrentSession(), isFalse);
      phone.closeGate!.complete();
      phone.closeGate = null;
      await leaving;
      expect(await desktop.lifecycle.mountCurrentSession(), isTrue);
      expect(server.lease!.epoch, greaterThan(epoch));
      expect(desktop.lifecycle.canExecuteAgent, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
    },
  );

  test(
    'expired owner cannot present while stale cleanup cannot release successor',
    () async {
      final phone = await peer();
      final desktop = await peer();
      await phone.login();
      await desktop.login();
      server.elapsed += const Duration(seconds: 61);
      expect(phone.lifecycle.isMounted, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(await desktop.lifecycle.mountCurrentSession(), isTrue);
      final successor = server.lease;
      expect(await phone.lifecycle.mountCurrentSession(), isFalse);
      await _flush();
      expect(server.lease, same(successor));
      expect(desktop.lifecycle.canExecuteAgent, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
    },
  );

  test(
    'valid but different coordinator receipt cannot present the old mount',
    () async {
      final phone = await peer();
      await phone.login();
      final old = phone.lifecycle.activeDeviceLease!;
      await phone.coordinator.release();
      await phone.coordinator.acquire(
        environment: environment.environment.value,
        accountUuid: 'same-account',
        deviceLabel: 'phone',
        platform: 'ios',
        appVersion: '1',
      );
      expect(phone.coordinator.canAdmitMutations, isTrue);
      expect(phone.coordinator.currentReceipt!.epoch, isNot(old.epoch));
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      // The fixture retires the deliberately injected replacement itself.
      await phone.coordinator.release();
    },
  );

  test(
    'policy off to shadow to off retains the same exclusive authority',
    () async {
      final phone = await peer(mode: AccountRuntimeAuthorityMode.shadow);
      await phone.login();
      final authority = phone.lifecycle.activeDeviceLease!;
      for (final mode in [
        AccountRuntimeAuthorityMode.shadow,
        AccountRuntimeAuthorityMode.off,
      ]) {
        server.mode = mode;
        server.revision++;
        phone.policyTimers.fireShortest();
        await _flush();
        expect(phone.lifecycle.effectiveAuthorityMode, mode);
        expect(phone.lifecycle.canExecuteAgent, isTrue);
        expect(phone.coordinator.currentReceipt!.leaseId, authority.leaseId);
        expect(phone.coordinator.currentPresence, isNotNull);
        expect(server.releaseCalls, 0);
        expect(phone.mounts, 1);
        expect(phone.lifecycle.enforcementActivated, isFalse);
      }
    },
  );

  test(
    'off still requires policy and expiry fences before delayed cleanup',
    () async {
      final phone = await peer();
      server.policyError = TimeoutException('offline');
      expect(await phone.login(), isFalse);
      expect(phone.lifecycle.requiresStandbyRoute, isTrue);
      expect(phone.mounts, 0);
      expect(server.acquireCalls, 0);
      server.policyError = null;
      server.policyTtl = const Duration(seconds: 10);
      expect(await phone.lifecycle.mountCurrentSession(), isTrue);
      phone.closeGate = Completer<void>();
      server.elapsed += const Duration(seconds: 10);
      phone.policyTimers.fireLongest();
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(
        phone.lifecycle.effectiveAuthorityMode,
        AccountRuntimeAuthorityMode.off,
      );
      await _flush();
      expect(phone.lifecycle.requiresStandbyRoute, isTrue);
      phone.closeGate!.complete();
      phone.closeGate = null;
      await _flush();
      server.policyError = TimeoutException('still offline');
      expect(await phone.lifecycle.mountCurrentSession(), isFalse);
      expect(phone.mounts, 1);
    },
  );

  test(
    'policy expiry during off acquisition never constructs runtime',
    () async {
      final phone = await peer();
      server.policyTtl = const Duration(seconds: 2);
      server.acquireGate = Completer<void>();
      final mounting = phone.login();
      await _flush();
      expect(server.acquireCalls, 1);
      server.elapsed += const Duration(seconds: 3);
      phone.policyTimers.fireLongest();
      server.acquireGate!.complete();
      expect(await mounting, isFalse);
      await _flush();
      expect(phone.mounts, 0);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(phone.coordinator.currentReceipt, isNull);
    },
  );

  test(
    'full enforce downgrade remains fenced instead of changing RTC semantics',
    () async {
      server.mode = AccountRuntimeAuthorityMode.enforce;
      final phone = await peer(mode: AccountRuntimeAuthorityMode.enforce);
      await phone.login();
      expect(phone.lifecycle.enforcementActivated, isTrue);
      server.mode = AccountRuntimeAuthorityMode.off;
      server.revision++;
      phone.policyTimers.fireShortest();
      await _flush();
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(await phone.lifecycle.mountCurrentSession(), isFalse);
      expect(
        phone.lifecycle.effectiveAuthorityMode,
        AccountRuntimeAuthorityMode.off,
      );
      expect(phone.lifecycle.enforcementActivated, isTrue);
      expect(phone.lifecycle.usesExclusiveDeviceLease, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(phone.mounts, 1);
    },
  );

  test(
    'active deadline hides before a held heartbeat response settles',
    () async {
      final heartbeatTimers = _HeartbeatTimers();
      await heartbeatTimers.run(() async {
        final delayed = _DelayedLeaseHeartbeatServer();
        server = delayed;
        final phone = await peer();
        final desktop = await peer();
        expect(await phone.login(), isTrue);
        expect(await desktop.login(), isFalse);
        final mount = phone.lifecycle.activeMount!;
        final visible = <bool>[];
        phone.lifecycle.addListener(
          () => visible.add(phone.lifecycle.canExecuteAgent),
        );
        final fencesBeforeExpiry = phone.fences;

        server.elapsed = const Duration(seconds: 40);
        heartbeatTimers.fireShortest();
        await _flush();
        expect(delayed.heartbeatStarted.isCompleted, isTrue);
        expect(delayed.heartbeatGate.isCompleted, isFalse);
        expect(phone.lifecycle.isMounted, isTrue);
        server.elapsed = const Duration(seconds: 61);
        phone.authorityTimers.fireShortest();
        expect(phone.lifecycle.isMounted, isFalse);
        expect(phone.lifecycle.canExecuteAgent, isFalse);
        expect(phone.lifecycle.storageScopes.isCurrent(mount), isFalse);
        expect(phone.fences, fencesBeforeExpiry + 1);
        await _flush();
        expect(visible, contains(false));
        expect(
          server.releaseCalls,
          0,
          reason: 'release must not race the pending heartbeat',
        );
        expect(await desktop.lifecycle.mountCurrentSession(), isTrue);
        final successor = server.lease;

        delayed.heartbeatGate.complete();
        await _flush();
        expect(phone.lifecycle.canExecuteAgent, isFalse);
        expect(
          phone.lifecycle.phase.value,
          AccountSessionLifecyclePhase.authenticatedStandby,
        );
        expect(desktop.lifecycle.canExecuteAgent, isTrue);
        expect(
          server.lease,
          same(successor),
          reason: 'late source reply cannot release new owner',
        );
        await phone.lifecycle.signOutAndUnmount();
        await desktop.lifecycle.signOutAndUnmount();
      });
    },
  );

  test(
    'active deadline bypasses a blocked handoff queue before the next device mounts',
    () async {
      final heartbeatTimers = _HeartbeatTimers();
      await heartbeatTimers.run(() async {
        final phone = await peer();
        final desktop = await peer();
        await phone.login();
        await desktop.login();
        final mount = phone.lifecycle.activeMount!;
        final gate = Completer<void>();
        var enteredQueue = false;
        final blocked = phone.lifecycle.serializeDeviceHandoff(() async {
          enteredQueue = true;
          await gate.future;
        });
        await _flush();
        expect(enteredQueue, isTrue);
        server.elapsed = const Duration(seconds: 61);
        heartbeatTimers.fireShortest();
        await _flush();
        expect(
          server.leaseHeartbeats,
          0,
          reason: 'heartbeat is still waiting in the queue',
        );
        phone.authorityTimers.fireShortest();
        expect(
          phone.lifecycle.phase.value,
          AccountSessionLifecyclePhase.retiring,
        );
        expect(phone.lifecycle.canExecuteAgent, isFalse);
        expect(phone.lifecycle.storageScopes.isCurrent(mount), isFalse);
        expect(server.releaseCalls, 0);
        expect(await desktop.lifecycle.mountCurrentSession(), isTrue);
        final successor = server.lease;
        gate.complete();
        await blocked;
        await _flush();
        expect(
          phone.lifecycle.phase.value,
          AccountSessionLifecyclePhase.authenticatedStandby,
        );
        expect(server.lease, same(successor));
        expect(desktop.lifecycle.canExecuteAgent, isTrue);
        expect(
          server.leaseHeartbeats,
          0,
          reason: 'queued stale heartbeat must not restart authority',
        );
        await phone.lifecycle.signOutAndUnmount();
        await desktop.lifecycle.signOutAndUnmount();
      });
    },
  );

  test(
    'renewal replaces active deadline and cancelled callbacks cannot fence a new mount',
    () async {
      final heartbeatTimers = _HeartbeatTimers();
      await heartbeatTimers.run(() async {
        server = _RenewingLeaseHeartbeatServer();
        final phone = await peer();
        await phone.login();
        final firstTimer = phone.authorityTimers.active.single;
        server.elapsed = const Duration(seconds: 20);
        firstTimer.fire();
        expect(
          phone.lifecycle.canExecuteAgent,
          isTrue,
          reason: 'early timer must re-arm',
        );
        final earlyRearm = phone.authorityTimers.active.single;
        server.elapsed = const Duration(seconds: 40);
        heartbeatTimers.fireShortest();
        await _flush();
        expect(server.leaseHeartbeats, 1);
        expect(earlyRearm.isActive, isFalse);
        final renewedTimer = phone.authorityTimers.active.single;
        server.elapsed = const Duration(seconds: 61);
        earlyRearm.callback();
        expect(phone.lifecycle.canExecuteAgent, isTrue);
        renewedTimer.fire();
        expect(
          phone.lifecycle.canExecuteAgent,
          isTrue,
          reason: 'renewed receipt is valid beyond old expiry',
        );
        final cancelled = phone.authorityTimers.active.single;
        await phone.lifecycle.unmount();
        expect(cancelled.isActive, isFalse);
        expect(await phone.lifecycle.mountCurrentSession(), isTrue);
        final replacement = phone.lifecycle.activeMount;
        cancelled.callback();
        expect(phone.lifecycle.activeMount, same(replacement));
        expect(phone.lifecycle.canExecuteAgent, isTrue);
        await phone.lifecycle.signOutAndUnmount();
        expect(phone.authorityTimers.active, isEmpty);
      });
    },
  );

  test(
    'committed target upgrades the same companion mount without acquiring again',
    () async {
      final source = await peer(layered: true);
      final target = await peer(layered: true);
      expect(await source.login(), isTrue);
      expect(await target.login(), isTrue);
      final sourceMount = source.lifecycle.activeMount;
      final targetMount = target.lifecycle.activeMount;
      final gateway = _CompanionTransferredHandoff(
        server,
        target.coordinator.currentPresence!,
      );
      await target.lifecycle.serializeDeviceHandoff(
        () => target.coordinator.acknowledgeHandoffReady(
          gateway,
          handoff: gateway.view(AccountHandoffState.prepared),
          requestId: 'target-ready',
        ),
      );
      await source.lifecycle.quiesceForDeviceHandoff();
      gateway.commit();
      source.coordinator.fence();
      await source.lifecycle.retireAgentExecution();
      expect(source.lifecycle.isMounted, isTrue);
      expect(source.lifecycle.activeMount, same(sourceMount));
      expect(source.lifecycle.canExecuteAgent, isFalse);
      await target.lifecycle.serializeDeviceHandoff(
        () => target.coordinator.adoptTargetHandoff(
          gateway,
          handoffId: 'companion-handoff',
        ),
      );
      expect(target.coordinator.hasTransferredLeaseAwaitingMount, isTrue);
      expect(await target.lifecycle.mountTransferredHandoff(), isTrue);
      expect(target.lifecycle.activeMount, same(targetMount));
      expect(target.lifecycle.canExecuteAgent, isTrue);
      expect(target.baseMounts, 1);
      expect(target.baseCloses, 0);
      expect(target.mounts, 1);
      expect(target.coordinator.hasTransferredLeaseAwaitingMount, isFalse);
      expect(
        server.acquireCalls,
        2,
        reason: 'only the initial owner and initial companion conflict acquire',
      );
      expect(server.lease?.leaseId, 'transferred-companion-lease');
    },
  );

  test(
    'companion pages mount on both devices while only one owns execution',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      expect(await phone.login(), isTrue);
      expect(await desktop.login(), isTrue);
      expect(phone.baseMounts, 1);
      expect(desktop.baseMounts, 1);
      expect(phone.mounts, 1);
      expect(desktop.mounts, 0);
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.owner);
      expect(desktop.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(desktop.lifecycle.isMounted, isTrue);
      expect(desktop.lifecycle.activeMount, isNotNull);
      expect(desktop.auth.session.value, isNotNull);
      expect(desktop.lifecycle.leaseConflict, isNotNull);
      expect(desktop.lifecycle.requiresStandbyRoute, isFalse);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(phone.activatedInsideOwnerCallback, isTrue);
      expect(phone.lifecycle.ownerActivationInProgress, isFalse);
      await expectLater(
        desktop.lifecycle.quiesceForDeviceHandoff(),
        throwsStateError,
      );
    },
  );

  test('companion startup and all account routes remain available', () async {
    final owner = await peer(layered: true);
    await owner.login();
    final companion = await peer(layered: true);
    appServices.put<AccountSessionLifecycleService>(companion.lifecycle);
    expect(
      await StartupRouteService().resolveInitialRoute(),
      AppRouteCatalog.home,
    );
    expect(companion.lifecycle.runtimeRole, AccountRuntimeRole.companion);
    for (final path in [
      AppRoutes.home,
      AppRoutes.settings,
      AppRoutes.gameFeed,
    ]) {
      expect(accountSessionRedirectForPath(path), isNull);
    }
    expect(
      accountSessionRedirectForPath(AppRoutes.accountStandby),
      AppRoutes.home,
    );
  });

  test(
    'unavailable execution policy preserves verified account and discovery',
    () async {
      server.policyError = TimeoutException('policy unavailable');
      final phone = await peer(layered: true);
      expect(await phone.login(), isTrue);
      expect(phone.lifecycle.isMounted, isTrue);
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(phone.mounts, 0);
      expect(phone.auth.session.value, isNotNull);
      await _flush();
      expect(phone.discovery.isObserving, isTrue);
      phone.presenceTimers.fireShortest();
      await _flush();
      expect(phone.coordinator.currentPresence, isNotNull);
      expect(server.acquireCalls, 0);
    },
  );

  test(
    'policy expiry retires only the owner and keeps the same base generation',
    () async {
      server.policyTtl = const Duration(seconds: 10);
      final phone = await peer(layered: true);
      await phone.login();
      final mount = phone.lifecycle.activeMount!;
      final published = phone.auth.session.value;
      final roles = <AccountRuntimeRole?>[];
      phone.lifecycle.addListener(() => roles.add(phone.lifecycle.runtimeRole));
      phone.closeGate = Completer<void>();
      server.elapsed = const Duration(seconds: 11);
      phone.policyTimers.fireLongest();
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(phone.lifecycle.isMounted, isTrue);
      expect(phone.lifecycle.activeMount, same(mount));
      expect(phone.lifecycle.storageScopes.isCurrent(mount), isTrue);
      expect(phone.auth.session.value, same(published));
      expect(phone.baseCloses, 0);
      await _flush();
      expect(roles, contains(AccountRuntimeRole.companion));
      phone.closeGate!.complete();
      phone.closeGate = null;
      await _flush();
      expect(phone.ownerCloses, 1);
      server.policyError = TimeoutException('offline');
      expect(await phone.lifecycle.mountCurrentSession(), isTrue);
      expect(phone.baseMounts, 1);
      expect(phone.mounts, 1);
    },
  );

  test(
    'owner moves away and follower upgrades without replacing either account graph',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      final phoneMount = phone.lifecycle.activeMount;
      final desktopMount = desktop.lifecycle.activeMount;
      await phone.lifecycle.retireAgentExecution();
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(phone.lifecycle.activeMount, same(phoneMount));
      expect(phone.baseCloses, 0);
      expect(phone.ownerCloses, 1);
      expect(await desktop.lifecycle.mountCurrentSession(), isTrue);
      expect(desktop.lifecycle.runtimeRole, AccountRuntimeRole.owner);
      expect(desktop.lifecycle.activeMount, same(desktopMount));
      expect(desktop.baseMounts, 1);
      expect(desktop.lifecycle.canExecuteAgent, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
    },
  );

  test(
    'owner construction expiry rolls back only the late host result',
    () async {
      final phone = await peer(layered: true);
      phone.mountGate = Completer<void>();
      final mounting = phone.login();
      await _flush();
      final mount = phone.lifecycle.activeMount!;
      expect(phone.lifecycle.isMounted, isTrue);
      expect(phone.lifecycle.ownerActivationInProgress, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      server.elapsed = const Duration(seconds: 61);
      phone.authorityTimers.fireShortest();
      expect(phone.lifecycle.ownerActivationInProgress, isFalse);
      expect(phone.lifecycle.storageScopes.isCurrent(mount), isTrue);
      phone.mountGate!.complete();
      expect(await mounting, isTrue);
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(phone.lifecycle.activeMount, same(mount));
      expect(phone.ownerCloses, 1);
      expect(phone.baseCloses, 0);
      expect(phone.coordinator.currentReceipt, isNull);
    },
  );

  test(
    'owner builder failure preserves pages and a later retry mounts only host',
    () async {
      final phone = await peer(layered: true);
      phone.mountError = StateError('host construction failed');
      expect(await phone.login(), isTrue);
      final mount = phone.lifecycle.activeMount;
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(server.lease, isNull);
      phone.mountError = null;
      expect(await phone.lifecycle.mountCurrentSession(), isTrue);
      expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.owner);
      expect(phone.lifecycle.activeMount, same(mount));
      expect(phone.baseMounts, 1);
      expect(phone.mounts, 2);
    },
  );

  test(
    'failed owner drain retains pages and retries cleanup before another owner',
    () async {
      final phone = await peer(layered: true);
      await phone.login();
      final mount = phone.lifecycle.activeMount;
      phone.closeError = StateError('host drain is pending');
      await expectLater(
        phone.lifecycle.retireAgentExecution(),
        throwsStateError,
      );
      await _flush();
      expect(phone.lifecycle.isMounted, isTrue);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(phone.lifecycle.activeMount, same(mount));
      expect(phone.baseCloses, 0);
      expect(await phone.lifecycle.mountCurrentSession(), isTrue);
      expect(phone.mounts, 1);
      expect(phone.ownerCloses, 0);
      phone.closeError = null;
      expect(await phone.lifecycle.mountCurrentSession(), isTrue);
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(phone.ownerCloses, 1);
      expect(phone.mounts, 2);
      expect(phone.baseMounts, 1);
      expect(phone.lifecycle.activeMount, same(mount));
    },
  );

  test(
    'confirmed credential rejection closes the base and returns to login gate',
    () async {
      server.policyError = const AccountDeviceLeaseRequestException(
        statusCode: 401,
        code: 'AUTHENTICATION_REQUIRED',
      );
      final phone = await peer(layered: true);
      expect(await phone.login(), isFalse);
      await _flush();
      expect(phone.lifecycle.isMounted, isFalse);
      expect(phone.lifecycle.hasCompanionRuntime, isFalse);
      expect(phone.lifecycle.requiresStandbyRoute, isFalse);
      expect(phone.auth.candidate, isNull);
      expect(phone.baseCloses, 1);
      expect(phone.mounts, 0);
    },
  );

  test(
    'account sign-out closes owner before base and stale callbacks cannot revive it',
    () async {
      final phone = await peer(layered: true);
      await phone.login();
      final mount = phone.lifecycle.activeMount!;
      final stale = phone.authorityTimers.active.single;
      await phone.lifecycle.signOutAndUnmount();
      expect(phone.closeOrder, ['owner', 'base']);
      expect(phone.lifecycle.storageScopes.isCurrent(mount), isFalse);
      expect(await phone.login(), isTrue);
      final replacement = phone.lifecycle.activeMount!;
      expect(replacement.generation, greaterThan(mount.generation));
      stale.callback();
      expect(phone.lifecycle.activeMount, same(replacement));
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(phone.baseMounts, 2);
    },
  );

  test(
    'held owner heartbeat expiry preserves base while another device takes over',
    () async {
      final delayed = _DelayedLeaseHeartbeatServer();
      server = delayed;
      final timers = _HeartbeatTimers();
      await timers.run(() async {
        final phone = await peer(layered: true);
        final desktop = await peer(layered: true);
        await phone.login();
        await desktop.login();
        final mount = phone.lifecycle.activeMount;
        server.elapsed = const Duration(seconds: 40);
        timers.fireShortest();
        await _flush();
        expect(delayed.heartbeatStarted.isCompleted, isTrue);
        server.elapsed = const Duration(seconds: 61);
        phone.authorityTimers.fireShortest();
        expect(phone.lifecycle.runtimeRole, AccountRuntimeRole.companion);
        expect(phone.lifecycle.activeMount, same(mount));
        expect(phone.baseCloses, 0);
        expect(await desktop.lifecycle.mountCurrentSession(), isTrue);
        final successor = server.lease;
        delayed.heartbeatGate.complete();
        await _flush();
        expect(server.lease, same(successor));
        expect(desktop.lifecycle.canExecuteAgent, isTrue);
        expect(phone.lifecycle.isMounted, isTrue);
        expect(phone.lifecycle.canExecuteAgent, isFalse);
        expect(phone.lifecycle.activeMount, same(mount));
      });
    },
  );

  test(
    'default off keeps legacy behavior and exclusive off rejects missing gateways',
    () async {
      final legacy = await peer(exclusive: false);
      expect(await legacy.login(), isTrue);
      expect(legacy.lifecycle.usesExclusiveDeviceLease, isFalse);
      expect(legacy.lifecycle.canExecuteAgent, isTrue);
      expect(server.acquireCalls, 0);
      expect(server.policyCalls, 0);
      expect(
        () => AccountSessionLifecycleService(
          auth: legacy.auth,
          environment: environment,
          requireExclusiveDeviceLease: true,
          mountRuntime: (_) async => _RuntimeLease(() async {}),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'mounted devices display avatars independently of execution ownership',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      expect(await phone.login(), isTrue);
      expect(await desktop.login(), isTrue);
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(phone.lifecycle.canPresentAvatar, isTrue);
      expect(desktop.lifecycle.canPresentAvatar, isTrue);
      await desktop.lifecycle.signOutAndUnmount();
      expect(desktop.lifecycle.canPresentAvatar, isFalse);
      expect(phone.lifecycle.canPresentAvatar, isTrue);
    },
  );

  test('explicit recovery leaves a valid remote owner untouched', () async {
    final phone = await peer(layered: true);
    final desktop = await peer(layered: true);
    await phone.login();
    await desktop.login();
    final held = server.lease;
    final acquires = server.acquireCalls;

    expect(
      await desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
      isFalse,
    );
    expect(server.currentCalls, 1);
    expect(server.acquireCalls, acquires);
    expect(server.lease, same(held));
    expect(phone.lifecycle.canExecuteAgent, isTrue);
    expect(desktop.lifecycle.runtimeRole, AccountRuntimeRole.companion);
    expect(desktop.mounts, 0);
  });

  test(
    'explicit recovery reacquires expired authority without remounting pages',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      final base = desktop.lifecycle.activeMount;
      final oldEpoch = server.epoch;
      server.elapsed = const Duration(seconds: 61);
      await _flush();
      expect(desktop.mounts, 0, reason: 'expiry does not automatically steal');

      expect(
        await desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        isTrue,
      );
      expect(server.currentCalls, 1);
      expect(server.epoch, oldEpoch + 1);
      expect(desktop.lifecycle.canExecuteAgent, isTrue);
      expect(desktop.lifecycle.canExecuteAgent, isTrue);
      expect(desktop.lifecycle.activeMount, same(base));
      expect(desktop.baseMounts, 1);
      expect(desktop.baseCloses, 0);
      expect(desktop.mounts, 1);
      expect(desktop.lifecycle.leaseConflict, isNull);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      final calls = server.currentCalls;
      expect(
        await desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        isTrue,
      );
      expect(server.currentCalls, calls, reason: 'an owner needs no recovery');
      expect(desktop.mounts, 1);
    },
  );

  test(
    'canonical read failure cannot be mistaken for an inactive lease',
    () async {
      final inspected = _RecoveryInspectionServer();
      server = inspected;
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      final acquires = server.acquireCalls;
      final failure = StateError('current lease unreachable');
      inspected.inspectionError = failure;

      await expectLater(
        desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        throwsA(same(failure)),
      );
      expect(server.acquireCalls, acquires);
      expect(desktop.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.mounts, 0);
    },
  );

  test(
    'a competing acquire after the inactive snapshot wins through CAS',
    () async {
      final inspected = _RecoveryInspectionServer();
      server = inspected;
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      final competitor = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      inspected.beforeCurrentReturns = () async {
        expect(await competitor.login(), isTrue);
      };

      expect(
        await desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        isFalse,
      );
      expect(server.currentCalls, 1);
      expect(competitor.lifecycle.canExecuteAgent, isTrue);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.lifecycle.runtimeRole, AccountRuntimeRole.companion);
      expect(desktop.lifecycle.leaseConflict, isNotNull);
      expect(desktop.mounts, 0);
      expect(phone.lifecycle.canExecuteAgent, isFalse);
    },
  );

  test(
    'a changed account invalidates an in-flight explicit recovery',
    () async {
      final inspected = _RecoveryInspectionServer();
      server = inspected;
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      final acquires = server.acquireCalls;
      inspected.beforeCurrentReturns = () async {
        desktop.auth.stage(accountUuid: 'different-account');
      };

      expect(
        await desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        isFalse,
      );
      expect(server.acquireCalls, acquires);
      expect(desktop.mounts, 0);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
    },
  );

  test(
    'owner mount failure reports failure instead of relay fallback',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      final failure = StateError('owner host could not start');
      desktop.mountError = failure;

      await expectLater(
        desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        throwsA(same(failure)),
      );
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.lifecycle.isMounted, isTrue);
      expect(desktop.baseCloses, 0);
      expect(
        server.lease,
        isNull,
        reason: 'failed host releases exact new lease',
      );
    },
  );
  test(
    'explicit recovery fences an expired owner before its watchdog runs',
    () async {
      final phone = await peer(layered: true);
      await phone.login();
      final base = phone.lifecycle.activeMount;
      final epoch = server.epoch;
      server.elapsed = const Duration(seconds: 61);
      // iOS may deliver a foreground event before overdue Dart timers.
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(phone.ownerCloses, 0);

      expect(
        await phone.lifecycle.recoverCompanionExecutionIfUnowned(),
        isTrue,
      );

      expect(phone.ownerCloses, 1);
      expect(phone.mounts, 2);
      expect(server.epoch, epoch + 1);
      expect(phone.lifecycle.activeMount, same(base));
      expect(phone.baseCloses, 0);
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(phone.lifecycle.canonicalRemoteHolder, isNull);
    },
  );

  test(
    'one recall renews a presence that expired during a long suspension',
    () async {
      final strict = _RecoveryFaultServer();
      server = strict;
      final phone = await peer(layered: true);
      await phone.login();
      final oldPresence = phone.coordinator.currentPresence!;
      server.elapsed = const Duration(minutes: 6);

      expect(
        await phone.lifecycle.recoverCompanionExecutionIfUnowned(),
        isTrue,
      );

      expect(strict.stalePresenceRejections, 1);
      expect(strict.acquisitionRequests, hasLength(3));
      final rejected = strict.acquisitionRequests[1];
      final retried = strict.acquisitionRequests[2];
      expect(rejected.presenceSessionId, oldPresence.presenceSessionId);
      expect(retried.presenceSessionId, isNot(rejected.presenceSessionId));
      expect(retried.requestId, isNot(rejected.requestId));
      expect(retried.holderProof, isNot(rejected.holderProof));
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(phone.baseMounts, 1);
      expect(phone.baseCloses, 0);
    },
  );

  test(
    'repeated stale presence rejection stops after one bounded retry',
    () async {
      final strict = _RecoveryFaultServer();
      server = strict;
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      strict.rejectEveryAcquisitionPresence = true;
      final before = strict.acquisitionRequests.length;

      await expectLater(
        desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        throwsA(
          isA<AccountDeviceLeaseRequestException>().having(
            (error) => error.code,
            'code',
            'STALE_RUNTIME_PRESENCE',
          ),
        ),
      );
      expect(strict.acquisitionRequests.length - before, 2);
      expect(desktop.mounts, 0);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.lifecycle.isMounted, isTrue);
      strict.rejectEveryAcquisitionPresence = false;
    },
  );

  test('recall replays a committed acquire whose response was lost', () async {
    final fault = _RecoveryFaultServer()..loseNextAcquireResponse = true;
    server = fault;
    final phone = await peer(layered: true);
    await phone.login();
    final committed = server.lease!;
    expect(phone.lifecycle.canExecuteAgent, isFalse);
    expect(phone.coordinator.hasPendingAcquire, isTrue);
    expect(phone.mounts, 0);

    expect(await phone.lifecycle.recoverCompanionExecutionIfUnowned(), isTrue);

    expect(fault.acquisitionRequests, hasLength(2));
    expect(
      fault.acquisitionRequests.last.requestId,
      fault.acquisitionRequests.first.requestId,
    );
    expect(
      fault.acquisitionRequests.last.holderProof,
      fault.acquisitionRequests.first.holderProof,
    );
    expect(server.lease!.leaseId, committed.leaseId);
    expect(server.lease!.epoch, committed.epoch);
    expect(phone.coordinator.hasPendingAcquire, isFalse);
    expect(phone.lifecycle.canExecuteAgent, isTrue);
    expect(phone.mounts, 1);
  });

  test(
    'recall retries its retained exact release before classifying remote owner',
    () async {
      final fault = _RecoveryFaultServer();
      server = fault;
      final phone = await peer(layered: true);
      await phone.login();
      final old = server.lease!;
      fault.releaseFailuresRemaining = 1;
      server.elapsed = const Duration(seconds: 56);
      phone.authorityTimers.fireShortest();
      await _flush();
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(phone.coordinator.currentReceipt, same(old));
      expect(server.lease, same(old), reason: 'server TTL is still live');
      expect(fault.releaseRequests, hasLength(1));

      expect(
        await phone.lifecycle.recoverCompanionExecutionIfUnowned(),
        isTrue,
      );

      expect(fault.releaseRequests, hasLength(2));
      expect(
        fault.releaseRequests[1],
        fault.releaseRequests[0],
        reason: 'retry must retain exact release identity and request',
      );
      expect(server.lease!.epoch, old.epoch + 1);
      expect(
        phone.ownerCloses,
        1,
        reason: 'successful local drain is not repeated',
      );
      expect(phone.lifecycle.canonicalRemoteHolder, isNull);
    },
  );

  test(
    'a live other runtime is exclusive even with the same installation',
    () async {
      final phone = await peer(layered: true, installationStoreId: 7);
      final desktop = await peer(layered: true, installationStoreId: 7);
      await phone.login();
      await desktop.login();
      final owner = server.lease!;
      expect(
        desktop.coordinator.currentPresence!.installationId,
        owner.installationId,
      );
      expect(
        desktop.coordinator.currentPresence!.runtimeInstanceId,
        isNot(owner.runtimeInstanceId),
      );
      final acquires = server.acquireCalls;

      expect(
        await desktop.lifecycle.recoverCompanionExecutionIfUnowned(),
        isFalse,
      );
      desktop.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(desktop);

      expect(server.acquireCalls, acquires);
      expect(server.lease, same(owner));
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(
        desktop.lifecycle.canonicalRemoteHolder,
        isNull,
        reason: 'another process on this installation is not another device',
      );
    },
  );

  test(
    'foreground automatically restores the sole phone after lock-screen expiry',
    () async {
      final phone = await peer(layered: true);
      await phone.login();
      final mount = phone.lifecycle.activeMount;
      phone.lifecycle.updateApplicationPresence(foreground: false);
      server.elapsed = const Duration(seconds: 61);
      phone.authorityTimers.fireShortest();
      await _flush();
      expect(phone.lifecycle.canExecuteAgent, isFalse);
      expect(phone.recoveryTimers.active, isEmpty);

      phone.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(phone);

      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(phone.lifecycle.activeMount, same(mount));
      expect(phone.baseMounts, 1);
      expect(phone.baseCloses, 0);
      expect(phone.lifecycle.presenceRecoveryInProgress, isFalse);
    },
  );

  test(
    'background cancels automatic recovery including an already queued timer',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      desktop.lifecycle.updateApplicationPresence(foreground: true);
      await _flush();
      final callbacks = desktop.recoveryTimers.active
          .map((timer) => timer.callback)
          .toList(growable: false);
      expect(callbacks, isNotEmpty);
      final acquires = server.acquireCalls;
      final inspections = server.currentCalls;
      desktop.lifecycle.updateApplicationPresence(foreground: false);
      server.elapsed = const Duration(seconds: 61);
      for (final callback in callbacks) {
        callback();
      }
      await _flush();

      expect(desktop.recoveryTimers.active, isEmpty);
      expect(server.acquireCalls, acquires);
      expect(server.currentCalls, inspections);
      expect(desktop.mounts, 0);
    },
  );

  test(
    'handoff in progress suppresses automatic recovery until it settles',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      final acquires = server.acquireCalls;
      desktop.lifecycle.updateApplicationPresence(
        foreground: true,
        handoffInProgress: true,
      );
      await _flush();
      expect(desktop.recoveryTimers.active, isEmpty);
      expect(server.acquireCalls, acquires);
      expect(desktop.mounts, 0);

      desktop.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(desktop);
      expect(desktop.lifecycle.canExecuteAgent, isTrue);
      expect(server.acquireCalls, acquires + 1);
    },
  );

  test(
    'background during canonical lookup cancels automatic acquisition',
    () async {
      final inspected = _RecoveryInspectionServer();
      server = inspected;
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      final entered = Completer<void>();
      final gate = Completer<void>();
      inspected.beforeCurrentReturns = () async {
        if (!entered.isCompleted) entered.complete();
        await gate.future;
      };
      final acquires = server.acquireCalls;
      desktop.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(desktop);
      expect(entered.isCompleted, isTrue);
      expect(desktop.lifecycle.presenceRecoveryInProgress, isTrue);
      desktop.lifecycle.updateApplicationPresence(foreground: false);
      gate.complete();
      await _flush();

      expect(server.acquireCalls, acquires);
      expect(desktop.mounts, 0);
      expect(desktop.lifecycle.presenceRecoveryInProgress, isFalse);
      expect(desktop.recoveryTimers.active, isEmpty);
    },
  );

  for (final handoffStarts in <bool>[false, true]) {
    test('late automatic acquire cannot activate after '
        '${handoffStarts ? 'handoff starts' : 'backgrounding'}', () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      server.elapsed = const Duration(seconds: 61);
      final before = server.acquireCalls;
      final gate = Completer<void>();
      server.acquireGate = gate;
      desktop.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(desktop);
      expect(
        server.acquireCalls,
        before + 1,
        reason: 'canonical check passed and CAS request is already in flight',
      );
      expect(desktop.lifecycle.presenceRecoveryInProgress, isTrue);
      expect(desktop.mounts, 0);

      desktop.lifecycle.updateApplicationPresence(
        foreground: handoffStarts,
        handoffInProgress: handoffStarts,
      );
      gate.complete();
      server.acquireGate = null;
      await _flush();

      expect(
        desktop.mounts,
        0,
        reason: 'a cancelled automatic request must not construct an owner',
      );
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(
        server.lease,
        isNull,
        reason: 'late exact authority must be released after cancellation',
      );
      expect(desktop.lifecycle.presenceRecoveryInProgress, isFalse);
      expect(desktop.recoveryTimers.active, isEmpty);
    });
  }

  for (final handoffStarts in <bool>[false, true]) {
    test('late automatic owner load rolls back after '
        '${handoffStarts ? 'handoff starts' : 'backgrounding'}', () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      final base = desktop.lifecycle.activeMount;
      server.elapsed = const Duration(seconds: 61);
      final gate = Completer<void>();
      desktop.mountGate = gate;
      desktop.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(desktop);
      expect(desktop.mounts, 1, reason: 'the owner is already being loaded');
      expect(desktop.lifecycle.presenceRecoveryInProgress, isTrue);
      expect(
        desktop.lifecycle.canExecuteAgent,
        isFalse,
        reason: 'construction is not publication',
      );
      expect(server.lease, isNotNull);

      desktop.lifecycle.updateApplicationPresence(
        foreground: handoffStarts,
        handoffInProgress: handoffStarts,
      );
      gate.complete();
      desktop.mountGate = null;
      await _flush();

      expect(desktop.mounts, 1);
      expect(
        desktop.ownerCloses,
        1,
        reason: 'late owner construction must be drained before publication',
      );
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.lifecycle.activeMount, same(base));
      expect(desktop.baseCloses, 0);
      expect(server.lease, isNull);
      expect(desktop.lifecycle.presenceRecoveryInProgress, isFalse);
      expect(desktop.recoveryTimers.active, isEmpty);
    });
  }

  test(
    'expired access token refreshes before recovery without replacing pages',
    () async {
      final phone = await peer(layered: true);
      await phone.login();
      final mount = phone.lifecycle.activeMount;
      phone.auth.stage(
        expiresAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      await phone.auth.publishCandidate();
      final expiredCandidate = phone.auth.candidate;
      expect(expiredCandidate!.session.isValid, isFalse);
      server.elapsed = const Duration(seconds: 61);

      expect(
        await phone.lifecycle.recoverCompanionExecutionIfUnowned(),
        isTrue,
      );

      expect(phone.auth.refreshCalls, 1);
      expect(phone.auth.candidate, isNot(same(expiredCandidate)));
      expect(phone.auth.candidate!.session.isValid, isTrue);
      expect(phone.auth.session.value, same(phone.auth.candidate!.session));
      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(phone.lifecycle.activeMount, same(mount));
      expect(phone.baseMounts, 1);
      expect(phone.baseCloses, 0);
      expect(phone.mounts, 2);
    },
  );

  test(
    'account change during refresh cancels recovery before acquiring',
    () async {
      final phone = await peer(layered: true);
      final desktop = await peer(layered: true);
      await phone.login();
      await desktop.login();
      desktop.auth.stage(
        expiresAt: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      await desktop.auth.publishCandidate();
      server.elapsed = const Duration(seconds: 61);
      final acquires = server.acquireCalls;
      final gate = Completer<void>();
      desktop.auth.refreshGate = gate;
      final recovery = desktop.lifecycle.recoverCompanionExecutionIfUnowned();
      await _flush();
      expect(desktop.auth.refreshCalls, 1);
      expect(server.acquireCalls, acquires);

      desktop.auth.stage(accountUuid: 'different-account');
      gate.complete();
      desktop.auth.refreshGate = null;
      expect(await recovery, isFalse);

      expect(server.acquireCalls, acquires);
      expect(desktop.mounts, 0);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.auth.candidate!.session.accountUuid, 'different-account');
      expect(desktop.lifecycle.presenceRecoveryInProgress, isFalse);
    },
  );

  test(
    'application exit releases owner and foreground companion takes over',
    () async {
      final desktop = await peer(layered: true);
      final phone = await peer(layered: true);
      await desktop.login();
      await phone.login();
      final epoch = server.epoch;
      phone.lifecycle.updateApplicationPresence(foreground: true);
      await _fireRecovery(phone);
      expect(phone.lifecycle.canExecuteAgent, isFalse);

      await desktop.lifecycle.prepareForApplicationExit();
      expect(server.lease, isNull);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(desktop.recoveryTimers.active, isEmpty);
      await _fireRecovery(phone);

      expect(phone.lifecycle.canExecuteAgent, isTrue);
      expect(server.epoch, epoch + 1);
      expect(desktop.lifecycle.canExecuteAgent, isFalse);
      expect(phone.baseMounts, 1);
    },
  );
}

Future<void> _fireRecovery(_Peer peer) async {
  await _flush();
  if (peer.recoveryTimers.active.isNotEmpty) {
    peer.recoveryTimers.fireShortest();
    await _flush();
  }
}

Future<void> _flush() async {
  for (var i = 0; i < 15; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class _Peer {
  _Peer(this.auth, this.coordinator, this.discovery);
  final _Auth auth;
  final AccountDeviceLeaseCoordinator coordinator;
  final _Discovery discovery;
  late AccountSessionLifecycleService lifecycle;
  final policyTimers = _Timers();
  final presenceTimers = _Timers();
  final authorityTimers = _Timers();
  final recoveryTimers = _Timers();
  int mounts = 0;
  int baseMounts = 0;
  int baseCloses = 0;
  int ownerCloses = 0;
  int fences = 0;
  bool activatedInsideOwnerCallback = false;
  final closeOrder = <String>[];
  Completer<void>? closeGate;
  Completer<void>? mountGate;
  Object? mountError;
  Object? closeError;

  static Future<_Peer> create(
    int id,
    _ExclusiveServer server,
    AppEnvironmentService environment, {
    required AccountRuntimeAuthorityMode mode,
    required bool exclusive,
    required bool layered,
    int? installationStoreId,
  }) async {
    final identity = AppInstallationIdentityService(
      store: _IdentityStore(installationStoreId ?? id),
      randomBytes: _Entropy(id * 30).bytes,
    );
    await identity.init();
    final auth = _Auth(environment);
    final coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: server,
      randomBytes: _Entropy(id * 50).bytes,
      monotonicNow: () => server.elapsed,
      wallClock: () => server.now,
    );
    final peer = _Peer(auth, coordinator, _Discovery());
    peer.lifecycle = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      deviceLeaseCoordinator: coordinator,
      authorityPolicyGateway: server,
      runtimeDiscovery: peer.discovery,
      authorityCompileMaximum: mode,
      requireExclusiveDeviceLease: exclusive,
      deviceLabel: 'device-$id',
      devicePlatform: id == 1 ? 'ios' : 'macos',
      authorityWatchdogFactory: peer.authorityTimers.create,
      policyWatchdogFactory: peer.policyTimers.create,
      shadowWatchdogFactory: peer.presenceTimers.create,
      recoveryWatchdogFactory: peer.recoveryTimers.create,
      policyMonotonicNow: () => server.elapsed,
      policyWallClock: () => server.now,
      fenceRuntime: () async {
        peer.fences++;
      },
      mountCompanionRuntime: !layered
          ? null
          : (_) async {
              peer.baseMounts++;
              return _RuntimeLease(() async {
                peer.baseCloses++;
                peer.closeOrder.add('base');
              });
            },
      mountRuntime: (_) async {
        peer.mounts++;
        peer.activatedInsideOwnerCallback =
            peer.lifecycle.ownerActivationInProgress;
        await peer.mountGate?.future;
        if (peer.mountError != null) throw peer.mountError!;
        return _RuntimeLease(() async {
          await peer.closeGate?.future;
          if (peer.closeError != null) throw peer.closeError!;
          peer.ownerCloses++;
          peer.closeOrder.add('owner');
        });
      },
    );
    return peer;
  }

  Future<bool> login() =>
      lifecycle.authenticateAndMount(() async => auth.stage());
}

class _Auth extends AuthSessionService {
  _Auth(this.environment);
  final AppEnvironmentService environment;
  MaasoAuthCandidate? _candidate;
  int refreshCalls = 0;
  Completer<void>? refreshGate;
  @override
  MaasoAuthCandidate? get candidate => _candidate;
  @override
  Future<bool> restoreCandidate() async {
    stage();
    return true;
  }

  @override
  Future<bool> restoreOrRefresh() async {
    final before = _candidate;
    if (before == null || !identical(session.value, before.session))
      return false;
    if (before.session.isValid) return true;
    refreshCalls++;
    await refreshGate?.future;
    // Mimic production refresh's operation/account/environment fencing. An
    // intervening authentication must not be overwritten by its late response.
    if (!identical(_candidate, before) ||
        environment.environment.value != before.environment)
      return false;
    stage(accountUuid: before.session.accountUuid);
    await publishCandidate();
    return true;
  }

  void stage({String accountUuid = 'same-account', DateTime? expiresAt}) {
    _candidate = MaasoAuthCandidate(
      environment: environment.environment.value,
      session: MaasoAuthSession(
        accountUuid: accountUuid,
        accessToken: 'test-access',
        refreshToken: 'test-refresh',
        expiresAt: expiresAt ?? DateTime.now().add(const Duration(hours: 1)),
      ),
      operationEpoch: 1,
      logoutFence: const AuthLogoutPendingSnapshot(
        pending: false,
        revision: 1,
        token: 'cleared',
      ),
    );
  }

  @override
  Future<void> publishCandidate([MaasoAuthCandidate? expected]) async {
    if (_candidate == null ||
        (expected != null && !identical(expected, _candidate))) {
      throw StateError('candidate changed');
    }
    session.value = _candidate!.session;
  }

  @override
  Future<void> unpublishSession() async {
    session.value = null;
  }

  @override
  Future<void> signOut() async {
    _candidate = null;
    session.value = null;
  }
}

class _RuntimeLease implements AccountRuntimeLease {
  _RuntimeLease(this.closeWork);
  final Future<void> Function() closeWork;
  @override
  Future<void> close() => closeWork();
}

class _Discovery implements AccountRuntimeDiscoveryService {
  bool observing = false;
  @override
  bool get isObserving => observing;
  @override
  void start({
    required MaasoEnvironment environment,
    required String accountUuid,
  }) {
    observing = true;
  }

  @override
  void stop() {
    observing = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _IdentityStore implements AppInstallationIdentityStore {
  _IdentityStore(this.id);
  final int id;
  @override
  Future<String?> read(String key) async =>
      id.toRadixString(16).padLeft(32, '0');
  @override
  Future<bool> write(String key, String value) async => true;
}

class _MemorySecureStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

class _Entropy {
  _Entropy(this.seed);
  int seed;
  List<int> bytes(int length) {
    final current = seed++;
    return List.generate(length, (i) => (current + i) & 255);
  }
}

class _Timers {
  final timers = <_Timer>[];
  List<_Timer> get active => timers.where((t) => t.isActive).toList();
  Timer create(Duration delay, void Function() callback) {
    final timer = _Timer(delay, callback);
    timers.add(timer);
    return timer;
  }

  void fireShortest() {
    final sorted = active..sort((a, b) => a.delay.compareTo(b.delay));
    expect(sorted, isNotEmpty);
    sorted.first.fire();
  }

  void fireLongest() {
    final sorted = active..sort((a, b) => a.delay.compareTo(b.delay));
    expect(sorted, isNotEmpty);
    sorted.last.fire();
  }
}

class _Timer implements Timer {
  _Timer(this.delay, this.callback);
  final Duration delay;
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => _active ? 0 : 1;
  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (_active) {
      _active = false;
      callback();
    }
  }
}

/// Two real coordinators share this CAS state; conflicts are determined from
/// the current owner and expiry, not injected independently for each device.
class _ExclusiveServer
    implements AccountDeviceLeaseGateway, AccountRuntimeAuthorityPolicyGateway {
  Duration elapsed = Duration.zero;
  DateTime get now => DateTime.utc(2026, 9, 8).add(elapsed);
  AccountRuntimeAuthorityMode mode = AccountRuntimeAuthorityMode.off;
  int revision = 1;
  Duration policyTtl = const Duration(minutes: 5);
  Object? policyError;
  Completer<void>? acquireGate;
  final presences = <String, AccountDevicePresenceReceipt>{};
  AccountDeviceLeaseReceipt? lease;
  String? proof;
  int epoch = 0;
  int acquireCalls = 0;
  int currentCalls = 0;
  int releaseCalls = 0;
  int policyCalls = 0;
  int presenceHeartbeats = 0;
  int leaseHeartbeats = 0;

  void expire() {
    if (lease != null && !now.isBefore(lease!.expiresAt)) {
      lease = null;
      proof = null;
    }
  }

  @override
  Future<AccountRuntimeAuthorityPolicy> fetchRuntimeAuthorityPolicy({
    required MaasoEnvironment environment,
    required String accountUuid,
  }) async {
    policyCalls++;
    if (policyError != null) throw policyError!;
    return AccountRuntimeAuthorityPolicy(
      mode: mode,
      revision: revision,
      expiresAt: now.add(policyTtl),
      remainingTtl: policyTtl,
      pollAfter: const Duration(seconds: 1),
    );
  }

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
    final receipt = AccountDevicePresenceReceipt(
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: 'presence-$runtimeInstanceId',
      generation: 1,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      openedAt: now,
      lastSeenAt: now,
      expiresAt: now.add(const Duration(minutes: 5)),
      remainingTtl: const Duration(minutes: 5),
      renewAfter: const Duration(seconds: 20),
    );
    presences[receipt.presenceSessionId] = receipt;
    return AccountDevicePresenceOperationResult(
      presence: receipt,
      replayed: false,
    );
  }

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    presenceHeartbeats++;
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: false,
    );
  }

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    presences.remove(presence.presenceSessionId);
    return AccountDevicePresenceCloseResult(
      closed: true,
      stale: false,
      generation: presence.generation,
    );
  }

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async {
    currentCalls++;
    expire();
    return AccountDeviceLeaseSnapshot(
      state: lease == null
          ? AccountDeviceLeaseRemoteState.inactive
          : AccountDeviceLeaseRemoteState.active,
      lease: lease,
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
    acquireCalls++;
    await acquireGate?.future;
    expire();
    final held = lease;
    if (held != null) {
      if (held.runtimeInstanceId == runtimeInstanceId && holderProof == proof) {
        return AccountDeviceLeaseOperationResult(lease: held, replayed: true);
      }
      throw AccountDeviceLeaseConflict(
        observedEpoch: held.epoch,
        holder: held.holder,
        expiresAt: held.expiresAt,
        remainingTtl: held.expiresAt.difference(now),
      );
    }
    epoch++;
    proof = holderProof;
    final presence = presences[presenceSessionId]!;
    lease = AccountDeviceLeaseReceipt(
      agentId: agentId,
      leaseId: 'lease-$epoch',
      epoch: epoch,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      expiresAt: now.add(const Duration(seconds: 60)),
      remainingTtl: const Duration(seconds: 60),
      renewAfter: const Duration(seconds: 40),
      holder: AccountDeviceLeaseHolder(
        installationId: installationId,
        runtimeInstanceId: runtimeInstanceId,
        presenceSessionId: presenceSessionId,
        deviceLabel: presence.deviceLabel,
        platform: presence.platform,
        lastSeenAt: now,
      ),
    );
    return AccountDeviceLeaseOperationResult(lease: lease!, replayed: false);
  }

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    leaseHeartbeats++;
    expire();
    if (this.lease?.epoch != lease.epoch || holderProof != proof) {
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_LEASE',
      );
    }
    return AccountDeviceLeaseOperationResult(
      lease: this.lease!,
      replayed: false,
    );
  }

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    releaseCalls++;
    expire();
    final exact = this.lease?.epoch == lease.epoch && holderProof == proof;
    if (exact) {
      this.lease = null;
      proof = null;
    }
    return AccountDeviceLeaseReleaseResult(
      released: exact,
      stale: !exact,
      epoch: epoch,
    );
  }
}

class _RecoveryInspectionServer extends _ExclusiveServer {
  Object? inspectionError;
  Future<void> Function()? beforeCurrentReturns;

  @override
  Future<AccountDeviceLeaseSnapshot> currentLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required String agentId,
  }) async {
    if (inspectionError != null) throw inspectionError!;
    final snapshot = await super.currentLease(
      environment: environment,
      accountUuid: accountUuid,
      agentId: agentId,
    );
    await beforeCurrentReturns?.call();
    return snapshot;
  }
}

/// Strict server behavior missing from the baseline CAS fake: presence TTL,
/// successful requests with lost responses, and exact-release retry identity.
class _RecoveryFaultServer extends _RecoveryInspectionServer {
  int _presenceSequence = 0;
  int stalePresenceRejections = 0;
  bool rejectEveryAcquisitionPresence = false;
  bool loseNextAcquireResponse = false;
  int releaseFailuresRemaining = 0;
  final acquisitionRequests =
      <({String presenceSessionId, String requestId, String holderProof})>[];
  final releaseRequests = <({String leaseId, int epoch, String requestId})>[];

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
    final result = await super.openPresence(
      environment: environment,
      accountUuid: accountUuid,
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      deviceLabel: deviceLabel,
      platform: platform,
      appVersion: appVersion,
      requestId: requestId,
    );
    final previous = result.presence;
    presences.remove(previous.presenceSessionId);
    final fresh = AccountDevicePresenceReceipt(
      agentId: previous.agentId,
      installationId: previous.installationId,
      runtimeInstanceId: previous.runtimeInstanceId,
      presenceSessionId: '${previous.presenceSessionId}-${++_presenceSequence}',
      generation: _presenceSequence,
      deviceLabel: previous.deviceLabel,
      platform: previous.platform,
      appVersion: previous.appVersion,
      openedAt: previous.openedAt,
      lastSeenAt: previous.lastSeenAt,
      expiresAt: previous.expiresAt,
      remainingTtl: previous.remainingTtl,
      renewAfter: previous.renewAfter,
    );
    presences[fresh.presenceSessionId] = fresh;
    return AccountDevicePresenceOperationResult(
      presence: fresh,
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
    acquisitionRequests.add((
      presenceSessionId: presenceSessionId,
      requestId: requestId,
      holderProof: holderProof,
    ));
    final presence = presences[presenceSessionId];
    if (rejectEveryAcquisitionPresence ||
        presence == null ||
        !now.isBefore(presence.expiresAt)) {
      stalePresenceRejections++;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_PRESENCE',
      );
    }
    final result = await super.acquireLease(
      environment: environment,
      accountUuid: accountUuid,
      agentId: agentId,
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
      holderProof: holderProof,
      requestId: requestId,
    );
    if (loseNextAcquireResponse) {
      loseNextAcquireResponse = false;
      throw StateError('acquire response lost after server commit');
    }
    return result;
  }

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    releaseRequests.add((
      leaseId: lease.leaseId,
      epoch: lease.epoch,
      requestId: requestId,
    ));
    if (releaseFailuresRemaining > 0) {
      releaseFailuresRemaining--;
      throw StateError('exact release temporarily unreachable');
    }
    return super.releaseLease(
      environment: environment,
      accountUuid: accountUuid,
      lease: lease,
      holderProof: holderProof,
      requestId: requestId,
    );
  }
}

class _DelayedLeaseHeartbeatServer extends _ExclusiveServer {
  final heartbeatStarted = Completer<void>();
  final heartbeatGate = Completer<void>();

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    heartbeatStarted.complete();
    await heartbeatGate.future;
    return super.heartbeatLease(
      environment: environment,
      accountUuid: accountUuid,
      lease: lease,
      holderProof: holderProof,
      requestId: requestId,
    );
  }
}

class _RenewingLeaseHeartbeatServer extends _ExclusiveServer {
  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    final result = await super.heartbeatLease(
      environment: environment,
      accountUuid: accountUuid,
      lease: lease,
      holderProof: holderProof,
      requestId: requestId,
    );
    final held = result.lease;
    final renewed = AccountDeviceLeaseReceipt(
      agentId: held.agentId,
      leaseId: held.leaseId,
      epoch: held.epoch,
      installationId: held.installationId,
      runtimeInstanceId: held.runtimeInstanceId,
      presenceSessionId: held.presenceSessionId,
      expiresAt: now.add(const Duration(seconds: 60)),
      remainingTtl: const Duration(seconds: 60),
      renewAfter: const Duration(seconds: 40),
      holder: held.holder,
    );
    this.lease = renewed;
    return AccountDeviceLeaseOperationResult(lease: renewed, replayed: false);
  }
}

/// Controls only the production renewal timer; asynchronous HTTP/queue futures
/// stay in the ordinary event loop so this test does not depend on widget clocks.
class _HeartbeatTimers extends _Timers {
  Future<T> run<T>(Future<T> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration == const Duration(seconds: 40)) {
          return create(duration, zone.bindCallback(callback));
        }
        return parent.createTimer(zone, duration, callback);
      },
    ),
  );
}

class _CompanionTransferredHandoff implements AccountDeviceHandoffGateway {
  _CompanionTransferredHandoff(this.server, this.target)
    : source = server.lease!;
  final _ExclusiveServer server;
  final AccountDevicePresenceReceipt target;
  final AccountDeviceLeaseReceipt source;
  String? targetProof;
  AccountDeviceLeaseReceipt? transferred;

  void commit() {
    final holder = AccountDeviceLeaseHolder(
      installationId: target.installationId,
      runtimeInstanceId: target.runtimeInstanceId,
      presenceSessionId: target.presenceSessionId,
      deviceLabel: target.deviceLabel,
      platform: target.platform,
      lastSeenAt: server.now,
    );
    transferred = AccountDeviceLeaseReceipt(
      agentId: 'self',
      leaseId: 'transferred-companion-lease',
      epoch: ++server.epoch,
      installationId: target.installationId,
      runtimeInstanceId: target.runtimeInstanceId,
      presenceSessionId: target.presenceSessionId,
      expiresAt: server.now.add(const Duration(seconds: 60)),
      remainingTtl: const Duration(seconds: 60),
      renewAfter: const Duration(seconds: 40),
      holder: holder,
    );
    server.lease = transferred;
    server.proof = targetProof;
  }

  AccountDeviceHandoff view(AccountHandoffState state) => AccountDeviceHandoff(
    handoffId: 'companion-handoff',
    agentId: 'self',
    state: state,
    sourceLeaseId: source.leaseId,
    sourceEpoch: source.epoch,
    sourcePresenceSessionId: source.presenceSessionId,
    sourceRuntimeInstanceId: source.runtimeInstanceId,
    targetPresenceSessionId: target.presenceSessionId,
    targetRuntimeInstanceId: target.runtimeInstanceId,
    avatarModel: HandoffAvatarIdentity(modelId: 'avatar-self', revision: '1'),
    createdAt: server.now,
    expiresAt: server.now.add(const Duration(minutes: 1)),
    remainingTtl: const Duration(minutes: 1),
    lease: state == AccountHandoffState.accepted ? transferred : null,
  );

  @override
  Future<AccountHandoffResult> handoffCommand({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountHandoffCommand command,
    required Map<String, Object?> body,
    String? handoffId,
  }) async {
    expect(command, AccountHandoffCommand.targetReady);
    targetProof = body['holderProof'] as String;
    return AccountHandoffResult(
      handoff: view(AccountHandoffState.targetReady),
      replayed: false,
    );
  }

  @override
  Future<AccountHandoffResult> currentHandoff({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    String? handoffId,
  }) async => AccountHandoffResult(
    handoff: view(AccountHandoffState.accepted),
    replayed: false,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
