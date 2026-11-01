import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

void main() {
  test(
    'priority preempts and release restores the next channel lease',
    () async {
      final sink = _RecordingSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );

      for (final (index, source) in <AvatarCommandSource>[
        AvatarCommandSource.idle,
        AvatarCommandSource.auto,
        AvatarCommandSource.scene,
        AvatarCommandSource.explicitAgent,
        AvatarCommandSource.explicitUser,
      ].indexed) {
        final receipt = await arbiter.acquire(
          _lease(
            source: source,
            commandGeneration: index + 1,
            command: AvatarFramingCommand('frame_${source.name}'),
          ),
        );
        expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatched);
        expect(receipt.selectedSource, source);
      }

      final retained = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 20,
          command: AvatarFramingCommand('late_scene'),
        ),
      );
      expect(
        retained.disposition,
        AvatarCommandReceiptDisposition.retainedBehindHigherPriority,
      );
      expect(sink.dispatches, hasLength(5));

      final released = await arbiter.release(
        const AvatarCommandReleaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 5,
          channel: AvatarCommandChannel.framing,
          source: AvatarCommandSource.explicitUser,
        ),
      );
      expect(released.disposition, AvatarCommandReceiptDisposition.released);
      expect(released.selectedSource, AvatarCommandSource.explicitAgent);
      expect(sink.dispatches.last.source, AvatarCommandSource.explicitAgent);
    },
  );

  test('TTS owns mouth while body remains independent', () async {
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );

    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.ttsMouth,
        commandGeneration: 1,
        command: AvatarMouthCommand(0.72),
      ),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
      ),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: const AvatarExpressionCommand(
          AvatarExpressionParams(happy: 1, mouthOpen: 0.99),
        ),
      ),
    );

    expect(sink.dispatches, hasLength(3));
    expect(sink.dispatches[0].channel, AvatarCommandChannel.mouth);
    expect(sink.dispatches[1].channel, AvatarCommandChannel.bodyGesture);
    final expression = sink.dispatches[2].command! as AvatarExpressionCommand;
    expect(expression.params.happy, 1);
    expect(expression.params.mouthOpen, 0);

    final invalidTts = await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.ttsMouth,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('jump'),
      ),
    );
    expect(
      invalidTts.disposition,
      AvatarCommandReceiptDisposition.rejectedInvalidSource,
    );
    expect(sink.dispatches, hasLength(3));
  });

  test('mouth rejects non-TTS sources and TTS release clears it', () async {
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 2,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 2,
      rendererGeneration: 4,
      ready: true,
    );
    final rejectedUser = await arbiter.acquire(
      _lease(
        accountGeneration: 2,
        rendererGeneration: 4,
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: AvatarMouthCommand(0.2),
      ),
    );
    expect(
      rejectedUser.disposition,
      AvatarCommandReceiptDisposition.rejectedInvalidSource,
    );
    expect(sink.dispatches, isEmpty);
    final rejectedRelease = await arbiter.release(
      const AvatarCommandReleaseRequest(
        accountGeneration: 2,
        rendererGeneration: 4,
        commandGeneration: 1,
        channel: AvatarCommandChannel.mouth,
        source: AvatarCommandSource.explicitUser,
      ),
    );
    expect(
      rejectedRelease.disposition,
      AvatarCommandReceiptDisposition.rejectedInvalidSource,
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 2,
        rendererGeneration: 4,
        source: AvatarCommandSource.ttsMouth,
        commandGeneration: 9,
        command: AvatarMouthCommand(0.8),
      ),
    );

    expect(
      (sink.dispatches.last.command! as AvatarMouthCommand).value,
      closeTo(0.8, 1e-9),
    );
    final released = await arbiter.release(
      const AvatarCommandReleaseRequest(
        accountGeneration: 2,
        rendererGeneration: 4,
        commandGeneration: 9,
        channel: AvatarCommandChannel.mouth,
        source: AvatarCommandSource.ttsMouth,
      ),
    );
    expect(released.selectedSource, isNull);
    expect(sink.dispatches.last.clearsChannel, isTrue);
  });

  test('TTL expiry dispatches the next eligible lease', () async {
    final clock = _FakeClock(DateTime.utc(2026, 8, 30));
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      clock: clock.call,
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'breathe', 'wave'}),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.idle,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('breathe'),
        ttl: const Duration(minutes: 2),
      ),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
        ttl: const Duration(seconds: 1),
      ),
    );

    clock.advance(const Duration(seconds: 2));
    final receipts = await arbiter.expireLeases();

    expect(receipts, hasLength(1));
    expect(
      receipts.single.disposition,
      AvatarCommandReceiptDisposition.expired,
    );
    expect(receipts.single.selectedSource, AvatarCommandSource.idle);
    expect(
      (sink.dispatches.last.command! as AvatarBodyGestureCommand).gesture,
      'breathe',
    );
  });

  test('not-ready retains commands and capabilities choose fallback', () async {
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 3,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 3,
      rendererGeneration: 2,
      ready: false,
    );
    final idle = await arbiter.acquire(
      _lease(
        accountGeneration: 3,
        rendererGeneration: 2,
        source: AvatarCommandSource.idle,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('breathe'),
      ),
    );
    final user = await arbiter.acquire(
      _lease(
        accountGeneration: 3,
        rendererGeneration: 2,
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('dance'),
      ),
    );

    expect(<AvatarCommandReceiptDisposition>[
      idle.disposition,
      user.disposition,
    ], everyElement(AvatarCommandReceiptDisposition.rendererNotReady));
    expect(sink.dispatches, isEmpty);

    final fallback = await arbiter.bindRenderer(
      accountGeneration: 3,
      rendererGeneration: 2,
      ready: true,
      capabilities: AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
        supportedBodyGestures: const <String>{'breathe'},
      ),
    );
    expect(fallback, hasLength(1));
    expect(
      fallback.single.disposition,
      AvatarCommandReceiptDisposition.capabilityFallback,
    );
    expect(fallback.single.selectedSource, AvatarCommandSource.idle);
    expect(sink.dispatches.single.source, AvatarCommandSource.idle);

    final restored = await arbiter.bindRenderer(
      accountGeneration: 3,
      rendererGeneration: 2,
      ready: true,
      capabilities: AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
        supportedBodyGestures: const <String>{'breathe', 'dance'},
      ),
    );
    expect(
      restored.single.disposition,
      AvatarCommandReceiptDisposition.dispatched,
    );
    expect(restored.single.selectedSource, AvatarCommandSource.explicitUser);
    expect(sink.dispatches.last.source, AvatarCommandSource.explicitUser);
  });

  test('generation fences reject stale commands with zero writes', () async {
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 8,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 8,
      rendererGeneration: 5,
      ready: true,
    );
    final wrongAccount = await arbiter.acquire(
      _lease(
        accountGeneration: 7,
        rendererGeneration: 5,
        source: AvatarCommandSource.auto,
        commandGeneration: 1,
        command: AvatarGazeCommand(_gaze),
      ),
    );
    final wrongRenderer = await arbiter.acquire(
      _lease(
        accountGeneration: 8,
        rendererGeneration: 4,
        source: AvatarCommandSource.auto,
        commandGeneration: 1,
        command: AvatarGazeCommand(_gaze),
      ),
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 8,
        rendererGeneration: 5,
        source: AvatarCommandSource.auto,
        commandGeneration: 3,
        command: AvatarGazeCommand(_gaze),
      ),
    );
    final writes = sink.dispatches.length;
    final replay = await arbiter.acquire(
      _lease(
        accountGeneration: 8,
        rendererGeneration: 5,
        source: AvatarCommandSource.auto,
        commandGeneration: 3,
        command: AvatarGazeCommand(_gaze),
      ),
    );

    expect(
      wrongAccount.disposition,
      AvatarCommandReceiptDisposition.rejectedStaleAccount,
    );
    expect(
      wrongRenderer.disposition,
      AvatarCommandReceiptDisposition.rejectedStaleRenderer,
    );
    expect(
      replay.disposition,
      AvatarCommandReceiptDisposition.rejectedStaleCommand,
    );
    expect(sink.dispatches, hasLength(writes));
  });

  test('release without fallback clears only its channel', () async {
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarFramingCommand('full'),
      ),
    );
    await arbiter.release(
      const AvatarCommandReleaseRequest(
        accountGeneration: 1,
        rendererGeneration: 1,
        commandGeneration: 1,
        channel: AvatarCommandChannel.framing,
        source: AvatarCommandSource.scene,
      ),
    );

    expect(sink.dispatches, hasLength(2));
    expect(sink.dispatches.last.channel, AvatarCommandChannel.framing);
    expect(sink.dispatches.last.clearsChannel, isTrue);
  });

  test(
    'capability loss clears a previously applied supported channel',
    () async {
      final sink = _RecordingSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        capabilities: AvatarCommandCapabilities(
          supportedChannels: const <AvatarCommandChannel>{
            AvatarCommandChannel.bodyGesture,
          },
          supportedBodyGestures: const <String>{'wave'},
        ),
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.explicitAgent,
          commandGeneration: 1,
          command: AvatarBodyGestureCommand('wave'),
        ),
      );

      final receipts = await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        capabilities: AvatarCommandCapabilities(
          supportedChannels: const <AvatarCommandChannel>{
            AvatarCommandChannel.bodyGesture,
          },
          supportedBodyGestures: const <String>{'breathe'},
        ),
      );

      expect(receipts, hasLength(1));
      expect(
        receipts.single.disposition,
        AvatarCommandReceiptDisposition.capabilityUnavailable,
      );
      expect(sink.dispatches, hasLength(2));
      expect(sink.dispatches.last.clearsChannel, isTrue);
    },
  );

  test('receipts are bounded and sealed arbiter rejects late work', () async {
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 0,
      dispatchSink: _RecordingSink(),
    );
    await arbiter.bindRenderer(
      accountGeneration: 0,
      rendererGeneration: 0,
      ready: false,
    );
    for (var generation = 1; generation <= 80; generation++) {
      await arbiter.acquire(
        _lease(
          accountGeneration: 0,
          rendererGeneration: 0,
          source: AvatarCommandSource.auto,
          commandGeneration: generation,
          command: AvatarFramingCommand('compact'),
        ),
      );
    }
    await arbiter.sealAndDrain();
    final late = await arbiter.acquire(
      _lease(
        accountGeneration: 0,
        rendererGeneration: 0,
        source: AvatarCommandSource.auto,
        commandGeneration: 81,
        command: AvatarFramingCommand('compact'),
      ),
    );

    expect(
      arbiter.recentReceipts,
      hasLength(AvatarCommandArbiter.maximumRecentReceipts),
    );
    expect(late.disposition, AvatarCommandReceiptDisposition.rejectedSealed);
    expect(
      arbiter.recentReceipts.every(
        (receipt) =>
            receipt.fingerprint.isEmpty || receipt.fingerprint.length == 16,
      ),
      isTrue,
    );
  });

  test(
    'invalid expression and gaze are rejected before generation mutation',
    () async {
      final sink = _RecordingSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );

      final invalidExpression = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.explicitUser,
          commandGeneration: 1,
          command: const AvatarExpressionCommand(
            AvatarExpressionParams(happy: double.nan),
          ),
        ),
      );
      expect(
        invalidExpression.disposition,
        AvatarCommandReceiptDisposition.rejectedInvalidCommand,
      );
      expect(sink.dispatches, isEmpty);

      final validExpression = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.explicitUser,
          commandGeneration: 1,
          command: const AvatarExpressionCommand(
            AvatarExpressionParams(happy: 3, sad: -2, mouthOpen: 0.8),
          ),
        ),
      );
      expect(
        validExpression.disposition,
        AvatarCommandReceiptDisposition.dispatched,
      );
      final expression =
          sink.dispatches.single.command! as AvatarExpressionCommand;
      expect(expression.params.happy, 1);
      expect(expression.params.sad, 0);
      expect(expression.params.mouthOpen, 0);

      final invalidGaze = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.auto,
          commandGeneration: 1,
          command: const AvatarGazeCommand(
            AvatarGaze(eyeX: double.infinity, eyeY: 0, headX: 0, headY: 0),
          ),
        ),
      );
      expect(
        invalidGaze.disposition,
        AvatarCommandReceiptDisposition.rejectedInvalidCommand,
      );

      final validGaze = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.auto,
          commandGeneration: 1,
          command: const AvatarGazeCommand(
            AvatarGaze(eyeX: 4, eyeY: -4, headX: 2, headY: -2),
          ),
        ),
      );
      expect(validGaze.disposition, AvatarCommandReceiptDisposition.dispatched);
      final gaze = sink.dispatches.last.command! as AvatarGazeCommand;
      expect(gaze.gaze.eyeX, 1);
      expect(gaze.gaze.eyeY, -1);
      expect(gaze.gaze.headX, 1);
      expect(gaze.gaze.headY, -1);
    },
  );

  test('timed-out dispatch cannot apply late or poison the queue', () async {
    final sink = _HeldFirstSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      dispatchTimeout: const Duration(milliseconds: 10),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );

    final timedOut = await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: AvatarFramingCommand('first'),
      ),
    );
    expect(
      timedOut.disposition,
      AvatarCommandReceiptDisposition.dispatchFailed,
    );

    final recovered = await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 2,
        command: AvatarFramingCommand('second'),
      ),
    );
    expect(recovered.disposition, AvatarCommandReceiptDisposition.dispatched);
    expect(sink.applied, hasLength(1));
    expect(
      (sink.applied.single.command! as AvatarFramingCommand).mode,
      'second',
    );

    expect(sink.operations.first.applyIfCurrent(sink.applied.add), isNull);
    sink.completeHeld();
    await Future<void>.delayed(Duration.zero);
    expect(sink.applied, hasLength(1));
  });

  test('seal revokes a held dispatch and rejects queued admission', () async {
    final sink = _HeldFirstSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      dispatchTimeout: const Duration(milliseconds: 10),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );
    final held = arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: AvatarFramingCommand('held'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final queued = arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 2,
        command: AvatarFramingCommand('queued'),
      ),
    );

    await arbiter.sealAndDrain();
    expect(
      (await held).disposition,
      AvatarCommandReceiptDisposition.dispatchFailed,
    );
    expect(
      (await queued).disposition,
      AvatarCommandReceiptDisposition.rejectedSealed,
    );
    expect(sink.operations.single.applyIfCurrent(sink.applied.add), isNull);
    sink.completeHeld();
    expect(sink.applied, isEmpty);
  });

  test('seal clears a command whose sink applied before timing out', () async {
    final sink = _ApplyThenHangFirstSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      dispatchTimeout: const Duration(milliseconds: 10),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );

    final receipt = await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
      ),
    );
    expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatchFailed);
    expect(sink.applied.single.clearsChannel, isFalse);

    await arbiter.sealAndDrain();
    expect(sink.applied.last.channel, AvatarCommandChannel.bodyGesture);
    expect(sink.applied.last.clearsChannel, isTrue);
    sink.completeHeld();
  });

  test(
    'TTS is the only mouth owner across update release expiry and rebind',
    () async {
      final clock = _FakeClock(DateTime.utc(2026, 8, 30));
      final scheduler = _ManualExpiryScheduler();
      final sink = _RecordingSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
        clock: clock.call,
        scheduleExpiry: scheduler.schedule,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: const AvatarExpressionCommand(
            AvatarExpressionParams(happy: 0.6, mouthOpen: 0.9),
          ),
        ),
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.ttsMouth,
          commandGeneration: 1,
          command: AvatarMouthCommand(0.7),
          ttl: const Duration(seconds: 1),
        ),
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.ttsMouth,
          commandGeneration: 2,
          command: AvatarMouthCommand(0.8),
          ttl: const Duration(seconds: 1),
        ),
      );
      expect((sink.dispatches.last.command! as AvatarMouthCommand).value, 0.8);
      expect(
        (sink.dispatches
                    .firstWhere(
                      (dispatch) =>
                          dispatch.channel == AvatarCommandChannel.expression,
                    )
                    .command!
                as AvatarExpressionCommand)
            .params
            .mouthOpen,
        0,
      );

      await arbiter.release(
        const AvatarCommandReleaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 2,
          channel: AvatarCommandChannel.mouth,
          source: AvatarCommandSource.ttsMouth,
        ),
      );
      expect(sink.dispatches.last.clearsChannel, isTrue);

      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.ttsMouth,
          commandGeneration: 3,
          command: AvatarMouthCommand(0.9),
          ttl: const Duration(seconds: 1),
        ),
      );
      clock.advance(const Duration(seconds: 2));
      scheduler.fireCurrent();
      await arbiter.waitForIdle();
      expect(sink.dispatches.last.channel, AvatarCommandChannel.mouth);
      expect(sink.dispatches.last.clearsChannel, isTrue);

      final beforeRebind = sink.dispatches.length;
      final resetRequired = await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      );
      expect(
        resetRequired.single.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );
      await arbiter.resetRendererForMount(
        accountGeneration: 1,
        rendererGeneration: 2,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      );
      final rebound = sink.dispatches.skip(beforeRebind).toList();
      expect(
        rebound.map((dispatch) => dispatch.channel),
        <AvatarCommandChannel>[AvatarCommandChannel.expression],
      );
      final reboundExpression =
          rebound
                  .firstWhere(
                    (dispatch) =>
                        dispatch.channel == AvatarCommandChannel.expression,
                  )
                  .command!
              as AvatarExpressionCommand;
      expect(reboundExpression.params.mouthOpen, 0);
      expect(scheduler.activeCount, 1);
      await arbiter.sealAndDrain();
      expect(scheduler.activeCount, 0);
    },
  );

  test('seal clears every applied channel and fences late admission', () async {
    final scheduler = _ManualExpiryScheduler();
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 4,
      dispatchSink: sink,
      scheduleExpiry: scheduler.schedule,
    );
    await arbiter.bindRenderer(
      accountGeneration: 4,
      rendererGeneration: 2,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 4,
        rendererGeneration: 2,
        source: AvatarCommandSource.ttsMouth,
        commandGeneration: 1,
        command: AvatarMouthCommand(0.5),
      ),
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 4,
        rendererGeneration: 2,
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
      ),
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 4,
        rendererGeneration: 2,
        source: AvatarCommandSource.auto,
        commandGeneration: 1,
        command: AvatarGazeCommand(_gaze),
      ),
    );
    final beforeSeal = sink.dispatches.length;

    await arbiter.sealAndDrain();
    final clears = sink.dispatches
        .skip(beforeSeal)
        .where((dispatch) => dispatch.clearsChannel)
        .toList();
    expect(
      clears.map((dispatch) => dispatch.channel).toSet(),
      <AvatarCommandChannel>{
        AvatarCommandChannel.mouth,
        AvatarCommandChannel.bodyGesture,
        AvatarCommandChannel.gaze,
      },
    );
    expect(scheduler.activeCount, 0);

    final late = await arbiter.acquire(
      _lease(
        accountGeneration: 4,
        rendererGeneration: 2,
        source: AvatarCommandSource.explicitUser,
        commandGeneration: 1,
        command: AvatarFramingCommand('late'),
      ),
    );
    expect(late.disposition, AvatarCommandReceiptDisposition.rejectedSealed);
    expect(sink.dispatches.length, beforeSeal + 3);
  });

  test('seal continues clearing after one channel clear times out', () async {
    final sink = _HangFirstClearSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 9,
      dispatchSink: sink,
      dispatchTimeout: const Duration(milliseconds: 10),
    );
    await arbiter.bindRenderer(
      accountGeneration: 9,
      rendererGeneration: 3,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 9,
        rendererGeneration: 3,
        source: AvatarCommandSource.ttsMouth,
        commandGeneration: 1,
        command: AvatarMouthCommand(0.4),
      ),
    );
    await arbiter.acquire(
      _lease(
        accountGeneration: 9,
        rendererGeneration: 3,
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
      ),
    );

    final sealing = arbiter.sealAndDrain();
    final next = AvatarCommandArbiter(
      accountGeneration: 10,
      dispatchSink: sink,
    );
    final blocked = await next.bindRenderer(
      accountGeneration: 10,
      rendererGeneration: 4,
      ready: true,
    );
    expect(
      blocked.single.disposition,
      AvatarCommandReceiptDisposition.rendererResetRequired,
    );
    await expectLater(
      sealing,
      throwsA(isA<AvatarRendererResetRequiredException>()),
    );
    expect(
      sink.applied
          .where((dispatch) => dispatch.clearsChannel)
          .map((dispatch) => dispatch.channel),
      contains(AvatarCommandChannel.bodyGesture),
    );
    expect(sink.heldClear!.applyIfCurrent(sink.applied.add), isNull);
    sink.completeHeld();

    final requirement = arbiter.pendingRendererReset!;
    expect(requirement.dirtyChannels, <AvatarCommandChannel>{
      AvatarCommandChannel.mouth,
    });
    final mounted = await next.bindRenderer(
      accountGeneration: 10,
      rendererGeneration: 4,
      ready: true,
    );
    expect(
      mounted.single.disposition,
      AvatarCommandReceiptDisposition.rendererResetRequired,
    );
    await next.resetRendererForMount(
      accountGeneration: 10,
      rendererGeneration: 4,
    );
    expect(
      await next.bindRenderer(
        accountGeneration: 10,
        rendererGeneration: 4,
        ready: true,
      ),
      isEmpty,
    );
  });

  test('removing and restoring a channel forces redispatch', () async {
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
        supportedBodyGestures: const <String>{'wave'},
      ),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.explicitAgent,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
      ),
    );
    expect(sink.dispatches, hasLength(1));

    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: AvatarCommandCapabilities(supportedChannels: const {}),
    );
    expect(sink.dispatches, hasLength(2));
    expect(sink.dispatches.last.clearsChannel, isTrue);

    final restored = await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
        supportedBodyGestures: const <String>{'wave'},
      ),
    );
    expect(
      restored.single.disposition,
      AvatarCommandReceiptDisposition.dispatched,
    );
    expect(sink.dispatches, hasLength(3));
    expect(
      (sink.dispatches.last.command! as AvatarBodyGestureCommand).gesture,
      'wave',
    );
  });

  test('expired lease cannot apply after sink preparation delay', () async {
    final clock = _FakeClock(DateTime.utc(2026, 8, 30));
    final sink = _DelayedApplySink(
      delay: const Duration(milliseconds: 20),
      beforeApply: () => clock.advance(const Duration(milliseconds: 20)),
    );
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      clock: clock.call,
      dispatchTimeout: const Duration(milliseconds: 100),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );

    final receipt = await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
        ttl: const Duration(milliseconds: 10),
      ),
    );

    expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatchFailed);
    expect(sink.operations.single.validUntil!.isBefore(clock.value), isTrue);
    expect(sink.applied, isEmpty);
  });

  test('renderer bind intent synchronously fences delayed dispatch', () async {
    final sink = _DelayedApplySink(
      delay: const Duration(milliseconds: 20),
      beforeApply: () {},
    );
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      dispatchTimeout: const Duration(milliseconds: 100),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );

    final acquire = arbiter.acquire(
      _lease(
        source: AvatarCommandSource.auto,
        commandGeneration: 1,
        command: AvatarGazeCommand(_gaze),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    final unavailable = arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: false,
    );

    expect(
      (await acquire).disposition,
      AvatarCommandReceiptDisposition.dispatchFailed,
    );
    await unavailable;
    expect(sink.applied, isEmpty);
  });

  test(
    'renderer receipt is fenced to the exact ticket and desired state',
    () async {
      final sink = _ReplayReceiptSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('first'),
        ),
      );

      final replayed = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 2,
          command: AvatarFramingCommand('second'),
        ),
      );
      expect(
        replayed.disposition,
        AvatarCommandReceiptDisposition.dispatchFailed,
      );
      expect(
        (sink.applied.last.command! as AvatarFramingCommand).mode,
        'second',
      );
      await arbiter.sealAndDrain();
      expect(sink.applied.last.clearsChannel, isTrue);
    },
  );

  test('ready to unavailable neutralizes before a lease can expire', () async {
    final clock = _FakeClock(DateTime.utc(2026, 8, 30));
    final scheduler = _ManualExpiryScheduler();
    final sink = _RecordingSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      clock: clock.call,
      scheduleExpiry: scheduler.schedule,
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
        ttl: const Duration(seconds: 1),
      ),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: false,
    );
    expect(sink.dispatches, hasLength(2));
    expect(sink.dispatches.last.channel, AvatarCommandChannel.bodyGesture);
    expect(sink.dispatches.last.clearsChannel, isTrue);
    clock.advance(const Duration(seconds: 2));
    scheduler.fireCurrent();
    await arbiter.waitForIdle();
    expect(sink.dispatches, hasLength(2));

    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );
    expect(sink.dispatches, hasLength(2));
  });

  test(
    'unconfirmed ready to unavailable clear blocks remount until trusted reset',
    () async {
      final sink = _HangFirstClearSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
        dispatchTimeout: const Duration(milliseconds: 10),
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
        capabilities: _bodyCapabilities(const <String>{'wave'}),
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarBodyGestureCommand('wave'),
        ),
      );

      final unavailable = await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: false,
      );
      expect(
        unavailable.map((receipt) => receipt.disposition),
        containsAll(<AvatarCommandReceiptDisposition>[
          AvatarCommandReceiptDisposition.dispatchFailed,
          AvatarCommandReceiptDisposition.rendererResetRequired,
        ]),
      );
      expect(arbiter.rendererReady, isFalse);
      expect(
        (await arbiter.bindRenderer(
          accountGeneration: 1,
          rendererGeneration: 1,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );

      final next = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
      );
      expect(
        (await next.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );
      sink.completeHeld();
      await next.resetRendererForMount(
        accountGeneration: 2,
        rendererGeneration: 2,
      );
      expect(
        await next.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        ),
        isEmpty,
      );
    },
  );

  test('uncertain neutral clear cannot dedupe a restored lease', () async {
    final sink = _HangFirstClearSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
      dispatchTimeout: const Duration(milliseconds: 10),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarBodyGestureCommand('wave'),
      ),
    );
    final unavailable = await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: AvatarCommandCapabilities(supportedChannels: const {}),
    );
    expect(
      unavailable.single.disposition,
      AvatarCommandReceiptDisposition.dispatchFailed,
    );
    expect(sink.applied.last.clearsChannel, isTrue);
    sink.completeHeld();

    final restored = await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
      capabilities: _bodyCapabilities(const <String>{'wave'}),
    );
    expect(
      restored.single.disposition,
      AvatarCommandReceiptDisposition.dispatched,
    );
    expect(sink.applied.last.clearsChannel, isFalse);
    expect(
      (sink.applied.last.command! as AvatarBodyGestureCommand).gesture,
      'wave',
    );
    await arbiter.sealAndDrain();
  });

  test(
    'renderer write then callback throw is dirty and never deduped',
    () async {
      final sink = _WriteThenThrowFirstSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      final failed = await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('full'),
        ),
      );
      expect(
        failed.disposition,
        AvatarCommandReceiptDisposition.dispatchFailed,
      );
      expect(sink.applied, hasLength(1));

      final rebound = await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      expect(
        rebound.single.disposition,
        AvatarCommandReceiptDisposition.dispatched,
      );
      expect(sink.applied, hasLength(2));
      await arbiter.sealAndDrain();
      expect(sink.applied.last.clearsChannel, isTrue);
    },
  );

  test(
    'dirty renderer generation change requires a one-time reset receipt',
    () async {
      final sink = _RecordingSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('full'),
        ),
      );

      final blocked = await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      );
      expect(
        blocked.single.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );
      await expectLater(
        arbiter.resetRendererForMount(
          accountGeneration: 1,
          rendererGeneration: 1,
        ),
        throwsA(isA<AvatarRendererResetFailedException>()),
      );
      await arbiter.resetRendererForMount(
        accountGeneration: 1,
        rendererGeneration: 2,
      );

      final rebound = await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      );
      expect(
        rebound.single.disposition,
        AvatarCommandReceiptDisposition.dispatched,
      );
      expect(sink.dispatches, hasLength(2));
      expect(sink.dispatches.last.rendererGeneration, 2);

      await expectLater(
        arbiter.resetRendererForMount(
          accountGeneration: 1,
          rendererGeneration: 2,
        ),
        throwsA(isA<AvatarRendererResetFailedException>()),
      );
    },
  );

  test('reset callback failure cannot mint proof or unblock mount', () async {
    final sink = _FailResetOnceSink();
    final arbiter = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );
    await arbiter.acquire(
      _lease(
        source: AvatarCommandSource.scene,
        commandGeneration: 1,
        command: AvatarFramingCommand('full'),
      ),
    );
    await arbiter.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 2,
      ready: true,
    );

    await expectLater(
      arbiter.resetRendererForMount(
        accountGeneration: 1,
        rendererGeneration: 2,
      ),
      throwsA(isA<AvatarRendererResetFailedException>()),
    );
    expect(arbiter.rendererGeneration, 1);
    expect(arbiter.pendingRendererReset, isNotNull);
    expect(
      (await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      )).single.disposition,
      AvatarCommandReceiptDisposition.rendererResetRequired,
    );

    await arbiter.resetRendererForMount(
      accountGeneration: 1,
      rendererGeneration: 2,
    );
    expect(arbiter.rendererGeneration, 2);
    expect(
      (await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      )).single.disposition,
      AvatarCommandReceiptDisposition.dispatched,
    );
  });

  test(
    'stale reset receipt cannot advance the losing arbiter generation',
    () async {
      final sink = _ResetRaceSink();
      final retired = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      await retired.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await retired.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('full'),
        ),
      );
      await retired.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 2,
        ready: true,
      );

      final losing = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
      );
      final winning = AvatarCommandArbiter(
        accountGeneration: 3,
        dispatchSink: sink,
      );
      sink.winning = winning;

      await expectLater(
        losing.resetRendererForMount(
          accountGeneration: 2,
          rendererGeneration: 2,
        ),
        throwsA(isA<AvatarRendererResetFailedException>()),
      );

      expect(losing.rendererGeneration, 0);
      expect(winning.rendererGeneration, 3);
      expect(losing.pendingRendererReset, isNull);
    },
  );

  test('body gesture capability list has a fail-closed fixed bound', () {
    expect(
      AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
      ).supports(AvatarBodyGestureCommand('wave')),
      isFalse,
    );
    final allowed = <String>{
      for (
        var index = 0;
        index < AvatarCommandCapabilities.maximumSupportedBodyGestures;
        index++
      )
        'gesture_$index',
    };
    expect(
      AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
        supportedBodyGestures: allowed,
      ).supportedBodyGestures,
      hasLength(AvatarCommandCapabilities.maximumSupportedBodyGestures),
    );
    expect(
      () => AvatarCommandCapabilities(
        supportedChannels: const <AvatarCommandChannel>{
          AvatarCommandChannel.bodyGesture,
        },
        supportedBodyGestures: <String>{...allowed, 'one_too_many'},
      ),
      throwsArgumentError,
    );
  });

  test(
    'one shared sink has exactly one active arbiter owner until clean seal',
    () async {
      final sink = _RecordingSink();
      final first = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      final second = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
      );

      expect(
        await first.bindRenderer(
          accountGeneration: 1,
          rendererGeneration: 1,
          ready: true,
        ),
        isEmpty,
      );
      expect(
        (await second.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(sink.dispatches, isEmpty);

      await first.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('first-owner'),
        ),
      );
      expect(sink.dispatches, hasLength(1));
      await first.sealAndDrain();
      expect(sink.dispatches, hasLength(2));
      expect(sink.dispatches.last.clearsChannel, isTrue);

      expect(
        await second.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        ),
        isEmpty,
      );
      await second.acquire(
        _lease(
          accountGeneration: 2,
          rendererGeneration: 2,
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('second-owner'),
        ),
      );
      expect(sink.dispatches, hasLength(3));

      final writesBeforeOldOwnerRetry = sink.dispatches.length;
      expect(
        (await first.acquire(
          _lease(
            source: AvatarCommandSource.scene,
            commandGeneration: 2,
            command: AvatarFramingCommand('stale-first-owner'),
          ),
        )).disposition,
        AvatarCommandReceiptDisposition.rejectedSealed,
      );
      expect(sink.dispatches, hasLength(writesBeforeOldOwnerRetry));
      await second.sealAndDrain();
    },
  );

  test(
    'owner-rejected acquire leaves no command to dispatch after handoff',
    () async {
      final sink = _RecordingSink();
      final blockedScheduler = _ManualExpiryScheduler();
      final current = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
      );
      final blocked = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
        scheduleExpiry: blockedScheduler.schedule,
      );
      await current.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      expect(
        (await blocked.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );

      final rejected = await blocked.acquire(
        _lease(
          accountGeneration: 2,
          rendererGeneration: 0,
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('must-not-be-retained'),
        ),
      );
      expect(
        rejected.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(rejected.activeLeaseCount, 0);
      expect(blockedScheduler.activeCount, 0);

      await current.sealAndDrain();
      expect(
        await blocked.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        ),
        isEmpty,
      );
      expect(sink.dispatches, isEmpty);

      final admitted = await blocked.acquire(
        _lease(
          accountGeneration: 2,
          rendererGeneration: 2,
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('fresh-after-handoff'),
        ),
      );
      expect(admitted.disposition, AvatarCommandReceiptDisposition.dispatched);
      expect(sink.dispatches, hasLength(1));
      expect(
        (sink.dispatches.single.command! as AvatarFramingCommand).mode,
        'fresh-after-handoff',
      );
      await blocked.sealAndDrain();
    },
  );

  test(
    'owner-rejected release does not remove the retired owner lease',
    () async {
      final sink = _HangFirstClearSink();
      final scheduler = _ManualExpiryScheduler();
      final retired = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
        scheduleExpiry: scheduler.schedule,
        dispatchTimeout: const Duration(milliseconds: 10),
      );
      await retired.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await retired.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('retained-by-retired-owner'),
        ),
      );
      await retired.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: false,
      );

      final next = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
      );
      sink.completeHeld();
      await next.resetRendererForMount(
        accountGeneration: 2,
        rendererGeneration: 2,
      );
      final writesBeforeRelease = sink.applied.length;
      final activeSchedulesBeforeRelease = scheduler.activeCount;

      final rejected = await retired.release(
        const AvatarCommandReleaseRequest(
          accountGeneration: 1,
          rendererGeneration: 1,
          commandGeneration: 1,
          channel: AvatarCommandChannel.framing,
          source: AvatarCommandSource.scene,
        ),
      );
      expect(
        rejected.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(rejected.activeLeaseCount, 1);
      expect(scheduler.activeCount, activeSchedulesBeforeRelease);
      expect(sink.applied, hasLength(writesBeforeRelease));

      await next.bindRenderer(
        accountGeneration: 2,
        rendererGeneration: 2,
        ready: true,
      );
      await next.sealAndDrain();
    },
  );

  test(
    'reset transfer permanently retires old owner and enforces generation high-water',
    () async {
      final sink = _HangFirstClearSink();
      final oldOwner = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
        dispatchTimeout: const Duration(milliseconds: 10),
      );
      await oldOwner.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await oldOwner.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('old-owner'),
        ),
      );
      final unavailable = await oldOwner.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: false,
      );
      expect(
        unavailable.map((receipt) => receipt.disposition),
        contains(AvatarCommandReceiptDisposition.rendererResetRequired),
      );

      final nextOwner = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
      );
      sink.completeHeld();
      await nextOwner.resetRendererForMount(
        accountGeneration: 2,
        rendererGeneration: 2,
      );
      final writesAfterTransfer = sink.applied.length;

      expect(
        (await oldOwner.bindRenderer(
          accountGeneration: 1,
          rendererGeneration: 1,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(
        (await oldOwner.acquire(
          _lease(
            source: AvatarCommandSource.scene,
            commandGeneration: 2,
            command: AvatarFramingCommand('old-owner-race'),
          ),
        )).disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(sink.applied, hasLength(writesAfterTransfer));

      expect(
        await nextOwner.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        ),
        isEmpty,
      );
      await nextOwner.acquire(
        _lease(
          accountGeneration: 2,
          rendererGeneration: 2,
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('next-owner'),
        ),
      );
      expect(sink.applied, hasLength(writesAfterTransfer + 1));
      await nextOwner.sealAndDrain();
      final writesAfterNextOwnerSeal = sink.applied.length;

      expect(
        (await oldOwner.bindRenderer(
          accountGeneration: 1,
          rendererGeneration: 1,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(
        (await oldOwner.acquire(
          _lease(
            source: AvatarCommandSource.scene,
            commandGeneration: 3,
            command: AvatarFramingCommand('retired-owner-after-clean-seal'),
          ),
        )).disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(sink.applied, hasLength(writesAfterNextOwnerSeal));

      final successor = AvatarCommandArbiter(
        accountGeneration: 3,
        dispatchSink: sink,
      );
      expect(
        (await successor.bindRenderer(
          accountGeneration: 3,
          rendererGeneration: 2,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
      );
      expect(sink.applied, hasLength(writesAfterNextOwnerSeal));
      expect(
        await successor.bindRenderer(
          accountGeneration: 3,
          rendererGeneration: 3,
          ready: true,
        ),
        isEmpty,
      );
      await successor.acquire(
        _lease(
          accountGeneration: 3,
          rendererGeneration: 3,
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('higher-generation-successor'),
        ),
      );
      expect(sink.applied, hasLength(writesAfterNextOwnerSeal + 1));
      await successor.sealAndDrain();
    },
  );

  test(
    'failed seal and reset keep owner locked until reset succeeds',
    () async {
      final sink = _FailFirstClearAndResetOnceSink();
      final oldOwner = AvatarCommandArbiter(
        accountGeneration: 1,
        dispatchSink: sink,
        dispatchTimeout: const Duration(milliseconds: 20),
      );
      await oldOwner.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await oldOwner.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('dirty-owner'),
        ),
      );
      await expectLater(
        oldOwner.sealAndDrain(),
        throwsA(isA<AvatarRendererResetRequiredException>()),
      );

      final nextOwner = AvatarCommandArbiter(
        accountGeneration: 2,
        dispatchSink: sink,
      );
      expect(
        (await nextOwner.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );
      await expectLater(
        nextOwner.resetRendererForMount(
          accountGeneration: 2,
          rendererGeneration: 2,
        ),
        throwsA(isA<AvatarRendererResetFailedException>()),
      );
      expect(
        (await nextOwner.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        )).single.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );

      await nextOwner.resetRendererForMount(
        accountGeneration: 2,
        rendererGeneration: 2,
      );
      expect(
        await nextOwner.bindRenderer(
          accountGeneration: 2,
          rendererGeneration: 2,
          ready: true,
        ),
        isEmpty,
      );
      final writesAfterRecovery = sink.applied.length;
      expect(
        (await oldOwner.acquire(
          _lease(
            source: AvatarCommandSource.scene,
            commandGeneration: 2,
            command: AvatarFramingCommand('retired-owner'),
          ),
        )).disposition,
        AvatarCommandReceiptDisposition.rejectedSealed,
      );
      expect(sink.applied, hasLength(writesAfterRecovery));
      await nextOwner.sealAndDrain();
    },
  );

  test('owner retirement remains bounded across repeated handoffs', () async {
    final sink = _RecordingSink();
    final first = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    final staleDormant = AvatarCommandArbiter(
      accountGeneration: 99,
      dispatchSink: sink,
    );
    await first.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );
    await first.sealAndDrain();

    for (var generation = 2; generation <= 40; generation++) {
      final owner = AvatarCommandArbiter(
        accountGeneration: generation,
        dispatchSink: sink,
      );
      expect(
        await owner.bindRenderer(
          accountGeneration: generation,
          rendererGeneration: generation,
          ready: true,
        ),
        isEmpty,
      );
      await owner.sealAndDrain();
    }

    expect(
      (await staleDormant.bindRenderer(
        accountGeneration: 99,
        rendererGeneration: 100,
        ready: true,
      )).single.disposition,
      AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
    );
    final fresh = AvatarCommandArbiter(
      accountGeneration: 41,
      dispatchSink: sink,
    );
    expect(
      await fresh.bindRenderer(
        accountGeneration: 41,
        rendererGeneration: 41,
        ready: true,
      ),
      isEmpty,
    );
    await fresh.sealAndDrain();
    expect(sink.dispatches, isEmpty);
  });

  test('receipt fingerprints are salted per arbiter instance', () async {
    final first = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: _RecordingSink(),
      scheduleExpiry: _ManualExpiryScheduler().schedule,
    );
    final second = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: _RecordingSink(),
      scheduleExpiry: _ManualExpiryScheduler().schedule,
    );
    for (final arbiter in <AvatarCommandArbiter>[first, second]) {
      await arbiter.bindRenderer(
        accountGeneration: 1,
        rendererGeneration: 1,
        ready: true,
      );
      await arbiter.acquire(
        _lease(
          source: AvatarCommandSource.scene,
          commandGeneration: 1,
          command: AvatarFramingCommand('full'),
        ),
      );
    }

    expect(first.recentReceipts.last.fingerprint, hasLength(16));
    expect(second.recentReceipts.last.fingerprint, hasLength(16));
    expect(
      first.recentReceipts.last.fingerprint,
      isNot(second.recentReceipts.last.fingerprint),
    );
    await first.sealAndDrain();
    await second.sealAndDrain();
  });

  test('late forced retirement cannot fence a newer renderer owner', () async {
    final sink = _RecordingSink();
    final first = AvatarCommandArbiter(
      accountGeneration: 1,
      dispatchSink: sink,
    );
    await first.bindRenderer(
      accountGeneration: 1,
      rendererGeneration: 1,
      ready: true,
    );
    await first.acquire(
      _lease(
        source: AvatarCommandSource.ttsMouth,
        commandGeneration: 1,
        command: AvatarMouthCommand(0.4),
      ),
    );
    await first.sealAndDrain();

    final second = AvatarCommandArbiter(
      accountGeneration: 2,
      dispatchSink: sink,
    );
    expect(
      await second.bindRenderer(
        accountGeneration: 2,
        rendererGeneration: 2,
        ready: true,
      ),
      isEmpty,
    );
    expect(
      (await second.acquire(
        _lease(
          accountGeneration: 2,
          rendererGeneration: 2,
          source: AvatarCommandSource.ttsMouth,
          commandGeneration: 1,
          command: AvatarMouthCommand(0.6),
        ),
      )).disposition,
      AvatarCommandReceiptDisposition.dispatched,
    );

    await first.sealAndDrain(requireRendererResetForNextOwner: true);

    expect(second.pendingRendererReset, isNull);
    expect(
      (await second.acquire(
        _lease(
          accountGeneration: 2,
          rendererGeneration: 2,
          source: AvatarCommandSource.ttsMouth,
          commandGeneration: 2,
          command: AvatarMouthCommand(0.7),
        ),
      )).disposition,
      AvatarCommandReceiptDisposition.dispatched,
    );
    await second.sealAndDrain();
  });
}

const _gaze = AvatarGaze(eyeX: 0.1, eyeY: 0, headX: 0, headY: 0);

AvatarCommandCapabilities _bodyCapabilities(Set<String> gestures) =>
    AvatarCommandCapabilities(
      supportedChannels: AvatarCommandChannel.values.toSet(),
      supportedBodyGestures: gestures,
    );

AvatarCommandLeaseRequest _lease({
  int accountGeneration = 1,
  int rendererGeneration = 1,
  required AvatarCommandSource source,
  required int commandGeneration,
  required AvatarChannelCommand command,
  Duration ttl = const Duration(minutes: 1),
}) => AvatarCommandLeaseRequest(
  accountGeneration: accountGeneration,
  rendererGeneration: rendererGeneration,
  commandGeneration: commandGeneration,
  leaseId: '${command.channel.name}_${source.name}_$commandGeneration',
  source: source,
  command: command,
  ttl: ttl,
);

abstract base class _TestSink implements AvatarCommandDispatchSink {
  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    final receipt = operation.resetOrDisposeIfCurrent(() {});
    if (receipt == null) {
      throw StateError('reset operation is no longer current');
    }
    return receipt;
  }
}

