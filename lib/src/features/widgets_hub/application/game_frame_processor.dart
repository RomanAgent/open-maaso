import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as image;

const gameFrameMaximumBytes = 256 * 1024;
const gameFrameMaximumEdge = 640;
const _fingerprintEdge = 32;

/// Ephemeral pixels from one player. No attachment/database metadata is created.
final class ProcessedGameFrame {
  ProcessedGameFrame({
    required Uint8List jpegBytes,
    required this.contentHash,
    required this.width,
    required this.height,
    required Uint8List fingerprint,
  }) : jpegBytes = Uint8List.fromList(jpegBytes).asUnmodifiableView(),
       fingerprint = Uint8List.fromList(fingerprint).asUnmodifiableView();

  final Uint8List jpegBytes;
  final String contentHash;
  final int width;
  final int height;
  final Uint8List fingerprint;
}

/// Decoding, resizing, JPEG encoding and the grayscale signature run off the UI
/// isolate on native platforms. Unsupported images fail before pixel allocation.
Future<ProcessedGameFrame> processGameFrame(Uint8List bytes) =>
    compute(_processGameFrameBytes, bytes);

ProcessedGameFrame _processGameFrameBytes(Uint8List bytes) {
  if (bytes.length < 12 || bytes.length > 4 * 1024 * 1024) {
    throw const FormatException('game_frame_size');
  }
  final decoder = image.findDecoderForData(bytes);
  if (decoder is! image.JpegDecoder && decoder is! image.PngDecoder) {
    throw const FormatException('game_frame_format');
  }
  final dimensions = decoder!.startDecode(bytes);
  if (dimensions == null ||
      dimensions.width < 1 ||
      dimensions.height < 1 ||
      dimensions.width > 4096 ||
      dimensions.height > 4096 ||
      dimensions.width * dimensions.height > 4 * 1024 * 1024 ||
      decoder.numFrames() != 1) {
    throw const FormatException('game_frame_dimensions');
  }
  var decoded = decoder.decodeFrame(0);
  if (decoded == null) throw const FormatException('game_frame_decode');
  decoded = image.bakeOrientation(decoded);
  if (decoded.width > gameFrameMaximumEdge ||
      decoded.height > gameFrameMaximumEdge) {
    decoded = image.copyResize(
      decoded,
      width: decoded.width >= decoded.height ? gameFrameMaximumEdge : null,
      height: decoded.height > decoded.width ? gameFrameMaximumEdge : null,
    );
  }
  // Fresh RGB pixels remove metadata and match the native opaque snapshot path.
  final clean = image.Image(
    width: decoded.width,
    height: decoded.height,
    numChannels: 3,
  );
  image.compositeImage(clean, decoded);
  Uint8List? jpeg;
  for (final quality in const [78, 64, 48]) {
    final candidate = Uint8List.fromList(
      image.encodeJpg(clean, quality: quality),
    );
    if (candidate.length <= gameFrameMaximumBytes) {
      jpeg = candidate;
      break;
    }
  }
  if (jpeg == null) throw const FormatException('game_frame_encoded_size');
  final thumbnail = image.copyResize(
    clean,
    width: _fingerprintEdge,
    height: _fingerprintEdge,
    interpolation: image.Interpolation.average,
  );
  final fingerprint = Uint8List(_fingerprintEdge * _fingerprintEdge);
  for (var y = 0; y < _fingerprintEdge; y++) {
    for (var x = 0; x < _fingerprintEdge; x++) {
      final pixel = thumbnail.getPixel(x, y);
      fingerprint[y * _fingerprintEdge + x] =
          (pixel.r * 0.299 + pixel.g * 0.587 + pixel.b * 0.114).round();
    }
  }
  return ProcessedGameFrame(
    jpegBytes: jpeg,
    contentHash: sha256.convert(jpeg).toString(),
    width: clean.width,
    height: clean.height,
    fingerprint: fingerprint,
  );
}

/// Pixel/region differences avoid treating JPEG encoding noise as a new scene.
/// A small changed board piece can cross the regional threshold even when the
/// full-frame average barely changes. This is a sampling hint, not a game event.
bool gameFramesDiffer(
  ProcessedGameFrame? previous,
  ProcessedGameFrame next, {
  double threshold = 0.04,
  double regionThreshold = 0.12,
  double changedFraction = 0.015,
  int pixelDelta = 24,
}) {
  for (final value in [threshold, regionThreshold, changedFraction]) {
    if (!value.isFinite || value < 0 || value > 1) {
      throw ArgumentError('game_frame_difference_threshold');
    }
  }
  if (pixelDelta < 1 || pixelDelta > 255) {
    throw ArgumentError('game_frame_pixel_delta');
  }
  if (previous == null ||
      previous.width != next.width ||
      previous.height != next.height) {
    return true;
  }
  if (previous.contentHash == next.contentHash) return false;
  const pixels = _fingerprintEdge * _fingerprintEdge;
  if (previous.fingerprint.length != pixels ||
      next.fingerprint.length != pixels) {
    return true;
  }
  var total = 0;
  var changed = 0;
  final regions = List<int>.filled(64, 0);
  for (var i = 0; i < pixels; i++) {
    final delta = (previous.fingerprint[i] - next.fingerprint[i]).abs();
    total += delta;
    if (delta >= pixelDelta) changed++;
    final x = i % _fingerprintEdge;
    final y = i ~/ _fingerprintEdge;
    regions[(y ~/ 4) * 8 + x ~/ 4] += delta;
  }
  return total / (pixels * 255) > threshold ||
      changed / pixels > changedFraction ||
      regions.any((delta) => delta / (16 * 255) > regionThreshold);
}
