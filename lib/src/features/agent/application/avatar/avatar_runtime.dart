import 'dart:async';
import 'dart:math' as math;

import 'avatar_presence_transition.dart';
export 'avatar_presence_transition.dart';
import 'avatar_doorway_transition.dart';
export 'avatar_doorway_transition.dart';
import 'avatar_furniture_state.dart';
export 'avatar_furniture_state.dart';
import 'avatar_phone_interaction.dart';
export 'avatar_phone_interaction.dart';
import 'avatar_background_task_work_contract.dart';
export 'avatar_background_task_work_contract.dart';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

enum AvatarBackendKind { unity }

enum AvatarWorldFraming {
  heroFullBody('hero_full_body'),
  upperBody('upper_body'),
  sleepingTop('sleeping_top');

  const AvatarWorldFraming(this.wireValue);
  final String wireValue;
}

/// Renderer-neutral lighting state for the avatar's surrounding world.
///
/// The current Unity backend maps these values to its day/night environment;
/// other backends can safely leave the default no-op implementation intact.
enum AvatarWorldLighting { day, night }

class AvatarViewportSafeArea {
  const AvatarViewportSafeArea({this.top = 0, this.bottom = 0});

  final double top;
  final double bottom;

  Map<String, double> toJson() => {
    'topSafeViewport': top.clamp(0.0, 0.45).toDouble(),
    'bottomSafeViewport': bottom.clamp(0.0, 0.45).toDouble(),
  };

  @override
  bool operator ==(Object other) {
    return other is AvatarViewportSafeArea &&
        other.top == top &&
        other.bottom == bottom;
  }

  @override
  int get hashCode => Object.hash(top, bottom);
}

class AvatarExpressionParams {
  const AvatarExpressionParams({
    this.happy = 0,
    this.sad = 0,
    this.angry = 0,
    this.surprised = 0,
    this.love = 0,
    this.relaxed = 0,
    this.thinking = 0,
    this.tired = 0,
    this.mouthSmile = 0,
    this.mouthOpen = 0,
    this.eyeOpen = 1,
    this.browConcern = 0,
  });

  final double happy;
  final double sad;
  final double angry;
  final double surprised;
  final double love;
  final double relaxed;
  final double thinking;
  final double tired;
  final double mouthSmile;
  final double mouthOpen;
  final double eyeOpen;
  final double browConcern;

  AvatarExpressionParams copyWith({
    double? happy,
    double? sad,
    double? angry,
    double? surprised,
    double? love,
    double? relaxed,
    double? thinking,
    double? tired,
    double? mouthSmile,
    double? mouthOpen,
    double? eyeOpen,
    double? browConcern,
  }) {
    return AvatarExpressionParams(
      happy: happy ?? this.happy,
      sad: sad ?? this.sad,
      angry: angry ?? this.angry,
      surprised: surprised ?? this.surprised,
      love: love ?? this.love,
      relaxed: relaxed ?? this.relaxed,
      thinking: thinking ?? this.thinking,
      tired: tired ?? this.tired,
      mouthSmile: mouthSmile ?? this.mouthSmile,
      mouthOpen: mouthOpen ?? this.mouthOpen,
      eyeOpen: eyeOpen ?? this.eyeOpen,
      browConcern: browConcern ?? this.browConcern,
    );
  }

  AvatarExpressionParams withMouthOverlay(double value) {
    return copyWith(mouthOpen: value.clamp(0.0, 1.0).toDouble());
  }

  Map<String, double> toJson() => {
    'happy': happy,
    'sad': sad,
    'angry': angry,
    'surprised': surprised,
    'love': love,
    'relaxed': relaxed,
    'thinking': thinking,
    'tired': tired,
    'mouthSmile': mouthSmile,
    'mouthOpen': mouthOpen,
    'eyeOpen': eyeOpen,
    'browConcern': browConcern,
  };
}

