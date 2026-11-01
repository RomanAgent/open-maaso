import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

typedef VoiceDuplexBoolEvidence = bool Function();

/// Why a duplex interaction is or is not admitted.
enum VoiceDuplexAdmission {
  allowed,
  agentNotSpeaking,
  unsupportedPlatform,
  missingAecEvidence,
  missingUserOptIn,
  behaviorDisabled,
}

/// Fail-closed policy for explicit and acoustic interruption paths.
///
/// A user tap is an explicit command and remains available whenever the agent
/// is speaking. It deliberately does not consult acoustic evidence, opt-in, or
/// the experimental behavior switch.
///
/// Open-mic capture during playback is materially different: it is admitted
/// only when the host supports local speech recognition, the platform supplies
/// affirmative AEC evidence, and both user consent and the behavior switch are
/// currently true. Callers must read [openMicDuringPlaybackAdmission] at the
/// moment they intend to bypass the normal playback gate.
final class VoiceDuplexPolicy {
  const VoiceDuplexPolicy({
    required AppPlatformCapabilities platformCapabilities,
    required VoiceDuplexBoolEvidence platformAecEvidence,
    required VoiceDuplexBoolEvidence userOptIn,
    required VoiceDuplexBoolEvidence behaviorEnabled,
  }) : _platformCapabilities = platformCapabilities,
       _platformAecEvidence = platformAecEvidence,
       _userOptIn = userOptIn,
       _behaviorEnabled = behaviorEnabled;

  final AppPlatformCapabilities _platformCapabilities;
  final VoiceDuplexBoolEvidence _platformAecEvidence;
  final VoiceDuplexBoolEvidence _userOptIn;
  final VoiceDuplexBoolEvidence _behaviorEnabled;

  /// Explicit tap-to-interrupt is safe while speech is active and needs no
  /// acoustic/open-mic permission.
  VoiceDuplexAdmission tapInterruptAdmission({required bool agentSpeaking}) =>
      agentSpeaking
      ? VoiceDuplexAdmission.allowed
      : VoiceDuplexAdmission.agentNotSpeaking;

  /// Admission for keeping recognition/VAD live while playback is active.
  ///
  /// The checks are ordered from host capability to increasingly dynamic
  /// evidence. Every missing or throwing evidence source fails closed.
  VoiceDuplexAdmission get openMicDuringPlaybackAdmission {
    if (!_platformCapabilities
        .actionStatus(AppActionCapability.localSpeechRecognition)
        .available) {
      return VoiceDuplexAdmission.unsupportedPlatform;
    }
    if (!_readEvidence(_platformAecEvidence)) {
      return VoiceDuplexAdmission.missingAecEvidence;
    }
    if (!_readEvidence(_userOptIn)) {
      return VoiceDuplexAdmission.missingUserOptIn;
    }
    if (!_readEvidence(_behaviorEnabled)) {
      return VoiceDuplexAdmission.behaviorDisabled;
    }
    return VoiceDuplexAdmission.allowed;
  }

  bool get allowsOpenMicDuringPlayback =>
      openMicDuringPlaybackAdmission == VoiceDuplexAdmission.allowed;

  static bool _readEvidence(VoiceDuplexBoolEvidence evidence) {
    try {
      return evidence();
    } on Object {
      return false;
    }
  }
}
