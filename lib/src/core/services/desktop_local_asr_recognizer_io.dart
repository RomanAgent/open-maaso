import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_contract.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:maaso/src/core/services/sherpa_bindings.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

DesktopLocalAsrRecognizerFactory createDesktopLocalAsrRecognizerFactory({
  required AppPlatformCapabilities platformCapabilities,
  required DesktopLocalAsrPackRuntime packRuntime,
  required DesktopLocalAsrMountFence isCurrentMount,
  int numThreads = 2,
}) {
  if (!_isDesktop(platformCapabilities.platform)) {
    return const UnsupportedDesktopLocalAsrRecognizerFactory();
  }
  return SherpaDesktopLocalAsrRecognizerFactory(
    packRuntime: packRuntime,
    isCurrentMount: isCurrentMount,
    numThreads: numThreads,
  );
}

final class UnsupportedDesktopLocalAsrRecognizerFactory
    implements DesktopLocalAsrRecognizerFactory {
  const UnsupportedDesktopLocalAsrRecognizerFactory();

  @override
  Future<DesktopLocalAsrRecognizer> create(
    DesktopLocalAsrModelPack modelPack,
  ) => Future<DesktopLocalAsrRecognizer>.error(
    UnsupportedError('desktop_local_asr_recognizer_unsupported'),
  );
}

/// sherpa_onnx 1.13.4 desktop recognizer factory backed only by verified,
/// account-scoped user-imported packs.
final class SherpaDesktopLocalAsrRecognizerFactory
    implements DesktopLocalAsrRecognizerFactory {
  SherpaDesktopLocalAsrRecognizerFactory({
    required DesktopLocalAsrPackRuntime packRuntime,
    required DesktopLocalAsrMountFence isCurrentMount,
    this.numThreads = 2,
  }) : _packRuntime = packRuntime,
       _isCurrentMount = isCurrentMount {
    if (numThreads < 1 || numThreads > 8) {
      throw ArgumentError.value(numThreads, 'numThreads', 'must be 1..8');
    }
  }

  final DesktopLocalAsrPackRuntime _packRuntime;
  final DesktopLocalAsrMountFence _isCurrentMount;
  final int numThreads;

  @override
  Future<DesktopLocalAsrRecognizer> create(
    DesktopLocalAsrModelPack modelPack,
  ) async {
    final verified = await _packRuntime.resolveForRecognition(modelPack);
    if (verified == null) {
      throw StateError('desktop_local_asr_model_pack_not_verified');
    }
    if (verified.descriptor.requiresLegalApproval) {
      throw StateError('desktop_local_asr_legal_approval_required');
    }
    final transport = await SherpaDesktopLocalAsrWorkerTransport._start(
      _workerConfigurationPayload(
        descriptor: verified.descriptor,
        directoryPath: verified.directoryPath,
        numThreads: numThreads,
      ),
    );
    return DesktopLocalAsrWorkerRecognizer(
      accountScopeDigest: _packRuntime.accountScopeDigest,
      generation: _packRuntime.generation,
      isCurrentMount: _isCurrentMount,
      transport: transport,
    );
  }
}

abstract interface class DesktopLocalAsrWorkerTransport {
  Future<String> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  });

  Future<void> close();
}

