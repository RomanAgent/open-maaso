import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  test(
    'stop waits for camera initialization and then disposes the camera',
    () async {
      final camera = _GatedInitializeCameraController();
      final sensor = EmotionSensorService(
        cameraLoader: () async => const <CameraDescription>[
          _GatedInitializeCameraController.cameraDescription,
        ],
        cameraFactory: (description) {
          expect(
            description,
            _GatedInitializeCameraController.cameraDescription,
          );
          return camera;
        },
        detectorFactory: () => throw StateError(
          'a fenced start must not create a detector after stop begins',
        ),
      );

      final starting = sensor.start();
      await camera.initializeEntered.future;

      var stopCompleted = false;
      final stopping = sensor.stop().whenComplete(() => stopCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(stopCompleted, isFalse);
      expect(camera.disposeCount, 0);
      expect(sensor.isStarting.value, isTrue);
      expect(sensor.isRunning.value, isFalse);

      camera.releaseInitialize.complete();
      await starting;
      await stopping;

      expect(camera.initializeCount, 1);
      expect(camera.disposeCount, 1);
      expect(stopCompleted, isTrue);
      expect(sensor.isStarting.value, isFalse);
      expect(sensor.isRunning.value, isFalse);
      expect(camera.debugCheckIsDisposed, returnsNormally);
    },
  );
}

class _GatedInitializeCameraController extends CameraController {
  _GatedInitializeCameraController()
    : super(cameraDescription, ResolutionPreset.low, enableAudio: false);

  static const CameraDescription cameraDescription = CameraDescription(
    name: 'gated-initialize-camera',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 0,
  );

  final Completer<void> initializeEntered = Completer<void>();
  final Completer<void> releaseInitialize = Completer<void>();

  int initializeCount = 0;
  int disposeCount = 0;

  @override
  Future<void> initialize() async {
    initializeCount++;
    initializeEntered.complete();
    await releaseInitialize.future;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    await super.dispose();
  }
}
