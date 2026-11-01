import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/acoustic_barge_in_policy.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/voice_duplex_policy.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';

void main() {
  test('admits only iOS typed speech with every live gate enabled', () {
    final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);
    final policy = _policy(behaviorConfig: behavior);

    expect(
      policy.captureDuringPlaybackAdmission,
      AcousticBargeInAdmission.allowed,
    );
    expect(policy.allowsCaptureDuringPlayback, isTrue);
  });

  test('all non-iOS platforms fail closed before consulting evidence', () {
    for (final platform in AppHostPlatform.values.where(
      (candidate) => candidate != AppHostPlatform.ios,
    )) {
      final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);
      final policy = _policy(
        platform: platform,
        behaviorConfig: behavior,
        aecEvidence: () => throw StateError('must not be read'),
        userInVoiceMode: () => throw StateError('must not be read'),
      );

      expect(
        policy.captureDuringPlaybackAdmission,
        AcousticBargeInAdmission.unsupportedPlatform,
        reason: platform.name,
      );
      expect(policy.allowsCaptureDuringPlayback, isFalse);
    }
  });

  test('legacy and text delivery fail closed before duplex evidence', () {
    for (final deliveryMode in <ConversationDeliveryMode>[
      ConversationDeliveryMode.legacy,
      ConversationDeliveryMode.text,
    ]) {
      final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);
      final policy = _policy(
        deliveryMode: deliveryMode,
        behaviorConfig: behavior,
        aecEvidence: () => throw StateError('must not be read'),
        userInVoiceMode: () => throw StateError('must not be read'),
      );

      expect(
        policy.captureDuringPlaybackAdmission,
        AcousticBargeInAdmission.speechDeliveryRequired,
        reason: deliveryMode.name,
      );
      expect(policy.allowsCaptureDuringPlayback, isFalse);
    }
  });

  test('entering voice mode is a live requirement', () {
    var voiceModeActive = false;
    final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);
    final policy = _policy(
      behaviorConfig: behavior,
      userInVoiceMode: () => voiceModeActive,
    );

    expect(
      policy.captureDuringPlaybackAdmission,
      AcousticBargeInAdmission.voiceModeInactive,
    );
    voiceModeActive = true;
    expect(policy.allowsCaptureDuringPlayback, isTrue);
  });

  test('AgentBehaviorConfig remains a live default-off rollout gate', () {
    final behavior = AgentBehaviorConfig();
    final policy = _policy(behaviorConfig: behavior);

    expect(
      policy.captureDuringPlaybackAdmission,
      AcousticBargeInAdmission.behaviorDisabled,
    );
    behavior.setVoiceBargeIn(true);
    expect(policy.allowsCaptureDuringPlayback, isTrue);
    behavior.setVoiceBargeIn(false);
    expect(policy.allowsCaptureDuringPlayback, isFalse);
  });

  test('missing or throwing AEC evidence fails closed', () {
    final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);

    expect(
      _policy(
        behaviorConfig: behavior,
        aecEvidence: () => false,
      ).captureDuringPlaybackAdmission,
      AcousticBargeInAdmission.missingAecEvidence,
    );
    expect(
      _policy(
        behaviorConfig: behavior,
        aecEvidence: () => throw StateError('AEC state unavailable'),
      ).captureDuringPlaybackAdmission,
      AcousticBargeInAdmission.missingAecEvidence,
    );
  });

  test('throwing voice-mode evidence fails closed', () {
    final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);

    expect(
      _policy(
        behaviorConfig: behavior,
        userInVoiceMode: () => throw StateError('voice state unavailable'),
      ).captureDuringPlaybackAdmission,
      AcousticBargeInAdmission.voiceModeInactive,
    );
  });

  test('constructor defaults to the configured conversation delivery mode', () {
    final behavior = AgentBehaviorConfig()..setVoiceBargeIn(true);
    final policy = AcousticBargeInPolicy(
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.ios,
      ),
      platformAecEvidence: () => true,
      userInVoiceMode: () => true,
      behaviorConfig: behavior,
    );

    expect(policy.deliveryMode, defaultConversationDeliveryMode);
    expect(
      policy.allowsCaptureDuringPlayback,
      defaultConversationDeliveryMode == ConversationDeliveryMode.speech,
    );
  });
}

AcousticBargeInPolicy _policy({
  AppHostPlatform platform = AppHostPlatform.ios,
  ConversationDeliveryMode deliveryMode = ConversationDeliveryMode.speech,
  required AgentBehaviorConfig behaviorConfig,
  VoiceDuplexBoolEvidence? aecEvidence,
  VoiceDuplexBoolEvidence? userInVoiceMode,
}) => AcousticBargeInPolicy(
  platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
  deliveryMode: deliveryMode,
  platformAecEvidence: aecEvidence ?? () => true,
  userInVoiceMode: userInVoiceMode ?? () => true,
  behaviorConfig: behaviorConfig,
);
