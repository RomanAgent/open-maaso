import 'package:flutter/services.dart';

abstract class StreamingAudioSink {
  Future<void> start({required int sampleRate, required int channels});
  Future<void> write(Uint8List pcmS16le);
  Future<void> stop({bool drain = true});
}

enum StreamingAudioPlaybackTerminal { completed, cancelled }

enum StreamingAudioControlState { paused, resumed }

class StreamingAudioPlaybackReceipt {
  const StreamingAudioPlaybackReceipt({
    required this.generation,
    required this.terminal,
  });

  final int generation;
  final StreamingAudioPlaybackTerminal terminal;
}

abstract class VerifiedStreamingAudioSink implements StreamingAudioSink {
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({bool drain = true});
}

/// Generation-bound controls required by acoustic interruption.
///
/// The broader [StreamingAudioSink] contract stays unchanged because live
/// audio and probe callers do not own resumable speech. Conversation PCM uses
/// this narrower capability so a delayed pause or resume can never target a
/// replacement native player.
abstract class ControllableStreamingAudioSink
    implements VerifiedStreamingAudioSink {
  int? get activeGeneration;

  Future<StreamingAudioControlReceipt> pauseWithReceipt();

  Future<StreamingAudioControlReceipt> resumeWithReceipt();
}

/// A controllable sink that exposes the native player's generation-bound
/// playback cursor.
///
/// [acceptedFrames] counts frames accepted by the native playback queue while
/// [playedFrames] counts the prefix the native player has actually rendered.
/// Both counters are cumulative within one active generation.
abstract class PositionedStreamingAudioSink
    implements ControllableStreamingAudioSink {
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt();
}

class StreamingAudioControlReceipt {
  const StreamingAudioControlReceipt({
    required this.generation,
    required this.state,
  });

  final int generation;
  final StreamingAudioControlState state;
}

class StreamingAudioPlaybackPositionReceipt {
  const StreamingAudioPlaybackPositionReceipt({
    required this.generation,
    required this.playedFrames,
    required this.acceptedFrames,
  });

  final int generation;
  final int playedFrames;
  final int acceptedFrames;
}

class MethodChannelStreamingAudioSink implements PositionedStreamingAudioSink {
  MethodChannelStreamingAudioSink({
    MethodChannel channel = const MethodChannel('maaso/streaming_audio_sink'),
    bool Function()? voiceProcessingCaptureActive,
  }) : _channel = channel,
       _voiceProcessingCaptureActive = voiceProcessingCaptureActive;

  final MethodChannel _channel;
  // Read at playback start: capture can stop or restart between utterances.
  // The caller supplies actual VPIO state; ordinary recording is insufficient.
  final bool Function()? _voiceProcessingCaptureActive;
  static int _lastGeneration = 0;
  int? _generation;
  int? _drainingGeneration;
  int? _cancellingGeneration;
  int? _pausedGeneration;

  @override
  int? get activeGeneration => _generation;

  @override
  Future<void> start({required int sampleRate, required int channels}) async {
    final generation = _allocateGeneration();
    _generation = generation;
    _drainingGeneration = null;
    _cancellingGeneration = null;
    _pausedGeneration = null;
    try {
      final response = await _channel.invokeMethod<Object?>('start', {
        'sampleRate': sampleRate,
        'channels': channels,
        'generation': generation,
        'voiceProcessingCaptureActive':
            _voiceProcessingCaptureActive?.call() ?? false,
      });
      _expectAcknowledgement(response, generation, 'started');
    } catch (_) {
      if (_generation == generation) {
        _generation = null;
        _drainingGeneration = null;
        _cancellingGeneration = null;
        _pausedGeneration = null;
      }
      rethrow;
    }
  }

  @override
  Future<void> write(Uint8List pcmS16le) async {
    final generation = _generation;
    if (generation == null) {
      throw StateError('Streaming audio sink has not started.');
    }
    if (_drainingGeneration == generation ||
        _cancellingGeneration == generation) {
      throw StateError('Streaming audio sink no longer accepts writes.');
    }
    final response = await _channel.invokeMethod<Object?>('write', {
      'generation': generation,
      'pcm': pcmS16le,
    });
    _expectAcknowledgement(response, generation, 'accepted');
  }

  @override
  Future<StreamingAudioControlReceipt> pauseWithReceipt() async {
    final generation = _generation;
    if (generation == null || _cancellingGeneration == generation) {
      throw StateError('Streaming audio sink is not controllable.');
    }
    if (_pausedGeneration == generation) {
      return StreamingAudioControlReceipt(
        generation: generation,
        state: StreamingAudioControlState.paused,
      );
    }
    final response = await _channel.invokeMethod<Object?>('pause', {
      'generation': generation,
    });
    final receipt = _parseControlReceipt(
      response,
      generation,
      StreamingAudioControlState.paused,
    );
    if (_generation == generation && _cancellingGeneration != generation) {
      _pausedGeneration = generation;
    }
    return receipt;
  }

  @override
  Future<StreamingAudioControlReceipt> resumeWithReceipt() async {
    final generation = _generation;
    if (generation == null ||
        _cancellingGeneration == generation ||
        _pausedGeneration != generation) {
      throw StateError('Streaming audio sink is not paused.');
    }
    final response = await _channel.invokeMethod<Object?>('resume', {
      'generation': generation,
    });
    final receipt = _parseControlReceipt(
      response,
      generation,
      StreamingAudioControlState.resumed,
    );
    if (_generation == generation && _cancellingGeneration != generation) {
      _pausedGeneration = null;
    }
    return receipt;
  }

