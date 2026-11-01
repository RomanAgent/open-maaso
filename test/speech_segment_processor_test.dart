import 'dart:io';
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/desktop_local_asr_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/services/speech_segment_processor.dart';
import 'package:maaso/src/core/services/voice_prosody_service.dart';

void main() {
  const processor = SpeechSegmentProcessor();

  test(
    'external segment preserves admission stop and recognition order',
    () async {
      final order = <String>[];
      final asr = _FakePlatformAsrService(
        supportsExternalAudioInput: true,
        starts: true,
        order: order,
      );
      final samples = Float32List.fromList(const <double>[0.1, -0.2, 0.3]);

      final result = await processor.process(
        platformAsr: asr,
        samples: samples,
        duration: const Duration(milliseconds: 120),
        locale: 'zh-CN',
        source: 'vad-segment',
        isCurrent: () => true,
        onExternalRecognitionAdmission: () => order.add('admit'),
        stopVad: () async => order.add('stop-vad'),
        stopMic: () async => order.add('stop-mic'),
      );

      expect(
        result.status,
        SpeechSegmentProcessingStatus.externalRecognitionStarted,
      );
      expect(result.diagnostic, isNull);
      expect(order, <String>['admit', 'stop-vad', 'stop-mic', 'recognize']);
      expect(asr.recognizeCalls, 1);
      expect(asr.samples, same(samples));
      expect(asr.locale, 'zh-CN');
      expect(result.utteranceId, startsWith('vad-utterance-'));
      expect(result.utteranceGeneration, 1);
    },
  );

  test(
    'unsupported external input requests the existing finalize fallback',
    () async {
      final order = <String>[];
      final asr = _FakePlatformAsrService(
        supportsExternalAudioInput: false,
        starts: true,
        order: order,
      );

      final result = await processor.process(
        platformAsr: asr,
        samples: Float32List.fromList(const <double>[0.1]),
        duration: const Duration(milliseconds: 10),
        locale: 'en-US',
        source: 'vad-segment',
        isCurrent: () => true,
        onExternalRecognitionAdmission: () => order.add('admit'),
        stopVad: () async => order.add('stop-vad'),
        stopMic: () async => order.add('stop-mic'),
      );

      expect(
        result.status,
        SpeechSegmentProcessingStatus.fallbackFinalizeRequested,
      );
      expect(order, isEmpty);
      expect(asr.recognizeCalls, 0);
    },
  );

  test(
    'stale external segment stops before touching mic or recognizer',
    () async {
      final order = <String>[];
      final stopVadEntered = Completer<void>();
      final releaseStopVad = Completer<void>();
      var current = true;
      final asr = _FakePlatformAsrService(
        supportsExternalAudioInput: true,
        starts: true,
        order: order,
      );

      final processing = processor.process(
        platformAsr: asr,
        samples: Float32List.fromList(const <double>[0.1]),
        duration: const Duration(milliseconds: 10),
        locale: 'en-US',
        source: 'vad-segment',
        isCurrent: () => current,
        onExternalRecognitionAdmission: () => order.add('admit'),
        stopVad: () async {
          order.add('stop-vad');
          stopVadEntered.complete();
          await releaseStopVad.future;
        },
        stopMic: () async => order.add('stop-mic'),
      );

      await stopVadEntered.future;
      current = false;
      releaseStopVad.complete();
      final result = await processing;

      expect(result.status, SpeechSegmentProcessingStatus.rejected);
      expect(result.diagnostic, 'stale_voice_segment');
      expect(order, <String>['admit', 'stop-vad']);
      expect(asr.recognizeCalls, 0);
    },
  );

  test('failed sample recognition returns the current diagnostic', () async {
    final order = <String>[];
    final asr = _FakePlatformAsrService(
      supportsExternalAudioInput: true,
      starts: false,
      order: order,
    );

    final result = await processor.process(
      platformAsr: asr,
      samples: Float32List.fromList(const <double>[0.1]),
      duration: const Duration(milliseconds: 10),
      locale: 'en-US',
      source: 'vad-segment',
      isCurrent: () => true,
      onExternalRecognitionAdmission: () => order.add('admit'),
      stopVad: () async => order.add('stop-vad'),
      stopMic: () async => order.add('stop-mic'),
    );

    expect(result.status, SpeechSegmentProcessingStatus.rejected);
    expect(result.diagnostic, 'sample recognition rejected');
    expect(order, <String>['admit', 'stop-vad', 'stop-mic', 'recognize']);
  });

  test(
    'explicit desktop local ASR consumes only the bounded VAD segment',
    () async {
      final order = <String>[];
      final localRecognizer = _FakeDesktopRecognizer(
        order: order,
        transcript: '  local transcript  ',
      );
      final localAsr = await _enabledDesktopLocalAsr(localRecognizer);
      addTearDown(localAsr.sealAndDrain);
      final platformAsr = _FakePlatformAsrService(
        supportsExternalAudioInput: false,
        starts: true,
        order: order,
      );
      final samples = Float32List.fromList(const <double>[0.2, -0.1]);

      final result = await processor.process(
        platformAsr: platformAsr,
        desktopLocalAsr: localAsr,
        samples: samples,
        duration: const Duration(milliseconds: 80),
        locale: 'en-US',
        source: 'vad-segment',
        isCurrent: () => true,
        onExternalRecognitionAdmission: () => order.add('admit'),
        stopVad: () async => order.add('stop-vad'),
        stopMic: () async => order.add('stop-mic'),
      );

      expect(
        result.status,
        SpeechSegmentProcessingStatus.localRecognitionCompleted,
      );
      expect(result.transcript, 'local transcript');
      expect(order, <String>[
        'admit',
        'stop-vad',
        'stop-mic',
        'local-recognize',
      ]);
      expect(platformAsr.recognizeCalls, 0);
      expect(localRecognizer.receivedSamples, isNot(same(samples)));
      expect(localRecognizer.sampleRateHz, 16000);
    },
  );

  test('stale local segment never starts local decode', () async {
    final order = <String>[];
    final stopVadEntered = Completer<void>();
    final releaseStopVad = Completer<void>();
    var current = true;
    final localRecognizer = _FakeDesktopRecognizer(
      order: order,
      transcript: 'must not run',
    );
    final localAsr = await _enabledDesktopLocalAsr(localRecognizer);
    addTearDown(localAsr.sealAndDrain);

    final processing = processor.process(
      platformAsr: _FakePlatformAsrService(
        supportsExternalAudioInput: false,
        starts: true,
        order: order,
      ),
      desktopLocalAsr: localAsr,
      samples: Float32List.fromList(const <double>[0.1]),
      duration: const Duration(milliseconds: 10),
      locale: 'en-US',
      source: 'vad-segment',
      isCurrent: () => current,
      onExternalRecognitionAdmission: () => order.add('admit'),
      stopVad: () async {
        order.add('stop-vad');
        stopVadEntered.complete();
        await releaseStopVad.future;
      },
      stopMic: () async => order.add('stop-mic'),
    );

    await stopVadEntered.future;
    current = false;
    releaseStopVad.complete();
    final result = await processing;

    expect(result.status, SpeechSegmentProcessingStatus.rejected);
    expect(result.diagnostic, 'stale_voice_segment');
    expect(order, <String>['admit', 'stop-vad']);
    expect(localRecognizer.receivedSamples, isNull);
  });

  test('an opted-in local failure never falls back to platform ASR', () async {
    final order = <String>[];
    final localRecognizer = _FakeDesktopRecognizer(
      order: order,
      throwsOnRecognize: true,
    );
    final localAsr = await _enabledDesktopLocalAsr(localRecognizer);
    addTearDown(localAsr.sealAndDrain);
    final platformAsr = _FakePlatformAsrService(
      supportsExternalAudioInput: true,
      starts: true,
      order: order,
    );

    final result = await processor.process(
      platformAsr: platformAsr,
      desktopLocalAsr: localAsr,
      samples: Float32List.fromList(const <double>[0.2]),
      duration: const Duration(milliseconds: 40),
      locale: 'en-US',
      source: 'vad-segment',
      isCurrent: () => true,
      onExternalRecognitionAdmission: () => order.add('admit'),
      stopVad: () async => order.add('stop-vad'),
      stopMic: () async => order.add('stop-mic'),
    );

    expect(result.status, SpeechSegmentProcessingStatus.rejected);
    expect(result.diagnostic, DesktopLocalAsrFailure.recognizerError.name);
    expect(platformAsr.recognizeCalls, 0);
    expect(order, <String>['admit', 'stop-vad', 'stop-mic', 'local-recognize']);
  });

  test(
    'a pinned local session fails closed when its preference changes',
    () async {
      final order = <String>[];
      final localAsr = await _enabledDesktopLocalAsr(
        _FakeDesktopRecognizer(order: order, transcript: 'must not run'),
      );
      addTearDown(localAsr.sealAndDrain);
      await localAsr.setEnabled(false);
      final platformAsr = _FakePlatformAsrService(
        supportsExternalAudioInput: true,
        starts: true,
        order: order,
      );

      final result = await processor.process(
        platformAsr: platformAsr,
        desktopLocalAsr: localAsr,
        samples: Float32List.fromList(const <double>[0.2]),
        duration: const Duration(milliseconds: 40),
        locale: 'en-US',
        source: 'vad-segment',
        isCurrent: () => true,
        onExternalRecognitionAdmission: () => order.add('admit'),
        stopVad: () async => order.add('stop-vad'),
        stopMic: () async => order.add('stop-mic'),
      );

      expect(result.status, SpeechSegmentProcessingStatus.rejected);
      expect(result.diagnostic, DesktopLocalAsrFailure.disabled.name);
      expect(platformAsr.recognizeCalls, 0);
      expect(order, <String>['admit', 'stop-vad', 'stop-mic']);
    },
  );

  test('prosody shadow forks without delaying ASR recognition', () async {
    final order = <String>[];
    final asr = _FakePlatformAsrService(
      supportsExternalAudioInput: true,
      starts: true,
      order: order,
    );
    final analyzer = _HeldAnalyzer();
    final prosody = _prosodyService(analyzer);

    final result = await processor.process(
      platformAsr: asr,
      voiceProsody: prosody,
      samples: Float32List.fromList(const <double>[0.1, -0.2, 0.3]),
      duration: const Duration(milliseconds: 120),
      locale: 'en-US',
      source: 'vad-segment',
      isCurrent: () => true,
      onExternalRecognitionAdmission: () => order.add('admit'),
      stopVad: () async => order.add('stop-vad'),
      stopMic: () async => order.add('stop-mic'),
    );

    expect(
      result.status,
      SpeechSegmentProcessingStatus.externalRecognitionStarted,
    );
    expect(order, <String>['admit', 'stop-vad', 'stop-mic', 'recognize']);
    await analyzer.started.future;
    expect(prosody.pendingMetadataCount, 0);

    analyzer.complete();
    await pumpEventQueue();
    expect(prosody.pendingMetadataCount, 1);
    expect(
      prosody.consume(
        accountScopeDigest: 'scope-a',
        accountGeneration: 3,
        utteranceId: result.utteranceId!,
        utteranceGeneration: result.utteranceGeneration!,
      ),
      isNotNull,
    );
    await prosody.retireAndDrain();
  });

  test('failed ASR invalidates late prosody metadata', () async {
    final analyzer = _HeldAnalyzer();
    final prosody = _prosodyService(analyzer);
    final result = await processor.process(
      platformAsr: _FakePlatformAsrService(
        supportsExternalAudioInput: true,
        starts: false,
        order: <String>[],
      ),
      voiceProsody: prosody,
      samples: Float32List.fromList(const <double>[0.1, -0.2]),
      duration: const Duration(milliseconds: 100),
      locale: 'en-US',
      source: 'vad-segment',
      isCurrent: () => true,
      onExternalRecognitionAdmission: () {},
      stopVad: () async {},
      stopMic: () async {},
    );

    await analyzer.started.future;
    analyzer.complete();
    await pumpEventQueue();
    expect(result.status, SpeechSegmentProcessingStatus.rejected);
    expect(prosody.pendingMetadataCount, 0);
    expect(
      prosody.consume(
        accountScopeDigest: 'scope-a',
        accountGeneration: 3,
        utteranceId: result.utteranceId!,
        utteranceGeneration: result.utteranceGeneration!,
      ),
      isNull,
    );
    await prosody.retireAndDrain();
  });

  test('processor owns no capture or PCM persistence dependency', () {
    final source = File(
      'lib/src/core/services/speech_segment_processor.dart',
    ).readAsStringSync();

    expect(source, isNot(contains('MicCaptureService')));
    expect(source, isNot(contains('SharedPreferences')));
    expect(source, isNot(contains('Database')));
    expect(source, isNot(contains('File(')));
    expect(source, isNot(contains('audioStream')));
  });
}

