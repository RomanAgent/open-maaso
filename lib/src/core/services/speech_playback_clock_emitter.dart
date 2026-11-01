import 'dart:convert';

import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

/// Bounds renderer calibration to four updates per second. Lifecycle receipts
/// are never throttled. Producers keep their native cursor polling ownership;
/// this helper has no timer and never delays audio playback.
final class SpeechPlaybackClockEmitter {
  SpeechPlaybackClockEmitter({
    required String playbackId,
    required this.nativeGeneration,
    required this.turnId,
    required this.utteranceId,
    required this.source,
    required this.agentId,
    Duration Function()? elapsed,
    void Function(SpeechPlaybackClock)? emit,
  }) : generation = _nextGeneration(),
       _elapsed = elapsed ?? (Stopwatch()..start()).elapsedGetter,
       _emit =
           emit ??
           ((clock) => EventBus().fire(
             SpeechPlaybackClockEvent(clock, agentId: agentId),
           )) {
    this.playbackId = '$playbackId-$generation';
  }

  static const updateInterval = Duration(milliseconds: 250);
  // Desktop sidecars cap the whole outer command at 32 KiB. Leave framing and
  // identity headroom. Oversize data degrades to cursor/lifecycle only; it is
  // never downsampled and claimed to be the original acoustic envelope.
  static const maximumStartPacketBytes = 24 * 1024;

  static int _generationHighWater = 0;
  static int _nextGeneration() {
    final now = DateTime.now().microsecondsSinceEpoch;
    return _generationHighWater = now > _generationHighWater
        ? now
        : _generationHighWater + 1;
  }

  late final String playbackId;
  final int generation;
  final int nativeGeneration;
  final String turnId;
  final String utteranceId;
  final SpeechPlaybackClockSource source;
  final String? agentId;
  final Duration Function() _elapsed;
  final void Function(SpeechPlaybackClock) _emit;
  int _sequence = 0;
  int _positionMs = 0;
  int? _durationMs;
  Duration? _lastUpdate;
  bool _started = false;
  bool _paused = false;
  bool _stopped = false;
  bool _authoritative = false;

  void start({
    int positionMs = 0,
    int? durationMs,
    bool authoritative = false,
    List<double> envelope = const [],
    int? frameRate,
  }) {
    if (_started || _stopped) return;
    _started = true;
    _acceptPosition(positionMs, durationMs, authoritative);
    _send(
      SpeechPlaybackClockState.start,
      envelope: envelope,
      frameRate: frameRate,
    );
  }

  void observe(int positionMs, {int? durationMs}) {
    if (!_started || _stopped || positionMs < _positionMs) return;
    final changed = positionMs != _positionMs || !_authoritative;
    _acceptPosition(positionMs, durationMs, true);
    // audioplayers publishes its final native cursor after acknowledging
    // pause. Preserve that exact frozen cursor, without resuming the clock.
    if (_paused) {
      if (changed) _send(SpeechPlaybackClockState.pause);
      return;
    }
    final now = _elapsed();
    if (_lastUpdate != null && now - _lastUpdate! < updateInterval) return;
    _send(SpeechPlaybackClockState.update);
  }

  void pause() {
    if (!_started || _stopped || _paused) return;
    _paused = true;
    _send(SpeechPlaybackClockState.pause);
  }

  void resume() {
    if (!_started || _stopped || !_paused) return;
    _paused = false;
    _send(SpeechPlaybackClockState.resume);
  }

  void stop() {
    if (!_started || _stopped) return;
    _stopped = true;
    _send(SpeechPlaybackClockState.stop);
  }

  void _acceptPosition(int positionMs, int? durationMs, bool authoritative) {
    if (positionMs < 0) return;
    if (durationMs != null && durationMs >= 0) _durationMs = durationMs;
    _positionMs = _durationMs == null
        ? positionMs
        : positionMs.clamp(0, _durationMs!);
    _authoritative = authoritative;
  }

  void _send(
    SpeechPlaybackClockState state, {
    List<double> envelope = const [],
    int? frameRate,
  }) {
    _lastUpdate = _elapsed();
    var clock = SpeechPlaybackClock(
      playbackId: playbackId,
      generation: generation,
      turnId: turnId,
      utteranceId: utteranceId,
      sequence: ++_sequence,
      state: state,
      positionMs: _positionMs,
      durationMs: _durationMs,
      source: source,
      authoritative: _authoritative,
      envelope: envelope,
      frameRate: frameRate,
    );
    if (clock.envelope.isNotEmpty &&
        utf8.encode(jsonEncode(clock.toJson())).length >
            maximumStartPacketBytes) {
      clock = clock.withoutAcousticEnvelope();
    }
    _emit(clock);
  }
}

extension on Stopwatch {
  Duration elapsedGetter() => elapsed;
}
