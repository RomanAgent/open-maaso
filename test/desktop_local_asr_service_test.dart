import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_model_catalog.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';

void main() {
  group('DesktopLocalAsrService', () {
    test('is inert and disabled by default on every host', () async {
      final store = _FakePreferenceStore();
      final factory = _FakeRecognizerFactory();
      final mount = _Mount(_scopeA, 1);
      final service = await _createService(
        store: store,
        factory: factory,
        mount: mount,
      );

      expect(service.state.value.lifecycle, DesktopLocalAsrLifecycle.ready);
      expect(service.state.value.preferenceEnabled, isFalse);
      expect(service.state.value.effectiveEnabled, isFalse);
      expect(service.state.value.completedDecodeCount, 0);
      expect(service.state.value.rejectedDecodeCount, 0);
      expect(store.writes, isEmpty);
      expect(factory.createCount, 0);

      final result = await service.decode(
        samples: Float32List.fromList(<double>[0.1]),
        sampleRateHz: 16000,
      );
      expect(result.failure, DesktopLocalAsrFailure.disabled);
      expect(factory.createCount, 0);

      final mobileStore = _FakePreferenceStore();
      final mobileFactory = _FakeRecognizerFactory();
      final mobile = await _createService(
        store: mobileStore,
        factory: mobileFactory,
        mount: mount,
        platform: AppHostPlatform.ios,
      );
      await mobile.selectModel(_modelId);
      await expectLater(
        mobile.setEnabled(true),
        throwsA(isA<UnsupportedError>()),
      );
      expect(mobile.state.value.effectiveEnabled, isFalse);
      expect(mobileFactory.createCount, 0);
    });

    test('opt-in lazily loads and reuses one recognizer', () async {
      final store = _FakePreferenceStore();
      final recognizer = _FakeRecognizer.immediate('  hello desktop  ');
      final factory = _FakeRecognizerFactory(<_FakeRecognizer>[recognizer]);
      final mount = _Mount(_scopeA, 1);
      final service = await _createService(
        store: store,
        factory: factory,
        mount: mount,
      );

      await service.selectModel(_modelId);
      await service.setEnabled(true);

      expect(store.writes, hasLength(2));
      expect(store.writes.last.enabled, isTrue);
      expect(store.writes.last.selectedModelId, _modelId);
      expect(service.state.value.effectiveEnabled, isTrue);
      expect(service.state.value.selectedModelAvailable, isTrue);
      expect(service.selectedModelPack?.id, _modelId);
      expect(service.modelPacks.keys, <String>[_modelId]);
      expect(() => service.modelPacks.clear(), throwsUnsupportedError);
      expect(factory.createCount, 0);

      final result = await service.decode(
        samples: Float32List.fromList(<double>[0.1, -0.2, 0.3]),
        sampleRateHz: 16000,
        locale: 'zh-CN',
      );
      await _flushAsync();

      expect(result.accepted, isTrue);
      expect(result.transcript, 'hello desktop');
      expect(factory.createdModelIds, <String>[_modelId]);
      expect(recognizer.recognizeCount, 1);
      expect(recognizer.closeCount, 0);
      expect(recognizer.sampleRateHz, 16000);
      expect(recognizer.locale, 'zh-CN');
      expect(service.state.value.lifecycle, DesktopLocalAsrLifecycle.ready);
      expect(service.state.value.completedDecodeCount, 1);
      expect(service.state.value.decodeActive, isFalse);

      final reused = await service.decode(
        samples: Float32List.fromList(<double>[0.4]),
        sampleRateHz: 16000,
      );
      expect(reused.transcript, 'hello desktop');
      expect(factory.createCount, 1);
      expect(recognizer.recognizeCount, 2);
      expect(recognizer.closeCount, 0);

      await service.setEnabled(false);
      expect(recognizer.closeCount, 1);
      expect(service.state.value.effectiveEnabled, isFalse);
    });

    test('supports explicit opt-in on macOS, Windows, and Linux', () async {
      for (final platform in <AppHostPlatform>[
        AppHostPlatform.macos,
        AppHostPlatform.windows,
        AppHostPlatform.linux,
      ]) {
        final service = await _createService(
          store: _FakePreferenceStore(),
          factory: _FakeRecognizerFactory(),
          mount: _Mount(_scopeA, 1),
          platform: platform,
        );
        await service.selectModel(_modelId);
        await service.setEnabled(true);
        expect(service.effectiveEnabled, isTrue, reason: platform.name);
      }
    });

    test(
      'closes cached recognizer after durable model switch and disable',
      () async {
        final store = _FakePreferenceStore(
          DesktopLocalAsrPreferenceSnapshot(
            accountScopeDigest: _scopeA,
            revision: 1,
            enabled: true,
            selectedModelId: _modelId,
          ),
        );
        final firstRecognizer = _FakeRecognizer.immediate('first model');
        final secondRecognizer = _FakeRecognizer.immediate('second model');
        final factory = _FakeRecognizerFactory(<_FakeRecognizer>[
          firstRecognizer,
          secondRecognizer,
        ]);
        final mount = _Mount(_scopeA, 1);
        final service = await _createService(
          store: store,
          factory: factory,
          mount: mount,
          modelIds: const <String>[_modelId, _modelId2],
        );

        expect(
          (await service.decode(
            samples: Float32List.fromList(<double>[0.1]),
            sampleRateHz: 16000,
          )).transcript,
          'first model',
        );
        firstRecognizer.onClose = () {
          expect(store.writes.last.selectedModelId, _modelId2);
          expect(store.writes.last.enabled, isTrue);
        };
        await service.selectModel(_modelId2);

        expect(firstRecognizer.closeCount, 1);
        expect(service.selectedModelPack?.id, _modelId2);
        expect(factory.createCount, 1);
        expect(
          (await service.decode(
            samples: Float32List.fromList(<double>[0.2]),
            sampleRateHz: 16000,
          )).transcript,
          'second model',
        );
        secondRecognizer.onClose = () {
          expect(store.writes.last.selectedModelId, _modelId2);
          expect(store.writes.last.enabled, isFalse);
        };
        await service.setEnabled(false);

        expect(secondRecognizer.closeCount, 1);
        expect(factory.createCount, 2);
        expect(service.state.value.preferenceEnabled, isFalse);
      },
    );

    test(
      'missing or tampered model pack fails closed without factory IO',
      () async {
        final availability = _FakeModelAvailability(false);
        final factory = _FakeRecognizerFactory(<_FakeRecognizer>[
          _FakeRecognizer.immediate('must not run'),
        ]);
        final mount = _Mount(_scopeA, 1);
        final service = await _enabledService(
          factory: factory,
          mount: mount,
          availability: availability,
        );

        expect(service.state.value.preferenceEnabled, isTrue);
        expect(service.state.value.selectedModelAvailable, isFalse);
        expect(service.state.value.effectiveEnabled, isFalse);
        expect(service.state.value.lastFailure, isNull);
        expect(availability.checkCount, 0);
        expect(await service.isOperational(), isFalse);
        expect(availability.checkCount, 1);
        expect(
          service.state.value.lastFailure,
          DesktopLocalAsrFailure.modelUnavailable,
        );
        final unavailable = await service.decode(
          samples: Float32List.fromList(<double>[0.1]),
          sampleRateHz: 16000,
        );
        expect(unavailable.failure, DesktopLocalAsrFailure.modelUnavailable);
        expect(factory.createCount, 0);

        availability.available = true;
        expect(await service.isOperational(), isTrue);
        expect(service.state.value.effectiveEnabled, isTrue);
        availability.available = false;
        expect(await service.isOperational(), isFalse);
        expect(service.state.value.effectiveEnabled, isFalse);
        expect(factory.createCount, 0);
      },
    );

    test('availability timeout joins one in-flight integrity check', () async {
      final availability = _FakeModelAvailability(false)
        ..pending = Completer<bool>();
      final service = await _enabledService(
        factory: _FakeRecognizerFactory(),
        mount: _Mount(_scopeA, 1),
        availability: availability,
        timeout: const Duration(milliseconds: 10),
        availabilityTimeout: const Duration(milliseconds: 10),
      );

      final first = service.isOperational();
      final second = service.isOperational();
      expect(await first, isFalse);
      expect(await second, isFalse);
      expect(availability.checkCount, 1);

      expect(await service.isOperational(), isFalse);
      expect(availability.checkCount, 1);
      availability.pending!.complete(true);
      await _flushAsync();

      availability.pending = null;
      availability.available = true;
      expect(await service.isOperational(), isTrue);
      expect(availability.checkCount, 2);
    });

    test(
      'restores enabled metadata without model IO on the startup path',
      () async {
        final availability = _FakeModelAvailability(true);
        final service = await _enabledService(
          factory: _FakeRecognizerFactory(),
          mount: _Mount(_scopeA, 1),
          availability: availability,
        );

        expect(service.state.value.preferenceEnabled, isTrue);
        expect(service.state.value.selectedModelId, _modelId);
        expect(service.state.value.selectedModelAvailable, isFalse);
        expect(service.state.value.effectiveEnabled, isFalse);
        expect(availability.checkCount, 0);

        expect(await service.isOperational(), isTrue);
        expect(availability.checkCount, 1);
        expect(service.state.value.effectiveEnabled, isTrue);
      },
    );

    test('restored legal-gated selection remains unavailable', () async {
      final gatedId = DesktopLocalAsrModelCatalog.senseVoiceInt8.id;
      final store = _FakePreferenceStore(
        DesktopLocalAsrPreferenceSnapshot(
          accountScopeDigest: _scopeA,
          revision: 7,
          enabled: true,
          selectedModelId: gatedId,
        ),
      );
      final availability = _FakeModelAvailability(true);
      final factory = _FakeRecognizerFactory(<_FakeRecognizer>[
        _FakeRecognizer.immediate('must not run'),
      ]);
      final service = await _createService(
        store: store,
        factory: factory,
        mount: _Mount(_scopeA, 1),
        availability: availability,
        modelIds: DesktopLocalAsrModelCatalog.productionSelectableModelPacks
            .map((pack) => pack.id)
            .toList(growable: false),
      );

      expect(service.state.value.selectedModelId, gatedId);
      expect(service.state.value.preferenceEnabled, isTrue);
      expect(service.state.value.effectiveEnabled, isFalse);
      expect(
        service.state.value.lastFailure,
        DesktopLocalAsrFailure.modelUnavailable,
      );
      expect(await service.isOperational(), isFalse);
      expect(availability.checkCount, 0);
      final result = await service.decode(
        samples: Float32List.fromList(<double>[0.1]),
        sampleRateHz: 16000,
      );
      expect(result.failure, DesktopLocalAsrFailure.modelUnavailable);
      expect(factory.createCount, 0);
    });

    test(
      'rejects a concurrent decode without creating another recognizer',
      () async {
        final recognizer = _FakeRecognizer.pending();
        final factory = _FakeRecognizerFactory(<_FakeRecognizer>[recognizer]);
        final mount = _Mount(_scopeA, 1);
        final service = await _enabledService(factory: factory, mount: mount);

        final first = service.decode(
          samples: Float32List.fromList(<double>[0.1, 0.2]),
          sampleRateHz: 16000,
        );
        await recognizer.started.future;
        final second = await service.decode(
          samples: Float32List.fromList(<double>[0.3]),
          sampleRateHz: 16000,
        );

        expect(second.failure, DesktopLocalAsrFailure.busy);
        expect(factory.createCount, 1);
        recognizer.complete('first');
        expect((await first).transcript, 'first');
        await _flushAsync();
        expect(recognizer.recognizeCount, 1);
        expect(service.state.value.rejectedDecodeCount, 1);
      },
    );

    test(
      'rejects stale A completion after B becomes the current mount',
      () async {
        final recognizerA = _FakeRecognizer.pending();
        final factoryA = _FakeRecognizerFactory(<_FakeRecognizer>[recognizerA]);
        final mount = _Mount(_scopeA, 1);
        final serviceA = await _enabledService(factory: factoryA, mount: mount);

        final oldDecode = serviceA.decode(
          samples: Float32List.fromList(<double>[0.1, 0.2]),
          sampleRateHz: 16000,
        );
        await recognizerA.started.future;
        mount
          ..scope = _scopeB
          ..generation = 2;
        recognizerA.complete('must not escape A');

        final oldResult = await oldDecode;
        expect(oldResult.accepted, isFalse);
        expect(oldResult.transcript, isNull);
        expect(oldResult.failure, DesktopLocalAsrFailure.staleMount);

        final recognizerB = _FakeRecognizer.immediate('account B');
        final factoryB = _FakeRecognizerFactory(<_FakeRecognizer>[recognizerB]);
        final serviceB = await _enabledService(
          factory: factoryB,
          mount: mount,
          scope: _scopeB,
          generation: 2,
        );
        final newResult = await serviceB.decode(
          samples: Float32List.fromList(<double>[0.4]),
          sampleRateHz: 16000,
        );
        expect(newResult.transcript, 'account B');
        await serviceA.sealAndDrain();
        expect(
          serviceA.state.value.lifecycle,
          DesktopLocalAsrLifecycle.retired,
        );
      },
    );

    test(
      'strict drain waits for native completion and recognizer close',
      () async {
        final recognizer = _FakeRecognizer.pending();
        final factory = _FakeRecognizerFactory(<_FakeRecognizer>[recognizer]);
        final mount = _Mount(_scopeA, 1);
        final service = await _enabledService(factory: factory, mount: mount);

        final decode = service.decode(
          samples: Float32List.fromList(<double>[0.1, 0.2]),
          sampleRateHz: 16000,
        );
        await recognizer.started.future;
        var drained = false;
        final drain = service.sealAndDrain().then((_) => drained = true);
        await _flushAsync();

        expect(drained, isFalse);
        expect(
          service.state.value.lifecycle,
          DesktopLocalAsrLifecycle.retiring,
        );
        recognizer.complete('late');
        expect((await decode).failure, DesktopLocalAsrFailure.staleMount);
        await drain;

        expect(drained, isTrue);
        expect(recognizer.closeCount, 1);
        expect(service.state.value.lifecycle, DesktopLocalAsrLifecycle.retired);
        expect(service.state.value.decodeActive, isFalse);
        final rejected = await service.decode(
          samples: Float32List.fromList(<double>[0.3]),
          sampleRateHz: 16000,
        );
        expect(rejected.failure, DesktopLocalAsrFailure.unavailable);
      },
    );

    test('failed strict close keeps retirement retryable', () async {
      final recognizer = _FakeRecognizer.immediate('ready')
        ..closeFailuresRemaining = 1;
      final factory = _FakeRecognizerFactory(<_FakeRecognizer>[recognizer]);
      final mount = _Mount(_scopeA, 1);
      final service = await _enabledService(factory: factory, mount: mount);

      expect(
        (await service.decode(
          samples: Float32List.fromList(<double>[0.1]),
          sampleRateHz: 16000,
        )).accepted,
        isTrue,
      );
      await expectLater(service.sealAndDrain(), throwsStateError);
      expect(service.state.value.lifecycle, DesktopLocalAsrLifecycle.retiring);

      await service.sealAndDrain();
      expect(recognizer.closeCount, 2);
      expect(service.state.value.lifecycle, DesktopLocalAsrLifecycle.retired);
    });

    test(
      'timeout stays busy until the underlying recognizer really ends',
      () async {
        final recognizer = _FakeRecognizer.pending();
        final factory = _FakeRecognizerFactory(<_FakeRecognizer>[recognizer]);
        final mount = _Mount(_scopeA, 1);
        final service = await _enabledService(
          factory: factory,
          mount: mount,
          timeout: const Duration(milliseconds: 10),
        );

        final result = await service.decode(
          samples: Float32List.fromList(<double>[0.1, 0.2]),
          sampleRateHz: 16000,
        );
        expect(result.failure, DesktopLocalAsrFailure.timeout);
        expect(service.state.value.decodeActive, isTrue);

        final concurrent = await service.decode(
          samples: Float32List.fromList(<double>[0.3]),
          sampleRateHz: 16000,
        );
        expect(concurrent.failure, DesktopLocalAsrFailure.busy);

        recognizer.complete('too late');
        await service.sealAndDrain();
        expect(recognizer.closeCount, 1);
        expect(service.state.value.decodeActive, isFalse);
      },
    );

    test('recognizer and preference failures fail closed', () async {
      final failingRecognizer = _FakeRecognizer.failing();
      final factory = _FakeRecognizerFactory(<_FakeRecognizer>[
        failingRecognizer,
      ]);
      final mount = _Mount(_scopeA, 1);
      final service = await _enabledService(factory: factory, mount: mount);

      final result = await service.decode(
        samples: Float32List.fromList(<double>[0.1]),
        sampleRateHz: 16000,
      );
      expect(result.failure, DesktopLocalAsrFailure.recognizerError);
      expect(failingRecognizer.closeCount, 1);

      final failingStore = _FakePreferenceStore()..failWrites = true;
      final secondFactory = _FakeRecognizerFactory();
      final second = await _createService(
        store: failingStore,
        factory: secondFactory,
        mount: mount,
      );
      await expectLater(second.selectModel(_modelId), throwsStateError);
      expect(second.state.value.preferenceEnabled, isFalse);
      expect(second.state.value.selectedModelId, isNull);
      expect(secondFactory.createCount, 0);
    });

    test('bounds input and zeroes only its private PCM copy', () async {
      final recognizer = _FakeRecognizer.immediate('safe');
      final factory = _FakeRecognizerFactory(<_FakeRecognizer>[recognizer]);
      final mount = _Mount(_scopeA, 1);
      final service = await _enabledService(
        factory: factory,
        mount: mount,
        maximumSampleCount: 3,
      );

      final oversized = await service.decode(
        samples: Float32List.fromList(<double>[0, 1, 2, 3]),
        sampleRateHz: 16000,
      );
      final nonFinite = await service.decode(
        samples: Float32List.fromList(<double>[double.nan]),
        sampleRateHz: 16000,
      );
      expect(oversized.failure, DesktopLocalAsrFailure.invalidAudio);
      expect(nonFinite.failure, DesktopLocalAsrFailure.invalidAudio);
      expect(factory.createCount, 0);

      final callerSamples = Float32List.fromList(<double>[0.25, -0.5]);
      final result = await service.decode(
        samples: callerSamples,
        sampleRateHz: 16000,
      );
      await _flushAsync();

      expect(result.accepted, isTrue);
      expect(callerSamples, <double>[0.25, -0.5]);
      expect(recognizer.receivedSamples, isNot(same(callerSamples)));
      expect(recognizer.receivedSamples, everyElement(0));
      expect(service.state.value.toString(), isNot(contains('0.25')));
      expect(service.state.value.toString(), isNot(contains('-0.5')));
    });
  });
}

