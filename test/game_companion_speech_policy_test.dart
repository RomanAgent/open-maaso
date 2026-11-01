import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_speech_policy.dart';

void main() {
  final now = DateTime.utc(2026, 10, 22, 12);
  final session = GameCompanionSessionKey(
    scopeKey: 'account',
    playerId: 'game',
    documentGeneration: 1,
    sessionGeneration: 1,
  );
  final moment = GameCompanionMoment(
    id: 'event',
    sessionKey: session,
    roundGeneration: 1,
    scope: GameCompanionMomentScope.occurredEvent,
    kind: 'any.new.kind',
    summary: 'Something happened.',
    observedAt: now.subtract(const Duration(seconds: 1)),
    expiresAt: now.add(const Duration(seconds: 30)),
  );
  final policy = GameCompanionSpeechPolicy(maxAttemptsPerWindow: 2);
  GameCompanionSpeechAdmission evaluate({
    GameCompanionPreferences preferences = const GameCompanionPreferences(
      enabled: true,
    ),
    bool sound = true,
    bool available = true,
    bool user = false,
    bool focus = false,
    List<DateTime> attempts = const [],
    DateTime? spoken,
    Set<String> spokenIds = const {},
    GameCompanionMoment? candidate,
    int round = 1,
    int position = 4,
    DateTime? clock,
  }) => policy.evaluate(
    now: clock ?? now,
    preferences: preferences,
    moment: candidate ?? moment,
    currentSession: session,
    currentRoundGeneration: round,
    currentPositionRevision: position,
    soundEnabled: sound,
    runtimeAvailable: available,
    userInputPending: user,
    focusRequiresSilence: focus,
    attempts: attempts,
    lastSpeechStartedAt: spoken,
    spokenMomentIds: spokenIds,
  );

  test(
    'user input, mute, quiet preference and busy runtime deny autonomous speech',
    () {
      expect(evaluate(), GameCompanionSpeechAdmission.allowed);
      expect(
        evaluate(user: true),
        GameCompanionSpeechAdmission.priorityUserInput,
      );
      expect(evaluate(sound: false), GameCompanionSpeechAdmission.muted);
      expect(
        evaluate(available: false),
        GameCompanionSpeechAdmission.runtimeBusy,
      );
      expect(evaluate(focus: true), GameCompanionSpeechAdmission.focusedPlay);
      expect(
        evaluate(preferences: const GameCompanionPreferences(enabled: false)),
        GameCompanionSpeechAdmission.disabled,
      );
      expect(
        evaluate(
          preferences: const GameCompanionPreferences(
            enabled: true,
            talkativeness: GameCompanionTalkativeness.quiet,
          ),
        ),
        GameCompanionSpeechAdmission.quietPreference,
      );
    },
  );

  test(
    'new frames preserve an occurred event, but position, round and expiry fences hold',
    () {
      expect(evaluate(position: 900), GameCompanionSpeechAdmission.allowed);
      expect(evaluate(round: 2), GameCompanionSpeechAdmission.wrongRound);
      expect(
        evaluate(clock: moment.expiresAt),
        GameCompanionSpeechAdmission.expired,
      );
      final position = GameCompanionMoment(
        id: 'position',
        sessionKey: session,
        roundGeneration: 1,
        positionRevision: 4,
        scope: GameCompanionMomentScope.currentPosition,
        kind: 'look',
        summary: 'The piece is on the left.',
        observedAt: now,
        expiresAt: now.add(const Duration(seconds: 5)),
      );
      expect(
        evaluate(candidate: position),
        GameCompanionSpeechAdmission.allowed,
      );
      expect(
        evaluate(candidate: position, position: 5),
        GameCompanionSpeechAdmission.changedPosition,
      );
    },
  );

  test('attempt spacing and actual speech cooldown are independent', () {
    expect(
      evaluate(attempts: [now.subtract(const Duration(seconds: 1))]),
      GameCompanionSpeechAdmission.attemptCooldown,
    );
    expect(
      evaluate(attempts: [now.subtract(const Duration(seconds: 3))]),
      GameCompanionSpeechAdmission.allowed,
    );
    expect(
      evaluate(spoken: now.subtract(const Duration(seconds: 10))),
      GameCompanionSpeechAdmission.speechCooldown,
    );
    expect(
      evaluate(attempts: [now.subtract(const Duration(seconds: 10))]),
      GameCompanionSpeechAdmission.allowed,
      reason: 'A silent/failed attempt is not a spoken sentence.',
    );
    expect(
      evaluate(
        spoken: now.subtract(const Duration(seconds: 10)),
        preferences: const GameCompanionPreferences(
          enabled: true,
          talkativeness: GameCompanionTalkativeness.chatty,
        ),
      ),
      GameCompanionSpeechAdmission.allowed,
    );
  });

  test(
    'rolling dispatch budgets expire and backwards clocks do not replenish them',
    () {
      expect(
        evaluate(
          attempts: [
            now.subtract(const Duration(seconds: 20)),
            now.subtract(const Duration(seconds: 10)),
          ],
        ),
        GameCompanionSpeechAdmission.attemptBudget,
      );
      expect(
        evaluate(
          attempts: [
            now.subtract(const Duration(minutes: 1)),
            now.subtract(const Duration(seconds: 10)),
          ],
        ),
        GameCompanionSpeechAdmission.allowed,
      );
      expect(
        evaluate(
          attempts: [
            now.add(const Duration(seconds: 1)),
            now.add(const Duration(seconds: 2)),
          ],
        ),
        GameCompanionSpeechAdmission.attemptBudget,
      );
      expect(
        evaluate(spoken: now.add(const Duration(seconds: 1))),
        GameCompanionSpeechAdmission.speechCooldown,
      );
    },
  );

  test('played moments and normalized repeated lines are suppressed', () {
    expect(
      evaluate(spokenIds: {'event'}),
      GameCompanionSpeechAdmission.duplicate,
    );
    expect(policy.isRepeatedReply('  NICE\nmove! ', ['Nice move!']), isTrue);
    expect(
      policy.isRepeatedReply('Another observation.', ['Nice move!']),
      isFalse,
    );
    expect(policy.isRepeatedReply(' ', ['']), isFalse);
  });
}
