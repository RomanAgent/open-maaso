import 'package:maaso/src/core/foundation/app_framework.dart';

/// Tunable behavior knobs for the proactive / face-aware feedback loop.
///
/// Default values are sensible "fresh user" defaults; the agent can adjust
/// any of them at runtime through [BehaviorSkill] in response to what the
/// user says (e.g. "I'm going to be busy, don't wait for me" → bump [absentReactDelay] up).
///
/// All values are reactive — every consumer ([EmotionSensorService],
/// [AgentRuntime._handleEnvironment]) reads the .value each time it needs
/// the threshold, so changes take effect immediately without rewiring.
class AgentBehaviorConfig extends AppService {
  /// How long the user must stay out of frame before we tell the agent
  /// "they walked away".  Default 10s.  Raise this when the user asks to be left
  /// alone for a while.
  final RxInt absentReactDelaySeconds = 10.obs;

  /// Minimum gap between two face-driven proactive reactions (any label).
  /// Default 45s — feels conversational without being chatty.
  final RxInt faceProactiveCooldownSeconds = 45.obs;

  /// Same-label re-emit cooldown.  If the user holds an expression this
  /// long, we'll fire the event again so the agent can acknowledge it
  /// fresh.  Default 120s.
  final RxInt sustainedMoodCooldownSeconds = 120.obs;

  /// Cooldown for non-face system cues (battery_low, network_changed…).
  /// Stays slow on purpose — these aren't conversation, they're alerts.
  /// Default 240s (4 min).
  final RxInt envProactiveCooldownSeconds = 240.obs;

  /// When true, AgentRuntime.chat() routes through the iterative
  /// multi-step "think → act → observe" loop instead of the single-shot
  /// streaming path.  Slower but supports tool-result feedback.
  /// Default true: the agent is an auto-plan agent (the user can stop a turn
  /// with the input-bar pause button).
  final RxBool multiStepEnabled = true.obs;

  /// Max steps the iterative loop will take before giving up.
  final RxInt multiStepBudget = 8.obs;

  /// When true, the runtime prefers the **native tool-calling** path
  /// (provider's `tools[]` + `tool_calls` protocol) over the JS sandbox for
  /// simple single-step queries.  Pros: ~15-20% fewer prompt tokens, faster
  /// (one fewer LLM round-trip vs the sandbox's parse-then-eval).
  ///
  /// Default OFF.  The native channel only exposes skills that declare a
  /// JSON schema. The voice-first runtime still
  /// expects a structured reply track plus host actions; a pure native tool
  /// call can leave assistant text empty, so [nativeToolProcess] has nothing
  /// useful to surface and returns the "(I ran N tool call(s) but did not
  /// produce a final reply…)" placeholder. Until the native path grows a reply
  /// channel + a native-specific prompt, keep the structured action path as the
  /// default.
  final RxBool useNativeTools = false.obs;

  /// Acoustic voice barge-in: when true, the mic keeps listening while the
  /// agent speaks (hardware AEC on) so the user can interrupt by talking.
  /// Default OFF — opt-in until validated on real devices (AEC quality varies).
  final RxBool voiceBargeInEnabled = false.obs;

  /// Host-driven presence loop.  When enabled, the agent can maintain a
  /// lightweight life state, move silently, and occasionally surface short
  /// presence thoughts through the normal runtime path.
  final RxBool presenceEnabled = true.obs;

  /// Cadence for presence state decay and ambient motion checks.
  final RxInt presenceTickSeconds = 30.obs;

  /// Minimum gap between silent avatar motions from the presence loop.
  final RxInt presenceSilentMotionCooldownSeconds = 18.obs;

  /// Minimum gap between spoken presence thoughts.
  final RxInt presenceSpokenCooldownSeconds = 240.obs;

  /// Spoken presence thoughts are rarer while half-resting.
  final RxInt presenceHalfRestSpokenCooldownSeconds = 900.obs;

  /// Rolling window for active-conversation detection.
  final RxInt presenceActiveWindowSeconds = 120.obs;

  /// Number of user turns in the active window that counts as active chat.
  final RxInt presenceActiveTurnThreshold = 3.obs;

  /// Average reply gap under this value counts as fast conversation.
  final RxInt presenceFastReplyGapSeconds = 24.obs;

  /// Minimum gap between agent follow-up questions in active chat.
  final RxInt presenceFollowUpCooldownSeconds = 120.obs;

