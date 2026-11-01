import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_emotion_timeline.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/local_brain_service.dart';

/// Decides which brain handles each user turn and what side effects fire
/// before the chosen brain even starts.
///
/// P2 responsibilities:
///   1. Ask the local brain for a [RoutingDecision] (<10 ms).
///   2. **Fire the emotion preemit on the EventBus immediately** so the
///      avatar reacts within ~50ms — well before any cloud token returns.
///   3. Return the decision so callers can thread the hint line into the
///      cloud/local answer path.
///
/// The on-device LLM is deliberately not consulted here. It is reserved for
/// local chat fallback and transient cloud-mode filler, so this route remains
/// deterministic and safely inside the perceptual budget.
class BrainRouter {
  BrainRouter({required this.agentId});

  final String agentId;

  LocalBrainService get _local => appServices.find<LocalBrainService>();

  /// One-shot routing.  Caller pattern:
  /// ```
  ///   final r = await router.route(text);
  ///   final cloudText = '${r.hintLine}\n$text';
  ///   ... // cloud LLM call with cloudText
  /// ```
  /// Target latency for the local preemit path — the avatar should react
  /// within this budget, well before any cloud token returns.
  static const _preemitBudgetMs = 50;

  Future<RoutingDecision> route(String userText) async {
    final sw = Stopwatch()..start();
    final decision = await _local.heuristicRoute(userText);
    final preemitMs = sw.elapsedMicroseconds / 1000.0;
    _firePreemit(decision);
    final preemitTotalMs = sw.elapsedMicroseconds / 1000.0;
    final decideMs = sw.elapsedMicroseconds / 1000.0;
    sw.stop();
    final totalMs = sw.elapsedMicroseconds / 1000.0;

    final line =
        '🧠 [BrainRouter/$agentId] preemit '
        'heuristic=${preemitMs.toStringAsFixed(1)}ms '
        'emotion=${preemitTotalMs.toStringAsFixed(1)}ms '
        'decide=${decideMs.toStringAsFixed(1)}ms '
        'total=${totalMs.toStringAsFixed(1)}ms '
        'backend=heuristic complexity=${decision.complexity.name} '
        'intent=${decision.intent.name} '
        'emotion=${decision.emotionPreemit} escalate=${decision.escalate}';
    if (totalMs > _preemitBudgetMs) {
      Log.w('$line ⚠️ over ${_preemitBudgetMs}ms budget');
    } else {
      Log.i('$line ✅ within ${_preemitBudgetMs}ms budget');
    }

    return decision;
  }

  void _firePreemit(RoutingDecision d) {
    // A fast routing hint is not evidence for a social smile. The same
    // answer model can choose a contextual smile without a second request.
    final params = AvatarEmotionTimeline.restingMood(
      _paramsForLabel(d.emotionPreemit, d.emotionIntensity),
    );
    EventBus().fire(
      EmotionStateEvent(
        params,
        semanticLabel: d.emotionPreemit,
        automatic: true,
        agentId: agentId,
      ),
    );
  }

  /// Maps the local brain's coarse label → an [EmotionParams] preset.
  /// Cloud LLM will fire its own (more nuanced) setEmotion within a couple
  /// of seconds, overwriting whatever we pick here — so being approximate
  /// is fine.  The point is to fill the visual gap, not nail the final mood.
  EmotionParams _paramsForLabel(String label, double intensity) {
    final clamped = intensity.clamp(0.0, 1.0);
    final base = switch (label) {
      'happy' => EmotionParams.happy,
      'sad' => EmotionParams.sad,
      'angry' => EmotionParams.angry,
      'surprised' => EmotionParams.surprised,
      'shy' => EmotionParams.shy,
      'thinking' => EmotionParams.thinking,
      'sleeping' => EmotionParams.sleeping,
      'love' => EmotionParams.love,
      'wink' => EmotionParams.wink,
      'bored' => EmotionParams.bored,
      'excited' => EmotionParams.excited,
      'confused' => EmotionParams.confused,
      'fear' => EmotionParams.fear,
      'calm' => EmotionParams.calm,
      'neutral' => EmotionParams.neutral,
      'serious' => EmotionParams.serious,
      'comforting' => EmotionParams.comforting,
      _ => EmotionParams.neutral,
    };
    return base.scaled(clamped.toDouble());
  }
}
