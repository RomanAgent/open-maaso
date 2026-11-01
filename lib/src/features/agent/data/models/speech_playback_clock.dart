/// Playback receipts shared by speech gestures and the existing TTS mouth.
///
/// This contains no audio, transcript or animation instruction. A renderer may
/// only calibrate an existing speech timeline; receiving a clock never grants
/// ownership of the mouth or starts a new utterance.
enum SpeechPlaybackClockState { start, update, pause, resume, stop }

enum SpeechPlaybackClockSource { wav, pcm, system }

final class SpeechPlaybackClock {
  SpeechPlaybackClock({
    required this.playbackId,
    required this.generation,
    required this.turnId,
    required this.utteranceId,
    required this.sequence,
    required this.state,
    required this.positionMs,
    required this.source,
    required this.authoritative,
    this.durationMs,
    List<double> envelope = const [],
    this.frameRate,
  }) : envelope = List<double>.unmodifiable(envelope) {
    for (final id in [playbackId, turnId, utteranceId]) {
      if (id.trim().isEmpty ||
          id.length > maximumIdentityLength ||
          RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(id)) {
        throw ArgumentError.value(id, 'playback identity');
      }
    }
    if (generation < 0 ||
        generation > maximumExactInteger ||
        sequence <= 0 ||
        sequence > maximumExactInteger ||
        positionMs < 0 ||
        positionMs > maximumPositionMs) {
      throw ArgumentError('Invalid playback clock receipt.');
    }
    if (durationMs != null &&
        (durationMs! < 0 ||
            durationMs! > maximumPositionMs ||
            positionMs > durationMs!)) {
      throw ArgumentError('Playback cursor exceeds its known duration.');
    }
    if (source == SpeechPlaybackClockSource.system && authoritative) {
      throw ArgumentError('System TTS has no authoritative playback cursor.');
    }
    if (this.envelope.isEmpty && frameRate != null && frameRate != 0) {
      throw ArgumentError('An envelope frame rate requires an envelope.');
    }
    if (this.envelope.isNotEmpty &&
        (state != SpeechPlaybackClockState.start ||
            this.envelope.length > 7200 ||
            frameRate == null ||
            frameRate! < 1 ||
            frameRate! > 120 ||
            this.envelope.any((v) => !v.isFinite || v < 0 || v > 1))) {
      throw ArgumentError('Invalid session-bound acoustic envelope.');
    }
  }

  static const int protocolVersion = 1;
  static const int maximumIdentityLength = 160;
  static const int maximumExactInteger = 9007199254740991;
  static const int maximumPositionMs = 86400000;

  final String playbackId;
  final int generation;
  final String turnId;
  final String utteranceId;
  final int sequence;
  final SpeechPlaybackClockState state;
  final int positionMs;
  final int? durationMs;
  final SpeechPlaybackClockSource source;

  /// False until a native position is observed. System TTS never sets this.
  final bool authoritative;

  /// Sent once with the start receipt from the exact same synthesized WAV.
  /// Receivers must never bind an unrelated legacy envelope to this identity.
  final List<double> envelope;
  final int? frameRate;

  SpeechPlaybackClock withoutAcousticEnvelope() => SpeechPlaybackClock(
    playbackId: playbackId,
    generation: generation,
    turnId: turnId,
    utteranceId: utteranceId,
    sequence: sequence,
    state: state,
    positionMs: positionMs,
    durationMs: durationMs,
    source: source,
    authoritative: authoritative,
  );

  Map<String, Object?> toJson() => {
    'protocolVersion': protocolVersion,
    'playbackId': playbackId,
    'generation': generation,
    'turnId': turnId,
    'utteranceId': utteranceId,
    'sequence': sequence,
    'state': state.name,
    'positionMs': positionMs,
    if (durationMs != null) 'durationMs': durationMs,
    'source': source.name,
    'authoritative': authoritative,
    if (envelope.isNotEmpty) 'envelope': envelope,
    if (envelope.isNotEmpty) 'frameRate': frameRate,
  };
}
