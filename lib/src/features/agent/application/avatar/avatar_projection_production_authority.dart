import 'avatar_emotion_timeline.dart';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/self_avatar_projection_service.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

enum AvatarProductionAuthorityPhase {
  legacy,
  shadow,
  enforcing,
  drainingLocked,
  failedLocked,
  sealedLocked,
}

enum AvatarProductionBehaviorDisposition {
  applied,
  rendererNotReady,
  capabilityUnavailable,
  authorityStale,
  retainedBehindHigherPriority,
  dispatchFailed,
}

final class AvatarProductionBehaviorResult {
  const AvatarProductionBehaviorResult(this.disposition);

  final AvatarProductionBehaviorDisposition disposition;

  bool get applied =>
      disposition == AvatarProductionBehaviorDisposition.applied;
}

/// Process-wide fence for the one concrete Unity renderer.
///
/// An absent authority preserves isolated arbiter/sink tests. Once a production
/// authority is installed, all legacy avatar-channel calls and all ticketed
/// transport operations are checked against its exact account and renderer
/// epoch. A failed retirement remains locked across account mounts until the
/// next authority obtains an exact Unity reset receipt.
abstract final class AvatarProductionOwnership {
  static AvatarProjectionProductionAuthority? _current;
  static bool _retirementLocked = false;

  static AvatarProjectionProductionAuthority? currentFor(String agentId) {
    if (agentId != 'self') return null;
    final current = _current;
    current?._refreshControlFence();
    return current;
  }

  static bool get ownsRenderer {
    final current = _current;
    current?._refreshControlFence();
    return current?._ownsRenderer ?? _retirementLocked;
  }

  static bool get blocksLegacyAvatarMutation => ownsRenderer;

  static bool allowsCommand(AvatarCommandDispatchOperation operation) {
    final current = _current;
    if (current == null) return !_retirementLocked;
    return current._allowsCommand(operation);
  }

  static bool allowsReset(AvatarRendererResetOperation operation) {
    final current = _current;
    if (current == null) return !_retirementLocked;
    return current._allowsReset(operation);
  }

  static void _install(AvatarProjectionProductionAuthority authority) {
    final current = _current;
    if (current != null && !identical(current, authority)) {
      final recoverableRetirement =
          current._phase == AvatarProductionAuthorityPhase.sealedLocked &&
          _retirementLocked;
      if (!recoverableRetirement) {
        throw StateError('avatar_production_authority_already_registered');
      }
    }
    _current = authority;
  }

  static void _uninstall(AvatarProjectionProductionAuthority authority) {
    if (identical(_current, authority)) _current = null;
  }

  @visibleForTesting
  static void resetForTest() {
    _current = null;
    _retirementLocked = false;
    AvatarProjectionProductionAuthority._nextRendererGeneration = 0;
  }
}

/// Account-scoped owner of EventBus -> self-avatar projection in enforce.
///
/// Off and shadow keep the legacy renderers untouched. Enforce owns the sole
/// renderer mutation lane through a fresh [AvatarCommandArbiter] epoch. Every
/// control, renderer-ready, backend, or account transition retires that epoch;
/// normal tickets close synchronously while exact neutral clears remain
/// authorized only for the retiring epoch.
final class AvatarProjectionProductionAuthority extends AppService {
  AvatarProjectionProductionAuthority({
    required this.accountGeneration,
    required this.featureFlags,
    required this.activeAvatarRuntime,
    required this.renderer,
    required this.dispatchSink,
    required this.mountIsCurrent,
    this.cameraFramingIsManaged,
    this.agentId = 'self',
  }) {
    if (accountGeneration < 0) {
      throw ArgumentError.value(accountGeneration, 'accountGeneration');
    }
    if (agentId != 'self') {
      throw ArgumentError.value(agentId, 'agentId');
    }
  }

  static int _nextRendererGeneration = 0;
  static const Duration _projectionLeaseTtl = Duration(minutes: 10);
  static const Set<String> _supportedBodyGestures = <String>{
    'cheer',
    'jump',
    'listen',
    'look_away',
    'nod',
    'shrug',
    'think',
    'wave',
    'speech',
    'explain',
    'palms_open',
    'point_small',
    'chest',
    'point_self',
    'dance',
    'clap',
    'laugh',
    'bow',
    'hand_to_chest',
    ...AvatarFurnitureState.gestures,
  };

  final int accountGeneration;
  final MaasoFeatureFlagService featureFlags;
  final ActiveAvatarRuntime activeAvatarRuntime;
  final AvatarRuntime renderer;
  final AvatarCommandDispatchSink dispatchSink;
  final bool Function() mountIsCurrent;
  final bool Function()? cameraFramingIsManaged;
  final String agentId;

  final List<StreamSubscription<dynamic>> _eventSubscriptions =
      <StreamSubscription<dynamic>>[];
  Worker? _flagWorker;
  Worker? _backendWorker;
  Worker? _readyWorker;
  void Function()? _unregisterSoundStopper;
  Future<void> _transitionTail = Future<void>.value();
  Future<void> _cameraTail = Future<void>.value();
  _ProductionCameraLease? _cameraLease;
  final _backgroundWorkLeases =
      <String, ({_AvatarProductionEpoch epoch, int generation})>{};
  Future<void>? _sealFuture;
  _AvatarProductionEpoch? _epoch;
  _AvatarProductionEpoch? _retiringEpoch;
  _AvatarProductionEpoch? _lastAppliedEpoch;
  _ExpectedAvatarReset? _expectedReset;
  AvatarProductionAuthorityPhase _phase = AvatarProductionAuthorityPhase.legacy;
  FeatureRolloutMode _observedMode = FeatureRolloutMode.off;
  int _observedFlagGeneration = -1;
  bool _observedRendererCurrent = false;
  bool _observedRendererReady = false;
  int _controlEpoch = 0;
  int _rendererGeneration = 0;
  int _hostTaskWorkAuthorityGeneration = 0;
  int _sequence = 0;
  int _speechGeneration = 0;
  int _commandGeneration = 0;
  EmotionParams _baseEmotion = EmotionParams.neutral;
  String? _baseEmotionLabel;
  bool _speaking = false;
  double _lipAmplitude = 0;
  bool _sealed = false;
  bool _drainSucceeded = false;

  AvatarProductionAuthorityPhase get phase {
    _refreshControlFence();
    return _phase;
  }

  int get rendererGeneration => _rendererGeneration;

