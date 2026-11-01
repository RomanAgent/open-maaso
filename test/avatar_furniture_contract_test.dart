import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_furniture_state.dart';
import 'package:maaso/src/features/agent/application/body/avatar_body_intent_policy.dart';

void main() {
  test(
    'task furniture observations bind a bounded owner only to a real desk work phase',
    () {
      final packet = <String, dynamic>{
        'phase': 'working',
        'furnitureId': 'desk',
        'sceneId': 'coastal:1',
        'sequence': 1,
        'workSessionId': 'a' * 64,
      };
      expect(AvatarFurnitureState.parse(packet)?.workSessionId, 'a' * 64);
      expect(
        AvatarFurnitureState.parse({...packet, 'furnitureId': 'sofa'}),
        isNull,
      );
      expect(
        AvatarFurnitureState.parse({...packet, 'phase': 'seated'}),
        isNull,
      );
      expect(
        AvatarFurnitureState.parse({...packet, 'workSessionId': 'some task'}),
        isNull,
      );
      expect(
        AvatarFurnitureState.parse({...packet, 'workSessionId': 1}),
        isNull,
      );
      expect(
        AvatarFurnitureState.parse({
          ...packet,
          'workSessionId': '',
        })?.workSessionId,
        isNull,
      );
    },
  );
  test('furniture intent only accepts semantic actions', () {
    for (final gesture in AvatarFurnitureState.gestures) {
      expect(
        AvatarBodyIntentPolicy.normalize({'posture': gesture})?['posture'],
        gesture,
      );
    }
    expect(
      AvatarBodyIntentPolicy.normalize({'posture': 'seat_at_1_2_3'}),
      isNull,
    );
    expect(
      AvatarFurnitureState.parse({
        'phase': 'lying',
        'furnitureId': 'bed',
        'sceneId': 'room:2',
        'sequence': 1,
      })?.sleeping,
      true,
    );
    expect(
      AvatarFurnitureState.parse({
        'phase': 'lying',
        'furnitureId': '',
        'sceneId': 'room:2',
        'sequence': 1,
      }),
      isNull,
    );
    expect(
      AvatarFurnitureState.parse({
        'phase': 'seated',
        'furnitureId': 'chair',
        'sceneId': '',
        'sequence': 1,
      }),
      isNull,
    );
    expect(
      AvatarFurnitureState.parse({
        'phase': 'seated',
        'furnitureId': 'chair',
        'sceneId': 'room',
        'sequence': 1.5,
      }),
      isNull,
    );
  });

  test(
    'observation requires current account renderer and opaque owner',
    () async {
      final sink = _PermitSink();
      final arbiter = AvatarCommandArbiter(
        accountGeneration: 3,
        dispatchSink: sink,
      );
      await arbiter.bindRenderer(
        accountGeneration: 3,
        rendererGeneration: 7,
        ready: true,
      );
      await arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: 3,
          rendererGeneration: 7,
          commandGeneration: 1,
          leaseId: 'face',
          source: AvatarCommandSource.explicitUser,
          command: AvatarFramingCommand('upper_body'),
          ttl: const Duration(seconds: 1),
        ),
      );
      final token =
          sink.permit!.toTransportJson(
                requestId: 'observation-test',
              )['ownerToken']
              as String;
      bool accept(String owner, int account, int renderer) =>
          arbiter.acceptsRendererObservation(
            ownerToken: owner,
            accountGeneration: account,
            rendererGeneration: renderer,
          );
      expect(accept(token, 3, 7), true);
      expect(accept('forged', 3, 7), false);
      expect(accept(token, 2, 7), false);
      expect(accept(token, 3, 6), false);
      await arbiter.sealAndDrain();
      expect(accept(token, 3, 7), false);
    },
  );
}

final class _PermitSink implements AvatarCommandDispatchSink {
  AvatarRendererMutationPermit? permit;
  @override
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  ) async {
    permit = operation.issueRendererMutationPermit()!;
    return operation.acceptRendererReceipt(permit!)!;
  }

  @override
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  ) async => operation.resetOrDisposeIfCurrent(() {})!;
}
