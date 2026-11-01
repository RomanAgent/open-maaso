import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/response_track_plan.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';

enum TurnOrigin {
  user,
  voice,
  proactivePresence,
  notificationInteraction,
  system,
  followUp,
  live;

  /// Whether this turn was authored directly by the person using Maaso.
  ///
  /// Keep this as the canonical provenance boundary for memory, relationship,
  /// and learning decisions. Agent-initiated and system-mediated turns must not
  /// be treated as user evidence merely because they travel through chat.
  bool get isHumanAuthored => switch (this) {
    TurnOrigin.user || TurnOrigin.voice => true,
    TurnOrigin.proactivePresence ||
    TurnOrigin.notificationInteraction ||
    TurnOrigin.system ||
    TurnOrigin.followUp ||
    TurnOrigin.live => false,
  };
}

enum PrimaryRoute { chat, search, surface, device, setup, task, structured }

class RouteEvidence {
  const RouteEvidence({
    required this.source,
    required this.reason,
    this.confidence = 1.0,
  });

  final String source;
  final String reason;
  final double confidence;
}

class RouteGuard {
  const RouteGuard({required this.id, required this.reason});

  final String id;
  final String reason;
}

class TurnRouteDecision {
  const TurnRouteDecision({
    required this.origin,
    required this.primaryRoute,
    required this.policy,
    required this.plan,
    required this.routing,
    this.evidence = const [],
    this.guards = const [],
  });

  final TurnOrigin origin;
  final PrimaryRoute primaryRoute;
  final TurnPolicy policy;
  final AgentTurnPlan plan;
  final RoutingDecision? routing;
  final List<RouteEvidence> evidence;
  final List<RouteGuard> guards;

  String enrichPrompt(String text, {String? intentWaveHint}) {
    var out = text;
    if (routing != null) {
      out = '${routing!.hintLine}\n$out';
    }
    if (intentWaveHint != null) {
      out = '$intentWaveHint\n$out';
    }
    return out;
  }
}

class TurnRouterGateway {
  const TurnRouterGateway({
    required TurnPolicyEngine policyEngine,
    required AgentTurnOrchestrator orchestrator,
  }) : _policyEngine = policyEngine,
       _orchestrator = orchestrator;

  final TurnPolicyEngine _policyEngine;
  final AgentTurnOrchestrator _orchestrator;

  TurnRouteDecision resolve({
    required TurnOrigin origin,
    required TurnContext context,
  }) {
    final rawPolicy = _policyEngine.decide(context);
    final rawRouting = context.routing;

    if (origin == TurnOrigin.proactivePresence ||
        origin == TurnOrigin.notificationInteraction ||
        origin == TurnOrigin.live) {
      final guardedRouting = _guardedPresenceRouting(rawRouting);
      final guardedPolicy = TurnPolicy(
        reason: [
          if (rawPolicy.reason.isNotEmpty) rawPolicy.reason,
          switch (origin) {
            TurnOrigin.live => 'origin_guard=live',
            TurnOrigin.notificationInteraction =>
              'origin_guard=notification_interaction',
            _ => 'origin_guard=proactive_presence',
          },
        ].join(','),
      );
      final guardedPlan = _orchestrator.plan(
        userText: context.userText,
        policy: guardedPolicy,
        routing: guardedRouting,
      );
      return TurnRouteDecision(
        origin: origin,
        primaryRoute: PrimaryRoute.chat,
        policy: guardedPolicy,
        plan: guardedPlan,
        routing: guardedRouting,
        evidence: _evidenceFor(rawPolicy, guardedPlan),
        guards: [
          RouteGuard(
            id: origin == TurnOrigin.live ? 'live_guard' : 'origin_guard',
            reason: '${origin.name} turns may only shape chat/voice/emotion',
          ),
        ],
      );
    }

    var policy = rawPolicy;
    var routing = rawRouting;
    final guards = <RouteGuard>[];
    if (_needsSurfaceGuard(context, rawPolicy, rawRouting)) {
      policy = _withoutSurface(rawPolicy);
      routing = _withoutSurfaceTool(rawRouting);
      guards.add(
        const RouteGuard(
          id: 'surface_guard',
          reason: 'freeform surface hints require explicit user surface intent',
        ),
      );
    }

    final plan = _orchestrator.plan(
      userText: context.userText,
      policy: policy,
      routing: routing,
    );
    return TurnRouteDecision(
      origin: origin,
      primaryRoute: _primaryRouteFor(policy, plan),
      policy: policy,
      plan: plan,
      routing: routing,
      evidence: _evidenceFor(policy, plan),
      guards: guards,
    );
  }