  /// Legacy host work survives a temporary native detach. Rollout, renderer
  /// ownership and account sealing remain fences; ticketed projection keeps
  /// using [rendererGeneration], including all readiness changes.
  int get hostTaskWorkAuthorityGeneration {
    _refreshControlFence();
    return _hostTaskWorkAuthorityGeneration;
  }

  bool acceptsRendererObservation(Map<String, dynamic> event) {
    _refreshControlFence();
    final epoch = _epoch;
    final owner = event['ownerToken'];
    final account = event['accountGeneration'];
    final rendererGeneration = event['rendererGeneration'];
    return _phase == AvatarProductionAuthorityPhase.enforcing &&
        epoch != null &&
        epoch.ticketAuthority &&
        _rendererIsCurrent &&
        owner is String &&
        account is int &&
        rendererGeneration is int &&
        epoch.arbiter.acceptsRendererObservation(
          ownerToken: owner,
          accountGeneration: account,
          rendererGeneration: rendererGeneration,
        );
  }

  bool get _ownsRenderer => switch (_phase) {
    AvatarProductionAuthorityPhase.enforcing ||
    AvatarProductionAuthorityPhase.drainingLocked ||
    AvatarProductionAuthorityPhase.failedLocked ||
    AvatarProductionAuthorityPhase.sealedLocked => true,
    AvatarProductionAuthorityPhase.legacy ||
    AvatarProductionAuthorityPhase.shadow => false,
  };

  bool get _rendererIsCurrent =>
      identical(activeAvatarRuntime.current, renderer) && mountIsCurrent();

  @override
  void onInit() {
    super.onInit();
    AvatarProductionOwnership._install(this);
    _subscribeToSelfEvents();
    _flagWorker = featureFlags.state.listen((_) => _refreshControlFence());
    _backendWorker = activeAvatarRuntime.backend.listen(
      (_) => _refreshControlFence(),
    );
    _readyWorker = renderer.isReady.listen((_) => _refreshControlFence());
    _refreshControlFence(force: true);
  }

