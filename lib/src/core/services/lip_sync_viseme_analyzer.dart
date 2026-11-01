import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';

/// Pure-Dart, offline vowel and consonant animation analysis.
///
/// This intentionally avoids speech-model dependencies. Audio paths combine a
/// noise-aware RMS envelope with lightweight formant probes. The result is an
/// approximation suitable for animation, not a speech-recognition transcript.
abstract final class LipSyncVisemeAnalyzer {
  static const int _minSampleRate = 8000;
  static const int _maxSampleRate = 192000;
  static const int _maxChannels = 8;
  static const int _bytesPerSample = 2;
  static const int _maxPcmBytes = 64 * 1024 * 1024;
  static const int _maxTextRunes = 4096;
  static const double _absoluteSilenceRms = 1.5 / 32768.0;
  static const double _visemeSilenceLevel = 0.06;

  static const List<({LipSyncViseme viseme, double f1, double f2})> _formants =
      <({LipSyncViseme viseme, double f1, double f2})>[
        (viseme: LipSyncViseme.aa, f1: 780, f2: 1200),
        (viseme: LipSyncViseme.ih, f1: 300, f2: 2300),
        (viseme: LipSyncViseme.ou, f1: 350, f2: 800),
        (viseme: LipSyncViseme.ee, f1: 420, f2: 2000),
        (viseme: LipSyncViseme.oh, f1: 520, f2: 900),
      ];

  /// Analyzes a PCM WAV containing signed 16-bit little-endian samples.
  ///
  /// RIFF chunks may appear in any order and may contain odd-byte padding. WAV
  /// compression, floating-point samples, and more than [_maxChannels] are
  /// rejected explicitly instead of being misinterpreted as PCM.
  static LipSyncVisemeTrack analyzeWav(
    Uint8List wavBytes, {
    int frameRate = 30,
  }) {
    _validateFrameRate(frameRate);
    if (wavBytes.length < 12 ||
        !_hasAscii(wavBytes, 0, 'RIFF') ||
        !_hasAscii(wavBytes, 8, 'WAVE')) {
      throw const FormatException('Expected a RIFF/WAVE file');
    }

    final data = ByteData.sublistView(wavBytes);
    int? audioFormat;
    int? channels;
    int? sampleRate;
    int? blockAlign;
    int? bitsPerSample;
    int? pcmOffset;
    int? pcmLength;

    var offset = 12;
    while (offset + 8 <= wavBytes.length) {
      final chunkSize = data.getUint32(offset + 4, Endian.little);
      final chunkOffset = offset + 8;
      final chunkEnd = chunkOffset + chunkSize;
      if (chunkEnd > wavBytes.length) {
        throw const FormatException('WAV chunk extends beyond the file');
      }

      if (_hasAscii(wavBytes, offset, 'fmt ')) {
        if (chunkSize < 16) {
          throw const FormatException('WAV fmt chunk is too short');
        }
        audioFormat = data.getUint16(chunkOffset, Endian.little);
        channels = data.getUint16(chunkOffset + 2, Endian.little);
        sampleRate = data.getUint32(chunkOffset + 4, Endian.little);
        blockAlign = data.getUint16(chunkOffset + 12, Endian.little);
        bitsPerSample = data.getUint16(chunkOffset + 14, Endian.little);
      } else if (_hasAscii(wavBytes, offset, 'data') && pcmOffset == null) {
        pcmOffset = chunkOffset;
        pcmLength = chunkSize;
      }

      offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
    }

    if (audioFormat == null ||
        channels == null ||
        sampleRate == null ||
        blockAlign == null ||
        bitsPerSample == null ||
        pcmOffset == null ||
        pcmLength == null) {
      throw const FormatException('WAV is missing fmt or data');
    }
    if (audioFormat != 1 || bitsPerSample != 16) {
      throw FormatException(
        'Only uncompressed 16-bit PCM WAV is supported '
        '(format=$audioFormat, bits=$bitsPerSample)',
      );
    }
    if (blockAlign != channels * _bytesPerSample) {
      throw const FormatException('WAV block alignment is inconsistent');
    }

    return analyzePcmS16le(
      Uint8List.sublistView(wavBytes, pcmOffset, pcmOffset + pcmLength),
      sampleRate: sampleRate,
      channels: channels,
      frameRate: frameRate,
      closeAtEnd: true,
    );
  }

