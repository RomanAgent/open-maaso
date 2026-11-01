import 'dart:async';
import 'dart:ui' show Size;

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart'
    show AppLifecycleState, WidgetsBinding, WidgetsBindingObserver;
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/gaze_director.dart';
import 'package:maaso/src/core/services/vision_service.dart';

typedef EmotionCameraLoader = Future<List<CameraDescription>> Function();
typedef EmotionCameraFactory =
    CameraController Function(CameraDescription description);
typedef EmotionDetectorFactory = FaceDetector Function();

Future<List<CameraDescription>> _loadEmotionCameras() => availableCameras();

CameraController _createEmotionCamera(CameraDescription description) =>
    CameraController(
      description,
      ResolutionPreset.low,
      enableAudio: false,
      fps: 5,
      imageFormatGroup: defaultTargetPlatform == TargetPlatform.iOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.nv21,
    );

FaceDetector _createEmotionDetector() => FaceDetector(
  options: FaceDetectorOptions(
    enableClassification: true,
    enableContours: false,
    enableLandmarks: false,
    enableTracking: false,
    performanceMode: FaceDetectorMode.fast,
    minFaceSize: 0.15,
  ),
);

/// MVP — opens the front camera, samples a frame every ~1.5s, runs ML Kit
/// face detection locally, and fires [SystemStatusEvent]s with triggerType
/// `user_emotion_<label>` so the agent runtime can react via its existing
/// proactive-event pipeline (same channel as battery_low etc).
///
/// Privacy: frames never leave the device.  Only the derived label + a few
/// probabilities are emitted on the EventBus.
class EmotionSensorService extends AppService with WidgetsBindingObserver {
  EmotionSensorService({
    String storageKeyPrefix = '',
    @visibleForTesting AppCapabilitySnapshotService? capabilitySnapshotService,
    @visibleForTesting CameraController? camera,
    @visibleForTesting FaceDetector? detector,
    @visibleForTesting EmotionCameraLoader cameraLoader = _loadEmotionCameras,
    @visibleForTesting
    EmotionCameraFactory cameraFactory = _createEmotionCamera,
    @visibleForTesting
    EmotionDetectorFactory detectorFactory = _createEmotionDetector,
  }) : _camera = camera,
       _detector = detector,
       _capabilitySnapshotService = capabilitySnapshotService,
       _storageKeyPrefix = storageKeyPrefix.trim(),
       _cameraLoader = cameraLoader,
       _cameraFactory = cameraFactory,
       _detectorFactory = detectorFactory;

