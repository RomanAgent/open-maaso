import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/device/embodied_device_facade.dart';

void main() {
  test('semantic capabilities have explicit permission tiers', () {
    expect(
      <EmbodiedDeviceCapability>{
        EmbodiedDeviceCapability.status,
        EmbodiedDeviceCapability.health,
        EmbodiedDeviceCapability.sense,
      }.every(
        (capability) =>
            capability.permissionTier == EmbodiedPermissionTier.readOnly,
      ),
      isTrue,
    );
    expect(
      <EmbodiedDeviceCapability>{
        EmbodiedDeviceCapability.face,
        EmbodiedDeviceCapability.move,
        EmbodiedDeviceCapability.nod,
        EmbodiedDeviceCapability.shake,
        EmbodiedDeviceCapability.home,
      }.every(
        (capability) =>
            capability.permissionTier ==
            EmbodiedPermissionTier.consequentialMotion,
      ),
      isTrue,
    );
    expect(
      EmbodiedDeviceCapability.stop.permissionTier,
      EmbodiedPermissionTier.emergencySafety,
    );
  });

  test(
    'capability result and telemetry carry scope freshness time and unit',
    () {
      final capturedAt = DateTime.utc(2026, 8, 30, 12);
      final capability = EmbodiedCapabilitySnapshot(
        capability: EmbodiedDeviceCapability.move,
        supported: true,
        unit: EmbodiedUnit.meters,
        capturedAt: capturedAt,
        freshness: EmbodiedFreshness.fresh,
        accountId: 'account-a',
        facadeGeneration: 7,
      );
      final telemetry = EmbodiedDeviceTelemetry(
        unit: EmbodiedUnit.meters,
        capturedAt: capturedAt,
        freshness: EmbodiedFreshness.fresh,
        accountId: 'account-a',
        facadeGeneration: 7,
        connected: true,
        backgrounded: false,
        value: const EmbodiedNumericValue(0.8),
      );
      final result = EmbodiedDeviceResult(
        capability: EmbodiedDeviceCapability.status,
        status: EmbodiedResultStatus.ok,
        unit: EmbodiedUnit.none,
        capturedAt: capturedAt,
        freshness: EmbodiedFreshness.fresh,
        accountId: 'account-a',
        facadeGeneration: 7,
        value: const EmbodiedBooleanValue(true),
      );

      for (final item in <Object>[capability, telemetry, result]) {
        expect(item, isNotNull);
      }
      expect(capability.unit, EmbodiedUnit.meters);
      expect(telemetry.capturedAt, capturedAt);
      expect(telemetry.accountId, 'account-a');
      expect(result.freshness, EmbodiedFreshness.fresh);
      expect(result.facadeGeneration, 7);
    },
  );

  test('facade exposes no raw transport or unrestricted operation surface', () {
    final source = File(
      'lib/src/core/services/device/embodied_device_facade.dart',
    ).readAsStringSync();
    final facade = _classBody(
      source,
      'abstract interface class EmbodiedDeviceFacade',
    );
    final lower = facade.toLowerCase();

    for (final forbidden in <String>[
      'gatt',
      'serial',
      'uint8list',
      'bytebuffer',
      'bytes',
      'command',
      'list<int>',
      ' write(',
      ' send(',
      ' execute(',
      ' connect(',
    ]) {
      expect(lower, isNot(contains(forbidden)), reason: forbidden);
    }
    for (final semanticMethod in <String>[
      'capabilities()',
      'get deviceId',
      'status()',
      'health()',
      'telemetry()',
      'sense(',
      'armDeadMan(',
      'beginMotion(',
      'beginStop()',
      'retireAndDrain()',
    ]) {
      expect(facade, contains(semanticMethod), reason: semanticMethod);
    }
    for (final bypass in <String>[
      'face(',
      'move(',
      'nod(',
      'shake(',
      'home(',
      'Future<EmbodiedDeviceResult> stop()',
    ]) {
      expect(facade, isNot(contains(bypass)), reason: bypass);
    }
    expect(source, isNot(contains('class BoundedEmbodiedMotion')));
    expect(source, isNot(contains('class EmbodiedMotionLease')));
  });

  test('opaque motion capability is issuer-bound and consumed once', () {
    final pair = createEmbodiedMotionAuthorityPair();
    final other = createEmbodiedMotionAuthorityPair();
    final owner = Object();
    pair.issuer.claim(owner);
    final capability = pair.issuer.issue(
      owner: owner,
      accountId: 'account-a',
      facadeGeneration: 1,
      capability: EmbodiedDeviceCapability.move,
      distanceMeters: 0.5,
      angleDegrees: 0,
      speedMetersPerSecond: 0.25,
      duration: const Duration(milliseconds: 500),
      issuedAt: DateTime.utc(2026, 8, 30, 8),
      expiresAt: DateTime.utc(2026, 8, 30, 8, 0, 1),
    );
    expect(
      () => pair.verifier.recordHardwareDeadManArmed(
        capability: capability,
        monotonicArmedAtMicros: 100,
        monotonicExpiresAtMicros: 1000101,
      ),
      throwsStateError,
      reason: 'hardware TTL cannot outlive the bounded supervisor lease',
    );
    final receipt = pair.verifier.recordHardwareDeadManArmed(
      capability: capability,
      monotonicArmedAtMicros: 100,
      monotonicExpiresAtMicros: 1000,
    );

    expect(other.verifier.recognizes(capability), isFalse);
    expect(
      () => pair.issuer.issue(
        owner: Object(),
        accountId: 'account-a',
        facadeGeneration: 1,
        capability: EmbodiedDeviceCapability.move,
        distanceMeters: 0.5,
        angleDegrees: 0,
        speedMetersPerSecond: 0.25,
        duration: const Duration(milliseconds: 500),
        issuedAt: DateTime.utc(2026, 8, 30, 8),
        expiresAt: DateTime.utc(2026, 8, 30, 8, 0, 1),
      ),
      throwsStateError,
    );
    final verified = pair.verifier.consume(
      capability,
      receipt,
      monotonicNowMicros: 500,
    );
    expect(verified.capability, EmbodiedDeviceCapability.move);
    expect(
      () => pair.verifier.consume(capability, receipt, monotonicNowMicros: 500),
      throwsStateError,
    );
  });
}

String _classBody(String source, String declaration) {
  final start = source.indexOf(declaration);
  expect(start, greaterThanOrEqualTo(0));
  final open = source.indexOf('{', start);
  var depth = 0;
  for (var index = open; index < source.length; index += 1) {
    if (source[index] == '{') depth += 1;
    if (source[index] == '}') {
      depth -= 1;
      if (depth == 0) return source.substring(start, index + 1);
    }
  }
  fail('facade declaration is incomplete');
}
