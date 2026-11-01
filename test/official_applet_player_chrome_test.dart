import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';
import 'package:maaso/src/features/applets/presentation/ble_projector/ble_projector_applet.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets(
    'official applet keeps back and like chrome and native device controls',
    (tester) async {
      final device = appServices.put<YoturetoysDevice>(_Device()) as _Device;
      await tester.pumpWidget(const MaterialApp(home: BleProjectorApplet()));
      await tester.pump();

      expect(find.byKey(const ValueKey('applet-player-back')), findsOneWidget);
      expect(find.byKey(const ValueKey('applet-player-like')), findsOneWidget);
      expect(find.text('applet.projector.title'.tr), findsNothing);
      expect(find.text('applet.projector.pick_gallery'.tr), findsOneWidget);
      expect(find.text('applet.projector.disconnect'.tr), findsOneWidget);
      await tester.tap(find.text('applet.projector.disconnect'.tr));
      await tester.pump();
      expect(device.disconnectCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );
}

class _Device extends YoturetoysDevice {
  _Device() : super(BleTransportService());
  final RxBool _connected = true.obs;
  int disconnectCalls = 0;
  @override
  bool get bluetoothAvailable => false;
  @override
  RxBool get isConnected => _connected;
  @override
  Future<void> disconnect() async {
    disconnectCalls++;
    _connected.value = false;
  }
}
