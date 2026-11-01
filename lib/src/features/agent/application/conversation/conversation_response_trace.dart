import 'package:maaso/src/core/services/turn_trace.dart';

enum ConversationResponseOutcome { completed, cancelled, failed }

/// Passive timings for one logical conversation, including input admission.
///
/// Text is measured at publication to UI subscribers, not at a rendered frame.
/// Audio is measured at the playback handle's started receipt, not acoustically.
/// Each event carries its own logical turn ID and monotonic elapsed time;
/// consumers must not correlate these events using TurnTrace's orphan fallback.
class ConversationResponseTrace {
  ConversationResponseTrace({
    required this.turnId,
    Duration Function()? elapsed,
    void Function(String, {String? details})? onEvent,
  }) : _elapsedOverride = elapsed,
       _onEvent = onEvent ?? TurnTrace.event;

  final String turnId;
  final Duration Function()? _elapsedOverride;
  final void Function(String, {String? details}) _onEvent;
  final Stopwatch _clock = Stopwatch()..start();
  int? _firstTextMicros;
  int? _firstAudioMicros;
  bool _finished = false;

  void recordPublished() {
    if (_finished || _firstTextMicros != null) return;
    final micros = _elapsedMicros;
    _firstTextMicros = micros;
    _emit(
      'conversation.response.first_text',
      'boundary=published elapsed_us=$micros',
    );
  }

  void recordAudioStarted() {
    if (_finished || _firstAudioMicros != null) return;
    final micros = _elapsedMicros;
    _firstAudioMicros = micros;
    _emit(
      'conversation.response.first_audio',
      'boundary=playback_handle_started elapsed_us=$micros',
    );
  }

  void finish(ConversationResponseOutcome outcome) {
    if (_finished) return;
    _finished = true;
    final micros = _elapsedMicros;
    _clock.stop();
    _emit(
      'conversation.response.completed',
      'outcome=${outcome.name} elapsed_us=$micros '
          'first_text_us=${_firstTextMicros ?? "unavailable"} '
          'first_audio_us=${_firstAudioMicros ?? "unavailable"}',
    );
  }

  int get _elapsedMicros =>
      (_elapsedOverride?.call() ?? _clock.elapsed).inMicroseconds;

  void _emit(String name, String details) {
    try {
      _onEvent(name, details: 'turn=$turnId $details');
    } catch (_) {
      // Diagnostics must never interrupt publication, speech, or sealing.
    }
  }
}
