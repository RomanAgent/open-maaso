import 'dart:async';

import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_animation_catalog.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_protection.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

typedef AvatarRuntimeProvider = AvatarRuntime? Function();
typedef AvatarEmotionEmitter = void Function(AvatarEmotionIntent intent);

abstract interface class AvatarGazeIntentHandler {
  Future<void> hold(AvatarGaze? gaze, {required Duration duration});
}

class AvatarEmotionIntent {
  const AvatarEmotionIntent({
    required this.label,
    required this.intensity,
    required this.params,
    this.agentId,
    this.duration,
    this.persistent = false,
    this.automatic = false,
  });

  final String label;
  final double intensity;
  final EmotionParams params;
  final String? agentId;
  final Duration? duration;
  final bool persistent;
  final bool automatic;
}

class AvatarBehaviorResult {
  const AvatarBehaviorResult({
    required this.applied,
    required this.reason,
    this.mood,
    this.primitive,
  });

  final bool applied;
  final String reason;
  final String? mood;
  final String? primitive;
}

enum AvatarBehaviorPlanKind { none, act, reaction }

enum AvatarConversationPhase { listening, thinking, speaking, stopped }

class AvatarBehaviorPlan {
  const AvatarBehaviorPlan({
    required this.scenario,
    required this.kind,
    required this.mood,
    required this.gesture,
    required this.gaze,
    required this.style,
    required this.intensity,
    required this.durationMs,
    this.emitMood = true,
    this.reason = 'planned',
  });

  const AvatarBehaviorPlan.none({required this.scenario, required this.reason})
    : kind = AvatarBehaviorPlanKind.none,
      mood = 'none',
      gesture = 'none',
      gaze = 'none',
      style = 'subtle',
      intensity = 0,
      durationMs = 0,
      emitMood = false;

  final String scenario;
  final AvatarBehaviorPlanKind kind;
  final String mood;
  final String gesture;
  final String gaze;
  final String style;
  final double intensity;
  final int durationMs;
  final bool emitMood;
  final String reason;

  bool get shouldApply => kind != AvatarBehaviorPlanKind.none;
}

String? _avatarPerformanceEnergy(Object? value) {
  if (value == null) return null;
  if (value is! String) {
    throw ArgumentError('invalid_avatar_performance_energy');
  }
  final energy = value.trim().toLowerCase();
  if (!AvatarBodyGestureCommand.performanceEnergies.contains(energy)) {
    throw ArgumentError('invalid_avatar_performance_energy');
  }
  return energy;
}

double _avatarPerformanceIntensity(double value, String? energy) {
  if (energy != null && !value.isFinite) {
    throw ArgumentError('invalid_avatar_performance_intensity');
  }
  return value.clamp(0.0, 1.0).toDouble();
}

String _avatarPerformanceEmotion(String mood) => switch (mood) {
  'calm' ||
  'happy' ||
  'excited' ||
  'sad' ||
  'comforting' ||
  'curious' ||
  'thinking' ||
  'surprised' ||
  'angry' => mood,
  'playful' || 'teasing' || 'proud' => 'happy',
  'serious' || 'sleepy' || 'shy' => 'calm',
  'confused' => 'curious',
  _ => 'neutral',
};

const _speechPerformanceGestures = {
  'speech',
  'listen',
  'explain',
  'palms_open',
  'point_small',
  'chest',
};

class AvatarReaction {
  const AvatarReaction({
    this.mood = 'none',
    this.gesture = 'none',
    this.gaze = 'none',
    this.style = 'normal',
    this.intensity = 0.65,
    this.durationMs = 1100,
    this.emitMood = true,
    this.energy,
  });

  final String mood;
  final String gesture;
  final String gaze;
  final String style;
  final double intensity;
  final int durationMs;
  final bool emitMood;
  final String? energy;

  factory AvatarReaction.fromJson(Map<dynamic, dynamic> json) {
    return AvatarReaction(
      mood: _token(json['mood'] ?? json['emotion'] ?? 'none'),
      gesture: _token(json['gesture'] ?? json['primitive'] ?? 'none'),
      gaze: _token(json['gaze'] ?? 'none'),
      style: _token(json['style'] ?? 'normal'),
      intensity: _avatarPerformanceIntensity(
        _double(json['intensity'], 0.65),
        _avatarPerformanceEnergy(json['energy']),
      ),
      energy: _avatarPerformanceEnergy(json['energy']),
      durationMs: _int(
        json['durationMs'] ?? json['duration'],
        1100,
      ).clamp(350, 4200),
      emitMood: json['emitMood'] != false,
    );
  }

  static String _token(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return 'none';
    return text.replaceAll(RegExp(r'[\s-]+'), '_');
  }

