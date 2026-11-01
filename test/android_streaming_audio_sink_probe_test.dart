import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';

import '../tool/android_streaming_audio_sink_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'exercises drain, in-flight cancel, and generation replacement in order',
    () async {
      const channel = MethodChannel('test/android_streaming_audio_sink_probe');
      final host = _FakeStreamingAudioHost();
      final delays = <Duration>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, host.handle);
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null);
      });

      final receipt = await AndroidStreamingAudioSinkProbe(
        supported: true,
        sinkFactory: () => MethodChannelStreamingAudioSink(channel: channel),
        delay: (duration) async {
          delays.add(duration);
        },
      ).run();

      expect(receipt.status, AndroidStreamingAudioSinkProbeStatus.passed);
      expect(
        receipt.scenarios.map((scenario) => scenario.scenario),
        <AndroidStreamingAudioSinkProbeScenario>[
          AndroidStreamingAudioSinkProbeScenario.drain,
          AndroidStreamingAudioSinkProbeScenario.immediateCancel,
          AndroidStreamingAudioSinkProbeScenario.replacement,
        ],
      );

      final drain = receipt.scenarios[0];
      expect(drain.terminal, StreamingAudioPlaybackTerminal.completed);
      expect(drain.replacementTerminal, isNull);
      expect(
        drain.writeOutcome,
        AndroidStreamingAudioSinkProbeWriteOutcome.accepted,
      );
      expect(drain.receiptMatches, isTrue);
      expect(drain.pcmBytes, 28800);

      final cancel = receipt.scenarios[1];
      expect(cancel.terminal, StreamingAudioPlaybackTerminal.cancelled);
      expect(cancel.replacementTerminal, isNull);
      expect(
        cancel.writeOutcome,
        AndroidStreamingAudioSinkProbeWriteOutcome.cancelled,
      );
      expect(cancel.receiptMatches, isTrue);
      expect(cancel.pcmBytes, 96000);

      final replacement = receipt.scenarios[2];
      expect(replacement.terminal, StreamingAudioPlaybackTerminal.cancelled);
      expect(
        replacement.replacementTerminal,
        StreamingAudioPlaybackTerminal.completed,
      );
      expect(
        replacement.writeOutcome,
        AndroidStreamingAudioSinkProbeWriteOutcome.cancelled,
      );
      expect(
        replacement.replacementWriteOutcome,
        AndroidStreamingAudioSinkProbeWriteOutcome.accepted,
      );
      expect(replacement.receiptMatches, isTrue);
      expect(replacement.generationsDistinct, isTrue);
      expect(replacement.staleStopIsolated, isTrue);
      expect(replacement.pcmBytes, 124800);

      for (final scenario in receipt.scenarios) {
        expect(scenario.elapsedMilliseconds, inInclusiveRange(0, 60000));
      }
      expect(delays, [
        const Duration(milliseconds: 150),
        const Duration(milliseconds: 150),
      ]);
      expect(host.events, [
        'start',
        'write:short',
        'stop:drain',
        'start',
        'write:long',
        'stop:cancel',
        'start',
        'write:long',
        'stop:drain',
        'start',
        'write:short',
        'stop:drain',
      ]);
      expect(host.startedGenerations, hasLength(4));
      expect(host.startedGenerations.toSet(), hasLength(4));
      expect(host.pcmPayloads, hasLength(4));
      expect(
        host.pcmPayloads[0],
        buildAndroidStreamingAudioSinkProbePcm(
          duration: const Duration(milliseconds: 600),
          frequencyHz: androidStreamingAudioSinkProbeDrainFrequencyHz,
        ),
      );
      expect(
        host.pcmPayloads[1],
        buildAndroidStreamingAudioSinkProbePcm(
          duration: const Duration(seconds: 2),
          frequencyHz: androidStreamingAudioSinkProbeCancelFrequencyHz,
        ),
      );
      expect(
        host.pcmPayloads[2],
        buildAndroidStreamingAudioSinkProbePcm(
          duration: const Duration(seconds: 2),
          frequencyHz: androidStreamingAudioSinkProbeReplacementAFrequencyHz,
        ),
      );
      expect(
        host.pcmPayloads[3],
        buildAndroidStreamingAudioSinkProbePcm(
          duration: const Duration(milliseconds: 600),
          frequencyHz: androidStreamingAudioSinkProbeReplacementBFrequencyHz,
        ),
      );
    },
  );

  test('receipt has a fixed shape and redacts host failure details', () async {
    const channel = MethodChannel(
      'test/android_streaming_audio_sink_probe_redaction',
    );
    const privateMarker = 'private-device-generation-exception-body';
    final host = _FakeStreamingAudioHost(failFirstWriteWith: privateMarker);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, host.handle);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final receipt = await AndroidStreamingAudioSinkProbe(
      supported: true,
      sinkFactory: () => MethodChannelStreamingAudioSink(channel: channel),
      delay: (_) async {},
    ).run();
    final json = receipt.toJson();
    final encoded = receipt.encode();

    expect(receipt.status, AndroidStreamingAudioSinkProbeStatus.failed);
    expect(json.keys, [
      'schemaVersion',
      'status',
      'audioFormat',
      'scenarios',
      'errorCode',
    ]);
    expect((json['audioFormat']! as Map<String, Object?>).keys, [
      'sampleRateHz',
      'channels',
      'sampleFormat',
    ]);
    for (final scenario in json['scenarios']! as List<Object?>) {
      expect((scenario! as Map<String, Object?>).keys, [
        'scenario',
        'status',
        'terminal',
        'replacementTerminal',
        'writeOutcome',
        'replacementWriteOutcome',
        'receiptMatches',
        'generationsDistinct',
        'staleStopIsolated',
        'pcmBytes',
        'elapsedMs',
        'errorCode',
      ]);
    }
    expect(receipt.scenarios.first.errorCode, 'write_not_accepted');
    expect(encoded, isNot(contains(privateMarker)));
    expect(encoded, isNot(contains('PlatformException')));
    expect(encoded, isNot(contains('"generation":')));
    expect(encoded.toLowerCase(), isNot(contains('deviceid')));
    expect(encoded, isNot(contains('"pcm":')));
    expect(jsonDecode(encoded), json);
  });

  test(
    'chunked log lines are bounded, fixed-shape, and losslessly ordered',
    () {
      final original = jsonEncode(<String, Object?>{
        'status': 'passed',
        'privateReceiptMarker': '不应明文出现在日志 envelope',
        'scenarios': List<String>.generate(
          180,
          (index) => 'scenario-$index-with-fixed-diagnostic-fields',
        ),
      });
      final lines = buildAndroidStreamingAudioSinkProbeLogLines(original);

      expect(lines.length, greaterThan(1));
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        expect(line.length, lessThan(750));
        expect(line, startsWith(androidStreamingAudioSinkProbeLogPrefix));
        expect(line, isNot(contains('不应明文')));
        final envelope =
            jsonDecode(
                  line.substring(
                    androidStreamingAudioSinkProbeLogPrefix.length,
                  ),
                )!
                as Map<String, dynamic>;
        expect(envelope.keys, ['schemaVersion', 'part', 'parts', 'payload']);
        expect(envelope['schemaVersion'], 1);
        expect(envelope['part'], index + 1);
        expect(envelope['parts'], lines.length);
        final payload = envelope['payload']! as String;
        expect(payload.length, lessThanOrEqualTo(600));
        expect(payload.codeUnits.every((unit) => unit <= 0x7f), isTrue);
      }
      expect(reassembleAndroidStreamingAudioSinkProbeLogLines(lines), original);
    },
  );

  test('chunk reassembly rejects out-of-order records', () {
    final lines = buildAndroidStreamingAudioSinkProbeLogLines(
      'x' * 1200,
      payloadCharacters: 200,
    );

    expect(
      () => reassembleAndroidStreamingAudioSinkProbeLogLines(lines.reversed),
      throwsFormatException,
    );
  });

  test('chunk protocol requires strict positive integer metadata', () {
    const validPayload = 'AXg=';
    for (final envelope in <Map<String, Object?>>[
      <String, Object?>{
        'schemaVersion': 1.0,
        'part': 1,
        'parts': 1,
        'payload': validPayload,
      },
      <String, Object?>{
        'schemaVersion': 1,
        'part': 1.0,
        'parts': 1,
        'payload': validPayload,
      },
      <String, Object?>{
        'schemaVersion': 1,
        'part': 1,
        'parts': 1.0,
        'payload': validPayload,
      },
      <String, Object?>{
        'schemaVersion': true,
        'part': 1,
        'parts': 1,
        'payload': validPayload,
      },
      <String, Object?>{
        'schemaVersion': 1,
        'part': 0,
        'parts': 1,
        'payload': validPayload,
      },
      <String, Object?>{
        'schemaVersion': 1,
        'part': 1,
        'parts': 0,
        'payload': validPayload,
      },
    ]) {
      expect(
        () => reassembleAndroidStreamingAudioSinkProbeLogLines([
          _probeLogLine(envelope),
        ]),
        throwsFormatException,
      );
    }
  });

  test(
    'chunk protocol rejects invalid payloads and missing or duplicate parts',
    () {
      for (final payload in <String>['', 'A' * 604, 'AQ你=', '!!!!']) {
        expect(
          () => reassembleAndroidStreamingAudioSinkProbeLogLines([
            _probeLogLine(<String, Object?>{
              'schemaVersion': 1,
              'part': 1,
              'parts': 1,
              'payload': payload,
            }),
          ]),
          throwsFormatException,
        );
      }

      final lines = buildAndroidStreamingAudioSinkProbeLogLines(
        'x' * 1200,
        payloadCharacters: 200,
      );
      expect(lines.length, greaterThan(2));
      expect(
        () => reassembleAndroidStreamingAudioSinkProbeLogLines([
          lines.first,
          ...lines.skip(2),
        ]),
        throwsFormatException,
      );
      expect(
        () => reassembleAndroidStreamingAudioSinkProbeLogLines([
          lines.first,
          lines.first,
          ...lines.skip(1),
        ]),
        throwsFormatException,
      );
    },
  );

  test('an empty receipt still uses a non-empty framed payload', () {
    final lines = buildAndroidStreamingAudioSinkProbeLogLines('');
    final envelope =
        jsonDecode(
              lines.single.substring(
                androidStreamingAudioSinkProbeLogPrefix.length,
              ),
            )!
            as Map<String, dynamic>;

    expect(envelope['payload'], isNotEmpty);
    expect(reassembleAndroidStreamingAudioSinkProbeLogLines(lines), '');
  });

  test('an active failed scenario is cancelled from finally', () async {
    const channel = MethodChannel(
      'test/android_streaming_audio_sink_probe_cleanup',
    );
    final host = _FakeStreamingAudioHost(failFirstWriteWith: 'secret');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, host.handle);
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    final receipt = await AndroidStreamingAudioSinkProbe(
      supported: true,
      sinkFactory: () => MethodChannelStreamingAudioSink(channel: channel),
      delay: (_) async {},
    ).run();

    expect(receipt.status, AndroidStreamingAudioSinkProbeStatus.failed);
    expect(host.events.take(3), ['start', 'write:short', 'stop:cancel']);
    expect(receipt.scenarios.first.terminal, isNull);
    expect(receipt.scenarios.first.errorCode, 'write_not_accepted');
  });

  test(
    'immediate cancel rejects failed, stale, and prematurely accepted writes',
    () async {
      for (final behavior in [
        _FakeLongWriteBehavior.failed,
        _FakeLongWriteBehavior.stale,
        _FakeLongWriteBehavior.accepted,
      ]) {
        final result = await _runWithLongWriteBehaviors(
          'immediate_${behavior.name}',
          <_FakeLongWriteBehavior>[
            behavior,
            _FakeLongWriteBehavior.pendingUntilRetired,
          ],
        );

        final cancel = result.receipt.scenarios[1];
        expect(
          cancel.status,
          AndroidStreamingAudioSinkProbeScenarioStatus.failed,
        );
        expect(cancel.terminal, StreamingAudioPlaybackTerminal.cancelled);
        expect(cancel.receiptMatches, isTrue);
        expect(
          cancel.writeOutcome,
          behavior == _FakeLongWriteBehavior.accepted
              ? AndroidStreamingAudioSinkProbeWriteOutcome.accepted
              : AndroidStreamingAudioSinkProbeWriteOutcome.failed,
        );
        expect(cancel.errorCode, 'write_not_cancelled');
      }
    },
  );

  test(
    'replacement rejects failed, stale, and prematurely accepted A writes',
    () async {
      for (final behavior in [
        _FakeLongWriteBehavior.failed,
        _FakeLongWriteBehavior.stale,
        _FakeLongWriteBehavior.accepted,
      ]) {
        final result = await _runWithLongWriteBehaviors(
          'replacement_${behavior.name}',
          <_FakeLongWriteBehavior>[
            _FakeLongWriteBehavior.pendingUntilRetired,
            behavior,
          ],
        );

        final replacement = result.receipt.scenarios[2];
        expect(
          replacement.status,
          AndroidStreamingAudioSinkProbeScenarioStatus.failed,
        );
        expect(replacement.terminal, StreamingAudioPlaybackTerminal.cancelled);
        expect(
          replacement.replacementTerminal,
          StreamingAudioPlaybackTerminal.completed,
        );
        expect(replacement.receiptMatches, isTrue);
        expect(replacement.generationsDistinct, isTrue);
        expect(replacement.staleStopIsolated, isTrue);
        expect(
          replacement.writeOutcome,
          behavior == _FakeLongWriteBehavior.accepted
              ? AndroidStreamingAudioSinkProbeWriteOutcome.accepted
              : AndroidStreamingAudioSinkProbeWriteOutcome.failed,
        );
        expect(replacement.errorCode, 'replaced_write_not_cancelled');
      }
    },
  );

  test('non-Android result is unsupported without creating a sink', () async {
    var factoryCalls = 0;
    final receipt = await AndroidStreamingAudioSinkProbe(
      supported: false,
      sinkFactory: () {
        factoryCalls++;
        throw StateError('must not run');
      },
    ).run();

    expect(factoryCalls, 0);
    expect(receipt.status, AndroidStreamingAudioSinkProbeStatus.unsupported);
    expect(receipt.scenarios, isEmpty);
    expect(receipt.errorCode, 'platform_unsupported');
  });

  test('fixture is deterministic s16le at amplitude 0.12 with 10 ms fades', () {
    final first = buildAndroidStreamingAudioSinkProbePcm(
      duration: const Duration(milliseconds: 100),
      frequencyHz: 600,
    );
    final second = buildAndroidStreamingAudioSinkProbePcm(
      duration: const Duration(milliseconds: 100),
      frequencyHz: 600,
    );
    final bytes = ByteData.sublistView(first);
    int sampleAt(int index) => bytes.getInt16(index * 2, Endian.little);

    expect(first, second);
    expect(first, hasLength(2400 * 2));
    expect(sampleAt(0), 0);
    expect(sampleAt(2399), 0);
    expect(sampleAt(250), 3932);
    expect(first[500], 0x5c);
    expect(first[501], 0x0f);
    expect(sampleAt(10).abs(), lessThan(3932 ~/ 20));
    expect(sampleAt(2390).abs(), lessThan(3932 ~/ 20));
    expect(
      List<int>.generate(2400, sampleAt).any((sample) => sample != 0),
      isTrue,
    );
  });
}