Future<DesktopLocalAsrService> _createService({
  required _FakePreferenceStore store,
  required _FakeRecognizerFactory factory,
  required _Mount mount,
  String scope = _scopeA,
  int generation = 1,
  AppHostPlatform platform = AppHostPlatform.macos,
  Duration timeout = const Duration(seconds: 1),
  Duration availabilityTimeout = const Duration(seconds: 1),
  int maximumSampleCount = 480000,
  _FakeModelAvailability? availability,
  List<String> modelIds = const <String>[_modelId],
}) async {
  final service = DesktopLocalAsrService(
    preferenceStore: store,
    recognizerFactory: factory,
    modelAvailability: availability ?? _FakeModelAvailability(true),
    modelPacks: modelIds.map((id) => DesktopLocalAsrModelPack(id: id)),
    platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
    accountScopeDigest: scope,
    generation: generation,
    isCurrentMount: ({required accountScopeDigest, required generation}) =>
        mount.scope == accountScopeDigest && mount.generation == generation,
    decodeTimeout: timeout,
    availabilityTimeout: availabilityTimeout,
    maximumSampleCount: maximumSampleCount,
  );
  return service.init();
}

Future<DesktopLocalAsrService> _enabledService({
  required _FakeRecognizerFactory factory,
  required _Mount mount,
  String scope = _scopeA,
  int generation = 1,
  Duration timeout = const Duration(seconds: 1),
  Duration availabilityTimeout = const Duration(seconds: 1),
  int maximumSampleCount = 480000,
  _FakeModelAvailability? availability,
}) async {
  final store = _FakePreferenceStore(
    DesktopLocalAsrPreferenceSnapshot(
      accountScopeDigest: scope,
      revision: 1,
      enabled: true,
      selectedModelId: _modelId,
    ),
  );
  return _createService(
    store: store,
    factory: factory,
    mount: mount,
    scope: scope,
    generation: generation,
    timeout: timeout,
    availabilityTimeout: availabilityTimeout,
    maximumSampleCount: maximumSampleCount,
    availability: availability,
  );
}

