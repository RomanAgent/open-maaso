import 'dart:async';

import 'package:camera/camera.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'stop deduplicates and retains the camera until a retry disposes it',
    () async {
      final camera = _FailOnceCameraController();
      final sensor = EmotionSensorService(camera: camera);
      sensor.isRunning.value = true;
      sensor.lastEmotion.value = 'happy';

      final first = sensor.stop();
      await camera.firstDisposeEntered.future;
      final concurrent = sensor.stop();

      expect(identical(first, concurrent), isTrue);
      expect(camera.disposeCount, 1);
      expect(sensor.isRunning.value, isTrue);

      final firstFailure = expectLater(
        first,
        throwsA(same(camera.firstDisposeFailure)),
      );
      final concurrentFailure = expectLater(
        concurrent,
        throwsA(same(camera.firstDisposeFailure)),
      );
      camera.releaseFirstDispose.complete();
      await Future.wait<void>([firstFailure, concurrentFailure]);

      expect(camera.disposeCount, 1);
      expect(sensor.isRunning.value, isTrue);
      expect(sensor.lastEmotion.value, 'happy');

      await sensor.stop();

      expect(camera.disposeCount, 2);
      expect(sensor.isRunning.value, isFalse);
      expect(sensor.lastEmotion.value, isNull);
    },
  );
}

class _FailOnceCameraController extends CameraController {
  _FailOnceCameraController()
    : super(
        const CameraDescription(
          name: 'retry-test-camera',
          lensDirection: CameraLensDirection.front,
          sensorOrientation: 0,
        ),
        ResolutionPreset.low,
        enableAudio: false,
      );

  final Object firstDisposeFailure = StateError('first camera dispose failed');
  final Completer<void> firstDisposeEntered = Completer<void>();
  final Completer<void> releaseFirstDispose = Completer<void>();

  int disposeCount = 0;

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (disposeCount == 1) {
      firstDisposeEntered.complete();
      await releaseFirstDispose.future;
      throw firstDisposeFailure;
    }
    await super.dispose();
  }
}
