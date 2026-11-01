import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_pack_runtime_contract.dart';
import 'package:maaso/src/core/services/desktop_local_asr_recognizer_io.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';

void main() {
  group('sherpa desktop local ASR configuration', () {
    test('maps Moonshine v1 files without loading model weights', () {
      final config = buildDesktopLocalAsrSherpaConfig(
        descriptor: DesktopLocalAsrModelCatalog.moonshineTinyEnInt8,
        directoryPath: '/verified/moonshine',
        numThreads: 3,
      );

      expect(config.feat.sampleRate, 16000);
      expect(config.feat.featureDim, 80);
      expect(config.model.tokens, '/verified/moonshine/tokens.txt');
      expect(config.model.numThreads, 3);
      expect(config.model.debug, isFalse);
      expect(config.model.provider, 'cpu');
      expect(
        config.model.moonshine.preprocessor,
        '/verified/moonshine/preprocess.onnx',
      );
      expect(
        config.model.moonshine.encoder,
        '/verified/moonshine/encode.int8.onnx',
      );
      expect(
        config.model.moonshine.uncachedDecoder,
        '/verified/moonshine/uncached_decode.int8.onnx',
      );
      expect(
        config.model.moonshine.cachedDecoder,
        '/verified/moonshine/cached_decode.int8.onnx',
      );
      expect(config.model.moonshine.mergedDecoder, isEmpty);
    });

    test('maps SenseVoice files, locale, and inverse normalization', () {
      final descriptor = DesktopLocalAsrModelCatalog.senseVoiceInt8;
      final config = buildDesktopLocalAsrSherpaConfig(
        descriptor: descriptor,
        directoryPath: '/verified/sensevoice',
        locale: 'zh-CN',
      );

      expect(config.model.tokens, '/verified/sensevoice/tokens.txt');
      expect(
        config.model.senseVoice.model,
        '/verified/sensevoice/model.int8.onnx',
      );
      expect(config.model.senseVoice.language, 'zh');
      expect(config.model.senseVoice.useInverseTextNormalization, isTrue);
      expect(normalizeDesktopLocalAsrSenseVoiceLocale('yue-HK'), 'yue');
      expect(normalizeDesktopLocalAsrSenseVoiceLocale('fr-FR'), 'auto');
    });

    test('mobile factory remains a non-loading stub', () async {
      final factory = createDesktopLocalAsrRecognizerFactory(
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.android,
        ),
        packRuntime: _UnavailablePackRuntime(),
        isCurrentMount: ({required accountScopeDigest, required generation}) =>
            true,
      );

      await expectLater(
        factory.create(
          DesktopLocalAsrModelCatalog.moonshineTinyEnInt8.coreModelPack,
        ),
        throwsUnsupportedError,
      );
    });

    test(
      'factory rejects a gated descriptor from a permissive pack runtime',
      () async {
        final descriptor = DesktopLocalAsrModelCatalog.senseVoiceInt8;
        final factory = SherpaDesktopLocalAsrRecognizerFactory(
          packRuntime: _UnavailablePackRuntime(
            verifiedPack: DesktopLocalAsrVerifiedPack(
              descriptor: descriptor,
              directoryPath: '/verified/sensevoice',
            ),
          ),
          isCurrentMount:
              ({required accountScopeDigest, required generation}) => true,
        );

        await expectLater(
          factory.create(descriptor.coreModelPack),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'desktop_local_asr_legal_approval_required',
            ),
          ),
        );
      },
    );
  });

  group('DesktopLocalAsrWorkerRecognizer contract', () {
    test('admits one request at a time and closes transport once', () async {
      final transport = _FakeWorkerTransport.pending();
      final mount = _Mount();
      final recognizer = _recognizer(transport, mount);

      final first = recognizer.recognize(
        samples: Float32List.fromList(<double>[0.1, -0.2]),
        sampleRateHz: 16000,
        locale: 'en-US',
      );
      await transport.started.future;
      await expectLater(
        recognizer.recognize(
          samples: Float32List.fromList(<double>[0.3]),
          sampleRateHz: 16000,
        ),
        throwsStateError,
      );
      expect(transport.maximumConcurrentRequests, 1);
      transport.complete('first');
      expect((await first).transcript, 'first');

      await recognizer.close();
      await recognizer.close();
      expect(transport.closeCount, 1);
      await expectLater(
        recognizer.recognize(
          samples: Float32List.fromList(<double>[0.4]),
          sampleRateHz: 16000,
        ),
        throwsStateError,
      );
    });

    test(
      'close waits for in-flight actor work and rejects its result',
      () async {
        final transport = _FakeWorkerTransport.pending();
        final mount = _Mount();
        final recognizer = _recognizer(transport, mount);
        final recognition = recognizer.recognize(
          samples: Float32List.fromList(<double>[0.1]),
          sampleRateHz: 16000,
        );
        await transport.started.future;

        var closed = false;
        final closing = recognizer.close().then((_) => closed = true);
        await Future<void>.delayed(Duration.zero);
        expect(closed, isFalse);
        expect(transport.closeCount, 0);
        transport.complete('must not escape');

        await expectLater(recognition, throwsStateError);
        await closing;
        expect(closed, isTrue);
        expect(transport.closeCount, 1);
      },
    );

    test(
      'rejects a completion after account generation becomes stale',
      () async {
        final transport = _FakeWorkerTransport.pending();
        final mount = _Mount();
        final recognizer = _recognizer(transport, mount);
        final recognition = recognizer.recognize(
          samples: Float32List.fromList(<double>[0.1]),
          sampleRateHz: 16000,
        );
        await transport.started.future;
        mount.generation = 2;
        transport.complete('account A transcript');

        await expectLater(recognition, throwsStateError);
        await recognizer.close();
        expect(transport.closeCount, 1);
      },
    );

    test(
      'Moonshine stays English-only without rejecting the UI locale',
      () async {
        final transport = _FakeWorkerTransport.pending();
        final recognizer = _recognizer(transport, _Mount());

        final recognition = recognizer.recognize(
          samples: Float32List.fromList(<double>[0.1]),
          sampleRateHz: 16000,
          locale: 'zh-CN',
        );
        await transport.started.future;
        transport.complete('english transcript');

        expect((await recognition).transcript, 'english transcript');
        expect(transport.locale, 'zh-CN');
        await recognizer.close();
      },
    );

    test('failed close can be retried strictly', () async {
      final transport = _FakeWorkerTransport.pending(failedCloseCount: 1);
      final recognizer = _recognizer(transport, _Mount());

      await expectLater(recognizer.close(), throwsStateError);
      expect(transport.closeCount, 1);
      await recognizer.close();
      expect(transport.closeCount, 2);
    });
  });

  group('Sherpa worker transport close protocol', () {
    test(
      'unexpected worker exit is terminal cleanup, not an infinite failure',
      () async {
        final transport =
            await SherpaDesktopLocalAsrWorkerTransport.startProtocolWorkerForTesting(
              _unexpectedExitWorker,
            );
        await Future<void>.delayed(const Duration(milliseconds: 10));

        await transport.close();
        await transport.close();
        expect(transport.isTerminallyClosed, isTrue);
      },
    );

    test('live worker close rejection fails once and can be retried', () async {
      final transport =
          await SherpaDesktopLocalAsrWorkerTransport.startProtocolWorkerForTesting(
            _retryableCloseWorker,
          );

      await expectLater(transport.close(), throwsStateError);
      expect(transport.isTerminallyClosed, isFalse);
      await transport.close();
      expect(transport.isTerminallyClosed, isTrue);
    });
  });
}

