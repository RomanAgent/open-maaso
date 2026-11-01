import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';

typedef VoiceProsodyAnalyzerFactory = Future<VoiceProsodyAnalyzer> Function();
typedef VoiceProsodyOptInReader = bool Function();
typedef VoiceProsodyRolloutReader = FeatureRolloutMode Function();
typedef VoiceProsodyClock = DateTime Function();

/// Finite backend identities exposed to diagnostics and future benchmarks.
///
/// `senseVoice` is only a contract seam. This service does not download,
/// construct, or register a SenseVoice model.
enum VoiceProsodyBackend { localDsp, senseVoice }

/// A local analyzer receives one VAD-ended segment and returns derived values.
///
/// Implementations must not retain [samples]. The service itself never copies,
/// persists, or caches the PCM buffer.
abstract interface class VoiceProsodyAnalyzer {
  VoiceProsodyBackend get backend;

  Future<VoiceProsodyAnalysis> analyze(
    Float32List samples, {
    required int sampleRate,
  });

  Future<void> close();
}

/// Analyzer output before personal-baseline normalization.
///
/// Values are treated as untrusted. [VoiceProsodyService] clamps every field
/// before using it or exposing turn metadata.
final class VoiceProsodyAnalysis {
  const VoiceProsodyAnalysis({
    required this.energy,
    required this.pitchHz,
    required this.speakingRate,
    required this.pauseRatio,
    required this.audioEventConfidence,
  });

  final double energy;
  final double pitchHz;
  final double speakingRate;
  final double pauseRatio;
  final double audioEventConfidence;
}

/// Bounded, one-turn-only voice context.
///
/// It intentionally contains no raw audio, transcript, medical label,
/// personality label, or durable account identifier.
final class SpeechTurnMetadata {
  const SpeechTurnMetadata._({
    required this.utteranceId,
    required this.utteranceGeneration,
    required this.accountGeneration,
    required this.backend,
    required this.energyDelta,
    required this.pitchDeltaSemitones,
    required this.rateDelta,
    required this.pauseDelta,
    required this.audioEventConfidence,
    required this.analysisLatencyMicros,
    required this.createdAt,
    required this.expiresAt,
  });

  final String utteranceId;
  final int utteranceGeneration;
  final int accountGeneration;
  final VoiceProsodyBackend backend;
  final double energyDelta;
  final double pitchDeltaSemitones;
  final double rateDelta;
  final double pauseDelta;
  final double audioEventConfidence;
  final int analysisLatencyMicros;
  final DateTime createdAt;
  final DateTime expiresAt;

  bool isFreshAt(DateTime value) => expiresAt.isAfter(value.toUtc());

  Map<String, Object> toJson() => <String, Object>{
    'utteranceId': utteranceId,
    'utteranceGeneration': utteranceGeneration,
    'accountGeneration': accountGeneration,
    'backend': backend.name,
    'energyDelta': energyDelta,
    'pitchDeltaSemitones': pitchDeltaSemitones,
    'rateDelta': rateDelta,
    'pauseDelta': pauseDelta,
    'audioEventConfidence': audioEventConfidence,
    'analysisLatencyMicros': analysisLatencyMicros,
    'createdAt': createdAt.toUtc().toIso8601String(),
    'expiresAt': expiresAt.toUtc().toIso8601String(),
  };

  /// Coarse, identity-free diagnostics for the local turn trace only.
  String get privacyTraceDetails =>
      'backend=${backend.name} '
      'energy=${_signedBucket(energyDelta, 0.12)} '
      'pitch=${_signedBucket(pitchDeltaSemitones, 1.5)} '
      'rate=${_signedBucket(rateDelta, 0.4)} '
      'pause=${_signedBucket(pauseDelta, 0.12)} '
      'confidence=${audioEventConfidence < 0.35
          ? "low"
          : audioEventConfidence < 0.7
          ? "medium"
          : "high"}';

  static String _signedBucket(double value, double neutralBand) =>
      value < -neutralBand
      ? 'lower'
      : value > neutralBand
      ? 'higher'
      : 'near';
}

final class _VoiceProsodyTurnClaim {
  const _VoiceProsodyTurnClaim(this.utteranceId, this.utteranceGeneration);

  final String utteranceId;
  final int utteranceGeneration;
}

enum _VoiceProsodyLifecycle { active, retiring, retired }

