import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/models/account_runtime_authority_policy.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/account_device_lease_transport.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/app_installation_identity_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/startup_route_service.dart';
import 'package:maaso/src/features/auth/presentation/account_standby_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> events;
  late AppEnvironmentService environment;
  late _LifecycleAuthSessionService auth;
  late _LifecycleLeaseGateway gateway;
  late AccountDeviceLeaseCoordinator coordinator;
  late _ManualWatchdogFactory watchdogs;
  late _ManualWatchdogFactory policyWatchdogs;
  late _ManualWatchdogFactory shadowWatchdogs;
  late Duration monotonicNow;
  late DateTime policyWallNow;
  AccountSessionLifecycleService? lifecycle;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    events = <String>[];
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    environment = appServices.put(AppEnvironmentService());
    await environment.init();
    auth = _LifecycleAuthSessionService(events);
    appServices.put<AuthSessionService>(auth);
    final identity = AppInstallationIdentityService(
      store: _MemoryInstallationIdentityStore(),
      randomBytes: _Entropy().bytes,
    );
    await identity.init();
    gateway = _LifecycleLeaseGateway(events);
    watchdogs = _ManualWatchdogFactory();
    policyWatchdogs = _ManualWatchdogFactory();
    shadowWatchdogs = _ManualWatchdogFactory();
    monotonicNow = Duration.zero;
    policyWallNow = _wallNow;
    coordinator = AccountDeviceLeaseCoordinator(
      identity: identity,
      gateway: gateway,
      randomBytes: _Entropy().bytes,
      monotonicNow: () => monotonicNow,
      wallClock: () => _wallNow,
    );
  });

  tearDown(() async {
    final current = lifecycle;
    if (current != null) {
      try {
        await current.signOutAndUnmount();
      } catch (_) {
        try {
          await current.retryFaultedCleanup();
        } catch (_) {
          // Failure tests assert retained state before making retries succeed.
        }
      }
      current.closeLifecycle();
    }
    if (coordinator.state != AccountDeviceLeaseCoordinatorState.closed &&
        coordinator.currentReceipt == null) {
      coordinator.close();
    }
    await appServices.reset();
  });

  AccountSessionLifecycleService buildLifecycle({
    required Future<AccountRuntimeLease> Function() mountRuntime,
    AccountRuntimeFenceCallback? fenceRuntime,
    AccountRuntimeBoundaryActivateCallback? activateRuntimeBoundary,
    AccountRuntimeBoundaryRetireCallback? retireRuntimeBoundary,
    AccountRuntimeAuthorityMode authorityCompileMaximum =
        AccountRuntimeAuthorityMode.enforce,
    AccountRuntimeAuthorityPolicyGateway? authorityPolicyGateway,
  }) {
    final result = AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      deviceLeaseCoordinator: coordinator,
      authorityPolicyGateway: authorityPolicyGateway ?? gateway,
      authorityCompileMaximum: authorityCompileMaximum,
      deviceLabel: 'Test Mac',
      devicePlatform: 'macos',
      appVersion: '1.0.0',
      fenceRuntime: fenceRuntime,
      activateRuntimeBoundary: activateRuntimeBoundary,
      retireRuntimeBoundary: retireRuntimeBoundary,
      authorityWatchdogFactory: watchdogs.create,
      policyWatchdogFactory: policyWatchdogs.create,
      shadowWatchdogFactory: shadowWatchdogs.create,
      policyWallClock: () => policyWallNow,
      policyMonotonicNow: () => monotonicNow,
      mountRuntime: (_) => mountRuntime(),
    );
    lifecycle = appServices.put(result);
    return result;
  }

  test('standby is registered as an internal non-destination route', () {
    expect(appRoutePaths, contains(AppRoutes.accountStandby));
    expect(
      AppRoutes.destinations.any(
        (destination) => destination.route == AppRoutes.accountStandby,
      ),
      isFalse,
    );
  });

  test(
    'handoff quiesces producers while retaining exact source authority and presence',
    () async {
      final drain = Completer<void>();
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
        fenceRuntime: () {
          events.add('handoffDrain');
          return drain.future;
        },
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      final source = coordinator.currentReceipt;
      final presence = coordinator.currentPresence;
      final pending = service.quiesceForDeviceHandoff();
      await pumpEventQueue();
      expect(events, contains('handoffDrain'));
      expect(gateway.releaseCalls, 0);
      expect(coordinator.currentReceipt, same(source));
      expect(coordinator.canAdmitMutations, isTrue);
      drain.complete();
      await pending;
      await service.unmount();
      expect(gateway.releaseCalls, 1);
      expect(coordinator.currentPresence, same(presence));
      expect(service.requiresStandbyRoute, isTrue);
    },
  );

  test(
    'cancelled handoff replaces sealed account runtime under a fresh acquisition',
    () async {
      var mounts = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mounts++;
          return _RecordingRuntimeLease(events);
        },
        fenceRuntime: () async {
          events.add('handoffDrain');
        },
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      final oldProof = gateway.acquiredProof;
      await service.quiesceForDeviceHandoff();
      expect(await service.restoreCancelledHandoff(), isTrue);
      expect(mounts, 2);
      expect(gateway.releaseCalls, 1);
      expect(gateway.acquireCalls, 2);
      expect(gateway.acquiredProof, isNot(oldProof));
      expect(
        events,
        containsAllInOrder([
          'handoffDrain',
          'runtimeClose',
          'leaseRelease',
          'leaseAcquire',
        ]),
      );
    },
  );

  test(
    'transferred target mounts the committed lease without a second acquire',
    () async {
      gateway.conflictOnAcquire = true;
      var mounts = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mounts++;
          expect(coordinator.currentReceipt?.leaseId, 'transferred-lease');
          return _RecordingRuntimeLease(events);
        },
      );
      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isFalse,
      );
      final presence = coordinator.currentPresence!;
      final base = _lease(
        installationId: presence.installationId,
        runtimeInstanceId: presence.runtimeInstanceId,
        presenceSessionId: presence.presenceSessionId,
      );
      final transferred = AccountDeviceLeaseReceipt.fromJson({
        ...base.toJson(),
        'leaseId': 'transferred-lease',
        'epoch': 8,
      });
      final handoffGateway = _TransferredHandoffGateway(presence, transferred);
      await service.serializeDeviceHandoff(
        () => coordinator.acknowledgeHandoffReady(
          handoffGateway,
          handoff: handoffGateway.view(AccountHandoffState.prepared),
          requestId: 'ready-request',
        ),
      );
      gateway.lease = transferred;
      await service.serializeDeviceHandoff(
        () => coordinator.adoptTargetHandoff(
          handoffGateway,
          handoffId: 'handoff-test',
        ),
      );
      expect(coordinator.hasTransferredLeaseAwaitingMount, isTrue);
      expect(await service.mountTransferredHandoff(), isTrue);
      expect(mounts, 1);
      expect(
        gateway.acquireCalls,
        1,
        reason: 'The only acquisition is the initial conflict.',
      );
      expect(coordinator.hasTransferredLeaseAwaitingMount, isFalse);
      expect(auth.session.value, isNotNull);
      expect(service.isMounted, isTrue);
    },
  );

  test(
    'handoff mutations and ordinary mount revalidation share one queue',
    () async {
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      final gate = Completer<void>();
      final pending = service.serializeDeviceHandoff(() async {
        events.add('handoffNetwork');
        await gate.future;
      });
      final revalidate = service.mountCurrentSession();
      await pumpEventQueue();
      expect(gateway.leaseHeartbeatCalls, 0);
      gate.complete();
      await pending;
      expect(await revalidate, isTrue);
      expect(gateway.leaseHeartbeatCalls, 1);
      expect(coordinator.canAdmitMutations, isTrue);
    },
  );

  test(
    'standby and legacy mode cannot quiesce or mount a transferred runtime',
    () async {
      final service = buildLifecycle(
        authorityCompileMaximum: AccountRuntimeAuthorityMode.off,
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      await expectLater(service.quiesceForDeviceHandoff(), throwsStateError);
      await expectLater(service.mountTransferredHandoff(), throwsStateError);
      expect(gateway.acquireCalls, 0);
    },
  );

  test(
    'acquires before storage/runtime publication and releases after local drain',
    () async {
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        mountRuntime: () async {
          events.add('runtimeMount');
          expect(coordinator.currentReceipt, isNotNull);
          expect(auth.session.value, isNull);
          return runtime;
        },
      );

      final mounted = await service.authenticateAndMount(() async {
        auth.stage(_session());
      });

      expect(mounted, isTrue);
      expect(
        events,
        containsAllInOrder(<String>[
          'candidate',
          'presenceOpen',
          'leaseAcquire',
          'runtimeMount',
          'publish',
        ]),
      );
      expect(service.phase.value, AccountSessionLifecyclePhase.mounted);

      await service.unmount();

      expect(
        events,
        containsAllInOrder(<String>[
          'unpublish',
          'runtimeClose',
          'leaseRelease',
        ]),
      );
      expect(gateway.releaseCalls, 1);
      expect(coordinator.currentReceipt, isNull);
      expect(
        service.phase.value,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );
    },
  );

  test(
    'same-scope mount revalidates exact authority without remounting',
    () async {
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));

      expect(await service.mountCurrentSession(), isTrue);

      expect(mountCalls, 1);
      expect(gateway.acquireCalls, 1);
      expect(gateway.presenceHeartbeatCalls, 1);
      expect(gateway.leaseHeartbeatCalls, 1);
      expect(auth.publishCalls, 2);
      expect(service.phase.value, AccountSessionLifecyclePhase.mounted);
    },
  );

  test('compile off mounts legacy without policy or lease requests', () async {
    gateway.policyHandler = () => throw StateError('must not fetch policy');
    final service = buildLifecycle(
      authorityCompileMaximum: AccountRuntimeAuthorityMode.off,
      mountRuntime: () async => _RecordingRuntimeLease(events),
    );

    expect(
      await service.authenticateAndMount(() async => auth.stage(_session())),
      isTrue,
    );

    expect(service.effectiveAuthorityMode, AccountRuntimeAuthorityMode.off);
    expect(gateway.policyFetchCalls, 0);
    expect(gateway.acquireCalls, 0);
    expect(events, isNot(contains('presenceOpen')));
    expect(service.requiresStandbyRoute, isFalse);
  });

  test('hung compile-shadow observation never blocks legacy mount', () async {
    final policyGate = Completer<AccountRuntimeAuthorityPolicy>();
    gateway.policyHandler = () => policyGate.future;
    final service = buildLifecycle(
      authorityCompileMaximum: AccountRuntimeAuthorityMode.shadow,
      mountRuntime: () async => _RecordingRuntimeLease(events),
    );

    final mounted = await service.authenticateAndMount(
      () async => auth.stage(_session()),
    );

    expect(mounted, isTrue);
    expect(service.isMounted, isTrue);
    expect(auth.session.value, isNotNull);
    expect(gateway.policyFetchCalls, 1);
    expect(gateway.acquireCalls, 0);
  });

  test(
    'shadow opens and heartbeats presence without lease authority',
    () async {
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1);
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');

      expect(service.isMounted, isTrue);
      expect(auth.session.value, isNotNull);
      expect(gateway.presenceOpenCalls, 1);
      expect(coordinator.currentPresence, isNotNull);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.canAdmitMutations, isFalse);
      _expectNoLeaseMutations(gateway);

      shadowWatchdogs.fireActive();
      await _waitForEvent(events, 'presenceHeartbeat');

      expect(gateway.presenceHeartbeatCalls, 1);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.canAdmitMutations, isFalse);
      _expectNoLeaseMutations(gateway);
    },
  );

  test('shadow presence open failure never blocks legacy mount', () async {
    gateway
      ..policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1)
      ..presenceOpenError = TimeoutException('shadow open unavailable');
    final service = buildLifecycle(
      mountRuntime: () async => _RecordingRuntimeLease(events),
    );

    expect(
      await service.authenticateAndMount(() async => auth.stage(_session())),
      isTrue,
    );
    await _waitForEvent(events, 'presenceOpenComplete');

    expect(service.isMounted, isTrue);
    expect(service.phase.value, AccountSessionLifecyclePhase.mounted);
    expect(gateway.presenceOpenCalls, 1);
    expect(coordinator.currentPresence, isNull);
    _expectNoLeaseMutations(gateway);
  });

  test(
    'shadow closes account A presence before authenticating account B',
    () async {
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1);
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');
      expect(coordinator.currentPresence, isNotNull);

      events.clear();
      expect(
        await service.authenticateAndMount(
          () async => auth.stage(_session(accountUuid: 'account-b')),
        ),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');

      final closeIndex = events.indexOf('presenceClose');
      final candidateIndex = events.indexOf('candidate');
      final openIndex = events.indexOf('presenceOpen');
      expect(closeIndex, greaterThanOrEqualTo(0));
      expect(candidateIndex, greaterThan(closeIndex));
      expect(openIndex, greaterThan(candidateIndex));
      expect(gateway.presenceCloseCalls, 1);
      expect(gateway.presenceOpenCalls, 2);
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(coordinator.currentPresence, isNotNull);
      expect(coordinator.currentReceipt, isNull);
      _expectNoLeaseMutations(gateway);
    },
  );

  test(
    'hung shadow open cannot block sign-out, B mount, or attach late result',
    () async {
      gateway
        ..policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1)
        ..presenceOpenGate = Completer<void>();
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpen');

      await service.signOutAndUnmount().timeout(const Duration(seconds: 1));
      expect(auth.candidate, isNull);
      expect(auth.session.value, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.off, 2);
      expect(
        await service.authenticateAndMount(
          () async => auth.stage(_session(accountUuid: 'account-b')),
        ),
        isTrue,
      );
      expect(service.isMounted, isTrue);
      expect(auth.session.value?.accountUuid, 'account-b');

      gateway.presenceOpenGate!.complete();
      await _waitForEvent(events, 'presenceOpenComplete');

      _expectNoLeaseMutations(gateway);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(service.isMounted, isTrue);
    },
  );

  test('hung shadow open cannot block environment switch', () async {
    gateway
      ..policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1)
      ..presenceOpenGate = Completer<void>();
    final service = buildLifecycle(
      mountRuntime: () async => _RecordingRuntimeLease(events),
    );

    expect(
      await service.authenticateAndMount(() async => auth.stage(_session())),
      isTrue,
    );
    await _waitForEvent(events, 'presenceOpen');

    await service
        .switchEnvironment(MaasoEnvironment.production)
        .timeout(const Duration(seconds: 1));
    expect(environment.environment.value, MaasoEnvironment.production);
    expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
    expect(service.isFaulted, isFalse);
    expect(policyWatchdogs.timers.where((timer) => timer.isActive), isEmpty);
    expect(shadowWatchdogs.timers.where((timer) => timer.isActive), isEmpty);

    gateway.presenceOpenGate!.complete();
    await _waitForEvent(events, 'presenceOpenComplete');
    _expectNoLeaseMutations(gateway);
    expect(coordinator.currentReceipt, isNull);
    expect(coordinator.currentPresence, isNull);
  });

  test(
    'same-scope republish deadline fences before late publish and exact release',
    () async {
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        mountRuntime: () async => runtime,
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      events.clear();
      auth
        ..publishGate = Completer<void>()
        ..publishStarted = Completer<void>();

      final republish = service.mountCurrentSession();
      await auth.publishStarted!.future;
      monotonicNow = const Duration(minutes: 5);
      watchdogs.fireActive();

      expect(service.storageScopes.isMounted, isFalse);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      expect(events, containsAllInOrder(<String>['publish', 'runtimeFence']));
      expect(auth.unpublishCalls, 1);
      expect(gateway.releaseCalls, 0);

      auth.publishGate!.complete();
      expect(await republish, isFalse);
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );

      expect(auth.session.value, isNull);
      expect(auth.unpublishCalls, 2);
      expect(runtime.closeCalls, 1);
      expect(gateway.releaseCalls, 1);
      expect(gateway.releasedLease, same(gateway.acquiredLease));
      expect(gateway.releasedProof, gateway.acquiredProof);
    },
  );

  test(
    'same revision may roll expiry without changing stable policy',
    () async {
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      final initialFetches = gateway.policyFetchCalls;
      policyWallNow = policyWallNow.add(const Duration(minutes: 1));
      monotonicNow = const Duration(minutes: 1);
      gateway.policy = _runtimePolicy(
        AccountRuntimeAuthorityMode.enforce,
        1,
        now: policyWallNow,
      );

      policyWatchdogs.fireShortestActive();
      await _waitForPolicyFetchCalls(gateway, initialFetches + 1);

      expect(service.isMounted, isTrue);
      expect(service.enforcementActivated, isTrue);
      expect(events, isNot(contains('runtimeFence')));
    },
  );

  test('policy poll upgrade fences legacy before enforce retry', () async {
    gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.off, 1);
    final runtime = _RecordingRuntimeLease(events);
    final service = buildLifecycle(
      fenceRuntime: () {
        events.add('runtimeFence');
        return Future<void>.value();
      },
      mountRuntime: () async => runtime,
    );
    await service.authenticateAndMount(() async => auth.stage(_session()));
    expect(gateway.acquireCalls, 0);
    gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
    monotonicNow = const Duration(minutes: 4);

    policyWatchdogs.fireShortestActive();
    await _waitForEvent(events, 'runtimeFence');
    await _waitForPhase(
      service,
      AccountSessionLifecyclePhase.authenticatedStandby,
    );

    expect(service.storageScopes.isMounted, isFalse);
    expect(service.enforcementActivated, isTrue);
    expect(auth.session.value, isNull);
    expect(runtime.closeCalls, 1);
    expect(gateway.acquireCalls, 0);
  });

  test(
    'shadow upgrade keeps proof-free close recoverable until lease acquire',
    () async {
      gateway
        ..policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1)
        ..presenceCloseFailures = 1;
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        mountRuntime: () async => runtime,
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');
      expect(coordinator.currentReceipt, isNull);

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
      monotonicNow = const Duration(minutes: 4);
      policyWatchdogs.fireShortestActive();
      await _waitForEvent(events, 'runtimeFence');
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );

      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 0);
      expect(gateway.presenceCloseCalls, 1);
      expect(coordinator.currentPresence, isNull);
      expect(coordinator.currentReceipt, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.isFaulted, isFalse);
      expect(auth.candidate, isNull);

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 3);
      expect(
        await service.authenticateAndMount(
          () async => auth.stage(_session(accountUuid: 'account-b')),
        ),
        isTrue,
      );
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(coordinator.currentReceipt, isNotNull);
      expect(service.isMounted, isTrue);
    },
  );

  test(
    'sign-out replays an uncertain shadow acquire before release and close',
    () async {
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1);
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        mountRuntime: () async => runtime,
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
      monotonicNow = const Duration(minutes: 4);
      policyWatchdogs.fireShortestActive();
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );

      gateway
        ..committedAcquireFailures = 1
        ..rejectCloseWhileLeaseActive = true;
      expect(await service.mountCurrentSession(), isFalse);
      expect(gateway.acquireCalls, 1);
      expect(gateway.lease, isNotNull);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.hasPendingAcquire, isTrue);

      events.clear();
      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 2);
      expect(gateway.acquireRequestIds, hasLength(2));
      expect(gateway.acquireRequestIds.toSet(), hasLength(1));
      expect(gateway.acquireProofs, hasLength(2));
      expect(gateway.acquireProofs.toSet(), hasLength(1));
      expect(gateway.releaseCalls, 1);
      expect(gateway.releaseProofs.single, gateway.acquireProofs.first);
      expect(gateway.presenceCloseCalls, 1);
      expect(
        events,
        containsAllInOrder(<String>[
          'leaseAcquire',
          'leaseRelease',
          'presenceClose',
        ]),
      );
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(auth.candidate, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.isFaulted, isFalse);
    },
  );

  test(
    'sign-out closes presence after an uncertain acquire replay becomes stale',
    () async {
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1);
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        mountRuntime: () async => runtime,
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
      monotonicNow = const Duration(minutes: 4);
      policyWatchdogs.fireShortestActive();
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );

      gateway
        ..committedAcquireFailures = 1
        ..staleCommittedAcquireFailures = 1
        ..rejectCloseWhileLeaseActive = true;
      expect(await service.mountCurrentSession(), isFalse);
      expect(gateway.lease, isNotNull);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.hasPendingAcquire, isTrue);

      events.clear();
      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 2);
      expect(gateway.acquireRequestIds.toSet(), hasLength(1));
      expect(gateway.acquireProofs.toSet(), hasLength(1));
      expect(gateway.releaseCalls, 0);
      expect(gateway.presenceCloseCalls, 1);
      expect(
        events,
        containsAllInOrder(<String>['leaseAcquire', 'presenceClose']),
      );
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(auth.candidate, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.isFaulted, isFalse);
    },
  );

  test(
    'sign-out abandons uncertain authority when replay authentication is gone',
    () async {
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1);
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        mountRuntime: () async => runtime,
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
      monotonicNow = const Duration(minutes: 4);
      policyWatchdogs.fireShortestActive();
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );

      gateway.committedAcquireFailures = 1;
      expect(await service.mountCurrentSession(), isFalse);
      expect(gateway.lease, isNotNull);
      expect(coordinator.hasPendingAcquire, isTrue);
      gateway.acquireError = const AccountDeviceLeaseRequestException(
        statusCode: 401,
        code: 'AUTHENTICATION_REQUIRED',
      );

      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 2);
      expect(gateway.acquireRequestIds.toSet(), hasLength(1));
      expect(gateway.acquireProofs.toSet(), hasLength(1));
      expect(gateway.lease, isNotNull);
      expect(gateway.releaseCalls, 0);
      expect(gateway.presenceCloseCalls, 0);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(auth.candidate, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.isFaulted, isFalse);

      // Simulate remote TTL expiry, then prove no retained local scope can
      // block a fresh account from mounting in this process.
      gateway
        ..acquireError = null
        ..lease = null
        ..presence = null
        ..policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 3);
      expect(
        await service.authenticateAndMount(
          () async => auth.stage(_session(accountUuid: 'account-b')),
        ),
        isTrue,
      );
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(coordinator.currentReceipt, isNotNull);
      expect(service.isMounted, isTrue);
    },
  );

  test(
    'sign-out accepts stale presence after an uncommitted acquire timeout',
    () async {
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 1);
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        mountRuntime: () async => runtime,
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isTrue,
      );
      await _waitForEvent(events, 'presenceOpenComplete');

      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
      monotonicNow = const Duration(minutes: 4);
      policyWatchdogs.fireShortestActive();
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );

      gateway
        ..precommitAcquireFailures = 1
        ..staleAcquirePresenceFailures = 1;
      expect(await service.mountCurrentSession(), isFalse);
      expect(gateway.lease, isNull);
      expect(coordinator.hasPendingAcquire, isTrue);

      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 2);
      expect(gateway.acquireRequestIds.toSet(), hasLength(1));
      expect(gateway.acquireProofs.toSet(), hasLength(1));
      expect(gateway.releaseCalls, 0);
      expect(gateway.presenceCloseCalls, 0);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(auth.candidate, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.isFaulted, isFalse);
    },
  );

  test('active enforce downgrade fences and never restores legacy', () async {
    final runtime = _RecordingRuntimeLease(events);
    final service = buildLifecycle(
      fenceRuntime: () {
        events.add('runtimeFence');
        return Future<void>.value();
      },
      mountRuntime: () async => runtime,
    );
    await service.authenticateAndMount(() async => auth.stage(_session()));
    events.clear();
    gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 2);
    monotonicNow = const Duration(minutes: 4);

    policyWatchdogs.fireShortestActive();
    await _waitForEvent(events, 'runtimeFence');
    await _waitForPhase(
      service,
      AccountSessionLifecyclePhase.authenticatedStandby,
    );

    expect(service.enforcementActivated, isTrue);
    expect(service.isMounted, isFalse);
    expect(auth.session.value, isNull);
    expect(gateway.releaseCalls, 1);
    expect(await service.mountCurrentSession(), isFalse);
    expect(gateway.acquireCalls, 1);
  });

  test('active enforce policy fetch failure fences immediately', () async {
    final runtime = _RecordingRuntimeLease(events);
    final service = buildLifecycle(
      fenceRuntime: () {
        events.add('runtimeFence');
        return Future<void>.value();
      },
      mountRuntime: () async => runtime,
    );
    await service.authenticateAndMount(() async => auth.stage(_session()));
    events.clear();
    gateway.policyHandler = () => throw TimeoutException('policy timeout');
    monotonicNow = const Duration(minutes: 4);

    policyWatchdogs.fireShortestActive();
    await _waitForEvent(events, 'runtimeFence');
    await _waitForPhase(
      service,
      AccountSessionLifecyclePhase.authenticatedStandby,
    );

    expect(service.enforcementActivated, isTrue);
    expect(service.storageScopes.isMounted, isFalse);
    expect(auth.session.value, isNull);
    expect(runtime.closeCalls, 1);
  });

  test('active enforce policy expiry fences outside serialized tail', () async {
    final runtime = _RecordingRuntimeLease(events);
    final service = buildLifecycle(
      fenceRuntime: () {
        events.add('runtimeFence');
        return Future<void>.value();
      },
      mountRuntime: () async => runtime,
    );
    await service.authenticateAndMount(() async => auth.stage(_session()));
    events.clear();
    monotonicNow = const Duration(minutes: 5);

    policyWatchdogs.fireLongestActive();

    expect(service.storageScopes.isMounted, isFalse);
    expect(events, contains('runtimeFence'));
    await _waitForPhase(
      service,
      AccountSessionLifecyclePhase.authenticatedStandby,
    );
    expect(runtime.closeCalls, 1);
    expect(auth.session.value, isNull);
  });

  test(
    'enforce policy expiry fences a pending first acquire and discards late lease',
    () async {
      gateway
        ..acquireGate = Completer<void>()
        ..releaseFailures = 1;
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );

      final mounting = service.authenticateAndMount(
        () async => auth.stage(_session()),
      );
      await _waitForEvent(events, 'leaseAcquire');
      monotonicNow = const Duration(minutes: 5);

      policyWatchdogs.fireLongestActive();

      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      expect(
        service.phase.value,
        AccountSessionLifecyclePhase.verificationRequired,
      );
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      gateway.acquireGate!.complete();
      expect(await mounting, isFalse);
      await _waitForEvent(events, 'leaseRelease');

      expect(gateway.releaseCalls, 1);
      expect(gateway.presenceCloseCalls, 0);
      expect(gateway.releasedLease, same(gateway.acquiredLease));
      expect(gateway.releasedProof, gateway.acquiredProof);
      expect(coordinator.currentReceipt, same(gateway.acquiredLease));
      expect(coordinator.currentPresence, isNotNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(service.isFaulted, isTrue);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.session.value, isNull);
      expect(auth.candidate, isNotNull);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      await expectLater(service.mountCurrentSession(), throwsStateError);
      expect(gateway.acquireCalls, 1);

      await service.retryFaultedCleanup();

      expect(gateway.acquireCalls, 1);
      expect(gateway.releaseCalls, 2);
      expect(gateway.presenceCloseCalls, 1);
      expect(gateway.releaseRequestIds, hasLength(2));
      expect(gateway.releaseRequestIds.toSet(), hasLength(1));
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(
        service.phase.value,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );
      expect(service.isFaulted, isFalse);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.candidate, isNotNull);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      gateway.conflictOnAcquire = true;
      expect(await service.mountCurrentSession(), isFalse);
      expect(gateway.acquireCalls, 2);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);
    },
  );

  test(
    'sign-out abandons rejected lease after a repeated release timeout',
    () async {
      gateway
        ..acquireGate = Completer<void>()
        ..releaseFailures = 2;
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );

      final mounting = service.authenticateAndMount(
        () async => auth.stage(_session()),
      );
      await _waitForEvent(events, 'leaseAcquire');
      monotonicNow = const Duration(minutes: 5);
      policyWatchdogs.fireLongestActive();
      gateway.acquireGate!.complete();

      expect(await mounting, isFalse);
      await _waitForEvent(events, 'leaseRelease');
      final rejectedProof = gateway.acquiredProof!;
      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(coordinator.currentReceipt, same(gateway.acquiredLease));
      expect(auth.candidate, isNotNull);

      await service.signOutAndUnmount();

      expect(gateway.releaseCalls, 2);
      expect(gateway.releaseRequestIds, hasLength(2));
      expect(gateway.releaseRequestIds.toSet(), hasLength(1));
      expect(gateway.releaseProofs, <String>[rejectedProof, rejectedProof]);
      expect(gateway.presenceCloseCalls, 0);
      expect(gateway.presenceOpenCalls, 1);
      expect(gateway.acquireCalls, 1);
      expect(gateway.presenceHeartbeatCalls, 0);
      expect(gateway.leaseHeartbeatCalls, 0);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(gateway.lease, same(gateway.acquiredLease));
      expect(gateway.presence, isNotNull);
      expect(service.activeDeviceLease, isNull);
      expect(auth.candidate, isNull);
      expect(auth.session.value, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      gateway.conflictOnAcquire = true;
      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isFalse,
      );

      expect(gateway.presenceOpenCalls, 2);
      expect(gateway.acquireCalls, 2);
      expect(gateway.presenceOpenRequestIds.toSet(), hasLength(2));
      expect(gateway.acquireRequestIds.toSet(), hasLength(2));
      expect(gateway.acquireProofs.toSet(), hasLength(2));
      expect(service.phase.value, AccountSessionLifecyclePhase.leaseConflict);
      expect(service.requiresStandbyRoute, isTrue);
      expect(auth.candidate, isNotNull);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);
    },
  );

  test(
    'sign-out abandons rejected presence after repeated close timeout',
    () async {
      gateway
        ..acquireGate = Completer<void>()
        ..presenceCloseFailures = 2;
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );

      final mounting = service.authenticateAndMount(
        () async => auth.stage(_session()),
      );
      await _waitForEvent(events, 'leaseAcquire');
      monotonicNow = const Duration(minutes: 5);
      policyWatchdogs.fireLongestActive();
      gateway.acquireGate!.complete();

      expect(await mounting, isFalse);
      await _waitForEvent(events, 'presenceClose');
      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNotNull);

      await service.signOutAndUnmount();

      expect(gateway.releaseCalls, 1);
      expect(gateway.presenceCloseCalls, 2);
      expect(gateway.presenceCloseRequestIds, hasLength(2));
      expect(gateway.presenceCloseRequestIds.toSet(), hasLength(1));
      expect(gateway.presenceOpenCalls, 1);
      expect(gateway.acquireCalls, 1);
      expect(gateway.presenceHeartbeatCalls, 0);
      expect(gateway.leaseHeartbeatCalls, 0);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.idle);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(gateway.lease, isNull);
      expect(gateway.presence, isNotNull);
      expect(service.activeDeviceLease, isNull);
      expect(auth.candidate, isNull);
      expect(auth.session.value, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      gateway.conflictOnAcquire = true;
      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isFalse,
      );

      expect(gateway.presenceOpenCalls, 2);
      expect(gateway.acquireCalls, 2);
      expect(gateway.presenceOpenRequestIds.toSet(), hasLength(2));
      expect(gateway.acquireRequestIds.toSet(), hasLength(2));
      expect(gateway.acquireProofs.toSet(), hasLength(2));
      expect(service.phase.value, AccountSessionLifecyclePhase.leaseConflict);
      expect(service.requiresStandbyRoute, isTrue);
      expect(auth.candidate, isNotNull);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);
    },
  );

  test(
    'enforce policy downgrade fences a pending first acquire before late lease',
    () async {
      gateway
        ..acquireGate = Completer<void>()
        ..releaseFailures = 1;
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );

      final mounting = service.authenticateAndMount(
        () async => auth.stage(_session()),
      );
      await _waitForEvent(events, 'leaseAcquire');
      gateway.policy = _runtimePolicy(AccountRuntimeAuthorityMode.shadow, 2);
      monotonicNow = const Duration(minutes: 4);

      policyWatchdogs.fireShortestActive();
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.verificationRequired,
      );

      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      gateway.acquireGate!.complete();
      expect(await mounting, isFalse);
      await _waitForEvent(events, 'leaseRelease');

      expect(gateway.releaseCalls, 1);
      expect(gateway.presenceCloseCalls, 0);
      expect(coordinator.currentReceipt, same(gateway.acquiredLease));
      expect(coordinator.currentPresence, isNotNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.session.value, isNull);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      await service.switchEnvironment(MaasoEnvironment.production);

      expect(gateway.acquireCalls, 1);
      expect(gateway.releaseCalls, 2);
      expect(gateway.presenceCloseCalls, 1);
      expect(gateway.releaseRequestIds.toSet(), hasLength(1));
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(environment.environment.value, MaasoEnvironment.production);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);
    },
  );

  test(
    'sign-out retries only retained presence close after rejected lease release',
    () async {
      gateway
        ..acquireGate = Completer<void>()
        ..presenceCloseFailures = 1;
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );

      final mounting = service.authenticateAndMount(
        () async => auth.stage(_session()),
      );
      await _waitForEvent(events, 'leaseAcquire');
      monotonicNow = const Duration(minutes: 5);
      policyWatchdogs.fireLongestActive();
      gateway.acquireGate!.complete();

      expect(await mounting, isFalse);
      await _waitForEvent(events, 'presenceClose');
      expect(gateway.releaseCalls, 1);
      expect(gateway.presenceCloseCalls, 1);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNotNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);

      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 1);
      expect(gateway.releaseCalls, 1);
      expect(gateway.presenceCloseCalls, 2);
      expect(gateway.presenceCloseRequestIds, hasLength(2));
      expect(gateway.presenceCloseRequestIds.toSet(), hasLength(1));
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(auth.candidate, isNull);
      expect(auth.session.value, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);
    },
  );

  test('new-scope policy wait starts only after old producer drain', () async {
    final runtimeA = _RecordingRuntimeLease(events);
    final runtimeB = _RecordingRuntimeLease(events);
    var mountCalls = 0;
    final policyStarted = Completer<void>();
    final policyGate = Completer<AccountRuntimeAuthorityPolicy>();
    final service = buildLifecycle(
      fenceRuntime: () {
        events.add('runtimeFence');
        return Future<void>.value();
      },
      mountRuntime: () async => mountCalls++ == 0 ? runtimeA : runtimeB,
    );
    await service.authenticateAndMount(() async => auth.stage(_session()));
    final previousPolicyFetches = gateway.policyFetchCalls;
    gateway.policyHandler = () {
      if (!policyStarted.isCompleted) policyStarted.complete();
      return policyGate.future;
    };
    auth.stage(_session(accountUuid: 'account-b'));

    final switching = service.mountCurrentSession();
    await policyStarted.future;

    expect(gateway.policyFetchCalls, previousPolicyFetches + 1);
    expect(service.storageScopes.isMounted, isFalse);
    expect(events, contains('runtimeFence'));
    expect(runtimeA.closeCalls, 1);
    expect(gateway.releaseCalls, 1);

    gateway.policyHandler = null;
    policyGate.complete(_runtimePolicy(AccountRuntimeAuthorityMode.enforce, 1));
    expect(await switching, isTrue);
    expect(runtimeB.closeCalls, 0);
    expect(service.activeScope?.accountUuid, 'account-b');
  });

  test(
    'conflict retains the candidate and resolves startup to standby',
    () async {
      gateway.conflictOnAcquire = true;
      auth.restoreSession = _session();
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async {
          mountCalls++;
          return _RecordingRuntimeLease(events);
        },
      );

      final route = await StartupRouteService().resolveInitialRoute();

      expect(route, AppRouteCatalog.accountStandby);
      expect(service.phase.value, AccountSessionLifecyclePhase.leaseConflict);
      expect(service.leaseConflict?.holder.deviceLabel, 'Other device');
      expect(service.hasAuthenticatedCandidate, isTrue);
      expect(service.requiresStandbyRoute, isTrue);
      expect(service.storageScopes.isMounted, isFalse);
      expect(auth.session.value, isNull);
      expect(auth.publishCalls, 0);
      expect(mountCalls, 0);
      expect(
        accountSessionRedirectForPath(AppRoutes.home),
        AppRoutes.accountStandby,
      );
      expect(accountSessionRedirectForPath(AppRoutes.accountStandby), isNull);
    },
  );

  test('authentication-required acquire stays verification gated', () async {
    gateway.acquireError = const AccountDeviceLeaseRequestException(
      statusCode: 401,
      code: 'AUTHENTICATION_REQUIRED',
    );
    var mountCalls = 0;
    final service = buildLifecycle(
      mountRuntime: () async {
        mountCalls++;
        return _RecordingRuntimeLease(events);
      },
    );

    final mounted = await service.authenticateAndMount(
      () async => auth.stage(_session()),
    );

    expect(mounted, isFalse);
    expect(
      service.phase.value,
      AccountSessionLifecyclePhase.verificationRequired,
    );
    expect(service.hasAuthenticatedCandidate, isTrue);
    expect(service.requiresStandbyRoute, isTrue);
    expect(service.storageScopes.isMounted, isFalse);
    expect(auth.session.value, isNull);
    expect(auth.publishCalls, 0);
    expect(mountCalls, 0);
  });

  test(
    'sign-out abandons an auth-rejected proof-free enforce presence',
    () async {
      gateway.acquireError = const AccountDeviceLeaseRequestException(
        statusCode: 401,
        code: 'AUTHENTICATION_REQUIRED',
      );
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );

      expect(
        await service.authenticateAndMount(() async => auth.stage(_session())),
        isFalse,
      );
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNotNull);
      expect(
        service.phase.value,
        AccountSessionLifecyclePhase.verificationRequired,
      );

      gateway.presenceCloseError = const AccountDeviceLeaseRequestException(
        statusCode: 401,
        code: 'AUTHENTICATION_REQUIRED',
      );
      await service.signOutAndUnmount();

      expect(gateway.acquireCalls, 1);
      expect(gateway.releaseCalls, 0);
      expect(gateway.presenceCloseCalls, 1);
      expect(gateway.presence, isNotNull);
      expect(coordinator.hasPendingAcquire, isFalse);
      expect(coordinator.currentReceipt, isNull);
      expect(coordinator.currentPresence, isNull);
      expect(auth.candidate, isNull);
      expect(service.phase.value, AccountSessionLifecyclePhase.signedOut);
      expect(service.isFaulted, isFalse);

      // Simulate proof-free presence TTL expiry, then verify the old scope no
      // longer blocks a new account from authenticating in this process.
      gateway
        ..acquireError = null
        ..presenceCloseError = null
        ..presence = null
        ..policy = _runtimePolicy(AccountRuntimeAuthorityMode.enforce, 2);
      expect(
        await service.authenticateAndMount(
          () async => auth.stage(_session(accountUuid: 'account-b')),
        ),
        isTrue,
      );
      expect(auth.session.value?.accountUuid, 'account-b');
      expect(coordinator.currentReceipt, isNotNull);
      expect(service.isMounted, isTrue);
    },
  );

  testWidgets(
    'standby page directs handoff from the current owner without force takeover',
    (tester) async {
      gateway.conflictOnAcquire = true;
      final service = buildLifecycle(
        mountRuntime: () async => _RecordingRuntimeLease(events),
      );
      await tester.runAsync(
        () => service.authenticateAndMount(() async => auth.stage(_session())),
      );

      await tester.pumpWidget(const MaterialApp(home: AccountStandbyPage()));
      await tester.pump();

      expect(find.text('Your Agent is active elsewhere'), findsOneWidget);
      expect(find.text('Other device'), findsOneWidget);
      expect(find.text('Platform: android'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(
        find.textContaining('open Settings → Move between devices'),
        findsOneWidget,
      );
      expect(find.text('Take over (coming soon)'), findsNothing);
      expect(gateway.acquireCalls, 1);
      expect(service.isMounted, isFalse);
    },
  );

  testWidgets(
    'faulted standby retry drains retained cleanup before remounting',
    (tester) async {
      final firstRuntime = _RecordingRuntimeLease(events, closeFailures: 1);
      final secondRuntime = _RecordingRuntimeLease(events);
      var mountCalls = 0;
      final service = buildLifecycle(
        mountRuntime: () async =>
            mountCalls++ == 0 ? firstRuntime : secondRuntime,
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      await expectLater(service.unmount(), throwsStateError);

      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(firstRuntime.closeCalls, 1);
      expect(mountCalls, 1);

      await tester.pumpWidget(const MaterialApp(home: AccountStandbyPage()));
      await tester.pump();
      expect(find.text('Cleanup needs attention'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.runAsync(
        () => _waitForPhase(service, AccountSessionLifecyclePhase.mounted),
      );
      await tester.pump();

      expect(firstRuntime.closeCalls, 2);
      expect(mountCalls, 2);
      expect(service.phase.value, AccountSessionLifecyclePhase.mounted);
      expect(service.activeDeviceLease, isNotNull);

      await tester.runAsync(service.unmount);
      await tester.pump();
    },
  );

  test(
    'deadline fences a slow mount before its guarded producer can register',
    () async {
      final runtimeReady = Completer<AccountRuntimeLease>();
      final runtime = _RecordingRuntimeLease(events);
      var producerCreated = false;
      var guardRejected = false;
      int? activatedBoundaryGeneration;
      final retiredBoundaryGenerations = <int>[];
      late AccountSessionLifecycleService service;
      service = buildLifecycle(
        fenceRuntime: () {
          events.add('runtimeFence');
          return Future<void>.value();
        },
        activateRuntimeBoundary: (mount) {
          activatedBoundaryGeneration = mount.generation;
          events.add('boundaryActivate');
        },
        retireRuntimeBoundary: (accountGeneration) {
          retiredBoundaryGenerations.add(accountGeneration);
          events.add('boundaryRetire');
        },
        mountRuntime: () async {
          events.add('runtimeMountStarted');
          expect(activatedBoundaryGeneration, isNotNull);
          final mount = service.storageScopes.activeMount!;
          final lateRuntime = await runtimeReady.future;
          try {
            service.storageScopes.requireCurrent(mount);
            producerCreated = true;
            return lateRuntime;
          } catch (_) {
            guardRejected = true;
            await lateRuntime.close();
            rethrow;
          }
        },
      );
      var settled = false;
      final mounting = service.authenticateAndMount(
        () async => auth.stage(_session()),
      );
      unawaited(
        mounting.then<void>(
          (_) => settled = true,
          onError: (Object _, StackTrace _) => settled = true,
        ),
      );
      await _waitForEvent(events, 'runtimeMountStarted');

      monotonicNow = const Duration(minutes: 5);
      watchdogs.fireActive();

      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      expect(service.storageScopes.isMounted, isFalse);
      expect(events, contains('runtimeFence'));
      expect(retiredBoundaryGenerations, <int>[activatedBoundaryGeneration!]);
      expect(
        events.indexOf('boundaryRetire'),
        greaterThan(events.indexOf('runtimeMountStarted')),
      );
      expect(auth.publishCalls, 0);
      expect(producerCreated, isFalse);
      expect(settled, isFalse);

      runtimeReady.complete(runtime);
      await expectLater(mounting, throwsStateError);

      expect(guardRejected, isTrue);
      expect(producerCreated, isFalse);
      expect(auth.publishCalls, 0);
      expect(auth.unpublishCalls, 0);
      expect(runtime.closeCalls, 1);
      expect(gateway.releaseCalls, 1);
      expect(gateway.releasedLease, same(gateway.acquiredLease));
      expect(gateway.releasedProof, gateway.acquiredProof);
      expect(coordinator.currentReceipt, isNull);
      expect(retiredBoundaryGenerations, <int>[activatedBoundaryGeneration!]);
    },
  );

  test('deadline during publish unpublishes before exact release', () async {
    auth
      ..publishGate = Completer<void>()
      ..publishStarted = Completer<void>();
    final runtime = _RecordingRuntimeLease(events);
    final service = buildLifecycle(
      fenceRuntime: () {
        events.add('runtimeFence');
        return Future<void>.value();
      },
      mountRuntime: () async => runtime,
    );
    final mounting = service.authenticateAndMount(
      () async => auth.stage(_session()),
    );
    await auth.publishStarted!.future;

    monotonicNow = const Duration(minutes: 5);
    watchdogs.fireActive();

    expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
    expect(service.storageScopes.isMounted, isFalse);
    expect(auth.publishCalls, 1);
    expect(auth.unpublishCalls, 0);
    auth.publishGate!.complete();

    await expectLater(mounting, throwsStateError);

    expect(auth.session.value, isNull);
    expect(auth.unpublishCalls, 1);
    expect(runtime.closeCalls, 1);
    expect(gateway.releaseCalls, 1);
    expect(gateway.releasedLease, same(gateway.acquiredLease));
    expect(gateway.releasedProof, gateway.acquiredProof);
    expect(
      events,
      containsAllInOrder(<String>[
        'publish',
        'runtimeFence',
        'unpublish',
        'runtimeClose',
        'leaseRelease',
      ]),
    );
  });

  test(
    'local close failure retains exact lease and release for retry',
    () async {
      final runtime = _RecordingRuntimeLease(events, closeFailures: 1);
      final service = buildLifecycle(mountRuntime: () async => runtime);
      await service.authenticateAndMount(() async => auth.stage(_session()));

      await expectLater(service.unmount(), throwsStateError);

      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(runtime.closeCalls, 1);
      expect(gateway.releaseCalls, 0);
      expect(coordinator.currentReceipt, isNotNull);

      await service.retryFaultedCleanup();

      expect(runtime.closeCalls, 2);
      expect(auth.unpublishCalls, 1);
      expect(gateway.releaseCalls, 1);
      expect(coordinator.currentReceipt, isNull);
    },
  );

  test(
    'release failure retries only release after local stages succeed',
    () async {
      gateway.releaseFailures = 1;
      final runtime = _RecordingRuntimeLease(events);
      final service = buildLifecycle(mountRuntime: () async => runtime);
      await service.authenticateAndMount(() async => auth.stage(_session()));

      await expectLater(service.unmount(), throwsA(isA<TimeoutException>()));

      expect(service.phase.value, AccountSessionLifecyclePhase.faulted);
      expect(auth.unpublishCalls, 1);
      expect(runtime.closeCalls, 1);
      expect(gateway.releaseCalls, 1);
      expect(coordinator.currentReceipt, isNotNull);

      await service.retryFaultedCleanup();

      expect(auth.unpublishCalls, 1);
      expect(runtime.closeCalls, 1);
      expect(gateway.releaseCalls, 2);
      expect(coordinator.currentReceipt, isNull);
    },
  );

  test(
    'stale revalidation fences authority runtime and storage before drain',
    () async {
      final runtime = _RecordingRuntimeLease(events);
      late AccountSessionLifecycleService service;
      service = buildLifecycle(
        mountRuntime: () async => runtime,
        fenceRuntime: () {
          expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
          expect(service.storageScopes.isMounted, isTrue);
          events.add('runtimeFence');
          return Future<void>.value();
        },
      );
      await service.authenticateAndMount(() async => auth.stage(_session()));
      events.clear();
      gateway.staleHeartbeat = true;

      expect(await service.mountCurrentSession(), isFalse);

      expect(service.storageScopes.isMounted, isFalse);
      expect(coordinator.state, AccountDeviceLeaseCoordinatorState.fenced);
      await _waitForPhase(
        service,
        AccountSessionLifecyclePhase.authenticatedStandby,
      );
      expect(
        events,
        containsAllInOrder(<String>[
          'presenceHeartbeat',
          'leaseHeartbeat',
          'runtimeFence',
          'unpublish',
          'runtimeClose',
        ]),
      );
      expect(gateway.releaseCalls, 0);
      expect(service.activeDeviceLease, isNull);
    },
  );
}

Future<void> _waitForPhase(
  AccountSessionLifecycleService lifecycle,
  AccountSessionLifecyclePhase expected,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (lifecycle.phase.value == expected) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for $expected; got ${lifecycle.phase.value}.');
}

Future<void> _waitForEvent(List<String> events, String expected) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (events.contains(expected)) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Timed out waiting for $expected; got $events.');
}

Future<void> _waitForPolicyFetchCalls(
  _LifecycleLeaseGateway gateway,
  int expected,
) async {
  for (var attempt = 0; attempt < 50; attempt++) {
    if (gateway.policyFetchCalls >= expected) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail(
    'Timed out waiting for $expected policy fetches; '
    'got ${gateway.policyFetchCalls}.',
  );
}

void _expectNoLeaseMutations(_LifecycleLeaseGateway gateway) {
  expect(gateway.acquireCalls, 0, reason: 'shadow acquired a lease');
  expect(gateway.leaseHeartbeatCalls, 0, reason: 'shadow renewed a lease');
  expect(gateway.releaseCalls, 0, reason: 'shadow released a lease');
  expect(gateway.acquireProofs, isEmpty, reason: 'shadow created holder proof');
}

MaasoAuthSession _session({String accountUuid = 'account-a'}) =>
    MaasoAuthSession(
      accountUuid: accountUuid,
      accessToken: 'access-token',
      refreshToken: 'refresh-token',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

class _LifecycleAuthSessionService extends AuthSessionService {
  _LifecycleAuthSessionService(this.events);

  final List<String> events;
  MaasoAuthCandidate? _candidate;
  MaasoAuthSession? restoreSession;
  Completer<void>? publishStarted;
  Completer<void>? publishGate;
  int operationEpoch = 0;
  int publishCalls = 0;
  int unpublishCalls = 0;

  @override
  MaasoAuthCandidate? get candidate => _candidate;

  void stage(MaasoAuthSession session) {
    events.add('candidate');
    _candidate = MaasoAuthCandidate(
      environment: appServices.find<AppEnvironmentService>().environment.value,
      session: session,
      operationEpoch: ++operationEpoch,
      logoutFence: const AuthLogoutPendingSnapshot(
        pending: false,
        revision: 1,
        token: 'cleared',
      ),
    );
    this.session.value = null;
  }

  @override
  Future<bool> restoreCandidate() async {
    final restored = restoreSession;
    if (restored == null) {
      _candidate = null;
      return false;
    }
    stage(restored);
    return true;
  }

  @override
  Future<void> publishCandidate([MaasoAuthCandidate? expected]) async {
    final current = _candidate;
    if (current == null ||
        (expected != null && !identical(expected, current))) {
      throw StateError('candidate changed');
    }
    events.add('publish');
    publishCalls++;
    final started = publishStarted;
    if (started != null && !started.isCompleted) started.complete();
    await publishGate?.future;
    session.value = current.session;
  }

  @override
  Future<void> unpublishSession() async {
    events.add('unpublish');
    unpublishCalls++;
    session.value = null;
  }

  @override
  Future<void> signOut() async {
    _candidate = null;
    session.value = null;
  }
}

class _RecordingRuntimeLease implements AccountRuntimeLease {
  _RecordingRuntimeLease(this.events, {this.closeFailures = 0});

  final List<String> events;
  int closeFailures;
  int closeCalls = 0;

  @override
  Future<void> close() async {
    events.add('runtimeClose');
    closeCalls++;
    if (closeFailures > 0) {
      closeFailures--;
      throw StateError('runtime close failed');
    }
  }
}

class _MemoryInstallationIdentityStore implements AppInstallationIdentityStore {
  final Map<String, String> values = <String, String>{
    AppInstallationIdentityService.preferencesKey:
        '0123456789abcdef0123456789abcdef',
  };

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String value) async {
    values[key] = value;
    return true;
  }
}

class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

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
  int seed = 1;

  List<int> bytes(int length) {
    final current = seed++;
    return List<int>.generate(length, (index) => (current + index) & 0xff);
  }
}

class _ManualWatchdogFactory {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  Timer create(Duration delay, void Function() callback) {
    final timer = _ManualTimer(delay, callback);
    timers.add(timer);
    return timer;
  }

  void fireActive() {
    final activeTimers = timers.where((timer) => timer.isActive).toList();
    if (activeTimers.isEmpty) {
      throw StateError('No active authority watchdog');
    }
    activeTimers.last.fire();
  }

  void fireShortestActive() {
    final activeTimers = timers.where((timer) => timer.isActive).toList()
      ..sort((left, right) => left.delay.compareTo(right.delay));
    if (activeTimers.isEmpty) {
      throw StateError('No active authority watchdog');
    }
    activeTimers.first.fire();
  }

  void fireLongestActive() {
    final activeTimers = timers.where((timer) => timer.isActive).toList()
      ..sort((left, right) => left.delay.compareTo(right.delay));
    if (activeTimers.isEmpty) {
      throw StateError('No active authority watchdog');
    }
    activeTimers.last.fire();
  }
}

class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;

  @override
  void cancel() {
    _active = false;
  }

  void fire() {
    if (!_active) return;
    _active = false;
    _tick++;
    _callback();
  }
}

class _LifecycleLeaseGateway
    implements AccountDeviceLeaseGateway, AccountRuntimeAuthorityPolicyGateway {
  _LifecycleLeaseGateway(this.events);

  final List<String> events;
  bool conflictOnAcquire = false;
  bool staleHeartbeat = false;
  AccountDeviceLeaseRequestException? acquireError;
  Completer<void>? acquireGate;
  Completer<void>? presenceOpenGate;
  Object? presenceOpenError;
  Object? presenceCloseError;
  int precommitAcquireFailures = 0;
  int committedAcquireFailures = 0;
  int staleCommittedAcquireFailures = 0;
  int staleAcquirePresenceFailures = 0;
  bool rejectCloseWhileLeaseActive = false;
  Completer<AccountDeviceLeaseSnapshot>? currentLeaseGate;
  AccountDeviceLeaseSnapshot? currentLeaseSnapshot;
  Object? currentLeaseError;
  int releaseFailures = 0;
  int presenceCloseFailures = 0;
  int presenceOpenCalls = 0;
  int presenceCloseCalls = 0;
  int currentLeaseCalls = 0;
  int acquireCalls = 0;
  int presenceHeartbeatCalls = 0;
  int leaseHeartbeatCalls = 0;
  int releaseCalls = 0;
  final List<String> releaseRequestIds = <String>[];
  final List<String> releaseProofs = <String>[];
  final List<String> presenceCloseRequestIds = <String>[];
  final List<String> presenceOpenRequestIds = <String>[];
  final List<String> acquireRequestIds = <String>[];
  final List<String> acquireProofs = <String>[];
  AccountDevicePresenceReceipt? presence;
  AccountDeviceLeaseReceipt? lease;
  AccountDeviceLeaseReceipt? acquiredLease;
  String? acquiredProof;
  AccountDeviceLeaseReceipt? releasedLease;
  String? releasedProof;
  AccountRuntimeAuthorityPolicy policy = AccountRuntimeAuthorityPolicy(
    mode: AccountRuntimeAuthorityMode.enforce,
    revision: 1,
    expiresAt: _wallNow.add(const Duration(minutes: 5)),
    remainingTtl: const Duration(minutes: 5),
    pollAfter: const Duration(minutes: 4),
  );
  Future<AccountRuntimeAuthorityPolicy> Function()? policyHandler;
  int policyFetchCalls = 0;

  @override
  Future<AccountRuntimeAuthorityPolicy> fetchRuntimeAuthorityPolicy({
    required MaasoEnvironment environment,
    required String accountUuid,
  }) async {
    events.add('policyFetch');
    policyFetchCalls++;
    final handler = policyHandler;
    if (handler != null) return handler();
    return policy;
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
    events.add('presenceOpen');
    presenceOpenCalls++;
    presenceOpenRequestIds.add(requestId);
    try {
      final result = presence ??= _presence(
        installationId: installationId,
        runtimeInstanceId: runtimeInstanceId,
        deviceLabel: deviceLabel,
        platform: platform,
        appVersion: appVersion,
      );
      await presenceOpenGate?.future;
      final exception = presenceOpenError;
      if (exception != null) throw exception;
      return AccountDevicePresenceOperationResult(
        presence: result,
        replayed: false,
      );
    } finally {
      events.add('presenceOpenComplete');
    }
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
    events.add('leaseAcquire');
    acquireCalls++;
    acquireRequestIds.add(requestId);
    acquireProofs.add(holderProof);
    await acquireGate?.future;
    if (conflictOnAcquire) {
      throw AccountDeviceLeaseConflict(
        observedEpoch: 7,
        holder: AccountDeviceLeaseHolder(
          installationId: 'other-installation',
          runtimeInstanceId: 'other-runtime',
          presenceSessionId: 'other-presence',
          deviceLabel: 'Other device',
          platform: 'android',
          lastSeenAt: _wallNow,
        ),
        expiresAt: _wallNow.add(const Duration(minutes: 1)),
        remainingTtl: const Duration(minutes: 1),
      );
    }
    final error = acquireError;
    if (error != null) throw error;
    if (precommitAcquireFailures > 0) {
      precommitAcquireFailures--;
      throw TimeoutException('acquire request outcome unknown before commit');
    }
    if (staleAcquirePresenceFailures > 0) {
      staleAcquirePresenceFailures--;
      presence = null;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_PRESENCE',
      );
    }
    final result = lease ??= _lease(
      installationId: installationId,
      runtimeInstanceId: runtimeInstanceId,
      presenceSessionId: presenceSessionId,
    );
    if (committedAcquireFailures > 0) {
      committedAcquireFailures--;
      throw TimeoutException('acquire response lost after commit');
    }
    if (staleCommittedAcquireFailures > 0) {
      staleCommittedAcquireFailures--;
      lease = null;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_LEASE',
      );
    }
    acquiredLease = result;
    acquiredProof = holderProof;
    return AccountDeviceLeaseOperationResult(lease: result, replayed: false);
  }

  @override
  Future<AccountDevicePresenceOperationResult> heartbeatPresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    events.add('presenceHeartbeat');
    presenceHeartbeatCalls++;
    return AccountDevicePresenceOperationResult(
      presence: presence,
      replayed: false,
    );
  }

  @override
  Future<AccountDeviceLeaseOperationResult> heartbeatLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    events.add('leaseHeartbeat');
    leaseHeartbeatCalls++;
    if (staleHeartbeat) {
      this.lease = null;
      throw const AccountDeviceLeaseRequestException(
        statusCode: 409,
        code: 'STALE_RUNTIME_LEASE',
      );
    }
    return AccountDeviceLeaseOperationResult(lease: lease, replayed: false);
  }

  @override
  Future<AccountDeviceLeaseReleaseResult> releaseLease({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDeviceLeaseReceipt lease,
    required String holderProof,
    required String requestId,
  }) async {
    events.add('leaseRelease');
    releaseCalls++;
    releaseRequestIds.add(requestId);
    releaseProofs.add(holderProof);
    releasedLease = lease;
    releasedProof = holderProof;
    if (releaseFailures > 0) {
      releaseFailures--;
      throw TimeoutException('release response lost');
    }
    this.lease = null;
    return AccountDeviceLeaseReleaseResult(
      released: true,
      stale: false,
      epoch: lease.epoch + 1,
    );
  }

  @override
  Future<AccountDevicePresenceCloseResult> closePresence({
    required MaasoEnvironment environment,
    required String accountUuid,
    required AccountDevicePresenceReceipt presence,
    required String requestId,
  }) async {
    events.add('presenceClose');
    presenceCloseCalls++;
    presenceCloseRequestIds.add(requestId);
    final error = presenceCloseError;
    if (error != null) throw error;
    if (rejectCloseWhileLeaseActive && lease != null) {
      throw StateError('cannot close presence while lease is active');
    }
    if (presenceCloseFailures > 0) {
      presenceCloseFailures--;
      throw TimeoutException('presence close response lost');
    }
    this.presence = null;
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
    events.add('leaseCurrent');
    currentLeaseCalls++;
    try {
      final gate = currentLeaseGate;
      if (gate != null) return await gate.future;
      final exception = currentLeaseError;
      if (exception != null) throw exception;
      return currentLeaseSnapshot ??
          AccountDeviceLeaseSnapshot(
            state: lease == null
                ? AccountDeviceLeaseRemoteState.inactive
                : AccountDeviceLeaseRemoteState.active,
            lease: lease,
          );
    } finally {
      events.add('leaseCurrentComplete');
    }
  }
}