/// Account-fenced front end for a serialized ASR worker transport.
///
/// At most one PCM request is admitted. The transport owns the in-flight
/// payload; this object retains no PCM or transcript after the Future settles.
final class DesktopLocalAsrWorkerRecognizer
    implements DesktopLocalAsrRecognizer {
  DesktopLocalAsrWorkerRecognizer({
    required this.accountScopeDigest,
    required this.generation,
    required DesktopLocalAsrMountFence isCurrentMount,
    required DesktopLocalAsrWorkerTransport transport,
  }) : _isCurrentMount = isCurrentMount,
       _transport = transport;

  final String accountScopeDigest;
  final int generation;
  final DesktopLocalAsrMountFence _isCurrentMount;
  final DesktopLocalAsrWorkerTransport _transport;
  Future<void>? _activeDrain;
  Future<void>? _closeFuture;
  bool _closeRequested = false;

  @override
  Future<DesktopLocalAsrRecognition> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  }) async {
    if (_closeRequested) {
      throw StateError('desktop_local_asr_recognizer_closed');
    }
    if (_activeDrain != null) {
      throw StateError('desktop_local_asr_recognizer_busy');
    }
    if (sampleRateHz != 16000 || samples.isEmpty) {
      throw ArgumentError('desktop local ASR requires 16 kHz mono PCM');
    }
    if (!_mountIsCurrent()) {
      throw StateError('desktop_local_asr_stale_mount');
    }
    final operation = _transport
        .recognize(samples: samples, sampleRateHz: sampleRateHz, locale: locale)
        .then((text) {
          if (_closeRequested || !_mountIsCurrent()) {
            throw StateError('desktop_local_asr_stale_mount');
          }
          return DesktopLocalAsrRecognition(transcript: text);
        });
    late final Future<void> drain;
    drain = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_activeDrain, drain)) {
            _activeDrain = null;
          }
        });
    _activeDrain = drain;
    return operation;
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closeRequested = true;
    late final Future<void> closing;
    closing = _closeStrictly().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (identical(_closeFuture, closing)) _closeFuture = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _closeFuture = closing;
    return closing;
  }

  Future<void> _closeStrictly() async {
    final active = _activeDrain;
    if (active != null) await active;
    await _transport.close();
  }

  bool _mountIsCurrent() {
    try {
      return _isCurrentMount(
        accountScopeDigest: accountScopeDigest,
        generation: generation,
      );
    } on Object {
      return false;
    }
  }
}