DesktopLocalAsrWorkerRecognizer _recognizer(
  DesktopLocalAsrWorkerTransport transport,
  _Mount mount,
) => DesktopLocalAsrWorkerRecognizer(
  accountScopeDigest: _scope,
  generation: 1,
  isCurrentMount: ({required accountScopeDigest, required generation}) =>
      accountScopeDigest == _scope && generation == mount.generation,
  transport: transport,
);

final class _FakeWorkerTransport implements DesktopLocalAsrWorkerTransport {
  _FakeWorkerTransport.pending({this.failedCloseCount = 0});

  final started = Completer<void>();
  final _result = Completer<String>();
  int activeRequests = 0;
  int maximumConcurrentRequests = 0;
  int closeCount = 0;
  int failedCloseCount;
  String? locale;

  @override
  Future<String> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  }) async {
    this.locale = locale;
    activeRequests++;
    if (activeRequests > maximumConcurrentRequests) {
      maximumConcurrentRequests = activeRequests;
    }
    if (!started.isCompleted) started.complete();
    try {
      return await _result.future;
    } finally {
      activeRequests--;
    }
  }

  void complete(String text) => _result.complete(text);

  @override
  Future<void> close() async {
    closeCount++;
    if (failedCloseCount > 0) {
      failedCloseCount--;
      throw StateError('transient close failure');
    }
  }
}

final class _UnavailablePackRuntime implements DesktopLocalAsrPackRuntime {
  _UnavailablePackRuntime({this.verifiedPack});

  final DesktopLocalAsrVerifiedPack? verifiedPack;

  @override
  String get accountScopeDigest => _scope;

  @override
  List<DesktopLocalAsrModelDescriptor> get descriptors =>
      DesktopLocalAsrModelCatalog.all;

  @override
  int get generation => 1;

  @override
  DesktopLocalAsrPackRuntimeState get state =>
      const DesktopLocalAsrPackRuntimeState.initial();

  @override
  bool get supported => false;

  @override
  Future<DesktopLocalAsrPackImportResult> importUserDirectory({
    required String modelId,
    required String sourceDirectoryPath,
    bool licenseAcknowledged = false,
  }) => throw UnimplementedError();

  @override
  Future<bool> isAvailable(DesktopLocalAsrModelPack modelPack) async => false;

  @override
  Future<DesktopLocalAsrVerifiedPack?> resolve(
    DesktopLocalAsrModelPack modelPack,
  ) async => null;

  @override
  Future<DesktopLocalAsrVerifiedPack?> resolveForRecognition(
    DesktopLocalAsrModelPack modelPack,
  ) async => verifiedPack;

  @override
  Future<void> sealAndDrain() async {}
}

final class _Mount {
  int generation = 1;
}

const String _scope =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void _unexpectedExitWorker(SendPort readyPort) {
  final commands = ReceivePort();
  readyPort.send(<String, Object>{'ok': true, 'port': commands.sendPort});
  commands.close();
}

void _retryableCloseWorker(SendPort readyPort) {
  final commands = ReceivePort();
  var closeCount = 0;
  readyPort.send(<String, Object>{'ok': true, 'port': commands.sendPort});
  commands.listen((Object? rawMessage) {
    if (rawMessage is! Map) return;
    final responsePort = rawMessage['responsePort'];
    if (responsePort is! SendPort || rawMessage['kind'] != 'close') return;
    closeCount++;
    if (closeCount == 1) {
      responsePort.send(const <String, Object>{
        'ok': false,
        'error': 'native_close_failed',
      });
      return;
    }
    responsePort.send(const <String, Object>{'ok': true});
    commands.close();
  });
}