class AvatarGaze {
  const AvatarGaze({
    required this.eyeX,
    required this.eyeY,
    required this.headX,
    required this.headY,
    this.headRoll = 0,
    this.upperBodyX = 0,
  });

  final double eyeX;
  final double eyeY;
  final double headX;
  final double headY;
  final double headRoll;
  final double upperBodyX;

  Map<String, double> toJson() => {
    'eyeX': eyeX.clamp(-1.0, 1.0).toDouble(),
    'eyeY': eyeY.clamp(-1.0, 1.0).toDouble(),
    'headX': headX.clamp(-1.0, 1.0).toDouble(),
    'headY': headY.clamp(-1.0, 1.0).toDouble(),
    'headRoll': headRoll.clamp(-1.0, 1.0).toDouble(),
    'upperBodyX': upperBodyX.clamp(-1.0, 1.0).toDouble(),
  };
}

class AvatarBodyPose {
  const AvatarBodyPose({
    this.yaw = 0,
    this.x = 0,
    this.y = 0,
    this.z = 0,
    this.scale = 1,
    this.durationMs = 900,
  });

  final double yaw;
  final double x;
  final double y;
  final double z;
  final double scale;
  final int durationMs;

  factory AvatarBodyPose.fromJson(Map<dynamic, dynamic> json) {
    return AvatarBodyPose(
      yaw: _double(json['yaw'], 0).clamp(-math.pi, math.pi).toDouble(),
      x: _double(json['x'], 0).clamp(-1.0, 1.0).toDouble(),
      y: _double(json['y'], 0).clamp(-1.0, 1.0).toDouble(),
      z: _double(json['z'], 0).clamp(-1.5, 1.5).toDouble(),
      scale: _double(json['scale'], 1).clamp(0.55, 1.35).toDouble(),
      durationMs: _int(
        json['durationMs'] ?? json['duration'],
        900,
      ).clamp(0, 5000),
    );
  }

  Map<String, Object> toJson() => {
    'yaw': yaw.clamp(-math.pi, math.pi).toDouble(),
    'x': x.clamp(-1.0, 1.0).toDouble(),
    'y': y.clamp(-1.0, 1.0).toDouble(),
    'z': z.clamp(-1.5, 1.5).toDouble(),
    'scale': scale.clamp(0.55, 1.35).toDouble(),
    'durationMs': durationMs.clamp(0, 5000),
  };