/// Dedicated-isolate transport. Every sherpa native object is created, used,
/// and freed by [_sherpaDesktopLocalAsrWorkerMain].
final class SherpaDesktopLocalAsrWorkerTransport
    implements DesktopLocalAsrWorkerTransport {
  SherpaDesktopLocalAsrWorkerTransport._({
    required SendPort commandPort,
    required ReceivePort exitPort,
    required ReceivePort errorPort,
    required Future<void> exited,
    required StreamSubscription<Object?> exitSubscription,
    required StreamSubscription<Object?> errorSubscription,
  }) : _commandPort = commandPort,
       _exitPort = exitPort,
       _errorPort = errorPort,
       _exited = exited,
       _exitSubscription = exitSubscription,
       _errorSubscription = errorSubscription;

  final SendPort _commandPort;
  final ReceivePort _exitPort;
  final ReceivePort _errorPort;
  final Future<void> _exited;
  final StreamSubscription<Object?> _exitSubscription;
  final StreamSubscription<Object?> _errorSubscription;
  Future<void>? _closeFuture;
  bool _closed = false;
  bool _portsClosed = false;

  bool get isTerminallyClosed => _portsClosed;

  static Future<SherpaDesktopLocalAsrWorkerTransport> _start(
    Map<String, Object> configuration,
  ) async {
    final readyPort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    final exited = Completer<void>();
    final exitSubscription = exitPort.listen((Object? _) {
      if (!exited.isCompleted) exited.complete();
    });
    final errorSubscription = errorPort.listen((Object? _) {});
    try {
      await Isolate.spawn<Map<String, Object?>>(
        _sherpaDesktopLocalAsrWorkerMain,
        <String, Object?>{
          'readyPort': readyPort.sendPort,
          'configuration': configuration,
        },
        debugName: 'maaso-desktop-local-asr',
        errorsAreFatal: true,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
      final ready = await Future.any<Object?>(<Future<Object?>>[
        readyPort.first,
        exited.future.then<Object?>(
          (_) => const <String, Object>{
            'ok': false,
            'error': 'worker_exited_during_initialization',
          },
        ),
      ]);
      if (ready is! Map || ready['ok'] != true || ready['port'] is! SendPort) {
        await exited.future;
        throw StateError('desktop_local_asr_worker_initialization_failed');
      }
      final transport = SherpaDesktopLocalAsrWorkerTransport._(
        commandPort: ready['port'] as SendPort,
        exitPort: exitPort,
        errorPort: errorPort,
        exited: exited.future,
        exitSubscription: exitSubscription,
        errorSubscription: errorSubscription,
      );
      return transport;
    } catch (_) {
      readyPort.close();
      await exitSubscription.cancel();
      await errorSubscription.cancel();
      exitPort.close();
      errorPort.close();
      rethrow;
    } finally {
      readyPort.close();
    }
  }

  /// Protocol-only worker seam for lifecycle tests; it never initializes
  /// sherpa or receives model paths.
  static Future<SherpaDesktopLocalAsrWorkerTransport>
  startProtocolWorkerForTesting(void Function(SendPort) entrypoint) async {
    final readyPort = ReceivePort();
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    final exited = Completer<void>();
    final exitSubscription = exitPort.listen((Object? _) {
      if (!exited.isCompleted) exited.complete();
    });
    final errorSubscription = errorPort.listen((Object? _) {});
    try {
      await Isolate.spawn<SendPort>(
        entrypoint,
        readyPort.sendPort,
        debugName: 'maaso-desktop-local-asr-protocol-test',
        errorsAreFatal: true,
        onError: errorPort.sendPort,
        onExit: exitPort.sendPort,
      );
      final ready = await Future.any<Object?>(<Future<Object?>>[
        readyPort.first,
        exited.future.then<Object?>(
          (_) => const <String, Object>{
            'ok': false,
            'error': 'worker_exited_during_initialization',
          },
        ),
      ]);
      if (ready is! Map || ready['ok'] != true || ready['port'] is! SendPort) {
        await exited.future;
        throw StateError('desktop_local_asr_test_worker_initialization_failed');
      }
      return SherpaDesktopLocalAsrWorkerTransport._(
        commandPort: ready['port'] as SendPort,
        exitPort: exitPort,
        errorPort: errorPort,
        exited: exited.future,
        exitSubscription: exitSubscription,
        errorSubscription: errorSubscription,
      );
    } catch (_) {
      await exitSubscription.cancel();
      await errorSubscription.cancel();
      exitPort.close();
      errorPort.close();
      rethrow;
    } finally {
      readyPort.close();
    }
  }

  @override
  Future<String> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  }) async {
    if (_closed) throw StateError('desktop_local_asr_worker_closed');
    final pcmBytes = samples.buffer.asUint8List(
      samples.offsetInBytes,
      samples.lengthInBytes,
    );
    final response = await _request(<String, Object?>{
      'kind': 'recognize',
      'sampleRateHz': sampleRateHz,
      'locale': locale,
      'pcm': TransferableTypedData.fromList(<TypedData>[pcmBytes]),
    });
    if (response['ok'] != true || response['text'] is! String) {
      throw StateError('desktop_local_asr_worker_recognition_failed');
    }
    return response['text'] as String;
  }

  @override
  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    late final Future<void> closing;
    closing = _closeStrictly().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      if (identical(_closeFuture, closing)) _closeFuture = null;
      Error.throwWithStackTrace(error, stackTrace);
    });
    _closeFuture = closing;
    return closing;
  }

  Future<void> _closeStrictly() async {
    final response = await _request(<String, Object?>{
      'kind': 'close',
    }, allowClosed: true);
    if (response['ok'] != true) {
      if (response['error'] == 'worker_exited') {
        await _closeLocalPorts();
        return;
      }
      throw StateError('desktop_local_asr_worker_close_failed');
    }
    await _exited;
    await _closeLocalPorts();
  }

  Future<void> _closeLocalPorts() async {
    if (_portsClosed) return;
    _portsClosed = true;
    await _exitSubscription.cancel();
    await _errorSubscription.cancel();
    _exitPort.close();
    _errorPort.close();
  }

  Future<Map<Object?, Object?>> _request(
    Map<String, Object?> body, {
    bool allowClosed = false,
  }) async {
    if (_closed && !allowClosed) {
      throw StateError('desktop_local_asr_worker_closed');
    }
    final responsePort = ReceivePort();
    try {
      _commandPort.send(<String, Object?>{
        ...body,
        'responsePort': responsePort.sendPort,
      });
      final response = await Future.any<Object?>(<Future<Object?>>[
        responsePort.first,
        _exited.then<Object?>(
          (_) => const <String, Object>{'ok': false, 'error': 'worker_exited'},
        ),
      ]);
      if (response is! Map) {
        throw StateError('desktop_local_asr_worker_protocol_error');
      }
      return response.cast<Object?, Object?>();
    } finally {
      responsePort.close();
    }
  }
}