final class _RecordingSink extends _TestSink {
  final dispatches = <AvatarCommandDispatch>[];

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    return _apply(operation, dispatches);
  }
}

final class _HeldFirstSink extends _TestSink {
  final operations = <AvatarCommandDispatchOperation>[];
  final applied = <AvatarCommandDispatch>[];
  final Completer<AvatarCommandDispatchReceipt> _held =
      Completer<AvatarCommandDispatchReceipt>();

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) {
    operations.add(operation);
    if (operations.length == 1) return _held.future;
    return Future<AvatarCommandDispatchReceipt>.value(
      _apply(operation, applied),
    );
  }

  void completeHeld() {
    if (!_held.isCompleted) _held.completeError(StateError('held released'));
  }
}

final class _HangFirstClearSink extends _TestSink {
  final applied = <AvatarCommandDispatch>[];
  final Completer<AvatarCommandDispatchReceipt> _held =
      Completer<AvatarCommandDispatchReceipt>();
  AvatarCommandDispatchOperation? heldClear;
  AvatarCommandDispatchReceipt? _heldReceipt;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) {
    if (operation.dispatch.clearsChannel && heldClear == null) {
      heldClear = operation;
      _heldReceipt = _apply(operation, applied);
      return _held.future;
    }
    return Future<AvatarCommandDispatchReceipt>.value(
      _apply(operation, applied),
    );
  }

  void completeHeld() {
    if (!_held.isCompleted) _held.complete(_heldReceipt!);
  }
}

