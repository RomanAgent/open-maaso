import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/voice_prosody_service.dart';

void main() {
  group('VoiceProsodyService admission', () {
    for (final platform in AppHostPlatform.values) {
      test(
        '${platform.name} follows desktop-only analyzer admission',
        () async {
          final analyzer = _FakeAnalyzer();
          var loads = 0;
          final service = _service(
            platform: platform,
            analyzer: analyzer,
            onLoad: () => loads++,
          );

          final metadata = await _process(service);
          final desktop = <AppHostPlatform>{
            AppHostPlatform.macos,
            AppHostPlatform.windows,
            AppHostPlatform.linux,
          }.contains(platform);

          expect(metadata, desktop ? isNotNull : isNull);
          expect(loads, desktop ? 1 : 0);
          expect(analyzer.calls, desktop ? 1 : 0);
          await service.retireAndDrain();
        },
      );
    }

    for (final mode in FeatureRolloutMode.values) {
      test('rollout ${mode.name} calls analyzer only in shadow', () async {
        final analyzer = _FakeAnalyzer();
        var loads = 0;
        final service = _service(
          analyzer: analyzer,
          rolloutMode: () => mode,
          onLoad: () => loads++,
        );

        final metadata = await _process(service);
        expect(
          metadata,
          mode == FeatureRolloutMode.shadow ? isNotNull : isNull,
        );
        expect(loads, mode == FeatureRolloutMode.shadow ? 1 : 0);
        expect(analyzer.calls, mode == FeatureRolloutMode.shadow ? 1 : 0);
        await service.retireAndDrain();
      });
    }

    test(
      'missing explicit opt-in performs zero analyzer load or call',
      () async {
        final analyzer = _FakeAnalyzer();
        var loads = 0;
        final service = _service(
          analyzer: analyzer,
          explicitOptIn: () => false,
          onLoad: () => loads++,
        );

        expect(await _process(service), isNull);
        expect(loads, 0);
        expect(analyzer.calls, 0);
        await service.retireAndDrain();
      },
    );
  });

  group('SpeechTurnMetadata fences', () {
    test('the recognized segment is claimed for exactly one turn', () async {
      final pending = Completer<VoiceProsodyAnalysis>();
      final service = _service(
        analyzer: _FakeAnalyzer(
          completers: <Completer<VoiceProsodyAnalysis>>[pending],
        ),
      );

      final processing = service.processActiveSegment(
        samples: Float32List.fromList(<double>[0.1, -0.2, 0.3]),
        sampleRate: 16000,
        utteranceId: 'claimed-u1',
        utteranceGeneration: 1,
      );
      await pumpEventQueue();
      service.markActiveUtteranceForNextTurn(
        utteranceId: 'claimed-u1',
        utteranceGeneration: 1,
      );
      pending.complete(_analysis());

      expect(await processing, isNotNull);
      expect(await service.consumeClaimedForNextTurn(), isNotNull);
      expect(await service.consumeClaimedForNextTurn(), isNull);
      await service.retireAndDrain();
    });

    test('an unclaimed segment cannot enrich a text turn', () async {
      final service = _service(analyzer: _FakeAnalyzer());

      expect(
        await service.processActiveSegment(
          samples: Float32List.fromList(<double>[0.1, -0.2, 0.3]),
          sampleRate: 16000,
          utteranceId: 'unclaimed-u1',
          utteranceGeneration: 1,
        ),
        isNotNull,
      );
      expect(await service.consumeClaimedForNextTurn(), isNull);
      await service.retireAndDrain();
    });

    test('claim wait is bounded and a late result cannot leak', () async {
      final pending = Completer<VoiceProsodyAnalysis>();
      final service = _service(
        analyzer: _FakeAnalyzer(
          completers: <Completer<VoiceProsodyAnalysis>>[pending],
        ),
      );

      final processing = service.processActiveSegment(
        samples: Float32List.fromList(<double>[0.1, -0.2, 0.3]),
        sampleRate: 16000,
        utteranceId: 'late-u1',
        utteranceGeneration: 1,
      );
      await pumpEventQueue();
      service.markActiveUtteranceForNextTurn(
        utteranceId: 'late-u1',
        utteranceGeneration: 1,
      );

      final stopwatch = Stopwatch()..start();
      expect(
        await service.consumeClaimedForNextTurn(
          waitBudget: const Duration(milliseconds: 10),
        ),
        isNull,
      );
      stopwatch.stop();
      expect(stopwatch.elapsed, lessThan(const Duration(milliseconds: 100)));

      pending.complete(_analysis());
      expect(await processing, isNull);
      expect(await service.consumeClaimedForNextTurn(), isNull);
      await service.retireAndDrain();
    });

    test('local trace details expose only coarse fixed buckets', () async {
      final service = _service(analyzer: _FakeAnalyzer());
      final metadata = await _process(service);

      final details = metadata!.privacyTraceDetails;
      expect(details, contains('backend=localDsp'));
      expect(details, isNot(contains('scope-a')));
      expect(details, isNot(contains('u1')));
      expect(details, isNot(contains(RegExp(r'\d'))));
      expect(details, isNot(contains('transcript')));
      await service.retireAndDrain();
    });

    test('metadata is consumed once and expires at the one-turn TTL', () async {
      var now = DateTime.utc(2026, 8, 30, 1);
      final service = _service(
        analyzer: _FakeAnalyzer(),
        clock: () => now,
        metadataTtl: const Duration(seconds: 30),
      );

      expect(await _process(service), isNotNull);
      expect(_consume(service), isNotNull);
      expect(_consume(service), isNull);

      expect(await _process(service, utteranceId: 'u2'), isNotNull);
      now = now.add(const Duration(seconds: 30));
      expect(_consume(service, utteranceId: 'u2'), isNull);
      expect(service.pendingMetadataCount, 0);
      await service.retireAndDrain();
    });

    test('account switch clears metadata and personal EMA', () async {
      final analyzer = _FakeAnalyzer(
        results: <VoiceProsodyAnalysis>[
          _analysis(energy: 0.2),
          _analysis(energy: 0.8),
        ],
      );
      final service = _service(analyzer: analyzer);

      expect(await _process(service), isNotNull);
      service.activateAccount(
        accountScopeDigest: 'scope-b',
        accountGeneration: 2,
      );
      expect(_consume(service), isNull);
      expect(
        await _process(
          service,
          accountScopeDigest: 'scope-a',
          accountGeneration: 1,
        ),
        isNull,
      );

      final accountB = await _process(
        service,
        accountScopeDigest: 'scope-b',
        accountGeneration: 2,
        utteranceId: 'u-b',
      );
      expect(accountB, isNotNull);
      expect(accountB!.energyDelta, 0, reason: 'account B gets a fresh EMA');
      await service.retireAndDrain();
    });

    test('stale utterance completion is discarded', () async {
      final pending = Completer<VoiceProsodyAnalysis>();
      final analyzer = _FakeAnalyzer(
        completers: <Completer<VoiceProsodyAnalysis>>[pending],
      );
      final service = _service(analyzer: analyzer);

      final processing = _process(service);
      await pumpEventQueue();
      service.invalidateUtterance(
        accountScopeDigest: 'scope-a',
        accountGeneration: 1,
        utteranceId: 'u1',
        nextGeneration: 2,
      );
      pending.complete(_analysis());

      expect(await processing, isNull);
      expect(_consume(service), isNull);
      await service.retireAndDrain();
    });

    test('stale completion cannot cross an account switch', () async {
      final pending = Completer<VoiceProsodyAnalysis>();
      final analyzer = _FakeAnalyzer(
        completers: <Completer<VoiceProsodyAnalysis>>[pending],
      );
      final service = _service(analyzer: analyzer);

      final processing = _process(service);
      await pumpEventQueue();
      service.activateAccount(
        accountScopeDigest: 'scope-b',
        accountGeneration: 2,
      );
      pending.complete(_analysis());

      expect(await processing, isNull);
      expect(service.pendingMetadataCount, 0);
      await service.retireAndDrain();
    });
  });

  group('bounded derived metadata and lifecycle', () {
    test('untrusted analyzer values are finite and clamped', () async {
      final analyzer = _FakeAnalyzer(
        results: <VoiceProsodyAnalysis>[
          _analysis(energy: 0, pitchHz: 1, speakingRate: 0, pauseRatio: 0),
          VoiceProsodyAnalysis(
            energy: 99,
            pitchHz: 99999,
            speakingRate: 99,
            pauseRatio: 99,
            audioEventConfidence: double.infinity,
          ),
        ],
      );
      final service = _service(analyzer: analyzer);

      await _process(service);
      final metadata = await _process(service, utteranceId: 'u2');
      expect(metadata, isNotNull);
      expect(metadata!.energyDelta, inInclusiveRange(-1, 1));
      expect(metadata.pitchDeltaSemitones, inInclusiveRange(-12, 12));
      expect(metadata.rateDelta, inInclusiveRange(-4, 4));
      expect(metadata.pauseDelta, inInclusiveRange(-1, 1));
      expect(metadata.audioEventConfidence, inInclusiveRange(0, 1));
      expect(
        metadata.analysisLatencyMicros,
        inInclusiveRange(0, VoiceProsodyService.maximumLatencyMicros),
      );
      for (final value in <double>[
        metadata.energyDelta,
        metadata.pitchDeltaSemitones,
        metadata.rateDelta,
        metadata.pauseDelta,
        metadata.audioEventConfidence,
      ]) {
        expect(value.isFinite, isTrue);
      }
      await service.retireAndDrain();
    });

    test(
      'metadata exposes no PCM, sample, transcript, or durable account field',
      () async {
        final samples = Float32List.fromList(<double>[0.1, -0.2, 0.3]);
        final analyzer = _FakeAnalyzer();
        final service = _service(analyzer: analyzer);

        final metadata = await _process(service, samples: samples);
        expect(metadata, isNotNull);
        samples.fillRange(0, samples.length, 0.99);
        final json = metadata!.toJson();
        final keys = json.keys.map((key) => key.toLowerCase()).join(' ');
        expect(keys, isNot(contains('pcm')));
        expect(keys, isNot(contains('sample')));
        expect(keys, isNot(contains('audio_bytes')));
        expect(keys, isNot(contains('transcript')));
        expect(keys, isNot(contains('accountscope')));
        expect(json.values.whereType<Float32List>(), isEmpty);
        await service.retireAndDrain();
      },
    );

    test(
      'analysis timeout drops metadata but retirement drains backend',
      () async {
        final pending = Completer<VoiceProsodyAnalysis>();
        final analyzer = _FakeAnalyzer(
          completers: <Completer<VoiceProsodyAnalysis>>[pending],
        );
        final service = _service(
          analyzer: analyzer,
          analysisTimeout: const Duration(milliseconds: 10),
        );

        expect(await _process(service), isNull);
        var retired = false;
        final retiring = service.retireAndDrain().then((_) => retired = true);
        await pumpEventQueue();
        expect(retired, isFalse);
        pending.complete(_analysis());
        await retiring;
        expect(analyzer.closeCalls, 1);
      },
    );

    test('synchronous analyzer failure is contained', () async {
      final analyzer = _ThrowingAnalyzer();
      final service = _service(analyzer: analyzer);

      expect(await _process(service), isNull);
      expect(service.pendingMetadataCount, 0);
      await service.retireAndDrain();
      expect(analyzer.closeCalls, 1);
    });

    test('analyzer factory failure is contained and retryable', () async {
      var loads = 0;
      final service = VoiceProsodyService(
        platformCapabilities: AppPlatformCapabilities.forPlatform(
          AppHostPlatform.macos,
        ),
        explicitOptIn: () => true,
        rolloutMode: () => FeatureRolloutMode.shadow,
        analyzerFactory: () {
          loads++;
          throw StateError('load_failed');
        },
        accountScopeDigest: 'scope-a',
        accountGeneration: 1,
      );

      expect(await _process(service), isNull);
      expect(await _process(service, utteranceId: 'u2'), isNull);
      expect(loads, 2);
      await service.retireAndDrain();
    });

    test('concurrent work is fenced and retire is idempotent', () async {
      final first = Completer<VoiceProsodyAnalysis>();
      final second = Completer<VoiceProsodyAnalysis>();
      final analyzer = _FakeAnalyzer(
        completers: <Completer<VoiceProsodyAnalysis>>[first, second],
      );
      final service = _service(analyzer: analyzer);

      final a = _process(service, utteranceId: 'u1');
      final b = _process(service, utteranceId: 'u2');
      await pumpEventQueue();
      final retireA = service.retireAndDrain();
      final retireB = service.retireAndDrain();
      expect(identical(retireA, retireB), isTrue);
      first.complete(_analysis());
      second.complete(_analysis());

      expect(await a, isNull);
      expect(await b, isNull);
      await retireA;
      expect(analyzer.closeCalls, 1);
      expect(await _process(service, utteranceId: 'u3'), isNull);
    });

    test('utterance tracking is bounded and evicts stale metadata', () async {
      final service = _service(
        analyzer: _FakeAnalyzer(),
        maximumTrackedUtterances: 2,
      );

      expect(await _process(service, utteranceId: 'u1'), isNotNull);
      expect(await _process(service, utteranceId: 'u2'), isNotNull);
      expect(await _process(service, utteranceId: 'u3'), isNotNull);

      expect(_consume(service, utteranceId: 'u1'), isNull);
      expect(_consume(service, utteranceId: 'u2'), isNotNull);
      expect(_consume(service, utteranceId: 'u3'), isNotNull);
      await service.retireAndDrain();
    });
  });
}

