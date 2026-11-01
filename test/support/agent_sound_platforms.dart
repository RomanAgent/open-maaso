import 'dart:async';

// ignore: depend_on_referenced_packages
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void installAgentSoundPlatforms() {
  GlobalAudioplayersPlatformInterface.instance = _SilentGlobalAudio();
  AudioplayersPlatformInterface.instance = _SilentPlayerAudio();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('flutter_tts'),
        (_) async => 1,
      );
}

class _SilentGlobalAudio extends GlobalAudioplayersPlatformInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<void> init() async {}
  @override
  Future<void> emitGlobalLog(String message) async {}
  @override
  Future<void> emitGlobalError(String code, String message) async {}
  @override
  Future<void> setGlobalAudioContext(AudioContext ctx) async {}
  @override
  Stream<GlobalAudioEvent> getGlobalEventStream() => const Stream.empty();
}

class _SilentPlayerAudio extends AudioplayersPlatformInterface {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
  @override
  Future<void> create(String id) async {}
  @override
  Future<void> stop(String id) async {}
  @override
  Future<void> pause(String id) async {}
  @override
  Future<void> resume(String id) async {}
  @override
  Future<void> dispose(String id) async {}
  @override
  Future<void> release(String id) async {}
  @override
  Future<int?> getCurrentPosition(String id) async => 0;
  @override
  Future<int?> getDuration(String id) async => 0;
  @override
  Future<void> emitLog(String id, String message) async {}
  @override
  Future<void> emitError(String id, String code, String message) async {}
  @override
  Future<void> setAudioContext(String id, AudioContext ctx) async {}
  @override
  Future<void> setReleaseMode(String id, ReleaseMode mode) async {}
  @override
  Stream<AudioEvent> getEventStream(String id) => const Stream.empty();
}