AccountDevicePresenceReceipt _presence({
  required String installationId,
  required String runtimeInstanceId,
  required String deviceLabel,
  required String platform,
  required String appVersion,
}) => AccountDevicePresenceReceipt(
  agentId: 'self',
  installationId: installationId,
  runtimeInstanceId: runtimeInstanceId,
  presenceSessionId: 'presence-1',
  generation: 1,
  deviceLabel: deviceLabel,
  platform: platform,
  appVersion: appVersion,
  openedAt: _wallNow,
  lastSeenAt: _wallNow,
  expiresAt: _wallNow.add(const Duration(minutes: 5)),
  remainingTtl: const Duration(minutes: 5),
  renewAfter: const Duration(minutes: 4),
);

AccountDeviceLeaseReceipt _lease({
  required String installationId,
  required String runtimeInstanceId,
  required String presenceSessionId,
}) {
  final holder = AccountDeviceLeaseHolder(
    installationId: installationId,
    runtimeInstanceId: runtimeInstanceId,
    presenceSessionId: presenceSessionId,
    deviceLabel: 'Test Mac',
    platform: 'macos',
    lastSeenAt: _wallNow,
  );
  return AccountDeviceLeaseReceipt(
    agentId: 'self',
    leaseId: 'lease-1',
    epoch: 1,
    installationId: installationId,
    runtimeInstanceId: runtimeInstanceId,
    presenceSessionId: presenceSessionId,
    expiresAt: _wallNow.add(const Duration(minutes: 5)),
    remainingTtl: const Duration(minutes: 5),
    renewAfter: const Duration(minutes: 4),
    holder: holder,
  );
}

