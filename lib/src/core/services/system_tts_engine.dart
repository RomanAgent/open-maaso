import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';

/// Installed phone voices produce PCM locally. Playback, cancellation fences
/// and mouth timing stay in MaasoTtsPlugin's existing utterance queue.
final class SystemTtsEngine implements TTSEngine {
  SystemTtsEngine({MethodChannel? channel})
    : _channel = channel ?? const MethodChannel('maaso/system_tts');

  final MethodChannel _channel;
  Future<bool>? _warming;
  bool _ready = false;
  String? _activeRequest;

  @override
  bool get isReady => _ready;

  @override
  Future<bool> warmUp({TTSEngineWarmupProgress? onProgress}) =>
      _warming ??= _warmUp().whenComplete(() => _warming = null);

  Future<bool> _warmUp() async {
    try {
      return _ready =
          await _channel
              .invokeMethod<bool>('isAvailable')
              .timeout(const Duration(seconds: 10)) ??
          false;
    } on PlatformException {
      return _ready = false;
    } on MissingPluginException {
      return _ready = false;
    } on TimeoutException {
      return _ready = false;
    }
  }

  @override
  Future<Uint8List> synthesizeToWav(
    String text, {
    String? language,
    String? voice,
  }) async {
    if (text.trim().isEmpty || text.length > 8000) {
      throw ArgumentError('System speech requires 1–8000 characters.');
    }
    if (_activeRequest != null) throw StateError('System speech is busy.');
    final id = const Uuid().v4();
    _activeRequest = id;
    try {
      if (!_ready && !await warmUp()) {
        throw StateError('No installed system speech service is available.');
      }
      if (_activeRequest != id) {
        throw StateError('System speech was cancelled.');
      }
      final bytes = await _channel
          .invokeMethod<Uint8List>('synthesize', {
            'id': id,
            'text': text,
            'language': language ?? 'en',
          })
          .timeout(const Duration(seconds: 30));
      if (_activeRequest != id) {
        throw StateError('System speech was cancelled.');
      }
      if (bytes == null || !_validPcmWave(bytes)) {
        throw StateError('System speech returned invalid audio.');
      }
      return bytes;
    } on TimeoutException {
      await cancelSynthesis();
      rethrow;
    } finally {
      if (_activeRequest == id) _activeRequest = null;
    }
  }

  static bool _validPcmWave(Uint8List bytes) {
    if (bytes.length < 44 ||
        bytes.length > 20 * 1024 * 1024 ||
        String.fromCharCodes(bytes.take(4)) != 'RIFF' ||
        String.fromCharCodes(bytes.skip(8).take(4)) != 'WAVE') {
      return false;
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint32(4, Endian.little) + 8 != bytes.length) return false;
    var validFormat = false, hasAudio = false;
    var alignment = 0;
    for (var cursor = 12; cursor + 8 <= bytes.length;) {
      final size = data.getUint32(cursor + 4, Endian.little);
      final start = cursor + 8;
      if (start + size > bytes.length) return false;
      final kind = String.fromCharCodes(bytes.sublist(cursor, cursor + 4));
      if (kind == 'fmt ') {
        if (size < 16) return false;
        final channels = data.getUint16(start + 2, Endian.little);
        final rate = data.getUint32(start + 4, Endian.little);
        alignment = data.getUint16(start + 12, Endian.little);
        validFormat =
            data.getUint16(start, Endian.little) == 1 &&
            channels >= 1 &&
            channels <= 2 &&
            rate >= 8000 &&
            rate <= 192000 &&
            data.getUint16(start + 14, Endian.little) == 16 &&
            alignment == channels * 2;
      } else if (kind == 'data') {
        hasAudio = validFormat && size > 0 && size % alignment == 0;
      }
      cursor = start + size + (size.isOdd ? 1 : 0);
    }
    return validFormat && hasAudio;
  }

  /// Native cancellation is request-scoped; an old owner cannot stop a newer
  /// utterance, and native callbacks never complete another request's Future.
  Future<void> cancelSynthesis() async {
    final id = _activeRequest;
    if (id == null) return;
    await _channel
        .invokeMethod<bool>('cancel', {'id': id})
        .timeout(const Duration(seconds: 5));
    if (_activeRequest == id) _activeRequest = null;
  }
}
