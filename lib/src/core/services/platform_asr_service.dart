import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

class PlatformAsrService extends AppService {
  PlatformAsrService({bool? supportsExternalAudioInputOverride})
    : _supportsExternalAudioInputOverride = supportsExternalAudioInputOverride;

  static const MethodChannel _channel = MethodChannel('maaso/native_asr');
  final bool? _supportsExternalAudioInputOverride;

  final isListening = false.obs;
  final partialTranscript = ''.obs;
  final error = RxnString();

  final _finalController = StreamController<String>.broadcast();
  Stream<String> get finalResults => _finalController.stream;
  StreamSubscription<Uint8List>? _externalAudioSub;
  bool _usingExternalAudio = false;
  bool _finishExternalAudioOnDone = false;
  int _externalChunksSent = 0;
  int _externalBytesSent = 0;
  Future<void> _externalAppendTail = Future.value();
  final Set<Future<bool>> _inFlightStarts = <Future<bool>>{};
  Future<void>? _nativeRetirementFuture;
  var _nativeRetirementRequired = false;
  Future<void>? _deactivationFuture;
  var _accountGeneration = 0;
  var _accountActive = true;
  var _deactivationSucceeded = false;
  var _nativeSessionMayBeActive = false;
  var _acceptingNativeCallbacks = false;
  var _allowLegacyCallbacks = true;
  var _nextRequestId = 0;
  int? _activeRequestId;

  bool get supportsExternalAudioInput =>
      _supportsExternalAudioInputOverride ?? Platform.isIOS;

