import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/streaming_pcm_playback_reference_service.dart';

void main() {
  test('pure echo is removed while low-SNR user speech survives', () async {
    final service = StreamingPcmPlaybackReferenceService();
    addTearDown(service.onClose);
    final sink = _ControllableSink(101);
    final lease = _bind(service, sink);
    final playback = _chirpPcm(
      sampleRate: 16000,
      samples: 4800,
      startFrequencyHz: 240,
      endFrequencyHz: 2900,
      durationSeconds: 0.3,
      amplitude: 0.35,
    );

    expect(
      lease.appendAcceptedPcm(
        pcmS16le: playback,
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      ),
      isTrue,
    );
    expect(lease.markAudible(), isTrue);
    await pumpEventQueue();
    final receipt = service.captureCurrentReference()!;
    final delayedEcho = Uint8List.sublistView(playback, 237 * 2, 1837 * 2);
    final user = _chirpPcm(
      sampleRate: 16000,
      samples: 1600,
      startFrequencyHz: 530,
      endFrequencyHz: 1730,
      durationSeconds: 0.1,
      amplitude: 0.02,
    );
    final mixed = _mixPcm(delayedEcho, user);

    expect(service.filterPlaybackCandidate(delayedEcho, receipt), isNull);
    final filtered = service.filterPlaybackCandidate(mixed, receipt);
    expect(filtered, isNotNull);
    expect(
      _rmsDifference(filtered!, user),
      lessThan(_rmsDifference(mixed, user) * 0.08),
      reason: 'the emitted residual should retain the quiet user signal',
    );
  });

  test(
    'continuous 24k resampling is invariant to arbitrary odd frames',
    () async {
      final source = _chirpPcm(
        sampleRate: 24000,
        samples: 7201,
        startFrequencyHz: 180,
        endFrequencyHz: 2500,
        durationSeconds: 0.3,
        amplitude: 0.32,
      );
      final expectedEcho = _chirpPcm(
        sampleRate: 16000,
        samples: 4800,
        startFrequencyHz: 180,
        endFrequencyHz: 2500,
        durationSeconds: 0.3,
        amplitude: 0.32,
      );

      final singleService = StreamingPcmPlaybackReferenceService();
      final splitService = StreamingPcmPlaybackReferenceService();
      addTearDown(singleService.onClose);
      addTearDown(splitService.onClose);
      final single = _bind(singleService, _ControllableSink(201));
      final split = _bind(splitService, _ControllableSink(202));

      single.appendAcceptedPcm(
        pcmS16le: source,
        sampleRate: 24000,
        channels: 1,
        sequence: 1,
      );
      var sourceFrame = 0;
      var sequence = 0;
      const oddFramePattern = <int>[1, 17, 3, 29, 5, 43, 7, 11, 31];
      while (sourceFrame < 7201) {
        final requested = oddFramePattern[sequence % oddFramePattern.length];
        final frames = math.min(requested, 7201 - sourceFrame);
        split.appendAcceptedPcm(
          pcmS16le: Uint8List.sublistView(
            source,
            sourceFrame * 2,
            (sourceFrame + frames) * 2,
          ),
          sampleRate: 24000,
          channels: 1,
          sequence: ++sequence,
        );
        sourceFrame += frames;
      }
      expect(sequence, greaterThan(96));
      single.markAudible();
      split.markAudible();
      await pumpEventQueue();
      final singleReceipt = singleService.captureCurrentReference()!;
      final splitReceipt = splitService.captureCurrentReference()!;

      expect(splitReceipt.retainedSamples, singleReceipt.retainedSamples);
      for (final start in <int>[37, 1901, 3599]) {
        final window = Uint8List.sublistView(
          expectedEcho,
          start * 2,
          (start + 800) * 2,
        );
        final splitFiltered = splitService.filterPlaybackCandidate(
          window,
          splitReceipt,
        );
        final singleFiltered = singleService.filterPlaybackCandidate(
          window,
          singleReceipt,
        );
        expect(
          splitFiltered == null,
          singleFiltered == null,
          reason: 'frame boundaries changed filtering at sample $start',
        );
        if (splitFiltered != null && singleFiltered != null) {
          expect(
            splitFiltered,
            orderedEquals(singleFiltered),
            reason: 'frame boundaries changed the residual at sample $start',
          );
        }
      }
    },
  );

  test(
    'native playback head isolates audible PCM from a fast 10s queue',
    () async {
      final service = StreamingPcmPlaybackReferenceService();
      addTearDown(service.onClose);
      final sink = _ControllableSink(251);
      final lease = _bind(service, sink);
      final playback = _deterministicNoisePcm(samples: 160000, amplitude: 0.32);
      expect(
        lease.appendAcceptedPcm(
          pcmS16le: playback,
          sampleRate: 16000,
          channels: 1,
          sequence: 1,
        ),
        isTrue,
      );
      sink
        ..acceptedFrames = 160000
        ..playedFrames = 8000;
      expect(lease.markAudible(), isTrue);
      await pumpEventQueue();
      expect(await lease.refreshPlaybackPosition(), isTrue);
      final earlyReceipt = service.captureCurrentReference()!;
      final earlyEcho = Uint8List.sublistView(playback, 3000 * 2, 4600 * 2);
      final futureEcho = Uint8List.sublistView(
        playback,
        100000 * 2,
        101600 * 2,
      );

      expect(service.filterPlaybackCandidate(earlyEcho, earlyReceipt), isNull);
      expect(
        identical(
          service.filterPlaybackCandidate(futureEcho, earlyReceipt),
          futureEcho,
        ),
        isTrue,
        reason: 'queued future audio must not be treated as already audible',
      );
      expect(earlyReceipt.retainedSamples, lessThanOrEqualTo(48000));

      sink.playedFrames = 101600;
      expect(await lease.refreshPlaybackPosition(), isTrue);
      final futureReceipt = service.captureCurrentReference()!;
      expect(
        service.filterPlaybackCandidate(futureEcho, futureReceipt),
        isNull,
      );
      expect(
        identical(
          service.filterPlaybackCandidate(earlyEcho, futureReceipt),
          earlyEcho,
        ),
        isTrue,
        reason: 'audio far behind the playback head must leave the window',
      );
    },
  );

  test('replacement synchronously rejects old frames and receipts', () async {
    final service = StreamingPcmPlaybackReferenceService();
    addTearDown(service.onClose);
    final oldLease = _bind(service, _ControllableSink(301));
    final echo = _sinePcm(
      sampleRate: 16000,
      samples: 800,
      frequencyHz: 503,
      amplitude: 0.3,
    );
    oldLease.appendAcceptedPcm(
      pcmS16le: echo,
      sampleRate: 16000,
      channels: 1,
      sequence: 1,
    );
    oldLease.markAudible();
    await pumpEventQueue();
    final oldReceipt = service.captureCurrentReference()!;

    final replacement = service.bind(
      turnId: 'turn-2',
      utteranceId: 'utterance-2',
      spokenText: 'replacement',
      agentId: 'agent-a',
      sink: _ControllableSink(302),
    );

    expect(oldLease.isCurrent, isFalse);
    expect(
      oldLease.appendAcceptedPcm(
        pcmS16le: echo,
        sampleRate: 16000,
        channels: 1,
        sequence: 2,
      ),
      isFalse,
    );
    expect(service.isLikelyOnlyPlaybackEcho(echo, oldReceipt), isFalse);
    expect(
      identical(service.filterPlaybackCandidate(echo, oldReceipt), echo),
      isTrue,
      reason: 'stale evidence must leave the candidate object untouched',
    );
    expect(service.captureCurrentReference(), isNull);
    expect(replacement.isCurrent, isTrue);
  });

  test(
    'invalid native playback position disables only acoustic reference',
    () async {
      final service = StreamingPcmPlaybackReferenceService();
      addTearDown(service.onClose);
      final sink = _ControllableSink(351);
      final lease = _bind(service, sink);
      final echo = _sinePcm(
        sampleRate: 16000,
        samples: 800,
        frequencyHz: 503,
        amplitude: 0.3,
      );
      lease.appendAcceptedPcm(
        pcmS16le: echo,
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      );
      sink
        ..acceptedFrames = 801
        ..playedFrames = 1;
      lease.markAudible();
      await pumpEventQueue();

      expect(service.captureCurrentReference(), isNull);
      expect(service.captureCurrentPlayback(), isNotNull);
      expect(await lease.refreshPlaybackPosition(), isFalse);
    },
  );

  test(
    'late playback position cannot invalidate a replacement lease',
    () async {
      final service = StreamingPcmPlaybackReferenceService();
      addTearDown(service.onClose);
      final oldSink = _ControllableSink(361);
      final oldLease = _bind(service, oldSink);
      final echo = _sinePcm(
        sampleRate: 16000,
        samples: 800,
        frequencyHz: 601,
        amplitude: 0.3,
      );
      oldLease.appendAcceptedPcm(
        pcmS16le: echo,
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      );
      final delayedPosition =
          Completer<StreamingAudioPlaybackPositionReceipt>();
      oldSink.positionGate = delayedPosition;
      final refreshing = oldLease.refreshPlaybackPosition();
      await Future<void>.delayed(Duration.zero);

      final replacementSink = _ControllableSink(362);
      final replacement = service.bind(
        turnId: 'turn-replacement',
        utteranceId: 'utterance-replacement',
        spokenText: 'replacement',
        agentId: 'agent-a',
        sink: replacementSink,
      );
      delayedPosition.complete(
        const StreamingAudioPlaybackPositionReceipt(
          generation: 361,
          playedFrames: 400,
          acceptedFrames: 800,
        ),
      );
      expect(await refreshing, isFalse);

      replacement.appendAcceptedPcm(
        pcmS16le: echo,
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      );
      replacement.markAudible();
      await pumpEventQueue();
      expect(service.captureCurrentReference(), isNotNull);
    },
  );

  test('pause receipt cannot control a replaced native generation', () async {
    final service = StreamingPcmPlaybackReferenceService();
    addTearDown(service.onClose);
    final pauseGate = Completer<void>();
    final oldSink = _ControllableSink(401)..pauseGate = pauseGate;
    final oldLease = _bind(service, oldSink);
    oldLease.appendAcceptedPcm(
      pcmS16le: _sinePcm(
        sampleRate: 16000,
        samples: 320,
        frequencyHz: 440,
        amplitude: 0.3,
      ),
      sampleRate: 16000,
      channels: 1,
      sequence: 1,
    );
    oldLease.markAudible();

    final pausing = oldLease.pause();
    await Future<void>.delayed(Duration.zero);
    service.bind(
      turnId: 'turn-new',
      utteranceId: 'utterance-new',
      spokenText: 'new',
      agentId: 'agent-a',
      sink: _ControllableSink(402),
    );
    pauseGate.complete();

    expect(await pausing, isFalse);
    expect(await oldLease.resume(), isFalse);
  });

  test(
    'semantic stop revokes reference before asynchronous cancellation',
    () async {
      final service = StreamingPcmPlaybackReferenceService();
      addTearDown(service.onClose);
      final stopped = Completer<void>();
      final lease = service.bind(
        turnId: 'turn-1',
        utteranceId: 'utterance-1',
        spokenText: 'spoken',
        agentId: 'agent-a',
        sink: _ControllableSink(501),
        onStop: (_) => stopped.future,
      );
      lease.appendAcceptedPcm(
        pcmS16le: _sinePcm(
          sampleRate: 16000,
          samples: 320,
          frequencyHz: 440,
          amplitude: 0.3,
        ),
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      );
      lease.markAudible();

      final stopping = lease.stop('semantic_barge_in');
      expect(service.captureCurrentPlayback(), isNull);
      expect(service.captureCurrentReference(), isNull);
      stopped.complete();
      expect(await stopping, isTrue);
    },
  );

  test('reference storage is bounded by samples and source frames', () async {
    final service = StreamingPcmPlaybackReferenceService(
      maximumReferenceSamples: 1600,
      maximumReferenceFrames: 2,
      maximumSearchSamples: 1600,
    );
    addTearDown(service.onClose);
    final sink = _ControllableSink(601);
    final lease = _bind(service, sink);
    for (var sequence = 1; sequence <= 3; sequence++) {
      lease.appendAcceptedPcm(
        pcmS16le: _sinePcm(
          sampleRate: 16000,
          samples: sequence == 1 ? 2000 : 100,
          frequencyHz: 440,
          amplitude: 0.3,
        ),
        sampleRate: 16000,
        channels: 1,
        sequence: sequence,
      );
    }
    sink
      ..acceptedFrames = 2200
      ..playedFrames = 2200;
    lease.markAudible();
    await pumpEventQueue();
    expect(await lease.refreshPlaybackPosition(), isTrue);

    final receipt = service.captureCurrentReference()!;
    expect(receipt.retainedSamples, lessThanOrEqualTo(1600));
    expect(receipt.droppedFrames, greaterThanOrEqualTo(2));
  });

  test(
    'production wiring prefers current PCM and preserves typed WAV fallback',
    () {
      final main = File('lib/main.dart').readAsStringSync();
      final runtime = File(
        'lib/src/features/agent/application/agent_runtime.dart',
      ).readAsStringSync();

      final referenceRegistration = main.indexOf(
        'StreamingPcmPlaybackReferenceService()',
      );
      final bargeInRegistration = main.indexOf(
        'BargeInController(',
        referenceRegistration,
      );
      expect(referenceRegistration, greaterThanOrEqualTo(0));
      expect(bargeInRegistration, greaterThan(referenceRegistration));
      expect(
        main,
        contains(
          'streamingPcmReference.captureCurrentPlayback(agentId: agentId) ??',
        ),
      );
      expect(main, contains('MaasoTtsPlugin.captureCurrentTypedPlayback'));
      expect(runtime, contains('agentId: agentId'));
      expect(
        runtime,
        contains('maybeFind<StreamingPcmPlaybackReferenceService>()'),
      );
    },
  );
}

