import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_doorway_transition.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_doorway_transitions.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_transport.dart';

class _Wire implements UnityAvatarTransport {
  final calls = <({String method, Object? args})>[];
  @override
  Future<T?> invokeMethod<T>(String method, [Object? arguments]) async {
    calls.add((method: method, args: arguments));
    return null;
  }

  @override
  void setMethodCallHandler(UnityAvatarMethodCallHandler? handler) {}
  @override
  void dispose() {}
}

void main() {
  testWidgets(
    'bedroom framing keeps its receipt open through a safe interior route',
    (tester) async {
      final wire = _Wire();
      final transitions = UnityAvatarDoorwayTransitions(wire, () => true);
      addTearDown(transitions.close);
      var complete = false;
      final operation = transitions
          .run(
            const AvatarDoorwayTransition(
              requestId: 'bedroom-frame',
              transitionId: 'entry',
              phase: AvatarDoorwayPhase.frame,
              durationMs: 300,
            ),
          )
          .then((_) => complete = true);
      await tester.pump(const Duration(seconds: 6));
      expect(complete, isFalse);
      expect(wire.calls.length, 1);
      transitions.handleResult({
        'requestId': 'bedroom-frame',
        'transitionId': 'entry',
        'phase': 'frame',
        'ok': true,
      });
      await operation;
      expect(complete, isTrue);
    },
  );
  test(
    'native enqueue acknowledgment cannot complete a doorway phase',
    () async {
      final wire = _Wire();
      final transitions = UnityAvatarDoorwayTransitions(wire, () => true);
      addTearDown(transitions.close);
      const request = AvatarDoorwayTransition(
        requestId: 'req-1',
        transitionId: 'entry-1',
        phase: AvatarDoorwayPhase.prepare,
      );
      var completed = false;
      final operation = transitions.run(request).then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      expect(wire.calls.single.method, 'transitionLoginDoorway');
      expect(
        transitions.handleResult({
          'requestId': 'req-1',
          'transitionId': 'wrong',
          'phase': 'prepare',
          'ok': true,
        }),
        isFalse,
      );
      expect(completed, isFalse);
      expect(
        transitions.handleResult({
          'requestId': 'req-1',
          'transitionId': 'entry-1',
          'phase': 'prepare',
          'ok': true,
        }),
        isTrue,
      );
      await operation;
      expect(completed, isTrue);
      await expectLater(
        transitions.run(request),
        throwsA(isA<AvatarDoorwayTransitionException>()),
      );
    },
  );
  test(
    'renderer invalidation fails pending work and ignores its late receipt',
    () async {
      final transitions = UnityAvatarDoorwayTransitions(_Wire(), () => true);
      addTearDown(transitions.close);
      final operation = transitions.run(
        const AvatarDoorwayTransition(
          requestId: 'req',
          transitionId: 'entry',
          phase: AvatarDoorwayPhase.open,
          durationMs: 650,
        ),
      );
      final failed = expectLater(
        operation,
        throwsA(isA<AvatarDoorwayTransitionException>()),
      );
      transitions.invalidate('renderer_unready');
      await failed;
      expect(
        transitions.handleResult({
          'requestId': 'req',
          'transitionId': 'entry',
          'phase': 'open',
          'ok': true,
        }),
        isFalse,
      );
    },
  );
  test(
    'invalid identifiers and durations cannot reach native transport',
    () async {
      final wire = _Wire();
      final transitions = UnityAvatarDoorwayTransitions(wire, () => true);
      addTearDown(transitions.close);
      await expectLater(
        transitions.run(
          const AvatarDoorwayTransition(
            requestId: '../bad',
            transitionId: 'entry',
            phase: AvatarDoorwayPhase.enter,
          ),
        ),
        throwsArgumentError,
      );
      await expectLater(
        transitions.run(
          const AvatarDoorwayTransition(
            requestId: 'req',
            transitionId: 'entry',
            phase: AvatarDoorwayPhase.enter,
            durationMs: 4001,
          ),
        ),
        throwsArgumentError,
      );
      expect(wire.calls, isEmpty);
    },
  );
}