/// Account-fenced, opt-in shadow computation for one VAD speech segment.
///
/// Admission is deliberately narrower than the general rollout contract:
/// only desktop speech-model support + explicit user opt-in + `shadow` may
/// load or call an analyzer. `enforce` remains fail-closed until a separate
/// benchmark and product gate approves it.
final class VoiceProsodyService extends AppService {
  VoiceProsodyService({
    required AppPlatformCapabilities platformCapabilities,
    required VoiceProsodyOptInReader explicitOptIn,
    required VoiceProsodyRolloutReader rolloutMode,
    required VoiceProsodyAnalyzerFactory analyzerFactory,
    required String accountScopeDigest,
    required int accountGeneration,
    VoiceProsodyClock? clock,
    Duration metadataTtl = const Duration(minutes: 2),
    Duration analysisTimeout = const Duration(milliseconds: 800),
    double emaAlpha = 0.2,
    int maximumSegmentSamples = 480000,
    int maximumTrackedUtterances = 64,
  }) : _platformCapabilities = platformCapabilities,
       _explicitOptIn = explicitOptIn,
       _rolloutMode = rolloutMode,
       _analyzerFactory = analyzerFactory,
       _clock = clock ?? DateTime.now,
       _metadataTtl = _validatedTtl(metadataTtl),
       _analysisTimeout = _validatedTimeout(analysisTimeout),
       _emaAlpha = _validatedAlpha(emaAlpha),
       _maximumSegmentSamples = _validatedMaximumSamples(maximumSegmentSamples),
       _maximumTrackedUtterances = _validatedTrackedUtterances(
         maximumTrackedUtterances,
       ),
       _accountScopeDigest = _validatedScopeDigest(accountScopeDigest),
       _accountGeneration = _validatedGeneration(accountGeneration);

  static const int maximumLatencyMicros = 5000000;

  final AppPlatformCapabilities _platformCapabilities;
  final VoiceProsodyOptInReader _explicitOptIn;
  final VoiceProsodyRolloutReader _rolloutMode;
  final VoiceProsodyAnalyzerFactory _analyzerFactory;
  final VoiceProsodyClock _clock;
  final Duration _metadataTtl;
  final Duration _analysisTimeout;
  final double _emaAlpha;
  final int _maximumSegmentSamples;
  final int _maximumTrackedUtterances;

  final Map<String, SpeechTurnMetadata> _pending =
      <String, SpeechTurnMetadata>{};
  final Map<String, int> _utteranceGenerations = <String, int>{};
  final Map<String, Future<SpeechTurnMetadata?>> _activeSegmentOperations =
      <String, Future<SpeechTurnMetadata?>>{};
  final Set<Future<void>> _inFlight = <Future<void>>{};
  final Set<Future<void>> _backendOperations = <Future<void>>{};

  String _accountScopeDigest;
  int _accountGeneration;
  int _lifecycleGeneration = 1;
  _VoiceProsodyLifecycle _lifecycle = _VoiceProsodyLifecycle.active;
  _ProsodyBaseline? _baseline;
  Future<VoiceProsodyAnalyzer>? _analyzerFuture;
  VoiceProsodyAnalyzer? _analyzer;
  Future<void>? _retireFuture;
  _VoiceProsodyTurnClaim? _nextTurnClaim;

  int get pendingMetadataCount => _pending.length;

