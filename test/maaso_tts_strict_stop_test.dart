import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FailingPlayerPlatform playerPlatform;

  setUpAll(() {
    GlobalAudioplayersPlatformInterface.instance = _FakeGlobalPlatform();
    playerPlatform = _FailingPlayerPlatform();
    AudioplayersPlatformInterface.instance = playerPlatform;
  });

  setUp(() {
    playerPlatform.failuresRemaining = 0;
  });

  test(
    'normal stop remains best-effort while teardown stop propagates',
    () async {
      playerPlatform.failuresRemaining = 1;
      await MaasoTtsPlugin.stopAll(agentId: 'self');

      playerPlatform.failuresRemaining = 1;
      await expectLater(
        MaasoTtsPlugin.stopAllStrict(agentId: 'self'),
        throwsA(isA<StateError>()),
      );

      await MaasoTtsPlugin.stopAllStrict(agentId: 'self');
      expect(playerPlatform.stopCalls, greaterThanOrEqualTo(3));
    },
  );
}

final class _FakeGlobalPlatform extends GlobalAudioplayersPlatformInterface {
  final StreamController<GlobalAudioEvent> _events =
      StreamController<GlobalAudioEvent>.broadcast();

  @override
  Future<void> emitGlobalError(String code, String message) async {}

  @override
  Future<void> emitGlobalLog(String message) async {}

  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => _events.stream;

  @override
  Future<void> init() async {}

  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}
}

final class _FailingPlayerPlatform extends AudioplayersPlatformInterface {
  final Map<String, StreamController<AudioEvent>> _events =
      <String, StreamController<AudioEvent>>{};
  int failuresRemaining = 0;
  int stopCalls = 0;

  @override
  Future<void> create(String id) async {
    _events[id] = StreamController<AudioEvent>.broadcast();
  }

  @override
  Future<void> dispose(String id) async {
    await _events.remove(id)?.close();
  }

  @override
  Future<void> emitError(String id, String code, String message) async {}

  @override
  Future<void> emitLog(String id, String message) async {}

  @override
  Future<int?> getCurrentPosition(String id) async => 0;

  @override
  Future<int?> getDuration(String id) async => 0;

  @override
  Stream<AudioEvent> getEventStream(String id) => _events
      .putIfAbsent(id, () => StreamController<AudioEvent>.broadcast())
      .stream;

  @override
  Future<void> pause(String id) async {}

  @override
  Future<void> release(String id) async {}

  @override
  Future<void> resume(String id) async {}

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
  Future<void> stop(String id) async {
    stopCalls += 1;
    if (failuresRemaining > 0) {
      failuresRemaining -= 1;
      throw StateError('audio_stop_failed');
    }
  }
}
