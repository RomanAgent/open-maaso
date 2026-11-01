import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/streaming_pcm_playback_reference_service.dart';
import 'package:record/record.dart';

/// A loud, constant-level PCM16 chunk so amplitude is unambiguously > 0 when
/// the waveform is live (RMS 8000 → /32768*6 → clamps to 1.0).
Uint8List _loudChunk({int samples = 320, int value = 8000}) {
  final bytes = Uint8List(samples * 2);
  final bd = ByteData.sublistView(bytes);
  for (var i = 0; i < samples; i++) {
    bd.setInt16(i * 2, value, Endian.little);
  }
  return bytes;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('MicCaptureService playback gate', () {
    test(
      'when playback is INACTIVE: amplitude is live and both streams emit',
      () async {
        final mic = MicCaptureService();
        final recognition = <int>[];
        final raw = <int>[];
        final subR = mic.recognitionStream.listen(
          (b) => recognition.add(b.length),
        );
        final subA = mic.audioStream.listen((b) => raw.add(b.length));

        mic.playbackActive.value = false;
        mic.debugIngest(_loudChunk());
        await pumpEventQueue();

        expect(
          mic.amplitude.value,
          greaterThan(0),
          reason: 'waveform should track the mic while the user can speak',
        );
        expect(
          recognition,
          isNotEmpty,
          reason: 'ASR/VAD should receive audio when the agent is silent',
        );
        expect(raw, isNotEmpty, reason: 'lip-sync reads the raw stream');

        await subR.cancel();
        await subA.cancel();
      },
    );

    test('when playback is ACTIVE: recognitionStream is muted and amplitude is '
        'zeroed, but raw audioStream stays live for lip-sync', () async {
      final mic = MicCaptureService();
      final recognition = <int>[];
      final raw = <int>[];
      final subR = mic.recognitionStream.listen(
        (b) => recognition.add(b.length),
      );
      final subA = mic.audioStream.listen((b) => raw.add(b.length));

      mic.playbackActive.value = true;
      mic.debugIngest(_loudChunk());
      await pumpEventQueue();

      expect(
        mic.amplitude.value,
        0,
        reason: 'waveform must not saturate on our own TTS / speaker echo',
      );
      expect(
        recognition,
        isEmpty,
        reason: 'the agent must never transcribe its own voice',
      );
      expect(
        raw,
        isNotEmpty,
        reason: 'system-TTS lip-sync still needs to hear playback echo',
      );

      await subR.cancel();
      await subA.cancel();
    });
  });

  group('MicCaptureService playback candidate capture', () {
    late RecordPlatform originalPlatform;
    late _CaptureAudioRecorder recorder;
    late MicCaptureService mic;
    late bool authorized;
    late bool authorizationThrows;
    late int authorizationReads;

    setUp(() async {
      originalPlatform = RecordPlatform.instance;
      RecordPlatform.instance = _RecorderInitializationPlatform();
      recorder = _CaptureAudioRecorder();
      await Future<void>.delayed(Duration.zero);
      authorized = false;
      authorizationThrows = false;
      authorizationReads = 0;
      mic = MicCaptureService(
        recorder: recorder,
        playbackCandidateHoldTimeout: const Duration(milliseconds: 250),
        playbackCandidateCaptureAuthorized: () {
          authorizationReads++;
          if (authorizationThrows) {
            throw StateError('authorization unavailable');
          }
          return authorized;
        },
      );
    });

    tearDown(() async {
      await mic.stop();
      mic.onClose();
      await recorder.streamController.close();
      RecordPlatform.instance = originalPlatform;
      await Future<void>.delayed(Duration.zero);
    });

    test('ordinary and denied sessions do not request AEC or NS', () async {
      authorized = true;
      expect(await mic.start(), isTrue);
      expect(authorizationReads, 0);
      expect(recorder.configs.single.echoCancel, isFalse);
      expect(recorder.configs.single.noiseSuppress, isFalse);
      expect(mic.playbackCandidateCaptureActive, isFalse);

      await mic.stop();
      authorized = false;
      expect(
        await mic.startWithOptions(includePlaybackCandidates: true),
        isTrue,
      );
      expect(authorizationReads, 1);
      expect(recorder.configs.last.echoCancel, isFalse);
      expect(recorder.configs.last.noiseSuppress, isFalse);
      expect(mic.playbackCandidateCaptureActive, isFalse);
    });

    test('authorized candidate session emits only during playback while '
        'recognition remains muted', () async {
      authorized = true;
      expect(
        await mic.startWithOptions(includePlaybackCandidates: true),
        isTrue,
      );
      expect(recorder.configs.single.echoCancel, isTrue);
      expect(recorder.configs.single.noiseSuppress, isTrue);
      expect(mic.playbackCandidateCaptureActive, isTrue);

      final raw = <Uint8List>[];
      final recognition = <Uint8List>[];
      final candidates = <Uint8List>[];
      final subscriptions = <StreamSubscription<Uint8List>>[
        mic.audioStream.listen(raw.add),
        mic.recognitionStream.listen(recognition.add),
        mic.playbackCandidateStream.listen(candidates.add),
      ];

      mic.playbackActive.value = true;
      recorder.streamController.add(_loudChunk());
      await pumpEventQueue();

      expect(raw, hasLength(1));
      expect(recognition, isEmpty);
      expect(candidates, hasLength(1));
      expect(mic.amplitude.value, 0);

      mic.playbackActive.value = false;
      recorder.streamController.add(_loudChunk());
      await pumpEventQueue();

      expect(raw, hasLength(2));
      expect(recognition, hasLength(1));
      expect(candidates, hasLength(1));
      expect(mic.amplitude.value, greaterThan(0));

      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    });

    test(
      'authorized PCM candidate suppresses exact echo but preserves user energy',
      () async {
        mic.onClose();
        final references = StreamingPcmPlaybackReferenceService();
        addTearDown(references.onClose);
        mic = MicCaptureService(
          recorder: recorder,
          streamingPcmReferenceService: () => references,
          playbackCandidateCaptureAuthorized: () => true,
        );
        expect(
          await mic.startWithOptions(includePlaybackCandidates: true),
          isTrue,
        );
        final playback = _sineChunk(frequencyHz: 503, amplitude: 0.32);
        final user = _sineChunk(frequencyHz: 1171, amplitude: 0.02);
        final lease = references.bind(
          turnId: 'turn-1',
          utteranceId: 'utterance-1',
          spokenText: 'private-spoken-text',
          agentId: 'agent-a',
          sink: _MicTestControllableSink(701),
        );
        lease.appendAcceptedPcm(
          pcmS16le: playback,
          sampleRate: 16000,
          channels: 1,
          sequence: 1,
        );
        lease.markAudible();
        mic.playbackActive.value = true;

        final raw = <Uint8List>[];
        final recognition = <Uint8List>[];
        final candidates = <Uint8List>[];
        final subscriptions = <StreamSubscription<Uint8List>>[
          mic.audioStream.listen(raw.add),
          mic.recognitionStream.listen(recognition.add),
          mic.playbackCandidateStream.listen(candidates.add),
        ];

        recorder.streamController.add(playback);
        await pumpEventQueue();
        expect(raw, hasLength(1));
        expect(recognition, isEmpty);
        expect(candidates, isEmpty);
        expect(mic.debugSuppressedStreamingEchoChunks, 1);

        recorder.streamController.add(_mixChunks(playback, user));
        await pumpEventQueue();
        expect(raw, hasLength(2));
        expect(recognition, isEmpty);
        expect(candidates, hasLength(1));
        expect(mic.debugSuppressedStreamingEchoChunks, 1);
        expect(
          _rmsDifference(candidates.single, user),
          lessThan(0.002),
          reason: 'candidate VAD/ASR should receive the quiet user residual',
        );

        references.bind(
          turnId: 'turn-2',
          utteranceId: 'utterance-2',
          spokenText: 'replacement',
          agentId: 'agent-a',
          sink: _MicTestControllableSink(702),
        );
        recorder.streamController.add(playback);
        await pumpEventQueue();
        expect(
          candidates,
          hasLength(2),
          reason: 'an old generation cannot suppress a new candidate window',
        );

        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      },
    );

    test(
      'invalid PCM playback cursor fails closed during active output',
      () async {
        mic.onClose();
        final references = StreamingPcmPlaybackReferenceService();
        addTearDown(references.onClose);
        mic = MicCaptureService(
          recorder: recorder,
          streamingPcmReferenceService: () => references,
          playbackCandidateCaptureAuthorized: () => true,
        );
        expect(
          await mic.startWithOptions(includePlaybackCandidates: true),
          isTrue,
        );
        final playback = _sineChunk(frequencyHz: 503, amplitude: 0.32);
        final sink = _MicTestControllableSink(711)
          ..acceptedFrames = 641
          ..playedFrames = 1;
        final lease = references.bind(
          turnId: 'turn-invalid-position',
          utteranceId: 'utterance-invalid-position',
          spokenText: 'private-spoken-text',
          agentId: 'agent-a',
          sink: sink,
        );
        lease.appendAcceptedPcm(
          pcmS16le: playback,
          sampleRate: 16000,
          channels: 1,
          sequence: 1,
        );
        lease.markAudible();
        await pumpEventQueue();
        expect(references.captureCurrentReference(), isNull);
        expect(references.captureCurrentPlayback(), isNotNull);
        mic.playbackActive.value = true;

        final candidates = <Uint8List>[];
        final candidateSub = mic.playbackCandidateStream.listen(candidates.add);
        recorder.streamController.add(playback);
        await pumpEventQueue();

        expect(candidates, isEmpty);
        expect(mic.debugSuppressedStreamingEchoChunks, 1);
        await candidateSub.cancel();
      },
    );

    test('authorization errors fail closed without failing capture', () async {
      authorizationThrows = true;

      expect(
        await mic.startWithOptions(includePlaybackCandidates: true),
        isTrue,
      );

      expect(authorizationReads, 1);
      expect(recorder.configs.single.echoCancel, isFalse);
      expect(recorder.configs.single.noiseSuppress, isFalse);
      expect(mic.playbackCandidateCaptureActive, isFalse);
      expect(mic.error.value, isNull);
    });

    test(
      'hold keeps pause tail on candidate stream until exact release',
      () async {
        authorized = true;
        expect(
          await mic.startWithOptions(includePlaybackCandidates: true),
          isTrue,
        );
        final recognition = <Uint8List>[];
        final candidates = <Uint8List>[];
        final recognitionSub = mic.recognitionStream.listen(recognition.add);
        final candidateSub = mic.playbackCandidateStream.listen(candidates.add);

        mic.playbackActive.value = true;
        final hold = mic.holdPlaybackCandidateCapture();
        expect(hold, isNotNull);
        expect(hold!.isActive, isTrue);

        // TTS pause and its playback tail may finish before VAD sees the
        // user's endpoint. The exact hold keeps those remaining frames on the
        // candidate path and never leaks them into ordinary recognition.
        mic.playbackActive.value = false;
        recorder.streamController.add(_loudChunk());
        await pumpEventQueue();

        expect(candidates, hasLength(1));
        expect(recognition, isEmpty);
        expect(mic.amplitude.value, 0);

        expect(hold.release(), isTrue);
        recorder.streamController.add(_loudChunk());
        await pumpEventQueue();

        expect(candidates, hasLength(1));
        expect(recognition, hasLength(1));
        expect(mic.amplitude.value, greaterThan(0));

        await recognitionSub.cancel();
        await candidateSub.cancel();
      },
    );

    test('stale release cannot clear a newer hold', () async {
      authorized = true;
      expect(
        await mic.startWithOptions(includePlaybackCandidates: true),
        isTrue,
      );
      final recognition = <Uint8List>[];
      final candidates = <Uint8List>[];
      final recognitionSub = mic.recognitionStream.listen(recognition.add);
      final candidateSub = mic.playbackCandidateStream.listen(candidates.add);

      mic.playbackActive.value = true;
      final first = mic.holdPlaybackCandidateCapture()!;
      final second = mic.holdPlaybackCandidateCapture()!;

      expect(first.isActive, isFalse);
      expect(first.release(), isFalse);
      expect(second.isActive, isTrue);

      mic.playbackActive.value = false;
      recorder.streamController.add(_loudChunk());
      await pumpEventQueue();
      expect(candidates, hasLength(1));
      expect(recognition, isEmpty);

      expect(second.release(), isTrue);
      expect(mic.playbackCandidateCaptureHeld, isFalse);

      await recognitionSub.cancel();
      await candidateSub.cancel();
    });

    test(
      'unauthorized or non-playback sessions cannot acquire a hold',
      () async {
        authorized = false;
        expect(
          await mic.startWithOptions(includePlaybackCandidates: true),
          isTrue,
        );
        mic.playbackActive.value = true;
        expect(mic.holdPlaybackCandidateCapture(), isNull);

        await mic.stop();
        authorized = true;
        expect(
          await mic.startWithOptions(includePlaybackCandidates: true),
          isTrue,
        );
        mic.playbackActive.value = false;
        expect(mic.holdPlaybackCandidateCapture(), isNull);
      },
    );

    test('stop clears a hold and invalidates its release token', () async {
      authorized = true;
      expect(
        await mic.startWithOptions(includePlaybackCandidates: true),
        isTrue,
      );
      mic.playbackActive.value = true;
      final hold = mic.holdPlaybackCandidateCapture()!;

      await mic.stop();

      expect(mic.playbackCandidateCaptureHeld, isFalse);
      expect(hold.isActive, isFalse);
      expect(hold.release(), isFalse);
    });

    test('hold auto-timeout restores ordinary recognition', () async {
      authorized = true;
      expect(
        await mic.startWithOptions(includePlaybackCandidates: true),
        isTrue,
      );
      final recognition = <Uint8List>[];
      final candidates = <Uint8List>[];
      final recognitionSub = mic.recognitionStream.listen(recognition.add);
      final candidateSub = mic.playbackCandidateStream.listen(candidates.add);

      mic.playbackActive.value = true;
      final hold = mic.holdPlaybackCandidateCapture()!;
      mic.playbackActive.value = false;
      recorder.streamController.add(_loudChunk());
      await pumpEventQueue();
      expect(candidates, hasLength(1));
      expect(recognition, isEmpty);

      await Future<void>.delayed(const Duration(milliseconds: 350));
      expect(hold.isActive, isFalse);
      expect(mic.playbackCandidateCaptureHeld, isFalse);

      recorder.streamController.add(_loudChunk());
      await pumpEventQueue();
      expect(candidates, hasLength(1));
      expect(recognition, hasLength(1));

      await recognitionSub.cancel();
      await candidateSub.cancel();
    });
  });

  group('playback-gate wiring (regression)', () {
    test('VAD reads the gated recognitionStream for voice endpointing', () {
      final vadFacade = File(
        'lib/src/core/services/vad_service.dart',
      ).readAsStringSync();
      expect(vadFacade, contains("if (dart.library.io) 'vad_service_io.dart'"));

      final vad = File(
        'lib/src/core/services/vad_service_io.dart',
      ).readAsStringSync();
      expect(vad, contains('recognitionStream'));

      final bar = File(
        'lib/src/core/widgets/chat_input_bar.dart',
      ).readAsStringSync();
      expect(bar, contains('vad.userIsSpeaking'));
      expect(bar, contains('playbackActive'));

      final u2aBar = File(
        'lib/src/features/chat/presentation/widgets/chat_input_bar.dart',
      ).readAsStringSync();
      expect(u2aBar, contains('vad.userIsSpeaking'));
    });

    test('system-TTS lip-sync keeps reading the raw, ungated audioStream', () {
      final lipFacade = File(
        'lib/src/core/services/tts_lip_sync_driver.dart',
      ).readAsStringSync();
      expect(
        lipFacade,
        contains("if (dart.library.io) 'tts_lip_sync_driver_io.dart'"),
      );

      final lip = File(
        'lib/src/core/services/tts_lip_sync_driver_io.dart',
      ).readAsStringSync();
      // If this ever flips to recognitionStream, lip-sync goes dead during
      // system TTS (it animates the mouth from the mic echo of playback).
      expect(lip, contains('mic.audioStream'));
    });
  });
}

