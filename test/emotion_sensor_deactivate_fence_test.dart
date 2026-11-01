import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test(
    'normal stop stays reusable but account deactivation is permanent',
    () async {
      var cameraLoads = 0;
      final service = EmotionSensorService(
        cameraLoader: () async {
          cameraLoads += 1;
          return const <CameraDescription>[];
        },
      );

      await service.start();
      await service.stop();
      await service.start();
      expect(
        cameraLoads,
        2,
        reason: 'normal lifecycle stop must remain reusable',
      );

      await service.deactivateAndDrain();
      await service.start();
      expect(
        cameraLoads,
        2,
        reason: 'retired account must never reopen camera',
      );
      expect(service.isRunning.value, isFalse);
    },
  );
}
