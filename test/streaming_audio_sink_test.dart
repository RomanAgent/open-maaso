import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'method channel sink carries one generation and awaits native drain',
    () async {
      const channel = MethodChannel('test/streaming_audio_sink');
      final calls = <MethodCall>[];
      final releaseDrain = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            switch (call.method) {
              case 'start':
                return {'generation': generation, 'terminal': 'started'};
              case 'write':
                return {'generation': generation, 'terminal': 'accepted'};
              case 'stop':
                if (arguments['drain'] == true) await releaseDrain.future;
                return {
                  'generation': generation,
                  'terminal': arguments['drain'] == true
                      ? 'completed'
                      : 'cancelled',
                };
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);
      await sink.write(Uint8List.fromList([1, 2, 3, 4]));
      var stopped = false;
      final stopping = sink.stopWithReceipt().then((receipt) {
        stopped = true;
        return receipt;
      });
      await Future<void>.delayed(Duration.zero);
      expect(stopped, isFalse);
      releaseDrain.complete();
      final receipt = await stopping;

      expect(calls.map((c) => c.method), ['start', 'write', 'stop']);
      final start = calls[0].arguments! as Map<Object?, Object?>;
      final write = calls[1].arguments! as Map<Object?, Object?>;
      final stop = calls[2].arguments! as Map<Object?, Object?>;
      expect(start['sampleRate'], 24000);
      expect(start['channels'], 1);
      expect(start['voiceProcessingCaptureActive'], isFalse);
      expect(start['generation'], isA<int>());
      expect(write['generation'], start['generation']);
      expect(write['pcm'], Uint8List.fromList([1, 2, 3, 4]));
      expect(stop, {'generation': start['generation'], 'drain': true});
      expect(receipt.generation, start['generation']);
      expect(receipt.terminal, StreamingAudioPlaybackTerminal.completed);
    },
  );

  test(
    'each playback samples current voice processing capture instead of retaining a past session',
    () async {
      const channel = MethodChannel('test/voice_processing_audio_sink');
      final starts = <Map<Object?, Object?>>[];
      var captureActive = false;
      var captureReads = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            if (call.method == 'start') {
              starts.add(arguments);
              return {'generation': generation, 'terminal': 'started'};
            }
            if (call.method == 'stop') {
              return {'generation': generation, 'terminal': 'completed'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(
        channel: channel,
        voiceProcessingCaptureActive: () {
          captureReads++;
          return captureActive;
        },
      );
      expect(captureReads, 0);

      for (final active in [false, true, false]) {
        captureActive = active;
        await sink.start(sampleRate: 24000, channels: 1);
        expect(starts.last['voiceProcessingCaptureActive'], active);
        expect(captureReads, starts.length);
        await sink.stopWithReceipt();
      }

      expect(
        starts.map((arguments) => arguments['voiceProcessingCaptureActive']),
        [false, true, false],
      );
      expect(captureReads, 3);
    },
  );

  test(
    'method channel sink rejects a receipt from another generation',
    () async {
      const channel = MethodChannel('test/stale_streaming_audio_sink');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            return {
              'generation': call.method == 'stop' ? generation + 1 : generation,
              'terminal': switch (call.method) {
                'start' => 'started',
                'write' => 'accepted',
                _ => 'completed',
              },
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);

      await expectLater(sink.stopWithReceipt(), throwsStateError);
    },
  );

  test(
    'method channel sink closes writes at the drain tail and still permits cancel',
    () async {
      const channel = MethodChannel('test/stopping_streaming_audio_sink');
      final drainStarted = Completer<void>();
      final drainResult = Completer<Object?>();
      var writeCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            switch (call.method) {
              case 'start':
                return {'generation': generation, 'terminal': 'started'};
              case 'write':
                writeCalls++;
                return {'generation': generation, 'terminal': 'accepted'};
              case 'stop':
                if (arguments['drain'] == true) {
                  drainStarted.complete();
                  return drainResult.future;
                }
                if (!drainResult.isCompleted) {
                  drainResult.complete({
                    'generation': generation,
                    'terminal': 'cancelled',
                  });
                }
                return {'generation': generation, 'terminal': 'cancelled'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);
      final draining = sink.stopWithReceipt();
      await drainStarted.future;

      await expectLater(
        sink.write(Uint8List.fromList([1, 2])),
        throwsStateError,
      );
      expect(writeCalls, 0);

      final cancelling = sink.stopWithReceipt(drain: false);
      expect(
        (await draining).terminal,
        StreamingAudioPlaybackTerminal.cancelled,
      );
      expect(
        (await cancelling).terminal,
        StreamingAudioPlaybackTerminal.cancelled,
      );
      expect(sink.activeGeneration, isNull);
    },
  );

  test(
    'pending drain remains generation-bound pausable until playback completes',
    () async {
      const channel = MethodChannel('test/pausable_draining_audio_sink');
      final drainStarted = Completer<void>();
      final releaseDrain = Completer<void>();
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            switch (call.method) {
              case 'start':
                return {'generation': generation, 'terminal': 'started'};
              case 'stop':
                drainStarted.complete();
                await releaseDrain.future;
                return {'generation': generation, 'terminal': 'completed'};
              case 'pause':
                return {'generation': generation, 'terminal': 'paused'};
              case 'resume':
                return {'generation': generation, 'terminal': 'resumed'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);
      final generation = sink.activeGeneration;
      final draining = sink.stopWithReceipt(drain: true);
      await drainStarted.future;

      final paused = await sink.pauseWithReceipt();
      final resumed = await sink.resumeWithReceipt();
      expect(paused.generation, generation);
      expect(paused.state, StreamingAudioControlState.paused);
      expect(resumed.generation, generation);
      expect(resumed.state, StreamingAudioControlState.resumed);
      expect(sink.activeGeneration, generation);

      releaseDrain.complete();
      final terminal = await draining;
      expect(terminal.generation, generation);
      expect(terminal.terminal, StreamingAudioPlaybackTerminal.completed);
      expect(sink.activeGeneration, isNull);
      expect(calls.map((call) => call.method), [
        'start',
        'stop',
        'pause',
        'resume',
      ]);
    },
  );

  test(
    'late old drain receipt cannot clear a replacement generation',
    () async {
      const channel = MethodChannel('test/replaced_draining_audio_sink');
      final oldDrain = Completer<Object?>();
      int? firstGeneration;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            switch (call.method) {
              case 'start':
                firstGeneration ??= generation;
                return {'generation': generation, 'terminal': 'started'};
              case 'write':
                return {'generation': generation, 'terminal': 'accepted'};
              case 'stop':
                if (arguments['drain'] == true &&
                    generation == firstGeneration) {
                  return oldDrain.future;
                }
                return {'generation': generation, 'terminal': 'cancelled'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);
      final retiredGeneration = sink.activeGeneration!;
      final draining = sink.stopWithReceipt(drain: true);
      await Future<void>.delayed(Duration.zero);
      await sink.start(sampleRate: 24000, channels: 1);
      final replacementGeneration = sink.activeGeneration!;
      expect(replacementGeneration, isNot(retiredGeneration));

      oldDrain.complete({
        'generation': retiredGeneration,
        'terminal': 'cancelled',
      });
      expect(
        (await draining).terminal,
        StreamingAudioPlaybackTerminal.cancelled,
      );
      expect(sink.activeGeneration, replacementGeneration);
      await sink.write(Uint8List.fromList([1, 0]));
      expect(
        (await sink.stopWithReceipt(drain: false)).generation,
        replacementGeneration,
      );
    },
  );

  test(
    'stale native pause receipt is rejected without changing generation',
    () async {
      const channel = MethodChannel('test/stale_pause_audio_sink');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            return switch (call.method) {
              'start' => {'generation': generation, 'terminal': 'started'},
              'pause' => {'generation': generation + 1, 'terminal': 'paused'},
              'stop' => {'generation': generation, 'terminal': 'cancelled'},
              _ => null,
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);
      final generation = sink.activeGeneration;

      await expectLater(sink.pauseWithReceipt(), throwsStateError);
      expect(sink.activeGeneration, generation);
      await sink.stopWithReceipt(drain: false);
    },
  );

  test(
    'method channel sink returns a validated native playback position',
    () async {
      const channel = MethodChannel('test/positioned_streaming_audio_sink');
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            return switch (call.method) {
              'start' => {'generation': generation, 'terminal': 'started'},
              'write' => {'generation': generation, 'terminal': 'accepted'},
              'position' => {
                'generation': generation,
                'playedFrames': 384,
                'acceptedFrames': 960,
              },
              'stop' => {'generation': generation, 'terminal': 'cancelled'},
              _ => null,
            };
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      expect(sink, isA<PositionedStreamingAudioSink>());
      await sink.start(sampleRate: 24000, channels: 1);
      await sink.write(Uint8List.fromList([1, 0, 2, 0]));

      final position = await sink.positionWithReceipt();

      expect(position.generation, sink.activeGeneration);
      expect(position.playedFrames, 384);
      expect(position.acceptedFrames, 960);
      expect(calls.map((call) => call.method), ['start', 'write', 'position']);
      expect(calls.last.arguments, {'generation': sink.activeGeneration});
      await sink.stopWithReceipt(drain: false);
    },
  );

  final invalidPositions = <Object?>[
    null,
    'not-a-receipt',
    const <String, Object?>{
      'generation': -1,
      'playedFrames': 0,
      'acceptedFrames': 0,
    },
    const <String, Object?>{'playedFrames': -1, 'acceptedFrames': 8},
    const <String, Object?>{'playedFrames': 0, 'acceptedFrames': -1},
    const <String, Object?>{'playedFrames': 9, 'acceptedFrames': 8},
    const <String, Object?>{'playedFrames': 0.5, 'acceptedFrames': 8},
    const <String, Object?>{'playedFrames': 0, 'acceptedFrames': double.nan},
  ];
  for (var index = 0; index < invalidPositions.length; index++) {
    test(
      'method channel sink rejects invalid position receipt $index',
      () async {
        final channel = MethodChannel('test/invalid_audio_position_$index');
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, (call) async {
              final arguments = call.arguments! as Map<Object?, Object?>;
              final generation = arguments['generation']! as int;
              return switch (call.method) {
                'start' => {'generation': generation, 'terminal': 'started'},
                'position' => switch (invalidPositions[index]) {
                  final Map<Object?, Object?> values => {
                    'generation': generation,
                    ...values,
                  },
                  final value => value,
                },
                'stop' => {'generation': generation, 'terminal': 'cancelled'},
                _ => null,
              };
            });
        addTearDown(() {
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(channel, null);
        });

        final sink = MethodChannelStreamingAudioSink(channel: channel);
        await sink.start(sampleRate: 24000, channels: 1);

        await expectLater(sink.positionWithReceipt(), throwsStateError);
        expect(sink.activeGeneration, isNotNull);
        await sink.stopWithReceipt(drain: false);
      },
    );
  }

  test(
    'late playback position cannot cross into a replacement generation',
    () async {
      const channel = MethodChannel('test/stale_audio_position');
      final oldPositionStarted = Completer<void>();
      final oldPosition = Completer<Object?>();
      int? firstGeneration;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            final arguments = call.arguments! as Map<Object?, Object?>;
            final generation = arguments['generation']! as int;
            switch (call.method) {
              case 'start':
                firstGeneration ??= generation;
                return {'generation': generation, 'terminal': 'started'};
              case 'position':
                if (generation == firstGeneration) {
                  oldPositionStarted.complete();
                  return oldPosition.future;
                }
                return {
                  'generation': generation,
                  'playedFrames': 0,
                  'acceptedFrames': 0,
                };
              case 'stop':
                return {'generation': generation, 'terminal': 'cancelled'};
            }
            return null;
          });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final sink = MethodChannelStreamingAudioSink(channel: channel);
      await sink.start(sampleRate: 24000, channels: 1);
      final retiredGeneration = sink.activeGeneration!;
      final stalePosition = sink.positionWithReceipt();
      await oldPositionStarted.future;
      await sink.start(sampleRate: 24000, channels: 1);
      final replacementGeneration = sink.activeGeneration!;
      oldPosition.complete({
        'generation': retiredGeneration,
        'playedFrames': 12,
        'acceptedFrames': 24,
      });

      await expectLater(stalePosition, throwsStateError);
      expect(replacementGeneration, isNot(retiredGeneration));
      expect(sink.activeGeneration, replacementGeneration);
      expect(
        (await sink.positionWithReceipt()).generation,
        replacementGeneration,
      );
      await sink.stopWithReceipt(drain: false);
    },
  );

  test('position query requires an active uncancelled generation', () async {
    const channel = MethodChannel('test/inactive_audio_position');
    var callCount = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          callCount++;
          return null;
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final sink = MethodChannelStreamingAudioSink(channel: channel);
    await expectLater(sink.positionWithReceipt(), throwsStateError);
    expect(callCount, 0);
  });

  test('native sinks drain queued streaming audio on normal stop', () {
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final android = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();

    expect(ios, contains('completionCallbackType: .dataPlayedBack'));
    expect(ios, contains('completionType == .dataPlayedBack'));
    expect(ios, contains('engine.isRunning'));
    expect(ios, contains('player.isPlaying'));
    expect(ios, contains('AVAudioSession.interruptionNotification'));
    expect(ios, contains('handleAudioSessionInterruption'));
    expect(ios, contains('AVAudioEngineConfigurationChange'));
    expect(ios, contains('handleEngineConfigurationChange'));
    expect(ios, contains('activeGeneration == generation'));
    expect(ios, contains('pendingAudioByteCount'));
    expect(ios, contains('maximumPendingAudioBytes'));
    expect(ios, contains('maximumSessionSeconds'));
    expect(ios, contains('audio_backpressure'));
    expect(ios, contains('audio_session_limit'));
    expect(ios, contains('guard !drainRequested'));
    expect(ios, contains('pendingDrainResult'));
    expect(ios, contains('let playerWasPaused = isPaused'));
    expect(ios, contains('if player.isPlaying || playerWasPaused'));
    expect(ios, contains('player.stop()'));
    expect(ios, contains('if !isPaused && !player.isPlaying'));
    expect(ios, contains('pendingDrainTimeout?.cancel()'));
    expect(android, contains('playbackHeadPosition'));
    expect(android, contains('streamingAudioGeneration != generation'));
    expect(android, contains('streamingAudioDrainResult'));
    expect(android, isNot(contains('streamingAudioDrainDelayMs()')));
  });

  test('iOS engine configuration changes only cancel the active sink', () {
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final sink = ios.substring(
      ios.indexOf('final class StreamingAudioSinkPlugin'),
      ios.indexOf('final class NativeAsrPlugin'),
    );
    final handler = sink.substring(
      sink.indexOf('private func handleEngineConfigurationChange()'),
      sink.indexOf('private func receipt('),
    );

    expect(sink, contains('forName: .AVAudioEngineConfigurationChange'));
    expect(sink, contains('object: engine'));
    expect(sink, contains('queue: nil'));
    expect(sink, contains('setEngineConfigurationInvalidated(true)'));
    expect(sink, contains('DispatchQueue.main.async'));
    expect(sink, contains('!self.isEngineConfigurationInvalidated()'));
    expect(
      handler,
      contains('stopImmediately(resetEngine: true, terminal: "cancelled")'),
    );
    expect(handler, isNot(contains('engine.start')));
  });

  test(
    'Android PCM uses a bounded preemptible worker instead of blocking UI',
    () {
      final android = File(
        'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
      ).readAsStringSync();

      expect(android, contains('HandlerThread('));
      expect(android, contains('Process.THREAD_PRIORITY_AUDIO'));
      expect(
        android,
        isNot(
          contains(
            'private val streamingAudioHandler = '
            'Handler(Looper.getMainLooper())',
          ),
        ),
      );
      expect(android, contains('AudioTrack.WRITE_NON_BLOCKING'));
      expect(android, contains('STREAMING_AUDIO_MAX_PENDING_BYTES'));
      expect(android, contains('STREAMING_AUDIO_WRITE_STALL_TIMEOUT_MS'));
      expect(android, contains('streamingAudioPendingWrites'));
      expect(android, contains('AtomicBoolean(false)'));
      expect(android, contains('streamingAudioMainHandler'));
      expect(android, contains('STREAMING_AUDIO_PLAYBACK_HEAD_MODULUS'));
      expect(android, contains('streamingAudioPlaybackHeadWrapFrames'));
      expect(android, contains('STREAMING_AUDIO_MAX_SESSION_SECONDS'));
      expect(android, contains('streamingAudioThread.quitSafely()'));
      final enqueueStart = android.indexOf(
        'private fun enqueueStreamingAudioWrite(',
      );
      final enqueueEnd = android.indexOf(
        'private fun scheduleStreamingAudioWritePump(',
        enqueueStart,
      );
      final enqueue = android.substring(enqueueStart, enqueueEnd);
      expect(
        enqueue,
        contains('streamingAudioAcceptedFrames = projectedFrames'),
      );
      expect(
        enqueue.indexOf(
          'result.success(streamingAudioReceipt(generation, "accepted"))',
        ),
        lessThan(enqueue.indexOf('scheduleStreamingAudioWritePump(')),
        reason: 'large frames must ACK bounded queue admission before pumping',
      );
      expect(android, isNot(contains('pending.result.success(')));
    },
  );

  test(
    'iOS streaming audio keeps microphone capture available for playback',
    () {
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();

      expect(ios, contains('session.setCategory('));
      expect(ios, contains('.playAndRecord'));
      expect(ios, contains('.defaultToSpeaker'));
    },
  );

  test('native drain remains generation-bound controllable while paused', () {
    final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
    final android = File(
      'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
    ).readAsStringSync();

    expect(ios, contains('guard activeGeneration == generation else'));
    expect(ios, contains('private func pause('));
    expect(ios, contains('private func resume('));
    expect(ios, contains('player.pause()'));
    expect(ios, contains('if drainRequested'));
    expect(ios, contains('let playerWasPaused = isPaused'));
    expect(ios, contains('if player.isPlaying || playerWasPaused'));

    expect(android, contains('private fun pauseStreamingAudio('));
    expect(android, contains('private fun resumeStreamingAudio('));
    expect(android, contains('streamingAudioGeneration != generation'));
    expect(android, contains('track.pause()'));
    expect(android, contains('streamingAudioPendingWrites.forEach'));
    expect(android, contains('streamingAudioDrainGeneration == generation'));
    expect(android, contains('if (streamingAudioPaused) return'));
  });

  test(
    'native position receipts expose bounded generation-local frame counts',
    () {
      final ios = File('ios/Runner/AppDelegate.swift').readAsStringSync();
      final android = File(
        'android/app/src/main/kotlin/com/futurpals/maaso/MainActivity.kt',
      ).readAsStringSync();

      expect(ios, contains('case "position":'));
      expect(ios, contains('private func position('));
      expect(ios, contains('guard activeGeneration == generation else'));
      expect(ios, contains('player.lastRenderTime'));
      expect(ios, contains('player.playerTime(forNodeTime: renderTime)'));
      expect(ios, contains('completedAudioFrameCount'));
      expect(ios, contains('lastReportedPlayedFrameCount'));
      expect(ios, contains('pausedPlayedFrameCount'));
      expect(ios, contains('playedFrames: observedPlayedAudioFrameCount()'));
      expect(ios, contains('acceptedFrames: scheduledAudioFrameCount'));
      expect(ios, contains('"playedFrames": playedFrames'));
      expect(ios, contains('"acceptedFrames": acceptedFrames'));

      expect(android, contains('"position" ->'));
      expect(android, contains('private fun positionStreamingAudio('));
      expect(android, contains('streamingAudioGeneration != generation'));
      expect(
        android,
        contains('streamingAudioPlayedFrames(track, generation)'),
      );
      expect(
        android,
        contains('streamingAudioAcceptedFrames.coerceAtLeast(0L)'),
      );
      expect(android, contains('.coerceIn(0L, acceptedFrames)'));
      expect(android, contains('"playedFrames" to playedFrames'));
      expect(android, contains('"acceptedFrames" to acceptedFrames'));
    },
  );
}