VoiceProsodyService _prosodyService(VoiceProsodyAnalyzer analyzer) =>
    VoiceProsodyService(
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.macos,
      ),
      explicitOptIn: () => true,
      rolloutMode: () => FeatureRolloutMode.shadow,
      analyzerFactory: () async => analyzer,
      accountScopeDigest: 'scope-a',
      accountGeneration: 3,
    );

final class _HeldAnalyzer implements VoiceProsodyAnalyzer {
  final Completer<void> started = Completer<void>();
  final Completer<VoiceProsodyAnalysis> _result =
      Completer<VoiceProsodyAnalysis>();

  @override
  VoiceProsodyBackend get backend => VoiceProsodyBackend.localDsp;

  @override
  Future<VoiceProsodyAnalysis> analyze(
    Float32List samples, {
    required int sampleRate,
  }) {
    if (!started.isCompleted) started.complete();
    return _result.future;
  }

  void complete() {
    _result.complete(
      const VoiceProsodyAnalysis(
        energy: 0.5,
        pitchHz: 180,
        speakingRate: 3,
        pauseRatio: 0.2,
        audioEventConfidence: 0.9,
      ),
    );
  }

  @override
  Future<void> close() async {}
}

final class _FakePlatformAsrService extends PlatformAsrService {
  _FakePlatformAsrService({
    required bool supportsExternalAudioInput,
    required this.starts,
    required this.order,
  }) : super(supportsExternalAudioInputOverride: supportsExternalAudioInput);

