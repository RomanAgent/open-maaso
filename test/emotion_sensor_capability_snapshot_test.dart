import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:camera/camera.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:maaso/src/core/services/vision_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  tearDown(appServices.reset);

  test('face detection uses the exact platform capability key', () {
    expect(EmotionSensorService.sensingCapabilityKeys, <AppCapabilityKey>{
      AppCapabilityKey.platformAction(
        AppActionCapability.onDeviceFaceDetection,
      ),
    });
  });

  test(
    'denied automatic and toggle starts stop before camera loading',
    () async {
      final snapshots = _snapshotFor(AppHostPlatform.macos);
      addTearDown(snapshots.closeLifecycle);
      var cameraLoads = 0;
      final sensor = EmotionSensorService(
        capabilitySnapshotService: snapshots,
        cameraLoader: () async {
          cameraLoads++;
          return const <CameraDescription>[];
        },
      );

      await sensor.start();
      await sensor.start();

      expect(sensor.sensingAvailable, isFalse);
      expect(cameraLoads, 0);
      expect(sensor.userEnabled.value, isFalse);
      expect(sensor.isStarting.value, isFalse);
      expect(sensor.isRunning.value, isFalse);
    },
  );

  test(
    'snapshot invalidation during camera initialize disposes without running',
    () async {
      final snapshots = _snapshotFor(AppHostPlatform.ios);
      addTearDown(snapshots.closeLifecycle);
      final camera = _TrackingCameraController(gateInitialize: true);
      var detectorCreations = 0;
      final sensor = EmotionSensorService(
        capabilitySnapshotService: snapshots,
        cameraLoader: () async => const <CameraDescription>[
          _TrackingCameraController.cameraDescription,
        ],
        cameraFactory: (_) => camera,
        detectorFactory: () {
          detectorCreations++;
          return _TrackingFaceDetector();
        },
      );

      final starting = sensor.start();
      await camera.initializeEntered.future;
      expect(sensor.isStarting.value, isTrue);

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
      );
      camera.releaseInitialize.complete();

      await starting;
      await camera.disposed.future;
      expect(camera.disposeCount, 1);
      expect(detectorCreations, 0);
      expect(sensor.isStarting.value, isFalse);
      expect(sensor.isRunning.value, isFalse);
    },
  );

  test(
    'snapshot invalidation drains even when camera initialize never completes',
    () async {
      final snapshots = _snapshotFor(AppHostPlatform.ios);
      addTearDown(snapshots.closeLifecycle);
      final camera = _TrackingCameraController(
        gateInitialize: true,
        gateDispose: true,
      );
      final sensor = EmotionSensorService(
        capabilitySnapshotService: snapshots,
        cameraLoader: () async => const <CameraDescription>[
          _TrackingCameraController.cameraDescription,
        ],
        cameraFactory: (_) => camera,
        detectorFactory: () =>
            throw StateError('a revoked startup must not create its detector'),
      );

      final starting = sensor.start();
      await camera.initializeEntered.future;

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
      );

      await camera.disposeEntered.future.timeout(const Duration(seconds: 1));
      final stopping = sensor.stop();
      await expectLater(
        stopping.timeout(const Duration(seconds: 1)),
        throwsA(isA<TimeoutException>()),
      );
      expect(camera.disposeCount, 1);
      expect(sensor.isStarting.value, isFalse);
      expect(sensor.isRunning.value, isFalse);

      camera.releaseInitialize.complete();
      await starting.timeout(const Duration(seconds: 1));
      await sensor.stop();
      expect(camera.disposeCount, 2);
    },
  );

  test(
    'an in-flight frame cannot emit derived events after invalidation',
    () async {
      final snapshots = _snapshotFor(AppHostPlatform.ios);
      addTearDown(snapshots.closeLifecycle);
      final camera = _FrameCameraController();
      final detector = _GatedFrameDetector();
      final vision = _TrackingVisionService();
      appServices.put<VisionService>(vision);
      final events = <SystemStatusEvent>[];
      final eventSubscription = EventBus().on<SystemStatusEvent>().listen(
        events.add,
      );
      addTearDown(eventSubscription.cancel);
      final sensor = EmotionSensorService(
        capabilitySnapshotService: snapshots,
        cameraLoader: () async => const <CameraDescription>[
          _FrameCameraController.cameraDescription,
        ],
        cameraFactory: (_) => camera,
        detectorFactory: () => detector,
      );

      await sensor.start();
      await detector.processEntered.future.timeout(const Duration(seconds: 4));

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
      );
      detector.releaseProcess.complete();

      await camera.disposed.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(sensor.lastEmotion.value, isNull);
      expect(vision.analyzeCount, 0);
      expect(
        events.where(
          (event) =>
              event.triggerType.startsWith('user_emotion_') ||
              event.triggerType == 'vision_scene',
        ),
        isEmpty,
      );
    },
  );

  test(
    'failed invalidation teardown retries retained owners automatically',
    () async {
      final snapshots = _snapshotFor(AppHostPlatform.ios);
      addTearDown(snapshots.closeLifecycle);
      final camera = _FailOnceCameraController();
      addTearDown(() {
        if (!camera.releaseSecondDispose.isCompleted) {
          camera.releaseSecondDispose.complete();
        }
      });
      final detector = _TrackingFaceDetector();
      final sensor = EmotionSensorService(
        capabilitySnapshotService: snapshots,
        cameraLoader: () async => const <CameraDescription>[
          _FailOnceCameraController.cameraDescription,
        ],
        cameraFactory: (_) => camera,
        detectorFactory: () => detector,
      );

      await sensor.start();
      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
      );
      await camera.firstDisposeFailed.future;
      await detector.closed.future.timeout(const Duration(seconds: 1));
      await camera.secondDisposeEntered.future.timeout(
        const Duration(seconds: 1),
      );

      expect(camera.disposeCount, 2);
      expect(detector.closeCount, 1);
      expect(sensor.isRunning.value, isTrue);

      camera.releaseSecondDispose.complete();
      await camera.disposed.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);
      expect(camera.disposeCount, 2);
      expect(detector.closeCount, 1);
      expect(sensor.isRunning.value, isFalse);
    },
  );

  test('active capability invalidation releases camera and detector', () async {
    final snapshots = _snapshotFor(AppHostPlatform.ios);
    addTearDown(snapshots.closeLifecycle);
    final camera = _TrackingCameraController();
    final detector = _TrackingFaceDetector();
    final sensor = EmotionSensorService(
      capabilitySnapshotService: snapshots,
      cameraLoader: () async => const <CameraDescription>[
        _TrackingCameraController.cameraDescription,
      ],
      cameraFactory: (_) => camera,
      detectorFactory: () => detector,
    );

    await sensor.start();
    expect(sensor.isRunning.value, isTrue);

    snapshots.refresh(
      snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
    );

    await camera.disposed.future;
    await detector.closed.future;
    await Future<void>.delayed(Duration.zero);
    expect(camera.disposeCount, 1);
    expect(detector.closeCount, 1);
    expect(sensor.isRunning.value, isFalse);
    expect(sensor.userEnabled.value, isTrue);
  });

  test(
    'foreground resume reacquires capability before camera loading',
    () async {
      final snapshots = _snapshotFor(AppHostPlatform.ios);
      addTearDown(snapshots.closeLifecycle);
      final cameras = <_TrackingCameraController>[];
      var cameraLoads = 0;
      final sensor = EmotionSensorService(
        capabilitySnapshotService: snapshots,
        cameraLoader: () async {
          cameraLoads++;
          return const <CameraDescription>[
            _TrackingCameraController.cameraDescription,
          ];
        },
        cameraFactory: (_) {
          final camera = _TrackingCameraController();
          cameras.add(camera);
          return camera;
        },
        detectorFactory: _TrackingFaceDetector.new,
      );

      await sensor.start();
      expect(cameraLoads, 1);
      sensor.didChangeAppLifecycleState(AppLifecycleState.paused);
      await cameras.single.disposed.future;

      snapshots.refresh(
        snapshots.context.copyWith(hostPlatform: AppHostPlatform.macos),
      );
      sensor.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);

      expect(sensor.sensingAvailable, isFalse);
      expect(cameraLoads, 1);
      expect(sensor.isRunning.value, isFalse);
      expect(sensor.userEnabled.value, isTrue);
    },
  );
}