  static double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class AvatarAct {
  const AvatarAct({
    this.mood = 'none',
    this.gesture = 'none',
    this.gaze = 'none',
    this.posture = 'none',
    this.style = 'normal',
    this.intensity = 0.65,
    this.durationMs = 1200,
    this.emitMood = true,
    this.inferGesture = true,
    this.energy,
    this.persistent = false,
  });

  final String mood;
  final String gesture;
  final String gaze;
  final String posture;
  final String style;
  final double intensity;
  final int durationMs;
  final bool emitMood;
  final String? energy;

  /// Hold only the facial mood, never the body/gaze task or its lease.
  final bool persistent;

  /// Omitted gestures may follow the mood; explicit `none` keeps the body still.
  final bool inferGesture;

  factory AvatarAct.fromJson(Map<dynamic, dynamic> json) {
    return AvatarAct(
      mood: _token(json['mood'] ?? json['emotion'] ?? 'none'),
      gesture: _token(json['gesture'] ?? json['intent'] ?? 'none'),
      inferGesture:
          !(json.containsKey('gesture') || json.containsKey('intent')) ||
          _token(json['gesture'] ?? json['intent']) != 'none',
      gaze: _token(json['gaze'] ?? 'none'),
      posture: _token(json['posture'] ?? json['body'] ?? 'none'),
      style: _token(json['style'] ?? 'normal'),
      intensity: _avatarPerformanceIntensity(
        _double(json['intensity'], 0.65),
        _avatarPerformanceEnergy(json['energy']),
      ),
      energy: _avatarPerformanceEnergy(json['energy']),
      durationMs: _int(
        json['durationMs'] ?? json['duration'],
        1200,
      ).clamp(350, 5000),
      emitMood: json['emitMood'] == false ? false : true,
      persistent: json['persistent'] == true,
    );
  }

  static String _token(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    if (text.isEmpty) return 'none';
    return text.replaceAll(RegExp(r'[\s-]+'), '_');
  }

  static double _double(Object? value, double fallback) {
    if (value is num) return value.toDouble();
    return double.tryParse(value?.toString() ?? '') ?? fallback;
  }

  static int _int(Object? value, int fallback) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '') ?? fallback;
  }
}

class AvatarAutoReactionContext {
  const AvatarAutoReactionContext({
    this.reply = '',
    this.voiceText = '',
    this.emotionLabel,
    this.actionTypes = const {},
  });

  final String reply;
  final String voiceText;
  final String? emotionLabel;
  final Set<String> actionTypes;

  bool get hasExplicitAvatarAction =>
      actionTypes.contains('avatar.act') ||
      actionTypes.contains('avatar.react') ||
      actionTypes.contains('avatar.motion');

  bool get hasVisibleResponse =>
      reply.trim().isNotEmpty || voiceText.trim().isNotEmpty;
}

class AvatarBehaviorDirector {
  AvatarBehaviorDirector({
    this.agentId = 'self',
    AvatarRuntimeProvider? runtimeProvider,
    AvatarEmotionEmitter? emitEmotion,
    AvatarAnimationCatalog? animationCatalog,
    AvatarGazeIntentHandler? gazeIntentHandler,
    DateTime Function()? now,
  }) : _runtimeProvider = runtimeProvider ?? _activeRuntime,
       _emitEmotion = emitEmotion ?? _eventBusEmitter,
       _animationCatalog = animationCatalog ?? AvatarAnimationCatalog.bundled,
       _now = now ?? DateTime.now,
       _gazeIntentHandler =
           gazeIntentHandler ??
           _RegisteredAvatarGazeIntentHandler(
             runtimeProvider ?? _activeRuntime,
           );

  final String agentId;
  final AvatarRuntimeProvider _runtimeProvider;
  final AvatarEmotionEmitter _emitEmotion;
  final AvatarAnimationCatalog _animationCatalog;
  final AvatarGazeIntentHandler _gazeIntentHandler;
  final DateTime Function() _now;
  Object? _autoScope;
  int? _autoRendererGeneration;
  String? _lastAutoGesture;
  DateTime? _lastAutoGestureAt;
  AvatarConversationPhase? _conversationPhase;
  int _phaseEpoch = 0;
  int? _phasePerformanceEpoch;
  static int _nativePhaseSequence = 0;

  void resetAutoBehavior() {
    _autoScope = null;
    _autoRendererGeneration = null;
    _lastAutoGesture = null;
    _lastAutoGestureAt = null;
    _conversationPhase = null;
    _phaseEpoch++;
  }

  void _syncAutoScope() {
    final authority = AvatarProductionOwnership.currentFor(agentId);
    final scope = authority ?? _runtimeProvider();
    final generation = authority?.rendererGeneration;
    if (!identical(scope, _autoScope) ||
        generation != _autoRendererGeneration) {
      resetAutoBehavior();
      _autoScope = scope;
      _autoRendererGeneration = generation;
    }
  }

  bool _autoScopeCurrent(Object? scope, int? generation) {
    final authority = AvatarProductionOwnership.currentFor(agentId);
    return identical(authority ?? _runtimeProvider(), scope) &&
        authority?.rendererGeneration == generation;
  }

  static const rendererNotReadyReason = 'avatar renderer not ready';

  Future<AvatarBehaviorResult> applyRequiredReaction(
    AvatarReaction reaction,
  ) async {
    final result = await applyReaction(reaction);
    _requireRenderer(result);
    return result;
  }

  Future<AvatarBehaviorResult> applyRequiredAct(AvatarAct act) async {
    final result = await applyAct(act);
    _requireRenderer(result);
    return result;
  }