/// Builds the exact sherpa_onnx 1.13.4 configuration without loading weights.
/// This seam lets integrity/config tests run without native model artifacts.
sherpa.OfflineRecognizerConfig buildDesktopLocalAsrSherpaConfig({
  required DesktopLocalAsrModelDescriptor descriptor,
  required String directoryPath,
  String? locale,
  int numThreads = 2,
}) {
  if (numThreads < 1 || numThreads > 8) {
    throw ArgumentError.value(numThreads, 'numThreads', 'must be 1..8');
  }
  if (!p.isAbsolute(directoryPath) || directoryPath.contains('\u0000')) {
    throw ArgumentError.value(
      directoryPath,
      'directoryPath',
      'must be absolute',
    );
  }
  final payload = _workerConfigurationPayload(
    descriptor: descriptor,
    directoryPath: directoryPath,
    numThreads: numThreads,
  );
  return _buildSherpaConfigFromWorkerPayload(payload, locale: locale);
}

Map<String, Object> _workerConfigurationPayload({
  required DesktopLocalAsrModelDescriptor descriptor,
  required String directoryPath,
  required int numThreads,
}) {
  final paths = <String, String>{
    'tokens': p.join(directoryPath, descriptor.fileNamed('tokens.txt').name),
  };
  switch (descriptor.engine) {
    case DesktopLocalAsrEngine.moonshineV1:
      paths.addAll(<String, String>{
        'preprocessor': p.join(
          directoryPath,
          descriptor.fileNamed('preprocess.onnx').name,
        ),
        'encoder': p.join(
          directoryPath,
          descriptor.fileNamed('encode.int8.onnx').name,
        ),
        'uncachedDecoder': p.join(
          directoryPath,
          descriptor.fileNamed('uncached_decode.int8.onnx').name,
        ),
        'cachedDecoder': p.join(
          directoryPath,
          descriptor.fileNamed('cached_decode.int8.onnx').name,
        ),
      });
    case DesktopLocalAsrEngine.senseVoice:
      paths['model'] = p.join(
        directoryPath,
        descriptor.fileNamed('model.int8.onnx').name,
      );
  }
  return <String, Object>{
    'engine': descriptor.engine.name,
    'numThreads': numThreads,
    'paths': paths,
  };
}

sherpa.OfflineRecognizerConfig _buildSherpaConfigFromWorkerPayload(
  Map<String, Object> payload, {
  String? locale,
}) {
  final engineName = payload['engine'];
  final numThreads = payload['numThreads'];
  final rawPaths = payload['paths'];
  if (engineName is! String ||
      numThreads is! int ||
      numThreads < 1 ||
      numThreads > 8 ||
      rawPaths is! Map) {
    throw const FormatException('invalid desktop local ASR worker config');
  }
  final paths = rawPaths.cast<String, String>();
  final tokens = paths['tokens'];
  if (tokens == null) {
    throw const FormatException('missing desktop local ASR tokens path');
  }
  late final sherpa.OfflineModelConfig model;
  if (engineName == DesktopLocalAsrEngine.moonshineV1.name) {
    model = sherpa.OfflineModelConfig(
      moonshine: sherpa.OfflineMoonshineModelConfig(
        preprocessor: _requiredWorkerPath(paths, 'preprocessor'),
        encoder: _requiredWorkerPath(paths, 'encoder'),
        uncachedDecoder: _requiredWorkerPath(paths, 'uncachedDecoder'),
        cachedDecoder: _requiredWorkerPath(paths, 'cachedDecoder'),
      ),
      tokens: tokens,
      numThreads: numThreads,
      debug: false,
      provider: 'cpu',
    );
  } else if (engineName == DesktopLocalAsrEngine.senseVoice.name) {
    model = sherpa.OfflineModelConfig(
      senseVoice: sherpa.OfflineSenseVoiceModelConfig(
        model: _requiredWorkerPath(paths, 'model'),
        language: normalizeDesktopLocalAsrSenseVoiceLocale(locale),
        useInverseTextNormalization: true,
      ),
      tokens: tokens,
      numThreads: numThreads,
      debug: false,
      provider: 'cpu',
    );
  } else {
    throw const FormatException('unknown desktop local ASR engine');
  }
  return sherpa.OfflineRecognizerConfig(
    feat: const sherpa.FeatureConfig(sampleRate: 16000, featureDim: 80),
    model: model,
    decodingMethod: 'greedy_search',
  );
}

