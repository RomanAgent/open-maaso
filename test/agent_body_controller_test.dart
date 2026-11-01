import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/body/agent_body_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';

void main() {
  test('automatic body intent degrades while the avatar is loading', () async {
    final controller = AgentBodyController(
      applyAct: (_) => throw PlatformException(
        code: 'not_ready',
        message: 'Unity WebGL is loading',
      ),
    );

    final result = await controller.reactToTurnStart(
      const AgentTurnPlan(
        route: AgentTurnRoute.simpleQa,
        mood: 'thinking',
        confidence: 1,
      ),
    );

    expect(result.applied, isFalse);
    expect(result.reason, 'avatar renderer not ready');
  });

  test('simple QA starts with a local thinking body intent', () async {
    AvatarAct? applied;
    final controller = AgentBodyController(
      applyAct: (act) async {
        applied = act;
        return const AvatarBehaviorResult(
          applied: true,
          reason: 'recorded',
          mood: 'thinking',
          primitive: 'think',
        );
      },
    );

    final result = await controller.reactToTurnStart(
      const AgentTurnPlan(
        route: AgentTurnRoute.simpleQa,
        mood: 'happy',
        confidence: 0.8,
      ),
    );

    expect(result.applied, isTrue);
    expect(applied?.mood, 'thinking');
    expect(applied?.gesture, 'think');
    expect(applied?.gaze, 'down');
  });

  test('generated surface jobs get a local working intent', () async {
    AvatarAct? applied;
    final controller = AgentBodyController(
      applyAct: (act) async {
        applied = act;
        return const AvatarBehaviorResult(
          applied: true,
          reason: 'recorded',
          mood: 'thinking',
          primitive: 'think',
        );
      },
    );

    await controller.reactToTurnStart(
      const AgentTurnPlan(
        route: AgentTurnRoute.explicitTask,
        taskKind: AgentTaskKind.gameGeneration,
        mood: 'excited',
        confidence: 0.8,
      ),
    );

    expect(applied?.mood, 'thinking');
    expect(applied?.gesture, 'think');
    expect(applied?.gaze, 'down');
  });

  test(
    'completed generated jobs get a surface-facing success intent',
    () async {
      AvatarAct? applied;
      final controller = AgentBodyController(
        applyAct: (act) async {
          applied = act;
          return const AvatarBehaviorResult(
            applied: true,
            reason: 'recorded',
            mood: 'excited',
            primitive: 'explain',
          );
        },
      );

      await controller.reactToTaskCompleted(
        AgentTaskJob(
          id: 'job_1',
          agentId: 'self',
          taskKind: AgentTaskKind.gameGeneration,
          userText: '生成五子棋',
          status: AgentTaskJobStatus.completed,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026, 1, 1, 0, 0, 1),
          summary: 'surface opened',
        ),
      );

      expect(applied?.mood, 'excited');
      expect(applied?.gesture, 'explain');
      expect(applied?.gaze, 'surface');
    },
  );

  test('failed generated jobs get a concise recovery intent', () async {
    AvatarAct? applied;
    final controller = AgentBodyController(
      applyAct: (act) async {
        applied = act;
        return const AvatarBehaviorResult(
          applied: true,
          reason: 'recorded',
          mood: 'confused',
          primitive: 'shrug',
        );
      },
    );

    await controller.reactToTaskFailed(
      AgentTaskJob(
        id: 'job_2',
        agentId: 'self',
        taskKind: AgentTaskKind.surfaceGeneration,
        userText: '生成透明天气组件',
        status: AgentTaskJobStatus.failed,
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026, 1, 1, 0, 0, 1),
        error: 'validator rejected empty surface',
      ),
    );

    expect(applied?.mood, 'confused');
    expect(applied?.gesture, 'shrug');
    expect(applied?.gaze, 'user');
  });

  test('applies remote body intent as a high-level avatar act', () async {
    AvatarAct? applied;
    final controller = AgentBodyController(
      applyAct: (act) async {
        applied = act;
        return const AvatarBehaviorResult(
          applied: true,
          reason: 'recorded',
          mood: 'playful',
          primitive: 'small_wave',
        );
      },
    );

    final result = await controller.applyRemoteIntent({
      'mood': 'playful',
      'gesture': 'small-wave',
      'gaze': 'user',
      'intensity': 0.72,
    });

    expect(result.applied, isTrue);
    expect(applied?.mood, 'playful');
    expect(applied?.gesture, 'small_wave');
    expect(applied?.gaze, 'user');
    expect(applied?.intensity, 0.72);
  });
}