VoiceProsodyService _service({
  AppHostPlatform platform = AppHostPlatform.macos,
  VoiceProsodyAnalyzer? analyzer,
  VoiceProsodyOptInReader? explicitOptIn,
  VoiceProsodyRolloutReader? rolloutMode,
  void Function()? onLoad,
  VoiceProsodyClock? clock,
  Duration metadataTtl = const Duration(minutes: 2),
  Duration analysisTimeout = const Duration(milliseconds: 800),
  int maximumTrackedUtterances = 64,
}) {
  final resolvedAnalyzer = analyzer ?? _FakeAnalyzer();
  return VoiceProsodyService(
    platformCapabilities: AppPlatformCapabilities.forPlatform(platform),
    explicitOptIn: explicitOptIn ?? () => true,
    rolloutMode: rolloutMode ?? () => FeatureRolloutMode.shadow,
    analyzerFactory: () async {
      onLoad?.call();
      return resolvedAnalyzer;
    },
    accountScopeDigest: 'scope-a',
    accountGeneration: 1,
    clock: clock,
    metadataTtl: metadataTtl,
    analysisTimeout: analysisTimeout,
    maximumTrackedUtterances: maximumTrackedUtterances,
  );
}

Future<SpeechTurnMetadata?> _process(
  VoiceProsodyService service, {
  Float32List? samples,
  String accountScopeDigest = 'scope-a',
  int accountGeneration = 1,
  String utteranceId = 'u1',
  int utteranceGeneration = 1,
}) => service.processSegment(
  samples: samples ?? Float32List.fromList(<double>[0.1, -0.2, 0.3]),
  sampleRate: 16000,
  accountScopeDigest: accountScopeDigest,
  accountGeneration: accountGeneration,
  utteranceId: utteranceId,
  utteranceGeneration: utteranceGeneration,
);

