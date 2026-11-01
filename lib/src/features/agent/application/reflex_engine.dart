import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/brain_router.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/core/services/intent_wave_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/working_memory.dart';

/// Output of a single reflex sweep.  Cheap value object — caller threads
/// it into prompt construction (cloud path) or directly into the local
/// LLM call (local fallback path).
class ReflexResult {
  ReflexResult({required this.userText, this.routing, this.intentWaveHint});

  /// Original user text — unchanged.  Use [enrich] to get the version with
  /// hint lines prepended for the answer brain.
  final String userText;

  /// Local brain's routing decision.  Null when the local brain isn't
  /// registered or threw.  When non-null the emotion preemit has already
  /// been fired on EventBus by [BrainRouter.route].
  final RoutingDecision? routing;

  /// IntentWave's collapse summary, formatted as a single bracketed hint
  /// line.  Null when IntentWaveService isn't registered.
  final String? intentWaveHint;

  /// True when the chitchat short-circuit fired — the local brain produced
  /// a complete in-character reply and asked us to skip the answer brain.
  bool get hasChitchatDraft =>
      routing != null &&
      !routing!.escalate &&
      routing!.draftReply != null &&
      routing!.draftReply!.trim().isNotEmpty;

  /// The chitchat draft reply, if any.  Caller may TTS and return it
  /// directly without hitting the cloud / local answer brain.
  String? get chitchatDraft => routing?.draftReply?.trim();

  /// Prepend the local-brain hint + intent-wave hint to [text].  Same
  /// ordering AgentRuntime used historically so cached system prompts and
  /// in-context behavior stay equivalent.
  String enrich(String text) {
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

/// Backend-agnostic reflex layer.
///
/// One [ReflexEngine] per agent.  On every user turn the engine performs
/// the side-effects historically buried inside [AgentRuntime.chat] —
/// routing, emotion preemit (via [BrainRouter]), IntentWave absorb +
/// collapse, and WorkingMemory write — and returns a [ReflexResult] the
/// answer brain (cloud OR local) can consume.
///
/// Why this lives outside AgentRuntime:
///   * The local fallback path ([HomeController._localChatFallback]) never
///     constructs an AgentRuntime, so historically it lost every one of
///     those side-effects.  An independent engine lets both paths reuse
///     the same reflex sweep.
///   * Keeps cloud/local branching at a single seam (the answer-brain
///     call) instead of duplicating reflex logic on both sides.
class ReflexEngine {
  ReflexEngine({required this.agentId});

  final String agentId;

  late final BrainRouter _router = BrainRouter(agentId: agentId);

  /// Run one reflex sweep for [userText].  Safe to call even when the
  /// optional services (LocalBrainService, IntentWaveService,
  /// WorkingMemory) aren't registered — each step is independently
  /// guarded.
  Future<ReflexResult> reflect(String userText) async {
    TurnTrace.event(
      'reflex.observe.start',
      details: 'agent=$agentId chars=${userText.length}',
    );
    IntentWaveService? intentWave;
    if (appServices.isRegistered<IntentWaveService>()) {
      intentWave = appServices.find<IntentWaveService>();
      intentWave.observeUserText(userText);
    }

    RoutingDecision? routing;
    if (appServices.isRegistered<LocalBrainService>()) {
      try {
        final routeSw = TurnTrace.stopwatch('router.local_brain');
        routing = await _router.route(userText);
        TurnTrace.done(
          'router.local_brain',
          routeSw,
          details:
              'complexity=${routing.complexity.name} '
              'intent=${routing.intent.name} '
              'confidence=${routing.confidence.toStringAsFixed(2)} '
              'escalate=${routing.escalate}',
        );
      } catch (e) {
        TurnTrace.event('router.local_brain.error', details: 'error=$e');
        Log.w('🧠 [ReflexEngine/$agentId] local brain routing failed: $e');
      }
    } else {
      TurnTrace.event('router.local_brain.skip', details: 'not_registered');
    }

    String? intentWaveHint;
    if (intentWave != null) {
      if (routing != null) {
        intentWave.absorbRoutingDecision(routing);
      }
      final collapsed = intentWave.collapse(reason: 'user_send');
      intentWaveHint =
          '[intent-wave: collapsed=${collapsed.lastCollapsedComponent}, '
          'entropy=${collapsed.entropy.toStringAsFixed(2)}, '
          'top=${collapsed.dominantComponent}]';
      TurnTrace.event(
        'intent_wave.collapse',
        details:
            'collapsed=${collapsed.lastCollapsedComponent} '
            'entropy=${collapsed.entropy.toStringAsFixed(2)} '
            'top=${collapsed.dominantComponent}',
      );
    }

    if (appServices.isRegistered<WorkingMemory>()) {
      final l0 = appServices.find<WorkingMemory>();
      l0.clear();
      l0.currentUserInput = userText;
      if (routing != null) {
        l0.localBrainHint = routing.intent.name;
        l0.localBrainEmotion = routing.emotionPreemit;
        l0.localBrainIntensity = routing.emotionIntensity;
      }
      TurnTrace.event(
        'working_memory.write',
        details: 'routing=${routing?.intent.name ?? "none"}',
      );
    }

    return ReflexResult(
      userText: userText,
      routing: routing,
      intentWaveHint: intentWaveHint,
    );
  }
}