Future<
  ({
    AndroidStreamingAudioSinkProbeReceipt receipt,
    _FakeStreamingAudioHost host,
  })
>
_runWithLongWriteBehaviors(
  String channelSuffix,
  List<_FakeLongWriteBehavior> behaviors,
) async {
  final channel = MethodChannel(
    'test/android_streaming_audio_sink_probe_adversarial_$channelSuffix',
  );
  final host = _FakeStreamingAudioHost(longWriteBehaviors: behaviors);
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(channel, host.handle);
  try {
    final receipt = await AndroidStreamingAudioSinkProbe(
      supported: true,
      sinkFactory: () => MethodChannelStreamingAudioSink(channel: channel),
      delay: (_) async {},
    ).run();
    return (receipt: receipt, host: host);
  } finally {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  }
}

enum _FakeLongWriteBehavior { pendingUntilRetired, accepted, failed, stale }

String _probeLogLine(Map<String, Object?> envelope) =>
    '$androidStreamingAudioSinkProbeLogPrefix${jsonEncode(envelope)}';

class _FakeStreamingAudioHost {
  _FakeStreamingAudioHost({
    this.failFirstWriteWith,
    this.longWriteBehaviors = const <_FakeLongWriteBehavior>[],
  });

  final String? failFirstWriteWith;
  final List<_FakeLongWriteBehavior> longWriteBehaviors;
  final List<String> events = <String>[];
  final List<int> startedGenerations = <int>[];
  final List<Uint8List> pcmPayloads = <Uint8List>[];
  int? _activeGeneration;
  int? _pendingWriteGeneration;
  Completer<Object?>? _pendingWrite;
  int? _pendingDrainGeneration;
  Completer<Object?>? _pendingDrain;
  bool _firstWriteSeen = false;
  int _longWriteIndex = 0;
  int? _unplayedGeneration;