final class _ApplyThenHangFirstSink extends _TestSink {
  final applied = <AvatarCommandDispatch>[];
  final Completer<AvatarCommandDispatchReceipt> _held =
      Completer<AvatarCommandDispatchReceipt>();
  AvatarCommandDispatchReceipt? _firstReceipt;
  var _first = true;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) {
    final receipt = _apply(operation, applied);
    if (_first) {
      _first = false;
      _firstReceipt = receipt;
      return _held.future;
    }
    return Future<AvatarCommandDispatchReceipt>.value(receipt);
  }

  void completeHeld() {
    if (!_held.isCompleted) _held.complete(_firstReceipt!);
  }
}

final class _DelayedApplySink extends _TestSink {
  _DelayedApplySink({required this.delay, required this.beforeApply});

  final Duration delay;
  final void Function() beforeApply;
  final operations = <AvatarCommandDispatchOperation>[];
  final applied = <AvatarCommandDispatch>[];

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    operations.add(operation);
    await Future<void>.delayed(delay);
    beforeApply();
    return _apply(operation, applied);
  }
}

final class _ReplayReceiptSink extends _TestSink {
  final applied = <AvatarCommandDispatch>[];
  AvatarCommandDispatchReceipt? _first;
  var _nonClearCount = 0;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    final current = _apply(operation, applied);
    if (operation.dispatch.clearsChannel) return current;
    _nonClearCount += 1;
    if (_nonClearCount == 1) {
      _first = current;
      return current;
    }
    return _first!;
  }
}

