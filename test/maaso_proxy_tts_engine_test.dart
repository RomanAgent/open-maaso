import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/services/lip_sync_viseme_analyzer.dart';
import 'package:maaso/src/core/services/maaso_proxy_tts_engine.dart';
import 'package:maaso/src/core/services/pcm_wav_stream_normalizer.dart';

void main() {
  test(
    'finalizes the observed LIST and unknown-length header without changing PCM',
    () {
      // Reproduce only the observed header layout and byte count, using generated
      // PCM. The user's real speech recording is deliberately not a test asset.
      final streamed = _wav(
        unknownRiff: true,
        unknownData: true,
        pcmBytes: 125388,
      );
      final original = Uint8List.fromList(streamed);
      expect(streamed.length, 125466);
      expect(ascii.decode(streamed.sublist(36, 40)), 'LIST');
      expect(ascii.decode(streamed.sublist(70, 74)), 'data');
      expect(
        () => LipSyncVisemeAnalyzer.analyzeWav(streamed),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            'WAV chunk extends beyond the file',
          ),
        ),
      );

      final normalized = PcmWavStreamNormalizer.normalize(streamed);
      final header = ByteData.sublistView(normalized);
      expect(header.getUint32(4, Endian.little), 125458);
      expect(header.getUint32(74, Endian.little), 125388);
      expect(streamed, original);
      expect(normalized.sublist(8, 74), streamed.sublist(8, 74));
      expect(normalized.sublist(78), streamed.sublist(78));
      final track = LipSyncVisemeAnalyzer.analyzeWav(normalized);
      expect(track.envelope, hasLength(79));
      expect(track.frameRate, 30);
    },
  );

  test('a finite standard PCM16 WAV remains the same object and bytes', () {
    final finite = _wav();
    final original = Uint8List.fromList(finite);
    expect(PcmWavStreamNormalizer.normalize(finite), same(finite));
    expect(finite, original);
  });

  for (final unknownRiff in [false, true]) {
    test('handles only ${unknownRiff ? 'RIFF' : 'data'} being unknown', () {
      final wav = _wav(unknownRiff: unknownRiff, unknownData: !unknownRiff);
      final normalized = PcmWavStreamNormalizer.normalize(wav);
      final header = ByteData.sublistView(normalized);
      expect(header.getUint32(4, Endian.little), normalized.length - 8);
      expect(header.getUint32(74, Endian.little), normalized.length - 78);
      expect(
        () => LipSyncVisemeAnalyzer.analyzeWav(normalized),
        returnsNormally,
      );
    });
  }

  test('preserves a padded odd-size unknown chunk before data', () {
    final wav = _wav(unknownRiff: true, unknownData: true, paddedJunk: true);
    final normalized = PcmWavStreamNormalizer.normalize(wav);
    expect(normalized.sublist(36, 80), wav.sublist(36, 80));
    expect(() => LipSyncVisemeAnalyzer.analyzeWav(normalized), returnsNormally);
  });

  test('ordinary finite RIFF truncation is rejected', () {
    final wav = _wav();
    expect(
      () => PcmWavStreamNormalizer.normalize(
        Uint8List.sublistView(wav, 0, wav.length - 2),
      ),
      throwsFormatException,
    );
  });

  test('finite metadata chunk overflow is rejected even with unknown RIFF', () {
    final wav = _wav(unknownRiff: true, unknownData: true);
    ByteData.sublistView(wav).setUint32(40, wav.length, Endian.little);
    expect(() => PcmWavStreamNormalizer.normalize(wav), throwsFormatException);
  });

  test('unknown metadata length is not treated as terminal PCM', () {
    final wav = _wav(unknownRiff: true, unknownData: true);
    ByteData.sublistView(wav).setUint32(40, 0xffffffff, Endian.little);
    expect(() => PcmWavStreamNormalizer.normalize(wav), throwsFormatException);
  });

  test('ordinary finite data overflow is never clamped', () {
    final wav = _wav(unknownRiff: true);
    ByteData.sublistView(wav).setUint32(74, wav.length - 78 + 2, Endian.little);
    expect(() => PcmWavStreamNormalizer.normalize(wav), throwsFormatException);
  });

  test('other large data values are not accepted as unknown length', () {
    final wav = _wav(unknownRiff: true);
    ByteData.sublistView(wav).setUint32(74, 0x7fffffff, Endian.little);
    expect(() => PcmWavStreamNormalizer.normalize(wav), throwsFormatException);
  });

  test('incomplete interleaved sample frames are rejected', () {
    final wav = _wav(
      unknownRiff: true,
      unknownData: true,
      channels: 2,
      pcmBytes: 6,
    );
    expect(() => PcmWavStreamNormalizer.normalize(wav), throwsFormatException);
  });

  for (final format in [3, 0xfffe]) {
    test('non-PCM format $format is rejected before repair', () {
      final wav = _wav(unknownRiff: true, unknownData: true);
      ByteData.sublistView(wav).setUint16(20, format, Endian.little);
      expect(
        () => PcmWavStreamNormalizer.normalize(wav),
        throwsFormatException,
      );
    });
  }

  test('non-16-bit and inconsistent PCM fields are rejected', () {
    for (final field in [34, 32, 28]) {
      final wav = _wav(unknownRiff: true, unknownData: true);
      final data = ByteData.sublistView(wav);
      if (field == 28) {
        data.setUint32(field, 1234, Endian.little);
      } else {
        data.setUint16(field, 24, Endian.little);
      }
      expect(
        () => PcmWavStreamNormalizer.normalize(wav),
        throwsFormatException,
      );
    }
  });

  test('missing format and empty PCM are rejected', () {
    final missingFmt = _wav(unknownRiff: true, unknownData: true);
    missingFmt.setRange(12, 16, 'JUNK'.codeUnits);
    expect(
      () => PcmWavStreamNormalizer.normalize(missingFmt),
      throwsFormatException,
    );
    expect(
      () => PcmWavStreamNormalizer.normalize(
        _wav(unknownRiff: true, unknownData: true, pcmBytes: 0),
      ),
      throwsFormatException,
    );
  });

  test('truncated chunk headers and odd chunk padding are rejected', () {
    final full = _wav(unknownRiff: true);
    // Keep the finite data valid, then append an incomplete next chunk header.
    final tail = Uint8List.fromList([...full, 1, 2, 3]);
    expect(() => PcmWavStreamNormalizer.normalize(tail), throwsFormatException);
    final odd = _wav(unknownRiff: true, unknownData: true, pcmBytes: 3);
    expect(() => PcmWavStreamNormalizer.normalize(odd), throwsFormatException);
  });

  test(
    'proxy waits for all HTTP chunks then normalizes without changing request contract',
    () async {
      final response = StreamController<List<int>>();
      http.Request? captured;
      final client = _Client((request) async {
        captured = request as http.Request;
        return http.StreamedResponse(
          response.stream,
          200,
          headers: {'content-type': 'audio/wav'},
        );
      });
      final engine = MaasoProxyTtsEngine(
        baseUri: Uri.parse('https://example.test'),
        accessTokenProvider: () async => 'test-token',
        httpClient: client,
      );
      addTearDown(client.close);
      final streamed = _wav(unknownRiff: true, unknownData: true);
      var completed = false;
      final pending = engine
          .synthesizeToWav(
            'fixture text',
            language: 'zh',
            voice: 'fixture-voice',
          )
          .then((wav) {
            completed = true;
            return wav;
          });
      response.add(streamed.sublist(0, 48));
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);
      response.add(streamed.sublist(48));
      await response.close();
      final wav = await pending;
      expect(() => LipSyncVisemeAnalyzer.analyzeWav(wav), returnsNormally);
      expect(captured!.url.path, '/v1/proxy/tts/stream');
      expect(captured!.method, 'POST');
      expect(captured!.headers['Accept'], 'audio/wav');
      expect(captured!.headers['Authorization'], 'Bearer test-token');
      expect(jsonDecode(captured!.body), {
        'text': 'fixture text',
        'language': 'zh',
        'voice': 'fixture-voice',
        'format': 'wav',
        'sampleRate': 24000,
      });
      expect(ByteData.sublistView(wav).getUint32(74, Endian.little), 800);
    },
  );

  test(
    'proxy rejects malformed successful responses instead of returning fake WAV',
    () async {
      final client = _Client(
        (_) async => http.StreamedResponse(Stream.value([1, 2, 3]), 200),
      );
      addTearDown(client.close);
      final engine = MaasoProxyTtsEngine(
        baseUri: Uri.parse('https://example.test'),
        accessTokenProvider: () async => null,
        httpClient: client,
      );
      await expectLater(
        engine.synthesizeToWav('fixture text'),
        throwsFormatException,
      );
    },
  );
}