  /// Minimum gap between input-focus boosts so tapping the field cannot spam
  /// arousal.
  final RxInt presenceInputFocusBoostCooldownSeconds = 8.obs;

  /// Quiet hours bias the presence state toward half-rest.
  final RxInt presenceNightQuietStartHour = 23.obs;
  final RxInt presenceNightQuietEndHour = 7.obs;

  /// Product-level style switch for the strong anthropomorphic behavior the
  /// owner requested.
  final RxBool presenceStrongAnthropomorphic = true.obs;

  /// Convenience getters so consumers don't have to wrap in Duration() each
  /// time they read a value.
  Duration get absentReactDelay =>
      Duration(seconds: absentReactDelaySeconds.value);
  Duration get faceProactiveCooldown =>
      Duration(seconds: faceProactiveCooldownSeconds.value);
  Duration get sustainedMoodCooldown =>
      Duration(seconds: sustainedMoodCooldownSeconds.value);
  Duration get envProactiveCooldown =>
      Duration(seconds: envProactiveCooldownSeconds.value);
  Duration get presenceTick => Duration(seconds: presenceTickSeconds.value);
  Duration get presenceSilentMotionCooldown =>
      Duration(seconds: presenceSilentMotionCooldownSeconds.value);
  Duration get presenceSpokenCooldown =>
      Duration(seconds: presenceSpokenCooldownSeconds.value);
  Duration get presenceHalfRestSpokenCooldown =>
      Duration(seconds: presenceHalfRestSpokenCooldownSeconds.value);
  Duration get presenceActiveWindow =>
      Duration(seconds: presenceActiveWindowSeconds.value);
  Duration get presenceFastReplyGap =>
      Duration(seconds: presenceFastReplyGapSeconds.value);
  Duration get presenceFollowUpCooldown =>
      Duration(seconds: presenceFollowUpCooldownSeconds.value);
  Duration get presenceInputFocusBoostCooldown =>
      Duration(seconds: presenceInputFocusBoostCooldownSeconds.value);

  /// Set a knob by name.  Returns the new value (clamped to a safe range)
  /// or null if the name is unknown.  Used by [BehaviorSkill].
  int? setParam(String name, int seconds) {
    switch (name) {
      case 'absentReactDelay':
        final v = seconds.clamp(3, 3600);
        absentReactDelaySeconds.value = v;
        return v;
      case 'faceProactiveCooldown':
        final v = seconds.clamp(10, 3600);
        faceProactiveCooldownSeconds.value = v;
        return v;
      case 'sustainedMoodCooldown':
        final v = seconds.clamp(30, 7200);
        sustainedMoodCooldownSeconds.value = v;
        return v;
      case 'envProactiveCooldown':
        final v = seconds.clamp(30, 86400);
        envProactiveCooldownSeconds.value = v;
        return v;
      case 'multiStepBudget':
        final v = seconds.clamp(1, 16);
        multiStepBudget.value = v;
        return v;
      case 'presenceTick':
        final v = seconds.clamp(5, 3600);
        presenceTickSeconds.value = v;
        return v;
      case 'presenceSilentMotionCooldown':
        final v = seconds.clamp(3, 3600);
        presenceSilentMotionCooldownSeconds.value = v;
        return v;
      case 'presenceSpokenCooldown':
        final v = seconds.clamp(30, 86400);
        presenceSpokenCooldownSeconds.value = v;
        return v;
      case 'presenceHalfRestSpokenCooldown':
        final v = seconds.clamp(60, 86400);
        presenceHalfRestSpokenCooldownSeconds.value = v;
        return v;
      case 'presenceActiveWindow':
        final v = seconds.clamp(15, 1800);
        presenceActiveWindowSeconds.value = v;
        return v;
      case 'presenceActiveTurnThreshold':
        final v = seconds.clamp(2, 12);
        presenceActiveTurnThreshold.value = v;
        return v;
      case 'presenceFastReplyGap':
        final v = seconds.clamp(3, 300);
        presenceFastReplyGapSeconds.value = v;
        return v;
      case 'presenceFollowUpCooldown':
        final v = seconds.clamp(15, 7200);
        presenceFollowUpCooldownSeconds.value = v;
        return v;
      case 'presenceInputFocusBoostCooldown':
        final v = seconds.clamp(1, 600);
        presenceInputFocusBoostCooldownSeconds.value = v;
        return v;
      case 'presenceNightQuietStartHour':
        final v = seconds.clamp(0, 23);
        presenceNightQuietStartHour.value = v;
        return v;
      case 'presenceNightQuietEndHour':
        final v = seconds.clamp(0, 23);
        presenceNightQuietEndHour.value = v;
        return v;
      default:
        return null;
    }
  }

