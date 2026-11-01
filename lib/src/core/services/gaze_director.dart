import 'dart:async';
import 'dart:ui' show Offset, Rect, Size;

import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';

/// A normalized look-at target. Both offsets are in `-1..1`.
///
/// [eye] drives the eyeballs; [head] drives the head turn (+ a small body lean).
/// Keeping them separate lets face-follow track the user's *position* with the
/// eyes while only *lightly* mirroring their head pose with the head.
class GazeFrame {
  final Offset eye;
  final Offset head;
  final double? headRoll;
  final double? upperBodyX;

  const GazeFrame({
    required this.eye,
    required this.head,
    this.headRoll,
    this.upperBodyX,
  });

  /// Window-style frame where the eyes and head share one direction.
  const GazeFrame.uniform(Offset dir)
    : eye = dir,
      head = dir,
      headRoll = null,
      upperBodyX = null;

  factory GazeFrame.fromAvatarGaze(AvatarGaze gaze) => GazeFrame(
    eye: Offset(gaze.eyeX, gaze.eyeY),
    head: Offset(gaze.headX, gaze.headY),
    headRoll: gaze.headRoll,
    upperBodyX: gaze.upperBodyX,
  );
}

/// Where the director writes look-at params. Abstracted so the director is
/// unit-testable without a 3D renderer.
abstract class GazeSink {
  void drive(Map<String, double> params);
  void release(List<String> params);
}

/// Default sink — forwards to the active avatar runtime.
class AvatarGazeSink implements GazeSink {
  @override
  void drive(Map<String, double> params) {
    if (!appServices.isRegistered<ActiveAvatarRuntime>()) return;
    final rt = appServices.find<ActiveAvatarRuntime>().current;
    if (rt == null) return;
    final eyeX = (params['ParamEyeBallX'] ?? 0) / 1.0;
    final eyeY = (params['ParamEyeBallY'] ?? 0) / 1.0;
    final headX = (params['ParamAngleX'] ?? 0) / 30.0;
    final headY = (params['ParamAngleY'] ?? 0) / 30.0;
    final headRoll = (params['ParamAngleZ'] ?? 0) / 30.0;
    final upperBodyX = (params['ParamBodyAngleX'] ?? 0) / 10.0;
    // ignore: unawaited_futures
    rt.setGaze(
      AvatarGaze(
        eyeX: eyeX,
        eyeY: eyeY,
        headX: headX,
        headY: headY,
        headRoll: headRoll,
        upperBodyX: upperBodyX,
      ),
    );
  }

  @override
  void release(List<String> params) {
    if (!appServices.isRegistered<ActiveAvatarRuntime>()) return;
    // ignore: unawaited_futures
    appServices.find<ActiveAvatarRuntime>().current?.clearGaze();
  }
}

/// Single owner of the agent's look-at.
///
/// Three sources publish into it — `desktopPointer` (the visible desktop pet),
/// `face` (the front camera, via
/// [EmotionSensorService]) and `window` (the foregrounded applet, via
/// [WidgetStageController]). The director picks the winner by priority
/// (desktopPointer > face > window), drives the avatar, and releases the params
/// back to the idle engine when no source is active.
///
/// Deliberate behavior gaze is held as a bounded lease above the ambient
/// sources. When it expires, the then-current ambient winner resumes without a
/// renderer-wide clear.
class GazeDirector extends AppService {
  GazeDirector({GazeSink? sink}) : _sink = sink ?? AvatarGazeSink();

  final GazeSink _sink;

  static const double _desktopEyeHorizontalGain = 1.4;
  static const double _desktopEyeVerticalGain = 1.25;
  static const double _desktopHeadHorizontalGain = 0.62;
  static const double _desktopHeadVerticalGain = 0.72;

  /// Params the director owns. Released (handed back to idle) when no source is
  /// active. `ParamBodyAngleY` is intentionally absent so the idle breath keeps
  /// the body moving.
  static const driveParams = <String>[
    'ParamEyeBallX',
    'ParamEyeBallY',
    'ParamAngleX',
    'ParamAngleY',
    'ParamAngleZ',
    'ParamBodyAngleX',
  ];

  GazeFrame? _face;
  GazeFrame? _window;
  GazeFrame? _desktopPointer;
  GazeFrame? _behavior;
  Timer? _behaviorLeaseTimer;
  int _behaviorLeaseGeneration = 0;
  bool _released = true;

  /// Holds an intentional behavior gaze above every ambient source.
  ///
  /// Replacing or clearing the lease advances a generation token so a stale
  /// timer can never clear a newer intent. Expiry re-runs arbitration and
  /// therefore restores the latest pointer/face/window source.
  void holdBehaviorGaze(AvatarGaze? gaze, {required Duration duration}) {
    final generation = ++_behaviorLeaseGeneration;
    _behaviorLeaseTimer?.cancel();
    _behaviorLeaseTimer = null;
    _behavior = gaze == null ? null : GazeFrame.fromAvatarGaze(gaze);
    _apply();

    if (_behavior == null) return;
    final durationMs = duration.inMilliseconds.clamp(0, 10000);
    if (durationMs == 0) {
      _behavior = null;
      _apply();
      return;
    }
    _behaviorLeaseTimer = Timer(Duration(milliseconds: durationMs), () {
      if (generation != _behaviorLeaseGeneration) return;
      _behaviorLeaseTimer = null;
      _behavior = null;
      _apply();
    });
  }