final class _CaptureAudioRecorder extends AudioRecorder {
  final StreamController<Uint8List> streamController =
      StreamController<Uint8List>.broadcast();
  final List<RecordConfig> configs = <RecordConfig>[];
  int stopCount = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    configs.add(config);
    return streamController.stream;
  }

  @override
  Future<String?> stop() async {
    stopCount++;
    return null;
  }

  @override
  Future<void> dispose() async {}
}

final class _RecorderInitializationPlatform extends RecordPlatform {
  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> cancel(String recorderId) async => _unsupported();

  @override
  Future<void> dispose(String recorderId) async => _unsupported();

  @override
  Future<Amplitude> getAmplitude(String recorderId) => _unsupported();

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) =>
      _unsupported();

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) =>
      _unsupported();

  @override
  Future<bool> isPaused(String recorderId) => _unsupported();

  @override
  Future<bool> isRecording(String recorderId) => _unsupported();

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) =>
      _unsupported();

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  Future<void> pause(String recorderId) async => _unsupported();

  @override
  Future<void> resume(String recorderId) async => _unsupported();

  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) {}

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async => _unsupported();

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) => _unsupported();

  @override
  Future<String?> stop(String recorderId) => _unsupported();

  Never _unsupported() => throw UnsupportedError('not used by this test');
}