  void _subscribeToSelfEvents() {
    _unregisterSoundStopper = MaasoTtsPlugin.registerSoundStopper(() {
      _speaking = false;
      _lipAmplitude = 0;
      if (_speechGeneration == 0) _speechGeneration = 1;
      _projectCurrent(
        (epoch) => SelfAvatarSpeakingProjectionInput(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          sequence: _nextSequence(),
          isSpeaking: false,
          generation: _speechGeneration,
        ),
      );
      return waitForIdle();
    });
    bool mine(ClawEvent event) =>
        event.agentId == null || event.agentId == agentId;

    _eventSubscriptions.addAll(<StreamSubscription<dynamic>>[
      EventBus().on<EmotionStateEvent>().where(mine).listen((event) {
        if (event.duration == null) {
          _baseEmotion = event.persistent
              ? event.params
              : AvatarEmotionTimeline.restingMood(event.params);
          _baseEmotionLabel = event.semanticLabel;
        }
        _projectCurrent(
          (epoch) => SelfAvatarEmotionProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
            params: event.params,
            duration: event.duration,
            semanticLabel: event.semanticLabel,
            persistent: event.persistent,
            automatic: event.automatic,
          ),
        );
      }),
      EventBus().on<AvatarEmotionResetEvent>().where(mine).listen((_) {
        _projectCurrent(
          (epoch) => SelfAvatarEmotionResetProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
          ),
        );
      }),
      EventBus().on<SendMemeEvent>().where(mine).listen((_) {
        _baseEmotion = AvatarEmotionTimeline.restingMood(EmotionParams.love);
        _baseEmotionLabel = 'love';
        _projectCurrent(
          (epoch) => SelfAvatarMemeProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
          ),
        );
      }),
      EventBus().on<SpeakingStatusEvent>().where(mine).listen((event) {
        if (event.isSpeaking &&
            !MaasoTtsPlugin.permitsPlaybackEvents(agentId)) {
          return;
        }
        if (event.isSpeaking) {
          _speechGeneration += 1;
          _speaking = true;
        } else {
          if (_speechGeneration == 0) _speechGeneration = 1;
          _speaking = false;
          _lipAmplitude = 0;
        }
        final speechGeneration = _speechGeneration;
        _projectCurrent(
          (epoch) => SelfAvatarSpeakingProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
            isSpeaking: event.isSpeaking,
            generation: speechGeneration,
          ),
        );
      }),
      EventBus().on<LipSyncAmplitudeEvent>().where(mine).listen((event) {
        if (event.amplitude > 0 &&
            !MaasoTtsPlugin.permitsPlaybackEvents(agentId)) {
          return;
        }
        _lipAmplitude = event.amplitude.clamp(0.0, 1.0).toDouble();
        if (_speechGeneration == 0) return;
        final speechGeneration = _speechGeneration;
        _projectCurrent(
          (epoch) => SelfAvatarLipFrameProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
            amplitude: _lipAmplitude,
            generation: speechGeneration,
          ),
        );
      }),
      EventBus().on<LipSyncEnvelopeEvent>().where(mine).listen((event) {
        if (!MaasoTtsPlugin.permitsPlaybackEvents(agentId)) return;
        if (_speechGeneration == 0 || event.envelope.isEmpty) return;
        final speechGeneration = _speechGeneration;
        try {
          _projectCurrent(
            (epoch) => SelfAvatarLipEnvelopeProjectionInput(
              accountGeneration: accountGeneration,
              rendererGeneration: epoch.rendererGeneration,
              sequence: _nextSequence(),
              envelope: event.envelope,
              frameRate: event.frameRate,
              generation: speechGeneration,
            ),
          );
        } on ArgumentError {
          // Invalid envelopes never enter the projection state machine.
        }
      }),
      EventBus().on<LipSyncVisemeTrackEvent>().where(mine).listen((event) {
        if (!MaasoTtsPlugin.permitsPlaybackEvents(agentId)) return;
        if (_speechGeneration == 0) return;
        final speechGeneration = _speechGeneration;
        _projectCurrent(
          (epoch) => SelfAvatarVisemeTrackProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
            track: event.track,
            generation: speechGeneration,
          ),
        );
      }),
      EventBus().on<SpeechPlaybackClockEvent>().where(mine).listen((event) {
        if (!MaasoTtsPlugin.permitsPlaybackEvents(agentId) &&
            event.clock.state.name != 'stop') {
          return;
        }
        _projectCurrent(
          (epoch) => SelfAvatarSpeechPlaybackClockProjectionInput(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            sequence: _nextSequence(),
            clock: event.clock,
          ),
        );
      }),
    ]);
  }

  void _projectCurrent(
    SelfAvatarProjectionInput Function(_AvatarProductionEpoch epoch) build,
  ) {
    _refreshControlFence();
    final epoch = _epoch;
    if (_sealed || epoch == null || epoch.controlEpoch != _controlEpoch) return;
    late final SelfAvatarProjectionInput input;
    try {
      input = build(epoch);
    } on ArgumentError {
      return;
    }
    unawaited(
      epoch.projection
          .project(input)
          .then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }

  void _refreshControlFence({bool force = false}) {
    if (_sealed) return;
    final mode = featureFlags.effectiveMode(
      MaasoFeatureFlag.avatarProjectionV2,
    );
    final flagGeneration = featureFlags.authorityGeneration(
      MaasoFeatureFlag.avatarProjectionV2,
    );
    final rendererCurrent = _rendererIsCurrent;
    final rendererReady = renderer.isReady.value;
    if (!force &&
        mode == _observedMode &&
        flagGeneration == _observedFlagGeneration &&
        rendererCurrent == _observedRendererCurrent &&
        rendererReady == _observedRendererReady) {
      return;
    }

    final oldEpoch = _epoch;
    if (force ||
        mode != _observedMode ||
        flagGeneration != _observedFlagGeneration ||
        rendererCurrent != _observedRendererCurrent) {
      _hostTaskWorkAuthorityGeneration++;
    }
    _epoch = null;
    _controlEpoch += 1;
    _rendererGeneration = ++_nextRendererGeneration;
    _observedMode = mode;
    _observedFlagGeneration = flagGeneration;
    _observedRendererCurrent = rendererCurrent;
    _observedRendererReady = rendererReady;

    final oldHadTicketAuthority = oldEpoch?.ticketAuthority == true;
    Future<void> projectionDrain = Future<void>.value();
    Future<void> arbiterDrain = Future<void>.value();
    if (oldEpoch != null) {
      _retiringEpoch = oldEpoch;
      projectionDrain = oldEpoch.projection.sealAndDrain();
      arbiterDrain = oldEpoch.arbiter.sealAndDrain();
    }

    final mustLock =
        oldHadTicketAuthority ||
        mode == FeatureRolloutMode.enforce ||
        AvatarProductionOwnership._retirementLocked;
    _phase = mustLock
        ? AvatarProductionAuthorityPhase.drainingLocked
        : mode == FeatureRolloutMode.shadow
        ? AvatarProductionAuthorityPhase.shadow
        : AvatarProductionAuthorityPhase.legacy;

    final transitionEpoch = _controlEpoch;
    _transitionTail = _transitionTail.then<void>(
      (_) => _completeTransition(
        controlEpoch: transitionEpoch,
        retiringEpoch: oldEpoch,
        projectionDrain: projectionDrain,
        arbiterDrain: arbiterDrain,
      ),
      onError: (Object _, StackTrace _) => _completeTransition(
        controlEpoch: transitionEpoch,
        retiringEpoch: oldEpoch,
        projectionDrain: projectionDrain,
        arbiterDrain: arbiterDrain,
      ),
    );
  }

  Future<void> _completeTransition({
    required int controlEpoch,
    required _AvatarProductionEpoch? retiringEpoch,
    required Future<void> projectionDrain,
    required Future<void> arbiterDrain,
  }) async {
    var retirementClean = true;
    await projectionDrain.catchError((Object _, StackTrace _) {});
    try {
      await arbiterDrain;
    } on Object {
      retirementClean = false;
      AvatarProductionOwnership._retirementLocked = true;
    } finally {
      if (identical(_retiringEpoch, retiringEpoch)) _retiringEpoch = null;
    }
    if (_sealed || controlEpoch != _controlEpoch) return;

    final candidate = _createEpoch(controlEpoch);
    final pendingReset = candidate.arbiter.pendingRendererReset;
    if (pendingReset != null) {
      if (!_rendererIsCurrent || !renderer.isReady.value) {
        _epoch = candidate;
        _phase = AvatarProductionAuthorityPhase.failedLocked;
        AvatarProductionOwnership._retirementLocked = true;
        return;
      }
      final expected = _ExpectedAvatarReset(
        authorityEpoch: controlEpoch,
        requirementId: pendingReset.requirementId,
        rendererId: pendingReset.rendererId,
        retiredAccountGeneration: pendingReset.retiredAccountGeneration,
        retiredRendererGeneration: pendingReset.retiredRendererGeneration,
        targetAccountGeneration: accountGeneration,
        targetRendererGeneration: candidate.rendererGeneration,
      );
      _expectedReset = expected;
      try {
        await candidate.arbiter.resetRendererForMount(
          accountGeneration: accountGeneration,
          rendererGeneration: candidate.rendererGeneration,
        );
        _lastAppliedEpoch = candidate;
        retirementClean = true;
      } on Object {
        _epoch = candidate;
        _phase = AvatarProductionAuthorityPhase.failedLocked;
        AvatarProductionOwnership._retirementLocked = true;
        return;
      } finally {
        if (identical(_expectedReset, expected)) _expectedReset = null;
      }
    }
    if (_sealed || controlEpoch != _controlEpoch) {
      unawaited(candidate.sealAndDrain());
      return;
    }

    if (_observedMode == FeatureRolloutMode.enforce) {
      final bound = await candidate.arbiter.bindRenderer(
        accountGeneration: accountGeneration,
        rendererGeneration: candidate.rendererGeneration,
        ready: _rendererIsCurrent && renderer.isReady.value,
        capabilities: _capabilities,
      );
      if (_bindFailed(bound) ||
          candidate.arbiter.pendingRendererReset != null ||
          !_rendererIsCurrent ||
          controlEpoch != _controlEpoch) {
        _epoch = candidate;
        _phase = AvatarProductionAuthorityPhase.failedLocked;
        AvatarProductionOwnership._retirementLocked = true;
        return;
      }
      _epoch = candidate;
      _phase = AvatarProductionAuthorityPhase.enforcing;
      AvatarProductionOwnership._retirementLocked = false;
      await _primeProjection(candidate, ready: renderer.isReady.value);
      return;
    }

    await _primeProjection(
      candidate,
      ready: _rendererIsCurrent && renderer.isReady.value,
    );
    await candidate.arbiter.sealAndDrain();
    if (_sealed || controlEpoch != _controlEpoch) {
      unawaited(candidate.sealAndDrain());
      return;
    }
    _epoch = candidate;
    if (retirementClean && candidate.arbiter.pendingRendererReset == null) {
      AvatarProductionOwnership._retirementLocked = false;
      _phase = _observedMode == FeatureRolloutMode.shadow
          ? AvatarProductionAuthorityPhase.shadow
          : AvatarProductionAuthorityPhase.legacy;
    } else {
      AvatarProductionOwnership._retirementLocked = true;
      _phase = AvatarProductionAuthorityPhase.failedLocked;
    }
  }

  _AvatarProductionEpoch _createEpoch(int controlEpoch) {
    final arbiter = AvatarCommandArbiter(
      accountGeneration: accountGeneration,
      dispatchSink: dispatchSink,
    );
    late final _AvatarProductionEpoch epoch;
    final adapter = _AvatarProjectionArbiterAdapter(
      authority: this,
      arbiter: arbiter,
      controlEpoch: controlEpoch,
    );
    final projection = SelfAvatarProjectionService(
      accountGeneration: accountGeneration,
      mode: () => controlEpoch == _controlEpoch && !_sealed
          ? featureFlags.effectiveMode(MaasoFeatureFlag.avatarProjectionV2)
          : FeatureRolloutMode.off,
      dispatchSink: adapter,
    );
    epoch = _AvatarProductionEpoch(
      controlEpoch: controlEpoch,
      flagGeneration: _observedFlagGeneration,
      rendererGeneration: _rendererGeneration,
      arbiter: arbiter,
      projection: projection,
      adapter: adapter,
    );
    return epoch;
  }

  Future<void> _primeProjection(
    _AvatarProductionEpoch epoch, {
    required bool ready,
  }) async {
    await epoch.projection.bindRenderer(
      accountGeneration: accountGeneration,
      rendererGeneration: epoch.rendererGeneration,
      ready: false,
      sequence: _nextSequence(),
    );
    await epoch.projection.project(
      SelfAvatarEmotionProjectionInput(
        accountGeneration: accountGeneration,
        rendererGeneration: epoch.rendererGeneration,
        sequence: _nextSequence(),
        params: _baseEmotion,
        semanticLabel: _baseEmotionLabel,
        persistent: true,
      ),
    );
    if (_speaking && _speechGeneration > 0) {
      await epoch.projection.project(
        SelfAvatarSpeakingProjectionInput(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          sequence: _nextSequence(),
          isSpeaking: true,
          generation: _speechGeneration,
        ),
      );
      await epoch.projection.project(
        SelfAvatarLipFrameProjectionInput(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          sequence: _nextSequence(),
          amplitude: _lipAmplitude,
          generation: _speechGeneration,
        ),
      );
    }
    await epoch.projection.bindRenderer(
      accountGeneration: accountGeneration,
      rendererGeneration: epoch.rendererGeneration,
      ready: ready,
      sequence: _nextSequence(),
    );
  }

  AvatarCommandCapabilities get _capabilities => AvatarCommandCapabilities(
    supportedChannels: AvatarCommandChannel.values.toSet(),
    supportedBodyGestures: _supportedBodyGestures,
  );

  static bool _bindFailed(List<AvatarCommandReceipt> receipts) => receipts.any(
    (receipt) =>
        receipt.disposition != AvatarCommandReceiptDisposition.dispatched &&
        receipt.disposition != AvatarCommandReceiptDisposition.released,
  );

  bool _allowsCommand(AvatarCommandDispatchOperation operation) {
    _refreshControlFence();
    final dispatch = operation.dispatch;
    if (_sealed && !dispatch.clearsChannel) return false;
    if (dispatch.accountGeneration != accountGeneration) return false;

    final current = _epoch;
    if (_phase == AvatarProductionAuthorityPhase.enforcing &&
        current != null &&
        current.ticketAuthority &&
        current.controlEpoch == _controlEpoch &&
        current.flagGeneration ==
            featureFlags.authorityGeneration(
              MaasoFeatureFlag.avatarProjectionV2,
            ) &&
        featureFlags.effectiveMode(MaasoFeatureFlag.avatarProjectionV2) ==
            FeatureRolloutMode.enforce &&
        dispatch.rendererGeneration == current.rendererGeneration &&
        _rendererIsCurrent) {
      return true;
    }

    final retiring = _retiringEpoch;
    return dispatch.clearsChannel &&
        (_phase == AvatarProductionAuthorityPhase.drainingLocked ||
            _phase == AvatarProductionAuthorityPhase.sealedLocked) &&
        retiring != null &&
        dispatch.rendererGeneration == retiring.rendererGeneration &&
        dispatch.accountGeneration == accountGeneration;
  }

  bool _allowsReset(AvatarRendererResetOperation operation) {
    _refreshControlFence();
    final expected = _expectedReset;
    return !_sealed &&
        (_phase == AvatarProductionAuthorityPhase.drainingLocked ||
            _phase == AvatarProductionAuthorityPhase.failedLocked) &&
        expected != null &&
        expected.authorityEpoch == _controlEpoch &&
        expected.requirementId == operation.requirementId &&
        expected.rendererId == operation.rendererId &&
        expected.retiredAccountGeneration ==
            operation.retiredAccountGeneration &&
        expected.retiredRendererGeneration ==
            operation.retiredRendererGeneration &&
        expected.targetAccountGeneration == operation.targetAccountGeneration &&
        expected.targetRendererGeneration ==
            operation.targetRendererGeneration &&
        operation.targetAccountGeneration == accountGeneration &&
        operation.targetRendererGeneration == _rendererGeneration &&
        _rendererIsCurrent &&
        renderer.isReady.value;
  }

  AvatarProductionBehaviorResult preflightBehavior({String? bodyGesture}) {
    _refreshControlFence();
    final epoch = _epoch;
    if (_phase != AvatarProductionAuthorityPhase.enforcing ||
        epoch == null ||
        !epoch.ticketAuthority) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.authorityStale,
      );
    }
    if (!renderer.isReady.value) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.rendererNotReady,
      );
    }
    final normalizedGesture = bodyGesture?.trim().toLowerCase();
    if (normalizedGesture != null &&
        normalizedGesture.isNotEmpty &&
        !_supportedBodyGestures.contains(normalizedGesture)) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.capabilityUnavailable,
      );
    }
    return const AvatarProductionBehaviorResult(
      AvatarProductionBehaviorDisposition.applied,
    );
  }

  Future<AvatarProductionBehaviorResult> applyBehavior({
    AvatarGaze? gaze,
    bool clearGaze = false,
    String? bodyGesture,
    String? energy,
    double? intensity,
    String? emotion,
    required Duration duration,
    Duration? bodyDuration,
    bool ambient = false,
    bool Function()? shouldContinue,
  }) async {
    final normalizedGesture =
        bodyGesture?.trim().toLowerCase() ?? (energy == null ? null : 'speech');
    // Validate the complete new payload before emitting gaze or any body lease.
    // Old callers continue to emit the exact two-field body payload.
    final bodyCommand = normalizedGesture == null || normalizedGesture.isEmpty
        ? null
        : AvatarBodyGestureCommand(
            normalizedGesture,
            energy: energy,
            intensity: intensity,
            emotion: emotion,
          );
    if (bodyCommand == null &&
        (energy != null || intensity != null || emotion != null)) {
      throw ArgumentError('invalid_avatar_performance_command');
    }
    final admission = preflightBehavior(bodyGesture: normalizedGesture);
    if (!admission.applied) return admission;
    final epoch = _epoch;
    if (epoch == null) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.authorityStale,
      );
    }

    final ttl = Duration(
      milliseconds: duration.inMilliseconds.clamp(350, 5000),
    );
    final bodyTtl = Duration(
      milliseconds: (bodyDuration ?? duration).inMilliseconds.clamp(350, 5000),
    );
    final receipts = <AvatarCommandReceipt>[];
    final ambientGenerations = <AvatarCommandChannel, int>{};
    final explicitGenerations = <AvatarCommandChannel, int>{};
    final source = ambient
        ? AvatarCommandSource.idle
        : AvatarCommandSource.explicitAgent;
    bool isCurrent() => shouldContinue?.call() ?? true;
    Future<AvatarProductionBehaviorResult> interrupted() async {
      // Retire only this request's exact generations. A newer owner is untouched.
      for (final entry in {
        ...ambientGenerations,
        ...explicitGenerations,
      }.entries) {
        await epoch.arbiter.release(
          AvatarCommandReleaseRequest(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            commandGeneration: entry.value,
            channel: entry.key,
            source: source,
          ),
        );
        if (entry.key == AvatarCommandChannel.gaze &&
            epoch.adapter.gazeLeaseGeneration == entry.value) {
          epoch.adapter.gazeLeaseGeneration = null;
        }
      }
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.dispatchFailed,
      );
    }

    if (!isCurrent()) return interrupted();
    // Ambient behavior lets gaze leases expire; it cannot clear explicit gaze.
    if (clearGaze && !ambient) {
      final generation = epoch.adapter.gazeLeaseGeneration;
      if (generation != null) {
        receipts.add(
          await epoch.arbiter.release(
            AvatarCommandReleaseRequest(
              accountGeneration: accountGeneration,
              rendererGeneration: epoch.rendererGeneration,
              commandGeneration: generation,
              channel: AvatarCommandChannel.gaze,
              source: AvatarCommandSource.explicitAgent,
            ),
          ),
        );
        if (!isCurrent()) return interrupted();
        epoch.adapter.gazeLeaseGeneration = null;
      }
    } else if (gaze != null) {
      final generation = _nextCommandGeneration();
      if (ambient) {
        ambientGenerations[AvatarCommandChannel.gaze] = generation;
      } else {
        explicitGenerations[AvatarCommandChannel.gaze] = generation;
      }
      final receipt = await epoch.arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          commandGeneration: generation,
          leaseId: 'behavior-gaze-$generation',
          source: source,
          command: AvatarGazeCommand(gaze),
          ttl: ttl,
        ),
      );
      receipts.add(receipt);
      if (!isCurrent()) return interrupted();
      if (!ambient &&
          receipt.disposition == AvatarCommandReceiptDisposition.dispatched) {
        epoch.adapter.gazeLeaseGeneration = generation;
      }
    }

    if (normalizedGesture != null && normalizedGesture.isNotEmpty) {
      if (!isCurrent()) return interrupted();
      final generation = _nextCommandGeneration();
      if (ambient) {
        ambientGenerations[AvatarCommandChannel.bodyGesture] = generation;
      } else {
        explicitGenerations[AvatarCommandChannel.bodyGesture] = generation;
      }
      final bodyReceipt = await epoch.arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          commandGeneration: generation,
          leaseId: 'behavior-body-$generation',
          source: source,
          command: bodyCommand!,
          ttl: bodyTtl,
        ),
      );
      receipts.add(bodyReceipt);
      if (AvatarFurnitureState.gestures.contains(normalizedGesture) &&
          bodyReceipt.disposition !=
              AvatarCommandReceiptDisposition.dispatched) {
        // A rejected sleep/sit must not spring into action later when an
        // unrelated gesture expires or after the user starts talking.
        await epoch.arbiter.release(
          AvatarCommandReleaseRequest(
            accountGeneration: accountGeneration,
            rendererGeneration: epoch.rendererGeneration,
            commandGeneration: generation,
            channel: AvatarCommandChannel.bodyGesture,
            source: source,
          ),
        );
      }
      if (!isCurrent()) return interrupted();
    }

    if (receipts.isEmpty) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.capabilityUnavailable,
      );
    }
    if (receipts.every(
      (receipt) =>
          receipt.disposition == AvatarCommandReceiptDisposition.dispatched,
    )) {
      _lastAppliedEpoch = epoch;
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.applied,
      );
    }
    if (receipts.any(
      (receipt) =>
          receipt.disposition ==
          AvatarCommandReceiptDisposition.rendererNotReady,
    )) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.rendererNotReady,
      );
    }
    if (receipts.any(
      (receipt) =>
          receipt.disposition ==
              AvatarCommandReceiptDisposition.capabilityUnavailable ||
          receipt.disposition ==
              AvatarCommandReceiptDisposition.capabilityFallback,
    )) {
      return const AvatarProductionBehaviorResult(
        AvatarProductionBehaviorDisposition.capabilityUnavailable,
      );
    }
    return const AvatarProductionBehaviorResult(
      AvatarProductionBehaviorDisposition.dispatchFailed,
    );
  }

  /// Host-owned work uses the existing ticketed body channel. Exact session
  /// binding is checked again by Unity before a stop can move any furniture.
  Future<AvatarProductionBehaviorResult> applyBackgroundTaskWork({
    required String sessionId,
    required AvatarBackgroundTaskWorkPhase phase,
    required bool Function() shouldContinue,
  }) async {
    final gesture = phase == AvatarBackgroundTaskWorkPhase.start
        ? 'work_desk'
        : 'stand_up';
    final command = AvatarBodyGestureCommand(
      gesture,
      workSessionId: sessionId,
      workPhase: phase,
    );
    final admission = preflightBehavior(bodyGesture: gesture);
    if (!admission.applied) return admission;
    final epoch = _epoch;
    if (epoch == null || !shouldContinue()) return _staleCamera;
    final generation = _nextCommandGeneration();
    final receipt = await epoch.arbiter.acquire(
      AvatarCommandLeaseRequest(
        accountGeneration: accountGeneration,
        rendererGeneration: epoch.rendererGeneration,
        commandGeneration: generation,
        leaseId: 'task-work-$generation',
        source: AvatarCommandSource.explicitAgent,
        command: command,
        ttl: phase == AvatarBackgroundTaskWorkPhase.start
            ? _projectionLeaseTtl
            : const Duration(milliseconds: 350),
      ),
    );
    if (phase == AvatarBackgroundTaskWorkPhase.start &&
        receipt.disposition == AvatarCommandReceiptDisposition.dispatched) {
      _backgroundWorkLeases[sessionId] = (epoch: epoch, generation: generation);
    }
    if (phase == AvatarBackgroundTaskWorkPhase.end ||
        receipt.disposition != AvatarCommandReceiptDisposition.dispatched ||
        !shouldContinue()) {
      // Never retain a rejected start behind a user's higher-priority pose.
      await epoch.arbiter.release(
        AvatarCommandReleaseRequest(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          commandGeneration: generation,
          channel: AvatarCommandChannel.bodyGesture,
          source: AvatarCommandSource.explicitAgent,
        ),
      );
    }
    return _cameraResult(receipt);
  }

  /// Removes only the start's exact lease. A user-owned replacement posture
  /// never receives a stand-up or a clear for its different generation.
  Future<void> releaseBackgroundTaskWorkLease(String sessionId) async {
    final lease = _backgroundWorkLeases.remove(sessionId);
    if (lease == null) return;
    await lease.epoch.arbiter.release(
      AvatarCommandReleaseRequest(
        accountGeneration: accountGeneration,
        rendererGeneration: lease.epoch.rendererGeneration,
        commandGeneration: lease.generation,
        channel: AvatarCommandChannel.bodyGesture,
        source: AvatarCommandSource.explicitAgent,
      ),
    );
  }

  /// The camera director's single framing lane. Source changes retire only its
  /// own exact lease; scene or behavior owners are never cleared by this API.
  Future<AvatarProductionBehaviorResult> applyCameraFraming({
    required String mode,
    required AvatarCommandSource source,
    bool Function()? shouldContinue,
  }) {
    if (!const {
          'head',
          'upper_body',
          'hero_full_body',
          'sleeping_top',
          'desk_over_shoulder',
        }.contains(mode) ||
        !const {
          AvatarCommandSource.explicitUser,
          AvatarCommandSource.auto,
          AvatarCommandSource.idle,
        }.contains(source)) {
      return Future.value(
        const AvatarProductionBehaviorResult(
          AvatarProductionBehaviorDisposition.capabilityUnavailable,
        ),
      );
    }
    return _enqueueCamera(() async {
      final admission = preflightBehavior();
      if (!admission.applied) return admission;
      final epoch = _epoch!;
      bool current() =>
          _cameraEpochIsCurrent(epoch) && (shouldContinue?.call() ?? true);
      if (!current()) return _staleCamera;

      // Renderer-ready may have emitted a legacy scene/full lease before the
      // director became active. Retire that adapter's exact lease on takeover.
      final legacy = await epoch.adapter.releaseManagedLegacyFraming();
      if (!current()) return _staleCamera;
      if (legacy != null && !_cameraReleaseSucceeded(legacy)) {
        return _cameraResult(legacy);
      }
      final previous = _cameraLease;
      if (previous != null &&
          (!identical(previous.epoch, epoch) || previous.source != source)) {
        final released = await _releaseCameraLease(previous);
        if (!current()) return _staleCamera;
        if (!released.applied && identical(previous.epoch, epoch)) {
          return released;
        }
      }

      final lease = _ProductionCameraLease(
        epoch: epoch,
        source: source,
        generation: _nextCommandGeneration(),
      );
      final receipt = await epoch.arbiter.acquire(
        AvatarCommandLeaseRequest(
          accountGeneration: accountGeneration,
          rendererGeneration: epoch.rendererGeneration,
          commandGeneration: lease.generation,
          leaseId: 'camera-${lease.generation}',
          source: source,
          command: AvatarFramingCommand(mode),
          ttl: _projectionLeaseTtl,
        ),
      );
      // A retained lease is still owned and must be releasable. Failed receipts
      // may also have installed a lease before renderer admission failed.
      _cameraLease = lease;
      if (!current()) {
        await _releaseCameraLease(lease);
        return _staleCamera;
      }
      final result = _cameraResult(receipt);
      if (result.applied) _lastAppliedEpoch = epoch;
      return result;
    });
  }

  Future<AvatarProductionBehaviorResult> releaseCameraFraming() =>
      _enqueueCamera(() async {
        final lease = _cameraLease;
        if (lease == null) return _releasedCamera;
        return _releaseCameraLease(lease);
      });

  Future<AvatarProductionBehaviorResult> _enqueueCamera(
    Future<AvatarProductionBehaviorResult> Function() operation,
  ) {
    final result = _cameraTail
        .then((_) => operation())
        .catchError(
          (Object _, StackTrace _) => const AvatarProductionBehaviorResult(
            AvatarProductionBehaviorDisposition.dispatchFailed,
          ),
        );
    _cameraTail = result.then<void>((_) {});
    return result;
  }

  bool _cameraEpochIsCurrent(_AvatarProductionEpoch epoch) {
    _refreshControlFence();
    return !_sealed &&
        identical(_epoch, epoch) &&
        epoch.controlEpoch == _controlEpoch &&
        epoch.ticketAuthority &&
        _phase == AvatarProductionAuthorityPhase.enforcing &&
        _rendererIsCurrent &&
        renderer.isReady.value;
  }

  Future<AvatarProductionBehaviorResult> _releaseCameraLease(
    _ProductionCameraLease lease,
  ) async {
    if (!_cameraEpochIsCurrent(lease.epoch)) {
      if (identical(_cameraLease, lease)) _cameraLease = null;
      // The retired epoch's existing drain owns its neutral clear.
      return _staleCamera;
    }
    final receipt = await lease.epoch.arbiter.release(
      AvatarCommandReleaseRequest(
        accountGeneration: accountGeneration,
        rendererGeneration: lease.epoch.rendererGeneration,
        commandGeneration: lease.generation,
        channel: AvatarCommandChannel.framing,
        source: lease.source,
      ),
    );
    if (!_cameraEpochIsCurrent(lease.epoch)) return _staleCamera;
    if (_cameraReleaseSucceeded(receipt)) {
      if (identical(_cameraLease, lease)) _cameraLease = null;
      return _releasedCamera;
    }
    return _cameraResult(receipt);
  }

  static bool _cameraReleaseSucceeded(AvatarCommandReceipt receipt) =>
      receipt.disposition == AvatarCommandReceiptDisposition.released ||
      receipt.disposition ==
          AvatarCommandReceiptDisposition.retainedBehindHigherPriority ||
      receipt.disposition == AvatarCommandReceiptDisposition.noLease ||
      receipt.disposition ==
          AvatarCommandReceiptDisposition.rejectedStaleCommand;

  static AvatarProductionBehaviorResult _cameraResult(
    AvatarCommandReceipt receipt,
  ) => AvatarProductionBehaviorResult(switch (receipt.disposition) {
    AvatarCommandReceiptDisposition.dispatched =>
      AvatarProductionBehaviorDisposition.applied,
    AvatarCommandReceiptDisposition.retainedBehindHigherPriority =>
      AvatarProductionBehaviorDisposition.retainedBehindHigherPriority,
    AvatarCommandReceiptDisposition.rendererNotReady =>
      AvatarProductionBehaviorDisposition.rendererNotReady,
    AvatarCommandReceiptDisposition.capabilityUnavailable ||
    AvatarCommandReceiptDisposition.capabilityFallback ||
    AvatarCommandReceiptDisposition.rejectedInvalidSource ||
    AvatarCommandReceiptDisposition.rejectedInvalidCommand =>
      AvatarProductionBehaviorDisposition.capabilityUnavailable,
    AvatarCommandReceiptDisposition.rejectedStaleAccount ||
    AvatarCommandReceiptDisposition.rejectedStaleRenderer ||
    AvatarCommandReceiptDisposition.rejectedStaleCommand ||
    AvatarCommandReceiptDisposition.rejectedSealed ||
    AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter ||
    AvatarCommandReceiptDisposition.rendererResetRequired =>
      AvatarProductionBehaviorDisposition.authorityStale,
    _ => AvatarProductionBehaviorDisposition.dispatchFailed,
  });

  static const _staleCamera = AvatarProductionBehaviorResult(
    AvatarProductionBehaviorDisposition.authorityStale,
  );
  static const _releasedCamera = AvatarProductionBehaviorResult(
    AvatarProductionBehaviorDisposition.applied,
  );

  int _nextSequence() => ++_sequence;
  int _nextCommandGeneration() => ++_commandGeneration;

  Future<void> waitForIdle() async {
    await _transitionTail;
    await _cameraTail;
    final epoch = _epoch;
    if (epoch == null) return;
    await epoch.projection.waitForIdle();
    await epoch.arbiter.waitForIdle();
  }

  Future<void> sealAndDrain() {
    final current = _sealFuture;
    if (current != null) return current;
    _sealed = true;
    _hostTaskWorkAuthorityGeneration++;
    _unregisterSoundStopper?.call();
    _unregisterSoundStopper = null;
    _phase = AvatarProductionAuthorityPhase.sealedLocked;
    _controlEpoch += 1;
    for (final subscription in _eventSubscriptions) {
      unawaited(subscription.cancel());
    }
    _eventSubscriptions.clear();
    _flagWorker?.dispose();
    _backendWorker?.dispose();
    _readyWorker?.dispose();
    final activeEpoch = _epoch ?? _retiringEpoch;
    final projectionEpoch = activeEpoch ?? _createEpoch(_controlEpoch);
    final resetAnchor = _lastAppliedEpoch ?? activeEpoch ?? projectionEpoch;
    _epoch = null;
    _retiringEpoch = activeEpoch ?? resetAnchor;
    final projectionDrain = projectionEpoch.projection.sealAndDrain();
    final arbiterDrain = _sealAccountRendererOwnership(
      activeEpoch: activeEpoch,
      resetAnchor: resetAnchor,
    );
    final draining = _sealAndDrainOnce(projectionDrain, arbiterDrain);
    _sealFuture = draining;
    return draining;
  }

  Future<void> _sealAccountRendererOwnership({
    required _AvatarProductionEpoch? activeEpoch,
    required _AvatarProductionEpoch resetAnchor,
  }) async {
    if (activeEpoch == null || identical(activeEpoch, resetAnchor)) {
      await resetAnchor.arbiter.sealAndDrain(
        requireRendererResetForNextOwner: true,
      );
      return;
    }
    await activeEpoch.arbiter.sealAndDrain();
    await resetAnchor.arbiter.sealAndDrain(
      requireRendererResetForNextOwner: true,
    );
  }

  Future<void> _sealAndDrainOnce(
    Future<void> projectionDrain,
    Future<void> arbiterDrain,
  ) async {
    try {
      await _transitionTail;
      await projectionDrain;
      await arbiterDrain;
      _retiringEpoch = null;
      _drainSucceeded = true;
      AvatarProductionOwnership._retirementLocked = true;
      AvatarProductionOwnership._uninstall(this);
    } on Object {
      _drainSucceeded = false;
      AvatarProductionOwnership._retirementLocked = true;
      rethrow;
    }
  }

  @override
  void onClose() {
    unawaited(sealAndDrain().catchError((Object _, StackTrace _) {}));
    if (_drainSucceeded) AvatarProductionOwnership._uninstall(this);
    super.onClose();
  }
}