  /// Convenience entry point for the currently mounted account.
  ///
  /// Account identity remains private to this account-owned service, so UI
  /// producers cannot accidentally label a segment with another account.
  Future<SpeechTurnMetadata?> processActiveSegment({
    required Float32List samples,
    required int sampleRate,
    required String utteranceId,
    required int utteranceGeneration,
  }) {
    final operation = processSegment(
      samples: samples,
      sampleRate: sampleRate,
      accountScopeDigest: _accountScopeDigest,
      accountGeneration: _accountGeneration,
      utteranceId: utteranceId,
      utteranceGeneration: utteranceGeneration,
    );
    _activeSegmentOperations[utteranceId] = operation;
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() {
          if (identical(_activeSegmentOperations[utteranceId], operation)) {
            _activeSegmentOperations.remove(utteranceId);
          }
        });
    unawaited(tracked);
    return operation;
  }

  /// Marks the exact recognized speech segment that may enrich the next turn.
  /// Merely analyzing a segment never makes it eligible for prompt use.
  void markActiveUtteranceForNextTurn({
    required String utteranceId,
    required int utteranceGeneration,
  }) {
    final id = _validatedUtteranceId(utteranceId);
    if (id == null ||
        !_shadowAdmissionAllowed ||
        _utteranceGenerations[id] != utteranceGeneration) {
      return;
    }
    final previous = _nextTurnClaim;
    if (previous != null &&
        (previous.utteranceId != id ||
            previous.utteranceGeneration != utteranceGeneration)) {
      invalidateActiveUtterance(
        utteranceId: previous.utteranceId,
        nextGeneration: previous.utteranceGeneration + 1,
      );
    }
    _nextTurnClaim = _VoiceProsodyTurnClaim(id, utteranceGeneration);
  }

  /// Claims at most one voice hint for the next user turn.
  ///
  /// The bounded wait prevents shadow analysis from adding more than the
  /// stated ASR submission latency budget. A timeout invalidates the exact
  /// segment so its late completion cannot leak into a later text turn.
  Future<SpeechTurnMetadata?> consumeClaimedForNextTurn({
    Duration waitBudget = const Duration(milliseconds: 20),
  }) async {
    if (waitBudget < Duration.zero ||
        waitBudget > const Duration(milliseconds: 30)) {
      throw ArgumentError.value(waitBudget, 'waitBudget', 'is invalid');
    }
    final claim = _nextTurnClaim;
    _nextTurnClaim = null;
    if (claim == null || !_shadowAdmissionAllowed) return null;
    final operation = _activeSegmentOperations[claim.utteranceId];
    if (operation != null) {
      try {
        if (waitBudget == Duration.zero) {
          return consume(
            accountScopeDigest: _accountScopeDigest,
            accountGeneration: _accountGeneration,
            utteranceId: claim.utteranceId,
            utteranceGeneration: claim.utteranceGeneration,
          );
        }
        await operation.timeout(waitBudget);
      } on Object {
        invalidateActiveUtterance(
          utteranceId: claim.utteranceId,
          nextGeneration: claim.utteranceGeneration + 1,
        );
        return null;
      }
    }
    return consume(
      accountScopeDigest: _accountScopeDigest,
      accountGeneration: _accountGeneration,
      utteranceId: claim.utteranceId,
      utteranceGeneration: claim.utteranceGeneration,
    );
  }

  /// Invalidates a segment owned by the currently mounted account.
  void invalidateActiveUtterance({
    required String utteranceId,
    required int nextGeneration,
  }) {
    final claim = _nextTurnClaim;
    if (claim?.utteranceId == utteranceId &&
        nextGeneration > claim!.utteranceGeneration) {
      _nextTurnClaim = null;
    }
    invalidateUtterance(
      accountScopeDigest: _accountScopeDigest,
      accountGeneration: _accountGeneration,
      utteranceId: utteranceId,
      nextGeneration: nextGeneration,
    );
  }

  /// Atomically switches the in-memory account fence.
  ///
  /// Existing metadata and EMA state are discarded before the new account is
  /// published. Any old analyzer completion observes a stale lifecycle token
  /// and cannot write into the new account.
  void activateAccount({
    required String accountScopeDigest,
    required int accountGeneration,
  }) {
    if (_lifecycle != _VoiceProsodyLifecycle.active || isClosed) {
      throw StateError('voice_prosody_retired');
    }
    final scope = _validatedScopeDigest(accountScopeDigest);
    final generation = _validatedGeneration(accountGeneration);
    if (scope == _accountScopeDigest && generation == _accountGeneration) {
      return;
    }
    if (generation <= _accountGeneration) {
      throw StateError('voice_prosody_account_generation_not_newer');
    }
    _lifecycleGeneration++;
    _accountScopeDigest = scope;
    _accountGeneration = generation;
    _clearAccountState();
  }

  /// Runs shadow analysis and stores one consumable metadata value.
  ///
  /// Returning null is the normal fail-closed outcome for unsupported
  /// platforms, missing opt-in, non-shadow rollout, stale fences, invalid
  /// input, timeouts, analyzer failures, and retirement races.
  Future<SpeechTurnMetadata?> processSegment({
    required Float32List samples,
    required int sampleRate,
    required String accountScopeDigest,
    required int accountGeneration,
    required String utteranceId,
    required int utteranceGeneration,
  }) {
    late final Future<SpeechTurnMetadata?> operation;
    operation = _processSegment(
      samples: samples,
      sampleRate: sampleRate,
      accountScopeDigest: accountScopeDigest,
      accountGeneration: accountGeneration,
      utteranceId: utteranceId,
      utteranceGeneration: utteranceGeneration,
    );
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _inFlight.remove(tracked));
    _inFlight.add(tracked);
    return operation;
  }

  Future<SpeechTurnMetadata?> _processSegment({
    required Float32List samples,
    required int sampleRate,
    required String accountScopeDigest,
    required int accountGeneration,
    required String utteranceId,
    required int utteranceGeneration,
  }) async {
    final normalizedUtteranceId = _validatedUtteranceId(utteranceId);
    if (normalizedUtteranceId == null ||
        utteranceGeneration < 1 ||
        sampleRate < 8000 ||
        sampleRate > 192000 ||
        samples.isEmpty ||
        samples.length > _maximumSegmentSamples ||
        !_matchesAccount(accountScopeDigest, accountGeneration) ||
        !_shadowAdmissionAllowed) {
      return null;
    }

    final previousGeneration =
        _utteranceGenerations[normalizedUtteranceId] ?? 0;
    if (utteranceGeneration < previousGeneration) return null;
    if (!_utteranceGenerations.containsKey(normalizedUtteranceId) &&
        _utteranceGenerations.length >= _maximumTrackedUtterances) {
      final evictedId = _utteranceGenerations.keys.first;
      _utteranceGenerations.remove(evictedId);
      _pending.remove(evictedId);
    }
    _utteranceGenerations[normalizedUtteranceId] = utteranceGeneration;
    _pending.remove(normalizedUtteranceId);
    final lifecycleGeneration = _lifecycleGeneration;

    late final VoiceProsodyAnalyzer analyzer;
    try {
      analyzer = await _loadAnalyzer();
    } on Object {
      return null;
    }
    if (!_isCurrent(
          lifecycleGeneration: lifecycleGeneration,
          accountScopeDigest: accountScopeDigest,
          accountGeneration: accountGeneration,
          utteranceId: normalizedUtteranceId,
          utteranceGeneration: utteranceGeneration,
        ) ||
        !_shadowAdmissionAllowed) {
      return null;
    }

    final stopwatch = Stopwatch()..start();
    final rawAnalysis = Future<VoiceProsodyAnalysis>.sync(
      () => analyzer.analyze(samples, sampleRate: sampleRate),
    );
    final backendCompletion = rawAnalysis.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    late final Future<void> trackedBackend;
    trackedBackend = backendCompletion.whenComplete(
      () => _backendOperations.remove(trackedBackend),
    );
    _backendOperations.add(trackedBackend);

    late final VoiceProsodyAnalysis analysis;
    try {
      analysis = await rawAnalysis.timeout(_analysisTimeout);
    } on Object {
      return null;
    } finally {
      stopwatch.stop();
    }
    if (!_isCurrent(
          lifecycleGeneration: lifecycleGeneration,
          accountScopeDigest: accountScopeDigest,
          accountGeneration: accountGeneration,
          utteranceId: normalizedUtteranceId,
          utteranceGeneration: utteranceGeneration,
        ) ||
        !_shadowAdmissionAllowed) {
      return null;
    }

    final bounded = _BoundedProsody.from(analysis);
    final baseline = _baseline ?? _ProsodyBaseline.from(bounded);
    final now = _clock().toUtc();
    final metadata = SpeechTurnMetadata._(
      utteranceId: normalizedUtteranceId,
      utteranceGeneration: utteranceGeneration,
      accountGeneration: accountGeneration,
      backend: analyzer.backend,
      energyDelta: _clamp(bounded.energy - baseline.energy, -1, 1),
      pitchDeltaSemitones: _pitchDelta(bounded.pitchHz, baseline.pitchHz),
      rateDelta: _clamp(bounded.speakingRate - baseline.speakingRate, -4, 4),
      pauseDelta: _clamp(bounded.pauseRatio - baseline.pauseRatio, -1, 1),
      audioEventConfidence: bounded.audioEventConfidence,
      analysisLatencyMicros: stopwatch.elapsedMicroseconds.clamp(
        0,
        maximumLatencyMicros,
      ),
      createdAt: now,
      expiresAt: now.add(_metadataTtl),
    );
    _baseline = baseline.updated(bounded, _emaAlpha);
    _pending[normalizedUtteranceId] = metadata;
    return metadata;
  }

  /// Consumes metadata exactly once when every account/utterance fence matches.
  SpeechTurnMetadata? consume({
    required String accountScopeDigest,
    required int accountGeneration,
    required String utteranceId,
    required int utteranceGeneration,
  }) {
    final id = _validatedUtteranceId(utteranceId);
    if (id == null ||
        !_matchesAccount(accountScopeDigest, accountGeneration) ||
        _utteranceGenerations[id] != utteranceGeneration) {
      return null;
    }
    final metadata = _pending.remove(id);
    if (metadata == null || !metadata.isFreshAt(_clock())) return null;
    return metadata;
  }

  /// Invalidates an in-flight or pending utterance without touching another
  /// utterance's metadata.
  void invalidateUtterance({
    required String accountScopeDigest,
    required int accountGeneration,
    required String utteranceId,
    required int nextGeneration,
  }) {
    final id = _validatedUtteranceId(utteranceId);
    if (id == null ||
        nextGeneration < 1 ||
        !_matchesAccount(accountScopeDigest, accountGeneration)) {
      return;
    }
    final current = _utteranceGenerations[id] ?? 0;
    if (nextGeneration <= current) return;
    _utteranceGenerations[id] = nextGeneration;
    _pending.remove(id);
  }

  void purgeExpired() {
    final now = _clock();
    _pending.removeWhere((_, metadata) => !metadata.isFreshAt(now));
  }

  /// Fences new work, drains all analyzer calls, drops account state, and
  /// closes the lazily loaded backend exactly once.
  Future<void> retireAndDrain() {
    final existing = _retireFuture;
    if (existing != null) return existing;
    if (_lifecycle == _VoiceProsodyLifecycle.retired) {
      return Future<void>.value();
    }
    _lifecycle = _VoiceProsodyLifecycle.retiring;
    _lifecycleGeneration++;
    _clearAccountState();
    late final Future<void> retiring;
    retiring = _retireOnce().whenComplete(() {
      _lifecycle = _VoiceProsodyLifecycle.retired;
    });
    _retireFuture = retiring;
    return retiring;
  }

  Future<void> _retireOnce() async {
    while (_inFlight.isNotEmpty) {
      await Future.wait<void>(_inFlight.toList(growable: false));
    }
    while (_backendOperations.isNotEmpty) {
      await Future.wait<void>(_backendOperations.toList(growable: false));
    }
    final analyzer = _analyzer;
    _analyzer = null;
    _analyzerFuture = null;
    await analyzer?.close();
  }

  bool get _shadowAdmissionAllowed =>
      _lifecycle == _VoiceProsodyLifecycle.active &&
      !isClosed &&
      _platformCapabilities.supportsOnDeviceSpeechModels &&
      _explicitOptIn() &&
      _rolloutMode() == FeatureRolloutMode.shadow;

  Future<VoiceProsodyAnalyzer> _loadAnalyzer() {
    final current = _analyzerFuture;
    if (current != null) return current;
    late final Future<VoiceProsodyAnalyzer> loading;
    loading = Future<VoiceProsodyAnalyzer>.sync(_analyzerFactory).then((value) {
      _analyzer = value;
      return value;
    });
    _analyzerFuture = loading;
    unawaited(
      loading.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {
          if (identical(_analyzerFuture, loading)) _analyzerFuture = null;
        },
      ),
    );
    return loading;
  }

  bool _matchesAccount(String scopeDigest, int generation) =>
      _lifecycle == _VoiceProsodyLifecycle.active &&
      !isClosed &&
      scopeDigest.trim() == _accountScopeDigest &&
      generation == _accountGeneration;

  bool _isCurrent({
    required int lifecycleGeneration,
    required String accountScopeDigest,
    required int accountGeneration,
    required String utteranceId,
    required int utteranceGeneration,
  }) =>
      lifecycleGeneration == _lifecycleGeneration &&
      _matchesAccount(accountScopeDigest, accountGeneration) &&
      _utteranceGenerations[utteranceId] == utteranceGeneration;

  void _clearAccountState() {
    _pending.clear();
    _utteranceGenerations.clear();
    _activeSegmentOperations.clear();
    _nextTurnClaim = null;
    _baseline = null;
  }

  @override
  void onClose() {
    unawaited(retireAndDrain());
    super.onClose();
  }

  static String _validatedScopeDigest(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty || normalized.length > 128) {
      throw ArgumentError.value(value, 'accountScopeDigest', 'is invalid');
    }
    return normalized;
  }

  static int _validatedGeneration(int value) {
    if (value < 1 || value > 0x1fffffffffffff) {
      throw ArgumentError.value(value, 'accountGeneration', 'is invalid');
    }
    return value;
  }

  static String? _validatedUtteranceId(String value) {
    final normalized = value.trim();
    if (normalized.isEmpty ||
        normalized.length > 96 ||
        !RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(normalized)) {
      return null;
    }
    return normalized;
  }

  static Duration _validatedTtl(Duration value) {
    if (value <= Duration.zero || value > const Duration(minutes: 5)) {
      throw ArgumentError.value(value, 'metadataTtl', 'is invalid');
    }
    return value;
  }

  static Duration _validatedTimeout(Duration value) {
    if (value < const Duration(milliseconds: 10) ||
        value > const Duration(seconds: 5)) {
      throw ArgumentError.value(value, 'analysisTimeout', 'is invalid');
    }
    return value;
  }

  static double _validatedAlpha(double value) {
    if (!value.isFinite || value <= 0 || value > 1) {
      throw ArgumentError.value(value, 'emaAlpha', 'is invalid');
    }
    return value;
  }

  static int _validatedMaximumSamples(int value) {
    if (value < 8000 || value > 1920000) {
      throw ArgumentError.value(value, 'maximumSegmentSamples', 'is invalid');
    }
    return value;
  }

  static int _validatedTrackedUtterances(int value) {
    if (value < 1 || value > 1024) {
      throw ArgumentError.value(
        value,
        'maximumTrackedUtterances',
        'is invalid',
      );
    }
    return value;
  }

  static double _pitchDelta(double pitchHz, double baselineHz) {
    if (pitchHz <= 0 || baselineHz <= 0) return 0;
    return _clamp(12 * (math.log(pitchHz / baselineHz) / math.ln2), -12, 12);
  }

  static double _clamp(double value, double minimum, double maximum) {
    if (!value.isFinite) return 0;
    return value.clamp(minimum, maximum).toDouble();
  }
}

