import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';

void main() {
  final policyEngine = TurnPolicyEngine(agentId: 'self');
  const orchestrator = AgentTurnOrchestrator();
  final gateway = TurnRouterGateway(
    policyEngine: policyEngine,
    orchestrator: orchestrator,
  );

  RoutingDecision routing({
    LocalIntent intent = LocalIntent.task,
    RouteComplexity complexity = RouteComplexity.medium,
    List<String> tools = const ['freeform_surface'],
  }) => RoutingDecision(
    intent: intent,
    confidence: 0.8,
    emotionPreemit: 'calm',
    complexity: complexity,
    needsTools: tools,
  );

  test('only direct user and voice turns are human authored', () {
    expect(
      {for (final origin in TurnOrigin.values) origin: origin.isHumanAuthored},
      const {
        TurnOrigin.user: true,
        TurnOrigin.voice: true,
        TurnOrigin.proactivePresence: false,
        TurnOrigin.notificationInteraction: false,
        TurnOrigin.system: false,
        TurnOrigin.followUp: false,
        TurnOrigin.live: false,
      },
    );
  });

  test('proactive presence turns are source-guarded to chat', () {
    final decision = gateway.resolve(
      origin: TurnOrigin.proactivePresence,
      context: TurnContext(
        userText:
            'do not list the memory mechanically; keep it one brief natural line',
        routing: routing(),
      ),
    );

    expect(decision.origin, TurnOrigin.proactivePresence);
    expect(decision.primaryRoute, PrimaryRoute.chat);
    expect(decision.policy.card, CardIntent.none);
    expect(decision.policy.surface.kind, SurfaceIntentKind.none);
    expect(decision.policy.preferredSkills, isEmpty);
    expect(decision.plan.taskKind, AgentTaskKind.none);
    expect(decision.routing?.needsTools, isEmpty);
    expect(decision.routing?.intent, LocalIntent.chitchat);
    expect(decision.guards.map((guard) => guard.id), contains('origin_guard'));
  });

  test('live turns are source-guarded to chat voice and emotion only', () {
    final decision = gateway.resolve(
      origin: TurnOrigin.live,
      context: TurnContext(
        userText: 'make a dashboard and switch the projector on',
        routing: routing(tools: const ['freeform_surface', 'Bluetooth']),
      ),
    );

    expect(decision.primaryRoute, PrimaryRoute.chat);
    expect(decision.policy.card, CardIntent.none);
    expect(decision.policy.surface.kind, SurfaceIntentKind.none);
    expect(decision.policy.preferredSkills, isEmpty);
    expect(decision.plan.taskKind, AgentTaskKind.none);
    expect(decision.routing?.needsTools, isEmpty);
    expect(decision.routing?.intent, LocalIntent.chitchat);
    expect(decision.guards.map((guard) => guard.id), contains('live_guard'));
  });

  test('notification interactions are source-guarded to chat', () {
    final decision = gateway.resolve(
      origin: TurnOrigin.notificationInteraction,
      context: TurnContext(
        userText: 'acknowledge the notification the user opened',
        routing: routing(tools: const ['freeform_surface', 'Bluetooth']),
      ),
    );

    expect(decision.primaryRoute, PrimaryRoute.chat);
    expect(decision.policy.card, CardIntent.none);
    expect(decision.policy.surface.kind, SurfaceIntentKind.none);
    expect(decision.policy.preferredSkills, isEmpty);
    expect(decision.plan.taskKind, AgentTaskKind.none);
    expect(decision.routing?.needsTools, isEmpty);
    expect(decision.routing?.intent, LocalIntent.chitchat);
    expect(decision.guards.map((guard) => guard.id), contains('origin_guard'));
  });

  test(
    'proactive presence routing hint does not leak surface tools to prompt',
    () {
      final decision = gateway.resolve(
        origin: TurnOrigin.proactivePresence,
        context: TurnContext(
          userText:
              'do not list the memory mechanically; keep it one brief natural line',
          routing: routing(),
        ),
      );

      final enriched = decision.enrichPrompt('hello');

      expect(enriched, contains('[local-brain:'));
      expect(enriched, isNot(contains('may_need=freeform_surface')));
      expect(enriched, contains('intent=chitchat'));
    },
  );

  test('local brain surface hints need explicit user surface intent', () {
    final decision = gateway.resolve(
      origin: TurnOrigin.user,
      context: TurnContext(
        userText: 'do not list the memory mechanically',
        routing: routing(),
      ),
    );

    expect(decision.primaryRoute, PrimaryRoute.chat);
    expect(decision.policy.card, CardIntent.none);
    expect(decision.policy.preferredSkills, isEmpty);
    expect(decision.plan.taskKind, AgentTaskKind.none);
    expect(decision.routing?.needsTools, isEmpty);
    expect(decision.guards.map((guard) => guard.id), contains('surface_guard'));
  });

  test('negated explicit wording cannot use the compatibility fallback', () {
    final decision = gateway.resolve(
      origin: TurnOrigin.user,
      context: TurnContext(
        userText: "don't create a dashboard",
        routing: routing(),
      ),
    );

    expect(decision.primaryRoute, PrimaryRoute.chat);
    expect(decision.plan.taskKind, AgentTaskKind.none);
    expect(decision.routing?.needsTools, isEmpty);
    expect(decision.guards.map((guard) => guard.id), contains('surface_guard'));
  });

  test(
    'explicit user surface requests still route to background surface work',
    () {
      final decision = gateway.resolve(
        origin: TurnOrigin.user,
        context: TurnContext(
          userText: 'make a list mini app',
          routing: routing(),
        ),
      );

      expect(decision.primaryRoute, PrimaryRoute.surface);
      expect(decision.policy.card, CardIntent.interactive);
      expect(decision.policy.preferredSkills, contains('FreeformSurface'));
      expect(decision.plan.taskKind, AgentTaskKind.surfaceGeneration);
      expect(decision.routing?.needsTools, contains('freeform_surface'));
    },
  );

  for (final request in const <String>[
    '帮我创建一个更好的小游戏',
    '做一个比较好玩的小游戏',
    '创建一个更适合儿童的小程序',
    'Create a better mini game than the old one',
    'Build a safer mini app for my family',
  ]) {
    test('quality adjective stays explicit Surface work: $request', () {
      final decision = gateway.resolve(
        origin: TurnOrigin.user,
        context: TurnContext(userText: request, routing: routing()),
      );

      expect(decision.primaryRoute, PrimaryRoute.surface);
      expect(
        decision.plan.taskKind,
        anyOf(AgentTaskKind.gameGeneration, AgentTaskKind.surfaceGeneration),
      );
      expect(decision.routing?.needsTools, contains('freeform_surface'));
      expect(
        decision.guards.map((guard) => guard.id),
        isNot(contains('surface_guard')),
      );
    });
  }

  for (final question in const <String>[
    'What makes a good dashboard?',
    'Can you explain how to create a dashboard?',
    'Tell me how to create a dashboard.',
    'Is it better to make a mini app or a website?',
    'Could you create a mini game or play chess—which is better',
    'Is a mini game better than a mini app',
    '如何做一个小游戏？',
    '你能解释一下如何创建看板吗？',
    '告诉我怎么做一个小游戏。',
    '做一个小游戏还是做一个小程序更好？',
    '做一个小游戏还是小程序更好',
    '小游戏和小程序哪个更适合儿童',
    '做小游戏或者小程序怎么选',
    '创建一个看板要多久？',
    '制作小游戏需要注意什么？',
  ]) {
    test('surface question is guarded from background work: $question', () {
      final decision = gateway.resolve(
        origin: TurnOrigin.user,
        context: TurnContext(userText: question, routing: routing()),
      );

      expect(decision.primaryRoute, PrimaryRoute.chat);
      expect(decision.plan.taskKind, AgentTaskKind.none);
      expect(decision.routing?.needsTools, isEmpty);
      expect(
        decision.guards.map((guard) => guard.id),
        contains('surface_guard'),
      );
    });
  }
}
