import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';
import 'package:maaso/src/core/services/device/embodied_device_supervisor.dart';
import 'package:maaso/src/core/services/device/physical_motion_policy.dart';
import 'package:maaso/src/core/services/device/yoturetoys_embodied_device_adapter.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';

void main() {
  test('production mount owns one account-bound read-only device graph', () {
    final source = File('lib/main.dart').readAsStringSync();
    final mountStart = source.indexOf(
      'Future<AccountRuntimeLease> _mountAccountRuntime',
    );
    final drainStart = source.indexOf(
      'Future<void> _drainAccountRuntimeProducers',
    );
    expect(mountStart, greaterThanOrEqualTo(0));
    expect(drainStart, greaterThan(mountStart));
    final mount = source.substring(mountStart, drainStart);

    expect(mount, contains('putOwned<EmbodiedDeviceFacade>('));
    expect(mount, contains('YoturetoysEmbodiedDeviceAdapter('));
    expect(mount, contains('device: appServices.find<YoturetoysDevice>()'));
    expect(mount, contains('accountId: accountScope.accountDigest'));
    expect(mount, contains('facadeGeneration: mount.generation'));
    expect(mount, contains('_isCurrentAccountMount(mount)'));
    expect(mount, contains('PhysicalMotionPolicy('));
    expect(mount, contains('EmbodiedDeviceSupervisor('));
    expect(
      mount,
      contains('featureFlags.effectiveMode(MaasoFeatureFlag.embodiedDeviceV1)'),
    );
    expect(mount, contains('UnavailableEmbodiedMotionConfirmationGateway()'));
    expect(mount, contains('ActionAuditLogEmbodiedMotionAuditSink.lazy('));
    expect(mount, contains('!appForeground.isForeground.value'));
    final auditRegistration = mount.indexOf(
      'lazyOwned<ActionAuditLog>(ActionAuditLog.new);',
    );
    final embodiedRegistration = mount.indexOf('EmbodiedDeviceSupervisor(');
    expect(auditRegistration, greaterThanOrEqualTo(0));
    expect(embodiedRegistration, greaterThan(auditRegistration));
    expect(mount, contains('() => appServices.find<ActionAuditLog>()'));

    // Production keeps the existing process-global projector facade and BLE
    // transport. The account graph only composes over those singletons.
    expect(RegExp(r'YoturetoysDevice\(').allMatches(source), hasLength(1));
    expect(RegExp(r'BleTransportService\(\)').allMatches(source), hasLength(1));
    final skillCatalog = File(
      'lib/src/features/agent/application/skill_catalog.dart',
    ).readAsStringSync();
    expect(skillCatalog, isNot(contains('EmbodiedDevice')));
    expect(skillCatalog, isNot(contains('device.motion')));
  });

  test('device retirement precedes flags, BLE lane, and owned deletion', () {
    final source = File('lib/main.dart').readAsStringSync();
    final drainStart = source.indexOf(
      'Future<void> _drainAccountRuntimeProducers',
    );
    final drainEnd = source.indexOf('void _registerDefaultVadServices');
    final drain = source.substring(drainStart, drainEnd);

    final embodiedStart = drain.indexOf("barrier.run('embodied_device'");
    final flagsStart = drain.indexOf("barrier.run('feature_flags'");
    final bluetoothStart = drain.indexOf("barrier.run('bluetooth'");
    expect(embodiedStart, greaterThanOrEqualTo(0));
    expect(flagsStart, greaterThan(embodiedStart));
    expect(bluetoothStart, greaterThan(flagsStart));

    final flags = drain.substring(flagsStart, bluetoothStart);
    expect(flags, contains('embodiedDeviceDrain'));
    final flagWait = flags.indexOf('await Future.wait<void>');
    final flagDeviceWait = flags.indexOf('embodiedDeviceDrain');
    final flagSeal = flags.indexOf('maybeFind<MaasoFeatureFlagService>()');
    expect(flagWait, greaterThanOrEqualTo(0));
    expect(flagDeviceWait, greaterThan(flagWait));
    expect(flagSeal, greaterThan(flagDeviceWait));

    // Bound this block by the following live producer, rather than the retired
    // World producer. Keep the device fence before both singleton BLE branches.
    final bluetoothEnd = drain.indexOf('final llmProxyDrain =', bluetoothStart);
    expect(bluetoothEnd, greaterThan(bluetoothStart));
    final bluetooth = drain.substring(bluetoothStart, bluetoothEnd);
    final deviceWait = bluetooth.indexOf('await embodiedDeviceDrain;');
    final projectorClose = bluetooth.indexOf(
      'projector.deactivateAccountAndDrain()',
    );
    final transportLookup = bluetooth.indexOf(
      'maybeFind<BleTransportService>()',
    );
    expect(deviceWait, greaterThanOrEqualTo(0));
    expect(projectorClose, greaterThan(deviceWait));
    expect(transportLookup, greaterThan(projectorClose));
    expect(
      bluetooth.substring(transportLookup),
      contains('?.deactivateAccountAndDrain()'),
    );
    expect(drain, contains('maybeFind<EmbodiedDeviceSupervisor>()'));
    expect(drain, contains('maybeFind<EmbodiedDeviceFacade>()'));
    expect(drain, contains('supervisor.retireRevokedAccountAndDrain('));

    final disposeStart = source.indexOf('Future<void> _disposeAccountRuntime');
    final disposeEnd = source.indexOf(
      'Future<void> _drainAccountRuntimeProducers',
      disposeStart,
    );
    final dispose = source.substring(disposeStart, disposeEnd);
    final fullDrain = dispose.indexOf('await _drainAccountRuntimeProducers();');
    expect(fullDrain, greaterThanOrEqualTo(0));
    expect(
      fullDrain,
      lessThan(dispose.indexOf('for (final type in ownedTypes.reversed)')),
    );
  });

  test(
    'default-off account switch is fenced and produces zero BLE writes',
    () async {
      final transport = _WriteSpyTransport();
      final device = YoturetoysDevice(transport);
      device.activateAccount(accountScopeKey: 'storage-a');
      var activeAccount = 'digest-a';
      var activeGeneration = 1;
      var rolloutMode = FeatureRolloutMode.off;
      var auditResolutions = 0;
      final sharedAuditLog = ActionAuditLog();

      final authorityA = createEmbodiedMotionAuthorityPair();
      final adapterA = YoturetoysEmbodiedDeviceAdapter(
        device: device,
        accountId: 'digest-a',
        facadeGeneration: 1,
        authorityIsCurrent: (accountId, generation) =>
            accountId == activeAccount && generation == activeGeneration,
        motionCapabilityVerifier: authorityA.verifier,
      );
      final supervisorA = EmbodiedDeviceSupervisor(
        facade: adapterA,
        policy: PhysicalMotionPolicy(
          accountId: 'digest-a',
          facadeGeneration: 1,
        ),
        rolloutMode: () => rolloutMode,
        authorityIsCurrent: (invocation) =>
            invocation.accountId == activeAccount &&
            invocation.facadeGeneration == activeGeneration &&
            invocation.runtimeGeneration == activeGeneration,
        confirmation: const UnavailableEmbodiedMotionConfirmationGateway(),
        audit: ActionAuditLogEmbodiedMotionAuditSink.lazy(() {
          auditResolutions += 1;
          return sharedAuditLog;
        }),
        motionCapabilityIssuer: authorityA.issuer,
        deviceTarget: adapterA.deviceId,
      );

      final disabled = await supervisorA.executeMotion(
        invocation: EmbodiedMotionInvocation(
          accountId: 'digest-a',
          facadeGeneration: 1,
          agentId: 'self',
          runtimeGeneration: 1,
          callId: 'account-a-call',
        ),
        request: const EmbodiedMotionRequest(
          capability: EmbodiedDeviceCapability.move,
          distanceMeters: 0.5,
        ),
      );
      expect(disabled.outcome, EmbodiedSupervisorOutcome.disabled);
      expect(disabled.code, 'rollout_off');
      expect((await adapterA.status()).status, EmbodiedResultStatus.ok);
      expect(auditResolutions, 0);
      expect(transport.writeCalls, 0);

      // Exercise the path that captures an authorized invocation, then prove a
      // later mount-authority fence cannot prevent retirement from completing.
      rolloutMode = FeatureRolloutMode.shadow;
      final shadow = await supervisorA.executeMotion(
        invocation: EmbodiedMotionInvocation(
          accountId: 'digest-a',
          facadeGeneration: 1,
          agentId: 'self',
          runtimeGeneration: 1,
          callId: 'account-a-shadow',
        ),
        request: const EmbodiedMotionRequest(
          capability: EmbodiedDeviceCapability.move,
          distanceMeters: 0.5,
        ),
      );
      expect(shadow.outcome, EmbodiedSupervisorOutcome.shadowRejected);
      expect(transport.writeCalls, 0);

      // Match production teardown: fence the account-owned graph before the
      // permanent projector lane is retired and reactivated for account B.
      await expectLater(
        supervisorA.retireRevokedAccountAndDrain(
          accountId: 'digest-b',
          facadeGeneration: 1,
        ),
        throwsStateError,
      );
      expect((await adapterA.status()).accountId, 'digest-a');
      final supervisorDrain = supervisorA.retireRevokedAccountAndDrain(
        accountId: adapterA.accountId,
        facadeGeneration: adapterA.facadeGeneration,
      );
      final adapterDrain = adapterA.retireAndDrain();
      activeAccount = 'digest-b';
      activeGeneration = 2;
      await Future.wait<void>(<Future<void>>[supervisorDrain, adapterDrain]);
      await device.deactivateAccountAndDrain();
      device.activateAccount(accountScopeKey: 'storage-b');

      await expectLater(adapterA.status(), throwsStateError);
      final authorityB = createEmbodiedMotionAuthorityPair();
      final adapterB = YoturetoysEmbodiedDeviceAdapter(
        device: device,
        accountId: 'digest-b',
        facadeGeneration: 2,
        authorityIsCurrent: (accountId, generation) =>
            accountId == activeAccount && generation == activeGeneration,
        motionCapabilityVerifier: authorityB.verifier,
      );
      expect((await adapterB.status()).accountId, 'digest-b');
      expect((await adapterB.health()).facadeGeneration, 2);
      expect(transport.writeCalls, 0);

      await adapterB.retireAndDrain();
      await device.deactivateAccountAndDrain();
    },
  );
}

final class _WriteSpyTransport extends BleTransportService {
  int writeCalls = 0;

  @override
  Future<void> write(
    List<int> bytes, {
    bool allowLongWrite = false,
    BleCapabilityAuthority? capabilityAuthority,
  }) async {
    writeCalls += 1;
  }
}