SpeechTurnMetadata? _consume(
  VoiceProsodyService service, {
  String accountScopeDigest = 'scope-a',
  int accountGeneration = 1,
  String utteranceId = 'u1',
  int utteranceGeneration = 1,
}) => service.consume(
  accountScopeDigest: accountScopeDigest,
  accountGeneration: accountGeneration,
  utteranceId: utteranceId,
  utteranceGeneration: utteranceGeneration,
);

VoiceProsodyAnalysis _analysis({
  double energy = 0.4,
  double pitchHz = 180,
  double speakingRate = 3.2,
  double pauseRatio = 0.15,
  double audioEventConfidence = 0.7,
}) => VoiceProsodyAnalysis(
  energy: energy,
  pitchHz: pitchHz,
  speakingRate: speakingRate,
  pauseRatio: pauseRatio,
  audioEventConfidence: audioEventConfidence,
);

final class _FakeAnalyzer implements VoiceProsodyAnalyzer {
  _FakeAnalyzer({
    List<VoiceProsodyAnalysis>? results,
    List<Completer<VoiceProsodyAnalysis>>? completers,
  }) : _results = results ?? <VoiceProsodyAnalysis>[],
       _completers = completers ?? <Completer<VoiceProsodyAnalysis>>[];

  final List<VoiceProsodyAnalysis> _results;
  final List<Completer<VoiceProsodyAnalysis>> _completers;
  int calls = 0;
  int closeCalls = 0;

  @override
  VoiceProsodyBackend get backend => VoiceProsodyBackend.localDsp;

  @override
  Future<VoiceProsodyAnalysis> analyze(
    Float32List samples, {
    required int sampleRate,
  }) async {
    final index = calls++;
    if (index < _completers.length) return _completers[index].future;
    if (index < _results.length) return _results[index];
    return _analysis();
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}

final class _ThrowingAnalyzer implements VoiceProsodyAnalyzer {
  int calls = 0;
  int closeCalls = 0;

  @override
  VoiceProsodyBackend get backend => VoiceProsodyBackend.localDsp;

  @override
  Future<VoiceProsodyAnalysis> analyze(
    Float32List samples, {
    required int sampleRate,
  }) {
    calls++;
    throw StateError('analysis_failed');
  }

  @override
  Future<void> close() async {
    closeCalls++;
  }
}
