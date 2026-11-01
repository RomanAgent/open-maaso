import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _PlayerPlatform player;
  TTSEngine? previousEngine;

  setUpAll(() {
    GlobalAudioplayersPlatformInterface.instance = _GlobalPlatform();
    player = _PlayerPlatform();
    AudioplayersPlatformInterface.instance = player;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => call.method == 'getVoices'
              ? [
                  for (final locale in ['zh-CN', 'en-US'])
                    {
                      'name': 'installed-$locale',
                      'locale': locale,
                      'network_required': '0',
                      'features': '',
                    },
                ]
              : 1,
        );
  });

  setUp(() async {
    previousEngine = TTSEngineRegistry.current;
    TTSEngineRegistry.current = null;
    player.failStops = 0;
    SharedPreferences.setMockInitialValues({});
    await MaasoTtsPlugin.loadSoundPreference();
  });

  tearDown(() async {
    await MaasoTtsPlugin.stopAll(agentId: 'fallback_cancel_test');
    TTSEngineRegistry.current = previousEngine;
  });

  test(
    'sound preference restores and mute stops speech and mouth together',
    () async {
      final system = _SystemTts();
      final plugin = MaasoTtsPlugin(fallbackTts: system);
      addTearDown(plugin.dispose);
      final states = <bool>[];
      final envelopes = <LipSyncEnvelopeEvent>[];
      final stateSub = EventBus().on<SpeakingStatusEvent>().listen(
        (e) => states.add(e.isSpeaking),
      );
      final lipSub = EventBus().on<LipSyncEnvelopeEvent>().listen(
        envelopes.add,
      );
      addTearDown(stateSub.cancel);
      addTearDown(lipSub.cancel);

      await _say(plugin, system);
      expect(states.last, isTrue);
      await MaasoTtsPlugin.setSoundEnabled(false);
      await _tick();
      expect(system.stopCalls, 1);
      expect(states.last, isFalse);
      final envelopeCount = envelopes.length;
      final stateCount = states.length;
      expect(plugin.methods['speak']!(['静音时这句话只显示文字。']), contains('muted'));
      await plugin.speakSystem('开机提示也保持静音。');
      await MaasoTtsPlugin.resume();
      await _tick();
      expect(system.speakCalls, 1);
      expect(envelopes.length, envelopeCount);
      expect(states.length, stateCount);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool(MaasoTtsPlugin.soundPreferenceKey), isFalse);
      await MaasoTtsPlugin.loadSoundPreference();
      expect(MaasoTtsPlugin.soundEnabled.value, isFalse);

      await MaasoTtsPlugin.setSoundEnabled(true);
      await plugin.speakSystem('恢复后新回复可以正常说话。');
      await _tick();
      expect(system.speakCalls, 2);
      expect(states.last, isTrue);
      expect(envelopes.length, greaterThan(envelopeCount));
    },
  );

  test(
    'muting during setup fences late speech even after sound is re-enabled',
    () async {
      final releaseLanguage = Completer<void>();
      final system = _SystemTts(languageGate: releaseLanguage.future);
      final plugin = MaasoTtsPlugin(fallbackTts: system);
      addTearDown(plugin.dispose);
      plugin.methods['speak']!(['This old utterance must never resume.']);
      await system.languageStarted.future;
      await MaasoTtsPlugin.setSoundEnabled(false);
      await MaasoTtsPlugin.setSoundEnabled(true);
      releaseLanguage.complete();
      await _tick();
      await _tick();
      expect(system.speakCalls, 0);
    },
  );

  test('sound enable waits for every registered backend to stop', () async {
    final released = Completer<void>();
    var stopCalls = 0;
    final unregister = MaasoTtsPlugin.registerSoundStopper(() {
      stopCalls++;
      return released.future;
    });
    addTearDown(unregister);
    final disabling = MaasoTtsPlugin.setSoundEnabled(false);
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    expect(stopCalls, 1);
    final enabling = MaasoTtsPlugin.setSoundEnabled(true);
    await _tick();
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
    released.complete();
    await disabling;
    await enabling;
    expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
  });

  test(
    'failed backend stop still persists mute and remains retryable',
    () async {
      var attempts = 0;
      final unregister = MaasoTtsPlugin.registerSoundStopper(() async {
        attempts++;
        if (attempts == 1) throw StateError('backend_stop_failed');
      });
      addTearDown(unregister);
      await expectLater(
        MaasoTtsPlugin.setSoundEnabled(false),
        throwsStateError,
      );
      expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          MaasoTtsPlugin.soundPreferenceKey,
        ),
        isFalse,
      );
      await MaasoTtsPlugin.setSoundEnabled(false);
      expect(attempts, 2);
      await MaasoTtsPlugin.setSoundEnabled(true);
      expect(MaasoTtsPlugin.soundEnabled.value, isTrue);
    },
  );

  test(
    'stopAll stops the speaking fallback rather than an unused facade',
    () async {
      final active = _SystemTts();
      final unused = _SystemTts();
      final plugin = MaasoTtsPlugin(
        agentId: 'fallback_cancel_test',
        fallbackTts: active,
      );
      MaasoTtsPlugin(agentId: 'fallback_cancel_test', fallbackTts: unused);
      await _say(plugin, active);
      await MaasoTtsPlugin.stopAll(agentId: 'fallback_cancel_test');
      expect(active.stopCalls, 1);
      expect(unused.stopCalls, 0);
    },
  );

  test(
    'prepareForNewTurn cancels the actual fallback and advances generation',
    () async {
      final system = _SystemTts();
      final plugin = MaasoTtsPlugin(fallbackTts: system);
      await _say(plugin, system);
      final generation = MaasoTtsPlugin.debugSpeakGeneration;
      await MaasoTtsPlugin.prepareForNewTurn(agentId: 'fallback_cancel_test');
      expect(system.stopCalls, 1);
      expect(MaasoTtsPlugin.debugSpeakGeneration, generation + 1);
    },
  );

  test(
    'slow old stop acknowledgement cannot erase or silence a newer owner',
    () async {
      final released = Completer<void>();
      final oldSystem = _SystemTts(stopGate: released.future);
      final newSystem = _SystemTts();
      final states = <bool>[];
      final subscription = EventBus()
          .on<SpeakingStatusEvent>()
          .where((event) => event.agentId == 'fallback_cancel_test')
          .listen((event) => states.add(event.isSpeaking));
      addTearDown(subscription.cancel);
      await _say(
        MaasoTtsPlugin(agentId: 'fallback_cancel_test', fallbackTts: oldSystem),
        oldSystem,
      );
      final stopping = MaasoTtsPlugin.stopAll(agentId: 'fallback_cancel_test');
      await _tick();
      expect(oldSystem.stopCalls, 1);
      await _say(
        MaasoTtsPlugin(agentId: 'fallback_cancel_test', fallbackTts: newSystem),
        newSystem,
      );
      await _tick();
      expect(states.last, isTrue);
      final beforeOldAck = states.length;
      released.complete();
      await stopping;
      await _tick();
      expect(states.skip(beforeOldAck), isEmpty);
      expect(newSystem.stopCalls, 0);
      await MaasoTtsPlugin.stopAll(agentId: 'fallback_cancel_test');
      expect(newSystem.stopCalls, 1);
      expect(oldSystem.stopCalls, 1);
    },
  );

  test(
    'an old fallback estimate cannot end a newer instance in the same turn',
    () async {
      final oldSystem = _SystemTts();
      final newSystem = _SystemTts();
      final states = <bool>[];
      final subscription = EventBus()
          .on<SpeakingStatusEvent>()
          .where((event) => event.agentId == 'fallback_cancel_test')
          .listen((event) => states.add(event.isSpeaking));
      addTearDown(subscription.cancel);
      await _say(
        MaasoTtsPlugin(agentId: 'fallback_cancel_test', fallbackTts: oldSystem),
        oldSystem,
        text: '嗯。',
      );
      await _say(
        MaasoTtsPlugin(agentId: 'fallback_cancel_test', fallbackTts: newSystem),
        newSystem,
        text: '这是一句明显更长的回复，用来保证旧实例的结束估计不能关闭当前说话状态。',
      );
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(states, [true, true]);
    },
  );

  test(
    'cancel during language setup prevents a late system speak call',
    () async {
      final releaseLanguage = Completer<void>();
      final system = _SystemTts(languageGate: releaseLanguage.future);
      final plugin = MaasoTtsPlugin(fallbackTts: system);
      plugin.methods['speak']!(['正在设置语音时收到新的问题。']);
      await system.languageStarted.future;
      await MaasoTtsPlugin.prepareForNewTurn();
      releaseLanguage.complete();
      await _tick();
      expect(system.stopCalls, 1);
      expect(system.speakCalls, 0);
    },
  );

  test(
    'strict stop retries the same fallback after platform failure',
    () async {
      final system = _SystemTts()..failStops = 1;
      await _say(MaasoTtsPlugin(fallbackTts: system), system);
      await expectLater(MaasoTtsPlugin.stopAllStrict(), throwsStateError);
      expect(system.stopCalls, 1);
      await MaasoTtsPlugin.stopAllStrict();
      expect(system.stopCalls, 2);
    },
  );

  test('a WAV stop failure does not skip the system fallback stop', () async {
    final system = _SystemTts();
    await _say(MaasoTtsPlugin(fallbackTts: system), system);
    player.failStops = 1;
    await expectLater(MaasoTtsPlugin.stopAllStrict(), throwsStateError);
    expect(system.stopCalls, 1);
  });
}

