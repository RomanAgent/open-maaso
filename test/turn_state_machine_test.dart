import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/turn_state_machine.dart';

void main() {
  group('TurnStateMachine', () {
    test('starts idle with derived flags false', () {
      final m = TurnStateMachine(agentId: 'self');
      expect(m.state.value, TurnState.idle);
      expect(m.isProcessing, isFalse);
      expect(m.isSpeaking, isFalse);
    });

    test('follows the happy-path turn lifecycle', () {
      final m = TurnStateMachine(agentId: 'self');
      expect(m.transition(TurnState.reflex), isTrue);
      expect(m.transition(TurnState.thinking), isTrue);
      expect(m.transition(TurnState.speaking), isTrue);
      expect(m.isSpeaking, isTrue);
      expect(m.transition(TurnState.reconcile), isTrue);
      expect(m.transition(TurnState.idle), isTrue);
      expect(m.isProcessing, isFalse);
    });

    test('rejects an illegal transition and keeps current state', () {
      final m = TurnStateMachine(agentId: 'self');
      m.transition(TurnState.reflex);
      expect(m.transition(TurnState.speaking), isFalse);
      expect(m.state.value, TurnState.reflex);
    });

    test('a no-op transition to the current state succeeds', () {
      final m = TurnStateMachine(agentId: 'self');
      m.transition(TurnState.reflex);
      expect(m.transition(TurnState.reflex), isTrue);
      expect(m.state.value, TurnState.reflex);
    });

    test(
      'barge-in transitions are legal (speaking<->listening, listening->reflex)',
      () {
        final m = TurnStateMachine(agentId: 'self');
        m.transition(TurnState.reflex);
        m.transition(TurnState.thinking);
        m.transition(TurnState.speaking);
        expect(m.transition(TurnState.listening), isTrue);
        expect(m.transition(TurnState.speaking), isTrue);
        m.transition(TurnState.listening);
        expect(m.transition(TurnState.reflex), isTrue);
      },
    );

    test('thinking can fall back to reflex (barge-in before any speech)', () {
      final m = TurnStateMachine(agentId: 'self');
      m.transition(TurnState.reflex);
      m.transition(TurnState.thinking);
      expect(m.transition(TurnState.reflex), isTrue);
    });

    test('reset() returns to idle from any state', () {
      final m = TurnStateMachine(agentId: 'self');
      m.transition(TurnState.reflex);
      m.transition(TurnState.thinking);
      m.transition(TurnState.speaking);
      m.reset();
      expect(m.state.value, TurnState.idle);
      expect(m.isProcessing, isFalse);
    });

    test('beginTurn() goes idle->reflex, and only from idle', () {
      final m = TurnStateMachine(agentId: 'self');
      expect(m.beginTurn(), isTrue);
      expect(m.state.value, TurnState.reflex);
      expect(m.beginTurn(), isFalse);
      expect(m.state.value, TurnState.reflex);
    });

    test('preempt() resets then begins a fresh turn', () {
      final m = TurnStateMachine(agentId: 'self');
      m.transition(TurnState.reflex);
      m.transition(TurnState.thinking);
      m.preempt();
      expect(m.state.value, TurnState.reflex);
    });
  });
}
