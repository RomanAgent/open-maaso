import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/self_avatar_projection_service.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

void main() {
  testWidgets('queued old restoration cannot overtake a newer emotion input', (
    tester,
  ) async {
    final sink = _BlockingDispatchSink();
    final service = SelfAvatarProjectionService(
      accountGeneration: 1,
      mode: () => FeatureRolloutMode.enforce,
      dispatchSink: sink,
    );
    addTearDown(service.onClose);
    await service.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      sequence: 1,
    );
    sink.block = true;
    final temporary = service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 2,
        params: EmotionParams.happy,
        duration: Duration(seconds: 1),
      ),
    );
    await sink.started.future;
    final newer = service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 3,
        params: EmotionParams.sad,
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    sink.release.complete();
    await temporary;
    await newer;
    await service.waitForIdle();
    expect(
      sink.dispatches.last.expression!.toJson(),
      emotionToAvatarParams(EmotionParams.sad).toJson(),
    );
    expect(
      sink.dispatches.where(
        (dispatch) =>
            dispatch.inputKind == SelfAvatarProjectionInputKind.emotionRestore,
      ),
      isEmpty,
    );
  });

  testWidgets(
    'timed expression restores base without changing the TTS channel',
    (tester) async {
      final sink = _RecordingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 1,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      addTearDown(service.onClose);
      await service.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        sequence: 1,
      );
      await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 2,
          params: EmotionParams.serious,
        ),
      );
      await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 3,
          isSpeaking: true,
          generation: 1,
        ),
      );
      await service.project(
        const SelfAvatarLipFrameProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 4,
          amplitude: 0.8,
          generation: 1,
        ),
      );
      await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 5,
          params: EmotionParams.happy,
          duration: Duration(seconds: 1),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await service.waitForIdle();
      final restored = sink.dispatches.last;
      expect(restored.inputKind, SelfAvatarProjectionInputKind.emotionRestore);
      expect(restored.expression!.happy, 0);
      expect(restored.expression!.mouthOpen, 0);
      expect(restored.expression!.surprised, 0);
      expect(
        sink.dispatches
            .where((event) => event.mouthOpen != null)
            .last
            .mouthOpen,
        0.8,
        reason: 'emotion restoration leaves the independent TTS mouth intact',
      );
      expect(restored.mouthOpen, isNull);
      expect(restored.stopLipSync, isFalse);
      expect(restored.lipEnvelope, isEmpty);
      // Timer transitions must not consume a caller's sequence number.
      final next = await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 6,
          params: EmotionParams.calm,
        ),
      );
      expect(next.disposition, SelfAvatarProjectionDisposition.enforced);
    },
  );

  testWidgets('new emotion and renderer generations fence older cue timers', (
    tester,
  ) async {
    final sink = _RecordingDispatchSink();
    final service = SelfAvatarProjectionService(
      accountGeneration: 1,
      mode: () => FeatureRolloutMode.enforce,
      dispatchSink: sink,
    );
    addTearDown(service.onClose);
    await service.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      sequence: 1,
    );
    await service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 2,
        params: EmotionParams.happy,
        duration: Duration(seconds: 1),
      ),
    );
    await service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 3,
        params: EmotionParams.sad,
      ),
    );
    final count = sink.dispatches.length;
    await tester.pump(const Duration(seconds: 2));
    await service.waitForIdle();
    expect(sink.dispatches, hasLength(count));
    expect(
      sink.dispatches.last.expression!.toJson(),
      emotionToAvatarParams(EmotionParams.sad).toJson(),
    );
    await service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 4,
        params: EmotionParams.happy,
        duration: Duration(seconds: 1),
      ),
    );
    await service.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 2,
      ready: true,
      sequence: 5,
    );
    expect(
      sink.dispatches.last.expression!.toJson(),
      emotionToAvatarParams(EmotionParams.sad).toJson(),
    );
    final reboundCount = sink.dispatches.length;
    await tester.pump(const Duration(seconds: 2));
    await service.waitForIdle();
    expect(sink.dispatches, hasLength(reboundCount));
  });

  testWidgets('reset and sealing terminate temporary projection cues', (
    tester,
  ) async {
    final sink = _RecordingDispatchSink();
    final service = SelfAvatarProjectionService(
      accountGeneration: 1,
      mode: () => FeatureRolloutMode.enforce,
      dispatchSink: sink,
    );
    await service.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      sequence: 1,
    );
    await service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 2,
        params: EmotionParams.happy,
        duration: Duration(seconds: 1),
      ),
    );
    await service.project(
      const SelfAvatarEmotionResetProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 3,
      ),
    );
    expect(
      sink.dispatches.last.expression!.toJson(),
      emotionToAvatarParams(EmotionParams.neutral).toJson(),
    );
    await service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 1,
        rendererGeneration: 1,
        sequence: 4,
        params: EmotionParams.happy,
        duration: Duration(seconds: 1),
      ),
    );
    await service.sealAndDrain();
    final count = sink.dispatches.length;
    await tester.pump(const Duration(seconds: 2));
    await service.waitForIdle();
    expect(sink.dispatches, hasLength(count));
  });

  for (final mode in <FeatureRolloutMode>[
    FeatureRolloutMode.off,
    FeatureRolloutMode.shadow,
  ]) {
    testWidgets('$mode timed projection preserves the legacy renderer owner', (
      tester,
    ) async {
      final sink = _RecordingDispatchSink();
      final comparator = _RecordingComparator(
        SelfAvatarProjectionShadowComparison.matched,
      );
      final service = SelfAvatarProjectionService(
        accountGeneration: 1,
        mode: () => mode,
        dispatchSink: sink,
        shadowComparator: comparator,
      );
      addTearDown(service.onClose);
      await service.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        sequence: 1,
      );
      await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 2,
          params: EmotionParams.happy,
          duration: Duration(seconds: 1),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await service.waitForIdle();
      expect(sink.dispatches, isEmpty);
      expect(
        service.recentReceipts.last.inputKind,
        SelfAvatarProjectionInputKind.emotionRestore,
      );
      expect(
        service.recentReceipts.last.disposition,
        mode == FeatureRolloutMode.off
            ? SelfAvatarProjectionDisposition.legacyPreserved
            : SelfAvatarProjectionDisposition.shadowMatched,
      );
    });
  }

  test(
    'off preserves the legacy owner and invokes no v2 collaborator',
    () async {
      final sink = _RecordingDispatchSink();
      final comparator = _RecordingComparator(
        SelfAvatarProjectionShadowComparison.matched,
      );
      final service = SelfAvatarProjectionService(
        accountGeneration: 7,
        mode: () => FeatureRolloutMode.off,
        dispatchSink: sink,
        shadowComparator: comparator,
      );

      await service.bindRenderer(
        accountGeneration: 7,
        rendererGeneration: 2,
        ready: true,
        sequence: 1,
      );
      final receipt = await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 7,
          rendererGeneration: 2,
          sequence: 2,
          params: EmotionParams.happy,
        ),
      );

      expect(
        receipt.disposition,
        SelfAvatarProjectionDisposition.legacyPreserved,
      );
      expect(receipt.fingerprint, hasLength(16));
      expect(sink.dispatches, isEmpty);
      expect(comparator.candidates, isEmpty);
    },
  );

  test('shadow compares bounded plans without dispatching', () async {
    var comparison = SelfAvatarProjectionShadowComparison.matched;
    final sink = _RecordingDispatchSink();
    final comparator = _RecordingComparator.dynamic(() => comparison);
    final service = SelfAvatarProjectionService(
      accountGeneration: 3,
      mode: () => FeatureRolloutMode.shadow,
      dispatchSink: sink,
      shadowComparator: comparator,
    );
    await service.bindRenderer(
      accountGeneration: 3,
      rendererGeneration: 1,
      ready: true,
      sequence: 1,
    );

    final matched = await service.project(
      const SelfAvatarMemeProjectionInput(
        accountGeneration: 3,
        rendererGeneration: 1,
        sequence: 2,
      ),
    );
    comparison = SelfAvatarProjectionShadowComparison.diverged;
    final diverged = await service.project(
      const SelfAvatarEmotionProjectionInput(
        accountGeneration: 3,
        rendererGeneration: 1,
        sequence: 3,
        params: EmotionParams.sad,
      ),
    );

    expect(matched.disposition, SelfAvatarProjectionDisposition.shadowMatched);
    expect(
      diverged.disposition,
      SelfAvatarProjectionDisposition.shadowDiverged,
    );
    expect(sink.dispatches, isEmpty);
    expect(comparator.candidates, hasLength(3));
    expect(
      comparator.candidates.every(
        (candidate) =>
            candidate.fingerprint.length == 16 &&
            candidate.commandCount <= 5 &&
            candidate.channels.length <= 4,
      ),
      isTrue,
    );
  });

  test(
    'enforce is the only mode that dispatches canonical projection',
    () async {
      var mode = FeatureRolloutMode.off;
      final sink = _RecordingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 4,
        mode: () => mode,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 4,
        rendererGeneration: 8,
        ready: true,
        sequence: 1,
      );

      mode = FeatureRolloutMode.enforce;
      final emotion = await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 4,
          rendererGeneration: 8,
          sequence: 2,
          params: EmotionParams.happy,
        ),
      );
      final speaking = await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 4,
          rendererGeneration: 8,
          sequence: 3,
          isSpeaking: true,
          generation: 11,
        ),
      );
      final lip = await service.project(
        const SelfAvatarLipFrameProjectionInput(
          accountGeneration: 4,
          rendererGeneration: 8,
          sequence: 4,
          amplitude: 0.75,
          generation: 11,
        ),
      );
      final envelope = await service.project(
        SelfAvatarLipEnvelopeProjectionInput(
          accountGeneration: 4,
          rendererGeneration: 8,
          sequence: 5,
          envelope: const <double>[0.1, 0.8, 0.2],
          frameRate: 30,
          generation: 11,
        ),
      );
      final stopped = await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 4,
          rendererGeneration: 8,
          sequence: 6,
          isSpeaking: false,
          generation: 11,
        ),
      );

      expect(<SelfAvatarProjectionDisposition>[
        emotion.disposition,
        speaking.disposition,
        lip.disposition,
        envelope.disposition,
        stopped.disposition,
      ], everyElement(SelfAvatarProjectionDisposition.enforced));
      expect(sink.dispatches, hasLength(5));
      expect(sink.dispatches[2].mouthOpen, closeTo(0.75, 1e-9));
      expect(sink.dispatches[3].lipEnvelope, const <double>[0.1, 0.8, 0.2]);
      expect(sink.dispatches[4].stopLipSync, isTrue);
      expect(sink.dispatches[4].framing, 'full');
    },
  );

  test(
    'account and renderer generations reject stale work with zero writes',
    () async {
      final sink = _RecordingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 9,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 9,
        rendererGeneration: 5,
        ready: true,
        sequence: 1,
      );
      sink.dispatches.clear();

      final wrongAccount = await service.project(
        const SelfAvatarMemeProjectionInput(
          accountGeneration: 8,
          rendererGeneration: 5,
          sequence: 2,
        ),
      );
      final oldRenderer = await service.project(
        const SelfAvatarMemeProjectionInput(
          accountGeneration: 9,
          rendererGeneration: 4,
          sequence: 3,
        ),
      );
      final oldBinding = await service.bindRenderer(
        accountGeneration: 9,
        rendererGeneration: 4,
        ready: true,
        sequence: 4,
      );

      expect(
        wrongAccount.disposition,
        SelfAvatarProjectionDisposition.rejectedStaleAccount,
      );
      expect(
        oldRenderer.disposition,
        SelfAvatarProjectionDisposition.rejectedStaleRenderer,
      );
      expect(
        oldBinding.disposition,
        SelfAvatarProjectionDisposition.rejectedStaleRenderer,
      );
      expect(sink.dispatches, isEmpty);
    },
  );

  test(
    'sequence and non-finite payloads fail closed with zero writes',
    () async {
      final sink = _RecordingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 9,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 9,
        rendererGeneration: 1,
        ready: true,
        sequence: 10,
      );
      sink.dispatches.clear();

      final replay = await service.project(
        const SelfAvatarMemeProjectionInput(
          accountGeneration: 9,
          rendererGeneration: 1,
          sequence: 10,
        ),
      );
      final invalid = await service.project(
        const SelfAvatarLipFrameProjectionInput(
          accountGeneration: 9,
          rendererGeneration: 1,
          sequence: 11,
          amplitude: double.nan,
          generation: 1,
        ),
      );

      expect(
        replay.disposition,
        SelfAvatarProjectionDisposition.rejectedStaleSequence,
      );
      expect(
        invalid.disposition,
        SelfAvatarProjectionDisposition.rejectedInvalidInput,
      );
      expect(sink.dispatches, isEmpty);
    },
  );

  test(
    'renderer readiness replays static state but never an old envelope',
    () async {
      final sink = _RecordingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 2,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 2,
        rendererGeneration: 1,
        ready: false,
        sequence: 1,
      );
      final notReady = await service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 2,
          rendererGeneration: 1,
          sequence: 2,
          params: EmotionParams.excited,
        ),
      );
      await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 2,
          rendererGeneration: 1,
          sequence: 3,
          isSpeaking: true,
          generation: 1,
        ),
      );
      await service.project(
        SelfAvatarLipEnvelopeProjectionInput(
          accountGeneration: 2,
          rendererGeneration: 1,
          sequence: 4,
          envelope: const <double>[0.2, 0.9],
          frameRate: 24,
          generation: 1,
        ),
      );
      final replay = await service.bindRenderer(
        accountGeneration: 2,
        rendererGeneration: 2,
        ready: true,
        sequence: 5,
      );

      expect(
        notReady.disposition,
        SelfAvatarProjectionDisposition.rendererNotReady,
      );
      expect(replay.disposition, SelfAvatarProjectionDisposition.enforced);
      expect(sink.dispatches, hasLength(1));
      expect(sink.dispatches.single.expression, isNotNull);
      expect(sink.dispatches.single.lipEnvelope, isEmpty);
    },
  );

  test(
    'old speech generations cannot move or clear the current mouth',
    () async {
      final sink = _RecordingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 1,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        sequence: 1,
      );
      sink.dispatches.clear();
      await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 2,
          isSpeaking: true,
          generation: 20,
        ),
      );
      final oldFrame = await service.project(
        const SelfAvatarLipFrameProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 3,
          amplitude: 0.9,
          generation: 19,
        ),
      );
      final oldStop = await service.project(
        const SelfAvatarSpeakingProjectionInput(
          accountGeneration: 1,
          rendererGeneration: 1,
          sequence: 4,
          isSpeaking: false,
          generation: 19,
        ),
      );

      expect(
        oldFrame.disposition,
        SelfAvatarProjectionDisposition.rejectedStaleSpeech,
      );
      expect(
        oldStop.disposition,
        SelfAvatarProjectionDisposition.rejectedStaleSpeech,
      );
      expect(service.speechGeneration, 20);
      expect(sink.dispatches, hasLength(1));
      expect(sink.dispatches.single.stopLipSync, isFalse);
    },
  );

  test(
    'seal rejects late work and drain waits for admitted dispatch',
    () async {
      final sink = _BlockingDispatchSink();
      final service = SelfAvatarProjectionService(
        accountGeneration: 6,
        mode: () => FeatureRolloutMode.enforce,
        dispatchSink: sink,
      );
      await service.bindRenderer(
        accountGeneration: 6,
        rendererGeneration: 1,
        ready: true,
        sequence: 1,
      );
      sink.block = true;
      final admitted = service.project(
        const SelfAvatarEmotionProjectionInput(
          accountGeneration: 6,
          rendererGeneration: 1,
          sequence: 2,
          params: EmotionParams.calm,
        ),
      );
      await sink.started.future;

      var drained = false;
      final drain = service.sealAndDrain().then((_) => drained = true);
      final late = await service.project(
        const SelfAvatarMemeProjectionInput(
          accountGeneration: 6,
          rendererGeneration: 1,
          sequence: 3,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(service.isSealed, isTrue);
      expect(drained, isFalse);
      expect(late.disposition, SelfAvatarProjectionDisposition.rejectedSealed);
      sink.release.complete();
      expect(
        (await admitted).disposition,
        SelfAvatarProjectionDisposition.enforced,
      );
      await drain;
      expect(drained, isTrue);
    },
  );

  test('receipt history and envelope input are bounded', () async {
    final service = SelfAvatarProjectionService(
      accountGeneration: 0,
      mode: () => FeatureRolloutMode.off,
      dispatchSink: _RecordingDispatchSink(),
    );
    await service.bindRenderer(
      accountGeneration: 0,
      rendererGeneration: 0,
      ready: false,
      sequence: 1,
    );
    for (var sequence = 2; sequence <= 90; sequence++) {
      await service.project(
        SelfAvatarMemeProjectionInput(
          accountGeneration: 0,
          rendererGeneration: 0,
          sequence: sequence,
        ),
      );
    }

    expect(
      service.recentReceipts,
      hasLength(SelfAvatarProjectionService.maximumRecentReceipts),
    );
    expect(service.recentReceipts.first.sequence, 27);
    expect(
      () => SelfAvatarLipEnvelopeProjectionInput(
        accountGeneration: 0,
        rendererGeneration: 0,
        sequence: 91,
        envelope: List<double>.filled(
          SelfAvatarLipEnvelopeProjectionInput.maximumEnvelopeFrames + 1,
          0.5,
        ),
        frameRate: 30,
        generation: 1,
      ),
      throwsArgumentError,
    );
  });
}

class _RecordingDispatchSink implements SelfAvatarProjectionDispatchSink {
  final dispatches = <SelfAvatarProjectionDispatch>[];

  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch command) async {
    dispatches.add(command);
  }
}

final class _BlockingDispatchSink extends _RecordingDispatchSink {
  bool block = false;
  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch command) async {
    await super.dispatch(command);
    if (!block) return;
    if (!started.isCompleted) started.complete();
    await release.future;
  }
}

final class _RecordingComparator
    implements SelfAvatarProjectionShadowComparator {
  _RecordingComparator(SelfAvatarProjectionShadowComparison comparison)
    : _read = (() => comparison);

  _RecordingComparator.dynamic(
    SelfAvatarProjectionShadowComparison Function() read,
  ) : _read = read;

  final SelfAvatarProjectionShadowComparison Function() _read;
  final candidates = <SelfAvatarProjectionPlanSummary>[];

  @override
  Future<SelfAvatarProjectionShadowComparison> compare(
    SelfAvatarProjectionPlanSummary candidate,
  ) async {
    candidates.add(candidate);
    return _read();
  }
}