  Future<Object?> handle(MethodCall call) async {
    final arguments = call.arguments! as Map<Object?, Object?>;
    final generation = arguments['generation']! as int;
    switch (call.method) {
      case 'start':
        events.add('start');
        _retireActive();
        _activeGeneration = generation;
        startedGenerations.add(generation);
        return _receipt(generation, 'started');
      case 'write':
        final pcm = Uint8List.fromList(arguments['pcm']! as Uint8List);
        events.add(pcm.length > 50000 ? 'write:long' : 'write:short');
        pcmPayloads.add(pcm);
        if (_activeGeneration != generation) {
          throw PlatformException(code: 'stale_audio_generation');
        }
        if (!_firstWriteSeen) {
          _firstWriteSeen = true;
          final detail = failFirstWriteWith;
          if (detail != null) {
            throw PlatformException(code: 'private_failure', message: detail);
          }
        }
        if (pcm.length > 50000) {
          _unplayedGeneration = generation;
          final behavior = _longWriteIndex < longWriteBehaviors.length
              ? longWriteBehaviors[_longWriteIndex]
              : _FakeLongWriteBehavior.pendingUntilRetired;
          _longWriteIndex++;
          switch (behavior) {
            case _FakeLongWriteBehavior.pendingUntilRetired:
              final pending = Completer<Object?>();
              _pendingWriteGeneration = generation;
              _pendingWrite = pending;
              return pending.future;
            case _FakeLongWriteBehavior.accepted:
              return _receipt(generation, 'accepted');
            case _FakeLongWriteBehavior.failed:
              throw PlatformException(
                code: 'audio_write_failed',
                message: 'private adversarial failure',
              );
            case _FakeLongWriteBehavior.stale:
              throw PlatformException(
                code: 'stale_audio_generation',
                message: 'private stale generation detail',
              );
          }
        }
        return _receipt(generation, 'accepted');
      case 'stop':
        final drain = arguments['drain']! as bool;
        events.add(drain ? 'stop:drain' : 'stop:cancel');
        if (_activeGeneration != generation) {
          return _receipt(generation, 'cancelled');
        }
        if (!drain) {
          _retireActive();
          return _receipt(generation, 'cancelled');
        }
        if (_pendingWriteGeneration == generation ||
            _unplayedGeneration == generation) {
          final pending = Completer<Object?>();
          _pendingDrainGeneration = generation;
          _pendingDrain = pending;
          return pending.future;
        }
        _activeGeneration = null;
        return _receipt(generation, 'completed');
    }
    throw MissingPluginException();
  }

  void _retireActive() {
    final write = _pendingWrite;
    final drain = _pendingDrain;
    final drainGeneration = _pendingDrainGeneration;
    _pendingWrite = null;
    _pendingWriteGeneration = null;
    _pendingDrain = null;
    _pendingDrainGeneration = null;
    _unplayedGeneration = null;
    _activeGeneration = null;
    if (write != null && !write.isCompleted) {
      write.completeError(PlatformException(code: 'audio_write_cancelled'));
    }
    if (drain != null && !drain.isCompleted && drainGeneration != null) {
      drain.complete(_receipt(drainGeneration, 'cancelled'));
    }
  }

  static Map<String, Object?> _receipt(int generation, String terminal) =>
      <String, Object?>{'generation': generation, 'terminal': terminal};
}
