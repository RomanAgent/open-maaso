/// Renderer-neutral vowel, closed-lip and labiodental mouth shapes.
/// Renderers without consonant morphs use neutral/nearby vowel fallbacks.
///
/// Wire names are deliberately lower-case and version-independent. Never use
/// [Enum.name] at the renderer boundary: changing a Dart enum case must not
/// silently change the signed avatar command protocol.
enum LipSyncViseme {
  sil('sil'),
  aa('aa'),
  ih('ih'),
  ou('ou'),
  ee('ee'),
  oh('oh'),
  pp('pp'),
  ff('ff');

  const LipSyncViseme(this.wireName);

  final String wireName;

  static LipSyncViseme fromWireName(String value) {
    for (final viseme in values) {
      if (viseme.wireName == value) return viseme;
    }
    throw FormatException('Unsupported lip-sync viseme: $value');
  }
}

/// A sparse viseme change at one frame in a [LipSyncVisemeTrack].
///
/// Amplitude is intentionally not duplicated here. The track envelope remains
/// the single intensity source while cues select the Aa/Ih/Ou/Ee/Oh shape.
final class LipSyncVisemeCue {
  factory LipSyncVisemeCue({
    required int frame,
    required LipSyncViseme viseme,
  }) {
    if (frame < 0) {
      throw RangeError.range(frame, 0, null, 'frame');
    }
    return LipSyncVisemeCue._(frame: frame, viseme: viseme);
  }

  const LipSyncVisemeCue._({required this.frame, required this.viseme});

  factory LipSyncVisemeCue.fromJson(Map<String, Object?> json) {
    const fields = <String>{'frame', 'viseme'};
    if (json.length != fields.length ||
        !json.keys.toSet().containsAll(fields)) {
      throw const FormatException(
        'A lip-sync cue must contain exactly frame and viseme',
      );
    }

    final rawFrame = json['frame'];
    final rawViseme = json['viseme'];
    if (rawFrame is! int || rawViseme is! String) {
      throw const FormatException(
        'Lip-sync cue frame must be an int and viseme must be a string',
      );
    }
    return LipSyncVisemeCue(
      frame: rawFrame,
      viseme: LipSyncViseme.fromWireName(rawViseme),
    );
  }

  final int frame;
  final LipSyncViseme viseme;

  Map<String, Object> toJson() => <String, Object>{
    'frame': frame,
    'viseme': viseme.wireName,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LipSyncVisemeCue &&
          frame == other.frame &&
          viseme == other.viseme;

  @override
  int get hashCode => Object.hash(frame, viseme);

  @override
  String toString() => 'LipSyncVisemeCue($frame, ${viseme.wireName})';
}

/// Bounded, immutable lip-sync data sent to an avatar renderer once per turn.
///
/// [envelope] contains one finite value in the closed range 0..1 per frame.
/// [cues] is sparse and its frame numbers must be strictly increasing. These
/// limits protect the command bridge from accidentally receiving an unbounded
/// waveform or a cue for every audio sample.
final class LipSyncVisemeTrack {
  factory LipSyncVisemeTrack({
    required List<double> envelope,
    required List<LipSyncVisemeCue> cues,
    int frameRate = 30,
  }) {
    _validateFrameRate(frameRate);
    if (envelope.length > maxEnvelopeFrames) {
      throw RangeError.range(
        envelope.length,
        0,
        maxEnvelopeFrames,
        'envelope.length',
      );
    }
    if (cues.length > maxCueCount) {
      throw RangeError.range(cues.length, 0, maxCueCount, 'cues.length');
    }
    if (envelope.isEmpty) {
      throw ArgumentError.value(envelope, 'envelope', 'Must not be empty');
    }
    if (cues.isEmpty) {
      throw ArgumentError.value(cues, 'cues', 'Must not be empty');
    }
    if (cues.first.frame != 0) {
      throw ArgumentError.value(
        cues.first.frame,
        'cues.first.frame',
        'The first cue must start at frame 0',
      );
    }

    final envelopeCopy = List<double>.of(envelope, growable: false);
    for (var frame = 0; frame < envelopeCopy.length; frame++) {
      final value = envelopeCopy[frame];
      if (!value.isFinite || value < 0 || value > 1) {
        throw RangeError.range(value, 0, 1, 'envelope[$frame]');
      }
    }

    final cueCopy = List<LipSyncVisemeCue>.of(cues, growable: false);
    var previousFrame = -1;
    for (var index = 0; index < cueCopy.length; index++) {
      final cue = cueCopy[index];
      if (cue.frame <= previousFrame) {
        throw ArgumentError.value(
          cue.frame,
          'cues[$index].frame',
          'Cue frames must be strictly increasing',
        );
      }
      if (cue.frame >= envelopeCopy.length) {
        throw RangeError.range(
          cue.frame,
          0,
          envelopeCopy.isEmpty ? 0 : envelopeCopy.length - 1,
          'cues[$index].frame',
        );
      }
      previousFrame = cue.frame;
    }

    return LipSyncVisemeTrack._(
      envelope: List<double>.unmodifiable(envelopeCopy),
      cues: List<LipSyncVisemeCue>.unmodifiable(cueCopy),
      frameRate: frameRate,
    );
  }