  static double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class AvatarMotionStep {
  const AvatarMotionStep({
    this.clip = '',
    this.motion = '',
    this.primitive = '',
    this.options = const {},
    this.bodyPose,
    this.atMs,
    this.delayMs = 0,
  });

  final String clip;
  final String motion;
  final String primitive;
  final Map<String, dynamic> options;
  final AvatarBodyPose? bodyPose;
  final int? atMs;
  final int delayMs;

  bool get hasCommand =>
      clip.trim().isNotEmpty ||
      motion.trim().isNotEmpty ||
      primitive.trim().isNotEmpty ||
      bodyPose != null;

  factory AvatarMotionStep.fromJson(Map<dynamic, dynamic> json) {
    final rawPose = json['bodyPose'] ?? json['pose'];
    final rawOptions = json['options'] ?? json['opts'];
    return AvatarMotionStep(
      clip: (json['clip'] ?? json['animation'] ?? json['animationClip'] ?? '')
          .toString()
          .trim()
          .toLowerCase(),
      motion: (json['motion'] ?? '').toString().trim().toLowerCase(),
      primitive: (json['primitive'] ?? '').toString().trim().toLowerCase(),
      options: rawOptions is Map
          ? rawOptions.map((key, value) => MapEntry(key.toString(), value))
          : const {},
      bodyPose: rawPose is Map ? AvatarBodyPose.fromJson(rawPose) : null,
      atMs: json.containsKey('atMs')
          ? _int(json['atMs'], 0).clamp(0, 120000)
          : null,
      delayMs: _int(json['delayMs'], 0).clamp(0, 120000),
    );
  }

  Map<String, Object> toJson() {
    final json = <String, Object>{};
    if (clip.trim().isNotEmpty) json['clip'] = clip;
    if (motion.trim().isNotEmpty) json['motion'] = motion;
    if (primitive.trim().isNotEmpty) json['primitive'] = primitive;
    if (options.isNotEmpty) json['options'] = options;
    final pose = bodyPose;
    if (pose != null) json['bodyPose'] = pose.toJson();
    final at = atMs;
    if (at != null) json['atMs'] = at.clamp(0, 120000);
    if (delayMs > 0) json['delayMs'] = delayMs.clamp(0, 120000);
    return json;
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

/// Optional renderer capability for sparse VRM Aa/Ih/Ou/Ee/Oh tracks.
///
/// [AvatarRuntime.startLipSync] deliberately remains unchanged so existing
/// renderers and test fakes retain the scalar envelope contract. Callers test
/// this interface after starting that legacy envelope, making visemes an
/// additive enhancement with a safe fallback.
abstract interface class AvatarVisemeRuntime {
  Future<void> startVisemeTrack(LipSyncVisemeTrack track);
}

/// Optional bounded calibration capability. It never grants a new mouth owner
/// and leaves renderers without a native playback clock on their legacy path.
abstract interface class AvatarSpeechPlaybackRuntime {
  Future<void> syncSpeechPlaybackClock(SpeechPlaybackClock clock);
}

/// Real conversation phases, independent of model response latency.
abstract interface class AvatarConversationPhaseRuntime {
  Future<void> setConversationPhase(String phase, {required int sequence});
}

/// Host-owned, brief attention to a Home background tap. The renderer owns its
/// return to neutral and cancels it when another gaze or scene takes over.
/// This is separate from intentional [AvatarRuntime.setGaze] commands.
abstract interface class AvatarScreenAttentionRuntime {
  Future<void> reactToScreenTap({
    required double normalizedX,
    required double normalizedY,
  });
}

abstract interface class AvatarFurnitureRuntime {
  AvatarFurnitureState? get furnitureState;
  Stream<AvatarFurnitureState> get furnitureStates;
}

abstract class AvatarRuntime {
  RxBool get isReady;

  /// True when the ready renderer has a visible presentation host. A retained
  /// engine can remain ready while its native view is detached or suspended.
  /// Renderers without a separate native host keep the readiness contract.
  RxBool get presentationReady => isReady;
  AvatarBackendKind get backendKind;

  /// Changes when a renderer loses its loaded model across a native reset.
  /// Reattaching a view to an intact renderer keeps the same epoch.
  int get modelLoadEpoch => 0;

  /// Optional host-owned coding presentation. It never starts an invisible
  /// renderer or exposes scene coordinates/animation controls to the model.
  bool get supportsBackgroundTaskWorkPresentation => false;

  /// Normal host-owned task work is independent of experimental projections.
  /// Only an acknowledged native implementation can expose this channel.
  bool get supportsHostBackgroundTaskWorkPresentation => false;

  Future<AvatarBackgroundTaskWorkResult> setBackgroundTaskWork({
    required String sessionId,
    required AvatarBackgroundTaskWorkPhase phase,
  }) => Future.value(
    const AvatarBackgroundTaskWorkResult(
      AvatarBackgroundTaskWorkDisposition.rejected,
      code: 'work_unavailable',
    ),
  );

  /// Work-session fence for model replacements as well as engine resets.
  /// This leaves the existing cache-loss-only modelLoadEpoch contract intact.
  int get backgroundTaskWorkPresentationEpoch => modelLoadEpoch;

  bool get supportsLoginDoorway => false;
  Future<void> transitionLoginDoorway(AvatarDoorwayTransition request) =>
      Future<void>.error(UnsupportedError('Login doorway is unavailable'));

  /// Account presentation ownership; does not hide the surrounding room.
  Future<void> setLocalAvatarVisible(bool visible) => Future<void>.value();

  /// Starts the existing renderer without granting presentation ownership.
  /// Callers still wait for [isReady] before loading or transitioning an avatar.
  Future<void> prepareRenderer() => Future<void>.value();

  Future<void> setPhoneInteraction({
    required String interactionId,
    required AvatarPhoneInteractionPhase phase,
  }) => Future<void>.error(
    UnsupportedError('Avatar phone interaction is unavailable'),
  );

  Future<void> transitionPresence(AvatarPresenceTransition request) =>
      Future<void>.error(
        UnsupportedError('Avatar presence transitions are unavailable'),
      );

  Future<void> setExpressionParams(AvatarExpressionParams params);
  Future<void> setMouthOpen(double value);
  Future<void> setGaze(AvatarGaze gaze);
  Future<void> clearGaze();
  Future<void> startLipSync(List<double> envelope, {int frameRate = 30});
  Future<void> stopLipSync();
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]);
  Future<void> playAnimationClip(String id, [Map<String, dynamic>? opts]);
  Future<void> setHandIkTarget(String target, [Map<String, dynamic>? opts]);
  Future<void> setBodyPose(AvatarBodyPose pose);
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]);
  Future<void> playMotionSequence(List<AvatarMotionStep> steps);
  Future<void> setFraming(String mode);

  /// Personal-room framing uses the same camera owner as Home.
  Future<void> setWorldFraming(AvatarWorldFraming framing) async {}
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea);
  Future<void> setWorldLighting(AvatarWorldLighting lighting) =>
      Future<void>.value();
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]);
  Future<void> resetAvatarForAccountBoundary(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) => loadAvatar(modelUrl, config);
  Future<void> pause();
  Future<void> resume();
}

