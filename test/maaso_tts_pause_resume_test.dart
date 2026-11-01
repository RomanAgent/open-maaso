// test/maaso_tts_pause_resume_test.dart
import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';

// ---------------------------------------------------------------------------
// Minimal fakes so AudioPlayer can construct without real platform channels.
// ---------------------------------------------------------------------------

class _FakeGlobalPlatform extends GlobalAudioplayersPlatformInterface {
  final _ctrl = StreamController<GlobalAudioEvent>.broadcast();

  @override
  Future<void> init() async {}

  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}

  @override
  Future<void> emitGlobalLog(String message) async {}

  @override
  Future<void> emitGlobalError(String code, String message) async {}

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => _ctrl.stream;
}

class _FakePlayerPlatform extends AudioplayersPlatformInterface {
  final Map<String, StreamController<AudioEvent>> _ctrls = {};

  @override
  Future<void> create(String id) async {
    _ctrls[id] = StreamController<AudioEvent>.broadcast();
  }

  @override
  Future<void> dispose(String id) async => _ctrls[id]?.close();

  @override
  Future<void> pause(String id) async {}

  @override
  Future<void> resume(String id) async {}

  @override
  Future<void> stop(String id) async {}

  @override
  Future<void> release(String id) async {}

  @override
  Future<void> seek(String id, Duration position) async {}

  @override
  Future<void> setAudioContext(String id, AudioContext ctx) async {}

  @override
  Future<void> setBalance(String id, double balance) async {}

  @override
  Future<void> setPlaybackRate(String id, double rate) async {}

  @override
  Future<void> setPlayerMode(String id, PlayerMode mode) async {}

  @override
  Future<void> setReleaseMode(String id, ReleaseMode mode) async {}

  @override
  Future<void> setSourceBytes(
    String id,
    Uint8List bytes, {
    String? mimeType,
  }) async {}

  @override
  Future<void> setSourceUrl(
    String id,
    String url, {
    bool? isLocal,
    String? mimeType,
  }) async {}

  @override
  Future<void> setVolume(String id, double volume) async {}

  @override
  Future<int?> getCurrentPosition(String id) async => 0;

  @override
  Future<int?> getDuration(String id) async => 0;

  @override
  Stream<AudioEvent> getEventStream(String id) {
    _ctrls.putIfAbsent(id, () => StreamController<AudioEvent>.broadcast());
    return _ctrls[id]!.stream;
  }

  @override
  Future<void> emitError(String id, String code, String message) async {}

  @override
  Future<void> emitLog(String id, String message) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Swap in fake platform implementations before any AudioPlayer is created.
  setUpAll(() {
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobalPlatform();
    AudioplayersPlatformInterface.instance = _FakePlayerPlatform();

    // Silence the flutter_tts method channel (opened by MaasoTtsPlugin init).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (call) async => null,
        );
  });

  test('pause/resume do not advance the speak generation', () async {
    final before = MaasoTtsPlugin.debugSpeakGeneration;
    await MaasoTtsPlugin.pause(agentId: 'self');
    await MaasoTtsPlugin.resume(agentId: 'self');
    expect(
      MaasoTtsPlugin.debugSpeakGeneration,
      before,
      reason: 'pause/resume must keep the in-flight reply task alive',
    );
  });

  test('stopAll DOES advance the generation (sanity)', () async {
    final before = MaasoTtsPlugin.debugSpeakGeneration;
    await MaasoTtsPlugin.stopAll(agentId: 'self');
    expect(MaasoTtsPlugin.debugSpeakGeneration, greaterThan(before));
  });

  test(
    'prepareForNewTurn advances generation to drop stale queued speech',
    () async {
      final before = MaasoTtsPlugin.debugSpeakGeneration;
      await MaasoTtsPlugin.prepareForNewTurn(agentId: 'self');
      expect(
        MaasoTtsPlugin.debugSpeakGeneration,
        greaterThan(before),
        reason: 'a fresh user turn should interrupt previous queued TTS',
      );
    },
  );
}
