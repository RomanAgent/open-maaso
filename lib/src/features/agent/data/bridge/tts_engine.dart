import 'dart:typed_data';

/// Pluggable neural-TTS backend for [TTSPlugin].
///
/// The core plugin has a built-in supertonic_flutter implementation as the
/// historical default.  Host code that wants a different engine registers it on
/// [TTSEngineRegistry.current] before any [TTSPlugin] is constructed; the
/// plugin then routes warm-up + synthesis through it instead of the
/// built-in path.
///
/// Kept intentionally narrow — language detection, lip-sync envelope, and
/// playback all stay in [TTSPlugin].  Engines only have to:
///   1. download / load their own model
///   2. take text → return 16-bit PCM WAV bytes
abstract class TTSEngine {
  /// One-time download + load.  Idempotent — calling twice after success
  /// should be a no-op.  Reports a 0..1 fraction via [onProgress] when
  /// download is in flight; pass a `null` fraction (or skip the call) when
  /// progress is unknown.
  ///
  /// Returns true iff the engine is ready to synthesize.
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress});

  /// Synthesize [text] into a complete 16-bit PCM WAV byte stream.  The
  /// caller (TTSPlugin) writes it to a temp file and hands it to
  /// audioplayers — the engine doesn't need to know about playback.
  ///
  /// [language] is a hint (`en`, `zh`, `ko`, etc.) for engines that need
  /// it; multilingual engines (Supertonic 3) usually ignore it because
  /// the text itself reveals the script.  [voice] is an opaque engine-
  /// specific identifier (sid number, speaker name, etc.) — null = default.
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  });

  /// True once [warmUp] has succeeded; cheap to call.
  bool get isReady;
}

class TtsAudioFrame {
  const TtsAudioFrame({
    required this.bytes,
    required this.sampleRate,
    required this.channels,
    required this.encoding,
    required this.sequence,
  });

  final Uint8List bytes;
  final int sampleRate;
  final int channels;
  final String encoding;
  final int sequence;
}

/// Stable identity for one text request in a correlated streaming TTS turn.
///
/// [textSequence] is the strictly increasing client request sequence. The
/// server echoes all four fields on every event for this segment. Audio frame
/// sequence numbers remain local to the segment and are carried by
/// [TtsAudioFrame.sequence].
class TtsSegmentIdentity {
  const TtsSegmentIdentity({
    required this.turnId,
    required this.textSequence,
    required this.utteranceId,
    required this.segmentOrdinal,
  });

  final String turnId;
  final int textSequence;
  final String utteranceId;
  final int segmentOrdinal;

  @override
  bool operator ==(Object other) =>
      other is TtsSegmentIdentity &&
      other.turnId == turnId &&
      other.textSequence == textSequence &&
      other.utteranceId == utteranceId &&
      other.segmentOrdinal == segmentOrdinal;

  @override
  int get hashCode =>
      Object.hash(turnId, textSequence, utteranceId, segmentOrdinal);
}

enum TtsSegmentEventKind { started, audio, completed, failed }

/// One ordered event from the request-correlated streaming TTS protocol.
///
/// Only [TtsSegmentEventKind.audio] carries [audioFrame]. Provider error text
/// is deliberately not retained in this transport-neutral contract.
class TtsSegmentEvent {
  const TtsSegmentEvent({
    required this.kind,
    required this.identity,
    this.audioFrame,
  });

  final TtsSegmentEventKind kind;
  final TtsSegmentIdentity identity;
  final TtsAudioFrame? audioFrame;
}

abstract class TtsSession {
  Stream<TtsAudioFrame> get audioFrames;
  Future<void> sendText(String text, {bool flush = false});
  Future<void> finish();
  Future<void> cancel([String reason = 'cancelled']);
}

/// Opt-in extension implemented only after the server advertises a correlated
/// segment protocol during the `started` handshake.
///
/// Callers must check [segmentProtocolVersion] before [sendSegment]. A zero
/// value preserves the legacy whole-session [TtsSession] behavior.
abstract interface class CorrelatedTtsSession implements TtsSession {
  String get turnId;
  int get segmentProtocolVersion;
  Stream<TtsSegmentEvent> get segmentEvents;

  Future<TtsSegmentIdentity> sendSegment({
    required String utteranceId,
    required String text,
    bool flush = false,
  });
}

abstract class FullDuplexTTSEngine implements TTSEngine {
  Future<TtsSession> openSession({
    required String turnId,
    String? language,
    String? voice,
  });
}

/// Single-double progress callback.  Optional `phase` lets the engine
/// surface a coarse stage label (e.g. "downloading", "extracting", "loading")
/// when the fraction alone is misleading (extraction can take 5–10 s while
/// the fraction sits at 1.0).
typedef TTSEngineWarmupProgress =
    void Function(double fraction, {String? phase});

/// Process-global registry.  Set [current] **before** constructing any
/// [TTSPlugin] (which happens whenever an AgentRuntime gets built).  Use
/// a plain static field rather than a DI container so the core stays free of
/// any host-app DI dependency.
class TTSEngineRegistry {
  /// The engine TTSPlugin will use.  Null = fall back to the legacy
  /// supertonic_flutter built-in path.
  static TTSEngine? current;
}