  static final Set<AppCapabilityKey> sensingCapabilityKeys =
      Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
        AppCapabilityKey.platformAction(
          AppActionCapability.onDeviceFaceDetection,
        ),
      });

  CameraController? _camera;
  FaceDetector? _detector;
  final AppCapabilitySnapshotService? _capabilitySnapshotService;
  final String _storageKeyPrefix;
  final EmotionCameraLoader _cameraLoader;
  final EmotionCameraFactory _cameraFactory;
  final EmotionDetectorFactory _detectorFactory;
  Future<void>? _startFuture;
  Future<void>? _stopFuture;
  Future<void>? _capabilityCleanupFuture;
  int _lifecycleGeneration = 0;
  int _capabilityFenceGeneration = 0;
  _EmotionSensorCapabilityAuthority? _activeCapabilityAuthority;
  bool _retired = false;
  bool _stopping = false;
  Object? _processingToken;
  // Drives the duty-cycle sampler (see [_scheduleNextSample]).
  Timer? _sampleTimer;
  // Backoff state: flips true once the user is confirmed absent, switching the
  // sampler from the active cadence to the slower idle cadence to save power.
  bool _idle = false;
  DateTime _lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastVisionAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Wall-clock of the last frame in which a face was actually visible.
  // Used together with [AgentBehaviorConfig.absentReactDelay] to decide
  // when to fire the "they walked away" event.
  DateTime? _lastFaceSeenAt;
  // True once we've already emitted "absent" for the current absence run;
  // cleared as soon as a face shows up again.
  bool _absenceReported = false;
  String? _lastEmittedLabel;
  // Most-recent raw face-present observation (one frame); used to debounce
  // flips between happy / neutral / flat / sleepy.
  String? _pendingLabel;
  int _pendingStreak = 0;

  // Duty-cycle cadence.  Rather than streaming frames continuously, we grab a
  // single frame per tick and stop delivery in between (see [_captureOnce]).
  // While the user is present we sample at [_activeSampleInterval]; once
  // they're confirmed absent we back off to [_idleSampleInterval] to save
  // power, still polling slowly so we notice when they return.
  static const _activeSampleInterval = Duration(milliseconds: 2500);
  static const _idleSampleInterval = Duration(seconds: 5);
  static const _visionInterval = Duration(seconds: 30);
  static const _shutdownDrainTimeout = Duration(milliseconds: 250);
  static const _cleanupRetryInitialDelay = Duration(milliseconds: 10);
  // To suppress jitter (a single frame flip from happy↔neutral), require the
  // new label to appear in N consecutive samples before we treat it as a
  // real transition.
  static const _labelConfirmFrames = 2;

  // ——— Face-follow (gaze tracking) ———
  // While a face is present we leave the stream open and process at this cap
  // (~12fps) to drive the agent's gaze smoothly; otherwise we stay on the
  // power-saving duty cycle above. Face must be gone this long before we drop
  // back to the duty cycle (avoids flapping when the face briefly leaves frame).
  static const _followFrameGap = Duration(milliseconds: 80);
  static const _faceLostGrace = Duration(milliseconds: 1500);

  /// User switch for the gaze-follow behaviour (the emotion sensing still runs
  /// when off). Defaults on; tied to the camera being on, no separate UI yet.
  final RxBool followEnabled = true.obs;
  // True while the continuous tracking stream is open (vs. the duty cycle).
  bool _following = false;
  DateTime _lastStreamProcessAt = DateTime.fromMillisecondsSinceEpoch(0);
  // Gaze updates every processed frame, but the emotion/proactive pipeline is
  // throttled to [_activeSampleInterval] so its debounce/cooldown semantics are
  // unchanged regardless of the (much higher) follow-mode frame rate.
  DateTime _lastInterpretAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _lastFaceForGazeAt;

  GazeDirector? get _gaze => appServices.isRegistered<GazeDirector>()
      ? appServices.find<GazeDirector>()
      : null;

  AgentBehaviorConfig? get _cfg =>
      appServices.isRegistered<AgentBehaviorConfig>()
      ? appServices.find<AgentBehaviorConfig>()
      : null;

  /// Visible to UI / settings — flips true once camera + detector are live.
  final RxBool isRunning = false.obs;

  /// True while the camera/detector are being initialized.
  final RxBool isStarting = false.obs;

  /// User-facing privacy switch. When false, lifecycle resume will not reopen
  /// the front camera.  Loaded from SharedPreferences on init; defaults to
  /// false so the camera stays off until the user explicitly opts in.
  final RxBool userEnabled = false.obs;

  static const _kUserEnabledKey = 'emotion_sensor.user_enabled';

  String get _userEnabledKey => _storageKeyPrefix.isEmpty
      ? _kUserEnabledKey
      : '$_storageKeyPrefix.preferences.$_kUserEnabledKey';

  /// Most recent label we emitted.  UI can show this for debug.
  final RxnString lastEmotion = RxnString();

  /// Whether this host's current immutable capability snapshot admits opening
  /// the on-device face detector. A missing snapshot keeps focused tests and
  /// legacy embedders compatible; production always resolves the registered
  /// process-wide snapshot service.
  bool get sensingAvailable {
    final snapshots = _resolvedCapabilitySnapshots;
    if (snapshots == null) return true;
    if (snapshots.isClosed) return false;
    return snapshots.value.rejected(sensingCapabilityKeys).isEmpty;
  }

  /// Returns null if camera couldn't open (no permission, no front cam, …).
  /// The 3D avatar happily continues without it.
  Future<void> start() {
    if (isRunning.value || _retired || _stopping) {
      return Future<void>.value();
    }
    final inFlight = _startFuture;
    if (inFlight != null) return inFlight;
    late final _EmotionSensorCapabilityAuthority? capabilityAuthority;
    try {
      capabilityAuthority = _captureCapabilityAuthority();
    } catch (error) {
      Log.w('🎥 [Emotion] capability denied: $error');
      return Future<void>.value();
    }
    final capabilityFenceGeneration = ++_capabilityFenceGeneration;
    _activeCapabilityAuthority = capabilityAuthority;
    if (capabilityAuthority != null) {
      unawaited(
        capabilityAuthority.lease.whenInvalidated.then((_) {
          if (capabilityFenceGeneration != _capabilityFenceGeneration ||
              !identical(_activeCapabilityAuthority, capabilityAuthority)) {
            return;
          }
          _retireCapabilityAuthority();
          _stopBestEffort(retryUntilDrained: true);
        }),
      );
    }
    final generation = _lifecycleGeneration;
    late final Future<void> starting;
    starting = _startOnce(generation, capabilityAuthority).whenComplete(() {
      if (identical(_startFuture, starting)) _startFuture = null;
      if (!isRunning.value &&
          capabilityFenceGeneration == _capabilityFenceGeneration &&
          identical(_activeCapabilityAuthority, capabilityAuthority)) {
        _retireCapabilityAuthority();
      }
    });
    _startFuture = starting;
    return starting;
  }

  Future<void> _startOnce(
    int generation,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) async {
    CameraController? ownedCamera;
    FaceDetector? ownedDetector;
    try {
      _requireCapabilityCurrent(capabilityAuthority);
      userEnabled.value = true;
      final prefs = await SharedPreferences.getInstance();
      _requireCapabilityCurrent(capabilityAuthority);
      if (!_isStartCurrent(generation) || isRunning.value) return;
      await prefs.setBool(_userEnabledKey, true);
      _requireCapabilityCurrent(capabilityAuthority);
      if (!_isStartCurrent(generation) || isRunning.value) return;
      isStarting.value = true;
      final cameras = await _cameraLoader();
      _requireCapabilityCurrent(capabilityAuthority);
      if (!_isStartCurrent(generation)) return;
      if (cameras.isEmpty) {
        Log.i('🎥 [Emotion] no cameras available');
        return;
      }
      final front = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.front,
        orElse: () => cameras.first,
      );
      // Low res is plenty for face detection and keeps the per-frame cost
      // (and battery drain) tiny.
      //
      // fps:5 is the big win for the video stream: the sensor would otherwise
      // push ~30 fps, but we only run inference every [_sampleInterval] (1.5s),
      // so ~29/30 frames were captured, format-converted and copied into the
      // Dart heap only to be dropped in [_onFrame].  Capping the capture
      // session to 5 fps cuts that churn ~6× — less battery/heat, far less
      // GC pressure and memory traffic (which also eases the device-wide
      // memory pressure that was starving on-device inference).  5 fps still
      // yields ~7 frames per sample window, so detection cadence is unchanged.
      final controller = _cameraFactory(front);
      ownedCamera = controller;
      _camera = controller;
      await controller.initialize();
      _requireCapabilityCurrent(capabilityAuthority);
      if (!_isStartCurrent(generation)) return;

      final detector = _detectorFactory();
      ownedDetector = detector;
      _detector = detector;
      _requireCapabilityCurrent(capabilityAuthority);
      if (!_isStartCurrent(generation)) return;

      isRunning.value = true;
      _idle = false;
      _scheduleNextSample();
      Log.i(
        '🎥 [Emotion] front-camera sensing started '
        '(${front.lensDirection.name}, ${controller.value.previewSize}, '
        'duty-cycle)',
      );
    } catch (error) {
      Log.e('🎥 [Emotion] start failed: $error');
      try {
        await _releaseOwnedResources(
          camera: identical(_camera, ownedCamera) ? ownedCamera : null,
          detector: identical(_detector, ownedDetector) ? ownedDetector : null,
        );
      } catch (cleanupError, cleanupStackTrace) {
        _stopping = true;
        Log.w(
          '🎥 [Emotion] start cleanup failed; retaining resources for retry',
          error: cleanupError,
          stackTrace: cleanupStackTrace,
        );
        Error.throwWithStackTrace(cleanupError, cleanupStackTrace);
      }
    } finally {
      isStarting.value = false;
    }
  }

  Future<void> stop({bool userInitiated = false}) {
    _retireCapabilityAuthority();
    _lifecycleGeneration++;
    _stopping = true;
    final inFlight = _stopFuture;
    if (inFlight != null) return inFlight;
    late final Future<void> stopping;
    stopping = _stopOnce(userInitiated: userInitiated).whenComplete(() {
      if (identical(_stopFuture, stopping)) _stopFuture = null;
    });
    _stopFuture = stopping;
    return stopping;
  }

  /// Permanently fences this account-owned sensor and releases its camera.
  /// Unlike [stop], this is teardown-only: lifecycle resume cannot reopen the
  /// old account's camera while the next account graph is being mounted.
  Future<void> deactivateAndDrain() {
    _retired = true;
    _autoResume = false;
    return stop();
  }

  Future<void> _stopOnce({required bool userInitiated}) async {
    final starting = _startFuture;
    if (starting != null) {
      try {
        await starting.timeout(_shutdownDrainTimeout);
      } on TimeoutException {
        if (identical(_startFuture, starting)) _startFuture = null;
        Log.w(
          '🎥 [Emotion] startup did not quiesce before shutdown; '
          'continuing with fenced resource teardown',
        );
      } catch (error, stackTrace) {
        Log.w(
          '🎥 [Emotion] startup failed while shutdown was draining',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
    if (userInitiated) {
      userEnabled.value = false;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_userEnabledKey, false);
    }
    isStarting.value = false;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    _following = false;
    _lastFaceForGazeAt = null;
    _gaze?.setFaceGaze(null); // hand the eyes back to the window/idle gaze
    await _releaseResources();
    isRunning.value = false;
    lastEmotion.value = null;
    _stopping = false;
  }

  Future<void> _releaseResources() async {
    final c = _camera;
    final d = _detector;
    if (c != null && c.value.isStreamingImages) {
      try {
        await c.stopImageStream().timeout(_shutdownDrainTimeout);
      } on TimeoutException {
        Log.w(
          '🎥 [Emotion] image stream did not stop before teardown; '
          'continuing with the capability fence active',
        );
      }
    }
    final processingToken = _processingToken;
    final drainDeadline = DateTime.now().add(_shutdownDrainTimeout);
    while (identical(_processingToken, processingToken) &&
        processingToken != null &&
        DateTime.now().isBefore(drainDeadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    if (identical(_processingToken, processingToken)) {
      _processingToken = null;
    }
    await _releaseOwnedResources(camera: c, detector: d);
  }

  Future<void> _releaseOwnedResources({
    required CameraController? camera,
    required FaceDetector? detector,
  }) async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() release) async {
      try {
        await release();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    if (camera != null) {
      await attempt(() async {
        await camera.dispose().timeout(_shutdownDrainTimeout);
        if (identical(_camera, camera)) _camera = null;
      });
    }
    if (detector != null) {
      await attempt(() async {
        await detector.close().timeout(_shutdownDrainTimeout);
        if (identical(_detector, detector)) _detector = null;
      });
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  bool _isStartCurrent(int generation) =>
      generation == _lifecycleGeneration && !_stopping;

  AppCapabilitySnapshotService? get _resolvedCapabilitySnapshots =>
      _capabilitySnapshotService ??
      appServices.maybeFind<AppCapabilitySnapshotService>();

  _EmotionSensorCapabilityAuthority? _captureCapabilityAuthority() {
    final snapshots = _resolvedCapabilitySnapshots;
    if (snapshots == null) return null;
    if (snapshots.isClosed) throw StateError('capability_unavailable');
    final acquisition = snapshots.acquireLease(sensingCapabilityKeys);
    final lease = acquisition.lease;
    if (lease == null) throw StateError('capability_unavailable');
    return _EmotionSensorCapabilityAuthority(snapshots, lease);
  }

  static void _requireCapabilityCurrent(
    _EmotionSensorCapabilityAuthority? authority,
  ) {
    if (authority == null) return;
    authority.snapshots.requireCurrent(authority.lease);
  }

  void _retireCapabilityAuthority() {
    _capabilityFenceGeneration++;
    _activeCapabilityAuthority = null;
  }

  bool _isRunCurrent(
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) {
    if (!isRunning.value ||
        _stopping ||
        lifecycleGeneration != _lifecycleGeneration ||
        !identical(_activeCapabilityAuthority, capabilityAuthority)) {
      return false;
    }
    if (capabilityAuthority != null) {
      try {
        return capabilityAuthority.snapshots.isCurrent(
          capabilityAuthority.lease,
        );
      } catch (_) {
        return false;
      }
    }
    try {
      return _resolvedCapabilitySnapshots == null;
    } catch (_) {
      return false;
    }
  }

  /// Schedule the next single-frame capture using the current cadence
  /// (active vs idle).  Self-reschedules from [_captureOnce]'s finally block.
  void _scheduleNextSample() {
    _sampleTimer?.cancel();
    final lifecycleGeneration = _lifecycleGeneration;
    final capabilityAuthority = _activeCapabilityAuthority;
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
    final interval = _idle ? _idleSampleInterval : _activeSampleInterval;
    _sampleTimer = Timer(
      interval,
      () => _captureOnce(lifecycleGeneration, capabilityAuthority),
    );
  }

  /// Duty-cycle core: briefly open the image stream, grab ONE frame, stop the
  /// stream, run detection, then schedule the next tick.  The camera session
  /// stays initialized (so restarting delivery is cheap) but no frames are
  /// copied into Dart between ticks — the per-frame video cost now happens
  /// ~once per interval instead of at the sensor's native frame rate.
  Future<void> _captureOnce(
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) async {
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
    if (_processingToken != null) {
      if (_isRunCurrent(lifecycleGeneration, capabilityAuthority)) {
        _scheduleNextSample();
      }
      return;
    }
    final processingToken = Object();
    _processingToken = processingToken;
    try {
      final frame = await _grabOneFrame(
        lifecycleGeneration,
        capabilityAuthority,
      );
      if (frame != null &&
          _isRunCurrent(lifecycleGeneration, capabilityAuthority)) {
        await _processFrame(frame, lifecycleGeneration, capabilityAuthority);
      }
    } catch (e) {
      Log.w('🎥 [Emotion] capture failed: $e');
    } finally {
      if (identical(_processingToken, processingToken)) {
        _processingToken = null;
      }
      // If that frame found a face, [_processFrame] switched us to the
      // continuous follow stream and cancelled the timer — don't reschedule.
      if (!_following &&
          _isRunCurrent(lifecycleGeneration, capabilityAuthority)) {
        _scheduleNextSample();
      }
    }
  }

  /// Open the stream just long enough to receive a single [CameraImage], then
  /// stop delivery.  Times out so a stalled sensor can't wedge the sampler.
  Future<CameraImage?> _grabOneFrame(
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) async {
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return null;
    final c = _camera;
    if (c == null) return null;
    final completer = Completer<CameraImage>();
    try {
      await c.startImageStream((image) {
        if (!completer.isCompleted &&
            _isRunCurrent(lifecycleGeneration, capabilityAuthority)) {
          completer.complete(image);
        }
      });
    } catch (_) {
      // Stream may already be running; fall through and await the next frame.
    }
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return null;
    CameraImage? frame;
    try {
      frame = await completer.future.timeout(const Duration(seconds: 2));
    } catch (_) {
      frame = null; // timeout / error — skip this tick
    } finally {
      try {
        if (c.value.isStreamingImages) await c.stopImageStream();
      } catch (_) {}
    }
    return frame;
  }

  /// Shared frame handler for both the duty-cycle sampler and the continuous
  /// follow stream. Runs detection once, then fans out to three rhythms:
  /// gaze (every frame), emotion (throttled), scene description (every 30s).
  Future<void> _processFrame(
    CameraImage image,
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) async {
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
    final detector = _detector;
    if (detector == null) return;
    final input = _toInputImage(image);
    if (input == null) return;
    List<Face> faces;
    try {
      faces = await detector.processImage(input);
    } catch (_) {
      return;
    }
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;

    final now = DateTime.now();
    // Gaze — every processed frame (up to ~12fps while following).
    _updateFaceGaze(faces, image, lifecycleGeneration, capabilityAuthority);
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
    // Emotion / proactive pipeline — throttled to the duty-cycle cadence so the
    // streak debounce + cooldown behave exactly as before, even at high fps.
    if (now.difference(_lastInterpretAt) >= _activeSampleInterval) {
      _lastInterpretAt = now;
      _interpret(faces);
    }
    // Scene description — unchanged 30s gate.
    if (now.difference(_lastVisionAt) >= _visionInterval &&
        appServices.isRegistered<VisionService>()) {
      if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
      _lastVisionAt = now;
      try {
        final desc = await appServices.find<VisionService>().analyzeFrame(
          image,
        );
        if (_isRunCurrent(lifecycleGeneration, capabilityAuthority) &&
            desc != null &&
            desc.isNotEmpty) {
          EventBus().fire(
            SystemStatusEvent('vision_scene', payload: {'description': desc}),
          );
        }
      } catch (_) {}
    }
  }

  /// Drive the agent's gaze from the largest face, and manage the follow-mode
  /// transition (duty cycle ↔ continuous stream).
  void _updateFaceGaze(
    List<Face> faces,
    CameraImage image,
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) {
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
    if (!followEnabled.value) return;
    final now = DateTime.now();
    if (faces.isNotEmpty) {
      _lastFaceForGazeAt = now;
      final f = _largestFace(faces);
      _gaze?.setFaceGaze(
        faceToGaze(
          boundingBox: f.boundingBox,
          frameSize: Size(image.width.toDouble(), image.height.toDouble()),
          eulerY: f.headEulerAngleY,
          eulerX: f.headEulerAngleX,
        ),
      );
      _enterFollowMode(lifecycleGeneration, capabilityAuthority);
    } else {
      // Hold the last gaze through a brief absence so a face slipping out of
      // frame for a frame or two doesn't snap the eyes back.
      final since = _lastFaceForGazeAt;
      if (since == null || now.difference(since) > _faceLostGrace) {
        _gaze?.setFaceGaze(null);
        _exitFollowMode();
      }
    }
  }

  Face _largestFace(List<Face> faces) {
    var best = faces.first;
    var bestArea = best.boundingBox.width * best.boundingBox.height;
    for (final f in faces.skip(1)) {
      final a = f.boundingBox.width * f.boundingBox.height;
      if (a > bestArea) {
        best = f;
        bestArea = a;
      }
    }
    return best;
  }

  /// Switch from the duty-cycle sampler to a continuous (throttled) stream so
  /// the gaze can track smoothly.
  void _enterFollowMode(
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) {
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
    if (_following) return;
    _following = true;
    _idle = false;
    _sampleTimer?.cancel();
    _sampleTimer = null;
    // ignore: unawaited_futures
    _startContinuousStream(lifecycleGeneration, capabilityAuthority);
  }

  /// Return to the power-saving duty cycle once the user is gone.
  void _exitFollowMode() {
    if (!_following) return;
    _following = false;
    // ignore: unawaited_futures
    _stopContinuousStream();
    _scheduleNextSample();
  }

  Future<void> _startContinuousStream(
    int lifecycleGeneration,
    _EmotionSensorCapabilityAuthority? capabilityAuthority,
  ) async {
    final c = _camera;
    if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority) ||
        c == null ||
        c.value.isStreamingImages) {
      return;
    }
    try {
      await c.startImageStream((image) {
        if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority) ||
            _processingToken != null) {
          return;
        }
        final now = DateTime.now();
        if (now.difference(_lastStreamProcessAt) < _followFrameGap) return;
        _lastStreamProcessAt = now;
        final processingToken = Object();
        _processingToken = processingToken;
        // ignore: unawaited_futures
        _processFrame(
          image,
          lifecycleGeneration,
          capabilityAuthority,
        ).whenComplete(() {
          if (identical(_processingToken, processingToken)) {
            _processingToken = null;
          }
        });
      });
      if (!_isRunCurrent(lifecycleGeneration, capabilityAuthority)) return;
      Log.i('🎥 [Emotion] follow mode → continuous stream (~12fps)');
    } catch (_) {}
  }

  Future<void> _stopContinuousStream() async {
    final c = _camera;
    if (c == null) return;
    try {
      if (c.value.isStreamingImages) await c.stopImageStream();
    } catch (_) {}
  }

  InputImage? _toInputImage(CameraImage image) {
    final camera = _camera?.description;
    if (camera == null) return null;
    final rotation =
        InputImageRotationValue.fromRawValue(camera.sensorOrientation) ??
        InputImageRotation.rotation0deg;
    final plane = image.planes.first;
    final format = defaultTargetPlatform == TargetPlatform.iOS
        ? InputImageFormat.bgra8888
        : InputImageFormat.nv21;
    return InputImage.fromBytes(
      bytes: plane.bytes,
      metadata: InputImageMetadata(
        size: Size(image.width.toDouble(), image.height.toDouble()),
        rotation: rotation,
        format: format,
        bytesPerRow: plane.bytesPerRow,
      ),
    );
  }

  void _interpret(List<Face> faces) {
    if (faces.isEmpty) {
      _handleAbsentFrame();
      return;
    }
    // Face is back — clear absence state so the next disappearance starts a
    // fresh timer, and return the sampler to its responsive active cadence.
    _lastFaceSeenAt = DateTime.now();
    _absenceReported = false;
    _idle = false;
    // Pick the largest face (closest to camera).
    faces.sort(
      (a, b) => (b.boundingBox.width * b.boundingBox.height).compareTo(
        a.boundingBox.width * a.boundingBox.height,
      ),
    );
    final f = faces.first;
    final smile = f.smilingProbability;
    final leftEye = f.leftEyeOpenProbability;
    final rightEye = f.rightEyeOpenProbability;
    final eyeOpen = (leftEye != null && rightEye != null)
        ? (leftEye + rightEye) / 2
        : null;

    String label;
    if (smile != null && smile > 0.65) {
      label = 'happy';
    } else if (eyeOpen != null && eyeOpen < 0.3) {
      label = 'sleepy';
    } else if (smile != null &&
        smile < 0.1 &&
        eyeOpen != null &&
        eyeOpen > 0.6) {
      label = 'flat'; // eyes open but no smile → possibly bored / serious
    } else {
      label = 'neutral';
    }

    _observe(label, {
      if (smile != null) 'smiling': double.parse(smile.toStringAsFixed(2)),
      if (eyeOpen != null) 'eyeOpen': double.parse(eyeOpen.toStringAsFixed(2)),
      if (f.headEulerAngleY != null)
        'yaw': double.parse(f.headEulerAngleY!.toStringAsFixed(1)),
      if (f.headEulerAngleX != null)
        'pitch': double.parse(f.headEulerAngleX!.toStringAsFixed(1)),
    });
  }

  /// Called every frame in which no face is detected.  We don't fire
  /// "absent" immediately — we wait until [AgentBehaviorConfig.absentReactDelay]
  /// of continuous absence has passed, and we only fire once per absence run.
  /// This is the knob the agent tunes when the user says "I'm busy, don't wait up".
  void _handleAbsentFrame() {
    final delay = _cfg?.absentReactDelay ?? const Duration(seconds: 10);
    final firstAbsence = _lastFaceSeenAt == null;
    _lastFaceSeenAt ??= DateTime.now();
    // If the configured delay hasn't elapsed yet, just keep waiting.
    final now = DateTime.now();
    if (now.difference(_lastFaceSeenAt!) < delay) {
      // Still mark the observable so debug UI can show "absent (waiting)".
      lastEmotion.value = firstAbsence ? 'absent?' : lastEmotion.value;
      return;
    }
    if (_absenceReported) return; // already told the agent for this run
    _absenceReported = true;
    // Confirmed gone — back off to the idle cadence until they return.
    _idle = true;
    // Reset transition debouncer state — we want the next face-present
    // frame to be treated as a fresh start.
    _pendingLabel = null;
    _pendingStreak = 0;
    _emit('absent', {
      'awaySeconds': now.difference(_lastFaceSeenAt!).inSeconds,
    }, forceTransition: true);
  }

  /// Take one raw observation per frame, debounce, and emit when a *stable*
  /// label transition is confirmed.
  void _observe(String label, Map<String, dynamic> payload) {
    lastEmotion.value = label;
    // Streak tracking — only commit a new label once it has stuck for
    // [_labelConfirmFrames] consecutive samples.
    if (label == _pendingLabel) {
      _pendingStreak++;
    } else {
      _pendingLabel = label;
      _pendingStreak = 1;
    }
    if (_pendingStreak < _labelConfirmFrames) return;
    // Only the present-face labels go through here; "absent" gets its own
    // path so it can honor the configurable wait.
    const reactable = {'happy', 'sleepy', 'flat'};
    if (!reactable.contains(label)) {
      _lastEmittedLabel = label;
      return;
    }
    _emit(label, payload);
  }

  /// Shared emit path: handles same-label cooldown (tunable via
  /// [AgentBehaviorConfig.sustainedMoodCooldown]) and fires the
  /// [SystemStatusEvent] onto the bus.
  void _emit(
    String label,
    Map<String, dynamic> payload, {
    bool forceTransition = false,
  }) {
    if (!_isRunCurrent(_lifecycleGeneration, _activeCapabilityAuthority)) {
      return;
    }
    final now = DateTime.now();
    final changed = forceTransition || label != _lastEmittedLabel;
    final sustained = _cfg?.sustainedMoodCooldown ?? const Duration(minutes: 2);
    if (!changed && now.difference(_lastEmitAt) < sustained) return;

    _lastEmittedLabel = label;
    _lastEmitAt = now;
    EventBus().fire(
      SystemStatusEvent(
        'user_emotion_$label',
        payload: {...payload, 'transition': changed},
      ),
    );
    Log.i('🎥 [Emotion] → $label  changed=$changed  $payload');
  }

  @override
  void onInit() {
    _loadUserEnabled();
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
  }

  Future<void> _loadUserEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    userEnabled.value = prefs.getBool(_userEnabledKey) ?? false;
  }

  /// Whether sensing should resume when the app comes back to foreground.
  /// We pause on background to release the camera (other apps may need it
  /// and we shouldn't burn battery while user can't see us anyway).
  bool _autoResume = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      if (isRunning.value) {
        _autoResume = true;
        _stopBestEffort();
      }
    } else if (state == AppLifecycleState.resumed) {
      if (_autoResume && userEnabled.value) {
        _autoResume = false;
        start();
      }
    }
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopBestEffort();
    super.onClose();
  }

  void _stopBestEffort({bool retryUntilDrained = false}) {
    if (retryUntilDrained) {
      final inFlight = _capabilityCleanupFuture;
      if (inFlight != null) return;
      late final Future<void> cleanup;
      cleanup = _retryCapabilityCleanup().whenComplete(() {
        if (identical(_capabilityCleanupFuture, cleanup)) {
          _capabilityCleanupFuture = null;
        }
      });
      _capabilityCleanupFuture = cleanup;
      unawaited(
        cleanup.catchError((Object error, StackTrace stackTrace) {
          Log.w(
            '🎥 [Emotion] capability cleanup stopped unexpectedly',
            error: error,
            stackTrace: stackTrace,
          );
        }),
      );
      return;
    }
    unawaited(
      stop().catchError((Object error, StackTrace stackTrace) {
        Log.w(
          '🎥 [Emotion] stop failed; retaining resources for retry',
          error: error,
          stackTrace: stackTrace,
        );
      }),
    );
  }

  Future<void> _retryCapabilityCleanup() async {
    var retryDelay = _cleanupRetryInitialDelay;
    do {
      try {
        await stop();
      } catch (error, stackTrace) {
        Log.w(
          '🎥 [Emotion] capability cleanup will retry',
          error: error,
          stackTrace: stackTrace,
        );
      }
      if (!_hasPendingCleanup) return;
      await Future<void>.delayed(retryDelay);
      final nextMilliseconds = retryDelay.inMilliseconds * 2;
      retryDelay = Duration(
        milliseconds: nextMilliseconds > _shutdownDrainTimeout.inMilliseconds
            ? _shutdownDrainTimeout.inMilliseconds
            : nextMilliseconds,
      );
    } while (_hasPendingCleanup);
  }

  bool get _hasPendingCleanup =>
      _camera != null ||
      _detector != null ||
      _processingToken != null ||
      isRunning.value ||
      _stopping;
}

final class _EmotionSensorCapabilityAuthority {
  const _EmotionSensorCapabilityAuthority(this.snapshots, this.lease);

  final AppCapabilitySnapshotService snapshots;
  final AppCapabilitySnapshotLease lease;
}
