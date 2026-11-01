import 'dart:async';
import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

typedef DesktopLocalAsrMountFence =
    bool Function({
      required String accountScopeDigest,
      required int generation,
    });

enum DesktopLocalAsrLifecycle {
  created,
  initializing,
  ready,
  decoding,
  retiring,
  retired,
}

enum DesktopLocalAsrFailure {
  unavailable,
  unsupportedHost,
  disabled,
  modelNotSelected,
  modelUnavailable,
  invalidAudio,
  busy,
  staleMount,
  timeout,
  recognizerError,
  preferenceError,
}

/// A locally provisioned model that a host-specific recognizer can resolve.
///
/// This object intentionally contains no URL, filesystem path, license claim,
/// or download behavior. Packaging and legal approval stay outside the app
/// runtime; the injected factory owns resolution of an approved [id].
final class DesktopLocalAsrModelPack {
  DesktopLocalAsrModelPack({required String id}) : id = _validateModelId(id);

  final String id;
}

final class DesktopLocalAsrRecognition {
  DesktopLocalAsrRecognition({required String transcript})
    : transcript = _validateTranscript(transcript);

  final String transcript;
}

/// Reusable model runtime; implementations create a fresh native stream for
/// every [recognize] call and must not persist or retain segment PCM after the
/// returned future completes. [close] must release model/runtime resources and
/// remain safe to retry until it succeeds.
abstract interface class DesktopLocalAsrRecognizer {
  Future<DesktopLocalAsrRecognition> recognize({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  });

  Future<void> close();
}

abstract interface class DesktopLocalAsrRecognizerFactory {
  Future<DesktopLocalAsrRecognizer> create(DesktopLocalAsrModelPack modelPack);
}

/// Host-owned integrity/installation check for an injected model pack.
///
/// Implementations may validate files, signatures, or native registrations.
/// The core service performs no IO and treats errors/timeouts as unavailable.
abstract interface class DesktopLocalAsrModelAvailability {
  Future<bool> isAvailable(DesktopLocalAsrModelPack modelPack);
}

/// Account-scoped, explicitly selected local-ASR preference.
final class DesktopLocalAsrPreferenceSnapshot {
  DesktopLocalAsrPreferenceSnapshot({
    required String accountScopeDigest,
    required this.revision,
    required this.enabled,
    required String? selectedModelId,
  }) : accountScopeDigest = _validateAccountScopeDigest(accountScopeDigest),
       selectedModelId = selectedModelId == null
           ? null
           : _validateModelId(selectedModelId) {
    if (revision < 1 || revision > _maximumPreferenceRevision) {
      throw ArgumentError.value(revision, 'revision', 'is invalid');
    }
    if (enabled && this.selectedModelId == null) {
      throw ArgumentError('enabled local ASR requires a selected model');
    }
  }

  final String accountScopeDigest;
  final int revision;
  final bool enabled;
  final String? selectedModelId;
}

abstract interface class DesktopLocalAsrPreferenceStore {
  Future<DesktopLocalAsrPreferenceSnapshot?> read();

  Future<void> write(DesktopLocalAsrPreferenceSnapshot snapshot);
}

/// Metadata-only observable state. PCM and transcripts are never retained.
final class DesktopLocalAsrState {
  const DesktopLocalAsrState({
    required this.lifecycle,
    required this.preferenceEnabled,
    required this.effectiveEnabled,
    required this.selectedModelId,
    required this.selectedModelAvailable,
    required this.decodeActive,
    required this.completedDecodeCount,
    required this.rejectedDecodeCount,
    required this.lastFailure,
  });

  const DesktopLocalAsrState.initial()
    : lifecycle = DesktopLocalAsrLifecycle.created,
      preferenceEnabled = false,
      effectiveEnabled = false,
      selectedModelId = null,
      selectedModelAvailable = false,
      decodeActive = false,
      completedDecodeCount = 0,
      rejectedDecodeCount = 0,
      lastFailure = null;

  final DesktopLocalAsrLifecycle lifecycle;
  final bool preferenceEnabled;
  final bool effectiveEnabled;
  final String? selectedModelId;
  final bool selectedModelAvailable;
  final bool decodeActive;
  final int completedDecodeCount;
  final int rejectedDecodeCount;
  final DesktopLocalAsrFailure? lastFailure;
}