Uint8List _sineChunk({
  required double frequencyHz,
  required double amplitude,
  int samples = 640,
}) {
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples; index++) {
    final sample =
        (math.sin(2 * math.pi * frequencyHz * index / 16000) *
                amplitude *
                32767)
            .round();
    data.setInt16(index * 2, sample, Endian.little);
  }
  return bytes;
}

Uint8List _mixChunks(Uint8List first, Uint8List second) {
  final output = Uint8List(first.length);
  final firstData = ByteData.sublistView(first);
  final secondData = ByteData.sublistView(second);
  final outputData = ByteData.sublistView(output);
  for (var offset = 0; offset < output.length; offset += 2) {
    final mixed =
        firstData.getInt16(offset, Endian.little) +
        secondData.getInt16(offset, Endian.little);
    outputData.setInt16(offset, mixed.clamp(-32768, 32767), Endian.little);
  }
  return output;
}

double _rmsDifference(Uint8List first, Uint8List second) {
  expect(first.length, second.length);
  final firstData = ByteData.sublistView(first);
  final secondData = ByteData.sublistView(second);
  var squaredError = 0.0;
  final samples = first.length ~/ 2;
  for (var offset = 0; offset < first.length; offset += 2) {
    final difference =
        firstData.getInt16(offset, Endian.little) -
        secondData.getInt16(offset, Endian.little);
    squaredError += difference * difference;
  }
  return math.sqrt(squaredError / samples) / 32768.0;
}

