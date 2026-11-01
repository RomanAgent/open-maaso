import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_command_dispatch_sink.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'ticketed envelope to clock replacement never clears the mouth channel',
    () async {
      final transport = _FakeTransport();
      final sink = UnityAvatarCommandDispatchSink(
        transport: transport,
        rendererReady: () => true,
      );
      transport.onInvoke = (call) {
        scheduleMicrotask(
          () => sink.handleCommandResult(_successReceipt(call)),
        );
      };
      final arbiter = await _boundArbiter(sink);
      addTearDown(arbiter.onClose);
      final commands = <AvatarChannelCommand>[
        AvatarLipEnvelopeCommand([0.1, 0.8, 0], frameRate: 30),
        for (var i = 0; i < 5; i++)
          AvatarSpeechPlaybackClockCommand(
            SpeechPlaybackClock(
              playbackId: 'wav-bound',
              generation: 1234567890123456,
              turnId: 'turn',
              utteranceId: 'u',
              sequence: i + 1,
              state: i == 0
                  ? SpeechPlaybackClockState.start
                  : SpeechPlaybackClockState.update,
              positionMs: i * 250,
              durationMs: 1500,
              source: SpeechPlaybackClockSource.wav,
              authoritative: i > 0,
              envelope: i == 0 ? [0.1, 0.8, 0] : [],
              frameRate: i == 0 ? 30 : null,
            ),
          ),
      ];
      for (final (index, command) in commands.indexed) {
        final receipt = await arbiter.acquire(
          AvatarCommandLeaseRequest(
            accountGeneration: 7,
            rendererGeneration: 1,
            commandGeneration: index + 1,
            leaseId: 'tts-$index',
            source: AvatarCommandSource.ttsMouth,
            command: command,
            ttl: const Duration(seconds: 2),
          ),
        );
        expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatched);
      }
      expect(
        transport.calls,
        hasLength(6),
        reason: 'no intermediate neutral-clear command is allowed',
      );
      final payloads = <Map<String, dynamic>>[];
      for (final call in transport.calls) {
        expect(call.method, UnityAvatarCommandDispatchSink.commandMethod);
        final arguments = Map<String, dynamic>.from(call.arguments as Map);
        expect(arguments['clearsChannel'], false);
        expect(arguments['channel'], 'mouth');
        payloads.add(
          jsonDecode(arguments['payloadJson'] as String)
              as Map<String, dynamic>,
        );
      }
      expect(payloads.first['envelope'], [0.1, 0.8, 0]);
      expect((payloads[1]['playbackClock'] as Map)['envelope'], [0.1, 0.8, 0]);
      expect(
        payloads
            .skip(1)
            .map((payload) => (payload['playbackClock'] as Map)['sequence']),
        [1, 2, 3, 4, 5],
      );
      expect(sink.pendingReceiptCount, 0);
    },
  );

  test('completes only after an exact post-mutation Unity receipt', () async {
    final transport = _FakeTransport();
    late final UnityAvatarCommandDispatchSink sink;
    sink = UnityAvatarCommandDispatchSink(
      transport: transport,
      rendererReady: () => true,
    );
    transport.onInvoke = (call) {
      expect(call.method, UnityAvatarCommandDispatchSink.commandMethod);
      expect(sink.pendingReceiptCount, 1);
      scheduleMicrotask(() => sink.handleCommandResult(_successReceipt(call)));
    };
    final arbiter = await _boundArbiter(sink);
    addTearDown(arbiter.onClose);

    final receipt = await arbiter.acquire(_mouthRequest(generation: 1));

    expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatched);
    expect(transport.calls, hasLength(1));
    expect(sink.pendingReceiptCount, 0);
  });

  test(
    'ignores forged acknowledgement fields until the exact ACK arrives',
    () async {
      final transport = _FakeTransport();
      final sink = UnityAvatarCommandDispatchSink(
        transport: transport,
        rendererReady: () => true,
        maximumReceiptWait: const Duration(milliseconds: 200),
      );
      final arbiter = await _boundArbiter(
        sink,
        dispatchTimeout: const Duration(milliseconds: 300),
      );
      addTearDown(arbiter.onClose);

      final pending = arbiter.acquire(_mouthRequest(generation: 1));
      await _waitForCalls(transport, 1);
      final call = transport.calls.single;
      final forged = _successReceipt(call)..['commitToken'] = 'x' * 43;
      final extraField = _successReceipt(call)..['unexpected'] = true;
      final invalidSuccessCode = _successReceipt(call)
        ..['code'] = 'mutation_failed';

      expect(sink.handleCommandResult(forged), isFalse);
      expect(sink.handleCommandResult(extraField), isFalse);
      expect(sink.handleCommandResult(invalidSuccessCode), isFalse);
      expect(sink.pendingReceiptCount, 1);
      expect(sink.handleCommandResult(_successReceipt(call)), isTrue);
      expect(
        (await pending).disposition,
        AvatarCommandReceiptDisposition.dispatched,
      );
    },
  );

  test(
    'timeout and late ACK fail closed behind the renderer reset gate',
    () async {
      final transport = _FakeTransport();
      final sink = UnityAvatarCommandDispatchSink(
        transport: transport,
        rendererReady: () => true,
        maximumReceiptWait: const Duration(milliseconds: 20),
      );
      final arbiter = await _boundArbiter(
        sink,
        dispatchTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(arbiter.onClose);

      final failed = await arbiter.acquire(_mouthRequest(generation: 1));
      final lateCall = transport.calls.single;

      expect(
        failed.disposition,
        AvatarCommandReceiptDisposition.dispatchFailed,
      );
      expect(arbiter.pendingRendererReset, isNotNull);
      expect(sink.handleCommandResult(_successReceipt(lateCall)), isFalse);
      final fenced = await arbiter.acquire(_mouthRequest(generation: 2));
      expect(
        fenced.disposition,
        AvatarCommandReceiptDisposition.rendererResetRequired,
      );
      expect(transport.calls, hasLength(1));
    },
  );

  test('stale and explicit Unity rejection cannot mint a receipt', () async {
    final transport = _FakeTransport();
    late final UnityAvatarCommandDispatchSink sink;
    sink = UnityAvatarCommandDispatchSink(
      transport: transport,
      rendererReady: () => true,
    );
    transport.onInvoke = (call) {
      scheduleMicrotask(
        () => sink.handleCommandResult(
          _receipt(call, ok: false, code: 'stale_ticket'),
        ),
      );
    };
    final arbiter = await _boundArbiter(sink);
    addTearDown(arbiter.onClose);

    final receipt = await arbiter.acquire(_mouthRequest(generation: 1));

    expect(receipt.disposition, AvatarCommandReceiptDisposition.dispatchFailed);
    expect(arbiter.pendingRendererReset, isNotNull);
  });

  test(
    'trusted reset requires real Unity ACK and transfers generation',
    () async {
      final transport = _FakeTransport();
      late final UnityAvatarCommandDispatchSink sink;
      var acknowledge = false;
      sink = UnityAvatarCommandDispatchSink(
        transport: transport,
        rendererReady: () => true,
        maximumReceiptWait: const Duration(milliseconds: 20),
      );
      transport.onInvoke = (call) {
        if (!acknowledge) return;
        scheduleMicrotask(
          () => sink.handleCommandResult(_successReceipt(call)),
        );
      };
      final arbiter = await _boundArbiter(
        sink,
        dispatchTimeout: const Duration(milliseconds: 100),
      );
      addTearDown(arbiter.onClose);
      await arbiter.acquire(_mouthRequest(generation: 1));
      expect(arbiter.pendingRendererReset, isNotNull);

      acknowledge = true;
      await arbiter.resetRendererForMount(
        accountGeneration: 7,
        rendererGeneration: 2,
      );
      final bind = await arbiter.bindRenderer(
        accountGeneration: 7,
        rendererGeneration: 2,
        ready: true,
      );

      expect(arbiter.pendingRendererReset, isNull);
      expect(arbiter.rendererGeneration, 2);
      expect(
        bind.where(
          (receipt) =>
              receipt.disposition == AvatarCommandReceiptDisposition.dispatched,
        ),
        isNotEmpty,
      );
      expect(
        transport.calls.map((call) => call.method),
        contains(UnityAvatarCommandDispatchSink.resetMethod),
      );
    },
  );

  test(
    'renderer unready and close complete pending receipts with fixed errors',
    () async {
      final transport = _FakeTransport();
      var ready = true;
      final sink = UnityAvatarCommandDispatchSink(
        transport: transport,
        rendererReady: () => ready,
        maximumReceiptWait: const Duration(seconds: 1),
      );
      final arbiter = await _boundArbiter(
        sink,
        dispatchTimeout: const Duration(seconds: 2),
      );
      addTearDown(arbiter.onClose);

      final pending = arbiter.acquire(_mouthRequest(generation: 1));
      await _waitForCalls(transport, 1);
      ready = false;
      sink.markRendererUnavailable();

      expect(
        (await pending).disposition,
        AvatarCommandReceiptDisposition.dispatchFailed,
      );
      expect(sink.pendingReceiptCount, 0);
      sink.close();
      expect(sink.isClosed, isTrue);
    },
  );

  test(
    'expression payload is canonicalized with mouthOpen permanently zero',
    () async {
      final transport = _FakeTransport();
      late final UnityAvatarCommandDispatchSink sink;
      sink = UnityAvatarCommandDispatchSink(
        transport: transport,
        rendererReady: () => true,
      );
      transport.onInvoke = (call) {
        scheduleMicrotask(
          () => sink.handleCommandResult(_successReceipt(call)),
        );
      };
      final arbiter = await _boundArbiter(sink);
      addTearDown(arbiter.onClose);

      await arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: 7,
          rendererGeneration: 1,
          commandGeneration: 1,
          leaseId: 'expression-1',
          source: AvatarCommandSource.explicitAgent,
          command: const AvatarExpressionCommand(
            AvatarExpressionParams(happy: 0.8, mouthOpen: 0.9),
          ),
          ttl: const Duration(seconds: 1),
        ),
      );

      final arguments =
          transport.calls.single.arguments as Map<String, Object?>;
      final payload =
          jsonDecode(arguments['payloadJson']! as String)
              as Map<String, dynamic>;
      expect((payload['params'] as Map<String, dynamic>)['mouthOpen'], 0);
    },
  );

  test('lip envelopes use only the mouth channel', () {
    final command = AvatarLipEnvelopeCommand(const <double>[
      0.1,
      0.6,
      0.2,
    ], frameRate: 24);

    expect(command.channel, AvatarCommandChannel.mouth);
    expect(command.toCanonicalJson()['frameRate'], 24);
    expect(
      () => AvatarLipEnvelopeCommand(List<double>.filled(7201, 0.1)),
      throwsArgumentError,
    );
  });
}