String _requiredWorkerPath(Map<String, String> paths, String key) {
  final value = paths[key];
  if (value == null || !p.isAbsolute(value) || value.contains('\u0000')) {
    throw const FormatException('invalid desktop local ASR model path');
  }
  return value;
}

String normalizeDesktopLocalAsrSenseVoiceLocale(String? locale) {
  final normalized = locale?.trim().toLowerCase().replaceAll('_', '-') ?? '';
  if (normalized.isEmpty || normalized == 'auto') return 'auto';
  if (normalized == 'yue' || normalized.startsWith('yue-')) return 'yue';
  final language = normalized.split('-').first;
  return switch (language) {
    'zh' => 'zh',
    'en' => 'en',
    'ja' => 'ja',
    'ko' => 'ko',
    _ => 'auto',
  };
}

bool _isDesktop(AppHostPlatform platform) =>
    platform == AppHostPlatform.macos ||
    platform == AppHostPlatform.windows ||
    platform == AppHostPlatform.linux;

Future<void> _sherpaDesktopLocalAsrWorkerMain(
  Map<String, Object?> initialization,
) async {
  final readyPort = initialization['readyPort'];
  final rawConfiguration = initialization['configuration'];
  if (readyPort is! SendPort || rawConfiguration is! Map) return;
  final configuration = rawConfiguration.cast<String, Object>();
  final commands = ReceivePort();
  sherpa.OfflineRecognizer? recognizer;
  try {
    initializeSherpaBindings();
    recognizer = sherpa.OfflineRecognizer(
      _buildSherpaConfigFromWorkerPayload(configuration),
    );
    readyPort.send(<String, Object>{'ok': true, 'port': commands.sendPort});
  } on Object {
    readyPort.send(<String, Object>{
      'ok': false,
      'error': 'native_initialization_failed',
    });
    commands.close();
    return;
  }

  try {
    await for (final rawMessage in commands) {
      if (rawMessage is! Map) continue;
      final message = rawMessage.cast<String, Object?>();
      final responsePort = message['responsePort'];
      if (responsePort is! SendPort) continue;
      final kind = message['kind'];
      if (kind == 'close') {
        try {
          recognizer?.free();
          recognizer = null;
          responsePort.send(const <String, Object>{'ok': true});
          commands.close();
          break;
        } on Object {
          responsePort.send(const <String, Object>{
            'ok': false,
            'error': 'native_close_failed',
          });
        }
        continue;
      }
      if (kind != 'recognize') {
        responsePort.send(const <String, Object>{
          'ok': false,
          'error': 'unknown_request',
        });
        continue;
      }

      Float32List? samples;
      try {
        final sampleRateHz = message['sampleRateHz'];
        final transferable = message['pcm'];
        if (sampleRateHz != 16000 || transferable is! TransferableTypedData) {
          throw const FormatException('invalid_pcm');
        }
        final bytes = transferable.materialize().asUint8List();
        if (bytes.isEmpty ||
            bytes.lengthInBytes % Float32List.bytesPerElement != 0) {
          throw const FormatException('invalid_pcm');
        }
        samples = Float32List.view(
          bytes.buffer,
          bytes.offsetInBytes,
          bytes.lengthInBytes ~/ Float32List.bytesPerElement,
        );
        final activeRecognizer = recognizer;
        if (activeRecognizer == null) {
          throw StateError('recognizer_closed');
        }
        final engine = configuration['engine'];
        if (engine == DesktopLocalAsrEngine.senseVoice.name) {
          activeRecognizer.setConfig(
            _buildSherpaConfigFromWorkerPayload(
              configuration,
              locale: message['locale'] as String?,
            ),
          );
        }
        final stream = activeRecognizer.createStream();
        try {
          stream.acceptWaveform(samples: samples, sampleRate: 16000);
          activeRecognizer.decode(stream);
          final text = activeRecognizer.getResult(stream).text;
          responsePort.send(<String, Object>{'ok': true, 'text': text});
        } finally {
          stream.free();
        }
      } on Object {
        responsePort.send(const <String, Object>{
          'ok': false,
          'error': 'native_recognition_failed',
        });
      } finally {
        samples?.fillRange(0, samples.length, 0);
      }
    }
  } finally {
    recognizer?.free();
    commands.close();
  }
}
