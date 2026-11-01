import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';

void main() {
  group('AgentTurnOrchestrator', () {
    const orchestrator = AgentTurnOrchestrator();

    TurnPolicy neutralPolicy() => TurnPolicy.neutral;

    RoutingDecision route({
      LocalIntent intent = LocalIntent.chitchat,
      RouteComplexity complexity = RouteComplexity.simple,
      List<String> tools = const [],
    }) => RoutingDecision(
      intent: intent,
      confidence: 0.8,
      emotionPreemit: 'happy',
      complexity: complexity,
      needsTools: tools,
    );

    test('routes emotional chitchat to persona chat loop', () {
      final plan = orchestrator.plan(
        userText: '今天好累，想和你聊聊天',
        policy: neutralPolicy(),
        routing: route(),
      );

      expect(plan.route, AgentTurnRoute.chitchat);
      expect(plan.usePersonaLoop, isTrue);
      expect(plan.requiresBackgroundJob, isFalse);
      expect(
        orchestrator.shouldUsePersonaLoop(
          pipelineMode: AgentPipelineMode.proxyDefault,
          policy: neutralPolicy(),
          routing: route(),
          plan: plan,
        ),
        isTrue,
      );
    });

    test('routes simple knowledge questions to persona QA', () {
      final plan = orchestrator.plan(
        userText: '为什么天空是蓝色的？',
        policy: neutralPolicy(),
        routing: route(
          intent: LocalIntent.knowledge,
          complexity: RouteComplexity.medium,
        ),
      );

      expect(plan.route, AgentTurnRoute.simpleQa);
      expect(plan.usePersonaLoop, isTrue);
      expect(plan.requiresBackgroundJob, isFalse);
    });

    test('defaults null routing to the cloud persona path', () {
      final plan = orchestrator.plan(
        userText: 'good',
        policy: neutralPolicy(),
        routing: null,
      );

      expect(plan.route, AgentTurnRoute.chitchat);
      expect(plan.usePersonaLoop, isTrue);
      expect(
        orchestrator.shouldUsePersonaLoop(
          pipelineMode: AgentPipelineMode.proxyDefault,
          policy: neutralPolicy(),
          routing: null,
          plan: plan,
        ),
        isTrue,
      );
    });

    test('does not trust local task guesses without policy evidence', () {
      final plan = orchestrator.plan(
        userText: 'good',
        policy: neutralPolicy(),
        routing: route(
          intent: LocalIntent.task,
          complexity: RouteComplexity.medium,
          tools: const ['made_up_tool'],
        ),
      );

      expect(plan.route, AgentTurnRoute.chitchat);
      expect(plan.usePersonaLoop, isTrue);
      expect(plan.requiresStructuredActions, isFalse);
      expect(
        orchestrator.shouldUsePersonaLoop(
          pipelineMode: AgentPipelineMode.proxyDefault,
          policy: neutralPolicy(),
          routing: route(
            intent: LocalIntent.task,
            complexity: RouteComplexity.medium,
            tools: const ['made_up_tool'],
          ),
          plan: plan,
        ),
        isTrue,
      );
    });

    test('routes generated games to background jobs', () {
      final plan = orchestrator.plan(
        userText: '创建一个能玩的五子棋小游戏',
        policy: const TurnPolicy(
          card: CardIntent.interactive,
          surface: SurfaceIntent(kind: SurfaceIntentKind.game),
        ),
        routing: route(
          intent: LocalIntent.task,
          complexity: RouteComplexity.medium,
          tools: const ['freeform_surface'],
        ),
      );

      expect(plan.route, AgentTurnRoute.explicitTask);
      expect(plan.taskKind, AgentTaskKind.gameGeneration);
      expect(plan.usePersonaLoop, isFalse);
      expect(plan.requiresBackgroundJob, isTrue);
    });

    test('game creation owns features containing risky or ambiguous words', () {
      final engine = TurnPolicyEngine(agentId: 'self');
      for (final prompt in const <String>[
        '生成一个底下有个杠，球会掉下来然后弹上去的小游戏',
        '生成一个可触摸的弹球小游戏，需要设置球的速度',
        '生成一个小游戏，确认后可以开始，失败后返回菜单',
        '生成一个小游戏，敌人被击中后删除，回到起点重新开始',
        '生成一个小游戏，这个游戏通关后清空敌人并返回菜单',
        'Create an arbitrary bouncing ball game with a bottom paddle',
      ]) {
        final policy = engine.decide(TurnContext(userText: prompt));
        final plan = orchestrator.plan(
          userText: prompt,
          policy: policy,
          routing: route(intent: LocalIntent.task),
        );
        expect(plan.route, AgentTurnRoute.explicitTask, reason: prompt);
        expect(plan.taskKind, AgentTaskKind.gameGeneration, reason: prompt);
        expect(plan.requiresBackgroundJob, isTrue, reason: prompt);
        expect(plan.usePersonaLoop, isFalse, reason: prompt);
      }
    });

    test('applet creation remains typed when features mention a game', () {
      final engine = TurnPolicyEngine(agentId: 'self');
      for (final prompt in const <String>[
        '生成一个有二级导航的小程序，点击设置可以进入设置页并返回首页',
        '生成一个小程序，球会掉下来然后弹上去',
        '生成一个记录游戏分数的小程序，这个页面可以清空记录并返回首页',
      ]) {
        final policy = engine.decide(TurnContext(userText: prompt));
        final plan = orchestrator.plan(
          userText: prompt,
          policy: policy,
          routing: route(intent: LocalIntent.task),
        );
        expect(plan.route, AgentTurnRoute.explicitTask, reason: prompt);
        expect(plan.taskKind, AgentTaskKind.surfaceGeneration, reason: prompt);
        expect(plan.requiresBackgroundJob, isTrue, reason: prompt);
      }
    });

    test('game nouns cannot promote navigation or discussion to creation', () {
      final engine = TurnPolicyEngine(agentId: 'self');
      for (final prompt in const <String>[
        '去小游戏频道',
        '不要生成小游戏，回到home页面',
        '解释如何做一个小游戏',
        '制作这个小游戏需要注意什么？',
        '生成一个小游戏，但不要保存',
        '帮我发帖介绍这个小游戏',
        'let me set my api key',
      ]) {
        final policy = engine.decide(TurnContext(userText: prompt));
        final plan = orchestrator.plan(
          userText: prompt,
          policy: policy,
          routing: route(intent: LocalIntent.task),
        );
        expect(plan.requiresBackgroundJob, isFalse, reason: prompt);
        expect(
          plan.taskKind,
          isNot(
            anyOf(
              AgentTaskKind.gameGeneration,
              AgentTaskKind.surfaceGeneration,
            ),
          ),
          reason: prompt,
        );
      }
    });

    test('interactive hints alone cannot authorize denied game creation', () {
      const gameHint = TurnPolicy(
        card: CardIntent.interactive,
        surface: SurfaceIntent(kind: SurfaceIntentKind.game),
      );
      for (final prompt in const <String>[
        '不要生成小游戏，只解释玩法',
        '解释如何做一个小游戏',
        '生成一个小游戏，但不要保存',
      ]) {
        final plan = orchestrator.plan(userText: prompt, policy: gameHint);
        expect(plan.requiresBackgroundJob, isFalse, reason: prompt);
      }
    });

    test('keeps skill-only tasks on the structured path', () {
      final plan = orchestrator.plan(
        userText: '查一下深圳天气',
        policy: const TurnPolicy(preferredSkills: ['WebSearch']),
        routing: route(
          intent: LocalIntent.task,
          complexity: RouteComplexity.medium,
          tools: const ['skill_websearch_websearch'],
        ),
      );

      expect(plan.route, AgentTurnRoute.explicitTask);
      expect(plan.taskKind, AgentTaskKind.skillTask);
      expect(plan.requiresBackgroundJob, isFalse);
      expect(plan.requiresStructuredActions, isTrue);
    });
  });
}
