import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maaso/src/offline/offline_speech.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('flutter_tts');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;
  late Object voices;
  late Future<Object?> Function(MethodCall)? override;
  setUp(() {
    calls = [];
    voices = <Object>[];
    override = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (override != null) return override!(call);
      if (call.method == 'getVoices') return voices;
      return 1;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, String> androidVoice({
    String network = '0',
    String features = '',
  }) => {
    'name': 'local-voice',
    'locale': 'zh-CN',
    'network_required': network,
    'features': features,
  };

  test(
    'construction is lazy and Android rejects network/unknown/uninstalled voices',
    () async {
      final speech = OfflineSpeechService(
        platform: TargetPlatform.android,
        isWeb: false,
      );
      expect(calls, isEmpty);
      voices = [
        androidVoice(network: '1'),
        {'name': 'unknown', 'locale': 'zh-CN'},
        androidVoice(features: 'notInstalled'),
      ];
      expect(await speech.speak('你好', language: 'zh-CN'), isFalse);
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
      expect(speech.unavailableReason, isNotNull);
      await speech.dispose();
    },
  );

  test(
    'Android explicitly selects installed embedded voice without completion blocking',
    () async {
      voices = [androidVoice(network: '1'), androidVoice()];
      final speech = OfflineSpeechService(
        platform: TargetPlatform.android,
        isWeb: false,
      );
      expect(await speech.speak('你好', language: 'zh-CN'), isTrue);
      expect(calls.firstWhere((c) => c.method == 'setVoice').arguments, {
        'name': 'local-voice',
        'locale': 'zh-CN',
      });
      expect(
        calls.firstWhere((c) => c.method == 'awaitSpeakCompletion').arguments,
        isFalse,
      );
      expect(speech.available, isTrue);
      await speech.dispose();
    },
  );

  test(
    'Apple uses a concrete listed voice identifier and fails if none exists',
    () async {
      voices = [
        {
          'name': 'Chinese',
          'locale': 'zh-CN',
          'identifier': 'com.apple.voice.compact.zh-CN',
          'quality': 'default',
        },
      ];
      final speech = OfflineSpeechService(
        platform: TargetPlatform.iOS,
        isWeb: false,
      );
      expect(await speech.initialize(language: 'zh-CN'), isTrue);
      expect(
        calls.firstWhere((c) => c.method == 'setVoice').arguments['identifier'],
        'com.apple.voice.compact.zh-CN',
      );
      await speech.dispose();
      calls.clear();
      voices = [
        {'name': 'Chinese', 'locale': 'zh-CN'},
      ];
      final missing = OfflineSpeechService(
        platform: TargetPlatform.iOS,
        isWeb: false,
      );
      expect(await missing.speak('hello', language: 'zh-CN'), isFalse);
      expect(calls.where((c) => c.method == 'speak'), isEmpty);
      await missing.dispose();
    },
  );

  test(
    'new turn cancels stale speech while voice preparation is in flight',
    () async {
      final reachedVoices = Completer<void>();
      final releaseVoices = Completer<void>();
      override = (call) async {
        if (call.method == 'getVoices') {
          if (!reachedVoices.isCompleted) reachedVoices.complete();
          await releaseVoices.future;
          return [androidVoice()];
        }
        return 1;
      };
      final speech = OfflineSpeechService(
        platform: TargetPlatform.android,
        isWeb: false,
      );
      final old = speech.speak('old reply', language: 'zh-CN');
      await reachedVoices.future;
      final stop = speech.stop();
      final next = speech.speak('new reply', language: 'zh-CN');
      releaseVoices.complete();
      expect(await old, isFalse);
      await stop;
      expect(await next, isTrue);
      final spoken = calls.where((c) => c.method == 'speak').toList();
      expect(spoken, hasLength(1));
      final payload = spoken.single.arguments;
      expect(payload is Map ? payload['text'] : payload, 'new reply');
      await speech.dispose();
    },
  );

  test(
    'script and region variants use installed same-language voices',
    () async {
      voices = [androidVoice(network: '1'), androidVoice()];
      final android = OfflineSpeechService(
        platform: TargetPlatform.android,
        isWeb: false,
      );
      expect(await android.initialize(language: 'zh-Hans-CN'), isTrue);
      await android.dispose();
      calls.clear();
      voices = [
        {
          'name': 'English',
          'locale': 'en-US',
          'identifier': 'com.apple.voice.compact.en-US',
        },
      ];
      final apple = OfflineSpeechService(
        platform: TargetPlatform.iOS,
        isWeb: false,
      );
      expect(await apple.initialize(language: 'en-CN'), isTrue);
      expect(
        calls.firstWhere((c) => c.method == 'setVoice').arguments['locale'],
        'en-US',
      );
      await apple.dispose();
    },
  );

  test(
    'native speech events own avatar callbacks and stale words are ignored',
    () async {
      voices = [androidVoice()];
      final tts = FlutterTts();
      final events = <String>[];
      final speech = OfflineSpeechService(
        tts: tts,
        platform: TargetPlatform.android,
        isWeb: false,
        onStart: () => events.add('start'),
        onEnd: () => events.add('end'),
        onProgress: () => events.add('word'),
      );
      await speech.speak('first reply', language: 'zh-CN');
      expect(
        events,
        isEmpty,
        reason: 'enqueueing is not proof of audio playback',
      );
      await tts.platformCallHandler(const MethodCall('speak.onStart'));
      await tts.platformCallHandler(
        const MethodCall('speak.onProgress', {
          'text': 'first reply',
          'start': 0,
          'end': 5,
          'word': 'first',
        }),
      );
      expect(events, ['start', 'word']);
      await speech.stop();
      expect(events.last, 'end');
      await tts.platformCallHandler(const MethodCall('speak.onStart'));
      await speech.speak('second reply', language: 'zh-CN');
      await tts.platformCallHandler(
        const MethodCall('speak.onProgress', {
          'text': 'first reply',
          'start': 0,
          'end': 5,
          'word': 'first',
        }),
      );
      expect(events, ['start', 'word', 'end']);
      await tts.platformCallHandler(const MethodCall('speak.onStart'));
      await tts.platformCallHandler(const MethodCall('speak.onComplete'));
      expect(events, ['start', 'word', 'end', 'start', 'end']);
      await speech.dispose();
    },
  );

  test(
    'web/unavailable platforms cannot silently select an online fallback',
    () async {
      final speech = OfflineSpeechService(
        platform: TargetPlatform.android,
        isWeb: true,
      );
      expect(await speech.initialize(language: 'zh-CN'), isFalse);
      expect(calls, isEmpty);
      expect(await speech.speak('text', language: 'zh-CN'), isFalse);
      expect(
        calls.where((c) => c.method == 'getVoices' || c.method == 'speak'),
        isEmpty,
      );
      await speech.dispose();
      expect(await speech.speak('after dispose'), isFalse);
    },
  );
}