final class DesktopLocalAsrDecodeResult {
  const DesktopLocalAsrDecodeResult._({
    required this.transcript,
    required this.failure,
  });

  const DesktopLocalAsrDecodeResult.success(String transcript)
    : this._(transcript: transcript, failure: null);

  const DesktopLocalAsrDecodeResult.rejected(DesktopLocalAsrFailure failure)
    : this._(transcript: null, failure: failure);

  final String? transcript;
  final DesktopLocalAsrFailure? failure;

  bool get accepted => failure == null;
}

/// Default-off desktop local-ASR lifecycle owned by one mounted account.
///
/// A decode copies and bounds its input, admits one segment at a time, and
/// zeroes that copy when recognition has really completed. One recognizer is
/// reused for the selected model, then closed after durable disable/model
/// switch or account retirement. A caller-visible timeout does not pretend to
/// cancel native work: the service stays busy and [sealAndDrain] waits for
/// actual completion and recognizer closure.
final class DesktopLocalAsrService extends AppService {
  DesktopLocalAsrService({
    required DesktopLocalAsrPreferenceStore preferenceStore,
    required DesktopLocalAsrRecognizerFactory recognizerFactory,
    required DesktopLocalAsrModelAvailability modelAvailability,
    required Iterable<DesktopLocalAsrModelPack> modelPacks,
    required AppPlatformCapabilities platformCapabilities,
    required String accountScopeDigest,
    required this.generation,
    required DesktopLocalAsrMountFence isCurrentMount,
    this.decodeTimeout = const Duration(seconds: 15),
    this.availabilityTimeout = const Duration(seconds: 2),
    this.maximumSampleCount = 480000,
  }) : _preferenceStore = preferenceStore,
       _recognizerFactory = recognizerFactory,
       _modelAvailability = modelAvailability,
       _platformCapabilities = platformCapabilities,
       _accountScopeDigest = _validateAccountScopeDigest(accountScopeDigest),
       _isCurrentMount = isCurrentMount,
       _modelPacks = _indexModelPacks(modelPacks) {
    if (generation < 1) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
    if (decodeTimeout <= Duration.zero ||
        decodeTimeout > const Duration(minutes: 2)) {
      throw ArgumentError.value(decodeTimeout, 'decodeTimeout', 'is invalid');
    }
    if (availabilityTimeout <= Duration.zero ||
        availabilityTimeout > const Duration(seconds: 30)) {
      throw ArgumentError.value(
        availabilityTimeout,
        'availabilityTimeout',
        'is invalid',
      );
    }
    if (maximumSampleCount < 1 || maximumSampleCount > 2880000) {
      throw ArgumentError.value(
        maximumSampleCount,
        'maximumSampleCount',
        'is invalid',
      );
    }
  }

  static const int minimumSampleRateHz = 8000;
  static const int maximumSampleRateHz = 48000;

  final DesktopLocalAsrPreferenceStore _preferenceStore;
  final DesktopLocalAsrRecognizerFactory _recognizerFactory;
  final DesktopLocalAsrModelAvailability _modelAvailability;
  final AppPlatformCapabilities _platformCapabilities;
  final Map<String, DesktopLocalAsrModelPack> _modelPacks;
  final String _accountScopeDigest;
  final DesktopLocalAsrMountFence _isCurrentMount;
  final int generation;
  final Duration decodeTimeout;
  final Duration availabilityTimeout;
  final int maximumSampleCount;

  final state = const DesktopLocalAsrState.initial().obs;

  DesktopLocalAsrLifecycle _lifecycle = DesktopLocalAsrLifecycle.created;
  Future<void> _preferenceTail = Future<void>.value();
  Future<void>? _activeDrain;
  Future<void>? _retirement;
  _DecodeToken? _activeToken;
  _CachedRecognizer? _cachedRecognizer;
  int _configurationMutationCount = 0;
  int _preferenceRevision = 0;
  int _configurationRevision = 0;
  bool _preferenceEnabled = false;
  bool _sealed = false;
  bool _selectedModelAvailable = false;
  String? _selectedModelId;
  final Map<String, Future<bool>> _availabilityChecks =
      <String, Future<bool>>{};

  String get accountScopeDigest => _accountScopeDigest;

  Map<String, DesktopLocalAsrModelPack> get modelPacks => _modelPacks;

  DesktopLocalAsrModelPack? get selectedModelPack =>
      _modelPacks[_selectedModelId];