final class _WriteThenThrowFirstSink extends _TestSink {
  final applied = <AvatarCommandDispatch>[];
  var _first = true;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    if (_first) {
      _first = false;
      try {
        operation.applyIfCurrent((dispatch) {
          applied.add(dispatch);
          throw StateError('renderer failed after partial write');
        });
      } on Object {
        rethrow;
      }
    }
    return _apply(operation, applied);
  }
}

final class _FailResetOnceSink extends _TestSink {
  final dispatches = <AvatarCommandDispatch>[];
  var _failReset = true;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async => _apply(operation, dispatches);

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    if (_failReset) {
      _failReset = false;
      operation.resetOrDisposeIfCurrent(() {
        throw StateError('renderer reset failed after mutation began');
      });
      throw StateError('unreachable');
    }
    return super.resetOrDispose(operation);
  }
}

final class _ResetRaceSink extends _TestSink {
  final dispatches = <AvatarCommandDispatch>[];
  late AvatarCommandArbiter winning;
  var _firstReset = true;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async => _apply(operation, dispatches);

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    if (!_firstReset) return super.resetOrDispose(operation);
    _firstReset = false;
    final stale = operation.resetOrDisposeIfCurrent(() {});
    if (stale == null) throw StateError('reset operation was stale');
    await winning.resetRendererForMount(
      accountGeneration: 3,
      rendererGeneration: 3,
    );
    return stale;
  }
}

