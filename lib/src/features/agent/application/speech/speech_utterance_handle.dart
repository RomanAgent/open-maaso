/// A terminal result for one host-identified utterance. Only a real playback
/// completion receipt can produce [SpeechTerminal.completed].
enum SpeechTerminal { completed, cancelled, failed, timedOut }

/// One logical reply with a voice configuration selected once by the host.
abstract interface class SpeechTurnHandle {
  String get turnId;
  SpeechUtteranceHandle speak({
    required String utteranceId,
    required String text,
  });
  Future<void> cancel([String reason = 'cancelled']);
  Future<void> get drained;
}

/// Playback identity is assigned by the conversation host, not by a model.
///
/// [started] resolves false when the utterance terminates before playback.
/// Terminal results never throw. [cancel] revokes playback immediately; a
/// synthesis operation which cannot be interrupted remains observable through
/// [drained], and its late result must never start audio.
abstract interface class SpeechUtteranceHandle {
  String get turnId;
  String get utteranceId;
  Future<bool> get started;
  Future<SpeechTerminal> get terminal;
  Future<void> cancel([String reason = 'cancelled']);
  Future<void> get drained;
}