  const LipSyncVisemeTrack._({
    required this.envelope,
    required this.cues,
    required this.frameRate,
  });

  factory LipSyncVisemeTrack.fromRendererJson(Map<String, Object?> json) {
    const fields = <String>{'format', 'envelope', 'cues', 'frameRate'};
    if (json.length != fields.length ||
        !json.keys.toSet().containsAll(fields)) {
      throw const FormatException(
        'A lip-sync track must contain exactly format, envelope, cues, and frameRate',
      );
    }
    if (json['format'] != wireFormat) {
      throw FormatException('Unsupported lip-sync format: ${json['format']}');
    }

    final rawEnvelope = json['envelope'];
    final rawCues = json['cues'];
    final rawFrameRate = json['frameRate'];
    if (rawEnvelope is! List || rawCues is! List || rawFrameRate is! int) {
      throw const FormatException('Invalid lip-sync track field types');
    }

    final envelope = <double>[];
    for (final value in rawEnvelope) {
      if (value is! num) {
        throw const FormatException('Lip-sync envelope values must be numbers');
      }
      envelope.add(value.toDouble());
    }

    final cues = <LipSyncVisemeCue>[];
    for (final value in rawCues) {
      if (value is! Map) {
        throw const FormatException('Lip-sync cues must be objects');
      }
      cues.add(
        LipSyncVisemeCue.fromJson(
          value.map((key, value) => MapEntry(key.toString(), value)),
        ),
      );
    }
    return LipSyncVisemeTrack(
      envelope: envelope,
      cues: cues,
      frameRate: rawFrameRate,
    );
  }

  static const String wireFormat = 'vrm_viseme_v2';
  static const int minFrameRate = 1;
  static const int maxFrameRate = 120;
  static const int maxEnvelopeFrames = 7200;
  static const int maxCueCount = 2048;

  final List<double> envelope;
  final List<LipSyncVisemeCue> cues;
  final int frameRate;

  Duration get duration => Duration(
    microseconds: envelope.length * Duration.microsecondsPerSecond ~/ frameRate,
  );

  LipSyncViseme visemeAtFrame(int frame) {
    if (frame < 0 || frame >= envelope.length) {
      throw RangeError.range(
        frame,
        0,
        envelope.isEmpty ? 0 : envelope.length - 1,
        'frame',
      );
    }
    if (cues.isEmpty) return LipSyncViseme.sil;

    var low = 0;
    var high = cues.length - 1;
    var result = -1;
    while (low <= high) {
      final middle = low + ((high - low) >> 1);
      if (cues[middle].frame <= frame) {
        result = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return result < 0 ? LipSyncViseme.sil : cues[result].viseme;
  }

  Map<String, Object> toRendererJson() => <String, Object>{
    'format': wireFormat,
    'envelope': envelope,
    'cues': cues.map((cue) => cue.toJson()).toList(growable: false),
    'frameRate': frameRate,
  };

  static void _validateFrameRate(int value) {
    if (value < minFrameRate || value > maxFrameRate) {
      throw RangeError.range(value, minFrameRate, maxFrameRate, 'frameRate');
    }
  }
}
