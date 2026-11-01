import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';
import 'package:maaso/src/core/services/device/yoturetoys_embodied_device_adapter.dart';

void main() {
  late _WriteSpyTransport transport;
  late YoturetoysDevice device;
  late DateTime now;
  late EmbodiedMotionAuthorityPair motionAuthority;
  var backgrounded = false;
  var authorityCurrent = true;

  setUp(() {
    transport = _WriteSpyTransport();
    device = YoturetoysDevice(transport);
    device.activateAccount(accountScopeKey: 'account-a');
    now = DateTime.utc(2026, 8, 30, 8);
    authorityCurrent = true;
    motionAuthority = createEmbodiedMotionAuthorityPair();
  });

  YoturetoysEmbodiedDeviceAdapter adapter() => YoturetoysEmbodiedDeviceAdapter(
    device: device,
    deviceId: 'projector-1',
    accountId: 'account-a',
    facadeGeneration: 7,
    authorityIsCurrent: (_, _) => authorityCurrent,
    motionCapabilityVerifier: motionAuthority.verifier,
    clock: () => now,
    backgrounded: () => backgrounded,
  );

  test(
    'exposes only truthful projector status and health capabilities',
    () async {
      final subject = adapter();

      final snapshots = await subject.capabilities();

      expect(subject.deviceId, 'projector-1');
      expect(snapshots, hasLength(EmbodiedDeviceCapability.values.length));
      for (final snapshot in snapshots) {
        expect(snapshot.accountId, 'account-a');
        expect(snapshot.facadeGeneration, 7);
        expect(snapshot.capturedAt, now);
        expect(snapshot.freshness, EmbodiedFreshness.fresh);
        final readOnly =
            snapshot.capability == EmbodiedDeviceCapability.status ||
            snapshot.capability == EmbodiedDeviceCapability.health;
        expect(snapshot.supported, readOnly);
        expect(
          snapshot.unit,
          readOnly ? EmbodiedUnit.boolean : EmbodiedUnit.none,
        );
      }
    },
  );

  test('reads connection and background telemetry at call time', () async {
    final subject = adapter();

    var telemetry = await subject.telemetry();
    expect(telemetry.connected, isFalse);
    expect(telemetry.backgrounded, isFalse);
    expect((telemetry.value! as EmbodiedBooleanValue).value, isFalse);

    transport.isConnected.value = true;
    backgrounded = true;
    now = now.add(const Duration(seconds: 1));
    telemetry = await subject.telemetry();

    expect(telemetry.connected, isTrue);
    expect(telemetry.backgrounded, isTrue);
    expect(telemetry.capturedAt, now);
    expect((telemetry.value! as EmbodiedBooleanValue).value, isTrue);
    expect((await subject.status()).status, EmbodiedResultStatus.ok);
    expect((await subject.health()).status, EmbodiedResultStatus.ok);
  });

  test(
    'never maps semantic motion or stop to the projector protocol',
    () async {
      final subject = adapter();
      final owner = Object();
      motionAuthority.issuer.claim(owner);
      final capability = motionAuthority.issuer.issue(
        owner: owner,
        accountId: 'account-a',
        facadeGeneration: 7,
        capability: EmbodiedDeviceCapability.move,
        distanceMeters: 1,
        angleDegrees: 0,
        speedMetersPerSecond: 0.25,
        duration: const Duration(milliseconds: 500),
        issuedAt: now,
        expiresAt: now.add(const Duration(milliseconds: 500)),
      );
      final arm = subject.armDeadMan(capability);
      final armResult = await arm.result;
      await arm.cancelAndDrain();
      final stop = subject.beginStop();

      final results = <EmbodiedDeviceResult>[
        await subject.sense(
          const EmbodiedSenseRequest(
            kind: EmbodiedSenseKind.distance,
            unit: EmbodiedUnit.meters,
          ),
        ),
        await stop.result,
      ];

      expect(armResult.status, EmbodiedDeadManArmStatus.unsupported);
      expect(armResult.receipt, isNull);
      expect(
        results.map((result) => result.status),
        everyElement(EmbodiedResultStatus.unsupported),
      );
      expect(
        results.map((result) => result.diagnostic),
        everyElement('capability_unsupported'),
      );
      expect(device.isTransferring.value, isFalse);
      expect(device.transferProgress.value, 0);
      expect(transport.writeCalls, 0);
    },
  );

  test('retirement fences synchronously and never writes transport', () async {
    final subject = adapter();

    final retiring = subject.retireAndDrain();

    await expectLater(subject.status(), throwsStateError);
    await expectLater(subject.telemetry(), throwsStateError);
    expect(subject.beginStop, throwsStateError);
    await retiring;
    await subject.retireAndDrain();
    expect(transport.writeCalls, 0);
  });

  test(
    'retirement succeeds after the storage-mount authority is fenced',
    () async {
      final subject = adapter();
      expect((await subject.status()).status, EmbodiedResultStatus.ok);

      authorityCurrent = false;
      final retiring = subject.retireAndDrain();

      await expectLater(subject.status(), throwsStateError);
      await retiring;
      expect(transport.writeCalls, 0);
    },
  );

  test('old adapter fails closed after account authority rotates', () async {
    final subject = adapter();
    expect((await subject.telemetry()).accountId, 'account-a');

    authorityCurrent = false;
    await device.deactivateAccountAndDrain();
    device.activateAccount(accountScopeKey: 'account-b');

    await expectLater(subject.status(), throwsStateError);
    await expectLater(subject.telemetry(), throwsStateError);
    expect(subject.beginStop, throwsStateError);
  });

  test('rejects unbounded identity inputs', () {
    expect(
      () => YoturetoysEmbodiedDeviceAdapter(
        device: device,
        deviceId: ' ',
        accountId: 'account-a',
        facadeGeneration: 1,
        authorityIsCurrent: (_, _) => true,
        motionCapabilityVerifier: motionAuthority.verifier,
      ),
      throwsArgumentError,
    );
    expect(
      () => YoturetoysEmbodiedDeviceAdapter(
        device: device,
        accountId: ' ',
        facadeGeneration: 1,
        authorityIsCurrent: (_, _) => true,
        motionCapabilityVerifier: motionAuthority.verifier,
      ),
      throwsArgumentError,
    );
    expect(
      () => YoturetoysEmbodiedDeviceAdapter(
        device: device,
        accountId: 'account-a',
        facadeGeneration: 0,
        authorityIsCurrent: (_, _) => true,
        motionCapabilityVerifier: motionAuthority.verifier,
      ),
      throwsArgumentError,
    );
  });
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
