import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/lip_sync_viseme_analyzer.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';

void main() {
  test(
    'text fallback articulates closed lips and labiodentals while ending silent',
    () {
      final track = LipSyncVisemeAnalyzer.fromTextEnvelope(
        'map five',
        List.filled(60, .7),
      );
      expect(
        track.cues.map((cue) => cue.viseme),
        containsAll([LipSyncViseme.pp, LipSyncViseme.ff]),
      );
      expect(track.visemeAtFrame(track.envelope.length - 1), LipSyncViseme.sil);
      final roundTrip = track.cues
          .map((cue) => LipSyncVisemeCue.fromJson(cue.toJson()))
          .toList();
      expect(roundTrip, track.cues);
    },
  );

  group('LipSyncVisemeTrack validation', () {
    test('uses strict bounded wire values and immutable collections', () {
      expect(LipSyncViseme.values.map((value) => value.wireName), <String>[
        'sil',
        'aa',
        'ih',
        'ou',
        'ee',
        'oh',
        'pp',
        'ff',
      ]);
      expect(LipSyncVisemeTrack.wireFormat, 'vrm_viseme_v2');
      expect(LipSyncVisemeTrack.maxEnvelopeFrames, 7200);
      expect(LipSyncVisemeTrack.maxCueCount, 2048);

      final sourceEnvelope = <double>[0, 0.7, 0];
      final sourceCues = <LipSyncVisemeCue>[
        LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
        LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.aa),
        LipSyncVisemeCue(frame: 2, viseme: LipSyncViseme.sil),
      ];
      final track = LipSyncVisemeTrack(
        envelope: sourceEnvelope,
        cues: sourceCues,
      );
      sourceEnvelope[1] = 0;
      sourceCues.clear();

      expect(track.envelope, <double>[0, 0.7, 0]);
      expect(track.cues, hasLength(3));
      expect(() => track.envelope[0] = 1, throwsUnsupportedError);
      expect(track.cues[1].toJson(), <String, Object>{
        'frame': 1,
        'viseme': 'aa',
      });
      expect(
        LipSyncVisemeTrack.fromRendererJson(track.toRendererJson()).cues,
        track.cues,
      );
    });

    test('rejects malformed tracks and cues', () {
      expect(
        () => LipSyncVisemeTrack(envelope: const [], cues: const []),
        throwsArgumentError,
      );
      expect(
        () => LipSyncVisemeTrack(
          envelope: const <double>[double.nan],
          cues: <LipSyncVisemeCue>[
            LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
          ],
        ),
        throwsRangeError,
      );
      expect(
        () => LipSyncVisemeTrack(
          envelope: const <double>[0, 1],
          cues: <LipSyncVisemeCue>[
            LipSyncVisemeCue(frame: 1, viseme: LipSyncViseme.aa),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => LipSyncVisemeTrack(
          envelope: const <double>[0, 1],
          cues: <LipSyncVisemeCue>[
            LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
            LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.aa),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => LipSyncVisemeCue.fromJson(<String, Object>{
          'frame': 0,
          'viseme': 'aa',
          'confidence': 1,
        }),
        throwsFormatException,
      );
      expect(() => LipSyncViseme.fromWireName('A'), throwsFormatException);
    });
  });

  group('LipSyncVisemeAnalyzer audio', () {
    test('keeps silent PCM closed', () {
      final track = LipSyncVisemeAnalyzer.analyzePcmS16le(
        Uint8List(16000),
        sampleRate: 16000,
        channels: 1,
      );

      expect(track.envelope, everyElement(0));
      expect(track.cues, <LipSyncVisemeCue>[
        LipSyncVisemeCue(frame: 0, viseme: LipSyncViseme.sil),
      ]);
    });

    test('adaptively boosts quiet voiced audio', () {
      final pcm = _syntheticPcm(
        formants: const <double>[440],
        amplitude: 0.001,
      );
      final track = LipSyncVisemeAnalyzer.analyzePcmS16le(
        pcm,
        sampleRate: 16000,
        channels: 1,
      );

      expect(track.envelope.reduce(math.max), greaterThan(0.65));
      expect(track.envelope, everyElement(inInclusiveRange(0, 1)));
    });

    for (final entry in const <({LipSyncViseme viseme, double f1, double f2})>[
      (viseme: LipSyncViseme.aa, f1: 780, f2: 1200),
      (viseme: LipSyncViseme.ih, f1: 300, f2: 2300),
      (viseme: LipSyncViseme.ou, f1: 350, f2: 800),
      (viseme: LipSyncViseme.ee, f1: 420, f2: 2000),
      (viseme: LipSyncViseme.oh, f1: 520, f2: 900),
    ]) {
      test('recognizes synthetic ${entry.viseme.wireName} formants', () {
        final pcm = _syntheticPcm(formants: <double>[entry.f1, entry.f2]);
        final track = LipSyncVisemeAnalyzer.analyzePcmS16le(
          pcm,
          sampleRate: 16000,
          channels: 1,
        );

        expect(track.cues.map((cue) => cue.viseme), contains(entry.viseme));
      });
    }

    test('parses a PCM WAV with padded RIFF chunks', () {
      final pcm = _syntheticPcm(formants: const <double>[520, 900]);
      final track = LipSyncVisemeAnalyzer.analyzeWav(
        _pcmWav(pcm, sampleRate: 16000, includePaddedJunk: true),
      );

      expect(track.cues.map((cue) => cue.viseme), contains(LipSyncViseme.oh));
      expect(
        () => LipSyncVisemeAnalyzer.analyzeWav(Uint8List(44)),
        throwsFormatException,
      );
    });

    for (final closeAtEnd in <bool>[true, false]) {
      test('raw silence closes release-tail visemes ($closeAtEnd)', () {
        final voiced = _syntheticPcm(
          formants: const <double>[420, 2000],
          seconds: 0.4,
        );
        final pcm = Uint8List(voiced.length * 2)..setAll(0, voiced);
        final track = LipSyncVisemeAnalyzer.analyzePcmS16le(
          pcm,
          sampleRate: 16000,
          channels: 1,
          closeAtEnd: closeAtEnd,
        );

        const silenceFrame = 12;
        expect(track.visemeAtFrame(silenceFrame - 1), LipSyncViseme.ee);
        // The intensity release may continue; it must not classify the zero
        // samples underneath it as an Aa vowel.
        expect(track.envelope[silenceFrame], greaterThan(0.06));
        for (var frame = silenceFrame; frame < track.envelope.length; frame++) {
          expect(track.visemeAtFrame(frame), LipSyncViseme.sil);
        }
      });
    }

    for (final milliseconds in <int>[40, 60]) {
      test('keeps ${milliseconds}ms streaming vowel chunks open', () {
        final track = LipSyncVisemeAnalyzer.analyzePcmS16le(
          _syntheticPcm(
            formants: const <double>[420, 2000],
            seconds: milliseconds / 1000,
          ),
          sampleRate: 16000,
          channels: 1,
          closeAtEnd: false,
        );

        expect(track.envelope, everyElement(greaterThan(0.6)));
        for (var frame = 0; frame < track.envelope.length; frame++) {
          expect(track.visemeAtFrame(frame), LipSyncViseme.ee);
        }
      });
    }

    test('completed PCM and WAV clips still close at the end by default', () {
      final pcm = _syntheticPcm(
        formants: const <double>[420, 2000],
        seconds: 0.06,
      );
      final tracks = <LipSyncVisemeTrack>[
        LipSyncVisemeAnalyzer.analyzePcmS16le(
          pcm,
          sampleRate: 16000,
          channels: 1,
        ),
        LipSyncVisemeAnalyzer.analyzeWav(_pcmWav(pcm, sampleRate: 16000)),
      ];

      for (final track in tracks) {
        expect(track.visemeAtFrame(0), LipSyncViseme.ee);
        expect(track.envelope.last, 0);
        expect(
          track.visemeAtFrame(track.envelope.length - 1),
          LipSyncViseme.sil,
        );
      }
    });
  });

  test('system-TTS text fallback emits all five literal vowel shapes', () {
    final track = LipSyncVisemeAnalyzer.fromTextEnvelope(
      'a i u e o',
      List<double>.filled(100, 0.08),
    );
    final spoken = track.cues
        .map((cue) => cue.viseme)
        .where((viseme) => viseme != LipSyncViseme.sil)
        .toList();

    expect(
      spoken,
      containsAllInOrder(<LipSyncViseme>[
        LipSyncViseme.aa,
        LipSyncViseme.ih,
        LipSyncViseme.ou,
        LipSyncViseme.ee,
        LipSyncViseme.oh,
      ]),
    );
    expect(track.envelope.reduce(math.max), greaterThan(0.65));
  });
}

Uint8List _syntheticPcm({
  required List<double> formants,
  double amplitude = 0.18,
  int sampleRate = 16000,
  double seconds = 0.45,
}) {
  final sampleCount = (sampleRate * seconds).round();
  final bytes = Uint8List(sampleCount * 2);
  final data = ByteData.sublistView(bytes);
  for (var sample = 0; sample < sampleCount; sample++) {
    final time = sample / sampleRate;
    var value = 0.0;
    for (final frequency in formants) {
      value += math.sin(2 * math.pi * frequency * time);
    }
    value *= amplitude / formants.length;
    data.setInt16(
      sample * 2,
      (value * 32767).round().clamp(-32768, 32767),
      Endian.little,
    );
  }
  return bytes;
}

Uint8List _pcmWav(
  Uint8List pcm, {
  required int sampleRate,
  bool includePaddedJunk = false,
}) {
  final junkSize = includePaddedJunk ? 1 : 0;
  final junkChunkBytes = includePaddedJunk ? 8 + junkSize + 1 : 0;
  final total = 12 + 24 + junkChunkBytes + 8 + pcm.length;
  final bytes = Uint8List(total);
  final data = ByteData.sublistView(bytes);
  _writeAscii(bytes, 0, 'RIFF');
  data.setUint32(4, total - 8, Endian.little);
  _writeAscii(bytes, 8, 'WAVE');
  _writeAscii(bytes, 12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 1, Endian.little);
  data.setUint32(24, sampleRate, Endian.little);
  data.setUint32(28, sampleRate * 2, Endian.little);
  data.setUint16(32, 2, Endian.little);
  data.setUint16(34, 16, Endian.little);

  var offset = 36;
  if (includePaddedJunk) {
    _writeAscii(bytes, offset, 'JUNK');
    data.setUint32(offset + 4, junkSize, Endian.little);
    bytes[offset + 8] = 0x7f;
    offset += junkChunkBytes;
  }
  _writeAscii(bytes, offset, 'data');
  data.setUint32(offset + 4, pcm.length, Endian.little);
  bytes.setRange(offset + 8, offset + 8 + pcm.length, pcm);
  return bytes;
}

void _writeAscii(Uint8List bytes, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    bytes[offset + index] = value.codeUnitAt(index);
  }
}
