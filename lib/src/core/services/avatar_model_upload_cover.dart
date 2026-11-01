import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as path;

class AvatarUploadCoverException implements Exception {
  const AvatarUploadCoverException(this.code);

  final String code;
  String get messageKey => 'avatar_store.cover.error.$code';

  @override
  String toString() => 'Invalid model cover: $code';
}

/// The exact, validated image shown in the upload confirmation. Keeping a small
/// immutable byte snapshot prevents file changes between preview and upload.
class AvatarModelUploadCover {
  AvatarModelUploadCover._({
    required this.fileName,
    required this.contentType,
    required this.width,
    required this.height,
    required Uint8List bytes,
  }) : _bytes = bytes.asUnmodifiableView(),
       sha256Hex = sha256.convert(bytes).toString();

  static const maxBytes = 8 * 1024 * 1024;
  static const minDimension = 64;
  static const maxDimension = 8192;
  static const maxPixels = 24000000;

  final String fileName;
  final String contentType;
  final int width;
  final int height;
  final String sha256Hex;
  final Uint8List _bytes;

  Uint8List get bytes => _bytes;
  int get contentLength => _bytes.length;

  static Future<AvatarModelUploadCover> fromFile(
    File file, {
    String? fileName,
  }) async {
    final handle = await file.open();
    late Uint8List bytes;
    try {
      bytes = await handle.read(maxBytes + 1);
    } finally {
      await handle.close();
    }
    return fromBytes(
      fileName: fileName ?? path.basename(file.path),
      bytes: bytes,
    );
  }

  static Future<AvatarModelUploadCover> fromBytes({
    required String fileName,
    required Uint8List bytes,
  }) async {
    if (bytes.isEmpty || bytes.length > maxBytes) {
      throw const AvatarUploadCoverException('size');
    }
    final snapshot = Uint8List.fromList(bytes);
    final name = path.basename(fileName).trim();
    final inspection = await _inspectCover(name, snapshot);
    return AvatarModelUploadCover._(
      fileName: name,
      contentType: inspection.$1,
      width: inspection.$2,
      height: inspection.$3,
      bytes: snapshot,
    );
  }
}

Future<(String, int, int)> _inspectCover(String name, Uint8List bytes) async {
  final suffix = path.extension(name).toLowerCase();
  final png =
      bytes.length >= 24 &&
      listEquals(bytes.sublist(0, 8), const [137, 80, 78, 71, 13, 10, 26, 10]);
  final jpeg =
      bytes.length >= 3 &&
      bytes[0] == 255 &&
      bytes[1] == 216 &&
      bytes[2] == 255;
  if (!(png && suffix == '.png' ||
      jpeg && (suffix == '.jpg' || suffix == '.jpeg'))) {
    throw const AvatarUploadCoverException('format');
  }
  // Read only fixed-size fields before invoking a decoder. This prevents a
  // tiny hostile JPEG SOF or PNG IHDR from allocating an oversized pixel plane.
  final (width, height) = png ? _pngDimensions(bytes) : _jpegDimensions(bytes);
  if (width < AvatarModelUploadCover.minDimension ||
      height < AvatarModelUploadCover.minDimension ||
      width > AvatarModelUploadCover.maxDimension ||
      height > AvatarModelUploadCover.maxDimension ||
      width * height > AvatarModelUploadCover.maxPixels) {
    throw const AvatarUploadCoverException('dimensions');
  }
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  ui.Codec? codec;
  ui.Image? frame;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    // Native decoders may expose the EXIF-oriented dimensions. The upload
    // contract reports the original encoded dimensions, without rewriting it.
    final matches = descriptor.width == width && descriptor.height == height;
    final rotated = descriptor.width == height && descriptor.height == width;
    if (!matches && !rotated) throw const AvatarUploadCoverException('format');
    final ratio =
        512 /
        (descriptor.width > descriptor.height
            ? descriptor.width
            : descriptor.height);
    codec = await descriptor.instantiateCodec(
      targetWidth: ratio < 1
          ? (descriptor.width * ratio).round().clamp(1, 512)
          : descriptor.width,
      targetHeight: ratio < 1
          ? (descriptor.height * ratio).round().clamp(1, 512)
          : descriptor.height,
    );
    frame = (await codec.getNextFrame()).image;
    return (png ? 'image/png' : 'image/jpeg', width, height);
  } on AvatarUploadCoverException {
    rethrow;
  } catch (_) {
    throw const AvatarUploadCoverException('format');
  } finally {
    frame?.dispose();
    codec?.dispose();
    descriptor?.dispose();
    buffer?.dispose();
  }
}

(int, int) _pngDimensions(Uint8List bytes) {
  final header = ByteData.sublistView(bytes);
  if (header.getUint32(8) != 13 || header.getUint32(12) != 0x49484452) {
    throw const AvatarUploadCoverException('format');
  }
  return (header.getUint32(16), header.getUint32(20));
}

(int, int) _jpegDimensions(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  var offset = 2;
  while (offset < bytes.length) {
    if (bytes[offset++] != 0xff) break;
    while (offset < bytes.length && bytes[offset] == 0xff) {
      offset++;
    }
    if (offset >= bytes.length) break;
    final marker = bytes[offset++];
    if (marker == 0xda || marker == 0xd9) break;
    if (marker == 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) break;
    final length = data.getUint16(offset);
    if (length < 2 || offset + length > bytes.length) break;
    const frameMarkers = {
      0xc0,
      0xc1,
      0xc2,
      0xc3,
      0xc5,
      0xc6,
      0xc7,
      0xc9,
      0xca,
      0xcb,
      0xcd,
      0xce,
      0xcf,
    };
    if (frameMarkers.contains(marker)) {
      if (length < 8) break;
      final components = bytes[offset + 7];
      if (components < 1 || components > 4 || length != 8 + components * 3) {
        break;
      }
      var sampling = 0;
      for (var i = 0; i < components; i++) {
        final factor = bytes[offset + 9 + i * 3];
        final horizontal = factor >> 4;
        final vertical = factor & 15;
        if (horizontal < 1 || horizontal > 4 || vertical < 1 || vertical > 4) {
          throw const AvatarUploadCoverException('format');
        }
        sampling += horizontal * vertical;
      }
      if (sampling > 10) throw const AvatarUploadCoverException('format');
      return (data.getUint16(offset + 5), data.getUint16(offset + 3));
    }
    offset += length;
  }
  throw const AvatarUploadCoverException('format');
}
