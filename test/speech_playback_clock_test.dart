import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/speech_playback_clock_emitter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/self_avatar_projection_service.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

void main() {
  test(
    'native cursor calibration is bounded, monotonic and lifecycle fenced',
    () {
      var now = Duration.zero;
      final output = <SpeechPlaybackClock>[];
      final emitter = SpeechPlaybackClockEmitter(
        playbackId: 'wav-1',
        nativeGeneration: 0,
        turnId: 'turn',
        utteranceId: 'u1',
        source: SpeechPlaybackClockSource.wav,
        agentId: 'self',
        elapsed: () => now,
        emit: output.add,
      );
      emitter.observe(90);
      expect(
        output,
        isEmpty,
        reason: 'synthesis/enqueueing cannot start a clock',
      );
      emitter.start(durationMs: 2000, envelope: [0, 0.8, 0], frameRate: 30);
      expect(output.single.authoritative, false);
      for (var ms = 10; ms <= 1000; ms += 10) {
        now = Duration(milliseconds: ms);
        emitter.observe(ms);
      }
      expect(
        output.where((c) => c.state == SpeechPlaybackClockState.update),
        hasLength(4),
      );
      emitter.pause();
      emitter.observe(1050);
      expect(output.last.state, SpeechPlaybackClockState.pause);
      expect(output.last.positionMs, 1050);
      emitter.resume();
      expect(
        output.last.positionMs,
        1050,
        reason: 'resume never restarts at zero',
      );
      now = const Duration(milliseconds: 1300);
      emitter.observe(1200);
      final count = output.length;
      emitter.observe(10);
      expect(output, hasLength(count));
      emitter.stop();
      final stoppedCount = output.length;
      emitter.resume();
      emitter.observe(1400);
      emitter.stop();
      expect(output, hasLength(stoppedCount));
      expect(output.last.state, SpeechPlaybackClockState.stop);
      expect(output.skip(1).every((c) => c.envelope.isEmpty), isTrue);
      expect(
        output.map((c) => c.sequence),
        orderedEquals(List.generate(output.length, (i) => i + 1)),
      );
    },
  );

  test('session envelope is immutable and only valid on start', () {
    final source = <double>[0.2, 0.8];
    final clock = _clock(envelope: source);
    source[0] = 1;
    expect(clock.envelope.first, 0.2);
    expect(() => clock.envelope.add(0), throwsUnsupportedError);
    expect(
      () => _clock(state: SpeechPlaybackClockState.update, envelope: [0.1]),
      throwsArgumentError,
    );
    expect(() => _clock(envelope: [double.nan]), throwsArgumentError);
    expect(() => _clock(envelope: List.filled(7201, 0)), throwsArgumentError);
    expect(
      () => _clock(source: SpeechPlaybackClockSource.system),
      throwsArgumentError,
    );
    expect(
      _clock(
        source: SpeechPlaybackClockSource.system,
        authoritative: false,
      ).toJson()['authoritative'],
      false,
    );
  });

  test('renderer generations increase across sources and native restarts', () {
    final packets = <SpeechPlaybackClock>[];
    SpeechPlaybackClockEmitter emitter(
      String id,
      int native,
      SpeechPlaybackClockSource source,
    ) => SpeechPlaybackClockEmitter(
      playbackId: id,
      nativeGeneration: native,
      turnId: 't',
      utteranceId: 'u',
      source: source,
      agentId: 'self',
      emit: packets.add,
    );
    final pcm = emitter('pcm', 900, SpeechPlaybackClockSource.pcm)..start();
    final wav = emitter('wav', 0, SpeechPlaybackClockSource.wav)..start();
    expect(pcm.nativeGeneration, 900);
    expect(wav.nativeGeneration, 0);
    expect(packets.last.generation, greaterThan(packets.first.generation));
    expect(packets.last.generation, lessThan(9007199254740992));
    expect(packets.last.playbackId, isNot(packets.first.playbackId));
    expect(packets.last.toJson().containsKey('nativeGeneration'), false);
  });

  test(
    'Dart and native clock protocol share strict numeric and identity bounds',
    () {
      SpeechPlaybackClock packet({
        String id = 'x',
        int generation = 1,
        int sequence = 1,
        int positionMs = 0,
        int? durationMs,
        List<double> envelope = const [],
        int? frameRate,
      }) => SpeechPlaybackClock(
        playbackId: id,
        generation: generation,
        turnId: 't',
        utteranceId: 'u',
        sequence: sequence,
        state: SpeechPlaybackClockState.start,
        positionMs: positionMs,
        durationMs: durationMs,
        source: SpeechPlaybackClockSource.wav,
        authoritative: true,
        envelope: envelope,
        frameRate: frameRate,
      );
      for (final invalid in <SpeechPlaybackClock Function()>[
        () => packet(id: 'a\u0000b'),
        () => packet(id: 'a\u0085b'),
        () => packet(id: 'x' * 161),
        () => packet(generation: SpeechPlaybackClock.maximumExactInteger + 1),
        () => packet(sequence: SpeechPlaybackClock.maximumExactInteger + 1),
        () => packet(positionMs: SpeechPlaybackClock.maximumPositionMs + 1),
        () => packet(durationMs: SpeechPlaybackClock.maximumPositionMs + 1),
        () => packet(frameRate: 30),
        () => packet(envelope: [0.1]),
      ]) {
        expect(invalid, throwsArgumentError);
      }
      expect(
        packet(
          id: 'x' * 160,
          generation: SpeechPlaybackClock.maximumExactInteger,
          sequence: SpeechPlaybackClock.maximumExactInteger,
          positionMs: SpeechPlaybackClock.maximumPositionMs,
          durationMs: SpeechPlaybackClock.maximumPositionMs,
        ).positionMs,
        SpeechPlaybackClock.maximumPositionMs,
      );
    },
  );

  test(
    'large bound envelopes retain clock identity with explicit acoustic fallback',
    () {
      final packets = <SpeechPlaybackClock>[];
      final envelope = List.generate(7200, (i) => (i + 1) / 7201);
      final emitter = SpeechPlaybackClockEmitter(
        playbackId: 'large',
        nativeGeneration: 1,
        turnId: 't',
        utteranceId: 'u',
        source: SpeechPlaybackClockSource.wav,
        agentId: 'self',
        emit: packets.add,
      );
      emitter.start(envelope: envelope, frameRate: 30, durationMs: 240000);
      expect(packets.single.envelope, isEmpty);
      expect(packets.single.frameRate, isNull);
      expect(packets.single.durationMs, 240000);
      expect(
        utf8.encode(jsonEncode(packets.single.toJson())).length,
        lessThan(SpeechPlaybackClockEmitter.maximumStartPacketBytes),
      );
      expect(
        envelope,
        hasLength(7200),
        reason: 'the full TTS track itself must not be shortened',
      );
      emitter.pause();
      emitter.resume();
      emitter.stop();
      expect(
        packets.every(
          (p) =>
              p.playbackId == packets.first.playbackId &&
              p.generation == packets.first.generation,
        ),
        true,
      );
    },
  );

  for (final mode in FeatureRolloutMode.values) {
    test(
      'clock uses existing $mode projection ownership and account fences',
      () async {
        final sink = _ProjectionSink();
        final service = SelfAvatarProjectionService(
          accountGeneration: 3,
          mode: () => mode,
          dispatchSink: sink,
        );
        addTearDown(service.onClose);
        await service.bindRenderer(
          accountGeneration: 3,
          rendererGeneration: 2,
          ready: true,
          sequence: 1,
        );
        sink.dispatches.clear();
        final result = await service.project(
          SelfAvatarSpeechPlaybackClockProjectionInput(
            accountGeneration: 3,
            rendererGeneration: 2,
            sequence: 2,
            clock: _clock(),
          ),
        );
        if (mode == FeatureRolloutMode.enforce) {
          expect(result.disposition, SelfAvatarProjectionDisposition.enforced);
          expect(
            sink.dispatches.single.speechPlaybackClock!.playbackId,
            'wav-1',
          );
          expect(sink.dispatches.single.commandCount, 1);
        } else {
          expect(
            sink.dispatches,
            isEmpty,
            reason: 'shadow/off cannot write the renderer',
          );
        }
        final stale = await service.project(
          SelfAvatarSpeechPlaybackClockProjectionInput(
            accountGeneration: 2,
            rendererGeneration: 2,
            sequence: 3,
            clock: _clock(),
          ),
        );
        expect(
          stale.disposition,
          SelfAvatarProjectionDisposition.rejectedStaleAccount,
        );
      },
    );
  }

  test('playback clocks require the TTS mouth owner', () async {
    final sink = _ArbiterSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    addTearDown(arbiter.onClose);
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );
    final command = AvatarSpeechPlaybackClockCommand(_clock());
    AvatarCommandLeaseRequest request(
      AvatarCommandSource source,
      int generation,
    ) => AvatarCommandLeaseRequest(
      accountGeneration: 1,
      rendererGeneration: 1,
      commandGeneration: generation,
      leaseId: 'clock-$generation',
      source: source,
      command: command,
      ttl: const Duration(seconds: 2),
    );
    final invalid = await arbiter.acquire(
      request(AvatarCommandSource.explicitAgent, 1),
    );
    expect(
      invalid.disposition,
      AvatarCommandReceiptDisposition.rejectedInvalidSource,
    );
    expect(sink.dispatches, isEmpty);
    final valid = await arbiter.acquire(
      request(AvatarCommandSource.ttsMouth, 2),
    );
    expect(valid.disposition, AvatarCommandReceiptDisposition.dispatched);
    expect(
      sink.dispatches.single.command!.toCanonicalJson()['playbackClock'],
      _clock().toJson(),
    );
  });
}

SpeechPlaybackClock _clock({
  SpeechPlaybackClockState state = SpeechPlaybackClockState.start,
  SpeechPlaybackClockSource source = SpeechPlaybackClockSource.wav,
  bool authoritative = true,
  List<double> envelope = const [],
}) => SpeechPlaybackClock(
  playbackId: 'wav-1',
  generation: 0,
  turnId: 't',
  utteranceId: 'u',
  sequence: 1,
  state: state,
  positionMs: 0,
  source: source,
  authoritative: authoritative,
  envelope: envelope,
  frameRate: envelope.isEmpty ? null : 30,
);

final class _ProjectionSink implements SelfAvatarProjectionDispatchSink {
  final dispatches = <SelfAvatarProjectionDispatch>[];
  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch command) async =>
      dispatches.add(command);
}

final class _ArbiterSink implements AvatarCommandDispatchSink {
  final dispatches = <AvatarCommandDispatch>[];
  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    return operation.applyIfCurrent(dispatches.add)!;
  }

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async => operation.resetOrDisposeIfCurrent(() {})!;
}