  /// Analyzes interleaved signed 16-bit little-endian PCM.
  ///
  /// Set [closeAtEnd] to false for a chunk in an ongoing stream; a network
  /// boundary is not an utterance boundary. Completed clips close by default.
  static LipSyncVisemeTrack analyzePcmS16le(
    Uint8List pcmBytes, {
    required int sampleRate,
    required int channels,
    int frameRate = 30,
    bool closeAtEnd = true,
  }) {
    _validateAudioArguments(
      pcmBytes,
      sampleRate: sampleRate,
      channels: channels,
      frameRate: frameRate,
    );
    if (pcmBytes.isEmpty) {
      throw const FormatException('PCM input must not be empty');
    }

    final sampleCount = pcmBytes.length ~/ (_bytesPerSample * channels);
    final samples = Float64List(sampleCount);
    final data = ByteData.sublistView(pcmBytes);
    for (var sample = 0; sample < sampleCount; sample++) {
      var mixed = 0.0;
      final sampleOffset = sample * channels * _bytesPerSample;
      for (var channel = 0; channel < channels; channel++) {
        mixed += data.getInt16(
          sampleOffset + channel * _bytesPerSample,
          Endian.little,
        );
      }
      samples[sample] = mixed / (channels * 32768.0);
    }

    final rms = _rmsFrames(samples, sampleRate, frameRate);
    final envelope = _adaptiveEnvelope(rms, closeAtEnd: closeAtEnd);
    final states = _audioVisemes(
      samples,
      sampleRate: sampleRate,
      frameRate: frameRate,
      envelope: envelope,
      rawRms: rms,
    );
    return LipSyncVisemeTrack(
      envelope: envelope,
      cues: _sparseCues(states, debounceSpeech: true),
      frameRate: frameRate,
    );
  }

  /// Adds approximate visemes when system TTS exposes text and an envelope but
  /// no PCM or phoneme timestamps.
  ///
  /// Literal Latin a/i/u/e/o map directly. Other scripts use a deterministic
  /// rotating fallback so system TTS remains expressive without pretending to
  /// perform linguistic transcription.
  static LipSyncVisemeTrack fromTextEnvelope(
    String text,
    List<double> envelope, {
    int frameRate = 30,
  }) {
    _validateFrameRate(frameRate);
    final runeCount = text.runes.length;
    if (runeCount > _maxTextRunes) {
      throw RangeError.range(runeCount, 0, _maxTextRunes, 'text.runes.length');
    }
    if (envelope.length > LipSyncVisemeTrack.maxEnvelopeFrames) {
      throw RangeError.range(
        envelope.length,
        0,
        LipSyncVisemeTrack.maxEnvelopeFrames,
        'envelope.length',
      );
    }
    for (var frame = 0; frame < envelope.length; frame++) {
      final value = envelope[frame];
      if (!value.isFinite || value < 0 || value > 1) {
        throw RangeError.range(value, 0, 1, 'envelope[$frame]');
      }
    }
    if (envelope.isEmpty) {
      throw ArgumentError.value(envelope, 'envelope', 'Must not be empty');
    }

    final enhancedEnvelope = _adaptiveEnvelope(envelope);
    final tokens = _textVisemes(text);
    final states = List<LipSyncViseme>.filled(
      enhancedEnvelope.length,
      LipSyncViseme.sil,
      growable: false,
    );
    for (var frame = 0; frame < states.length; frame++) {
      if (enhancedEnvelope[frame] <= _visemeSilenceLevel) continue;
      final token = math.min(
        tokens.length - 1,
        frame * tokens.length ~/ states.length,
      );
      states[frame] = tokens[token];
    }

    return LipSyncVisemeTrack(
      envelope: enhancedEnvelope,
      cues: _sparseCues(states, debounceSpeech: false),
      frameRate: frameRate,
    );
  }

