import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:maaso/src/core/services/local_system_voice.dart';

/// Local installed system voices only. No cloud engine, fallback or download.
/// Initialization is lazy; merely constructing this service never speaks.
class OfflineSpeechService {
  OfflineSpeechService({
    FlutterTts? tts,
    TargetPlatform? platform,
    bool? isWeb,
    this.onStart,
    this.onEnd,
    this.onProgress,
  }) : _tts = tts ?? FlutterTts(),
       _platform = platform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb {
    _tts.setStartHandler(_speechStarted);
    _tts.setCompletionHandler(_speechEnded);
    _tts.setCancelHandler(_speechEnded);
    _tts.setPauseHandler(_speechEnded);
    _tts.setErrorHandler((_) => _speechEnded());
    _tts.setProgressHandler((text, start, end, word) {
      if (_disposed ||
          _eventGeneration != _generation ||
          text != _eventText ||
          start < 0 ||
          end < start ||
          end > text.length) {
        return;
      }
      _speechStarted();
      _callback(onProgress);
    });
  }

  /// Actual native TTS events. Progress is a coarse word cue, not phoneme data.
  VoidCallback? onStart;
  VoidCallback? onEnd;
  VoidCallback? onProgress;

  final FlutterTts _tts;
  final TargetPlatform _platform;
  final bool _isWeb;
  Future<void> _tail = Future<void>.value();
  String? _language;
  bool _available = false;
  String? _unavailableReason;
  bool _disposed = false;
  int _generation = 0;
  int? _eventGeneration;
  String? _eventText;
  bool _nativeSpeaking = false;

  void _callback(VoidCallback? callback) {
    try {
      callback?.call();
    } catch (_) {
      /* presentation cannot break speech */
    }
  }

  void _speechStarted() {
    if (_disposed || _eventGeneration != _generation || _nativeSpeaking) return;
    _nativeSpeaking = true;
    _callback(onStart);
  }

  void _speechEnded() {
    _eventGeneration = null;
    _eventText = null;
    if (!_nativeSpeaking) return;
    _nativeSpeaking = false;
    _callback(onEnd);
  }

  bool get available => _available && !_disposed;
  String? get unavailableReason => _unavailableReason;

  Future<T> _serial<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation;
  }

  Future<bool> initialize({String? language}) => _serial(
    () => _initialize(
      language ?? PlatformDispatcher.instance.locale.toLanguageTag(),
    ),
  );

  Future<bool> _initialize(String language) async {
    if (_disposed) return false;
    final locale = language.replaceAll('_', '-');
    if (_language == locale && _available) return true;
    _available = false;
    _language = locale;
    if (_isWeb ||
        !const {
          TargetPlatform.android,
          TargetPlatform.iOS,
          TargetPlatform.macOS,
          TargetPlatform.windows,
        }.contains(_platform)) {
      _unavailableReason = '此平台无法确认离线系统语音，文字功能仍可使用。';
      return false;
    }
    try {
      final voices = await _tts.getVoices;
      Map<String, String>? voice;
      if (_platform == TargetPlatform.android) {
        voice = embeddedAndroidVoice(voices, locale);
        if (voice == null && voices is List) {
          final language = locale.toLowerCase().split('-').first;
          for (final candidate in voices.whereType<Map>()) {
            final candidateLocale = candidate['locale'];
            if (candidateLocale is String &&
                candidateLocale
                        .replaceAll('_', '-')
                        .toLowerCase()
                        .split('-')
                        .first ==
                    language) {
              voice = embeddedAndroidVoice(voices, candidateLocale);
              if (voice != null) break;
            }
          }
        }
      } else if (voices is List) {
        // Apple AVSpeechSynthesizer and Windows SAPI enumerate locally
        // available voices. Pin a concrete entry; never request a download.
        final normalized = locale.toLowerCase();
        final matches = voices
            .whereType<Map>()
            .where(
              (v) =>
                  v['name'] is String &&
                  (v['name'] as String).isNotEmpty &&
                  v['locale'] is String &&
                  (v['locale'] as String)
                          .replaceAll('_', '-')
                          .toLowerCase()
                          .split('-')
                          .first ==
                      normalized.split('-').first &&
                  v['network_required'] != '1' &&
                  v['network_required'] != true &&
                  !'${v['features'] ?? ''}'
                      .split('\t')
                      .contains('notInstalled'),
            )
            .toList();
        matches.sort((a, b) {
          final exactA =
              (a['locale'] as String).replaceAll('_', '-').toLowerCase() ==
              normalized;
          final exactB =
              (b['locale'] as String).replaceAll('_', '-').toLowerCase() ==
              normalized;
          return (exactB ? 1 : 0).compareTo(exactA ? 1 : 0);
        });
        for (final match in matches) {
          final id = match['identifier'];
          if ((_platform == TargetPlatform.iOS ||
                  _platform == TargetPlatform.macOS) &&
              (id is! String || id.isEmpty)) {
            continue;
          }
          voice = {
            'name': match['name'] as String,
            'locale': match['locale'] as String,
            if (id is String && id.isNotEmpty) 'identifier': id,
          };
          break;
        }
      }
      if (voice == null || await _tts.setVoice(voice) != 1) {
        _unavailableReason = '未找到已安装的本地语音，请在系统设置中准备语音后重试。';
        return false;
      }
      // A speak call returns after enqueueing, so stop/new-turn commands are
      // never held behind the full duration of an older utterance.
      await _tts.awaitSpeakCompletion(false);
      await _tts.setSpeechRate(0.48);
      await _tts.setVolume(1.0);
      _available = !_disposed;
      _unavailableReason = null;
      return _available;
    } catch (_) {
      _unavailableReason = '本地系统语音暂不可用，文字功能仍可使用。';
      return false;
    }
  }

  Future<bool> speak(String text, {String? language}) {
    final generation = ++_generation;
    _speechEnded();
    return _serial(() async {
      if (_disposed || generation != _generation || text.trim().isEmpty) {
        return false;
      }
      try {
        await _tts.stop();
        if (generation != _generation || _disposed) return false;
        if (!await _initialize(
          language ??
              _language ??
              PlatformDispatcher.instance.locale.toLanguageTag(),
        )) {
          return false;
        }
        if (generation != _generation || _disposed) return false;
        _eventGeneration = generation;
        _eventText = text.trim();
        final result = await _tts.speak(text.trim());
        if (result != 1) {
          _speechEnded();
          _unavailableReason = '本地系统语音未能播放，文字功能仍可使用。';
          return false;
        }
        return generation == _generation && !_disposed;
      } catch (_) {
        _speechEnded();
        _unavailableReason = '本地系统语音未能播放，文字功能仍可使用。';
        return false;
      }
    });
  }

  Future<void> stop() {
    ++_generation;
    _speechEnded();
    return _serial(() async {
      try {
        await _tts.stop();
      } catch (_) {
        /* no cloud fallback */
      }
    });
  }

  Future<void> dispose() {
    _disposed = true;
    _available = false;
    return stop();
  }
}