  RoutingDecision? _guardedPresenceRouting(RoutingDecision? routing) {
    if (routing == null) return null;
    return routing.copyWith(
      intent: LocalIntent.chitchat,
      needsTools: const [],
      complexity: RouteComplexity.simple,
    );
  }

  PrimaryRoute _primaryRouteFor(TurnPolicy policy, AgentTurnPlan plan) {
    if (policy.projectorMedia.isProjectorFollowUp ||
        policy.preferredSkills.contains('BleYoturetoys') ||
        policy.preferredSkills.contains('Bluetooth')) {
      return PrimaryRoute.device;
    }
    if (policy.card == CardIntent.setup) return PrimaryRoute.setup;
    if (plan.taskKind == AgentTaskKind.gameGeneration ||
        plan.taskKind == AgentTaskKind.surfaceGeneration) {
      return PrimaryRoute.surface;
    }
    if (policy.shouldSearch) return PrimaryRoute.search;
    if (plan.route == AgentTurnRoute.chitchat ||
        plan.route == AgentTurnRoute.simpleQa) {
      return PrimaryRoute.chat;
    }
    if (plan.route == AgentTurnRoute.explicitTask) return PrimaryRoute.task;
    return PrimaryRoute.structured;
  }

  bool _needsSurfaceGuard(
    TurnContext context,
    TurnPolicy policy,
    RoutingDecision? routing,
  ) {
    if (context.hasOpenSurface) return false;
    if (policy.projectorMedia.isProjectorFollowUp) return false;
    final hasSurfaceHint =
        policy.card == CardIntent.interactive ||
        policy.surface.isSurface ||
        policy.preferredSkills.contains('FreeformSurface') ||
        (routing?.needsTools.contains('freeform_surface') ?? false);
    if (!hasSurfaceHint) return false;
    return !_hasExplicitSurfaceIntent(context.userText, policy.surface);
  }

  bool _hasExplicitSurfaceIntent(String text, SurfaceIntent surfaceIntent) {
    final lower = text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
    if (lower.isEmpty) return false;
    // The shared authority checks full-message denial and outer questions.
    // Re-running a broad question-word guard here would reject instructions
    // requested inside an otherwise authorized generated product.
    if (SurfaceCreationAuthority.experienceTypeFor(
          text: lower,
          interactiveHint: true,
          surfaceIntent: surfaceIntent,
        ) !=
        null) {
      return true;
    }

    return false;
  }

  TurnPolicy _withoutSurface(TurnPolicy policy) {
    final preferredSkills = policy.preferredSkills
        .where((skill) => skill != 'FreeformSurface')
        .toList(growable: false);
    final hasSkillWork =
        policy.shouldSearch ||
        policy.projectorMedia.isProjectorFollowUp ||
        preferredSkills.isNotEmpty;
    return TurnPolicy(
      shouldSearch: policy.shouldSearch,
      shouldSearchApplets: policy.shouldSearchApplets,
      card: policy.card == CardIntent.interactive
          ? CardIntent.none
          : policy.card,
      shouldAskClarifying: policy.shouldAskClarifying,
      preferMultiStep:
          policy.preferMultiStep && policy.card != CardIntent.interactive,
      preferNativeTools: policy.preferNativeTools,
      preferredSkills: preferredSkills,
      projectorMedia: policy.projectorMedia,
      surface: SurfaceIntent.none,
      tracks: hasSkillWork
          ? ResponseTrackPlan.forTurn(
              hasSkillWork: hasSkillWork,
              surface: SurfaceIntent.none,
            )
          : ResponseTrackPlan.none,
      acknowledgement: policy.acknowledgement == 'policy.ack_card'
          ? null
          : policy.acknowledgement,
      reason: [
        if (policy.reason.isNotEmpty) policy.reason,
        'surface_guard',
      ].join(','),
    );
  }

  RoutingDecision? _withoutSurfaceTool(RoutingDecision? routing) {
    if (routing == null) return null;
    final tools = routing.needsTools
        .where((tool) => tool != 'freeform_surface')
        .toList(growable: false);
    return routing.copyWith(
      intent: tools.isEmpty && routing.intent == LocalIntent.task
          ? LocalIntent.chitchat
          : routing.intent,
      needsTools: tools,
      complexity: tools.isEmpty && routing.intent == LocalIntent.task
          ? RouteComplexity.simple
          : routing.complexity,
    );
  }

  List<RouteEvidence> _evidenceFor(TurnPolicy policy, AgentTurnPlan plan) {
    return [
      if (policy.reason.isNotEmpty)
        RouteEvidence(source: 'turn_policy', reason: policy.reason),
      RouteEvidence(
        source: 'turn_orchestrator',
        reason: 'route=${plan.route.name},task=${plan.taskKind.name}',
        confidence: plan.confidence,
      ),
    ];
  }
}