  Future<AvatarBehaviorResult> applyReaction(
    AvatarReaction reaction, {
    bool ambient = false,
    bool Function()? shouldContinue,
  }) => _withBehaviorProtection(
    ambient: ambient,
    shouldContinue: shouldContinue,
    duration: Duration(milliseconds: reaction.durationMs),
    apply: (canContinue) async {
      final mood = _normalizeMood(reaction.mood);
      final energy = _avatarPerformanceEnergy(reaction.energy);
      final performanceIntensity = energy == null
          ? null
          : _avatarPerformanceIntensity(reaction.intensity, energy);
      final primitive = energy != null && reaction.gesture == 'none'
          ? 'speech'
          : _primitiveFor(reaction.gesture, mood) ??
                (energy == null ? null : 'speech');
      final performanceEnergy =
          AvatarFurnitureState.gestures.contains(primitive) ? null : energy;
      final avatar = _runtimeProvider();
      var applied = false;
      AvatarProjectionProductionAuthority? productionAuthority;
      AvatarGaze? productionGaze;
      var productionHasBehaviorIntent = false;

      if (AvatarProductionOwnership.ownsRenderer) {
        final authority = AvatarProductionOwnership.currentFor(agentId);
        if (authority == null) {
          return AvatarBehaviorResult(
            applied: false,
            reason: rendererNotReadyReason,
            mood: mood,
            primitive: primitive,
          );
        }
        productionAuthority = authority;
        productionGaze = _gazeFor(reaction.gaze);
        productionHasBehaviorIntent =
            primitive != null ||
            productionGaze != null ||
            reaction.gaze != 'none';
        if (productionHasBehaviorIntent ||
            (reaction.emitMood && mood != 'none')) {
          final admission = authority.preflightBehavior(bodyGesture: primitive);
          if (!admission.applied) {
            return _productionBehaviorResult(
              admission,
              mood: mood,
              primitive: primitive,
            );
          }
        }
      }

      if (reaction.emitMood && mood != 'none') {
        final intensity = reaction.intensity.clamp(0.0, 1.0).toDouble();
        final params = _emotionFor(mood).scaled(intensity);
        _emitEmotion(
          AvatarEmotionIntent(
            label: mood,
            intensity: intensity,
            params: params,
            agentId: agentId,
            duration: Duration(milliseconds: reaction.durationMs),
            automatic: ambient,
          ),
        );
        applied = true;
      }

      if (!canContinue()) return _interruptedAmbient;
      final authority = productionAuthority;
      if (authority != null) {
        if (!productionHasBehaviorIntent) {
          return AvatarBehaviorResult(
            applied: applied,
            reason: applied ? 'applied' : 'no visible intent',
            mood: mood,
            primitive: primitive,
          );
        }
        final result = await authority.applyBehavior(
          ambient: ambient,
          shouldContinue: canContinue,
          gaze: productionGaze,
          clearGaze: productionGaze == null && reaction.gaze != 'none',
          bodyGesture: primitive,
          energy: performanceEnergy,
          intensity: performanceEnergy == null ? null : performanceIntensity,
          emotion: performanceEnergy == null
              ? null
              : _avatarPerformanceEmotion(mood),
          duration: Duration(milliseconds: reaction.durationMs),
          bodyDuration:
              performanceEnergy == null ||
                  primitive == null ||
                  _speechPerformanceGestures.contains(primitive)
              ? null
              : _performanceBodyDuration(
                  primitive,
                  mood,
                  reaction.intensity,
                  reaction.durationMs,
                  avatar,
                ),
        );
        return _productionBehaviorResult(
          result,
          mood: mood,
          primitive: primitive,
        );
      }

      try {
        if (avatar != null) {
          final gaze = _gazeFor(reaction.gaze);
          if (gaze == null) {
            if (reaction.gaze == 'none') {
              // Leave the current gaze alone for unspecified reactions.
            } else {
              await _gazeIntentHandler.hold(
                null,
                duration: Duration(milliseconds: reaction.durationMs),
              );
            }
          } else {
            await _gazeIntentHandler.hold(
              gaze,
              duration: Duration(milliseconds: reaction.durationMs),
            );
            applied = true;
          }

          if (!canContinue()) return _interruptedAmbient;
          if (primitive != null) {
            await avatar.playPrimitive(primitive, _primitiveOptions(reaction));
            applied = true;
          }
        }
      } on PlatformException catch (error) {
        if (error.code != 'not_ready') rethrow;
        return AvatarBehaviorResult(
          applied: false,
          reason: rendererNotReadyReason,
          mood: mood,
          primitive: primitive,
        );
      }

      return AvatarBehaviorResult(
        applied: applied,
        reason: applied ? 'applied' : 'no avatar runtime or visible intent',
        mood: mood,
        primitive: primitive,
      );
    },
  );

