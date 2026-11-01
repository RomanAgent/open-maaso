import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/voice_duplex_policy.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';

/// Why playback-time acoustic capture is or is not admitted.
enum AcousticBargeInAdmission {
  allowed,
  unsupportedPlatform,
  speechDeliveryRequired,
  missingAecEvidence,
  voiceModeInactive,
  behaviorDisabled,
  duplexPolicyDenied,
}

/// Product rollout gate for acoustic barge-in.
///
/// Playback-time capture is deliberately narrower than general voice duplex:
/// it is available only for the typed speech-delivery pipeline on iOS. The
/// underlying [VoiceDuplexPolicy] remains responsible for AEC evidence, user
/// opt-in (entering voice mode), and the behavior switch.
final class AcousticBargeInPolicy {
  AcousticBargeInPolicy({
    required this.platformCapabilities,
    required VoiceDuplexBoolEvidence platformAecEvidence,
    required VoiceDuplexBoolEvidence userInVoiceMode,
    required AgentBehaviorConfig behaviorConfig,
    this.deliveryMode = defaultConversationDeliveryMode,
  }) : _duplexPolicy = VoiceDuplexPolicy(
         platformCapabilities: platformCapabilities,
         platformAecEvidence: platformAecEvidence,
         userOptIn: userInVoiceMode,
         behaviorEnabled: () => behaviorConfig.voiceBargeInEnabled.value,
       );

  final AppPlatformCapabilities platformCapabilities;
  final ConversationDeliveryMode deliveryMode;
  final VoiceDuplexPolicy _duplexPolicy;

  AcousticBargeInAdmission get captureDuringPlaybackAdmission {
    if (platformCapabilities.platform != AppHostPlatform.ios) {
      return AcousticBargeInAdmission.unsupportedPlatform;
    }
    if (deliveryMode != ConversationDeliveryMode.speech) {
      return AcousticBargeInAdmission.speechDeliveryRequired;
    }

    return switch (_duplexPolicy.openMicDuringPlaybackAdmission) {
      VoiceDuplexAdmission.allowed => AcousticBargeInAdmission.allowed,
      VoiceDuplexAdmission.unsupportedPlatform =>
        AcousticBargeInAdmission.unsupportedPlatform,
      VoiceDuplexAdmission.missingAecEvidence =>
        AcousticBargeInAdmission.missingAecEvidence,
      VoiceDuplexAdmission.missingUserOptIn =>
        AcousticBargeInAdmission.voiceModeInactive,
      VoiceDuplexAdmission.behaviorDisabled =>
        AcousticBargeInAdmission.behaviorDisabled,
      VoiceDuplexAdmission.agentNotSpeaking =>
        AcousticBargeInAdmission.duplexPolicyDenied,
    };
  }

  bool get allowsCaptureDuringPlayback =>
      captureDuringPlaybackAdmission == AcousticBargeInAdmission.allowed;
}