  /// Toggle the iterative multi-step loop on/off.  Separate from setParam
  /// because it's a bool, not seconds.
  void setMultiStep(bool enabled) {
    multiStepEnabled.value = enabled;
  }

  /// Toggle acoustic voice barge-in on/off.
  void setVoiceBargeIn(bool enabled) {
    voiceBargeInEnabled.value = enabled;
  }

  void setPresenceEnabled(bool enabled) {
    presenceEnabled.value = enabled;
  }

  void setPresenceStrongAnthropomorphic(bool enabled) {
    presenceStrongAnthropomorphic.value = enabled;
  }

  /// Read a knob by name (seconds) or null if unknown.
  int? getParam(String name) {
    switch (name) {
      case 'absentReactDelay':
        return absentReactDelaySeconds.value;
      case 'faceProactiveCooldown':
        return faceProactiveCooldownSeconds.value;
      case 'sustainedMoodCooldown':
        return sustainedMoodCooldownSeconds.value;
      case 'envProactiveCooldown':
        return envProactiveCooldownSeconds.value;
      case 'presenceTick':
        return presenceTickSeconds.value;
      case 'presenceSilentMotionCooldown':
        return presenceSilentMotionCooldownSeconds.value;
      case 'presenceSpokenCooldown':
        return presenceSpokenCooldownSeconds.value;
      case 'presenceHalfRestSpokenCooldown':
        return presenceHalfRestSpokenCooldownSeconds.value;
      case 'presenceActiveWindow':
        return presenceActiveWindowSeconds.value;
      case 'presenceActiveTurnThreshold':
        return presenceActiveTurnThreshold.value;
      case 'presenceFastReplyGap':
        return presenceFastReplyGapSeconds.value;
      case 'presenceFollowUpCooldown':
        return presenceFollowUpCooldownSeconds.value;
      case 'presenceInputFocusBoostCooldown':
        return presenceInputFocusBoostCooldownSeconds.value;
      case 'presenceNightQuietStartHour':
        return presenceNightQuietStartHour.value;
      case 'presenceNightQuietEndHour':
        return presenceNightQuietEndHour.value;
      default:
        return null;
    }
  }

  /// Snapshot of every knob — used by the skill's getAll method so the
  /// agent can quote its own current settings to the user.
  Map<String, dynamic> snapshot() => {
    'absentReactDelay': absentReactDelaySeconds.value,
    'faceProactiveCooldown': faceProactiveCooldownSeconds.value,
    'sustainedMoodCooldown': sustainedMoodCooldownSeconds.value,
    'envProactiveCooldown': envProactiveCooldownSeconds.value,
    'multiStepEnabled': multiStepEnabled.value,
    'multiStepBudget': multiStepBudget.value,
    'useNativeTools': useNativeTools.value,
    'voiceBargeInEnabled': voiceBargeInEnabled.value,
    'presenceEnabled': presenceEnabled.value,
    'presenceTickSeconds': presenceTickSeconds.value,
    'presenceSilentMotionCooldownSeconds':
        presenceSilentMotionCooldownSeconds.value,
    'presenceSpokenCooldownSeconds': presenceSpokenCooldownSeconds.value,
    'presenceHalfRestSpokenCooldownSeconds':
        presenceHalfRestSpokenCooldownSeconds.value,
    'presenceActiveWindowSeconds': presenceActiveWindowSeconds.value,
    'presenceActiveTurnThreshold': presenceActiveTurnThreshold.value,
    'presenceFastReplyGapSeconds': presenceFastReplyGapSeconds.value,
    'presenceFollowUpCooldownSeconds': presenceFollowUpCooldownSeconds.value,
    'presenceInputFocusBoostCooldownSeconds':
        presenceInputFocusBoostCooldownSeconds.value,
    'presenceNightQuietStartHour': presenceNightQuietStartHour.value,
    'presenceNightQuietEndHour': presenceNightQuietEndHour.value,
    'presenceStrongAnthropomorphic': presenceStrongAnthropomorphic.value,
  };
}