  Future<AvatarBehaviorResult> applyAct(
    AvatarAct act, {
    bool ambient = false,
    bool Function()? shouldContinue,
  }) => _withBehaviorProtection(
    ambient: ambient,
    shouldContinue: shouldContinue,
    duration: Duration(milliseconds: act.durationMs),
    apply: (canContinue) async {
      final gesture = _normalizeGesture(act.gesture);
      final mood = _normalizeMood(_moodForAct(act, gesture));
      final energy = _avatarPerformanceEnergy(act.energy);
      final performanceIntensity = energy == null
          ? null
          : _avatarPerformanceIntensity(act.intensity, energy);
      final avatar = _runtimeProvider();
      var applied = false;
      final furniture = AvatarFurnitureState.gestureForPosture(act.posture);
      final primitive =
          furniture ??
          (energy != null && gesture == 'none'
              ? 'speech'
              : !act.inferGesture && gesture == 'none'
              ? null
              : energy != null && gesture == 'explain'
              ? 'explain'
              : _primitiveForAct(gesture, mood)) ??
          (energy == null ? null : 'speech');
      final performanceEnergy = furniture == null ? energy : null;
      final quietListeningGaze =
          performanceEnergy != null &&
          gesture == 'listen' &&
          act.gaze == 'none';

      AvatarProjectionProductionAuthority? productionAuthority;
      AvatarGaze? productionGaze;
      var productionHasBehaviorIntent = false;

      if (furniture != null && !AvatarProductionOwnership.ownsRenderer) {
        return AvatarBehaviorResult(
          applied: false,
          reason: 'furniture_authority_unavailable',
          mood: mood,
          primitive: primitive,
        );
      }
      if (AvatarProductionOwnership.ownsRenderer) {
        final authority = AvatarProductionOwnership.currentFor(agentId);
        if (authority == null) {
          return AvatarBehaviorResult(
            applied: false,
            reason: rendererNotReadyReason,
            mood: mood,
            primitive: primitive,
          );
        }
        productionAuthority = authority;
        productionGaze = quietListeningGaze
            ? null
            : _gazeForAct(act, gesture, mood);
        productionHasBehaviorIntent =
            primitive != null || productionGaze != null || act.gaze != 'none';
        if (productionHasBehaviorIntent || (act.emitMood && mood != 'none')) {
          final admission = authority.preflightBehavior(bodyGesture: primitive);
          if (!admission.applied) {
            return _productionBehaviorResult(
              admission,
              mood: mood,
              primitive: primitive,
            );
          }
        }
      }

      if (act.emitMood && mood != 'none') {
        final intensity = act.intensity.clamp(0.0, 1.0).toDouble();
        final params = _emotionFor(mood).scaled(intensity);
        _emitEmotion(
          AvatarEmotionIntent(
            label: mood,
            intensity: intensity,
            params: params,
            agentId: agentId,
            duration: act.persistent
                ? null
                : Duration(milliseconds: act.durationMs),
            persistent: act.persistent,
            automatic: ambient,
          ),
        );
        applied = true;
      }

      if (!canContinue()) return _interruptedAmbient;
      final authority = productionAuthority;
      if (authority != null) {
        if (!productionHasBehaviorIntent) {
          return AvatarBehaviorResult(
            applied: applied,
            reason: applied ? 'applied' : 'no visible intent',
            mood: mood,
            primitive: primitive,
          );
        }
        // The ticket still carries the bounded semantic primitive. Only keep
        // its body lease long enough for the corresponding imported one-shot;
        // gaze and expression retain the requested cue duration.
        final bodyClip = primitive == null
            ? null
            : _animationCatalog.selectClipForAct(
                backendKind: avatar?.backendKind ?? AvatarBackendKind.unity,
                gesture: primitive,
                mood: mood,
                posture: 'none',
                intensity: act.intensity,
              );
        final bodyDuration =
            bodyClip != null &&
                bodyClip.tags.contains('open_annie') &&
                !bodyClip.loop
            ? Duration(
                milliseconds: bodyClip.durationMs > act.durationMs
                    ? bodyClip.durationMs
                    : act.durationMs,
              )
            : null;
        final result = await authority.applyBehavior(
          ambient: ambient,
          shouldContinue: canContinue,
          gaze: productionGaze,
          clearGaze: productionGaze == null && act.gaze != 'none',
          bodyGesture: primitive,
          energy: performanceEnergy,
          intensity: performanceEnergy == null ? null : performanceIntensity,
          emotion: performanceEnergy == null
              ? null
              : _avatarPerformanceEmotion(mood),
          duration: Duration(milliseconds: act.durationMs),
          bodyDuration:
              performanceEnergy != null &&
                  _speechPerformanceGestures.contains(primitive)
              ? Duration(milliseconds: act.durationMs)
              : bodyDuration,
        );
        return _productionBehaviorResult(
          result,
          mood: mood,
          primitive: primitive,
        );
      }
      try {
        if (avatar != null) {
          final gaze = quietListeningGaze
              ? null
              : _gazeForAct(act, gesture, mood);
          if (gaze == null) {
            if (act.gaze != 'none') {
              await _gazeIntentHandler.hold(
                null,
                duration: Duration(milliseconds: act.durationMs),
              );
            }
          } else {
            await _gazeIntentHandler.hold(
              gaze,
              duration: Duration(milliseconds: act.durationMs),
            );
            applied = true;
          }

          if (!canContinue()) return _interruptedAmbient;
          final animationClip =
              performanceEnergy != null ||
                  (!act.inferGesture && gesture == 'none')
              ? null
              : _animationClipForAct(act, gesture, mood, avatar);
          if (animationClip != null) {
            await avatar.playAnimationClip(
              animationClip,
              _animationOptionsForAct(act),
            );
            applied = true;
          } else {
            final handTarget = performanceEnergy == null
                ? _handTargetForAct(gesture)
                : null;
            if (handTarget != null) {
              await avatar.setHandIkTarget(handTarget, _actOptions(act));
              applied = true;
            }

            if (!canContinue()) return _interruptedAmbient;
            if (primitive != null) {
              await avatar.playPrimitive(
                primitive,
                _primitiveOptionsForAct(act),
              );
              applied = true;
            }

            if (!canContinue()) return _interruptedAmbient;
            final postureMotion = _postureMotionForAct(act.posture);
            if (postureMotion != null) {
              await avatar.playMotion(postureMotion, _actOptions(act));
              applied = true;
            }
          }
        }
      } on PlatformException catch (error) {
        if (error.code != 'not_ready') rethrow;
        return AvatarBehaviorResult(
          applied: false,
          reason: rendererNotReadyReason,
          mood: mood,
          primitive: primitive,
        );
      }

      return AvatarBehaviorResult(
        applied: applied,
        reason: applied ? 'applied' : 'no avatar runtime or visible intent',
        mood: mood,
        primitive: primitive,
      );
    },
  );

  Future<AvatarBehaviorResult> _withBehaviorProtection({
    required bool ambient,
    bool Function()? shouldContinue,
    required Duration duration,
    required Future<AvatarBehaviorResult> Function(bool Function() canContinue)
    apply,
  }) async {
    final protection = appServices.maybeFind<AvatarBehaviorProtection>();
    final revision = protection?.revisionFor(agentId) ?? 0;
    bool canContinue() =>
        (shouldContinue?.call() ?? true) &&
        (!ambient || (protection?.allowsAmbient(agentId, revision) ?? true));
    if (!canContinue()) return _interruptedAmbient;
    final hold = ambient ? null : protection?.begin(agentId, duration);
    try {
      final result = await apply(canContinue);
      if (!canContinue()) return _interruptedAmbient;
      hold?.complete(applied: result.applied);
      return result;
    } finally {
      // Idempotent: only failure/throw paths release an unfinished hold.
      hold?.complete(applied: false);
    }
  }

