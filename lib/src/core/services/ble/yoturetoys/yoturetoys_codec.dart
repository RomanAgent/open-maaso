import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Wire codec for the **Yoturetoys AI Drawing Projector** BLE protocol.
///
/// Headless port of iprojectoren's `EncodeService` / `DecodeService` — the
/// pure framing + command algorithms with all UI/framework coupling stripped,
/// so
/// it can be shared by both the dialogue skill and the official applet.
///
/// Frame layout (all multi-byte fields big-endian):
///   55 AA 00 <cmd> <len(2)> <payload...> <checksum(2)>
///   checksum = sum(all bytes before checksum) & 0xFFFF
class YoturetoysCodec {
  YoturetoysCodec._();

  static const int header0 = 0x55;
  static const int header1 = 0xAA;

  // —————————————————— encode ——————————————————

  static List<int> intToBytes(int value, int byteCount) {
    final out = Uint8List(byteCount);
    for (var i = 0; i < byteCount; i++) {
      out[i] = (value >> (8 * (byteCount - i - 1))) & 0xFF;
    }
    return out.toList();
  }

  /// Wrap [content] in a framed command for [cmd].
  static List<int> encode(int cmd, List<int> content) {
    final data = <int>[
      header0,
      header1,
      0x00,
      cmd,
      ...intToBytes(content.length, 2),
      ...content,
    ];
    final checksum = data.fold<int>(0, (acc, b) => acc + b) & 0xFFFF;
    data.addAll(intToBytes(checksum, 2));
    return data;
  }

  /// 0x27 — "direct image" request: announce the JPEG size before streaming.
  static List<int> generate0x27({required int imageSize}) =>
      intToBytes(imageSize, 4);

  /// 0x22 — switch to a stored artwork.
  static List<int> generate0x22({int artworkId = 0, int artworkIndex = 0}) => [
    ...intToBytes(artworkId, 2),
    ...intToBytes(artworkIndex, 1),
  ];

  /// 0x26 — toggle the device voice.
  static List<int> generate0x26({required bool enable}) =>
      intToBytes(enable ? 1 : 0, 1);

  /// 0x29 — request a page of the device's local artwork list.
  static List<int> generate0x29({int start = 0, int offset = 0}) => [
    ...intToBytes(start, 1),
    ...intToBytes(offset, 1),
  ];

  // —————————————————— image → JPEG ——————————————————

  /// Decode arbitrary image [bytes] (PNG/JPEG/WebP/…), fit it to the device's
  /// [targetWidth]×[targetHeight] panel, and re-encode as JPEG at [quality].
  /// The device's 0x27/0x28 path expects a fixed-size JPEG frame.
  ///
  /// Fitting is "cover": scale to fill the panel, then centre-crop the overflow
  /// — fills the screen with no letterbox bars, at the cost of trimming the
  /// long edge (the right default for displaying artwork).
  static List<int> toJpeg(
    List<int> bytes, {
    int quality = 80,
    required int targetWidth,
    required int targetHeight,
  }) {
    final src = img.decodeImage(Uint8List.fromList(bytes));
    if (src == null) {
      throw const FormatException('unsupported / corrupt image bytes');
    }
    final scale = (targetWidth / src.width) > (targetHeight / src.height)
        ? targetWidth / src.width
        : targetHeight / src.height;
    final rw = (src.width * scale).round().clamp(targetWidth, 1 << 16);
    final rh = (src.height * scale).round().clamp(targetHeight, 1 << 16);
    final resized = img.copyResize(src, width: rw, height: rh);
    final dx = ((rw - targetWidth) / 2).round();
    final dy = ((rh - targetHeight) / 2).round();
    final cropped = img.copyCrop(
      resized,
      x: dx,
      y: dy,
      width: targetWidth,
      height: targetHeight,
    );
    return img.encodeJpg(cropped, quality: quality);
  }

  // —————————————————— decode ——————————————————

  static int _u16(List<int> b) =>
      ByteData.sublistView(Uint8List.fromList(b)).getUint16(0, Endian.big);

  static String _snHex(List<int> b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  /// SN decoded from a BLE advertisement's manufacturer payload (id 0xAA55).
  static String? snFromManufacturerData(List<int> data) {
    if (data.length < 6) return null;
    return _snHex(data.sublist(0, 6));
  }

  /// Parse one inbound notification frame into `{cmd, ...}`. Returns null on a
  /// malformed frame or checksum mismatch (caller just ignores it).
  static Map<String, dynamic>? parse(List<int> data) {
    if (data.length < 8) return null;
    if (_u16(data.sublist(0, 2)) != 0x55AA) return null;
    final cmd = data[3];
    final len = _u16(data.sublist(4, 6));
    if (6 + len + 2 > data.length) return null;
    final content = data.sublist(6, 6 + len);
    final checksum = _u16(data.sublist(6 + len, 6 + len + 2));
    final calc =
        data.sublist(0, 6 + len).fold<int>(0, (a, b) => a + b) & 0xFFFF;
    if (checksum != calc) return null;
    return _parseCmd(cmd, content);
  }

  static Map<String, dynamic> _parseCmd(int cmd, List<int> c) {
    switch (cmd) {
      case 0x21: // device info
        return {
          'cmd': 0x21,
          'deviceId': c.length >= 4
              ? ByteData.sublistView(
                  Uint8List.fromList(c.sublist(0, 4)),
                ).getInt32(0, Endian.big)
              : 0,
          'sn': c.length >= 10 ? _snHex(c.sublist(4, 10)) : '',
          'firmwareVersion': c.length >= 14 ? '${c[10]}.${c[11]}.${c[12]}' : '',
        };
      case 0x56: // voice state push
        return {'cmd': 0x56, 'status': c.isNotEmpty ? c[0] : 0};
      default:
        // Generic ack frames (0x22/0x25/0x26/0x27/0x28/0x81…) carry a status byte.
        return {'cmd': cmd, 'status': c.isNotEmpty ? c[0] : 0};
    }
  }
}