  final bool starts;
  final List<String> order;
  int recognizeCalls = 0;
  Float32List? samples;
  String? locale;

  @override
  Future<bool> recognizeSamples({
    required Float32List samples,
    String? locale,
    int chunkBytes = 3200,
  }) async {
    order.add('recognize');
    recognizeCalls += 1;
    this.samples = samples;
    this.locale = locale;
    if (!starts) error.value = 'sample recognition rejected';
    return starts;
  }
}

Future<DesktopLocalAsrService> _enabledDesktopLocalAsr(
  _FakeDesktopRecognizer recognizer,
) => DesktopLocalAsrService(
  preferenceStore: _FakeDesktopPreferenceStore(),
  recognizerFactory: _FakeDesktopRecognizerFactory(recognizer),
  modelAvailability: const _AvailableDesktopModel(),
  modelPacks: <DesktopLocalAsrModelPack>[
    DesktopLocalAsrModelPack(id: 'test-local-asr'),
  ],
  platformCapabilities: const AppPlatformCapabilities.forPlatform(
    AppHostPlatform.macos,
  ),
  accountScopeDigest:
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  generation: 1,
  isCurrentMount: ({required accountScopeDigest, required generation}) =>
      accountScopeDigest ==
          'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' &&
      generation == 1,
).init();