AppCapabilitySnapshotService _snapshotFor(AppHostPlatform platform) =>
    AppCapabilitySnapshotService(
      resolver: AppPlatformCapabilitySnapshotResolver(
        routeIds: const <String>{'home'},
      ),
      initialContext: AppCapabilitySnapshotContext(
        hostPlatform: platform,
        rolloutGeneration: 0,
      ),
    );

class _TrackingCameraController extends CameraController {
  _TrackingCameraController({
    bool gateInitialize = false,
    bool gateDispose = false,
  }) : _gateDispose = gateDispose,
       _gateInitialize = gateInitialize,
       super(cameraDescription, ResolutionPreset.low, enableAudio: false);

  static const CameraDescription cameraDescription = CameraDescription(
    name: 'capability-test-camera',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 0,
  );

  final bool _gateInitialize;
  final bool _gateDispose;
  final Completer<void> initializeEntered = Completer<void>();
  final Completer<void> releaseInitialize = Completer<void>();
  final Completer<void> disposeEntered = Completer<void>();
  final Completer<void> disposed = Completer<void>();
  int disposeCount = 0;

  @override
  Future<void> initialize() async {
    initializeEntered.complete();
    if (_gateInitialize) await releaseInitialize.future;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (!disposeEntered.isCompleted) disposeEntered.complete();
    if (_gateDispose) await releaseInitialize.future;
    if (!disposed.isCompleted) disposed.complete();
    await super.dispose();
  }
}