  bool get isDesktopHost =>
      _platformCapabilities.platform == AppHostPlatform.macos ||
      _platformCapabilities.platform == AppHostPlatform.windows ||
      _platformCapabilities.platform == AppHostPlatform.linux;

  bool get effectiveEnabled =>
      !_sealed &&
      _lifecycle != DesktopLocalAsrLifecycle.created &&
      _lifecycle != DesktopLocalAsrLifecycle.initializing &&
      _lifecycle != DesktopLocalAsrLifecycle.retired &&
      _configurationMutationCount == 0 &&
      isDesktopHost &&
      _preferenceEnabled &&
      _selectedModelId != null &&
      _modelPacks.containsKey(_selectedModelId) &&
      _selectedModelAvailable;

  Future<DesktopLocalAsrService> init() async {
    if (_lifecycle != DesktopLocalAsrLifecycle.created || isClosed) {
      throw StateError('desktop_local_asr_already_initialized');
    }
    _lifecycle = DesktopLocalAsrLifecycle.initializing;
    _publish();
    DesktopLocalAsrFailure? failure;
    try {
      final restored = await _preferenceStore.read();
      if (!_mountIsCurrent() || _sealed || isClosed) {
        _sealed = true;
        _lifecycle = DesktopLocalAsrLifecycle.retired;
        _publish(lastFailure: DesktopLocalAsrFailure.staleMount);
        return this;
      }
      if (restored != null) {
        if (restored.accountScopeDigest != _accountScopeDigest) {
          throw const FormatException('desktop local ASR account mismatch');
        }
        _preferenceRevision = restored.revision;
        _configurationRevision = restored.revision;
        _preferenceEnabled = restored.enabled;
        _selectedModelId = restored.selectedModelId;
        _selectedModelAvailable = false;
        if (_preferenceEnabled && !isDesktopHost) {
          failure = DesktopLocalAsrFailure.unsupportedHost;
        } else if (_preferenceEnabled &&
            !_modelPacks.containsKey(_selectedModelId)) {
          failure = DesktopLocalAsrFailure.modelUnavailable;
        }
      }
      if (!_mountIsCurrent() || _sealed || isClosed) {
        _sealed = true;
        _lifecycle = DesktopLocalAsrLifecycle.retired;
        _publish(lastFailure: DesktopLocalAsrFailure.staleMount);
        return this;
      }
    } on Object {
      _preferenceRevision = 0;
      _configurationRevision = 0;
      _preferenceEnabled = false;
      _selectedModelId = null;
      _selectedModelAvailable = false;
      failure = DesktopLocalAsrFailure.preferenceError;
    }
    _lifecycle = DesktopLocalAsrLifecycle.ready;
    _publish(lastFailure: failure);
    return this;
  }

  Future<void> selectModel(String modelId) {
    final normalized = _validateModelId(modelId);
    final pack = _modelPacks[normalized];
    if (pack == null) {
      return Future<void>.error(
        StateError('desktop_local_asr_model_unavailable'),
      );
    }
    return _enqueuePreferenceMutation(() async {
      final available = await _checkModelAvailable(pack);
      if (_preferenceEnabled && !available) {
        throw StateError('desktop_local_asr_model_unavailable');
      }
      await _writePreference(
        enabled: _preferenceEnabled,
        selectedModelId: normalized,
        selectedModelAvailable: available,
      );
    });
  }

  Future<void> setEnabled(bool enabled) {
    if (enabled && !isDesktopHost) {
      return Future<void>.error(
        UnsupportedError('desktop_local_asr_desktop_only'),
      );
    }
    if (enabled &&
        (_selectedModelId == null ||
            !_modelPacks.containsKey(_selectedModelId))) {
      return Future<void>.error(
        StateError('desktop_local_asr_model_not_selected'),
      );
    }
    return _enqueuePreferenceMutation(() async {
      var available = _selectedModelAvailable;
      if (enabled) {
        final pack = _modelPacks[_selectedModelId]!;
        available = await _checkModelAvailable(pack);
        if (!available) {
          if (_selectedModelId == pack.id && _canMutatePreferences()) {
            _selectedModelAvailable = false;
            _publish(lastFailure: DesktopLocalAsrFailure.modelUnavailable);
          }
          throw StateError('desktop_local_asr_model_unavailable');
        }
      }
      await _writePreference(
        enabled: enabled,
        selectedModelId: _selectedModelId,
        selectedModelAvailable: available,
      );
    });
  }

