import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride, TargetPlatform;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/sherpa_tts_engine.dart';
import 'package:maaso/src/features/agent/application/speech/speech_playback_lease.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/context/agent_config.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Player player;
  final plugins = <MaasoTtsPlugin>[];
  final turns = <SpeechTurnHandle>[];
  final systemCalls = <String>[];
  TTSEngine? previousEngine;

  MaasoTtsTurn open(
    _Engine? engine,
    String id, {
    String text = 'First. Second.',
    Duration startTimeout = const Duration(seconds: 30),
    bool Function()? canSpeak,
  }) {
    TTSEngineRegistry.current = engine;
    final plugin = MaasoTtsPlugin(agentId: 'utterance_test');
    plugins.add(plugin);
    final turn = plugin.openTurn(
      turnId: id,
      text: text,
      startTimeout: startTimeout,
      canSpeak: canSpeak,
    );
    turns.add(turn);
    return turn;
  }

  setUpAll(() {
    GlobalAudioplayersPlatformInterface.instance = _Global();
    player = _Player();
    AudioplayersPlatformInterface.instance = player;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
          call,
        ) async {
          systemCalls.add(call.method);
          return 1;
        });
  });
  setUp(() async {
    previousEngine = TTSEngineRegistry.current;
    player.reset();
    systemCalls.clear();
    SharedPreferences.setMockInitialValues({});
    await MaasoTtsPlugin.loadSoundPreference();
  });
  tearDown(() async {
    await MaasoTtsPlugin.stopAll();
    for (final plugin in plugins) {
      await plugin.dispose();
    }
    for (final turn in turns) {
      await turn.drained;
    }
    plugins.clear();
    turns.clear();
    TTSEngineRegistry.current = previousEngine;
    AgentConfig().clearApiKey('TTS_VOICE_STYLE');
  });

  test(
    'WAV clock starts after native playback and preserves pause cursor',
    () async {
      final clocks = <SpeechPlaybackClock>[];
      final subscription = EventBus()
          .on<SpeechPlaybackClockEvent>()
          .where((event) => event.agentId == 'utterance_test')
          .listen((event) => clocks.add(event.clock));
      addTearDown(subscription.cancel);
      final setup = Completer<void>();
      player.sourceGate = setup.future;
      final turn = open(_Engine(), 'clock-turn');
      final utterance = turn.speak(utteranceId: 'clock-turn:0', text: 'First.');
      await _until(() => player.sourceCalls > 0);
      await pumpEventQueue();
      expect(clocks, isEmpty, reason: 'prepared audio is not audible playback');
      setup.complete();
      expect(await utterance.started, isTrue);
      await _until(() => clocks.isNotEmpty);
      final start = clocks.single;
      expect(start.state, SpeechPlaybackClockState.start);
      expect(start.turnId, 'clock-turn');
      expect(start.utteranceId, 'clock-turn:0');
      expect(start.envelope, isNotEmpty);
      expect(
        start.authoritative,
        false,
        reason: 'start acknowledgement is not a position receipt',
      );
      player.currentPosition = 55;
      await _until(() => clocks.any((clock) => clock.authoritative));
      expect(clocks.last.positionMs, 55);
      final lease = MaasoTtsPlugin.captureCurrentTypedPlayback()!;
      player.currentPosition = 75;
      expect(await lease.pause(), true);
      await _until(
        () =>
            clocks.last.state == SpeechPlaybackClockState.pause &&
            clocks.last.positionMs == 75,
      );
      expect(await lease.resume(), true);
      await _until(() => clocks.last.state == SpeechPlaybackClockState.resume);
      expect(clocks.last.positionMs, 75);
      expect(clocks.last.playbackId, start.playbackId);
      expect(clocks.last.generation, start.generation);
      player.complete();
      expect(await utterance.terminal, SpeechTerminal.completed);
      await turn.drained;
      await _until(() => clocks.last.state == SpeechPlaybackClockState.stop);
      expect(clocks.skip(1).every((clock) => clock.envelope.isEmpty), true);
    },
  );

  test(
    'cancelling speech revokes clock before a delayed native stop',
    () async {
      final clocks = <SpeechPlaybackClock>[];
      final subscription = EventBus()
          .on<SpeechPlaybackClockEvent>()
          .where((event) => event.agentId == 'utterance_test')
          .listen((event) => clocks.add(event.clock));
      addTearDown(subscription.cancel);
      final turn = open(_Engine(), 'clock-stop');
      final speech = turn.speak(utteranceId: 'clock-stop:0', text: 'Stop.');
      expect(await speech.started, true);
      await _until(() => clocks.isNotEmpty);
      final nativeStop = Completer<void>();
      player.stopGate = nativeStop.future;
      var stopped = false;
      final stopping = MaasoTtsPlugin.stopAll().then((_) => stopped = true);
      await _until(() => clocks.last.state == SpeechPlaybackClockState.stop);
      expect(
        stopped,
        false,
        reason: 'presentation revocation cannot await the platform',
      );
      nativeStop.complete();
      await stopping;
      expect(await speech.terminal, SpeechTerminal.cancelled);
      await turn.drained;
      await pumpEventQueue();
      expect(clocks.last.state, SpeechPlaybackClockState.stop);
      expect(
        clocks.where((clock) => clock.state == SpeechPlaybackClockState.start),
        hasLength(1),
      );
    },
  );

  test(
    'mute cancels playing and queued units and never replays them on enable',
    () async {
      final engine = _Engine();
      final turn = open(engine, 'mute');
      final first = turn.speak(utteranceId: 'mute:0', text: 'First.');
      final queued = turn.speak(utteranceId: 'mute:1', text: 'Queued.');
      expect(await first.started, isTrue);
      final lease = MaasoTtsPlugin.captureCurrentTypedPlayback();
      await MaasoTtsPlugin.setSoundEnabled(false);
      expect(await first.terminal, SpeechTerminal.cancelled);
      expect(await queued.started, isFalse);
      expect(await queued.terminal, SpeechTerminal.cancelled);
      expect(await lease!.resume(), isFalse);
      await turn.drained;

      final mutedTurn = open(engine, 'muted');
      final muted = mutedTurn.speak(utteranceId: 'muted:0', text: 'Silent.');
      expect(await muted.started, isFalse);
      expect(await muted.terminal, SpeechTerminal.cancelled);
      expect(engine.requests, hasLength(1));
      await MaasoTtsPlugin.setSoundEnabled(true);
      expect(await lease.resume(), isFalse);
      final next = open(
        engine,
        'enabled',
      ).speak(utteranceId: 'enabled:0', text: 'New reply.');
      expect(await next.started, isTrue);
      expect(engine.requests, hasLength(2));
      player.complete();
      expect(await next.terminal, SpeechTerminal.completed);
    },
  );

  test(
    'each unit waits for native completion and shares one serial queue',
    () async {
      final engine = _Engine();
      final turn = open(engine, 'serial');
      final one = turn.speak(utteranceId: 'serial:0', text: 'First.');
      final two = turn.speak(utteranceId: 'serial:1', text: 'Second.');
      expect(one.turnId, 'serial');
      expect(one.utteranceId, 'serial:0');
      expect(await one.started, isTrue);
      var ended = false;
      one.terminal.then((_) => ended = true);
      await _tick();
      expect(ended, isFalse);
      expect(engine.requests, hasLength(1));
      expect(player.resumes, 1);
      player.complete();
      expect(await one.terminal, SpeechTerminal.completed);
      expect(await two.started, isTrue);
      expect(engine.requests.map((request) => request.text), [
        'First.',
        'Second.',
      ]);
      expect(player.maximumLivePlayers, 1);
      player.complete();
      expect(await two.terminal, SpeechTerminal.completed);
      await turn.drained;
    },
  );

  test(
    'scoped game speech plays while ordinary speech stays globally muted',
    () async {
      MaasoTtsPlugin.soundEnabled.value = false;
      final engine = _Engine();
      final turn = open(engine, 'game', canSpeak: () => true);
      expect(MaasoTtsPlugin.permitsPlaybackEvents('utterance_test'), isTrue);
      expect(MaasoTtsPlugin.permitsPlaybackEvents('another_agent'), isFalse);
      final ordinary = open(
        engine,
        'ordinary',
      ).speak(utteranceId: 'ordinary:0', text: 'Silent');
      expect(await ordinary.terminal, SpeechTerminal.cancelled);
      final speech = turn.speak(utteranceId: 'game:0', text: 'Game reply.');
      expect(await speech.started, isTrue);
      final resumes = player.resumes;
      await MaasoTtsPlugin.pause(agentId: 'utterance_test');
      await MaasoTtsPlugin.resume(agentId: 'another_agent');
      expect(player.resumes, resumes);
      await MaasoTtsPlugin.resume(agentId: 'utterance_test');
      expect(player.resumes, resumes + 1);
      expect(engine.requests.single.text, 'Game reply.');
      player.complete();
      expect(await speech.terminal, SpeechTerminal.completed);
      await turn.drained;
      await turn.cancel();
      expect(MaasoTtsPlugin.permitsPlaybackEvents('utterance_test'), isFalse);
      expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
      expect(
        (await SharedPreferences.getInstance()).getBool(
          MaasoTtsPlugin.soundPreferenceKey,
        ),
        isNull,
      );
    },
  );

  test(
    'scoped permission revoked during synthesis fences audio and avatar events',
    () async {
      MaasoTtsPlugin.soundEnabled.value = false;
      var permitted = true;
      final synthesis = Completer<Uint8List>();
      final engine = _Engine(synthesis: synthesis.future);
      final turn = open(engine, 'revoked-game', canSpeak: () => permitted);
      final speech = turn.speak(
        utteranceId: 'revoked-game:0',
        text: 'Late reply.',
      );
      await _until(() => engine.requests.isNotEmpty);
      permitted = false;
      expect(MaasoTtsPlugin.permitsPlaybackEvents('utterance_test'), isFalse);
      synthesis.complete(_wav());
      expect(await speech.started, isFalse);
      expect(await speech.terminal, SpeechTerminal.cancelled);
      expect(player.resumes, 0);
    },
  );

  for (final boundary in ['cancel', 'new turn', 'dispose']) {
    test('scoped event permission ends at $boundary', () async {
      MaasoTtsPlugin.soundEnabled.value = false;
      final turn = open(_Engine(), 'scope-$boundary', canSpeak: () => true);
      expect(MaasoTtsPlugin.permitsPlaybackEvents('utterance_test'), isTrue);
      if (boundary == 'cancel') {
        await turn.cancel();
      } else if (boundary == 'new turn') {
        await MaasoTtsPlugin.prepareForNewTurn();
      } else {
        await plugins.last.dispose();
      }
      expect(MaasoTtsPlugin.permitsPlaybackEvents('utterance_test'), isFalse);
      final late = turn.speak(utteranceId: 'late', text: 'Must stay silent.');
      expect(await late.terminal, SpeechTerminal.cancelled);
      expect(player.resumes, 0);
    });
  }

  test('throwing scoped speech permission fails closed', () async {
    final turn = open(
      _Engine(),
      'bad-scope',
      canSpeak: () => throw StateError('retired'),
    );
    final speech = turn.speak(utteranceId: 'bad-scope:0', text: 'Silent.');
    expect(await speech.terminal, SpeechTerminal.cancelled);
    expect(player.resumes, 0);
  });

  test(
    'legacy speech synthesizes and plays a complete paragraph once',
    () async {
      final text = List.filled(
        8,
        'This sentence remains inside the same published reply.',
      ).join(' ');
      final engine = _Engine();
      open(engine, 'legacy-facade');
      plugins.last.methods['speak']!([text]);
      await _until(() => player.resumes > 0);
      expect(engine.requests.single.text, text);
      expect(player.resumes, 1);
      player.complete();
      await _tick();
      expect(engine.requests, hasLength(1));
      expect(player.resumes, 1);
    },
  );

  test(
    'one long published unit is synthesized once without punctuation splitting',
    () async {
      final text = List.filled(
        6,
        'A sentence that belongs to the same published unit.',
      ).join(' ');
      final engine = _Engine();
      final turn = open(engine, 'long', text: text);
      final speech = turn.speak(utteranceId: 'long:0', text: text);
      expect(await speech.started, isTrue);
      expect(engine.requests.single.text, text);
      player.complete();
      expect(await speech.terminal, SpeechTerminal.completed);
    },
  );

  for (final platform in <TargetPlatform>[
    TargetPlatform.macOS,
    TargetPlatform.iOS,
    TargetPlatform.linux,
  ]) {
    test(
      'BytesSource creates an absent cache directory on $platform',
      () async {
        final root = await Directory.systemTemp.createTemp('maaso-tts-cache-');
        final cache = Directory('${root.path}/missing/app-cache');
        final previousProvider = PathProviderPlatform.instance;
        final previousPlatform = debugDefaultTargetPlatformOverride;
        PathProviderPlatform.instance = _TemporaryPathProvider(cache.path);
        debugDefaultTargetPlatformOverride = platform;
        addTearDown(() async {
          PathProviderPlatform.instance = previousProvider;
          debugDefaultTargetPlatformOverride = previousPlatform;
          await root.delete(recursive: true);
        });
        expect(await cache.exists(), isFalse);

        final turn = open(_Engine(), 'cache_${platform.name}');
        final speech = turn.speak(utteranceId: 'cache:0', text: 'First.');
        expect(await speech.started, isTrue);
        expect(await cache.exists(), isTrue);
        expect(player.fileSources.single, startsWith('${cache.path}/'));
        expect(player.fileBytes.single, _wav());
        player.complete();
        expect(await speech.terminal, SpeechTerminal.completed);
        await speech.drained;
      },
    );
  }

  test(
    'cancel during cache lookup never writes or plays the old unit',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'maaso-tts-cache-cancel-',
      );
      final cache = Directory('${root.path}/missing/app-cache');
      final lookup = Completer<void>();
      final provider = _TemporaryPathProvider(
        cache.path,
        lookup: lookup.future,
      );
      final previousProvider = PathProviderPlatform.instance;
      final previousPlatform = debugDefaultTargetPlatformOverride;
      PathProviderPlatform.instance = provider;
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      addTearDown(() async {
        if (!lookup.isCompleted) lookup.complete();
        PathProviderPlatform.instance = previousProvider;
        debugDefaultTargetPlatformOverride = previousPlatform;
        await root.delete(recursive: true);
      });

      final turn = open(_Engine(), 'cache_cancel');
      final speech = turn.speak(utteranceId: 'cache_cancel:0', text: 'First.');
      await _until(() => provider.requests == 1);
      await speech.cancel();
      expect(await speech.started, isFalse);
      expect(await speech.terminal, SpeechTerminal.cancelled);
      lookup.complete();
      await speech.drained;
      expect(await cache.exists(), isFalse);
      expect(player.sourceCalls, 0);
      expect(player.resumes, 0);
    },
  );

  test(
    'voice engine and language are frozen before a preference change',
    () async {
      AgentConfig().setApiKey('TTS_VOICE_STYLE', 'voice-a');
      final engine = _Engine();
      final turn = open(engine, 'voice');
      AgentConfig().setApiKey('TTS_VOICE_STYLE', 'voice-b');
      final replacement = _Engine();
      TTSEngineRegistry.current = replacement;
      final one = turn.speak(utteranceId: 'voice:0', text: 'First.');
      expect(await one.started, isTrue);
      player.complete();
      expect(await one.terminal, SpeechTerminal.completed);
      final two = turn.speak(utteranceId: 'voice:1', text: '日本語。');
      expect(await two.started, isTrue);
      expect(engine.requests.map((request) => request.voice), [
        'voice-a',
        'voice-a',
      ]);
      expect(engine.requests.map((request) => request.language), ['en', 'en']);
      expect(replacement.requests, isEmpty);
      player.complete();
      expect(await two.terminal, SpeechTerminal.completed);
    },
  );

  test(
    'cancelled synthesis keeps its physical slot and never plays late audio',
    () async {
      final gate = Completer<Uint8List>();
      final engine = _Engine(synthesis: gate.future);
      final old = open(engine, 'old');
      final speech = old.speak(utteranceId: 'old:0', text: 'Old.');
      await _until(() => engine.requests.isNotEmpty);
      await MaasoTtsPlugin.prepareForNewTurn();
      expect(await speech.terminal, SpeechTerminal.cancelled);
      expect(await speech.started, isFalse);
      var drained = false;
      speech.drained.then((_) => drained = true);
      final nextEngine = _Engine();
      final next = open(nextEngine, 'new');
      final nextSpeech = next.speak(utteranceId: 'new:0', text: 'New.');
      await _tick();
      expect(nextEngine.requests, isEmpty);
      expect(drained, isFalse);
      gate.complete(_wav());
      await speech.drained;
      expect(await nextSpeech.started, isTrue);
      expect(player.resumes, 1);
      player.complete();
      expect(await nextSpeech.terminal, SpeechTerminal.completed);
    },
  );

  test('cancelling a queued unit does not stop the active unit', () async {
    final engine = _Engine();
    final turn = open(engine, 'queued');
    final one = turn.speak(utteranceId: 'queued:0', text: 'First.');
    expect(await one.started, isTrue);
    final two = turn.speak(utteranceId: 'queued:1', text: 'Second.');
    final stops = player.stops;
    await two.cancel();
    expect(await two.terminal, SpeechTerminal.cancelled);
    expect(await two.started, isFalse);
    expect(player.stops, stops);
    player.complete();
    expect(await one.terminal, SpeechTerminal.completed);
    await turn.drained;
    expect(engine.requests, hasLength(1));
  });

  test(
    'an old turn cancellation and old cleanup do not stop a new owner',
    () async {
      final old = open(_Engine(), 'old_playing');
      final one = old.speak(utteranceId: 'old_playing:0', text: 'Old.');
      expect(await one.started, isTrue);
      await MaasoTtsPlugin.prepareForNewTurn();
      expect(await one.terminal, SpeechTerminal.cancelled);
      final next = open(_Engine(), 'next_playing');
      final two = next.speak(utteranceId: 'next_playing:0', text: 'New.');
      expect(await two.started, isTrue);
      final stops = player.stops;
      await old.cancel();
      await old.drained;
      expect(player.stops, stops);
      player.complete();
      expect(await two.terminal, SpeechTerminal.completed);
    },
  );

  test(
    'unidentified system speech receipts downgrade typed delivery to text',
    () async {
      final turn = open(null, 'system', text: '系统语音。');
      final speech = turn.speak(utteranceId: 'system:0', text: '系统语音。');
      expect(await speech.started, isFalse);
      expect(await speech.terminal, SpeechTerminal.failed);
      expect(systemCalls.where((call) => call == 'speak'), isEmpty);
      expect(player.resumes, 0);
    },
  );

  test('WAV synthesis failure never retries through another voice', () async {
    final failed = Completer<Uint8List>();
    final engine = _Engine(synthesis: failed.future);
    final turn = open(engine, 'failure');
    final speech = turn.speak(utteranceId: 'failure:0', text: 'One try.');
    await _until(() => engine.requests.isNotEmpty);
    failed.completeError(StateError('synthesis_failed'));
    expect(await speech.terminal, SpeechTerminal.failed);
    expect(await speech.started, isFalse);
    expect(engine.requests, hasLength(1));
    expect(systemCalls.where((call) => call == 'speak'), isEmpty);
  });

  test('playback timeout stops output before reporting timedOut', () async {
    final turn = open(_Engine(), 'timeout');
    final speech = turn.speak(utteranceId: 'timeout:0', text: 'A short clip.');
    expect(await speech.started, isTrue);
    final stopped = Completer<void>();
    player.stopGate = stopped.future;
    var terminal = false;
    speech.terminal.then((_) => terminal = true);
    final stops = player.stops;
    await _until(
      () => player.stops > stops,
      timeout: const Duration(seconds: 4),
    );
    expect(terminal, isFalse);
    stopped.complete();
    expect(await speech.terminal, SpeechTerminal.timedOut);
    await speech.drained;
    player.stopGate = null;
  });

  test('paused playback does not consume its completion watchdog', () async {
    final turn = open(_Engine(), 'pause');
    final speech = turn.speak(utteranceId: 'pause:0', text: 'Pause.');
    expect(await speech.started, isTrue);
    await MaasoTtsPlugin.pause();
    var terminal = false;
    speech.terminal.then((_) => terminal = true);
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(terminal, isFalse);
    await MaasoTtsPlugin.resume();
    player.complete();
    expect(await speech.terminal, SpeechTerminal.completed);
  });

  test('typed playback lease pauses and resumes only its utterance', () async {
    final turn = open(_Engine(), 'lease_pause');
    final speech = turn.speak(
      utteranceId: 'lease_pause:0',
      text: 'Pause this utterance.',
    );
    expect(await speech.started, isTrue);
    final lease = MaasoTtsPlugin.captureCurrentTypedPlayback();
    expect(lease, isA<SpeechPlaybackLease>());
    expect(lease!.turnId, 'lease_pause');
    expect(lease.utteranceId, 'lease_pause:0');

    expect(await lease.pause(), isTrue);
    var terminal = false;
    speech.terminal.then((_) => terminal = true);
    await Future<void>.delayed(const Duration(milliseconds: 2300));
    expect(terminal, isFalse);

    expect(await lease.resume(), isTrue);
    player.complete();
    expect(await speech.terminal, SpeechTerminal.completed);
  });

  test('an old typed playback lease cannot control a new owner', () async {
    final turn = open(_Engine(), 'lease_stale');
    final first = turn.speak(utteranceId: 'lease_stale:0', text: 'First.');
    expect(await first.started, isTrue);
    final oldLease = MaasoTtsPlugin.captureCurrentTypedPlayback()!;
    player.complete();
    expect(await first.terminal, SpeechTerminal.completed);

    final second = turn.speak(utteranceId: 'lease_stale:1', text: 'Second.');
    expect(await second.started, isTrue);
    final pauses = player.pauses;
    final resumes = player.resumes;
    final stops = player.stops;

    expect(await oldLease.pause(), isFalse);
    expect(await oldLease.resume(), isFalse);
    expect(await oldLease.stop(), isFalse);
    expect(player.pauses, pauses);
    expect(player.resumes, resumes);
    expect(player.stops, stops);

    player.complete();
    expect(await second.terminal, SpeechTerminal.completed);
  });

  test(
    'typed playback lease stop cancels only the captured identity',
    () async {
      final turn = open(_Engine(), 'lease_stop');
      final first = turn.speak(utteranceId: 'lease_stop:0', text: 'First.');
      final second = turn.speak(utteranceId: 'lease_stop:1', text: 'Second.');
      expect(await first.started, isTrue);
      final lease = MaasoTtsPlugin.captureCurrentTypedPlayback()!;

      expect(await lease.stop(), isTrue);
      expect(await first.terminal, SpeechTerminal.cancelled);
      expect(await second.started, isTrue);
      final stops = player.stops;
      expect(await lease.stop(), isFalse);
      expect(player.stops, stops);

      player.complete();
      expect(await second.terminal, SpeechTerminal.completed);
    },
  );

  test(
    'typed playback lease exposes normalized text without logging it',
    () async {
      const secret = 'LEASE_SECRET_92841';
      final printed = <String>[];
      await runZoned<Future<void>>(
        () async {
          final turn = open(
            _Engine(),
            'lease_text',
            text: '  **$secret**\n   hello 👋 ',
          );
          final speech = turn.speak(
            utteranceId: 'lease_text:0',
            text: '  **$secret**\n   hello 👋 ',
          );
          expect(await speech.started, isTrue);
          final lease = MaasoTtsPlugin.captureCurrentTypedPlayback()!;
          expect(lease.spokenText, '$secret hello');
          player.complete();
          expect(await speech.terminal, SpeechTerminal.completed);
        },
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      expect(printed.join('\n'), isNot(contains(secret)));
    },
  );

  test(
    'start watchdog revokes a stalled warmup without late playback',
    () async {
      final warmup = Completer<bool>();
      final engine = _Engine(warmup: warmup.future);
      final turn = open(
        engine,
        'warmup',
        startTimeout: const Duration(milliseconds: 20),
      );
      final speech = turn.speak(utteranceId: 'warmup:0', text: 'Wait.');
      expect(
        await speech.terminal.timeout(const Duration(seconds: 1)),
        SpeechTerminal.timedOut,
      );
      expect(await speech.started, isFalse);
      warmup.complete(true);
      await speech.drained;
      expect(engine.requests, isEmpty);
      expect(player.resumes, 0);
    },
  );

  test(
    'disposing an unused facade does not stop another facade output',
    () async {
      final turn = open(_Engine(), 'owner');
      final speech = turn.speak(utteranceId: 'owner:0', text: 'Speaking.');
      expect(await speech.started, isTrue);
      final unused = MaasoTtsPlugin();
      final stops = player.stops;
      await unused.dispose();
      expect(player.stops, stops);
      player.complete();
      expect(await speech.terminal, SpeechTerminal.completed);
      expect(
        () => unused.openTurn(turnId: 'disposed', text: 'No.'),
        throwsStateError,
      );
    },
  );

  test(
    'cancel during pending player setup emits no late lip sync or start',
    () async {
      final setup = Completer<void>();
      player.sourceGate = setup.future;
      final envelopes = <LipSyncEnvelopeEvent>[];
      final subscription = EventBus().on<LipSyncEnvelopeEvent>().listen(
        envelopes.add,
      );
      addTearDown(subscription.cancel);
      final turn = open(_Engine(), 'setup');
      final speech = turn.speak(utteranceId: 'setup:0', text: 'Setup.');
      await _until(() => player.sourceCalls > 0);
      await speech.cancel();
      expect(await speech.terminal, SpeechTerminal.cancelled);
      setup.complete();
      await speech.drained;
      expect(await speech.started, isFalse);
      expect(envelopes, isEmpty);
      expect(player.resumes, 0);
      player.sourceGate = null;
    },
  );

  test(
    'late completion from a retired native player cannot complete a new unit',
    () async {
      final turn = open(_Engine(), 'late');
      final first = turn.speak(utteranceId: 'late:0', text: 'First.');
      expect(await first.started, isTrue);
      final oldId = player.live.single;
      player.complete();
      expect(await first.terminal, SpeechTerminal.completed);
      final second = turn.speak(utteranceId: 'late:1', text: 'Second.');
      expect(await second.started, isTrue);
      expect(player.live.single, isNot(oldId));
      var ended = false;
      second.terminal.then((_) => ended = true);
      player.complete(id: oldId);
      await _tick();
      expect(ended, isFalse);
      expect(player.maximumLivePlayers, 1);
      player.complete();
      expect(await second.terminal, SpeechTerminal.completed);
    },
  );

  test(
    'next synthesis and player wait for the previous player disposal',
    () async {
      final dispose = Completer<void>();
      final engine = _Engine();
      final turn = open(engine, 'dispose_wait');
      final first = turn.speak(utteranceId: 'dispose_wait:0', text: 'First.');
      expect(await first.started, isTrue);
      player.disposeGate = dispose.future;
      final before = player.playersCreated;
      player.complete();
      expect(await first.terminal, SpeechTerminal.completed);
      final second = turn.speak(utteranceId: 'dispose_wait:1', text: 'Second.');
      await _tick();
      expect(engine.requests, hasLength(1));
      expect(player.playersCreated, before);
      dispose.complete();
      expect(await second.started, isTrue);
      expect(player.maximumLivePlayers, 1);
      player.disposeGate = null;
      player.complete();
      expect(await second.terminal, SpeechTerminal.completed);
    },
  );

  test(
    'local speaker sid is pinned instead of rereading settings per unit',
    () async {
      final local = _LocalTts();
      local.isReady.value = true;
      local.voiceSid.value = 2;
      appServices.put<SherpaNeuralTts>(local);
      addTearDown(() => appServices.reset());
      TTSEngineRegistry.current = SherpaTtsEngine();
      final plugin = MaasoTtsPlugin(agentId: 'utterance_test');
      plugins.add(plugin);
      final turn = plugin.openTurn(
        turnId: 'local_voice',
        text: 'First. Second.',
      );
      turns.add(turn);
      local.voiceSid.value = 7;
      final first = turn.speak(utteranceId: 'local_voice:0', text: 'First.');
      expect(await first.started, isTrue);
      player.complete();
      expect(await first.terminal, SpeechTerminal.completed);
      local.voiceSid.value = 9;
      final second = turn.speak(utteranceId: 'local_voice:1', text: 'Second.');
      expect(await second.started, isTrue);
      expect(local.sids, [2, 2]);
      player.complete();
      expect(await second.terminal, SpeechTerminal.completed);
      await turn.drained;
    },
  );

  test(
    'failed disposal reports cleanup failure and never creates a concurrent player',
    () async {
      final engine = _Engine();
      final turn = open(engine, 'dispose_failure');
      final first = turn.speak(
        utteranceId: 'dispose_failure:0',
        text: 'First.',
      );
      expect(await first.started, isTrue);
      final before = player.playersCreated;
      player.failDispose = true;
      player.complete();
      expect(await first.terminal, SpeechTerminal.completed);
      await expectLater(first.drained, throwsStateError);
      final second = turn.speak(
        utteranceId: 'dispose_failure:1',
        text: 'Second.',
      );
      expect(await second.terminal, SpeechTerminal.failed);
      expect(await second.started, isFalse);
      expect(engine.requests, hasLength(1));
      expect(player.playersCreated, before);
      turns.remove(turn); // The expected drain error was asserted above.
    },
  );
}