StreamingPcmPlaybackLease _bind(
  StreamingPcmPlaybackReferenceService service,
  _ControllableSink sink,
) => service.bind(
  turnId: 'turn-1',
  utteranceId: 'utterance-1',
  spokenText: 'spoken',
  agentId: 'agent-a',
  sink: sink,
);

Uint8List _sinePcm({
  required int sampleRate,
  required int samples,
  required double frequencyHz,
  required double amplitude,
}) {
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  for (var index = 0; index < samples; index++) {
    final value =
        (math.sin(2 * math.pi * frequencyHz * index / sampleRate) *
                amplitude *
                32767)
            .round();
    data.setInt16(index * 2, value, Endian.little);
  }
  return bytes;
}

Uint8List _chirpPcm({
  required int sampleRate,
  required int samples,
  required double startFrequencyHz,
  required double endFrequencyHz,
  required double durationSeconds,
  required double amplitude,
}) {
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  final sweepRate = (endFrequencyHz - startFrequencyHz) / durationSeconds;
  for (var index = 0; index < samples; index++) {
    final time = index / sampleRate;
    final phase =
        2 * math.pi * (startFrequencyHz * time + sweepRate * time * time / 2);
    final value = (math.sin(phase) * amplitude * 32767).round();
    data.setInt16(index * 2, value, Endian.little);
  }
  return bytes;
}