  Future<PlatformAsrService> init() async {
    _channel.setMethodCallHandler(_handleMethodCall);
    return this;
  }

  Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } catch (e) {
      error.value = e.toString();
      return false;
    }
  }

  Future<bool> start({
    String? locale,
    Stream<Uint8List>? audioStream,
    bool finishExternalAudioOnDone = false,
  }) async {
    if (!_accountActive) {
      error.value = 'native_asr_account_inactive';
      return false;
    }
    while (true) {
      final retirement = _nativeRetirementFuture;
      if (retirement == null) break;
      try {
        await retirement;
      } catch (e) {
        error.value = e.toString();
        return false;
      }
    }
    if (_nativeRetirementRequired) {
      error.value = 'native_asr_previous_session_not_drained';
      return false;
    }
    if (!_accountActive) {
      error.value = 'native_asr_account_inactive';
      return false;
    }
    final generation = _accountGeneration;
    final requestId = ++_nextRequestId;
    _activeRequestId = requestId;
    late final Future<bool> starting;
    starting = _startOnce(
      generation: generation,
      requestId: requestId,
      locale: locale,
      audioStream: audioStream,
      finishExternalAudioOnDone: finishExternalAudioOnDone,
    ).whenComplete(() => _inFlightStarts.remove(starting));
    _inFlightStarts.add(starting);
    return starting;
  }

  Future<bool> _startOnce({
    required int generation,
    required int requestId,
    String? locale,
    Stream<Uint8List>? audioStream,
    required bool finishExternalAudioOnDone,
  }) async {
    error.value = null;
    partialTranscript.value = '';
    final previousAudioSub = _externalAudioSub;
    if (previousAudioSub != null) {
      await previousAudioSub.cancel();
      if (identical(_externalAudioSub, previousAudioSub)) {
        _externalAudioSub = null;
      }
    }
    if (!_isCurrentStart(generation, requestId)) return false;
    await _externalAppendTail;
    if (!_isCurrentStart(generation, requestId)) return false;
    _usingExternalAudio = audioStream != null && supportsExternalAudioInput;
    _finishExternalAudioOnDone =
        finishExternalAudioOnDone && _usingExternalAudio;
    _externalChunksSent = 0;
    _externalBytesSent = 0;
    _externalAppendTail = Future.value();
    _nativeSessionMayBeActive = true;
    _acceptingNativeCallbacks = true;
    bool? ok;
    try {
      ok = await _channel.invokeMethod<bool>(
        _usingExternalAudio ? 'startExternal' : 'start',
        <String, Object>{
          'requestId': requestId,
          if (locale != null && locale.trim().isNotEmpty) 'locale': locale,
        },
      );
    } on MissingPluginException catch (e) {
      if (!_isCurrentStart(generation, requestId)) return false;
      error.value = e.toString();
      isListening.value = false;
      _nativeSessionMayBeActive = false;
      _acceptingNativeCallbacks = false;
      _activeRequestId = null;
      _usingExternalAudio = false;
      _finishExternalAudioOnDone = false;
      return false;
    } catch (e) {
      // A transport failure cannot prove that the native start side effect did
      // not happen. Retain [_nativeSessionMayBeActive] so account teardown must
      // make a strict, retryable cancel attempt.
      if (!_isCurrentStart(generation, requestId)) return false;
      error.value = e.toString();
      isListening.value = false;
      _acceptingNativeCallbacks = false;
      _usingExternalAudio = false;
      _finishExternalAudioOnDone = false;
      return false;
    }
    if (!_isCurrentAccountGeneration(generation)) {
      try {
        await _cancelNativeSessionStrict();
      } catch (e) {
        error.value = e.toString();
      }
      return false;
    }
    if (_activeRequestId != requestId) return false;
    if (!(ok ?? false)) {
      _nativeSessionMayBeActive = false;
      _acceptingNativeCallbacks = false;
      _activeRequestId = null;
    }
    isListening.value = ok ?? false;
    if ((ok ?? false) && _usingExternalAudio) {
      final sharedAudioStream = audioStream!;
      _externalAudioSub = sharedAudioStream.listen(
        (bytes) {
          if (!_isCurrentAccountGeneration(generation) ||
              _activeRequestId != requestId ||
              !isListening.value ||
              bytes.isEmpty) {
            return;
          }
          _externalChunksSent++;
          _externalBytesSent += bytes.length;
          _externalAppendTail = _externalAppendTail.then((_) async {
            if (!_isCurrentAccountGeneration(generation) ||
                _activeRequestId != requestId) {
              return;
            }
            try {
              await _channel.invokeMethod<void>('appendPcm16', bytes);
            } catch (e) {
              Log.w('🎙️ [NativeASR] append PCM failed: $e');
            }
          });
        },
        onError: (e) {
          Log.w('🎙️ [NativeASR] external audio stream error: $e');
        },
        onDone: () {
          _logExternalAudioEnded('done');
          if (_finishExternalAudioOnDone) {
            unawaited(
              _stopAfterExternalAudioDone(
                generation: generation,
                requestId: requestId,
              ),
            );
          }
        },
      );
      Log.i('🎙️ [NativeASR] started with shared PCM stream');
    } else if (ok ?? false) {
      Log.i('🎙️ [NativeASR] started with platform microphone');
    }
    return ok ?? false;
  }

  Future<bool> recognizeSamples({
    required Float32List samples,
    String? locale,
    int chunkBytes = 3200,
  }) async {
    if (samples.isEmpty) {
      error.value = 'no speech samples';
      return false;
    }
    if (!supportsExternalAudioInput) {
      return start(locale: locale);
    }
    return start(
      locale: locale,
      audioStream: _pcm16Chunks(
        samplesToPcm16(samples),
        chunkBytes: chunkBytes,
      ),
      finishExternalAudioOnDone: true,
    );
  }

  Future<void> stop() async {
    try {
      _logExternalAudioEnded('stop');
      final externalAudioSub = _externalAudioSub;
      if (externalAudioSub != null) {
        await externalAudioSub.cancel();
        if (identical(_externalAudioSub, externalAudioSub)) {
          _externalAudioSub = null;
        }
      }
      await _externalAppendTail;
      if (_nativeSessionMayBeActive) {
        await _channel.invokeMethod<void>('stop');
      }
    } catch (e) {
      Log.w('🎙️ [NativeASR] stop failed: $e');
    } finally {
      isListening.value = false;
      _usingExternalAudio = false;
      _finishExternalAudioOnDone = false;
    }
  }

  /// Strictly retires native recognition before another start may be admitted.
  ///
  /// A native `start` can be waiting on an OS permission prompt. The first
  /// cancel releases that pending call, then a second cancel after every
  /// admitted start settles compensates for a plugin that completed late.
  /// Failed retirement remains fenced and must be retried before [start].
  Future<void> cancelAndDrain() {
    _acceptingNativeCallbacks = false;
    isListening.value = false;
    _nativeRetirementRequired = true;
    final current = _nativeRetirementFuture;
    if (current != null) return current;

    late final Future<void> retirement;
    retirement = _cancelAndDrainOnce()
        .then<void>((_) => _nativeRetirementRequired = false)
        .whenComplete(() {
          if (identical(_nativeRetirementFuture, retirement)) {
            _nativeRetirementFuture = null;
          }
        });
    _nativeRetirementFuture = retirement;
    return retirement;
  }

  /// Best-effort compatibility API for non-owning UI callers.
  ///
  /// Shared-capture teardown must use [cancelAndDrain] so errors propagate to
  /// the process-wide voice lease coordinator.
  Future<void> cancel() async {
    try {
      await cancelAndDrain();
    } catch (e) {
      Log.w('🎙️ [NativeASR] cancel failed: $e');
    }
  }

  /// Re-opens native recognition admission for the next mounted account.
  ///
  /// A failed drain deliberately cannot be bypassed: the account lifecycle
  /// retains its failed teardown lease and must retry it first.
  void activateAccount() {
    if (_accountActive) return;
    if (!_deactivationSucceeded) {
      throw StateError('native_asr_previous_account_not_drained');
    }
    _accountGeneration++;
    _accountActive = true;
    _deactivationSucceeded = false;
    _deactivationFuture = null;
  }

  /// Permanently fences the current account generation and drains native ASR.
  ///
  /// Unlike the ordinary UI [cancel], native errors are propagated so account
  /// teardown remains retryable and a different account cannot mount while an
  /// old recognizer may still own the microphone or emit transcripts.
  Future<void> deactivateAccountAndDrain() {
    if (_accountActive) {
      _accountActive = false;
      _accountGeneration++;
      _deactivationSucceeded = false;
      _acceptingNativeCallbacks = false;
      isListening.value = false;
      _activeRequestId = null;
      _allowLegacyCallbacks = false;
    }
    if (_deactivationSucceeded) {
      return _deactivationFuture ?? Future<void>.value();
    }
    final current = _deactivationFuture;
    if (current != null) return current;

    late final Future<void> draining;
    draining = _deactivateOnce();
    _deactivationFuture = draining;
    unawaited(
      draining.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_deactivationFuture, draining)) {
            _deactivationFuture = null;
          }
        },
      ),
    );
    return draining;
  }

  Future<void> _deactivateOnce() async {
    await cancelAndDrain();
    _deactivationSucceeded = true;
  }

  Future<void> _cancelAndDrainOnce() async {
    final hadAdmittedStarts = _inFlightStarts.isNotEmpty;
    if (hadAdmittedStarts) {
      // Do not wait for a permission-blocked start before asking the host to
      // cancel it. Android and iOS both resolve their pending start on cancel.
      await _invokeNativeCancelStrict();
    }
    Object? firstError;
    StackTrace? firstStackTrace;
    while (_inFlightStarts.isNotEmpty) {
      try {
        await Future.wait<bool>(
          _inFlightStarts.toList(growable: false),
          eagerError: false,
        );
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    try {
      await _cancelNativeSessionStrict(forceNativeCancel: hadAdmittedStarts);
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _cancelNativeSessionStrict({
    bool forceNativeCancel = false,
  }) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    final externalAudioSub = _externalAudioSub;
    if (externalAudioSub != null) {
      try {
        await externalAudioSub.cancel();
        if (identical(_externalAudioSub, externalAudioSub)) {
          _externalAudioSub = null;
        }
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    try {
      await _externalAppendTail;
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (_nativeSessionMayBeActive || forceNativeCancel) {
      try {
        await _invokeNativeCancelStrict();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _acceptingNativeCallbacks = false;
    isListening.value = false;
    _usingExternalAudio = false;
    _finishExternalAudioOnDone = false;
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _invokeNativeCancelStrict() async {
    try {
      await _channel.invokeMethod<void>('cancel');
      _nativeSessionMayBeActive = false;
      _activeRequestId = null;
    } catch (_) {
      // Transport failure leaves the native side effect unknowable. Preserve
      // the retry bit even when a successful pre-cancel cleared it earlier.
      _nativeSessionMayBeActive = true;
      rethrow;
    }
  }

  bool _isCurrentAccountGeneration(int generation) =>
      _accountActive && generation == _accountGeneration;

  bool _isCurrentStart(int generation, int requestId) =>
      _isCurrentAccountGeneration(generation) && _activeRequestId == requestId;

  Future<void> _handleMethodCall(MethodCall call) async {
    final callback = _decodeNativeCallback(call);
    final callbackRequestId = callback.requestId;
    final callbackMatchesRequest = callbackRequestId == null
        ? _allowLegacyCallbacks
        : callbackRequestId == _activeRequestId;
    if (!_acceptingNativeCallbacks || !callbackMatchesRequest) {
      Log.i('🎙️ [NativeASR] ignored stale callback=${call.method}');
      return;
    }
    switch (call.method) {
      case 'onPartial':
        final text = callback.value?.toString() ?? '';
        partialTranscript.value = text;
        Log.i('🎙️ [NativeASR] partial len=${text.trim().length}');
      case 'onFinal':
        final text = callback.value?.toString() ?? '';
        partialTranscript.value = text;
        isListening.value = false;
        _logExternalAudioEnded('final');
        unawaited(_externalAudioSub?.cancel());
        _externalAudioSub = null;
        _usingExternalAudio = false;
        _finishExternalAudioOnDone = false;
        _nativeSessionMayBeActive = false;
        _acceptingNativeCallbacks = false;
        _activeRequestId = null;
        Log.i('🎙️ [NativeASR] final len=${text.trim().length}');
        if (text.trim().isNotEmpty) _finalController.add(text);
      case 'onError':
        error.value = callback.value?.toString() ?? 'speech recognition failed';
        isListening.value = false;
        _logExternalAudioEnded('error');
        unawaited(_externalAudioSub?.cancel());
        _externalAudioSub = null;
        _usingExternalAudio = false;
        _finishExternalAudioOnDone = false;
        _nativeSessionMayBeActive = false;
        _acceptingNativeCallbacks = false;
        _activeRequestId = null;
        Log.w('🎙️ [NativeASR] error=${error.value}');
      case 'onListening':
        isListening.value = callback.value == true;
    }
  }

  ({int? requestId, Object? value}) _decodeNativeCallback(MethodCall call) {
    final arguments = call.arguments;
    if (arguments is! Map) {
      return (requestId: null, value: arguments);
    }
    final rawRequestId = arguments['requestId'];
    final requestId = rawRequestId is int
        ? rawRequestId
        : rawRequestId is num
        ? rawRequestId.toInt()
        : null;
    final value = switch (call.method) {
      'onListening' => arguments['listening'],
      'onError' => arguments['error'],
      _ => arguments['text'],
    };
    return (requestId: requestId, value: value);
  }

  @override
  void onClose() {
    _channel.setMethodCallHandler(null);
    _externalAudioSub?.cancel();
    _finalController.close();
    super.onClose();
  }

  static Uint8List samplesToPcm16(Float32List samples) {
    final out = Uint8List(samples.length * 2);
    final data = ByteData.sublistView(out);
    for (var i = 0; i < samples.length; i++) {
      final clamped = samples[i].clamp(-1.0, 1.0).toDouble();
      final value = clamped <= -1.0
          ? -32768
          : (clamped >= 1.0 ? 32767 : (clamped * 32768).round());
      data.setInt16(i * 2, value, Endian.little);
    }
    return out;
  }

  void _logExternalAudioEnded(String reason) {
    if (!_usingExternalAudio) return;
    Log.i(
      '🎙️ [NativeASR] external audio ended chunks=$_externalChunksSent '
      'bytes=$_externalBytesSent reason=$reason',
    );
    if (_externalChunksSent == 0 || _externalBytesSent == 0) {
      Log.w('🎙️ [NativeASR] no external PCM was sent before recognizer ended');
    }
  }

  Future<void> _stopAfterExternalAudioDone({
    required int generation,
    required int requestId,
  }) async {
    try {
      await _externalAppendTail;
      if (_isCurrentAccountGeneration(generation) &&
          _activeRequestId == requestId &&
          isListening.value &&
          _usingExternalAudio) {
        await _channel.invokeMethod<void>('stop');
      }
    } catch (e) {
      Log.w('🎙️ [NativeASR] finish external audio failed: $e');
    }
  }

  static Stream<Uint8List> _pcm16Chunks(
    Uint8List bytes, {
    required int chunkBytes,
  }) async* {
    final safeChunkBytes = chunkBytes <= 0 ? bytes.length : chunkBytes;
    for (var offset = 0; offset < bytes.length; offset += safeChunkBytes) {
      final end = offset + safeChunkBytes < bytes.length
          ? offset + safeChunkBytes
          : bytes.length;
      yield Uint8List.sublistView(bytes, offset, end);
    }
  }
}