Uint8List _wav({
  bool unknownRiff = false,
  bool unknownData = false,
  bool paddedJunk = false,
  int channels = 1,
  int pcmBytes = 800,
}) {
  final extra = paddedJunk ? 10 : 0;
  final dataOffset = 70 + extra;
  final wav = Uint8List(dataOffset + 8 + pcmBytes);
  final data = ByteData.sublistView(wav);
  void asciiAt(int offset, String text) =>
      wav.setRange(offset, offset + text.length, text.codeUnits);
  asciiAt(0, 'RIFF');
  data.setUint32(4, unknownRiff ? 0xffffffff : wav.length - 8, Endian.little);
  asciiAt(8, 'WAVE');
  asciiAt(12, 'fmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, channels, Endian.little);
  data.setUint32(24, 24000, Endian.little);
  data.setUint32(28, 24000 * channels * 2, Endian.little);
  data.setUint16(32, channels * 2, Endian.little);
  data.setUint16(34, 16, Endian.little);
  asciiAt(36, 'LIST');
  data.setUint32(40, 26, Endian.little);
  asciiAt(44, 'INFOISFT');
  data.setUint32(52, 14, Endian.little);
  asciiAt(56, 'synthetic-wav\x00');
  if (paddedJunk) {
    asciiAt(70, 'JUNK');
    data.setUint32(74, 1, Endian.little);
    wav[78] = 0x42;
  }
  asciiAt(dataOffset, 'data');
  data.setUint32(
    dataOffset + 4,
    unknownData ? 0xffffffff : pcmBytes,
    Endian.little,
  );
  for (var offset = dataOffset + 8; offset + 2 <= wav.length; offset += 2) {
    data.setInt16(offset, offset % 2000 - 1000, Endian.little);
  }
  return wav;
}

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      respond(request);
}