Future<void> _flushAsync() => Future<void>.delayed(Duration.zero);

final class _Mount {
  _Mount(this.scope, this.generation);

  String scope;
  int generation;
}

final class _FakePreferenceStore implements DesktopLocalAsrPreferenceStore {
  _FakePreferenceStore([this.snapshot]);

  DesktopLocalAsrPreferenceSnapshot? snapshot;
  bool failReads = false;
  bool failWrites = false;
  final writes = <DesktopLocalAsrPreferenceSnapshot>[];

  @override
  Future<DesktopLocalAsrPreferenceSnapshot?> read() async {
    if (failReads) throw StateError('read failed');
    return snapshot;
  }

  @override
  Future<void> write(DesktopLocalAsrPreferenceSnapshot snapshot) async {
    if (failWrites) throw StateError('write failed');
    writes.add(snapshot);
    this.snapshot = snapshot;
  }
}

final class _FakeRecognizerFactory implements DesktopLocalAsrRecognizerFactory {
  _FakeRecognizerFactory([List<_FakeRecognizer>? recognizers])
    : _recognizers = recognizers ?? <_FakeRecognizer>[];

  final List<_FakeRecognizer> _recognizers;
  final createdModelIds = <String>[];
  int createCount = 0;

  @override
  Future<DesktopLocalAsrRecognizer> create(
    DesktopLocalAsrModelPack modelPack,
  ) async {
    createCount++;
    createdModelIds.add(modelPack.id);
    if (_recognizers.isEmpty) throw StateError('no recognizer');
    return _recognizers.removeAt(0);
  }
}

