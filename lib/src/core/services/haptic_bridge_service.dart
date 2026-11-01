import 'dart:async';

import 'package:flutter/services.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';

/// Bridges [EmotionParams] to OS-level haptic feedback so the user can
/// *feel* the agent's mood through the phone.
///
/// Translation table (rough heuristics):
///   • tremor > 0.5            → heavy impact (anger)
///   • cheekFlush > 0.6 + any → light double-tap (shy / heart pounding)
///   • emotion happy intensity → light tap
///   • emotion sad             → soft selection click
///   • emotion fear / surprise → medium impact
///
/// Coalesced: a new "buzz" only fires when the emotion meaningfully *changed*
/// (not every frame the renderer ticks), so we don't vibrate the user to
/// death during a single conversation turn.
class HapticBridgeService extends AppService {
  AgentCoreController get _core => appServices.find<AgentCoreController>();
  AgentRuntimeRegistry get _registry =>
      appServices.find<AgentRuntimeRegistry>();

  Worker? _profileWatcher;
  Worker? _emotionWatcher;

  EmotionParams _lastSeen = EmotionParams.neutral;
  DateTime _lastBuzz = DateTime.fromMillisecondsSinceEpoch(0);
  static const _coolDown = Duration(milliseconds: 350);

  /// Master toggle (you might want a "do not disturb / no haptics" pref).
  final RxBool enabled = true.obs;

  @override
  void onInit() {
    super.onInit();
    _profileWatcher = ever(_core.profile, (profile) {
      if (profile != null) _attach();
    });
    if (_core.profile.value != null) _attach();
  }

  @override
  void onClose() {
    _profileWatcher?.dispose();
    _emotionWatcher?.dispose();
    super.onClose();
  }

  void _attach() {
    final runtime = _registry.get('self');
    if (runtime == null) return;
    _emotionWatcher?.dispose();
    _emotionWatcher = ever<EmotionParams>(runtime.emotion, _onEmotionChanged);
  }

  void _onEmotionChanged(EmotionParams e) {
    if (!enabled.value) {
      _lastSeen = e;
      return;
    }

    final now = DateTime.now();
    if (now.difference(_lastBuzz) < _coolDown) {
      _lastSeen = e;
      return;
    }

    final buzz = _selectFeedback(_lastSeen, e);
    if (buzz != null) {
      buzz();
      _lastBuzz = now;
    }
    _lastSeen = e;
  }

  /// Picks a haptic action based on what changed.  Returns null = stay silent.
  void Function()? _selectFeedback(EmotionParams prev, EmotionParams next) {
    // Anger / aggression: tremor crossing high threshold or hue going red.
    final crossedTremor = next.tremor > 0.4 && prev.tremor <= 0.4;
    final crossedRed = next.bodyHueShift > 0.5 && prev.bodyHueShift <= 0.5;
    if (crossedTremor || crossedRed) {
      return () => _heartbeat(intensity: next.tremor.clamp(0.4, 1.0));
    }

    // Surprise / fear: eyes pop wide.
    final crossedSurprise = next.eyeOpen > 1.2 && prev.eyeOpen <= 1.2;
    if (crossedSurprise) {
      return () => HapticFeedback.mediumImpact();
    }

    // Shy / pounding heart: cheekFlush spikes.
    final crossedFlush = next.cheekFlush > 0.55 && prev.cheekFlush <= 0.55;
    if (crossedFlush) {
      return _heartbeatLight;
    }

    // Joy / happiness onset: mouth curve goes strongly up.
    if (next.mouthCurve > 0.6 && prev.mouthCurve <= 0.4) {
      return HapticFeedback.lightImpact;
    }

    // Sadness: subtle quiet tap.
    if (next.mouthCurve < -0.5 && prev.mouthCurve >= -0.3) {
      return HapticFeedback.selectionClick;
    }

    return null;
  }

  /// Three quick light pulses, like a heartbeat.  Used for shy / pounding.
  Future<void> _heartbeatLight() async {
    await HapticFeedback.lightImpact();
    await Future.delayed(const Duration(milliseconds: 140));
    await HapticFeedback.lightImpact();
  }

  /// Heavy "thump" with optional follow-up rumble for high tremor.
  Future<void> _heartbeat({double intensity = 0.6}) async {
    await HapticFeedback.heavyImpact();
    if (intensity > 0.7) {
      await Future.delayed(const Duration(milliseconds: 80));
      await HapticFeedback.heavyImpact();
    }
  }
}
