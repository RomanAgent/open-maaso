import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => appServices.reset());

  test(
    'VAD stop attempts both stream cleanups and keeps failures retryable',
    () async {
      final subscription = _RetryCancelSubscription();
      final candidateSubscription = _RetryCancelSubscription(failFirst: false);
      final mic = _TestMicCaptureService(
        _SubscriptionStream(subscription),
        playbackCandidates: _SubscriptionStream(candidateSubscription),
      );
      appServices.put<MicCaptureService>(mic);
      final vad = VadService()..isReady.value = true;
      addTearDown(vad.dispose);

      await vad.startWithOptions(includePlaybackCandidates: true);
      expect(vad.isRunning.value, isTrue);

      await expectLater(vad.stop(), throwsA(same(subscription.firstFailure)));
      expect(subscription.cancelCalls, 1);
      expect(candidateSubscription.cancelCalls, 1);
      expect(vad.isRunning.value, isTrue);

      await vad.stop();
      expect(subscription.cancelCalls, 2);
      expect(candidateSubscription.cancelCalls, 1);
      expect(vad.isRunning.value, isFalse);
    },
  );

  test('playback candidate VAD subscription is opt-in', () async {
    final recognition = _CountingStream();
    final candidates = _CountingStream();
    final mic = _TestMicCaptureService(
      recognition,
      playbackCandidates: candidates,
    );
    appServices.put<MicCaptureService>(mic);
    final vad = VadService()..isReady.value = true;
    addTearDown(vad.dispose);

    await vad.start();
    expect(recognition.listenCalls, 1);
    expect(candidates.listenCalls, 0);
    await vad.stop();

    await vad.startWithOptions(includePlaybackCandidates: true);
    expect(recognition.listenCalls, 2);
    expect(candidates.listenCalls, 1);
    await vad.stop();
  });

  test('speech-ended playback marker defaults closed', () {
    final samples = Float32List(0);

    expect(
      UserSpeakingEndedEvent(
        duration: Duration.zero,
        samples: samples,
      ).beganDuringPlayback,
      isFalse,
    );
    expect(
      UserSpeakingEndedEvent(
        duration: Duration.zero,
        samples: samples,
        beganDuringPlayback: true,
      ).beganDuringPlayback,
      isTrue,
    );
  });
}

final class _TestMicCaptureService extends MicCaptureService {
  _TestMicCaptureService(this.stream, {this.playbackCandidates});

  final Stream<Uint8List> stream;
  final Stream<Uint8List>? playbackCandidates;

  @override
  Stream<Uint8List> get recognitionStream => stream;

  @override
  Stream<Uint8List> get playbackCandidateStream =>
      playbackCandidates ?? const Stream<Uint8List>.empty();
}

final class _CountingStream extends Stream<Uint8List> {
  int listenCalls = 0;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    listenCalls++;
    return const Stream<Uint8List>.empty().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }
}

final class _SubscriptionStream extends Stream<Uint8List> {
  _SubscriptionStream(this.subscription);

  final StreamSubscription<Uint8List> subscription;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => subscription;
}

final class _RetryCancelSubscription implements StreamSubscription<Uint8List> {
  _RetryCancelSubscription({this.failFirst = true});

  final bool failFirst;
  final Object firstFailure = StateError('VAD subscription cancel failed');
  int cancelCalls = 0;

  @override
  Future<void> cancel() async {
    cancelCalls++;
    if (failFirst && cancelCalls == 1) throw firstFailure;
  }

  @override
  bool get isPaused => false;

  @override
  void onData(void Function(Uint8List data)? handleData) {}

  @override
  void onDone(void Function()? handleDone) {}

  @override
  void onError(Function? handleError) {}

  @override
  void pause([Future<void>? resumeSignal]) {}

  @override
  void resume() {}

  @override
  Future<E> asFuture<E>([E? futureValue]) => Future<E>.value(futureValue);
}
