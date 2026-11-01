import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('missing renderer fails explicitly', () async {
    await expectLater(
      ActiveAvatarRuntime().setPhoneInteraction(
        interactionId: 'one',
        phase: AvatarPhoneInteractionPhase.reading,
      ),
      throwsUnsupportedError,
    );
  });
  test('invalid ID and unready renderer never queue a visible phone', () async {
    final wire = _Wire();
    final runtime = UnityAvatarRuntime(transport: wire);
    for (final id in ['../invalid', '', 'one']) {
      await expectLater(
        runtime.setPhoneInteraction(
          interactionId: id,
          phase: AvatarPhoneInteractionPhase.reading,
        ),
        throwsA(isA<AvatarPhoneInteractionException>()),
      );
    }
    expect(wire.calls, isEmpty);
    runtime.onClose();
  });
  test('requires exact Unity action receipt, not native delivery', () async {
    final wire = _Wire();
    final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
    final active = ActiveAvatarRuntime()..register(runtime);
    bool complete = false;
    final future = active
        .setPhoneInteraction(
          interactionId: 'inbox:one',
          phase: AvatarPhoneInteractionPhase.reading,
        )
        .then((_) => complete = true);
    await Future<void>.delayed(Duration.zero);
    final packet = wire.calls.single.arguments as Map;
    expect(complete, isFalse);
    expect(packet['phase'], 'reading');
    expect(packet['sequence'], 1);
    expect(
      packet['expiresAtMs'],
      greaterThan(DateTime.now().millisecondsSinceEpoch),
    );
    expect(
      await wire.reply(packet, changes: {'interactionId': 'wrong'}),
      isFalse,
    );
    expect(await wire.reply(packet, changes: {'phase': 'none'}), isFalse);
    expect(complete, isFalse);
    expect(await wire.reply(packet), isTrue);
    await future;
    expect(complete, isTrue);
    expect(await wire.reply(packet), isFalse);
    runtime.onClose();
  });
  test(
    'superseded reading is a failure while the new reply can complete',
    () async {
      final wire = _Wire();
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      final first = runtime.setPhoneInteraction(
        interactionId: 'one',
        phase: AvatarPhoneInteractionPhase.reading,
      );
      final failure = expectLater(
        first,
        throwsA(
          isA<AvatarPhoneInteractionException>().having(
            (e) => e.code,
            'code',
            'superseded',
          ),
        ),
      );
      final second = runtime.setPhoneInteraction(
        interactionId: 'one',
        phase: AvatarPhoneInteractionPhase.replying,
      );
      await wire.reply(
        wire.calls.first.arguments as Map,
        changes: {'ok': false, 'code': 'superseded'},
      );
      await failure;
      await wire.reply(wire.calls.last.arguments as Map);
      await second;
      runtime.onClose();
    },
  );
  test('renderer loss fails pending action and ignores late success', () async {
    final wire = _Wire();
    final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
    final future = runtime.setPhoneInteraction(
      interactionId: 'one',
      phase: AvatarPhoneInteractionPhase.reading,
    );
    final expectation = expectLater(
      future,
      throwsA(isA<AvatarPhoneInteractionException>()),
    );
    final packet = wire.calls.single.arguments as Map;
    await wire.handler!(const MethodCall('unready', {'reason': 'detached'}));
    await expectation;
    expect(await wire.reply(packet), isFalse);
    runtime.onClose();
  });
  test('transport failure is not success', () async {
    final wire = _Wire()..fail = true;
    final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
    await expectLater(
      runtime.setPhoneInteraction(
        interactionId: 'one',
        phase: AvatarPhoneInteractionPhase.reading,
      ),
      throwsA(isA<PlatformException>()),
    );
    runtime.onClose();
  });
  testWidgets('timeout fences only its own interaction with a newer stop', (
    tester,
  ) async {
    final wire = _Wire();
    final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
    final future = runtime.setPhoneInteraction(
      interactionId: 'old',
      phase: AvatarPhoneInteractionPhase.reading,
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<AvatarPhoneInteractionException>().having(
          (e) => e.code,
          'code',
          'timeout',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 6));
    await expectation;
    final first = wire.calls.first.arguments as Map;
    final stop = wire.calls.last.arguments as Map;
    expect(stop['interactionId'], 'old');
    expect(stop['phase'], 'none');
    expect(stop['sequence'], greaterThan(first['sequence'] as int));
    expect(await wire.reply(first), isFalse);
    runtime.onClose();
  });
  test('close cancels pending phone animation', () async {
    final wire = _Wire();
    final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
    final future = runtime.setPhoneInteraction(
      interactionId: 'one',
      phase: AvatarPhoneInteractionPhase.reading,
    );
    final expectation = expectLater(
      future,
      throwsA(
        isA<AvatarPhoneInteractionException>().having(
          (e) => e.code,
          'code',
          'runtime_closed',
        ),
      ),
    );
    runtime.onClose();
    await expectation;
  });
}

class _Wire implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  Future<dynamic> Function(MethodCall)? handler;
  bool fail = false;
  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (fail) throw PlatformException(code: 'missing_host');
    return null;
  }

  @override
  void setMethodCallHandler(Future<dynamic> Function(MethodCall)? value) =>
      handler = value;
  Future<dynamic> reply(
    Map packet, {
    Map<String, dynamic> changes = const {},
  }) => handler!(
    MethodCall('commandResult', {
      'method': 'setPhoneInteraction',
      'requestId': packet['requestId'],
      'interactionId': packet['interactionId'],
      'phase': packet['phase'],
      'ok': true,
      'code': 'completed',
      ...changes,
    }),
  );
  @override
  Future<void> dispose() async {}
}