Future<AvatarCommandArbiter> _boundArbiter(
  AvatarCommandDispatchSink sink, {
  Duration dispatchTimeout = const Duration(milliseconds: 500),
}) async {
  final arbiter = AvatarCommandArbiter(
    accountGeneration: 7,
    dispatchSink: sink,
    dispatchTimeout: dispatchTimeout,
  );
  final receipts = await arbiter.bindRenderer(
    accountGeneration: 7,
    rendererGeneration: 1,
    ready: true,
  );
  expect(receipts, isEmpty);
  return arbiter;
}

AvatarCommandLeaseRequest _mouthRequest({required int generation}) =>
    AvatarCommandLeaseRequest(
      accountGeneration: 7,
      rendererGeneration: 1,
      commandGeneration: generation,
      leaseId: 'mouth-$generation',
      source: AvatarCommandSource.ttsMouth,
      command: AvatarMouthCommand(0.4),
      ttl: const Duration(seconds: 2),
    );

Map<String, dynamic> _successReceipt(MethodCall call) =>
    _receipt(call, ok: true, code: '');

Map<String, dynamic> _receipt(
  MethodCall call, {
  required bool ok,
  required String code,
}) {
  final arguments = Map<String, dynamic>.from(
    call.arguments! as Map<Object?, Object?>,
  )..remove('payloadJson');
  return <String, dynamic>{
    ...arguments,
    'method': call.method,
    'ok': ok,
    'code': code,
  };
}

Future<void> _waitForCalls(_FakeTransport transport, int count) async {
  for (
    var attempt = 0;
    attempt < 100 && transport.calls.length < count;
    attempt++
  ) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  expect(transport.calls, hasLength(count));
}

final class _FakeTransport implements UnityAvatarTransport {
  final List<MethodCall> calls = <MethodCall>[];
  void Function(MethodCall call)? onInvoke;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    final call = MethodCall(method, arguments);
    calls.add(call);
    onInvoke?.call(call);
    return null;
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {}

  @override
  void dispose() {}
}