  static List<double> _rmsFrames(
    Float64List samples,
    int sampleRate,
    int frameRate,
  ) {
    final frameCount =
        (samples.length * frameRate + sampleRate - 1) ~/ sampleRate;
    final output = List<double>.filled(frameCount, 0, growable: false);
    for (var frame = 0; frame < frameCount; frame++) {
      final start = frame * sampleRate ~/ frameRate;
      final end = math.min(
        samples.length,
        (frame + 1) * sampleRate ~/ frameRate,
      );
      var sumSquares = 0.0;
      var mean = 0.0;
      for (var sample = start; sample < end; sample++) {
        mean += samples[sample];
      }
      mean /= end - start;
      for (var sample = start; sample < end; sample++) {
        final centered = samples[sample] - mean;
        sumSquares += centered * centered;
      }
      output[frame] = math.sqrt(sumSquares / (end - start));
    }
    return output;
  }

  static List<double> _adaptiveEnvelope(
    List<double> raw, {
    bool closeAtEnd = true,
  }) {
    if (raw.isEmpty) return const <double>[];
    final activePeak = raw.fold<double>(0, math.max);
    if (activePeak <= _absoluteSilenceRms) {
      return List<double>.filled(raw.length, 0, growable: false);
    }

    final sorted = List<double>.of(raw)..sort();
    final low = _percentile(sorted, 0.20);
    final high = math.max(_percentile(sorted, 0.90), activePeak * 0.72);
    final hasDynamicFloor = high > low * 1.45 && high - low > 0.00015;
    final noiseFloor = hasDynamicFloor ? low * 0.90 : 0.0;
    final dynamicRange = math.max(high - noiseFloor, _absoluteSilenceRms);
    final gate = math.max(
      _absoluteSilenceRms,
      noiseFloor + dynamicRange * 0.035,
    );

    final targets = List<double>.filled(raw.length, 0, growable: false);
    for (var frame = 0; frame < raw.length; frame++) {
      final value = raw[frame];
      if (value <= gate) continue;
      final normalized = ((value - noiseFloor) / dynamicRange).clamp(0.0, 1.0);
      final shaped = math.pow(normalized, 0.58).toDouble();
      targets[frame] = (0.18 + shaped * 0.82).clamp(0.0, 1.0);
    }

    final output = List<double>.filled(raw.length, 0, growable: false);
    var smoothed = 0.0;
    for (var frame = 0; frame < targets.length; frame++) {
      final target = targets[frame];
      final coefficient = target > smoothed ? 0.72 : 0.34;
      smoothed += coefficient * (target - smoothed);
      if (target == 0 && smoothed < 0.018) smoothed = 0;
      output[frame] = smoothed.clamp(0.0, 1.0);
    }
    if (closeAtEnd && output.length > 1) output[output.length - 1] = 0;
    return output;
  }

  static List<LipSyncViseme> _audioVisemes(
    Float64List samples, {
    required int sampleRate,
    required int frameRate,
    required List<double> envelope,
    required List<double> rawRms,
  }) {
    final states = List<LipSyncViseme>.filled(
      envelope.length,
      LipSyncViseme.sil,
      growable: false,
    );
    for (var frame = 0; frame < envelope.length; frame++) {
      // A smoothed release can outlast the actual sound. Classifying its zero
      // spectrum would select Aa by tie-break even though this frame is silent.
      if (envelope[frame] <= _visemeSilenceLevel ||
          rawRms[frame] <= _absoluteSilenceRms) {
        continue;
      }
      final start = frame * sampleRate ~/ frameRate;
      final end = math.min(
        samples.length,
        (frame + 1) * sampleRate ~/ frameRate,
      );
      states[frame] = end - start < 48
          ? LipSyncViseme.aa
          : _classifyFormants(samples, start, end, sampleRate);
    }

    if (states.length < 3) return states;
    final filtered = List<LipSyncViseme>.of(states, growable: false);
    for (var frame = 1; frame < states.length - 1; frame++) {
      if (states[frame] == LipSyncViseme.sil) continue;
      if (states[frame - 1] == states[frame + 1] &&
          states[frame - 1] != LipSyncViseme.sil) {
        filtered[frame] = states[frame - 1];
      }
    }
    return filtered;
  }

