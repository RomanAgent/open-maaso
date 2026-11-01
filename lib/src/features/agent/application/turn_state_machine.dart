import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

/// The phases one conversational turn passes through. `listening` is entered
/// only when voice barge-in is active (Phase 2); Phase 1 never enters it but
/// the transition table already permits it for forward-compatibility.
enum TurnState { idle, reflex, thinking, speaking, listening, reconcile }

/// Single source of truth for one [AgentRuntime]'s turn lifecycle. Pure: no
/// I/O, no EventBus, no Get lookups — just state + a legal-transition table,
/// so it is fully unit-testable.
class TurnStateMachine {
  TurnStateMachine({required this.agentId});

  final String agentId;

  final Rx<TurnState> state = TurnState.idle.obs;

  /// "A turn is in flight" — every non-idle state. Mirrors the legacy
  /// `isProcessing` flag the UI and `MicCaptureService` watch.
  bool get isProcessing => state.value != TurnState.idle;

  /// The agent is voicing its reply. Mirrors the legacy `isSpeaking` flag.
  bool get isSpeaking => state.value == TurnState.speaking;

  /// Legal forward transitions. Any state may additionally jump to [idle]
  /// (hard cancel), handled in [transition] without listing it here.
  static const Map<TurnState, Set<TurnState>> _allowed = {
    TurnState.idle: {TurnState.reflex},
    TurnState.reflex: {TurnState.thinking},
    TurnState.thinking: {
      TurnState.speaking,
      TurnState.reconcile,
      TurnState.reflex,
    },
    TurnState.speaking: {
      TurnState.listening,
      TurnState.reconcile,
    }, // listening = Phase 2 (voice barge-in) only
    TurnState.listening: {
      TurnState.speaking,
      TurnState.reflex,
    }, // Phase 2 (voice barge-in) only
    TurnState.reconcile: {TurnState.idle},
  };

  bool _isLegal(TurnState to) =>
      to == state.value ||
      to == TurnState.idle ||
      (_allowed[state.value]?.contains(to) ?? false);

  /// Attempt a transition. Returns true if applied (or a no-op to the current
  /// state), false if rejected. Rejected transitions are logged and leave the
  /// state unchanged, so concurrency bugs surface loudly instead of racing.
  bool transition(TurnState to) {
    if (to == state.value) return true;
    if (!_isLegal(to)) {
      Log.w(
        '🚦 [Turn/$agentId] illegal transition ${state.value.name} → ${to.name}',
      );
      return false;
    }
    Log.i('🚦 [Turn/$agentId] ${state.value.name} → ${to.name}');
    state.value = to;
    return true;
  }

  /// Hard cancel from any state (Stop button, dispose). Always legal.
  void reset() {
    if (state.value == TurnState.idle) return;
    Log.i('🚦 [Turn/$agentId] ${state.value.name} → idle (reset)');
    state.value = TurnState.idle;
  }

  /// Start a new turn. Succeeds only from idle; returns false if a turn is
  /// already in flight (caller should reject or preempt).
  bool beginTurn() {
    if (state.value != TurnState.idle) return false;
    return transition(TurnState.reflex);
  }

  /// Cancel whatever is in flight and immediately begin a fresh turn. Used when
  /// a real user message preempts a low-priority proactive turn.
  void preempt() {
    reset();
    beginTurn();
  }
}