final class _FailFirstClearAndResetOnceSink extends _TestSink {
  final applied = <AvatarCommandDispatch>[];
  var _failClear = true;
  var _failReset = true;

  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    if (operation.dispatch.clearsChannel && _failClear) {
      _failClear = false;
      operation.applyIfCurrent((dispatch) {
        applied.add(dispatch);
        throw StateError('clear acknowledgement failed after renderer write');
      });
      throw StateError('unreachable');
    }
    return _apply(operation, applied);
  }

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async {
    if (_failReset) {
      _failReset = false;
      operation.resetOrDisposeIfCurrent(() {
        throw StateError('reset failed after renderer mutation began');
      });
      throw StateError('unreachable');
    }
    return super.resetOrDispose(operation);
  }
}

AvatarCommandDispatchReceipt _apply(
  AvatarCommandDispatchOperation operation,
  List<AvatarCommandDispatch> applied,
) {
  final receipt = operation.applyIfCurrent(applied.add);
  if (receipt == null) throw StateError('dispatch ticket is no longer current');
  return receipt;
}

final class _ManualExpiryScheduler {
  final handles = <_ManualExpiryHandle>[];

  int get activeCount => handles.where((handle) => !handle.cancelled).length;

  AvatarLeaseExpiryHandle schedule(Duration delay, void Function() callback) {
    final handle = _ManualExpiryHandle(delay, callback);
    handles.add(handle);
    return handle;
  }

  void fireCurrent() {
    final handle = handles.lastWhere((candidate) => !candidate.cancelled);
    handle.cancelled = true;
    handle.callback();
  }
}

final class _ManualExpiryHandle implements AvatarLeaseExpiryHandle {
  _ManualExpiryHandle(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;

  @override
  void cancel() {
    cancelled = true;
  }
}

final class _FakeClock {
  _FakeClock(this.value);

  DateTime value;

  DateTime call() => value;

  void advance(Duration duration) {
    value = value.add(duration);
  }
}
