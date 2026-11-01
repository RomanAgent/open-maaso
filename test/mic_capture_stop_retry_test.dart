import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:record/record.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordPlatform originalPlatform;
  late _FailOnceAudioRecorder recorder;
  late MicCaptureService mic;

  setUp(() async {
    originalPlatform = RecordPlatform.instance;
    RecordPlatform.instance = _RecorderInitializationPlatform();
    recorder = _FailOnceAudioRecorder();
    // AudioRecorder creates its platform handle from its constructor's async
    // initializer. Let that initializer settle before the test can restore the
    // process-global platform implementation.
    await Future<void>.delayed(Duration.zero);
    mic = MicCaptureService(recorder: recorder);
    mic.isRecording.value = true;
    mic.amplitude.value = 0.75;
  });

  tearDown(() async {
    mic.onClose();
    RecordPlatform.instance = originalPlatform;
    await Future<void>.delayed(Duration.zero);
  });

  test(
    'stop deduplicates, propagates failure, and retries the retained recorder',
    () async {
      final first = mic.stop();
      await recorder.firstStopEntered.future;
      final concurrent = mic.stop();

      expect(identical(first, concurrent), isTrue);
      expect(recorder.stopCount, 1);
      expect(mic.isRecording.value, isTrue);

      final firstFailure = expectLater(
        first,
        throwsA(same(recorder.firstStopFailure)),
      );
      final concurrentFailure = expectLater(
        concurrent,
        throwsA(same(recorder.firstStopFailure)),
      );
      recorder.releaseFirstStop.complete();
      await Future.wait<void>([firstFailure, concurrentFailure]);

      expect(recorder.stopCount, 1);
      expect(mic.isRecording.value, isTrue);
      expect(mic.amplitude.value, 0.75);

      await mic.stop();

      expect(recorder.stopCount, 2);
      expect(mic.isRecording.value, isFalse);
      expect(mic.amplitude.value, 0);
    },
  );
}

class _FailOnceAudioRecorder extends AudioRecorder {
  final Object firstStopFailure = StateError('first recorder stop failed');
  final Completer<void> firstStopEntered = Completer<void>();
  final Completer<void> releaseFirstStop = Completer<void>();

  int stopCount = 0;
  int disposeCount = 0;

  @override
  Future<String?> stop() async {
    stopCount++;
    if (stopCount == 1) {
      firstStopEntered.complete();
      await releaseFirstStop.future;
      throw firstStopFailure;
    }
    return null;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
  }
}

/// AudioRecorder always creates a platform handle in its constructor, even
/// when every operation used by the test is overridden by a fake subclass.
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