class _TrackingFaceDetector extends FaceDetector {
  _TrackingFaceDetector() : super(options: FaceDetectorOptions());

  final Completer<void> closed = Completer<void>();
  int closeCount = 0;

  @override
  Future<void> close() async {
    closeCount++;
    if (!closed.isCompleted) closed.complete();
  }
}

class _FrameCameraController extends CameraController {
  _FrameCameraController()
    : super(cameraDescription, ResolutionPreset.low, enableAudio: false);

  static const CameraDescription cameraDescription = CameraDescription(
    name: 'frame-capability-test-camera',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 0,
  );

  final Completer<void> disposed = Completer<void>();

  // The camera package keeps this constructor specifically for synthetic
  // method-channel frames; using it avoids a test-only direct dependency on
  // camera_platform_interface.
  // ignore: deprecated_member_use
  static final CameraImage frame = CameraImage.fromPlatformData(
    <dynamic, dynamic>{
      'format': 17,
      'height': 2,
      'width': 2,
      'lensAperture': null,
      'sensorExposureTime': null,
      'sensorSensitivity': null,
      'planes': <dynamic>[
        <dynamic, dynamic>{
          'bytes': Uint8List(4),
          'bytesPerPixel': 1,
          'bytesPerRow': 2,
          'height': 2,
          'width': 2,
        },
      ],
    },
  );

  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> startImageStream(onLatestImageAvailable onAvailable) async {
    value = value.copyWith(isStreamingImages: true);
    scheduleMicrotask(() => onAvailable(frame));
  }

  @override
  Future<void> stopImageStream() async {
    value = value.copyWith(isStreamingImages: false);
  }

  @override
  Future<void> dispose() async {
    if (!disposed.isCompleted) disposed.complete();
    await super.dispose();
  }
}

class _GatedFrameDetector extends FaceDetector {
  _GatedFrameDetector() : super(options: FaceDetectorOptions());

  final Completer<void> processEntered = Completer<void>();
  final Completer<void> releaseProcess = Completer<void>();

  @override
  Future<List<Face>> processImage(InputImage inputImage) async {
    processEntered.complete();
    await releaseProcess.future;
    return <Face>[
      Face(
        boundingBox: const Rect.fromLTWH(0, 0, 2, 2),
        landmarks: const <FaceLandmarkType, FaceLandmark?>{},
        contours: const <FaceContourType, FaceContour?>{},
        smilingProbability: 0.9,
        leftEyeOpenProbability: 0.9,
        rightEyeOpenProbability: 0.9,
      ),
    ];
  }

  @override
  Future<void> close() async {}
}

class _TrackingVisionService extends VisionService {
  int analyzeCount = 0;

  @override
  Future<String?> analyzeFrame(CameraImage frame) async {
    analyzeCount++;
    return 'derived scene';
  }
}

class _FailOnceCameraController extends CameraController {
  _FailOnceCameraController()
    : super(cameraDescription, ResolutionPreset.low, enableAudio: false);

  static const CameraDescription cameraDescription = CameraDescription(
    name: 'fail-once-capability-test-camera',
    lensDirection: CameraLensDirection.front,
    sensorOrientation: 0,
  );

  final Completer<void> firstDisposeFailed = Completer<void>();
  final Completer<void> secondDisposeEntered = Completer<void>();
  final Completer<void> releaseSecondDispose = Completer<void>();
  final Completer<void> disposed = Completer<void>();
  int disposeCount = 0;

  @override
  Future<void> initialize() async {
    value = value.copyWith(isInitialized: true);
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    if (disposeCount == 1) {
      firstDisposeFailed.complete();
      throw StateError('first capability teardown failed');
    }
    if (!secondDisposeEntered.isCompleted) secondDisposeEntered.complete();
    await releaseSecondDispose.future;
    await super.dispose();
    if (!disposed.isCompleted) disposed.complete();
  }
}