AccountRuntimeAuthorityPolicy _runtimePolicy(
  AccountRuntimeAuthorityMode mode,
  int revision, {
  DateTime? now,
}) => AccountRuntimeAuthorityPolicy(
  mode: mode,
  revision: revision,
  expiresAt: (now ?? _wallNow).add(const Duration(minutes: 5)),
  remainingTtl: const Duration(minutes: 5),
  pollAfter: const Duration(minutes: 4),
);

final DateTime _wallNow = DateTime.utc(2026, 8, 21, 12);

class _TransferredHandoffGateway implements AccountDeviceHandoffGateway {
  _TransferredHandoffGateway(this.presence, this.lease);
  final AccountDevicePresenceReceipt presence;
  final AccountDeviceLeaseReceipt lease;

  AccountDeviceHandoff view(AccountHandoffState state) => AccountDeviceHandoff(
    handoffId: 'handoff-test',
    agentId: 'self',
    state: state,
    sourceLeaseId: 'source-lease',
    sourceEpoch: 7,
    sourcePresenceSessionId: 'source-presence',
    sourceRuntimeInstanceId: 'source-runtime',
    targetPresenceSessionId: presence.presenceSessionId,
    targetRuntimeInstanceId: presence.runtimeInstanceId,
    avatarModel: HandoffAvatarIdentity(modelId: 'avatar-agent', revision: '1'),
    createdAt: _wallNow,
    expiresAt: _wallNow.add(const Duration(minutes: 1)),
    remainingTtl: const Duration(minutes: 1),
    lease: state == AccountHandoffState.accepted ? lease : null,
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