  Future<bool> isOperational() async {
    if (_sealed ||
        isClosed ||
        _configurationMutationCount != 0 ||
        !_mountIsCurrent() ||
        !isDesktopHost ||
        !_preferenceEnabled) {
      return false;
    }
    final modelId = _selectedModelId;
    final pack = _modelPacks[modelId];
    if (modelId == null || pack == null) return false;
    final configurationRevision = _configurationRevision;
    final available = await _checkModelAvailable(pack);
    if (!_sealed &&
        !isClosed &&
        _mountIsCurrent() &&
        modelId == _selectedModelId &&
        configurationRevision == _configurationRevision) {
      _selectedModelAvailable = available;
      _publish(
        lastFailure: available ? null : DesktopLocalAsrFailure.modelUnavailable,
        clearFailure: available,
      );
    }
    return available &&
        !_sealed &&
        !isClosed &&
        _configurationMutationCount == 0 &&
        _mountIsCurrent() &&
        modelId == _selectedModelId &&
        configurationRevision == _configurationRevision;
  }

  Future<DesktopLocalAsrDecodeResult> decode({
    required Float32List samples,
    required int sampleRateHz,
    String? locale,
  }) async {
    final admissionFailure = _admissionFailure(
      samples: samples,
      sampleRateHz: sampleRateHz,
      locale: locale,
    );
    if (admissionFailure != null) {
      _recordRejection(admissionFailure);
      return DesktopLocalAsrDecodeResult.rejected(admissionFailure);
    }

    final modelId = _selectedModelId!;
    final modelPack = _modelPacks[modelId]!;
    final token = _DecodeToken(
      configurationRevision: _configurationRevision,
      modelId: modelId,
    );
    final ownedSamples = Float32List.fromList(samples);
    _activeToken = token;
    _lifecycle = DesktopLocalAsrLifecycle.decoding;
    _publish(clearFailure: true);

    final operation = _performDecode(
      token: token,
      modelPack: modelPack,
      samples: ownedSamples,
      sampleRateHz: sampleRateHz,
      locale: locale?.trim(),
    );
    final operationSettled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    late final Future<void> drain;
    drain =
        Future.wait<void>(<Future<void>>[
          operationSettled,
          token.responseSettled.future,
        ]).whenComplete(() {
          if (identical(_activeToken, token)) {
            _activeToken = null;
            _activeDrain = null;
            if (!_sealed && _lifecycle == DesktopLocalAsrLifecycle.decoding) {
              _lifecycle = DesktopLocalAsrLifecycle.ready;
              _publish();
            }
          }
        });
    _activeDrain = drain;

    late final DesktopLocalAsrDecodeResult response;
    try {
      final outcome = await operation.timeout(decodeTimeout);
      if (!_tokenIsCurrent(token)) {
        _recordRejection(DesktopLocalAsrFailure.staleMount);
        response = const DesktopLocalAsrDecodeResult.rejected(
          DesktopLocalAsrFailure.staleMount,
        );
      } else if (outcome.failure != null) {
        if (outcome.failure == DesktopLocalAsrFailure.modelUnavailable) {
          _selectedModelAvailable = false;
        }
        _recordRejection(outcome.failure!);
        response = DesktopLocalAsrDecodeResult.rejected(outcome.failure!);
      } else {
        _selectedModelAvailable = true;
        final transcript = outcome.recognition!.transcript;
        final current = state.value;
        state.value = DesktopLocalAsrState(
          lifecycle: current.lifecycle,
          preferenceEnabled: _preferenceEnabled,
          effectiveEnabled: effectiveEnabled,
          selectedModelId: _selectedModelId,
          selectedModelAvailable: _selectedModelAvailable,
          decodeActive: _activeToken != null,
          completedDecodeCount: current.completedDecodeCount + 1,
          rejectedDecodeCount: current.rejectedDecodeCount,
          lastFailure: null,
        );
        response = DesktopLocalAsrDecodeResult.success(transcript);
      }
    } on TimeoutException {
      _recordRejection(DesktopLocalAsrFailure.timeout);
      response = const DesktopLocalAsrDecodeResult.rejected(
        DesktopLocalAsrFailure.timeout,
      );
    } on Object {
      _recordRejection(DesktopLocalAsrFailure.recognizerError);
      response = const DesktopLocalAsrDecodeResult.rejected(
        DesktopLocalAsrFailure.recognizerError,
      );
    } finally {
      token.responseClosed = true;
      if (!token.responseSettled.isCompleted) {
        token.responseSettled.complete();
      }
    }
    return response;
  }

