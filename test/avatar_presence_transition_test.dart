import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  AvatarPresenceTransition request({
    String id = 'exit-1',
    String transaction = 'handoff-1',
    AvatarPresencePhase phase = AvatarPresencePhase.exit,
  }) => AvatarPresenceTransition(
    requestId: id,
    transitionId: transaction,
    phase: phase,
  );

  test(
    'missing active renderer fails instead of reporting completed movement',
    () async {
      await expectLater(
        ActiveAvatarRuntime().transitionPresence(request()),
        throwsUnsupportedError,
      );
    },
  );

  test('not ready fails without queueing a late visible movement', () async {
    final wire = _Transport();
    final runtime = UnityAvatarRuntime(transport: wire);
    await expectLater(
      runtime.transitionPresence(request()),
      throwsA(
        isA<AvatarPresenceTransitionException>().having(
          (e) => e.code,
          'code',
          'not_ready',
        ),
      ),
    );
    expect(wire.calls, isEmpty);
    runtime.onClose();
  });

  test(
    'waits for matching rendered receipt, not successful native send',
    () async {
      final wire = _Transport();
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      final active = ActiveAvatarRuntime()..register(runtime);
      var completed = false;
      final operation = active
          .transitionPresence(request())
          .then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      final packet = wire.calls.single.arguments as Map;
      expect(packet, containsPair('phase', 'exit'));
      expect(packet, containsPair('edge', 'left'));
      expect(packet['sequence'], greaterThan(0));
      expect(
        packet['expiresAtMs'],
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
      expect(await wire.result(request(), transaction: 'another'), isFalse);
      expect(await wire.result(request(), phase: 'enter'), isFalse);
      expect(completed, isFalse);
      await wire.result(request());
      await operation;
      expect(completed, isTrue);
      expect(await wire.result(request()), isFalse);
      runtime.onClose();
    },
  );

  for (final phase in AvatarPresencePhase.values) {
    test(
      'forwards ${phase.name} and stationary desktop walking unchanged',
      () async {
        final wire = _Transport();
        final runtime = UnityAvatarRuntime(transport: wire)
          ..isReady.value = true;
        final command = AvatarPresenceTransition(
          requestId: 'phase-${phase.name}',
          transitionId: 'desktop-1',
          phase: phase,
          edge: AvatarPresenceEdge.right,
          stationaryWalk: true,
          durationMs: 3000,
        );
        final operation = runtime.transitionPresence(command);
        expect(wire.calls.single.method, 'transitionPresence');
        expect(
          wire.calls.single.arguments,
          containsPair('stationaryWalk', true),
        );
        expect(wire.calls.single.arguments, containsPair('edge', 'right'));
        await wire.result(command);
        await operation;
        runtime.onClose();
      },
    );
  }

  test(
    'Home interruption fence reaches Unity without changing handoff defaults',
    () async {
      final wire = _Transport();
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      const command = AvatarPresenceTransition(
        requestId: 'home-prepare',
        transitionId: 'home-startup',
        phase: AvatarPresencePhase.prepare,
        doNotInterrupt: true,
      );
      final operation = runtime.transitionPresence(command);
      expect(wire.calls.single.arguments, containsPair('doNotInterrupt', true));
      expect(request().toJson(), containsPair('doNotInterrupt', false));
      await wire.result(command);
      await operation;
      runtime.onClose();
    },
  );

  test(
    'Unity rejection is an error and repeated request IDs are rejected',
    () async {
      final wire = _Transport();
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      final operation = runtime.transitionPresence(request());
      final expectation = expectLater(
        operation,
        throwsA(
          isA<AvatarPresenceTransitionException>().having(
            (e) => e.code,
            'code',
            'world_busy',
          ),
        ),
      );
      await wire.result(request(), ok: false, code: 'world_busy');
      await expectation;
      await expectLater(
        runtime.transitionPresence(request()),
        throwsA(
          isA<AvatarPresenceTransitionException>().having(
            (e) => e.code,
            'code',
            'duplicate_request',
          ),
        ),
      );
      runtime.onClose();
    },
  );

  for (final reason in ['unready', 'close']) {
    test(
      '$reason fails pending movement and ignores its late receipt',
      () async {
        final wire = _Transport();
        final runtime = UnityAvatarRuntime(transport: wire)
          ..isReady.value = true;
        final operation = runtime.transitionPresence(request());
        final expectation = expectLater(
          operation,
          throwsA(isA<AvatarPresenceTransitionException>()),
        );
        if (reason == 'unready') {
          await wire.handler!(
            const MethodCall('unready', {'reason': 'detached'}),
          );
        } else {
          runtime.onClose();
        }
        await expectation;
        if (reason == 'unready') {
          expect(await wire.result(request()), isFalse);
          runtime.onClose();
        }
      },
    );
  }

  testWidgets('timeout fences delayed entry with a newer holdHidden command', (
    tester,
  ) async {
    final wire = _Transport();
    final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
    const command = AvatarPresenceTransition(
      requestId: 'startup-enter-timeout',
      transitionId: 'startup-timeout',
      phase: AvatarPresencePhase.enter,
      doNotInterrupt: true,
    );
    final operation = runtime.transitionPresence(command);
    final expectation = expectLater(
      operation,
      throwsA(
        isA<AvatarPresenceTransitionException>().having(
          (e) => e.code,
          'code',
          'timeout',
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 7));
    await expectation;
    expect(wire.calls.length, 2);
    final first = wire.calls.first.arguments as Map;
    final fence = wire.calls.last.arguments as Map;
    expect(fence['phase'], 'holdHidden');
    expect(fence['transitionId'], first['transitionId']);
    expect(fence['doNotInterrupt'], isTrue);
    expect(fence['sequence'], greaterThan(first['sequence'] as int));
    expect(await wire.result(command), isFalse);
    runtime.onClose();
  });

  testWidgets(
    'long stationary exit keeps its complete motion receipt deadline',
    (tester) async {
      final wire = _Transport();
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      const command = AvatarPresenceTransition(
        requestId: 'long-exit',
        transitionId: 'handoff-long',
        phase: AvatarPresencePhase.exit,
        stationaryWalk: true,
        durationMs: 30000,
      );
      var completed = false;
      final before = DateTime.now().millisecondsSinceEpoch;
      final operation = runtime
          .transitionPresence(command)
          .then((_) => completed = true);
      final packet = wire.calls.single.arguments as Map;
      expect(
        packet['expiresAtMs'] as int,
        greaterThanOrEqualTo(before + 35000),
      );
      await tester.pump(const Duration(seconds: 20));
      expect(completed, isFalse);
      expect(wire.calls, hasLength(1), reason: 'no early holdHidden fence');
      await wire.result(command);
      await operation;
      expect(completed, isTrue);
      runtime.onClose();
    },
  );

  test('long duration is restricted to stationary departure', () {
    for (final phase in AvatarPresencePhase.values) {
      for (final stationary in [true, false]) {
        final command = AvatarPresenceTransition(
          requestId: 'boundary',
          transitionId: 'handoff-long',
          phase: phase,
          stationaryWalk: stationary,
          durationMs: 60000,
        );
        if (phase == AvatarPresencePhase.exit && stationary) {
          expect(command.validate, returnsNormally);
        } else {
          expect(command.validate, throwsArgumentError);
        }
      }
    }
    expect(
      const AvatarPresenceTransition(
        requestId: 'too-long',
        transitionId: 'handoff-long',
        phase: AvatarPresencePhase.exit,
        stationaryWalk: true,
        durationMs: 60001,
      ).validate,
      throwsArgumentError,
    );
  });

  test(
    'transport failure is not turned into a successful completion',
    () async {
      final wire = _Transport()
        ..error = PlatformException(code: 'native_missing');
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      await expectLater(
        runtime.transitionPresence(request()),
        throwsA(isA<PlatformException>()),
      );
      runtime.onClose();
    },
  );

  test(
    'invalid identifiers and out of bounds durations never reach native',
    () async {
      final wire = _Transport();
      final runtime = UnityAvatarRuntime(transport: wire)..isReady.value = true;
      for (final command in [
        request(id: '../exit'),
        const AvatarPresenceTransition(
          requestId: 'low',
          transitionId: 'one',
          phase: AvatarPresencePhase.exit,
          durationMs: 299,
        ),
        const AvatarPresenceTransition(
          requestId: 'high',
          transitionId: 'one',
          phase: AvatarPresencePhase.exit,
          durationMs: 3001,
        ),
      ]) {
        await expectLater(
          runtime.transitionPresence(command),
          throwsArgumentError,
        );
      }
      expect(wire.calls, isEmpty);
      runtime.onClose();
    },
  );
}

class _Transport implements UnityAvatarTransport {
  final calls = <MethodCall>[];
  UnityAvatarMethodCallHandler? handler;
  Object? error;

  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add(MethodCall(method, arguments));
    if (error != null) throw error!;
    return null;
  }

  Future<dynamic> result(
    AvatarPresenceTransition request, {
    String? transaction,
    String? phase,
    bool ok = true,
    String code = '',
  }) => handler!(
    MethodCall('commandResult', {
      'method': 'transitionPresence',
      'requestId': request.requestId,
      'transitionId': transaction ?? request.transitionId,
      'phase': phase ?? request.phase.name,
      'ok': ok,
      'code': code,
    }),
  );

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) =>
      this.handler = handler;

  @override
  void dispose() => handler = null;
}