  @override
  Future<StreamingAudioPlaybackPositionReceipt> positionWithReceipt() async {
    final generation = _generation;
    if (generation == null || _cancellingGeneration == generation) {
      throw StateError('Streaming audio sink has no active playback cursor.');
    }
    final response = await _channel.invokeMethod<Object?>('position', {
      'generation': generation,
    });
    final receipt = _parsePositionReceipt(response, generation);
    if (_generation != generation || _cancellingGeneration == generation) {
      throw StateError(
        'Streaming audio position receipt belongs to a retired generation.',
      );
    }
    return receipt;
  }

  @override
  Future<void> stop({bool drain = true}) async {
    await stopWithReceipt(drain: drain);
  }

  @override
  Future<StreamingAudioPlaybackReceipt> stopWithReceipt({
    bool drain = true,
  }) async {
    final generation = _generation;
    if (generation == null) {
      return const StreamingAudioPlaybackReceipt(
        generation: 0,
        terminal: StreamingAudioPlaybackTerminal.cancelled,
      );
    }
    if (drain) {
      if (_cancellingGeneration == generation) {
        throw StateError('Streaming audio sink is already cancelling.');
      }
      if (_drainingGeneration == generation) {
        throw StateError('Streaming audio sink is already draining.');
      }
      _drainingGeneration = generation;
    } else {
      // Immediate stop is a semantic takeover. It is deliberately allowed to
      // preempt a pending drain; the native host closes both stop callbacks
      // with generation-bound cancelled receipts.
      _cancellingGeneration = generation;
    }
    try {
      final response = await _channel.invokeMethod<Object?>('stop', {
        'generation': generation,
        'drain': drain,
      });
      final receipt = _parseStopReceipt(response, generation, drain: drain);
      _clearGeneration(generation);
      return receipt;
    } catch (_) {
      _clearGeneration(generation);
      rethrow;
    }
  }

  void _clearGeneration(int generation) {
    if (_generation != generation) return;
    _generation = null;
    _drainingGeneration = null;
    _cancellingGeneration = null;
    _pausedGeneration = null;
  }

  static int _allocateGeneration() {
    final wallClock = DateTime.now().microsecondsSinceEpoch;
    final generation = wallClock > _lastGeneration
        ? wallClock
        : _lastGeneration + 1;
    _lastGeneration = generation;
    return generation;
  }

  static void _expectAcknowledgement(
    Object? response,
    int generation,
    String terminal,
  ) {
    final values = _receiptMap(response);
    if (_receiptGeneration(values) != generation ||
        values['terminal'] != terminal) {
      throw StateError(
        'Streaming audio $terminal acknowledgement did not match generation '
        '$generation.',
      );
    }
  }

  static StreamingAudioPlaybackReceipt _parseStopReceipt(
    Object? response,
    int generation, {
    required bool drain,
  }) {
    final values = _receiptMap(response);
    if (_receiptGeneration(values) != generation) {
      throw StateError(
        'Streaming audio stop receipt did not match generation $generation.',
      );
    }
    final terminal = switch (values['terminal']) {
      'completed' => StreamingAudioPlaybackTerminal.completed,
      'cancelled' => StreamingAudioPlaybackTerminal.cancelled,
      _ => throw StateError('Streaming audio stop returned no terminal state.'),
    };
    if (!drain && terminal != StreamingAudioPlaybackTerminal.cancelled) {
      throw StateError('Immediate streaming audio stop was not cancelled.');
    }
    return StreamingAudioPlaybackReceipt(
      generation: generation,
      terminal: terminal,
    );
  }

  static StreamingAudioControlReceipt _parseControlReceipt(
    Object? response,
    int generation,
    StreamingAudioControlState expected,
  ) {
    final values = _receiptMap(response);
    if (_receiptGeneration(values) != generation ||
        values['terminal'] != expected.name) {
      throw StateError(
        'Streaming audio ${expected.name} receipt did not match generation '
        '$generation.',
      );
    }
    return StreamingAudioControlReceipt(
      generation: generation,
      state: expected,
    );
  }

  static StreamingAudioPlaybackPositionReceipt _parsePositionReceipt(
    Object? response,
    int generation,
  ) {
    final values = _receiptMap(response);
    final playedFrames = _receiptNonNegativeInteger(values, 'playedFrames');
    final acceptedFrames = _receiptNonNegativeInteger(values, 'acceptedFrames');
    if (_receiptGeneration(values) != generation ||
        playedFrames == null ||
        acceptedFrames == null ||
        playedFrames > acceptedFrames) {
      throw StateError(
        'Streaming audio position receipt was invalid for generation '
        '$generation.',
      );
    }
    return StreamingAudioPlaybackPositionReceipt(
      generation: generation,
      playedFrames: playedFrames,
      acceptedFrames: acceptedFrames,
    );
  }

  static Map<Object?, Object?> _receiptMap(Object? response) {
    if (response is Map<Object?, Object?>) return response;
    if (response is Map) return Map<Object?, Object?>.of(response);
    throw StateError('Streaming audio host returned an invalid receipt.');
  }

  static int? _receiptGeneration(Map<Object?, Object?> values) {
    final value = values['generation'];
    if (value is int) return value;
    if (value is num && value.isFinite && value == value.truncate()) {
      return value.toInt();
    }
    return null;
  }

  static int? _receiptNonNegativeInteger(
    Map<Object?, Object?> values,
    String key,
  ) {
    final value = values[key];
    if (value is int) return value >= 0 ? value : null;
    if (value is num &&
        value.isFinite &&
        value == value.truncate() &&
        value >= 0) {
      return value.toInt();
    }
    return null;
  }
}
