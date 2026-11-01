import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:record/record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordPlatform originalPlatform;
  late _GatedStartAudioRecorder recorder;
  late MicCaptureService mic;

  setUp(() async {
    originalPlatform = RecordPlatform.instance;
    RecordPlatform.instance = _RecorderInitializationPlatform();
    recorder = _GatedStartAudioRecorder();
    await Future<void>.delayed(Duration.zero);
    mic = MicCaptureService(recorder: recorder);
  });

  tearDown(() async {
    mic.onClose();
    await recorder.streamController.close();
    RecordPlatform.instance = originalPlatform;
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'stop waits for an in-flight startStream and then stops the recorder',
    () async {
      final starting = mic.start();
      await recorder.startStreamEntered.future;

      var stopCompleted = false;
      final stopping = mic.stop().whenComplete(() => stopCompleted = true);
      await Future<void>.delayed(Duration.zero);

      expect(stopCompleted, isFalse);
      expect(recorder.stopCount, 0);
      expect(mic.isRecording.value, isFalse);

      recorder.releaseStartStream.complete();

      expect(await starting, isFalse);
      await stopping;

      expect(recorder.startStreamCount, 1);
      expect(recorder.stopCount, 1);
      expect(stopCompleted, isTrue);
      expect(mic.isRecording.value, isFalse);
    },
  );
}

class _GatedStartAudioRecorder extends AudioRecorder {
  final Completer<void> startStreamEntered = Completer<void>();
  final Completer<void> releaseStartStream = Completer<void>();
  final StreamController<Uint8List> streamController =
      StreamController<Uint8List>.broadcast();

  int startStreamCount = 0;
  int stopCount = 0;

  @override
  Future<bool> hasPermission({bool request = true}) async => true;

  @override
  Future<Stream<Uint8List>> startStream(RecordConfig config) async {
    startStreamCount++;
    startStreamEntered.complete();
    await releaseStartStream.future;
    return streamController.stream;
  }

  @override
  Future<String?> stop() async {
    stopCount++;
    return null;
  }

  @override
  Future<void> dispose() async {}
}

class _RecorderInitializationPlatform extends RecordPlatform {
  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> cancel(String recorderId) async => _unsupported();

  @override
  Future<void> dispose(String recorderId) async => _unsupported();

  @override
  Future<Amplitude> getAmplitude(String recorderId) => _unsupported();

  @override
  Future<bool> hasPermission(String recorderId, {bool request = true}) =>
      _unsupported();

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) =>
      _unsupported();

  @override
  Future<bool> isPaused(String recorderId) => _unsupported();

  @override
  Future<bool> isRecording(String recorderId) => _unsupported();

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) =>
      _unsupported();

  @override
  Stream<RecordState> onStateChanged(String recorderId) =>
      const Stream<RecordState>.empty();

  @override
  Future<void> pause(String recorderId) async => _unsupported();

  @override
  Future<void> resume(String recorderId) async => _unsupported();

  @override
  void setOnConfigChanged(
    String recorderId,
    void Function(RecordConfig config)? handler,
  ) {}

  @override
  Future<void> start(
    String recorderId,
    RecordConfig config, {
    required String path,
  }) async => _unsupported();

  @override
  Future<Stream<Uint8List>> startStream(
    String recorderId,
    RecordConfig config,
  ) => _unsupported();

  @override
  Future<String?> stop(String recorderId) => _unsupported();

  Never _unsupported() => throw UnsupportedError('not used by this test');
}