  /// Desktop-pet cursor source. Pass `null` as soon as the pet is hidden.
  void setDesktopPointerGaze(Offset? dir) {
    _desktopPointer = dir == null
        ? null
        : GazeFrame(
            eye: Offset(
              (dir.dx * _desktopEyeHorizontalGain).clamp(-1.0, 1.0).toDouble(),
              (dir.dy * _desktopEyeVerticalGain).clamp(-1.0, 1.0).toDouble(),
            ),
            head: Offset(
              dir.dx * _desktopHeadHorizontalGain,
              dir.dy * _desktopHeadVerticalGain,
            ),
            // Cursor tracking is yaw + pitch. Roll is reserved for deliberate
            // reactions such as a playful tilt and must never be inferred from
            // horizontal mouse movement.
            headRoll: 0,
          );
    _apply();
  }

  /// Face source. Pass `null` to deactivate (face lost / camera off).
  void setFaceGaze(GazeFrame? g) {
    _face = g;
    _apply();
  }

  /// Window source. Pass `null` to deactivate (window minimized/closed).
  void setWindowGaze(Offset? dir) {
    _window = dir == null ? null : GazeFrame.uniform(dir);
    _apply();
  }

  GazeFrame? get _winner => _behavior ?? _desktopPointer ?? _face ?? _window;

  void _apply() {
    final w = _winner;
    if (w == null) {
      if (!_released) {
        _sink.release(driveParams);
        _released = true;
      }
      return;
    }
    _released = false;
    _sink.drive(driveFor(w));
  }

  /// Maps a [GazeFrame] to avatar params. Shared by both sources, so the
  /// amplitude is consistent whether the agent is following a window or a face.
  static Map<String, double> driveFor(GazeFrame g) => {
    // Pushed toward the avatar motion limits (head ±30, body ±10, eyes ±1) so the
    // follow is unmistakable — a full turn-and-lean, not a subtle glance.
    'ParamEyeBallX': g.eye.dx * 1.0,
    'ParamEyeBallY': g.eye.dy * 0.85,
    'ParamAngleX': g.head.dx * 30,
    'ParamAngleY': g.head.dy * 22,
    'ParamAngleZ': (g.headRoll ?? (-g.head.dx * 8 / 30)) * 30,
    'ParamBodyAngleX': (g.upperBodyX ?? g.head.dx) * 10,
  };

  @override
  void onClose() {
    _behaviorLeaseGeneration++;
    _behaviorLeaseTimer?.cancel();
    _behaviorLeaseTimer = null;
    _behavior = null;
    _desktopPointer = null;
    _face = null;
    _window = null;
    _apply();
    super.onClose();
  }
}

/// Account-scoped adapter used to expose the director through the behavior
/// layer without registering the lifecycle-owned director instance twice.
class GazeDirectorBehaviorIntentHandler implements AvatarGazeIntentHandler {
  const GazeDirectorBehaviorIntentHandler(this._director);

  final GazeDirector _director;

  @override
  Future<void> hold(AvatarGaze? gaze, {required Duration duration}) async {
    _director.holdBehaviorGaze(gaze, duration: duration);
  }
}

// —————————————————— pure face → gaze mapping ——————————————————

// Face position → eye deflection. >1 so the eyes hit full travel before the
// face reaches the frame edge.
const double _kEyeGain = 1.3;
// Face position → head turn. Subtler than the eyes (the head leads less).
const double _kHeadGain = 0.7;
// User head pose → agent head. Small, so a tilt reads as a light mirror, not a
// full puppet.
const double _kPoseMirror = 0.4;
// Degrees of head Euler angle that map to full -1..1.
const double _kEulerSpan = 35.0;

/// Pure mapping from a detected face to a [GazeFrame].
///
/// * [boundingBox] / [frameSize] — the face box in the detector's image space.
/// * [eulerY] / [eulerX] — head yaw / pitch in degrees (ML Kit), optional.
/// * [mirror] — handedness of the horizontal axis. With the front camera the
///   agent should look the same way the user moves (move left → agent looks
///   left), which is what `mirror: true` produces here. Pass `false` to invert
///   if a device reports the opposite handedness.
GazeFrame faceToGaze({
  required Rect boundingBox,
  required Size frameSize,
  double? eulerY,
  double? eulerX,
  bool mirror = true,
}) {
  final w = frameSize.width <= 0 ? 1.0 : frameSize.width;
  final h = frameSize.height <= 0 ? 1.0 : frameSize.height;
  final nx = (boundingBox.center.dx / w).clamp(0.0, 1.0);
  final ny = (boundingBox.center.dy / h).clamp(0.0, 1.0);
  final mirrorSign = mirror ? 1.0 : -1.0;

  // Signed offset from frame centre, -1..1. Screen-y grows downward, so invert
  // for the vertical axis ("face high in frame" → "look up").
  final posX = (nx - 0.5) * 2;
  final posY = (0.5 - ny) * 2;

  final eyeX = (posX * _kEyeGain * mirrorSign).clamp(-1.0, 1.0);
  final eyeY = (posY * _kEyeGain).clamp(-1.0, 1.0);

  final poseYaw = ((eulerY ?? 0) / _kEulerSpan).clamp(-1.0, 1.0);
  final posePitch = ((eulerX ?? 0) / _kEulerSpan).clamp(-1.0, 1.0);

  final headX =
      (posX * _kHeadGain * mirrorSign + poseYaw * _kPoseMirror * mirrorSign)
          .clamp(-1.0, 1.0);
  final headY = (posY * _kHeadGain + posePitch * _kPoseMirror).clamp(-1.0, 1.0);

  return GazeFrame(
    eye: Offset(eyeX.toDouble(), eyeY.toDouble()),
    head: Offset(headX.toDouble(), headY.toDouble()),
  );
}