final class _AvatarProductionEpoch {
  const _AvatarProductionEpoch({
    required this.controlEpoch,
    required this.flagGeneration,
    required this.rendererGeneration,
    required this.arbiter,
    required this.projection,
    required this.adapter,
  });

  final int controlEpoch;
  final int flagGeneration;
  final int rendererGeneration;
  final AvatarCommandArbiter arbiter;
  final SelfAvatarProjectionService projection;
  final _AvatarProjectionArbiterAdapter adapter;

  bool get ticketAuthority => !arbiter.isSealed;

  Future<void> sealAndDrain({bool requireResetForNextOwner = false}) async {
    await projection.sealAndDrain();
    await arbiter.sealAndDrain(
      requireRendererResetForNextOwner: requireResetForNextOwner,
    );
  }
}

final class _ProductionCameraLease {
  const _ProductionCameraLease({
    required this.epoch,
    required this.source,
    required this.generation,
  });

  final _AvatarProductionEpoch epoch;
  final AvatarCommandSource source;
  final int generation;
}

final class _ExpectedAvatarReset {
  const _ExpectedAvatarReset({
    required this.authorityEpoch,
    required this.requirementId,
    required this.rendererId,
    required this.retiredAccountGeneration,
    required this.retiredRendererGeneration,
    required this.targetAccountGeneration,
    required this.targetRendererGeneration,
  });