Future<void> _tick() => Future<void>.delayed(const Duration(milliseconds: 10));
Future<void> _until(
  bool Function() test, {
  Duration timeout = const Duration(seconds: 3),
}) async {
  final end = DateTime.now().add(timeout);
  while (!test()) {
    if (DateTime.now().isAfter(end)) fail('Condition did not complete');
    await _tick();
  }
}

class _Engine implements TTSEngine {
  _Engine({this.synthesis, this.warmup});
  final Future<Uint8List>? synthesis;
  final Future<bool>? warmup;
  final requests = <({String text, String? language, String? voice})>[];
  @override
  bool get isReady => warmup == null;
  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) async =>
      await warmup ?? true;
  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) {
    requests.add((text: text, language: language, voice: voice));
    return synthesis ?? Future.value(_wav());
  }
}

class _LocalTts extends SherpaNeuralTts {
  final sids = <int?>[];
  @override
  Future<SherpaTtsClip> synthesizeToWavWithEnvelope(
    String text, {
    int? sid,
    double? speed,
    String? lang,
  }) async {
    sids.add(sid);
    return SherpaTtsClip(wav: _wav(), envelope: const []);
  }
}

Uint8List _wav() {
  final wav = Uint8List(44 + 3200);
  final data = ByteData.sublistView(wav);
  void ascii(int offset, String value) =>
      wav.setRange(offset, offset + value.length, value.codeUnits);
  ascii(0, 'RIFF');
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  ascii(36, 'data');
  data.setUint32(4, wav.length - 8, Endian.little);
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, 16000, Endian.little);
  data.setUint32(28, 32000, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  data.setUint32(40, 3200, Endian.little);
  return wav;
}

