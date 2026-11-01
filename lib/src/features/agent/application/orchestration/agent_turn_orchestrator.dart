import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/turn_policy.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';

enum AgentTurnRoute {
  chitchat,
  simpleQa,
  explicitTask,
  ambiguousTask,
  riskyAction,
  structured,
}

enum AgentTaskKind { none, gameGeneration, surfaceGeneration, skillTask }

class AgentTurnPlan {
  const AgentTurnPlan({
    required this.route,
    this.taskKind = AgentTaskKind.none,
    this.mood = 'attentive',
    this.confidence = 0.0,
  });

  final AgentTurnRoute route;
  final AgentTaskKind taskKind;
  final String mood;
  final double confidence;

  bool get usePersonaLoop =>
      route == AgentTurnRoute.chitchat ||
      route == AgentTurnRoute.simpleQa ||
      route == AgentTurnRoute.ambiguousTask ||
      route == AgentTurnRoute.riskyAction;

  bool get requiresBackgroundJob =>
      route == AgentTurnRoute.explicitTask &&
      (taskKind == AgentTaskKind.gameGeneration ||
          taskKind == AgentTaskKind.surfaceGeneration);

  bool get requiresStructuredActions =>
      !usePersonaLoop && !requiresBackgroundJob;
}

class AgentTurnOrchestrator {
  const AgentTurnOrchestrator();

  AgentTurnPlan plan({
    required String userText,
    required TurnPolicy policy,
    RoutingDecision? routing,
  }) {
    final text = userText.trim();
    final lower = text.toLowerCase();
    final mood = routing?.emotionPreemit ?? 'attentive';
    final confidence = routing?.confidence ?? 0.4;
    final taskKind = _taskKindFor(text, policy);

    // In an authorized creation request, "delete enemies", "confirm" and
    // "return to this menu" are gameplay requirements, not host operations.
    if (taskKind == AgentTaskKind.gameGeneration ||
        taskKind == AgentTaskKind.surfaceGeneration) {
      return AgentTurnPlan(
        route: AgentTurnRoute.explicitTask,
        taskKind: taskKind,
        mood: mood,
        confidence: confidence,
      );
    }

    if (_looksRisky(lower)) {
      return AgentTurnPlan(
        route: AgentTurnRoute.riskyAction,
        mood: mood,
        confidence: confidence,
      );
    }

    if (_looksAmbiguousTask(lower, routing)) {
      return AgentTurnPlan(
        route: AgentTurnRoute.ambiguousTask,
        mood: mood,
        confidence: confidence,
      );
    }

    if (_looksExplicitTask(policy, routing)) {
      return AgentTurnPlan(
        route: AgentTurnRoute.explicitTask,
        taskKind: taskKind,
        mood: mood,
        confidence: confidence,
      );
    }

    if (_isPlainConversationTurn(policy, routing)) {
      if (routing?.intent == LocalIntent.knowledge) {
        return AgentTurnPlan(
          route: AgentTurnRoute.simpleQa,
          mood: mood,
          confidence: confidence,
        );
      }
      return AgentTurnPlan(
        route: AgentTurnRoute.chitchat,
        mood: mood,
        confidence: confidence,
      );
    }

    return AgentTurnPlan(
      route: AgentTurnRoute.structured,
      mood: mood,
      confidence: confidence,
    );
  }

  bool shouldUsePersonaLoop({
    required AgentPipelineMode pipelineMode,
    required TurnPolicy policy,
    required RoutingDecision? routing,
    required AgentTurnPlan plan,
  }) {
    if (pipelineMode != AgentPipelineMode.proxyDefault) return false;
    if (!plan.usePersonaLoop) return false;
    if (policy.shouldSearch) return false;
    if (policy.card != CardIntent.none) return false;
    if (policy.preferMultiStep) return false;
    if (policy.preferNativeTools) return false;
    if (policy.preferredSkills.isNotEmpty) return false;
    if (policy.surface.isSurface) return false;
    if (policy.projectorMedia.isProjectorFollowUp) return false;
    return true;
  }

  bool _isPlainConversationTurn(TurnPolicy policy, RoutingDecision? routing) {
    if (policy.shouldSearch) return false;
    if (policy.card != CardIntent.none) return false;
    if (policy.preferMultiStep) return false;
    if (policy.preferNativeTools) return false;
    if (policy.preferredSkills.isNotEmpty) return false;
    if (policy.surface.isSurface) return false;
    if (policy.projectorMedia.isProjectorFollowUp) return false;
    if (routing?.intent == LocalIntent.knowledge) {
      return routing!.complexity != RouteComplexity.complex &&
          routing.complexity != RouteComplexity.unsafe;
    }
    return true;
  }

  bool _looksExplicitTask(TurnPolicy policy, RoutingDecision? routing) {
    if (policy.card != CardIntent.none) return true;
    if (policy.surface.isSurface) return true;
    if (policy.preferNativeTools) return true;
    if (policy.preferredSkills.isNotEmpty) return true;
    return false;
  }

  AgentTaskKind _taskKindFor(String text, TurnPolicy policy) {
    final creationType = SurfaceCreationAuthority.experienceTypeFor(
      text: text,
      interactiveHint: policy.card == CardIntent.interactive,
      surfaceIntent: policy.surface,
    );
    if (creationType == SurfaceExperienceType.game) {
      return AgentTaskKind.gameGeneration;
    }
    if (creationType == SurfaceExperienceType.utility) {
      return AgentTaskKind.surfaceGeneration;
    }
    if (policy.preferredSkills.isNotEmpty) {
      return AgentTaskKind.skillTask;
    }
    return AgentTaskKind.none;
  }

  bool _looksAmbiguousTask(String lower, RoutingDecision? routing) {
    if (routing?.intent != LocalIntent.task) return false;
    return _containsAny(lower, const ['那个', '这个', '弄一下', '搞一下', '随便', '你看着办']);
  }

  bool _looksRisky(String lower) {
    return _containsAny(lower, const [
      '删除',
      '清空',
      '支付',
      '转账',
      'send email',
      'delete',
      'pay',
      'transfer',
    ]);
  }

  bool _containsAny(String haystack, List<String> needles) {
    for (final needle in needles) {
      if (haystack.contains(needle)) return true;
    }
    return false;
  }
}
