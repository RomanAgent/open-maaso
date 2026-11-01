import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'iOS PCM playback uses ordinary output unless voice processing capture is active',
    () {
      final appDelegate = File(
        'ios/Runner/AppDelegate.swift',
      ).readAsStringSync();
      final sinkStart = appDelegate.substring(
        appDelegate.indexOf('final class StreamingAudioSinkPlugin'),
        appDelegate.indexOf('final class NativeAsrPlugin'),
      );

      expect(sinkStart, contains('.playAndRecord'));
      expect(
        sinkStart,
        contains('args?["voiceProcessingCaptureActive"] as? Bool ?? false'),
      );
      expect(
        sinkStart,
        matches(
          RegExp(
            r'let mode:\s*AVAudioSession\.Mode\s*=\s*voiceProcessingCaptureActive\s*\?\s*\.voiceChat\s*:\s*\.default',
          ),
        ),
      );
      expect(sinkStart, contains('mode: mode'));
      expect(sinkStart, isNot(contains('mode: .spokenAudio')));
      expect(sinkStart, contains('.defaultToSpeaker'));
      expect(sinkStart, contains('.duckOthers'));
    },
  );

  test(
    'both conversation outputs observe recording and playback candidate capture at playback start',
    () {
      final runtime = File(
        'lib/src/features/agent/application/agent_runtime.dart',
      ).readAsStringSync();
      final factoryStart = runtime.indexOf(
        'MethodChannelStreamingAudioSink _createDefaultStreamingAudioSink()',
      );
      expect(factoryStart, greaterThanOrEqualTo(0));
      final factory = runtime.substring(
        factoryStart,
        runtime.indexOf('\n  }', factoryStart),
      );

      expect(factory, contains('voiceProcessingCaptureActive:'));
      expect(
        factory,
        matches(
          RegExp(
            r'isRecording\.value\s*==\s*true\s*&&\s*mic\?\.playbackCandidateCaptureActive\s*==\s*true',
          ),
        ),
      );
      expect(
        runtime,
        contains('sinkFactory: _createDefaultStreamingAudioSink'),
      );
      expect(
        runtime,
        contains('sink: liveAudioSink ?? _createDefaultStreamingAudioSink()'),
      );
    },
  );
}