class _Global extends GlobalAudioplayersPlatformInterface {
  final events = StreamController<GlobalAudioEvent>.broadcast();
  @override
  Future<void> init() async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => events.stream;
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Future<void> emitGlobalLog(String message) async {}
  @override
  Future<void> setGlobalAudioContext(AudioContext context) async {}
}

class _Player extends AudioplayersPlatformInterface {
  final events = <String, StreamController<AudioEvent>>{};
  int playersCreated = 0;
  final live = <String>{};
  int maximumLivePlayers = 0;
  int resumes = 0;
  int pauses = 0;
  int stops = 0;
  int sourceCalls = 0;
  int currentPosition = 0;
  final fileSources = <String>[];
  final fileBytes = <Uint8List>[];
  Future<void>? stopGate;
  Future<void>? sourceGate;
  Future<void>? disposeGate;
  bool failDispose = false;
  void reset() {
    resumes = 0;
    pauses = 0;
    stops = 0;
    sourceCalls = 0;
    currentPosition = 0;
    fileSources.clear();
    fileBytes.clear();
    stopGate = null;
    sourceGate = null;
    disposeGate = null;
  }

  void complete({String? id}) {
    events[id ?? live.single]!.add(
      const AudioEvent(eventType: AudioEventType.complete),
    );
  }