final class _FakeDesktopPreferenceStore
    implements DesktopLocalAsrPreferenceStore {
  @override
  Future<DesktopLocalAsrPreferenceSnapshot?> read() async =>
      DesktopLocalAsrPreferenceSnapshot(
        accountScopeDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        revision: 1,
        enabled: true,
        selectedModelId: 'test-local-asr',
      );

  @override
  Future<void> write(DesktopLocalAsrPreferenceSnapshot snapshot) async {}
}

final class _AvailableDesktopModel implements DesktopLocalAsrModelAvailability {
  const _AvailableDesktopModel();

  @override
  Future<bool> isAvailable(DesktopLocalAsrModelPack modelPack) async => true;
}

final class _FakeDesktopRecognizerFactory
    implements DesktopLocalAsrRecognizerFactory {
  const _FakeDesktopRecognizerFactory(this.recognizer);

  final _FakeDesktopRecognizer recognizer;

  @override
  Future<DesktopLocalAsrRecognizer> create(
    DesktopLocalAsrModelPack modelPack,
  ) async => recognizer;
}

final class _FakeDesktopRecognizer implements DesktopLocalAsrRecognizer {
  _FakeDesktopRecognizer({
    required this.order,
    this.transcript = '',
    this.throwsOnRecognize = false,
  });

  final List<String> order;
  final String transcript;
  final bool throwsOnRecognize;
  Float32List? receivedSamples;
  int? sampleRateHz;

  @override
  Future<DesktopLocalAsrRecognition> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  }) async {
    order.add('local-recognize');
    receivedSamples = samples;
    this.sampleRateHz = sampleRateHz;
    if (throwsOnRecognize) throw StateError('local decode failed');
    return DesktopLocalAsrRecognition(transcript: transcript);
  }

  @override
  Future<void> close() async {}
}