  /// Stops admission and waits for every admitted preference write, decode,
  /// PCM zeroization, and recognizer close. It deliberately has no timeout:
  /// account teardown must not claim success while native work is still live.
  Future<void> sealAndDrain() {
    final existing = _retirement;
    if (existing != null) return existing;
    _sealed = true;
    _configurationRevision++;
    _lifecycle = DesktopLocalAsrLifecycle.retiring;
    _publish();
    late final Future<void> retirement;
    retirement = _drainRetirementAttempt();
    _retirement = retirement;
    return retirement;
  }

  Future<void> _drainRetirementAttempt() async {
    try {
      await _drainStrictly();
    } on Object {
      _retirement = null;
      rethrow;
    }
  }

  Future<void> _drainStrictly() async {
    await _preferenceTail;
    final active = _activeDrain;
    if (active != null) await active;
    await _closeCachedRecognizerNow();
    _lifecycle = DesktopLocalAsrLifecycle.retired;
    _publish();
  }

  Future<void> _enqueuePreferenceMutation(Future<void> Function() mutation) {
    if (!_canMutatePreferences()) {
      return Future<void>.error(
        StateError('desktop_local_asr_preference_unavailable'),
      );
    }
    _configurationMutationCount++;
    _publish();
    final previous = _preferenceTail;
    late final Future<void> current;
    current = previous.then<void>(
      (_) => mutation(),
      onError: (Object _, StackTrace _) => mutation(),
    );
    final completed = current.whenComplete(() {
      _configurationMutationCount--;
      _publish();
    });
    _preferenceTail = completed.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return completed;
  }

  Future<void> _writePreference({
    required bool enabled,
    required String? selectedModelId,
    required bool selectedModelAvailable,
  }) async {
    if (!_canMutatePreferences()) {
      throw StateError('desktop_local_asr_preference_retired');
    }
    final revision = _preferenceRevision + 1;
    if (revision > _maximumPreferenceRevision) {
      throw StateError('desktop_local_asr_preference_revision_exhausted');
    }
    final previousModelId = _selectedModelId;
    final snapshot = DesktopLocalAsrPreferenceSnapshot(
      accountScopeDigest: _accountScopeDigest,
      revision: revision,
      enabled: enabled,
      selectedModelId: selectedModelId,
    );
    try {
      await _preferenceStore.write(snapshot);
    } on Object {
      _publish(lastFailure: DesktopLocalAsrFailure.preferenceError);
      rethrow;
    }
    if (!_canMutatePreferences()) {
      await _closeCachedRecognizerAfterActiveDecode();
      return;
    }
    _preferenceRevision = revision;
    _configurationRevision++;
    _preferenceEnabled = enabled;
    _selectedModelId = selectedModelId;
    _selectedModelAvailable = selectedModelAvailable;
    _publish(clearFailure: true);
    if (!enabled || previousModelId != selectedModelId) {
      await _closeCachedRecognizerAfterActiveDecode();
    }
  }

  _DecodeOutcome _staleOutcome() =>
      const _DecodeOutcome.failure(DesktopLocalAsrFailure.staleMount);

  Future<_DecodeOutcome> _performDecode({
    required _DecodeToken token,
    required DesktopLocalAsrModelPack modelPack,
    required Float32List samples,
    required int sampleRateHz,
    required String? locale,
  }) async {
    try {
      if (!_tokenIsCurrent(token)) return _staleOutcome();
      if (!await _checkModelAvailable(modelPack)) {
        await _closeCachedRecognizerForRejectedOutcome();
        return const _DecodeOutcome.failure(
          DesktopLocalAsrFailure.modelUnavailable,
        );
      }
      if (!_tokenIsCurrent(token)) {
        await _closeCachedRecognizerForRejectedOutcome();
        return _staleOutcome();
      }
      final recognizer = await _obtainRecognizer(modelPack, token);
      if (recognizer == null) return _staleOutcome();
      final recognition = await recognizer.recognize(
        samples: samples,
        sampleRateHz: sampleRateHz,
        locale: locale,
      );
      if (!_tokenIsCurrent(token)) {
        await _closeCachedRecognizerForRejectedOutcome();
        return _staleOutcome();
      }
      return _DecodeOutcome.success(recognition);
    } on Object {
      await _closeCachedRecognizerForRejectedOutcome();
      return const _DecodeOutcome.failure(
        DesktopLocalAsrFailure.recognizerError,
      );
    } finally {
      samples.fillRange(0, samples.length, 0);
    }
  }