  static const _interruptedAmbient = AvatarBehaviorResult(
    applied: false,
    reason: 'explicit avatar expression is active',
  );

  static AvatarBehaviorResult _productionBehaviorResult(
    AvatarProductionBehaviorResult result, {
    required String mood,
    required String? primitive,
  }) => switch (result.disposition) {
    AvatarProductionBehaviorDisposition.applied => AvatarBehaviorResult(
      applied: true,
      reason: 'applied',
      mood: mood,
      primitive: primitive,
    ),
    AvatarProductionBehaviorDisposition.capabilityUnavailable =>
      AvatarBehaviorResult(
        applied: false,
        reason: 'avatar capability unavailable',
        mood: mood,
        primitive: primitive,
      ),
    AvatarProductionBehaviorDisposition.rendererNotReady ||
    AvatarProductionBehaviorDisposition.authorityStale ||
    AvatarProductionBehaviorDisposition.retainedBehindHigherPriority ||
    AvatarProductionBehaviorDisposition.dispatchFailed => AvatarBehaviorResult(
      applied: false,
      reason: rendererNotReadyReason,
      mood: mood,
      primitive: primitive,
    ),
  };

  static void _requireRenderer(AvatarBehaviorResult result) {
    if (result.applied) return;
    if (result.reason == rendererNotReadyReason) {
      throw PlatformException(
        code: 'not_ready',
        message: 'Avatar renderer is still loading',
      );
    }
    if (result.reason == 'avatar capability unavailable') {
      throw PlatformException(
        code: 'avatar_capability_unavailable',
        message: 'Avatar capability is unavailable',
      );
    }
    throw PlatformException(
      code: 'avatar_action_not_applied',
      message: 'Avatar action was not applied',
    );
  }

  Future<AvatarBehaviorResult> autoReact(
    AvatarAutoReactionContext context,
  ) async {
    _syncAutoScope();
    final plan = planAutoReaction(context);
    if (!plan.shouldApply) {
      return AvatarBehaviorResult(applied: false, reason: plan.reason);
    }
    final now = _now();
    final repeatedGesture =
        plan.gesture == _lastAutoGesture &&
        _lastAutoGestureAt != null &&
        !now.isBefore(_lastAutoGestureAt!) &&
        now.difference(_lastAutoGestureAt!) < const Duration(seconds: 4);
    if (repeatedGesture) {
      // Keep a bounded gaze/expression cue, without replaying the same body
      // animation on every short answer. TTS alone owns the mouth.
      return applyAct(
        AvatarAct(
          mood: plan.mood,
          gesture: 'none',
          gaze: plan.gaze,
          style: 'subtle',
          intensity: plan.intensity * 0.6,
          durationMs: 650,
          emitMood: plan.emitMood,
          inferGesture: false,
        ),
        ambient: true,
      );
    }
    final AvatarBehaviorResult result = await switch (plan.kind) {
      AvatarBehaviorPlanKind.act => applyAct(
        AvatarAct(
          mood: plan.mood,
          gesture: plan.gesture,
          gaze: plan.gaze,
          style: plan.style,
          intensity: plan.intensity,
          durationMs: plan.durationMs,
          emitMood: plan.emitMood,
        ),
        ambient: true,
      ),
      AvatarBehaviorPlanKind.reaction => applyReaction(
        AvatarReaction(
          mood: plan.emitMood ? plan.mood : 'none',
          gesture: plan.gesture,
          gaze: plan.gaze,
          style: plan.style,
          intensity: plan.intensity,
          durationMs: plan.durationMs,
        ),
        ambient: true,
      ),
      AvatarBehaviorPlanKind.none => Future.value(
        AvatarBehaviorResult(applied: false, reason: plan.reason),
      ),
    };
    if (result.applied) {
      _lastAutoGesture = plan.gesture;
      _lastAutoGestureAt = now;
    }
    return result;
  }