final class _BoundedProsody {
  const _BoundedProsody({
    required this.energy,
    required this.pitchHz,
    required this.speakingRate,
    required this.pauseRatio,
    required this.audioEventConfidence,
  });

  factory _BoundedProsody.from(VoiceProsodyAnalysis value) => _BoundedProsody(
    energy: _finiteClamp(value.energy, 0, 1),
    pitchHz: _finiteClamp(value.pitchHz, 0, 2000),
    speakingRate: _finiteClamp(value.speakingRate, 0, 12),
    pauseRatio: _finiteClamp(value.pauseRatio, 0, 1),
    audioEventConfidence: _finiteClamp(value.audioEventConfidence, 0, 1),
  );

  final double energy;
  final double pitchHz;
  final double speakingRate;
  final double pauseRatio;
  final double audioEventConfidence;

  static double _finiteClamp(double value, double minimum, double maximum) {
    if (!value.isFinite) return 0;
    return value.clamp(minimum, maximum).toDouble();
  }
}

final class _ProsodyBaseline {
  const _ProsodyBaseline({
    required this.energy,
    required this.pitchHz,
    required this.speakingRate,
    required this.pauseRatio,
  });

  factory _ProsodyBaseline.from(_BoundedProsody value) => _ProsodyBaseline(
    energy: value.energy,
    pitchHz: value.pitchHz,
    speakingRate: value.speakingRate,
    pauseRatio: value.pauseRatio,
  );

  final double energy;
  final double pitchHz;
  final double speakingRate;
  final double pauseRatio;

  _ProsodyBaseline updated(_BoundedProsody next, double alpha) =>
      _ProsodyBaseline(
        energy: _ema(energy, next.energy, alpha),
        pitchHz: _ema(pitchHz, next.pitchHz, alpha),
        speakingRate: _ema(speakingRate, next.speakingRate, alpha),
        pauseRatio: _ema(pauseRatio, next.pauseRatio, alpha),
      );

  static double _ema(double current, double next, double alpha) =>
      current + ((next - current) * alpha);
}
