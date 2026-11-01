import 'game_companion_context.dart';

enum GameCompanionSpeechAdmission {
  allowed,
  disabled,
  muted,
  quietPreference,
  runtimeBusy,
  priorityUserInput,
  focusedPlay,
  wrongSession,
  wrongRound,
  expired,
  changedPosition,
  duplicate,
  attemptBudget,
  attemptCooldown,
  speechCooldown,
}

/// Pure automatic-speech admission. It neither queues work nor grants a tool
/// capability. Host scheduling records actual dispatches and speech starts.
final class GameCompanionSpeechPolicy {
  GameCompanionSpeechPolicy({
    this.attemptWindow = const Duration(minutes: 1),
    this.maxAttemptsPerWindow = 8,
    this.minimumAttemptSpacing = const Duration(seconds: 3),
    this.balancedSpeechInterval = const Duration(seconds: 20),
    this.chattySpeechInterval = const Duration(seconds: 8),
  }) {
    if (attemptWindow <= Duration.zero ||
        maxAttemptsPerWindow < 1 ||
        maxAttemptsPerWindow > 60 ||
        minimumAttemptSpacing < Duration.zero ||
        balancedSpeechInterval < Duration.zero ||
        chattySpeechInterval < Duration.zero) {
      throw ArgumentError('Invalid companion speech budget.');
    }
  }
  final Duration attemptWindow, minimumAttemptSpacing;
  final Duration balancedSpeechInterval, chattySpeechInterval;
  final int maxAttemptsPerWindow;

  GameCompanionSpeechAdmission evaluate({
    required DateTime now,
    required GameCompanionPreferences preferences,
    required GameCompanionMoment moment,
    required GameCompanionSessionKey currentSession,
    required int currentRoundGeneration,
    int? currentPositionRevision,
    required bool soundEnabled,
    required bool runtimeAvailable,
    bool userInputPending = false,
    bool focusRequiresSilence = false,
    List<DateTime> attempts = const [],
    DateTime? lastSpeechStartedAt,
    Set<String> spokenMomentIds = const {},
    Duration? speechIntervalOverride,
  }) {
    if (!preferences.enabled) return GameCompanionSpeechAdmission.disabled;
    if (!soundEnabled) return GameCompanionSpeechAdmission.muted;
    if (userInputPending) return GameCompanionSpeechAdmission.priorityUserInput;
    if (preferences.talkativeness == GameCompanionTalkativeness.quiet) {
      return GameCompanionSpeechAdmission.quietPreference;
    }
    if (!runtimeAvailable) return GameCompanionSpeechAdmission.runtimeBusy;
    if (focusRequiresSilence) return GameCompanionSpeechAdmission.focusedPlay;
    if (moment.sessionKey != currentSession) {
      return GameCompanionSpeechAdmission.wrongSession;
    }
    if (moment.roundGeneration != currentRoundGeneration) {
      return GameCompanionSpeechAdmission.wrongRound;
    }
    if (now.isBefore(moment.observedAt) || !now.isBefore(moment.expiresAt)) {
      return GameCompanionSpeechAdmission.expired;
    }
    if (moment.scope == GameCompanionMomentScope.currentPosition &&
        moment.positionRevision != currentPositionRevision) {
      return GameCompanionSpeechAdmission.changedPosition;
    }
    if (spokenMomentIds.contains(moment.id)) {
      return GameCompanionSpeechAdmission.duplicate;
    }
    final interval =
        speechIntervalOverride ??
        (preferences.talkativeness == GameCompanionTalkativeness.chatty
            ? chattySpeechInterval
            : balancedSpeechInterval);
    if (interval < Duration.zero) {
      throw ArgumentError('Negative speech interval.');
    }
    if (lastSpeechStartedAt != null &&
        now.difference(lastSpeechStartedAt) < interval) {
      return GameCompanionSpeechAdmission.speechCooldown;
    }
    var inWindow = 0;
    DateTime? latestAttempt;
    for (final at in attempts) {
      // Future timestamps after a backwards clock jump remain charged; clock
      // correction must not silently replenish an attempt or speech budget.
      if (now.difference(at) < attemptWindow) inWindow++;
      if (latestAttempt == null || at.isAfter(latestAttempt)) {
        latestAttempt = at;
      }
    }
    if (inWindow >= maxAttemptsPerWindow) {
      return GameCompanionSpeechAdmission.attemptBudget;
    }
    if (latestAttempt != null &&
        now.difference(latestAttempt) < minimumAttemptSpacing) {
      return GameCompanionSpeechAdmission.attemptCooldown;
    }
    return GameCompanionSpeechAdmission.allowed;
  }

  /// Exact normalized repeat suppression, not a claim to judge humor/meaning.
  bool isRepeatedReply(String text, Iterable<String> recentReplies) {
    String key(String value) =>
        value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
    final candidate = key(text);
    return candidate.isNotEmpty &&
        recentReplies.any((previous) => key(previous) == candidate);
  }
}
