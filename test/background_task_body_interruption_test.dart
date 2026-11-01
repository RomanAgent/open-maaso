import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/body/agent_body_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('foreground body reactions cannot replace current task work', () async {
    final avatar = _Avatar();
    var currentJob = true;
    final work = <AvatarBackgroundTaskWorkPhase>[];
    final acts = <AvatarAct>[];
    final presentation = AvatarBackgroundTaskWorkController(
      runtimeProvider: () => avatar,
      authorityProvider: () => null,
      canPresent: () => true,
      applyWork: (_, phase, admitted) async {
        expect(admitted(), isTrue);
        work.add(phase);
        return const AvatarProductionBehaviorResult(
          AvatarProductionBehaviorDisposition.applied,
        );
      },
    );
    final body = AgentBodyController(
      backgroundTaskWork: presentation,
      applyAct: (act) async {
        acts.add(act);
        return const AvatarBehaviorResult(applied: true, reason: 'recorded');
      },
    );
    addTearDown(body.dispose);
    final owner = body.beginBackgroundTaskWork(
      jobId: 'job-current',
      attempt: 1,
      scopeKey: 'account-current',
      isCurrent: () => currentJob,
    );
    await body.waitForBackgroundTaskWorkIdle();
    expect(owner, isNotNull);
    expect(work, [AvatarBackgroundTaskWorkPhase.start]);
    for (final route in [AgentTurnRoute.chitchat, AgentTurnRoute.simpleQa]) {
      final result = await body.reactToTurnStart(AgentTurnPlan(route: route));
      expect(result.applied, isFalse);
    }
    final remote = await body.applyRemoteIntent({
      'mood': 'thinking',
      'gesture': 'listen',
      'gaze': 'user',
    });
    expect(remote.applied, isFalse);
    expect(acts, isEmpty);
    expect(work, [AvatarBackgroundTaskWorkPhase.start]);

    currentJob = false;
    await body.endBackgroundTaskWork(owner);
    expect(work, [
      AvatarBackgroundTaskWorkPhase.start,
      AvatarBackgroundTaskWorkPhase.end,
    ]);
    final after = await body.reactToTurnStart(
      const AgentTurnPlan(route: AgentTurnRoute.chitchat),
    );
    expect(after.applied, isTrue);
    expect(acts.single.gesture, 'listen');
  });
}

class _Avatar extends AvatarRuntime {
  @override
  final isReady = true.obs;
  @override
  final presentationReady = true.obs;
  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;
  @override
  bool get supportsBackgroundTaskWorkPresentation => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