  static LipSyncViseme _classifyFormants(
    Float64List samples,
    int start,
    int end,
    int sampleRate,
  ) {
    // Unvoiced broadband frication has no stable formants. Give it a small
    // labiodental articulation instead of choosing Aa by vowel tie-break.
    // This remains acoustic animation, not a claim to transcribe /f/ vs /s/.
    var crossings = 0;
    for (var i = start + 1; i < end; i++) {
      if ((samples[i] >= 0) != (samples[i - 1] >= 0)) crossings++;
    }
    final crossingRate = crossings / math.max(1, end - start - 1);
    if (sampleRate >= 12000 && crossingRate > .22) {
      final high = _nearbyBandEnergy(samples, start, end, sampleRate, 3300);
      final low = _nearbyBandEnergy(samples, start, end, sampleRate, 500);
      final upperVowel = _nearbyBandEnergy(
        samples,
        start,
        end,
        sampleRate,
        2300,
      );
      if (high > (math.max(low, upperVowel) + 1e-12) * 5) {
        return LipSyncViseme.ff;
      }
    }
    var best = LipSyncViseme.aa;
    var bestScore = -1.0;
    for (final candidate in _formants) {
      final first = _nearbyBandEnergy(
        samples,
        start,
        end,
        sampleRate,
        candidate.f1,
      );
      final second = _nearbyBandEnergy(
        samples,
        start,
        end,
        sampleRate,
        candidate.f2,
      );
      final score = math.sqrt((first + 1e-18) * (second + 1e-18));
      if (score > bestScore) {
        bestScore = score;
        best = candidate.viseme;
      }
    }
    return best;
  }

  static double _nearbyBandEnergy(
    Float64List samples,
    int start,
    int end,
    int sampleRate,
    double center,
  ) {
    var energy = 0.0;
    for (final offset in const <double>[-55, 0, 55]) {
      energy = math.max(
        energy,
        _goertzelEnergy(samples, start, end, sampleRate, center + offset),
      );
    }
    return energy;
  }

  static double _goertzelEnergy(
    Float64List samples,
    int start,
    int end,
    int sampleRate,
    double frequency,
  ) {
    if (frequency <= 0 || frequency >= sampleRate / 2) return 0;
    final coefficient = 2 * math.cos(2 * math.pi * frequency / sampleRate);
    var previous = 0.0;
    var previousPrevious = 0.0;
    final length = end - start;
    for (var index = 0; index < length; index++) {
      final window = length == 1
          ? 1.0
          : 0.5 - 0.5 * math.cos(2 * math.pi * index / (length - 1));
      final current =
          samples[start + index] * window +
          coefficient * previous -
          previousPrevious;
      previousPrevious = previous;
      previous = current;
    }
    return math.max(
      0,
      previous * previous +
          previousPrevious * previousPrevious -
          coefficient * previous * previousPrevious,
    );
  }

  static List<LipSyncVisemeCue> _sparseCues(
    List<LipSyncViseme> states, {
    required bool debounceSpeech,
  }) {
    if (states.isEmpty) return const <LipSyncVisemeCue>[];
    final cues = <LipSyncVisemeCue>[
      LipSyncVisemeCue(frame: 0, viseme: states.first),
    ];
    var current = states.first;
    var pending = current;
    var pendingStart = 0;
    var pendingCount = 0;

    for (var frame = 1; frame < states.length; frame++) {
      final candidate = states[frame];
      if (candidate == current) {
        pending = current;
        pendingCount = 0;
        continue;
      }
      if (candidate != pending) {
        pending = candidate;
        pendingStart = frame;
        pendingCount = 1;
      } else {
        pendingCount++;
      }

      final requiredFrames = !debounceSpeech || candidate == LipSyncViseme.sil
          ? 1
          : 2;
      if (pendingCount < requiredFrames) continue;
      cues.add(LipSyncVisemeCue(frame: pendingStart, viseme: candidate));
      current = candidate;
      pendingCount = 0;
    }

    if (cues.length > LipSyncVisemeTrack.maxCueCount) {
      throw StateError('Generated lip-sync cue count exceeds the wire limit');
    }
    return cues;
  }