  Future<DesktopLocalAsrRecognizer?> _obtainRecognizer(
    DesktopLocalAsrModelPack modelPack,
    _DecodeToken token,
  ) async {
    final existing = _cachedRecognizer;
    if (existing != null && existing.modelId == modelPack.id) {
      return existing.recognizer;
    }
    if (existing != null) await _closeCachedRecognizerNow();
    if (!_tokenIsCurrent(token)) return null;
    final created = await _recognizerFactory.create(modelPack);
    _cachedRecognizer = _CachedRecognizer(
      modelId: modelPack.id,
      recognizer: created,
    );
    if (!_tokenIsCurrent(token)) {
      await _closeCachedRecognizerForRejectedOutcome();
      return null;
    }
    return created;
  }

  Future<void> _closeCachedRecognizerAfterActiveDecode() async {
    final active = _activeDrain;
    if (active != null) await active;
    await _closeCachedRecognizerNow();
  }

  Future<void> _closeCachedRecognizerNow() async {
    final cached = _cachedRecognizer;
    if (cached == null) return;
    await cached.recognizer.close();
    if (identical(_cachedRecognizer, cached)) _cachedRecognizer = null;
  }

  Future<void> _closeCachedRecognizerForRejectedOutcome() async {
    try {
      await _closeCachedRecognizerNow();
    } on Object {
      // Keep the failed holder so sealAndDrain can retry strict closure.
    }
  }

  Future<bool> _checkModelAvailable(DesktopLocalAsrModelPack modelPack) async {
    var check = _availabilityChecks[modelPack.id];
    if (check == null) {
      late final Future<bool> tracked;
      tracked =
          Future<bool>.sync(() => _modelAvailability.isAvailable(modelPack))
              .then<bool>(
                (available) => available,
                onError: (Object _, StackTrace _) => false,
              )
              .whenComplete(() {
                if (identical(_availabilityChecks[modelPack.id], tracked)) {
                  _availabilityChecks.remove(modelPack.id);
                }
              });
      check = tracked;
      _availabilityChecks[modelPack.id] = tracked;
    }
    try {
      return await check.timeout(availabilityTimeout, onTimeout: () => false);
    } on Object {
      return false;
    }
  }

  DesktopLocalAsrFailure? _admissionFailure({
    required Float32List samples,
    required int sampleRateHz,
    required String? locale,
  }) {
    if (_sealed ||
        isClosed ||
        _lifecycle == DesktopLocalAsrLifecycle.created ||
        _lifecycle == DesktopLocalAsrLifecycle.initializing ||
        _lifecycle == DesktopLocalAsrLifecycle.retired) {
      return DesktopLocalAsrFailure.unavailable;
    }
    if (!_mountIsCurrent()) return DesktopLocalAsrFailure.staleMount;
    if (!isDesktopHost) return DesktopLocalAsrFailure.unsupportedHost;
    if (_configurationMutationCount != 0) {
      return DesktopLocalAsrFailure.busy;
    }
    if (!_preferenceEnabled) return DesktopLocalAsrFailure.disabled;
    if (_selectedModelId == null) {
      return DesktopLocalAsrFailure.modelNotSelected;
    }
    if (!_modelPacks.containsKey(_selectedModelId)) {
      return DesktopLocalAsrFailure.modelUnavailable;
    }
    if (_activeToken != null) return DesktopLocalAsrFailure.busy;
    if (sampleRateHz < minimumSampleRateHz ||
        sampleRateHz > maximumSampleRateHz ||
        samples.isEmpty ||
        samples.length > maximumSampleCount ||
        samples.any((sample) => !sample.isFinite) ||
        (locale != null && (locale.trim().isEmpty || locale.length > 64))) {
      return DesktopLocalAsrFailure.invalidAudio;
    }
    return null;
  }