  /// Only real conversation lifecycle events call this. Ambient arbitration
  /// lets explicit Avatar actions and persistent furniture posture win.
  Future<AvatarBehaviorResult> reactToConversationPhase(
    AvatarConversationPhase phase,
  ) async {
    _syncAutoScope();
    if (phase == _conversationPhase ||
        (phase == AvatarConversationPhase.stopped &&
            _conversationPhase == AvatarConversationPhase.listening) ||
        (phase == AvatarConversationPhase.speaking &&
            _conversationPhase == AvatarConversationPhase.listening)) {
      return const AvatarBehaviorResult(
        applied: false,
        reason: 'conversation phase unchanged or user still speaking',
      );
    }
    _conversationPhase = phase;
    final epoch = ++_phaseEpoch;
    final scope = _autoScope;
    final generation = _autoRendererGeneration;
    final runtime = _runtimeProvider();
    final nativePhase =
        runtime != null &&
        runtime is AvatarConversationPhaseRuntime &&
        runtime.isReady.value &&
        !AvatarProductionOwnership.blocksLegacyAvatarMutation;
    final ticketedPhase =
        !nativePhase &&
        AvatarProductionOwnership.currentFor(agentId)?.phase ==
            AvatarProductionAuthorityPhase.enforcing;
    final retirePhasePerformance =
        ticketedPhase && _phasePerformanceEpoch == epoch - 1;
    if (nativePhase) {
      final stamp = DateTime.now().microsecondsSinceEpoch;
      _nativePhaseSequence = stamp > _nativePhaseSequence
          ? stamp
          : _nativePhaseSequence + 1;
      // Phase hints schedule local ambient motion; model and audio playback
      // never wait for this optional renderer capability.
      unawaited(
        (runtime as AvatarConversationPhaseRuntime)
            .setConversationPhase(phase.name, sequence: _nativePhaseSequence)
            .catchError((Object _) {}),
      );
    }
    final act = switch (phase) {
      AvatarConversationPhase.listening => AvatarAct(
        mood: 'comforting',
        gesture: nativePhase ? 'none' : 'listen',
        inferGesture: !nativePhase,
        gaze: ticketedPhase ? 'none' : 'user',
        style: 'subtle',
        intensity: 0.3,
        durationMs: ticketedPhase ? 3500 : 750,
        energy: ticketedPhase ? 'gentle' : null,
      ),
      AvatarConversationPhase.thinking => AvatarAct(
        mood: 'thinking',
        gesture: nativePhase ? 'none' : 'think',
        inferGesture: !nativePhase,
        gaze: 'down',
        style: 'subtle',
        intensity: 0.35,
        durationMs: 950,
      ),
      AvatarConversationPhase.speaking => AvatarAct(
        gesture: nativePhase || ticketedPhase ? 'none' : 'explain',
        inferGesture: !nativePhase && !ticketedPhase,
        gaze: 'user',
        style: 'subtle',
        intensity: 0.36,
        durationMs: ticketedPhase ? 3500 : 1250,
        energy: ticketedPhase ? 'gentle' : null,
        emitMood: false,
      ),
      AvatarConversationPhase.stopped => AvatarAct(
        gesture: 'none',
        gaze: retirePhasePerformance ? 'none' : 'user',
        style: 'subtle',
        intensity: retirePhasePerformance ? 0 : 0.22,
        durationMs: retirePhasePerformance ? 350 : 550,
        energy: retirePhasePerformance ? 'gentle' : null,
        emitMood: false,
        inferGesture: false,
      ),
    };
    final result = await applyAct(
      act,
      ambient: true,
      shouldContinue: () =>
          epoch == _phaseEpoch && _autoScopeCurrent(scope, generation),
    );
    if (epoch == _phaseEpoch) {
      if (!result.applied) {
        _conversationPhase = null;
      } else {
        _phasePerformanceEpoch =
            ticketedPhase &&
                (phase == AvatarConversationPhase.listening ||
                    phase == AvatarConversationPhase.speaking)
            ? epoch
            : null;
      }
    }
    return result;
  }

  AvatarBehaviorPlan planAutoReaction(AvatarAutoReactionContext context) {
    if (context.hasExplicitAvatarAction) {
      return const AvatarBehaviorPlan.none(
        scenario: 'explicit_avatar_action',
        reason: 'explicit avatar action already present',
      );
    }
    if (!context.hasVisibleResponse && context.emotionLabel == null) {
      return const AvatarBehaviorPlan.none(
        scenario: 'no_visible_response',
        reason: 'no visible response',
      );
    }

    final mood = _autoMood(context);
    final text = _autoText(context);
    final emitMood = !context.actionTypes.contains('emotion.set');

    if (_hasSurface(context)) {
      // Completing or showing a work is not inherently a celebration. A
      // positive face requires the response model's contextual mood choice.
      final showcaseMood = mood;
      final intensity = _autoIntensity(showcaseMood);
      return AvatarBehaviorPlan(
        scenario: _isGameTurn(text) ? 'game_showcase' : 'surface_showcase',
        kind: AvatarBehaviorPlanKind.act,
        mood: showcaseMood,
        gesture: 'explain',
        gaze: 'surface',
        style: 'normal',
        intensity: intensity < 0.68 ? 0.68 : intensity,
        durationMs: 1600,
        emitMood: emitMood,
      );
    }

    if (mood == 'thinking') {
      return AvatarBehaviorPlan(
        scenario: 'thinking',
        kind: AvatarBehaviorPlanKind.act,
        mood: mood,
        gesture: 'think',
        gaze: 'down',
        style: 'subtle',
        intensity: _autoIntensity(mood),
        durationMs: _autoDuration(mood),
        emitMood: emitMood,
      );
    }

    return AvatarBehaviorPlan(
      scenario: _scenarioForMood(mood),
      kind: AvatarBehaviorPlanKind.reaction,
      mood: mood,
      gesture: _autoGesture(context, mood),
      gaze: _autoGaze(context, mood),
      style: 'subtle',
      intensity: _autoIntensity(mood),
      durationMs: _autoDuration(mood),
      emitMood: emitMood,
    );
  }

  static AvatarRuntime? _activeRuntime() {
    if (!appServices.isRegistered<ActiveAvatarRuntime>()) return null;
    return appServices.find<ActiveAvatarRuntime>().current;
  }

  static void _eventBusEmitter(AvatarEmotionIntent intent) {
    EventBus().fire(
      EmotionStateEvent(
        intent.params,
        semanticLabel: intent.label,
        agentId: intent.agentId,
        duration: intent.duration,
        persistent: intent.persistent,
        automatic: intent.automatic,
      ),
    );
  }

  Duration? _performanceBodyDuration(
    String gesture,
    String mood,
    double intensity,
    int durationMs,
    AvatarRuntime? avatar,
  ) {
    final clip = _animationCatalog.selectClipForAct(
      backendKind: avatar?.backendKind ?? AvatarBackendKind.unity,
      gesture: gesture,
      mood: mood,
      posture: 'none',
      intensity: intensity,
    );
    if (clip == null || !clip.tags.contains('open_annie') || clip.loop) {
      return null;
    }
    return Duration(
      milliseconds: clip.durationMs > durationMs ? clip.durationMs : durationMs,
    );
  }

