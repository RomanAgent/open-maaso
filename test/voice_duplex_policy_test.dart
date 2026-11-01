import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/voice_duplex_policy.dart';

void main() {
  group('VoiceDuplexPolicy tap interrupt', () {
    test('explicit tap is always admitted while agent is speaking', () {
      final policy = _policy(
        platform: AppHostPlatform.web,
        aecEvidence: () => throw StateError('must not be read'),
        userOptIn: () => throw StateError('must not be read'),
        behaviorEnabled: () => throw StateError('must not be read'),
      );

      expect(
        policy.tapInterruptAdmission(agentSpeaking: true),
        VoiceDuplexAdmission.allowed,
      );
      expect(
        policy.tapInterruptAdmission(agentSpeaking: false),
        VoiceDuplexAdmission.agentNotSpeaking,
      );
    });
  });

  group('VoiceDuplexPolicy open-mic admission', () {
    for (final platform in AppHostPlatform.values) {
      test('${platform.name} requires native speech platform support', () {
        final policy = _policy(platform: platform);
        final supported = AppPlatformCapabilities.forPlatform(
          platform,
        ).actionStatus(AppActionCapability.localSpeechRecognition).available;

        expect(
          policy.openMicDuringPlaybackAdmission,
          supported
              ? VoiceDuplexAdmission.allowed
              : VoiceDuplexAdmission.unsupportedPlatform,
        );
      });
    }

    test('AEC evidence, opt-in, and behavior flag are all mandatory', () {
      final cases =
          <
            ({
              bool aec,
              bool optIn,
              bool behavior,
              VoiceDuplexAdmission expected,
            })
          >[
            (
              aec: false,
              optIn: true,
              behavior: true,
              expected: VoiceDuplexAdmission.missingAecEvidence,
            ),
            (
              aec: true,
              optIn: false,
              behavior: true,
              expected: VoiceDuplexAdmission.missingUserOptIn,
            ),
            (
              aec: true,
              optIn: true,
              behavior: false,
              expected: VoiceDuplexAdmission.behaviorDisabled,
            ),
            (
              aec: true,
              optIn: true,
              behavior: true,
              expected: VoiceDuplexAdmission.allowed,
            ),
          ];

      for (final entry in cases) {
        final policy = _policy(
          aecEvidence: () => entry.aec,
          userOptIn: () => entry.optIn,
          behaviorEnabled: () => entry.behavior,
        );
        expect(
          policy.openMicDuringPlaybackAdmission,
          entry.expected,
          reason:
              'aec=${entry.aec} optIn=${entry.optIn} '
              'behavior=${entry.behavior}',
        );
      }
    });

    test('throwing evidence readers fail closed', () {
      expect(
        _policy(
          aecEvidence: () => throw StateError('aec unavailable'),
        ).openMicDuringPlaybackAdmission,
        VoiceDuplexAdmission.missingAecEvidence,
      );
      expect(
        _policy(
          userOptIn: () => throw StateError('preference unavailable'),
        ).openMicDuringPlaybackAdmission,
        VoiceDuplexAdmission.missingUserOptIn,
      );
      expect(
        _policy(
          behaviorEnabled: () => throw StateError('config unavailable'),
        ).openMicDuringPlaybackAdmission,
        VoiceDuplexAdmission.behaviorDisabled,
      );
    });

    test('evidence is evaluated dynamically instead of cached', () {
      var optedIn = false;
      final policy = _policy(userOptIn: () => optedIn);

      expect(policy.allowsOpenMicDuringPlayback, isFalse);
      optedIn = true;
      expect(policy.allowsOpenMicDuringPlayback, isTrue);
    });
  });

  group('voice path contracts', () {
    test('Home explicit tap reaches runtime and the TTS stop seam', () {
      final homePage = _source(
        'lib/src/features/home/presentation/home_page.dart',
      );
      final homeController = _source(
        'lib/src/features/home/application/home_controller.dart',
      );
      final runtime = _source(
        'lib/src/features/agent/application/agent_runtime.dart',
      );

      expect(homePage, contains('onInterrupt: c.cancelCurrent'));
      expect(homePage, contains('onVoiceSend: c.send'));
      expect(homeController, contains('runtime!.interruptConversation()'));
      expect(homeController, contains('runtime?.cancelCurrent()'));
      expect(runtime, contains('MaasoTtsPlugin.stopAll(agentId: agentId)'));
    });

    test('VAD consumes recognitionStream and never raw audioStream', () {
      final vad = _source('lib/src/core/services/vad_service_io.dart');
      final subscription = _methodSlice(vad, 'Future<void> startWithOptions({');

      expect(subscription, contains('mic.recognitionStream.listen'));
      expect(subscription, isNot(contains('mic.audioStream.listen')));
    });

    test('both chat inputs pass only recognitionStream to streaming ASR', () {
      for (final path in <String>[
        'lib/src/core/widgets/chat_input_bar.dart',
        'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
      ]) {
        final source = _source(path);
        expect(source, contains('mic.recognitionStream'));
        expect(
          source,
          isNot(contains('audioStream: mic.audioStream')),
          reason: path,
        );
      }
    });
  });
}

VoiceDuplexPolicy _policy({
  AppHostPlatform platform = AppHostPlatform.macos,
  VoiceDuplexBoolEvidence? aecEvidence,
  VoiceDuplexBoolEvidence? userOptIn,
  VoiceDuplexBoolEvidence? behaviorEnabled,
}) => VoiceDuplexPolicy(
  platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
  platformAecEvidence: aecEvidence ?? () => true,
  userOptIn: userOptIn ?? () => true,
  behaviorEnabled: behaviorEnabled ?? () => true,
);

String _source(String path) => File(path).readAsStringSync();

String _methodSlice(String source, String signature) {
  final start = source.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: signature);
  final nextMethod = source.indexOf('\n  Future<', start + signature.length);
  return source.substring(start, nextMethod < 0 ? source.length : nextMethod);
}