final class _MicTestControllableSink implements PositionedStreamingAudioSink {
  _MicTestControllableSink(this.activeGeneration);

  @override
  int? activeGeneration;
  int acceptedFrames = 0;
  int playedFrames = 0;

  @override
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt() async =>
      StreamingAudioPlaybackPositionReceipt(
        generation: activeGeneration!,
        playedFrames: playedFrames,
        acceptedFrames: acceptedFrames,
      );

  @override
  Future<void> start({required int sampleRate, required int channels}) async {}

  @override
  Future<void> write(Uint8List pcmS16le) async {}

  @override
  Future<StreamingAudioControlReceipt> pauseWithReceipt() async =>
      StreamingAudioControlReceipt(
        generation: activeGeneration!,
        state: StreamingAudioControlState.paused,
      );

  @override
  Future<StreamingAudioControlReceipt> resumeWithReceipt() async =>
      StreamingAudioControlReceipt(
        generation: activeGeneration!,
        state: StreamingAudioControlState.resumed,
      );

  @override
  Future<void> stop({bool drain = true}) async {
    await stopWithReceipt(drain: drain);
  }

  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({
    bool drain = true,
  }) async {
    final generation = activeGeneration ?? 0;
    activeGeneration = null;
    return StreamingAudioPlaybackReceipt(
      generation: generation,
      terminal: drain
          ? StreamingAudioPlaybackTerminal.completed
          : StreamingAudioPlaybackTerminal.cancelled,
    );
  }
}
