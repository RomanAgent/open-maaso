import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/core/services/streaming_pcm_playback_reference_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

void main() {
  test(
    'PCM requires an advancing native cursor and keeps exact lease identity',
    () async {
      final clocks = <SpeechPlaybackClock>[];
      final subscription = EventBus().on<SpeechPlaybackClockEvent>().listen(
        (event) => clocks.add(event.clock),
      );
      addTearDown(subscription.cancel);
      final service = StreamingPcmPlaybackReferenceService(
        playbackPositionPollInterval: const Duration(days: 1),
      );
      addTearDown(service.onClose);
      final sink = _Sink(99);
      final first = service.bind(
        turnId: 'turn-pcm',
        utteranceId: 'u1',
        spokenText: 'Hello',
        agentId: 'self',
        sink: sink,
      );
      first.appendAcceptedPcm(
        pcmS16le: Uint8List(3200),
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      );
      first.markAudible();
      await pumpEventQueue();
      expect(
        clocks,
        isEmpty,
        reason: 'accepted PCM is not proof that it played',
      );
      sink.playedFrames = 800;
      expect(await first.refreshPlaybackPosition(), true);
      await pumpEventQueue();
      expect(clocks, hasLength(1));
      final start = clocks.single;
      expect(start.state, SpeechPlaybackClockState.start);
      expect(start.positionMs, 50);
      expect(start.authoritative, true);
      expect(start.turnId, 'turn-pcm');
      expect(start.utteranceId, 'u1');
      expect(
        first.generation,
        99,
        reason: 'native generation is never remapped',
      );
      expect(
        start.generation,
        greaterThan(first.generation),
        reason: 'renderer sessions have a distinct monotonic generation',
      );
      expect(
        start.envelope,
        isEmpty,
        reason: 'PCM has no complete WAV envelope',
      );
      expect(await first.pause(), true);
      await pumpEventQueue();
      expect(clocks.last.state, SpeechPlaybackClockState.pause);
      expect(clocks.last.positionMs, 50);
      expect(await first.resume(), true);
      await pumpEventQueue();
      expect(clocks.last.state, SpeechPlaybackClockState.resume);
      final lowerNativeGeneration = _Sink(1)..playedFrames = 320;
      final replacement = service.bind(
        turnId: 'turn-new',
        utteranceId: 'u2',
        spokenText: 'New',
        agentId: 'self',
        sink: lowerNativeGeneration,
      );
      replacement.appendAcceptedPcm(
        pcmS16le: Uint8List(3200),
        sampleRate: 16000,
        channels: 1,
        sequence: 1,
      );
      replacement.markAudible();
      await pumpEventQueue();
      expect(clocks[clocks.length - 2].state, SpeechPlaybackClockState.stop);
      expect(clocks.last.state, SpeechPlaybackClockState.start);
      expect(clocks.last.generation, greaterThan(start.generation));
      expect(clocks.last.playbackId, isNot(start.playbackId));
      expect(await first.refreshPlaybackPosition(), false);
    },
  );
}

final class _Sink implements PositionedStreamingAudioSink {
  _Sink(this.activeGeneration);
  @override
  int? activeGeneration;
  int playedFrames = 0;
  @override
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt() async =>
      StreamingAudioPlaybackPositionReceipt(
        generation: activeGeneration!,
        playedFrames: playedFrames,
        acceptedFrames: 1600,
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
  Future<void> stop({bool drain = true}) async {}
  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({
    bool drain = true,
  }) async => StreamingAudioPlaybackReceipt(
    generation: activeGeneration!,
    terminal: StreamingAudioPlaybackTerminal.cancelled,
  );
}