class ActiveAvatarRuntime extends AppService {
  static const preferredBackend = AvatarBackendKind.unity;

  final backend = preferredBackend.obs;
  final _runtimes = <AvatarBackendKind, AvatarRuntime>{};

  AvatarRuntime? get current => _runtimes[backend.value];

  bool? _localAvatarVisible;
  bool? get localAvatarVisible => _localAvatarVisible;

  Future<void> setLocalAvatarVisible(bool visible) async {
    _localAvatarVisible = visible;
    await current?.setLocalAvatarVisible(visible);
  }

  Future<void> setPhoneInteraction({
    required String interactionId,
    required AvatarPhoneInteractionPhase phase,
  }) async {
    final runtime = current;
    if (runtime == null) {
      throw UnsupportedError('Avatar renderer is unavailable');
    }
    await runtime.setPhoneInteraction(
      interactionId: interactionId,
      phase: phase,
    );
  }

  Future<void> transitionPresence(AvatarPresenceTransition request) async {
    final runtime = current;
    if (runtime == null) {
      throw UnsupportedError('Avatar renderer is unavailable');
    }
    await runtime.transitionPresence(request);
  }

  void register(AvatarRuntime runtime) {
    _runtimes[runtime.backendKind] = runtime;
    final visibility = _localAvatarVisible;
    if (visibility != null) {
      unawaited(runtime.setLocalAvatarVisible(visibility));
    }
    if (!_runtimes.containsKey(backend.value)) {
      backend.value = runtime.backendKind;
    }
    if (runtime.backendKind == preferredBackend) {
      backend.value = preferredBackend;
    }
  }

  void select(AvatarBackendKind kind) {
    if (_runtimes.containsKey(kind)) backend.value = kind;
  }

  Future<void> setWorldFraming(AvatarWorldFraming framing) async {
    await current?.setWorldFraming(framing);
  }

  Future<void> playMotion(String type, [Map<String, dynamic>? options]) async {
    await current?.playMotion(type, options);
  }

  Future<void> setFraming(String mode) async {
    await current?.setFraming(mode);
  }
}
