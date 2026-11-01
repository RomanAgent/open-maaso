import 'dart:math' as math;

enum VoiceOrbPhase { listening, recognizing, thinking, speaking }

VoiceOrbPhase resolveVoiceOrbPhase({
  required bool playbackActive,
  required bool awaitingFinal,
  required bool isThinking,
}) {
  if (playbackActive) return VoiceOrbPhase.speaking;
  if (awaitingFinal) return VoiceOrbPhase.recognizing;
  if (isThinking) return VoiceOrbPhase.thinking;
  return VoiceOrbPhase.listening;
}

double normalizeVoiceOrbAmplitude(double amplitude) {
  final clamped = amplitude.clamp(0.0, 1.0).toDouble();
  return math.pow(clamped, 0.65).toDouble();
}

double smoothVoiceOrbAmplitude({
  required double from,
  required double to,
  required double t,
}) {
  final progress = t.clamp(0.0, 1.0).toDouble();
  return from + (to - from) * progress;
}
