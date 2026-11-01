import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';

import '../tool/ios_controllable_streaming_audio_sink_probe.dart';

void main() {
  test(
    'iOS probe verifies drain controls and paused generation takeover',
    () async {
      final sinks = <_ProbeSink>[];
      final receipt = await IosControllableStreamingAudioSinkProbe(
        supported: true,
        sinkFactory: () {
          final sink = _ProbeSink();
          sinks.add(sink);
          return sink;
        },
        delay: (_) async {},
      ).run();

      expect(receipt.status, IosControllableSinkProbeStatus.passed);
      expect(receipt.scenarios, hasLength(2));
      final pauseResume = receipt.scenarios[0];
      expect(
        pauseResume.scenario,
        IosControllableSinkProbeScenario.pauseResumeDrain,
      );
      expect(pauseResume.pauseReceiptMatches, isTrue);
      expect(pauseResume.resumeReceiptMatches, isTrue);
      expect(pauseResume.positionReceiptMatches, isTrue);
      expect(pauseResume.positionFrozenWhilePaused, isTrue);
      expect(pauseResume.positionAdvancedAfterResume, isTrue);
      expect(pauseResume.drainPendingWhilePaused, isTrue);
      expect(
        pauseResume.drainTerminal,
        StreamingAudioPlaybackTerminal.completed,
      );

      final takeover = receipt.scenarios[1];
      expect(
        takeover.scenario,
        IosControllableSinkProbeScenario.pausedTakeover,
      );
      expect(takeover.pauseReceiptMatches, isTrue);
      expect(takeover.drainTerminal, StreamingAudioPlaybackTerminal.cancelled);
      expect(
        takeover.takeoverTerminal,
        StreamingAudioPlaybackTerminal.cancelled,
      );
      expect(
        takeover.replacementTerminal,
        StreamingAudioPlaybackTerminal.completed,
      );
      expect(takeover.generationsDistinct, isTrue);
      expect(sinks[1].controls, ['pause', 'immediateStop']);

      final json = jsonDecode(receipt.encode()) as Map<String, dynamic>;
      expect(json.keys, {
        'schemaVersion',
        'platform',
        'status',
        'audibleConfirmationRequired',
        'audioFormat',
        'scenarios',
        'errorCode',
      });
      expect(json['platform'], 'ios');
      expect(json['audibleConfirmationRequired'], isTrue);
      expect(receipt.encode(), isNot(contains('private')));
    },
  );

  test('iOS probe is explicitly unsupported on another platform', () async {
    final receipt = await IosControllableStreamingAudioSinkProbe(
      supported: false,
      sinkFactory: _ProbeSink.new,
    ).run();

    expect(receipt.status, IosControllableSinkProbeStatus.unsupported);
    expect(receipt.scenarios, isEmpty);
    expect(receipt.errorCode, 'platform_unsupported');
  });

  test('iOS probe PCM fixture is bounded aligned PCM16', () {
    final pcm = buildIosControllableSinkProbePcm(
      duration: const Duration(milliseconds: 600),
      frequencyHz: 523.25,
    );

    expect(pcm.length, 24000 * 600 ~/ 1000 * 2);
    expect(pcm.length.isEven, isTrue);
    expect(pcm.length, lessThan(2 * 1024 * 1024));
    expect(ByteData.sublistView(pcm).getInt16(0, Endian.little), 0);
  });
}

final class _ProbeSink implements PositionedStreamingAudioSink {
  int _nextGeneration = 800;
  int _starts = 0;
  int? _activeGeneration;
  Completer<StreamingAudioPlaybackReceipt>? _drain;
  final controls = <String>[];
  bool _paused = false;
  int _acceptedFrames = 0;
  int _playedFrames = 0;
  bool _completeDrainAfterPosition = false;

  @override
  int? get activeGeneration => _activeGeneration;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    _starts++;
    _activeGeneration = ++_nextGeneration;
    _paused = false;
    _acceptedFrames = 0;
    _playedFrames = 0;
    _completeDrainAfterPosition = false;
  }

  @override
  Future<void> write(Uint8List pcmS16le) async {
    if (_activeGeneration == null) throw StateError('inactive');
    _acceptedFrames += pcmS16le.length ~/ 2;
  }

  @override
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt() async {
    final generation = _activeGeneration;
    if (generation == null) throw StateError('inactive');
    if (!_paused) {
      _playedFrames = (_playedFrames + 120).clamp(0, _acceptedFrames).toInt();
    }
    final receipt = StreamingAudioPlaybackPositionReceipt(
      generation: generation,
      playedFrames: _playedFrames,
      acceptedFrames: _acceptedFrames,
    );
    if (_completeDrainAfterPosition) {
      _completeDrainAfterPosition = false;
      final drain = _drain;
      if (drain != null && !drain.isCompleted) {
        drain.complete(
          StreamingAudioPlaybackReceipt(
            generation: generation,
            terminal: StreamingAudioPlaybackTerminal.completed,
          ),
        );
      }
    }
    return receipt;
  }

  @override
  Future<StreamingAudioControlReceipt> pauseWithReceipt() async {
    final generation = _activeGeneration!;
    controls.add('pause');
    _paused = true;
    return StreamingAudioControlReceipt(
      generation: generation,
      state: StreamingAudioControlState.paused,
    );
  }

  @override
  Future<StreamingAudioControlReceipt> resumeWithReceipt() async {
    final generation = _activeGeneration!;
    if (!_paused) throw StateError('not paused');
    controls.add('resume');
    _paused = false;
    final drain = _drain;
    if (drain != null && !drain.isCompleted) {
      _completeDrainAfterPosition = true;
    }
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
    final generation = _activeGeneration ?? 0;
    if (!drain) {
      controls.add('immediateStop');
      final pending = _drain;
      if (pending != null && !pending.isCompleted) {
        pending.complete(
          StreamingAudioPlaybackReceipt(
            generation: generation,
            terminal: StreamingAudioPlaybackTerminal.cancelled,
          ),
        );
      }
      _activeGeneration = null;
      _paused = false;
      return StreamingAudioPlaybackReceipt(
        generation: generation,
        terminal: StreamingAudioPlaybackTerminal.cancelled,
      );
    }
    final pending = _drain = Completer<StreamingAudioPlaybackReceipt>();
    if (_starts > 1) {
      pending.complete(
        StreamingAudioPlaybackReceipt(
          generation: generation,
          terminal: StreamingAudioPlaybackTerminal.completed,
        ),
      );
    }
    final receipt = await pending.future;
    if (_activeGeneration == generation) _activeGeneration = null;
    return receipt;
  }
}