  bool _canMutatePreferences() =>
      !_sealed &&
      !isClosed &&
      _lifecycle != DesktopLocalAsrLifecycle.created &&
      _lifecycle != DesktopLocalAsrLifecycle.initializing &&
      _lifecycle != DesktopLocalAsrLifecycle.retired &&
      _mountIsCurrent();

  bool _tokenIsCurrent(_DecodeToken token) =>
      !token.responseClosed &&
      !_sealed &&
      !isClosed &&
      identical(_activeToken, token) &&
      token.configurationRevision == _configurationRevision &&
      token.modelId == _selectedModelId &&
      _mountIsCurrent();

  bool _mountIsCurrent() {
    try {
      return _isCurrentMount(
        accountScopeDigest: _accountScopeDigest,
        generation: generation,
      );
    } on Object {
      return false;
    }
  }

  void _recordRejection(DesktopLocalAsrFailure failure) {
    final current = state.value;
    state.value = DesktopLocalAsrState(
      lifecycle: current.lifecycle,
      preferenceEnabled: _preferenceEnabled,
      effectiveEnabled: effectiveEnabled,
      selectedModelId: _selectedModelId,
      selectedModelAvailable: _selectedModelAvailable,
      decodeActive: _activeToken != null,
      completedDecodeCount: current.completedDecodeCount,
      rejectedDecodeCount: current.rejectedDecodeCount + 1,
      lastFailure: failure,
    );
  }

  void _publish({
    DesktopLocalAsrFailure? lastFailure,
    bool clearFailure = false,
  }) {
    final current = state.value;
    state.value = DesktopLocalAsrState(
      lifecycle: _lifecycle,
      preferenceEnabled: _preferenceEnabled,
      effectiveEnabled: effectiveEnabled,
      selectedModelId: _selectedModelId,
      selectedModelAvailable: _selectedModelAvailable,
      decodeActive: _activeToken != null,
      completedDecodeCount: current.completedDecodeCount,
      rejectedDecodeCount: current.rejectedDecodeCount,
      lastFailure: clearFailure ? null : lastFailure ?? current.lastFailure,
    );
  }

  @override
  void onClose() {
    unawaited(sealAndDrain().catchError((Object _, StackTrace _) {}));
    super.onClose();
  }
}

final class _DecodeToken {
  _DecodeToken({required this.configurationRevision, required this.modelId});

  final int configurationRevision;
  final String modelId;
  final responseSettled = Completer<void>();
  bool responseClosed = false;
}

final class _CachedRecognizer {
  const _CachedRecognizer({required this.modelId, required this.recognizer});

  final String modelId;
  final DesktopLocalAsrRecognizer recognizer;
}

final class _DecodeOutcome {
  const _DecodeOutcome.success(this.recognition) : failure = null;

  const _DecodeOutcome.failure(this.failure) : recognition = null;

  final DesktopLocalAsrRecognition? recognition;
  final DesktopLocalAsrFailure? failure;
}

const int _maximumPreferenceRevision = 0x1fffffffffffff;
final RegExp _accountScopeDigestPattern = RegExp(r'^[a-f0-9]{64}$');
final RegExp _modelIdPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,95}$');

String _validateAccountScopeDigest(String value) {
  final normalized = value.trim();
  if (!_accountScopeDigestPattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, 'accountScopeDigest', 'is invalid');
  }
  return normalized;
}

String _validateModelId(String value) {
  final normalized = value.trim();
  if (!_modelIdPattern.hasMatch(normalized)) {
    throw ArgumentError.value(value, 'modelId', 'is invalid');
  }
  return normalized;
}

String _validateTranscript(String value) {
  final normalized = value.trim();
  if (normalized.length > 65536) {
    throw ArgumentError.value(value.length, 'transcript', 'is too long');
  }
  return normalized;
}

Map<String, DesktopLocalAsrModelPack> _indexModelPacks(
  Iterable<DesktopLocalAsrModelPack> packs,
) {
  final indexed = <String, DesktopLocalAsrModelPack>{};
  for (final pack in packs) {
    if (indexed.containsKey(pack.id)) {
      throw ArgumentError.value(pack.id, 'modelPacks', 'contains a duplicate');
    }
    indexed[pack.id] = pack;
  }
  return Map<String, DesktopLocalAsrModelPack>.unmodifiable(indexed);
}
