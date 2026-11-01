import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/skills/ble_yoturetoys_skill.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';

/// Controllable stand-in: overrides the connection flag and records the bytes
/// handed to projectImage, so we test the skill without a real radio.
class _FakeDevice extends YoturetoysDevice {
  _FakeDevice() : super(BleTransportService());
  final RxBool _conn = false.obs;
  @override
  Future<T> runAccountOperation<T>(Future<T> Function() operation) =>
      operation();
  @override
  RxBool get isConnected => _conn;
  List<int>? sent;
  @override
  Future<void> projectImage(List<int> bytes, {int quality = 80}) async {
    sent = bytes;
  }
}

Future<Map<String, dynamic>> _call(BleYoturetoysSkill skill) async {
  final out = await skill.methods['projectorSendGallery']!([]) as String;
  return jsonDecode(out) as Map<String, dynamic>;
}

void main() {
  late _FakeDevice device;

  setUp(() {
    device = _FakeDevice();
    appServices.put<YoturetoysDevice>(device);
  });
  tearDown(appServices.reset);

  test('errors and does not send when not connected', () async {
    device._conn.value = false;
    final skill = BleYoturetoysSkill()
      ..connectWait = Duration
          .zero // don't wait in the never-connects case
      ..galleryPicker = () async => [1, 2, 3];
    final res = await _call(skill);
    expect(res['error'], isNotNull);
    expect(device.sent, isNull);
  });

  test('waits for an in-flight connection, then projects', () async {
    // Mirrors the real flow: the agent's connect is still completing when the
    // user picks "gallery". _ensureConnected should wait, not fail.
    device._conn.value = false;
    final skill = BleYoturetoysSkill()
      ..connectWait = const Duration(seconds: 3)
      ..galleryPicker = () async => [4, 5, 6];
    Future<void>.delayed(
      const Duration(milliseconds: 400),
      () => device._conn.value = true,
    );
    final res = await _call(skill);
    expect(res['ok'], isTrue);
    expect(device.sent, [4, 5, 6]);
  });

  test('reports cancelled when the picker returns null', () async {
    device._conn.value = true;
    final skill = BleYoturetoysSkill()..galleryPicker = () async => null;
    final res = await _call(skill);
    expect(res['cancelled'], isTrue);
    expect(device.sent, isNull);
  });

  test('projects the picked bytes when connected', () async {
    device._conn.value = true;
    final skill = BleYoturetoysSkill()..galleryPicker = () async => [9, 8, 7];
    final res = await _call(skill);
    expect(res['ok'], isTrue);
    expect(device.sent, [9, 8, 7]);
  });
}