  static Map<String, dynamic> _primitiveOptions(AvatarReaction reaction) {
    final amplitude = (reaction.intensity * _styleAmplitude(reaction.style))
        .clamp(0.2, 1.25)
        .toDouble();
    return {
      'durationMs': reaction.durationMs,
      'amplitude': amplitude,
      if (reaction.energy != null &&
          !AvatarFurnitureState.gestures.contains(reaction.gesture)) ...{
        'energy': _avatarPerformanceEnergy(reaction.energy),
        'intensity': _avatarPerformanceIntensity(
          reaction.intensity,
          reaction.energy,
        ),
        'emotion': _avatarPerformanceEmotion(_normalizeMood(reaction.mood)),
      },
    };
  }

  static Map<String, dynamic> _primitiveOptionsForAct(AvatarAct act) {
    final amplitude = (act.intensity * _styleAmplitude(act.style))
        .clamp(0.2, 1.25)
        .toDouble();
    return {
      'durationMs': act.durationMs,
      'amplitude': amplitude,
      if (act.energy != null &&
          AvatarFurnitureState.gestureForPosture(act.posture) == null) ...{
        'energy': _avatarPerformanceEnergy(act.energy),
        'intensity': _avatarPerformanceIntensity(act.intensity, act.energy),
        'emotion': _avatarPerformanceEmotion(
          _normalizeMood(_moodForAct(act, _normalizeGesture(act.gesture))),
        ),
      },
    };
  }

  static Map<String, dynamic> _actOptions(AvatarAct act) => {
    'durationMs': act.durationMs,
    'intensity': act.intensity.clamp(0.0, 1.0).toDouble(),
  };

  static Map<String, dynamic> _animationOptionsForAct(AvatarAct act) => {
    'durationMs': act.durationMs,
    'intensity': act.intensity.clamp(0.0, 1.0).toDouble(),
    'fadeMs': 180,
    'loop': false,
    'speed': 1.0,
  };

  static double _styleAmplitude(String style) {
    return switch (style) {
      'subtle' => 0.55,
      'dramatic' => 1.15,
      _ => 0.85,
    };
  }

  static String _normalizeMood(String mood) {
    return switch (mood) {
      'tease' => 'teasing',
      'comfort' => 'comforting',
      'listen' => 'comforting',
      'questioning' => 'confused',
      'sleep' => 'sleepy',
      _ => mood,
    };
  }

  static String _normalizeGesture(String gesture) {
    return switch (gesture) {
      'explaining' || 'talk' || 'talking' => 'explain',
      'thinking' || 'thoughtful' => 'think',
      'comfort' || 'listening' => 'listen',
      'bashful' => 'shy',
      'jumping' => 'jump',
      _ => gesture,
    };
  }

  static String _moodForAct(AvatarAct act, String gesture) {
    if (act.mood != 'none') return act.mood;
    return switch (gesture) {
      'think' => 'thinking',
      'shy' => 'playful',
      'wave' || 'explain' => 'calm',
      'jump' => 'excited',
      'listen' => 'comforting',
      _ => 'none',
    };
  }

  static EmotionParams _emotionFor(String mood) {
    return switch (mood) {
      'playful' || 'teasing' => EmotionParams.wink,
      'comforting' => EmotionParams.comforting,
      'serious' => EmotionParams.serious,
      'excited' || 'proud' => EmotionParams.excited,
      'sleepy' => EmotionParams.sleeping,
      _ => EmotionParams.byName[mood] ?? EmotionParams.neutral,
    };
  }

  static String? _primitiveFor(String gesture, String mood) {
    final normalized = switch (gesture) {
      'lean' => 'lean_in',
      'leanin' => 'lean_in',
      'lookaway' => 'look_away',
      'none' || '' => _primitiveForMood(mood),
      _ => gesture,
    };
    if (normalized == 'none') return null;
    return normalized;
  }

  static String _primitiveForMood(String mood) {
    return switch (mood) {
      'thinking' => 'think',
      'playful' || 'teasing' => 'tease',
      'comforting' || 'calm' => 'listen',
      'excited' => 'cheer',
      'proud' => 'proud',
      'confused' => 'shrug',
      'sleepy' => 'yawn',
      'happy' => 'nod',
      'serious' => 'nod',
      _ => 'none',
    };
  }

  static AvatarGaze? _gazeFor(String gaze) {
    return switch (gaze) {
      'user' => const AvatarGaze(eyeX: 0, eyeY: 0, headX: 0, headY: 0),
      'surface' => const AvatarGaze(
        eyeX: 0.35,
        eyeY: -0.05,
        headX: 0.25,
        headY: -0.05,
        headRoll: -0.07,
        upperBodyX: 0.25,
      ),
      'down' => const AvatarGaze(eyeX: 0, eyeY: -0.55, headX: 0, headY: -0.42),
      'away' || 'look_away' => const AvatarGaze(
        eyeX: 0.55,
        eyeY: -0.05,
        headX: 0.45,
        headY: -0.05,
        headRoll: -0.12,
        upperBodyX: 0.45,
      ),
      'left' => const AvatarGaze(
        eyeX: -0.55,
        eyeY: 0,
        headX: -0.4,
        headY: 0,
        headRoll: 0.11,
        upperBodyX: -0.4,
      ),
      'right' => const AvatarGaze(
        eyeX: 0.55,
        eyeY: 0,
        headX: 0.4,
        headY: 0,
        headRoll: -0.11,
        upperBodyX: 0.4,
      ),
      _ => null,
    };
  }