Future<void> _say(
  MaasoTtsPlugin plugin,
  _SystemTts system, {
  String text = '这句话由正在使用的系统语音实例播放。',
}) async {
  plugin.methods['speak']!([text]);
  await system.spoken.future.timeout(const Duration(seconds: 1));
  await _tick();
}

Future<void> _tick() => Future<void>.delayed(Duration.zero);

class _SystemTts extends FlutterTts {
  _SystemTts({this.stopGate, this.languageGate});

  final Future<void>? stopGate;
  final Future<void>? languageGate;
  final spoken = Completer<void>();
  final languageStarted = Completer<void>();
  int stopCalls = 0;
  int speakCalls = 0;
  int failStops = 0;

  @override
  Future<dynamic> setSpeechRate(double rate) async => 1;

  @override
  Future<dynamic> setPitch(double pitch) async => 1;

  @override
  Future<dynamic> setLanguage(String language) async {
    if (!languageStarted.isCompleted) languageStarted.complete();
    await languageGate;
    return 1;
  }

  @override
  Future<dynamic> speak(String text, {bool focus = false}) async {
    speakCalls++;
    if (!spoken.isCompleted) spoken.complete();
    return 1;
  }

  @override
  Future<dynamic> stop() async {
    stopCalls++;
    await stopGate;
    if (failStops > 0) {
      failStops--;
      throw StateError('system_stop_failed');
    }
    return 1;
  }
}

class _GlobalPlatform extends GlobalAudioplayersPlatformInterface {
  final _events = StreamController<GlobalAudioEvent>.broadcast();

  @override
  Future<void> init() async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => _events.stream;
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Future<void> emitGlobalLog(String message) async {}
  @override
  Future<void> setGlobalAudioContext(AudioContext context) async {}
}

class _PlayerPlatform extends AudioplayersPlatformInterface {
  final _events = <String, StreamController<AudioEvent>>{};
  int failStops = 0;

  @override
  Future<int?> getCurrentPosition(String id) async => 0;

  @override
  Future<int?> getDuration(String id) async => 0;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected WAV operation: ${invocation.memberName}',
  );

  @override
  Future<void> create(String id) async {
    _events.putIfAbsent(id, () => StreamController<AudioEvent>.broadcast());
  }

  @override
  Stream<AudioEvent> getEventStream(String id) => _events
      .putIfAbsent(id, () => StreamController<AudioEvent>.broadcast())
      .stream;

  @override
  Future<void> stop(String id) async {
    if (failStops > 0) {
      failStops--;
      throw StateError('wav_stop_failed');
    }
  }
}
