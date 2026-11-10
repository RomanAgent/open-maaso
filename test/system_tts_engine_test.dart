import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/system_tts_engine.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test/system_tts_engine');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test(
    'installed phone speech produces bounded PCM without a model/backend key',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'isAvailable' ? true : _wave();
      });
      final engine = SystemTtsEngine(channel: channel);
      expect(await engine.warmUp(), isTrue);
      expect(await engine.synthesizeToWav('本地系统语音', language: 'zh'), _wave());
      expect(calls.map((c) => c.method), ['isAvailable', 'synthesize']);
      final args = Map<String, Object?>.from(calls.last.arguments as Map);
      expect(args['language'], 'zh');
      expect(args['text'], '本地系统语音');
      expect(args.keys, unorderedEquals(['id', 'text', 'language']));
    },
  );

  test(
    'request-scoped cancellation stops synthesis and rejects late audio',
    () async {
      final audio = Completer<Uint8List>();
      String? owner;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isAvailable') return true;
        final id = (call.arguments as Map)['id'] as String;
        if (call.method == 'synthesize') {
          owner = id;
          return audio.future;
        }
        expect(id, owner);
        return true;
      });
      final engine = SystemTtsEngine(channel: channel);
      final result = engine.synthesizeToWav('An older reply');
      final rejected = expectLater(result, throwsStateError);
      await pumpEventQueue();
      expect(owner, isNotNull);
      await expectLater(
        engine.synthesizeToWav('Parallel reply'),
        throwsStateError,
      );
      await engine.cancelSynthesis();
      audio.complete(_wave());
      await rejected;
    },
  );

  test(
    'cancelling during availability cannot start a stale native request',
    () async {
      final ready = Completer<bool>();
      var synthesis = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'isAvailable') return ready.future;
        if (call.method == 'cancel') return false;
        synthesis++;
        return _wave();
      });
      final engine = SystemTtsEngine(channel: channel);
      final result = engine.synthesizeToWav('Stale');
      final rejected = expectLater(result, throwsStateError);
      await pumpEventQueue();
      await engine.cancelSynthesis();
      ready.complete(true);
      await rejected;
      expect(synthesis, 0);
    },
  );

  test(
    'invalid, silent-container and non-PCM output cannot masquerade as speech',
    () async {
      for (final value in [
        Uint8List(44),
        _wave(empty: true),
        _wave(format: 3),
      ]) {
        messenger.setMockMethodCallHandler(
          channel,
          (call) async => call.method == 'isAvailable' ? true : value,
        );
        await expectLater(
          SystemTtsEngine(channel: channel).synthesizeToWav('Test'),
          throwsStateError,
        );
      }
    },
  );

  test(
    'missing installed service fails without synthesis or a cloud fallback',
    () async {
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        return false;
      });
      await expectLater(
        SystemTtsEngine(channel: channel).synthesizeToWav('Test'),
        throwsStateError,
      );
      expect(calls, ['isAvailable']);
    },
  );
}

Uint8List _wave({bool empty = false, int format = 1}) {
  final bytes = Uint8List(44 + (empty ? 0 : 320));
  final data = ByteData.sublistView(bytes);
  void word(int offset, String text) =>
      bytes.setRange(offset, offset + text.length, text.codeUnits);
  word(0, 'RIFF');
  data.setUint32(4, bytes.length - 8, Endian.little);
  word(8, 'WAVE');
  word(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, format, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  word(36, 'data');
  data.setUint32(40, bytes.length - 44, Endian.little);
  for (var i = 44; i < bytes.length; i += 2)
    data.setInt16(i, 1000, Endian.little);
  return bytes;
}
