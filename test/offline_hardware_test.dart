import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/offline/offline_hardware.dart';

class _Transport extends BleTransportService {
  int scans = 0, retirements = 0;
  // The test transport deliberately avoids subscribing to a real radio.
  @override
  // ignore: must_call_super
  void onInit() {}
  @override
  // ignore: must_call_super
  void onClose() {}
  @override
  Future<void> scan(
    BleDeviceProfile profile, {
    int seconds = 10,
    BleCapabilityAuthority? capabilityAuthority,
  }) async {
    scans++;
  }

  @override
  Future<void> deactivateAccountAndDrain() async {
    retirements++;
  }
}

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });
  tearDown(appServices.reset);
  test(
    'opening offline controller does not initialize or scan Bluetooth',
    () async {
      var created = 0;
      final c = OfflineHardwareController(
        transportFactory: () {
          created++;
          return _Transport();
        },
      );
      expect(c.initialized, isFalse);
      expect(created, 0);
      await c.retire();
      expect(created, 0);
      c.dispose();
    },
  );
  test(
    'explicit scan reuses one transport and retires account on exit',
    () async {
      var created = 0;
      final transport = _Transport();
      final c = OfflineHardwareController(
        transportFactory: () {
          created++;
          return transport;
        },
      );
      await c.scan();
      await c.scan();
      expect(created, 1);
      expect(transport.scans, 2);
      expect(
        identical(appServices.find<BleTransportService>(), transport),
        isTrue,
      );
      await c.retire();
      expect(transport.retirements, greaterThanOrEqualTo(1));
      c.dispose();
    },
  );
}