final class _FakeModelAvailability implements DesktopLocalAsrModelAvailability {
  _FakeModelAvailability(this.available);

  bool available;
  bool fail = false;
  int checkCount = 0;
  Completer<bool>? pending;

  @override
  Future<bool> isAvailable(DesktopLocalAsrModelPack modelPack) async {
    checkCount++;
    if (fail) throw StateError('availability failed');
    final pendingResult = pending;
    if (pendingResult != null) return pendingResult.future;
    return available;
  }
}

final class _FakeRecognizer implements DesktopLocalAsrRecognizer {
  _FakeRecognizer._({
    required this.pendingResult,
    required this.immediateTranscript,
    required this.failRecognition,
  });

  factory _FakeRecognizer.immediate(String transcript) => _FakeRecognizer._(
    pendingResult: null,
    immediateTranscript: transcript,
    failRecognition: false,
  );

  factory _FakeRecognizer.pending() => _FakeRecognizer._(
    pendingResult: Completer<DesktopLocalAsrRecognition>(),
    immediateTranscript: null,
    failRecognition: false,
  );

  factory _FakeRecognizer.failing() => _FakeRecognizer._(
    pendingResult: null,
    immediateTranscript: null,
    failRecognition: true,
  );

  final Completer<DesktopLocalAsrRecognition>? pendingResult;
  final String? immediateTranscript;
  final bool failRecognition;
  final started = Completer<void>();
  int recognizeCount = 0;
  int closeCount = 0;
  int? sampleRateHz;
  String? locale;
  Float32List? receivedSamples;
  void Function()? onClose;
  int closeFailuresRemaining = 0;

  @override
  Future<DesktopLocalAsrRecognition> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  }) async {
    recognizeCount++;
    receivedSamples = samples;
    this.sampleRateHz = sampleRateHz;
    this.locale = locale;
    if (!started.isCompleted) started.complete();
    if (failRecognition) throw StateError('recognition failed');
    final pending = pendingResult;
    if (pending != null) return pending.future;
    return DesktopLocalAsrRecognition(transcript: immediateTranscript!);
  }

  void complete(String transcript) {
    pendingResult!.complete(DesktopLocalAsrRecognition(transcript: transcript));
  }

  @override
  Future<void> close() async {
    closeCount++;
    onClose?.call();
    if (closeFailuresRemaining > 0) {
      closeFailuresRemaining--;
      throw StateError('close failed');
    }
  }
}

const String _modelId = 'sensevoice-approved';
const String _modelId2 = 'sensevoice-approved-v2';
const String _scopeA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const String _scopeB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
