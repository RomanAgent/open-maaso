/// A capability for controlling one currently playing, host-identified speech
/// utterance.
///
/// Implementations must bind every operation to both [generation] and the
/// [turnId]/[utteranceId] identity. Methods return false after this lease loses
/// ownership, so a delayed acoustic result cannot pause, resume, or stop newer
/// speech. [spokenText] is the normalized text sent to synthesis and is kept in
/// memory for self-echo comparison; implementations must not write it to logs.
abstract interface class SpeechPlaybackLease {
  int get generation;
  String get turnId;
  String get utteranceId;
  String? get agentId;
  String get spokenText;

  Future<bool> pause();
  Future<bool> resume();
  Future<bool> stop([String reason = 'interrupted']);
}