  @override
  Future<void> create(String id) async {
    playersCreated++;
    live.add(id);
    if (live.length > maximumLivePlayers) maximumLivePlayers = live.length;
    events.putIfAbsent(id, () => StreamController<AudioEvent>.broadcast());
  }

  @override
  Stream<AudioEvent> getEventStream(String id) => events
      .putIfAbsent(id, () => StreamController<AudioEvent>.broadcast())
      .stream;
  @override
  Future<void> setSourceBytes(
    String id,
    Uint8List bytes, {
    String? mimeType,
  }) async {
    sourceCalls++;
    await sourceGate;
    events[id]!.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
  }

  @override
  Future<void> resume(String id) async {
    resumes++;
  }

  @override
  Future<void> stop(String id) async {
    stops++;
    await stopGate;
  }

  @override
  Future<void> pause(String id) async {
    pauses++;
  }

  @override
  Future<void> release(String id) async {}
  @override
  Future<int?> getCurrentPosition(String id) async => currentPosition;
  @override
  Future<int?> getDuration(String id) async => 100;
  @override
  Future<void> setVolume(String id, double volume) async {}
  @override
  Future<void> setBalance(String id, double balance) async {}
  @override
  Future<void> setPlaybackRate(String id, double rate) async {}
  @override
  Future<void> setPlayerMode(String id, PlayerMode mode) async {}
  @override
  Future<void> setReleaseMode(String id, ReleaseMode mode) async {}
  @override
  Future<void> setAudioContext(String id, AudioContext context) async {}
  @override
  Future<void> seek(String id, Duration position) async {}
  @override
  Future<void> emitError(String id, String code, String message) async {}
  @override
  Future<void> emitLog(String id, String message) async {}
  @override
  Future<void> dispose(String id) async {
    await disposeGate;
    if (failDispose) throw StateError('dispose_failed');
    live.remove(id);
  }

  @override
  Future<void> setSourceUrl(
    String id,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {
    if (isLocal != true || mimeType != 'audio/wav') {
      throw UnsupportedError('Expected local WAV');
    }
    sourceCalls++;
    fileSources.add(url);
    fileBytes.add(await File(url).readAsBytes());
    await sourceGate;
    events[id]!.add(
      const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true),
    );
  }
}

class _TemporaryPathProvider extends PathProviderPlatform {
  _TemporaryPathProvider(this.path, {this.lookup});
  final String path;
  final Future<void>? lookup;
  int requests = 0;

  @override
  Future<String?> getTemporaryPath() async {
    requests++;
    await lookup;
    return path;
  }
}