  final int authorityEpoch;
  final int requirementId;
  final String rendererId;
  final int retiredAccountGeneration;
  final int retiredRendererGeneration;
  final int targetAccountGeneration;
  final int targetRendererGeneration;
}

final class _AvatarProjectionArbiterAdapter
    implements SelfAvatarProjectionDispatchSink {
  _AvatarProjectionArbiterAdapter({
    required this.authority,
    required this.arbiter,
    required this.controlEpoch,
  });

  final AvatarProjectionProductionAuthority authority;
  final AvatarCommandArbiter arbiter;
  final int controlEpoch;
  int? mouthLeaseGeneration;
  int? gazeLeaseGeneration;
  int? legacyFramingLeaseGeneration;

  Future<AvatarCommandReceipt?> releaseManagedLegacyFraming() async {
    if (!(authority.cameraFramingIsManaged?.call() ?? false)) return null;
    final generation = legacyFramingLeaseGeneration;
    if (generation == null) return null;
    final receipt = await arbiter.release(
      AvatarCommandReleaseRequest(
        accountGeneration: authority.accountGeneration,
        rendererGeneration: authority._rendererGeneration,
        commandGeneration: generation,
        channel: AvatarCommandChannel.framing,
        source: AvatarCommandSource.scene,
      ),
    );
    if (AvatarProjectionProductionAuthority._cameraReleaseSucceeded(receipt) &&
        legacyFramingLeaseGeneration == generation) {
      legacyFramingLeaseGeneration = null;
    }
    return receipt;
  }

  @override
  Future<void> dispatch(SelfAvatarProjectionDispatch dispatch) async {
    if (controlEpoch != authority._controlEpoch ||
        authority._phase != AvatarProductionAuthorityPhase.enforcing ||
        !identical(authority._epoch?.adapter, this)) {
      throw StateError('avatar_projection_authority_stale');
    }
    final rendererGeneration = authority._rendererGeneration;
    final receipts = <AvatarCommandReceipt>[];

    if (dispatch.stopLipSync) {
      final generation = mouthLeaseGeneration;
      if (generation != null) {
        receipts.add(
          await arbiter.release(
            AvatarCommandReleaseRequest(
              accountGeneration: authority.accountGeneration,
              rendererGeneration: rendererGeneration,
              commandGeneration: generation,
              channel: AvatarCommandChannel.mouth,
              source: AvatarCommandSource.ttsMouth,
            ),
          ),
        );
        mouthLeaseGeneration = null;
      }
    }
    if (dispatch.lipEnvelope.isNotEmpty) {
      final generation = authority._nextCommandGeneration();
      receipts.add(
        await _acquire(
          generation: generation,
          source: AvatarCommandSource.ttsMouth,
          command: AvatarLipEnvelopeCommand(
            dispatch.lipEnvelope,
            frameRate: dispatch.lipFrameRate ?? 30,
          ),
          leaseId: 'tts-envelope-$generation',
        ),
      );
      mouthLeaseGeneration = generation;
    } else if (dispatch.mouthOpen != null) {
      final generation = authority._nextCommandGeneration();
      receipts.add(
        await _acquire(
          generation: generation,
          source: AvatarCommandSource.ttsMouth,
          command: AvatarMouthCommand(dispatch.mouthOpen!),
          leaseId: 'tts-mouth-$generation',
        ),
      );
      mouthLeaseGeneration = generation;
    }
    if (dispatch.visemeTrack != null) {
      final generation = authority._nextCommandGeneration();
      receipts.add(
        await _acquire(
          generation: generation,
          source: AvatarCommandSource.ttsMouth,
          command: AvatarVisemeTrackCommand(dispatch.visemeTrack!),
          leaseId: 'tts-viseme-$generation',
        ),
      );
      mouthLeaseGeneration = generation;
    }
    if (dispatch.speechPlaybackClock != null) {
      final generation = authority._nextCommandGeneration();
      receipts.add(
        await _acquire(
          generation: generation,
          source: AvatarCommandSource.ttsMouth,
          command: AvatarSpeechPlaybackClockCommand(
            dispatch.speechPlaybackClock!,
          ),
          leaseId: 'tts-clock-$generation',
        ),
      );
      mouthLeaseGeneration = generation;
    }
    if (dispatch.expression != null) {
      final generation = authority._nextCommandGeneration();
      receipts.add(
        await _acquire(
          generation: generation,
          source: AvatarCommandSource.auto,
          command: AvatarExpressionCommand(dispatch.expression!),
          leaseId: 'expression-$generation',
        ),
      );
    }
    final cameraManaged = authority.cameraFramingIsManaged?.call() ?? false;
    if (cameraManaged) {
      final released = await releaseManagedLegacyFraming();
      if (released != null &&
          !AvatarProjectionProductionAuthority._cameraReleaseSucceeded(
            released,
          )) {
        receipts.add(released);
      }
    } else if (dispatch.framing != null) {
      final generation = authority._nextCommandGeneration();
      legacyFramingLeaseGeneration = generation;
      receipts.add(
        await _acquire(
          generation: generation,
          source: AvatarCommandSource.scene,
          command: AvatarFramingCommand(dispatch.framing!),
          leaseId: 'framing-$generation',
        ),
      );
    }

    if ((receipts.isEmpty && !(cameraManaged && dispatch.framing != null)) ||
        receipts.any(
          (receipt) =>
              receipt.disposition !=
                  AvatarCommandReceiptDisposition.dispatched &&
              receipt.disposition != AvatarCommandReceiptDisposition.released &&
              receipt.disposition !=
                  AvatarCommandReceiptDisposition.retainedBehindHigherPriority,
        )) {
      throw StateError('avatar_projection_dispatch_not_applied');
    }
    authority._lastAppliedEpoch = authority._epoch;
  }

  Future<AvatarCommandReceipt> _acquire({
    required int generation,
    required AvatarCommandSource source,
    required AvatarChannelCommand command,
    required String leaseId,
  }) => arbiter.acquire(
    AvatarCommandLeaseRequest(
      accountGeneration: authority.accountGeneration,
      rendererGeneration: authority._rendererGeneration,
      commandGeneration: generation,
      leaseId: leaseId,
      source: source,
      command: command,
      ttl: AvatarProjectionProductionAuthority._projectionLeaseTtl,
    ),
  );
}