  static AvatarGaze? _gazeForAct(AvatarAct act, String gesture, String mood) {
    final explicit = _gazeFor(act.gaze);
    if (explicit != null || act.gaze != 'none') return explicit;
    return switch (gesture) {
      'think' => _gazeFor('down'),
      'shy' => _gazeFor('away'),
      'explain' || 'wave' || 'listen' => _gazeFor('user'),
      _ => switch (mood) {
        'thinking' => _gazeFor('down'),
        'playful' || 'teasing' || 'comforting' || 'calm' => _gazeFor('user'),
        _ => null,
      },
    };
  }

  static String? _handTargetForAct(String gesture) {
    return switch (gesture) {
      'think' => 'chest',
      'explain' => 'explain',
      'wave' => 'wave',
      'shy' => 'shy',
      'listen' => 'rest',
      _ => null,
    };
  }

  static String? _primitiveForAct(String gesture, String mood) {
    final primitive = switch (gesture) {
      'think' => 'think',
      'explain' => 'nod',
      'wave' => 'wave',
      'shy' => 'look_away',
      'listen' => 'listen',
      'jump' => 'jump',
      'none' || '' => _primitiveForMood(mood),
      _ => gesture,
    };
    if (primitive == 'none') return null;
    return primitive;
  }

  static String? _postureMotionForAct(String posture) {
    final motion = switch (posture) {
      'turn_left' ||
      'turn_right' ||
      'turn_back' ||
      'look_back' ||
      'step_forward' ||
      'step_back' ||
      'jump' ||
      'reset' => posture,
      'lean_in' => 'step_forward',
      'lean_back' => 'step_back',
      _ => 'none',
    };
    if (motion == 'none') return null;
    return motion;
  }

  String? _animationClipForAct(
    AvatarAct act,
    String gesture,
    String mood,
    AvatarRuntime avatar,
  ) {
    return _animationCatalog
        .selectClipForAct(
          backendKind: avatar.backendKind,
          gesture: gesture,
          mood: mood,
          posture: act.posture,
          intensity: act.intensity,
        )
        ?.id;
  }

  static String _autoMood(AvatarAutoReactionContext context) {
    final label = context.emotionLabel?.trim().toLowerCase();
    if (label != null && label.isNotEmpty) return _normalizeMood(label);
    final text = '${context.reply} ${context.voiceText}'.toLowerCase();
    if (_containsAny(text, const ['想想', '捋', '看看', 'think', 'check'])) {
      return 'thinking';
    }
    if (_containsAny(text, const ['辛苦', '别急', '我在', '陪', 'tired'])) {
      return 'comforting';
    }
    return 'calm';
  }

  static String _autoGesture(AvatarAutoReactionContext context, String mood) {
    return switch (mood) {
      'thinking' => 'think',
      'comforting' || 'calm' => 'listen',
      'excited' => 'cheer',
      'confused' => 'shrug',
      'playful' || 'teasing' => 'tease',
      _ => 'nod',
    };
  }

  static String _autoGaze(AvatarAutoReactionContext context, String mood) {
    return switch (mood) {
      'thinking' => 'down',
      'playful' || 'teasing' => 'user',
      'comforting' || 'calm' => 'user',
      _ => 'none',
    };
  }

  static double _autoIntensity(String mood) {
    return switch (mood) {
      'excited' => 0.75,
      'playful' || 'teasing' => 0.68,
      'comforting' || 'calm' => 0.45,
      _ => 0.6,
    };
  }

  static int _autoDuration(String mood) {
    return switch (mood) {
      'thinking' => 1400,
      'comforting' || 'calm' => 1200,
      'excited' => 1300,
      _ => 1000,
    };
  }

  static String _autoText(AvatarAutoReactionContext context) {
    return '${context.reply} ${context.voiceText}'.trim().toLowerCase();
  }

  static bool _hasSurface(AvatarAutoReactionContext context) {
    return context.actionTypes.contains('surface.show');
  }

  static bool _isGameTurn(String text) {
    return _containsAny(text, const [
      'game',
      'playable',
      '游戏',
      '小游戏',
      '雷霆战机',
      '五子棋',
      '俄罗斯方块',
      '大富翁',
      '开始玩',
      '能玩',
    ]);
  }

  static String _scenarioForMood(String mood) {
    return switch (mood) {
      'comforting' => 'comfort',
      'excited' => 'celebration',
      'playful' || 'teasing' => 'playful',
      'confused' => 'confused',
      'sleepy' => 'sleepy',
      'calm' => 'calm',
      _ => 'default',
    };
  }

  static bool _containsAny(String text, List<String> needles) {
    for (final needle in needles) {
      if (text.contains(needle)) return true;
    }
    return false;
  }
}

class _RegisteredAvatarGazeIntentHandler implements AvatarGazeIntentHandler {
  const _RegisteredAvatarGazeIntentHandler(this._runtimeProvider);

  final AvatarRuntimeProvider _runtimeProvider;

  @override
  Future<void> hold(AvatarGaze? gaze, {required Duration duration}) async {
    final registered = appServices.maybeFind<AvatarGazeIntentHandler>();
    if (registered != null && !identical(registered, this)) {
      await registered.hold(gaze, duration: duration);
      return;
    }

    // Account-runtime tests and pre-mount callers do not own a GazeDirector
    // yet. Keep that boundary compatible without letting the behavior
    // director itself manage renderer gaze or timers.
    final runtime = _runtimeProvider();
    if (runtime == null) return;
    if (gaze == null) {
      await runtime.clearGaze();
    } else {
      await runtime.setGaze(gaze);
    }
  }
}