  static List<LipSyncViseme> _textVisemes(String text) {
    final output = <LipSyncViseme>[];
    for (final rune in text.runes) {
      final lower = rune >= 0x41 && rune <= 0x5a ? rune + 0x20 : rune;
      final literal = switch (lower) {
        0x61 => LipSyncViseme.aa,
        0x69 || 0x79 => LipSyncViseme.ih,
        0x75 || 0x77 => LipSyncViseme.ou,
        0x65 => LipSyncViseme.ee,
        0x6f => LipSyncViseme.oh,
        0x62 || 0x6d || 0x70 => LipSyncViseme.pp,
        0x66 || 0x76 => LipSyncViseme.ff,
        _ => null,
      };
      if (literal != null) {
        if (output.isEmpty || output.last != literal) output.add(literal);
        continue;
      }
      if (_isAsciiLetter(lower) || _isWhitespace(rune)) continue;
      if (_isPausePunctuation(rune)) {
        if (output.isNotEmpty && output.last != LipSyncViseme.sil) {
          output.add(LipSyncViseme.sil);
        }
        continue;
      }

      final viseme = _formants[rune % _formants.length].viseme;
      if (output.isEmpty || output.last != viseme) output.add(viseme);
    }
    return output.isEmpty ? const <LipSyncViseme>[LipSyncViseme.aa] : output;
  }

  static bool _isAsciiLetter(int rune) => rune >= 0x61 && rune <= 0x7a;

  static bool _isWhitespace(int rune) =>
      rune == 0x20 || (rune >= 0x09 && rune <= 0x0d) || rune == 0x3000;

  static bool _isPausePunctuation(int rune) => switch (rune) {
    0x21 ||
    0x2c ||
    0x2e ||
    0x3a ||
    0x3b ||
    0x3f ||
    0x3001 ||
    0x3002 ||
    0xff01 ||
    0xff0c ||
    0xff1a ||
    0xff1b ||
    0xff1f => true,
    _ => false,
  };

  static double _percentile(List<double> sorted, double percentile) {
    final index = ((sorted.length - 1) * percentile).round();
    return sorted[index];
  }

  static bool _hasAscii(Uint8List bytes, int offset, String value) {
    if (offset < 0 || offset + value.length > bytes.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (bytes[offset + index] != value.codeUnitAt(index)) return false;
    }
    return true;
  }

  static void _validateAudioArguments(
    Uint8List pcmBytes, {
    required int sampleRate,
    required int channels,
    required int frameRate,
  }) {
    _validateFrameRate(frameRate);
    if (sampleRate < _minSampleRate || sampleRate > _maxSampleRate) {
      throw RangeError.range(
        sampleRate,
        _minSampleRate,
        _maxSampleRate,
        'sampleRate',
      );
    }
    if (channels < 1 || channels > _maxChannels) {
      throw RangeError.range(channels, 1, _maxChannels, 'channels');
    }
    if (pcmBytes.length > _maxPcmBytes) {
      throw RangeError.range(
        pcmBytes.length,
        0,
        _maxPcmBytes,
        'pcmBytes.length',
      );
    }
    final blockSize = channels * _bytesPerSample;
    if (pcmBytes.length % blockSize != 0) {
      throw FormatException(
        'PCM byte length must be divisible by the $blockSize-byte frame size',
      );
    }
    final sampleCount = pcmBytes.length ~/ blockSize;
    final outputFrames =
        (sampleCount * frameRate + sampleRate - 1) ~/ sampleRate;
    if (outputFrames > LipSyncVisemeTrack.maxEnvelopeFrames) {
      throw RangeError.range(
        outputFrames,
        0,
        LipSyncVisemeTrack.maxEnvelopeFrames,
        'outputFrames',
      );
    }
  }

  static void _validateFrameRate(int value) {
    if (value < LipSyncVisemeTrack.minFrameRate ||
        value > LipSyncVisemeTrack.maxFrameRate) {
      throw RangeError.range(
        value,
        LipSyncVisemeTrack.minFrameRate,
        LipSyncVisemeTrack.maxFrameRate,
        'frameRate',
      );
    }
  }
}
