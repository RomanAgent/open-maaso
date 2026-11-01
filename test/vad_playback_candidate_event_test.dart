import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

void main() {
  tearDown(appServices.reset);

  test(
    'playback candidates stay off the formal user-speaking event chain',
    () async {
      final userStarts = <UserSpeakingStartedEvent>[];
      final userEnds = <UserSpeakingEndedEvent>[];
      final candidateStarts = <PlaybackSpeechCandidateStartedEvent>[];
      final candidateEnds = <PlaybackSpeechCandidateEndedEvent>[];
      final subscriptions = <StreamSubscription<ClawEvent>>[
        EventBus().on<UserSpeakingStartedEvent>().listen(userStarts.add),
        EventBus().on<UserSpeakingEndedEvent>().listen(userEnds.add),
        EventBus().on<PlaybackSpeechCandidateStartedEvent>().listen(
          candidateStarts.add,
        ),
        EventBus().on<PlaybackSpeechCandidateEndedEvent>().listen(
          candidateEnds.add,
        ),
      ];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });
      final samples = Float32List.fromList(<double>[-0.5, 0.25, 0.75]);
      const duration = Duration(milliseconds: 420);

      final started = PlaybackSpeechCandidateStartedEvent();
      final ended = PlaybackSpeechCandidateEndedEvent(
        duration: duration,
        samples: samples,
      );
      EventBus().fire(started);
      EventBus().fire(ended);
      await Future<void>.delayed(Duration.zero);

      // AgentPresenceService and formal turn input subscribe to UserSpeaking*,
      // so sibling candidate events must never reach either subscription.
      expect(userStarts, isEmpty);
      expect(userEnds, isEmpty);
      expect(candidateStarts, <PlaybackSpeechCandidateStartedEvent>[started]);
      expect(candidateEnds, <PlaybackSpeechCandidateEndedEvent>[ended]);
      expect(started, isNot(isA<UserSpeakingStartedEvent>()));
      expect(ended, isNot(isA<UserSpeakingEndedEvent>()));
      expect(ended.duration, duration);
      expect(ended.samples, same(samples));
      expect(ended.samples, orderedEquals(<double>[-0.5, 0.25, 0.75]));
    },
  );

  test(
    'overlapping playback and user segments keep independent detector state',
    () async {
      final recognition = StreamController<Uint8List>.broadcast(sync: true);
      final playbackCandidates = StreamController<Uint8List>.broadcast(
        sync: true,
      );
      final userDetector = _FakeVadDetector();
      final candidateDetector = _FakeVadDetector();
      final vad = VadService.withDetectorsForTesting(
        userDetector: userDetector,
        playbackCandidateDetector: candidateDetector,
      );
      appServices.put<MicCaptureService>(
        _TestMicCaptureService(recognition.stream, playbackCandidates.stream),
      );
      addTearDown(() async {
        vad.dispose();
        await recognition.close();
        await playbackCandidates.close();
      });
      final userStarts = <UserSpeakingStartedEvent>[];
      final userEnds = <UserSpeakingEndedEvent>[];
      final candidateStarts = <PlaybackSpeechCandidateStartedEvent>[];
      final candidateEnds = <PlaybackSpeechCandidateEndedEvent>[];
      final subscriptions = <StreamSubscription<ClawEvent>>[
        EventBus().on<UserSpeakingStartedEvent>().listen(userStarts.add),
        EventBus().on<UserSpeakingEndedEvent>().listen(userEnds.add),
        EventBus().on<PlaybackSpeechCandidateStartedEvent>().listen(
          candidateStarts.add,
        ),
        EventBus().on<PlaybackSpeechCandidateEndedEvent>().listen(
          candidateEnds.add,
        ),
      ];
      addTearDown(() async {
        for (final subscription in subscriptions) {
          await subscription.cancel();
        }
      });
      final userSamples = Float32List.fromList(<double>[0.1, 0.2]);
      final candidateSamples = Float32List.fromList(<double>[0.7, -0.4]);
      userDetector
        ..enqueue(detected: true)
        ..enqueue(detected: false, completedSegment: userSamples);
      candidateDetector
        ..enqueue(detected: true)
        ..enqueue(detected: false, completedSegment: candidateSamples);

      await vad.startWithOptions(includePlaybackCandidates: true);
      recognition.add(_silentPcmChunk);
      expect(vad.userIsSpeaking.value, isTrue);
      playbackCandidates.add(_silentPcmChunk);
      playbackCandidates.add(_silentPcmChunk);
      await Future<void>.delayed(Duration.zero);

      // Ending a playback candidate cannot close the still-active formal
      // user segment or publish its audio through UserSpeakingEndedEvent.
      expect(vad.userIsSpeaking.value, isTrue);
      expect(userStarts, hasLength(1));
      expect(userEnds, isEmpty);
      expect(candidateStarts, hasLength(1));
      expect(candidateEnds.single.samples, same(candidateSamples));

      recognition.add(_silentPcmChunk);
      await Future<void>.delayed(Duration.zero);

      expect(vad.userIsSpeaking.value, isFalse);
      expect(userEnds.single.samples, same(userSamples));
      expect(candidateEnds, hasLength(1));
      expect(userDetector.acceptCalls, 2);
      expect(candidateDetector.acceptCalls, 2);

      await vad.stop();
      expect(userDetector.resetCalls, 1);
      expect(candidateDetector.resetCalls, 1);
      vad.dispose();
      expect(userDetector.freeCalls, 1);
      expect(candidateDetector.freeCalls, 1);
    },
  );

  test('testing seam rejects a shared detector instance', () {
    final detector = _FakeVadDetector();

    expect(
      () => VadService.withDetectorsForTesting(
        userDetector: detector,
        playbackCandidateDetector: detector,
      ),
      throwsArgumentError,
    );
  });
}

final Uint8List _silentPcmChunk = Uint8List.fromList(<int>[0, 0]);

final class _TestMicCaptureService extends MicCaptureService {
  _TestMicCaptureService(this._recognition, this._playbackCandidates);

  final Stream<Uint8List> _recognition;
  final Stream<Uint8List> _playbackCandidates;

  @override
  Stream<Uint8List> get recognitionStream => _recognition;

  @override
  Stream<Uint8List> get playbackCandidateStream => _playbackCandidates;
}

final class _FakeVadDetector implements VadAudioDetector {
  final Queue<_DetectorFrame> _frames = Queue<_DetectorFrame>();
  final Queue<Float32List> _segments = Queue<Float32List>();
  bool _detected = false;
  int acceptCalls = 0;
  int resetCalls = 0;
  int freeCalls = 0;

  void enqueue({required bool detected, Float32List? completedSegment}) {
    _frames.add(
      _DetectorFrame(detected: detected, completedSegment: completedSegment),
    );
  }

  @override
  void acceptWaveform(Float32List samples) {
    acceptCalls++;
    final frame = _frames.removeFirst();
    _detected = frame.detected;
    final completedSegment = frame.completedSegment;
    if (completedSegment != null) _segments.add(completedSegment);
  }

  @override
  bool isDetected() => _detected;

  @override
  bool isEmpty() => _segments.isEmpty;

  @override
  Float32List frontSamples() => _segments.first;

  @override
  void pop() => _segments.removeFirst();

  @override
  void reset() {
    resetCalls++;
    _detected = false;
    _segments.clear();
  }

  @override
  void free() => freeCalls++;
}

final class _DetectorFrame {
  const _DetectorFrame({
    required this.detected,
    required this.completedSegment,
  });

  final bool detected;
  final Float32List? completedSegment;
}