Uint8List _deterministicNoisePcm({
  required int samples,
  required double amplitude,
}) {
  final bytes = Uint8List(samples * 2);
  final data = ByteData.sublistView(bytes);
  var state = 0x5a17c9e3;
  for (var index = 0; index < samples; index++) {
    state = (1664525 * state + 1013904223) & 0xffffffff;
    final normalized = ((state >> 8) & 0xffff) / 32767.5 - 1;
    data.setInt16(
      index * 2,
      (normalized * amplitude * 32767).round(),
      Endian.little,
    );
  }
  return bytes;
}

Uint8List _mixPcm(Uint8List first, Uint8List second) {
  expect(first.length, second.length);
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

final class _ControllableSink implements PositionedStreamingAudioSink {
  _ControllableSink(this.activeGeneration);

  @override
  int? activeGeneration;
  Completer<void>? pauseGate;
  bool paused = false;
  int acceptedFrames = 0;
  int playedFrames = 0;
  Completer<StreamingAudioPlaybackPositionReceipt>? positionGate;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {}

  @override
  Future<void> write(Uint8List pcmS16le) async {}

  @override
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt() {
    final gate = positionGate;
    if (gate != null) return gate.future;
    return Future<StreamingAudioPlaybackPositionReceipt>.value(
      StreamingAudioPlaybackPositionReceipt(
        generation: activeGeneration!,
        playedFrames: playedFrames,
        acceptedFrames: acceptedFrames,
      ),
    );
  }

  @override
  Future<StreamingAudioControlReceipt> pauseWithReceipt() async {
    final generation = activeGeneration!;
    await pauseGate?.future;
    paused = true;
    return StreamingAudioControlReceipt(
      generation: generation,
      state: StreamingAudioControlState.paused,
    );
  }

  @override
  Future<StreamingAudioControlReceipt> resumeWithReceipt() async {
    final generation = activeGeneration!;
    paused = false;
    return StreamingAudioControlReceipt(
      generation: generation,
      state: StreamingAudioControlState.resumed,
    );
  }

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
