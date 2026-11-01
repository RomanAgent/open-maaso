import 'dart:typed_data';

/// Finalizes PCM16 WAV responses whose streaming headers use unknown lengths.
///
/// Call only after the entire HTTP response has completed. The sole accepted
/// unknown length is 0xffffffff, on RIFF or the terminal data chunk. Finite
/// lengths are validated, never clamped, so truncation is not repaired as audio.
abstract final class PcmWavStreamNormalizer {
  static const _unknownLength = 0xffffffff;
  static const _maxPcmBytes = 64 * 1024 * 1024;

  static Uint8List normalize(Uint8List wav) {
    if (wav.length < 12 ||
        !_hasAscii(wav, 0, 'RIFF') ||
        !_hasAscii(wav, 8, 'WAVE')) {
      throw const FormatException('Expected a RIFF/WAVE file');
    }
    final data = ByteData.sublistView(wav);
    final riffSize = data.getUint32(4, Endian.little);
    final unknownRiff = riffSize == _unknownLength;
    if (!unknownRiff && riffSize != wav.length - 8) {
      throw const FormatException(
        'WAV RIFF length does not match the response',
      );
    }

    int? blockAlign;
    int? pcmLength;
    int? unknownDataSizeOffset;
    var offset = 12;
    while (offset < wav.length) {
      if (offset + 8 > wav.length) {
        throw const FormatException('WAV chunk header is truncated');
      }
      final declaredSize = data.getUint32(offset + 4, Endian.little);
      final chunkOffset = offset + 8;
      final isData = _hasAscii(wav, offset, 'data');
      final unknownSize = declaredSize == _unknownLength;
      if (unknownSize && !isData) {
        throw const FormatException(
          'Only WAV data may have unknown chunk length',
        );
      }
      final chunkSize = unknownSize ? wav.length - chunkOffset : declaredSize;
      final chunkEnd = chunkOffset + chunkSize;
      if (chunkEnd > wav.length) {
        throw const FormatException('WAV chunk extends beyond the file');
      }
      if (_hasAscii(wav, offset, 'fmt ')) {
        if (chunkSize < 16 || blockAlign != null) {
          throw const FormatException(
            'WAV fmt chunk is missing data or duplicated',
          );
        }
        final format = data.getUint16(chunkOffset, Endian.little);
        final channels = data.getUint16(chunkOffset + 2, Endian.little);
        final sampleRate = data.getUint32(chunkOffset + 4, Endian.little);
        final byteRate = data.getUint32(chunkOffset + 8, Endian.little);
        final alignment = data.getUint16(chunkOffset + 12, Endian.little);
        final bits = data.getUint16(chunkOffset + 14, Endian.little);
        if (format != 1 || bits != 16) {
          throw const FormatException(
            'Only uncompressed 16-bit PCM WAV is supported',
          );
        }
        if (channels < 1 ||
            channels > 8 ||
            sampleRate < 8000 ||
            sampleRate > 192000 ||
            alignment != channels * 2 ||
            byteRate != sampleRate * alignment) {
          throw const FormatException('WAV PCM format fields are inconsistent');
        }
        blockAlign = alignment;
      } else if (isData) {
        if (pcmLength != null) {
          throw const FormatException('WAV data chunk is duplicated');
        }
        pcmLength = chunkSize;
        if (unknownSize) unknownDataSizeOffset = offset + 4;
      }
      offset = chunkEnd + (chunkSize.isOdd ? 1 : 0);
      if (offset > wav.length) {
        throw const FormatException('WAV chunk padding is truncated');
      }
    }
    if (blockAlign == null || pcmLength == null) {
      throw const FormatException('WAV is missing fmt or data');
    }
    if (pcmLength == 0 ||
        pcmLength > _maxPcmBytes ||
        pcmLength % blockAlign != 0) {
      throw const FormatException(
        'WAV PCM data must contain complete bounded frames',
      );
    }
    if (!unknownRiff && unknownDataSizeOffset == null) return wav;

    final normalized = Uint8List.fromList(wav);
    final header = ByteData.sublistView(normalized);
    header.setUint32(4, normalized.length - 8, Endian.little);
    if (unknownDataSizeOffset != null) {
      header.setUint32(unknownDataSizeOffset, pcmLength, Endian.little);
    }
    return normalized;
  }

  static bool _hasAscii(Uint8List bytes, int offset, String value) {
    if (offset + value.length > bytes.length) return false;
    for (var index = 0; index < value.length; index++) {
      if (bytes[offset + index] != value.codeUnitAt(index)) return false;
    }
    return true;
  }
}
