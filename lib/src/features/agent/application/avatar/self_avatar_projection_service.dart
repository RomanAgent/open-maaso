import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_emotion_timeline.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/emotion_to_avatar.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';
import 'package:maaso/src/features/agent/data/models/emotion_params.dart';

typedef SelfAvatarProjectionMode = FeatureRolloutMode Function();

enum SelfAvatarProjectionInputKind {
  emotion,
  emotionRestore,
  meme,
  speakingStarted,
  speakingStopped,
  lipFrame,
  lipEnvelope,
  visemeTrack,
  speechPlaybackClock,
  rendererReady,
}

enum SelfAvatarProjectionChannel { expression, mouth, lipSync, framing }

enum SelfAvatarProjectionDisposition {
  legacyPreserved,
  shadowMatched,
  shadowDiverged,
  shadowUnavailable,
  enforced,
  rendererNotReady,
  rejectedStaleAccount,
  rejectedStaleRenderer,
  rejectedStaleSequence,
  rejectedStaleSpeech,
  rejectedInvalidInput,
  rejectedSealed,
  dispatchFailed,
}

/// One bounded, payload-free observation of a projection decision.
///
/// [fingerprint] is a truncated digest of normalized renderer commands. It
/// never contains account identifiers, meme URLs, raw text, or lip envelopes.
final class SelfAvatarProjectionReceipt {
  const SelfAvatarProjectionReceipt({
    required this.inputKind,
    required this.disposition,
    required this.mode,
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.sequence,
    required this.speechGeneration,
    required this.fingerprint,
    required this.commandCount,
    required this.channels,
  });

  final SelfAvatarProjectionInputKind inputKind;
  final SelfAvatarProjectionDisposition disposition;
  final FeatureRolloutMode mode;
  final int accountGeneration;
  final int rendererGeneration;
  final int sequence;
  final int? speechGeneration;
  final String fingerprint;
  final int commandCount;
  final Set<SelfAvatarProjectionChannel> channels;
}

/// Bounded summary given to the shadow comparator.
///
/// Production wiring can compare this fingerprint with an observation emitted
/// by the legacy owner without exposing the renderer payload to metrics.
final class SelfAvatarProjectionPlanSummary {
  const SelfAvatarProjectionPlanSummary({
    required this.inputKind,
    required this.sequence,
    required this.fingerprint,
    required this.commandCount,
    required this.channels,
  });

  final SelfAvatarProjectionInputKind inputKind;
  final int sequence;
  final String fingerprint;
  final int commandCount;
  final Set<SelfAvatarProjectionChannel> channels;
}

enum SelfAvatarProjectionShadowComparison { matched, diverged, unavailable }

abstract interface class SelfAvatarProjectionShadowComparator {
  Future<SelfAvatarProjectionShadowComparison> compare(
    SelfAvatarProjectionPlanSummary candidate,
  );
}

/// Renderer-neutral batch produced by one projection input.
///
/// The eventual ActiveAvatarRuntime adapter is the only layer that should map
/// this batch to renderer calls. Tests inject a recording sink instead.
final class SelfAvatarProjectionDispatch {
  SelfAvatarProjectionDispatch({
    required this.inputKind,
    required this.sequence,
    this.expression,
    this.mouthOpen,
    List<double> lipEnvelope = const <double>[],
    this.lipFrameRate,
    this.visemeTrack,
    this.speechPlaybackClock,
    this.stopLipSync = false,
    this.framing,
  }) : lipEnvelope = List<double>.unmodifiable(lipEnvelope);

  final SelfAvatarProjectionInputKind inputKind;
  final int sequence;
  final AvatarExpressionParams? expression;
  final double? mouthOpen;
  final List<double> lipEnvelope;
  final int? lipFrameRate;
  final LipSyncVisemeTrack? visemeTrack;
  final SpeechPlaybackClock? speechPlaybackClock;
  final bool stopLipSync;
  final String? framing;

  int get commandCount =>
      (expression == null ? 0 : 1) +
      (mouthOpen == null ? 0 : 1) +
      (lipEnvelope.isEmpty ? 0 : 1) +
      (visemeTrack == null ? 0 : 1) +
      (speechPlaybackClock == null ? 0 : 1) +
      (stopLipSync ? 1 : 0) +
      (framing == null ? 0 : 1);

  Set<SelfAvatarProjectionChannel> get channels =>
      Set<SelfAvatarProjectionChannel>.unmodifiable({
        if (expression != null) SelfAvatarProjectionChannel.expression,
        if (mouthOpen != null) SelfAvatarProjectionChannel.mouth,
        if (lipEnvelope.isNotEmpty ||
            visemeTrack != null ||
            speechPlaybackClock != null ||
            stopLipSync)
          SelfAvatarProjectionChannel.lipSync,
        if (framing != null) SelfAvatarProjectionChannel.framing,
      });
}

abstract interface class SelfAvatarProjectionDispatchSink {
  Future<void> dispatch(SelfAvatarProjectionDispatch command);
}

sealed class SelfAvatarProjectionInput {
  const SelfAvatarProjectionInput({
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.sequence,
  }) : assert(accountGeneration >= 0),
       assert(rendererGeneration >= 0),
       assert(sequence > 0);

  final int accountGeneration;
  final int rendererGeneration;
  final int sequence;

  SelfAvatarProjectionInputKind get kind;
  int? get speechGeneration => null;
}

final class SelfAvatarEmotionProjectionInput extends SelfAvatarProjectionInput {
  const SelfAvatarEmotionProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
    required this.params,
    this.duration,
    this.semanticLabel,
    this.persistent = false,
    this.automatic = false,
  });

  final EmotionParams params;
  final Duration? duration;
  final String? semanticLabel;
  final bool persistent;
  final bool automatic;

  @override
  SelfAvatarProjectionInputKind get kind =>
      SelfAvatarProjectionInputKind.emotion;
}

final class SelfAvatarEmotionResetProjectionInput
    extends SelfAvatarProjectionInput {
  const SelfAvatarEmotionResetProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
  });

  @override
  SelfAvatarProjectionInputKind get kind =>
      SelfAvatarProjectionInputKind.emotionRestore;
}

final class SelfAvatarMemeProjectionInput extends SelfAvatarProjectionInput {
  const SelfAvatarMemeProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
  });

  @override
  SelfAvatarProjectionInputKind get kind => SelfAvatarProjectionInputKind.meme;
}

final class SelfAvatarSpeakingProjectionInput
    extends SelfAvatarProjectionInput {
  const SelfAvatarSpeakingProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
    required this.isSpeaking,
    required this.generation,
  }) : assert(generation > 0);

  final bool isSpeaking;
  final int generation;

  @override
  int get speechGeneration => generation;

  @override
  SelfAvatarProjectionInputKind get kind => isSpeaking
      ? SelfAvatarProjectionInputKind.speakingStarted
      : SelfAvatarProjectionInputKind.speakingStopped;
}

final class SelfAvatarLipFrameProjectionInput
    extends SelfAvatarProjectionInput {
  const SelfAvatarLipFrameProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
    required this.amplitude,
    required this.generation,
  }) : assert(generation > 0);

  final double amplitude;
  final int generation;

  @override
  int get speechGeneration => generation;

  @override
  SelfAvatarProjectionInputKind get kind =>
      SelfAvatarProjectionInputKind.lipFrame;
}

final class SelfAvatarLipEnvelopeProjectionInput
    extends SelfAvatarProjectionInput {
  SelfAvatarLipEnvelopeProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
    required List<double> envelope,
    required this.frameRate,
    required this.generation,
  }) : envelope = List<double>.unmodifiable(envelope) {
    if (generation <= 0) {
      throw ArgumentError.value(generation, 'generation', 'must be positive');
    }
    if (frameRate < 1 || frameRate > 120) {
      throw ArgumentError.value(
        frameRate,
        'frameRate',
        'must be within 1..120',
      );
    }
    if (envelope.isEmpty || envelope.length > maximumEnvelopeFrames) {
      throw ArgumentError.value(
        envelope.length,
        'envelope.length',
        'must be within 1..$maximumEnvelopeFrames',
      );
    }
  }

  static const int maximumEnvelopeFrames = 7200;

  final List<double> envelope;
  final int frameRate;
  final int generation;

  @override
  int get speechGeneration => generation;

  @override
  SelfAvatarProjectionInputKind get kind =>
      SelfAvatarProjectionInputKind.lipEnvelope;
}

final class SelfAvatarVisemeTrackProjectionInput
    extends SelfAvatarProjectionInput {
  const SelfAvatarVisemeTrackProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
    required this.track,
    required this.generation,
  }) : assert(generation > 0);

  final LipSyncVisemeTrack track;
  final int generation;

  @override
  int get speechGeneration => generation;

  @override
  SelfAvatarProjectionInputKind get kind =>
      SelfAvatarProjectionInputKind.visemeTrack;
}

final class SelfAvatarSpeechPlaybackClockProjectionInput
    extends SelfAvatarProjectionInput {
  const SelfAvatarSpeechPlaybackClockProjectionInput({
    required super.accountGeneration,
    required super.rendererGeneration,
    required super.sequence,
    required this.clock,
  });

  final SpeechPlaybackClock clock;

  @override
  SelfAvatarProjectionInputKind get kind =>
      SelfAvatarProjectionInputKind.speechPlaybackClock;
}

/// Account-scoped, renderer-neutral state machine for self-avatar projection.
///
/// This foundation deliberately does not subscribe to EventBus or resolve
/// ActiveAvatarRuntime. Commit A's wiring adapters will translate existing
/// events into [SelfAvatarProjectionInput] and provide the dispatch sink.
final class SelfAvatarProjectionService extends AppService {
  SelfAvatarProjectionService({
    required int accountGeneration,
    required SelfAvatarProjectionMode mode,
    required SelfAvatarProjectionDispatchSink dispatchSink,
    SelfAvatarProjectionShadowComparator? shadowComparator,
  }) : _accountGeneration = accountGeneration,
       _mode = mode,
       _dispatchSink = dispatchSink,
       _shadowComparator = shadowComparator {
    if (accountGeneration < 0) {
      throw ArgumentError.value(
        accountGeneration,
        'accountGeneration',
        'must not be negative',
      );
    }
  }

  static const int maximumRecentReceipts = 64;

  final int _accountGeneration;
  final SelfAvatarProjectionMode _mode;
  final SelfAvatarProjectionDispatchSink _dispatchSink;
  final SelfAvatarProjectionShadowComparator? _shadowComparator;
  final StreamController<SelfAvatarProjectionReceipt> _receiptController =
      StreamController<SelfAvatarProjectionReceipt>.broadcast(sync: true);
  final ListQueue<SelfAvatarProjectionReceipt> _recentReceipts =
      ListQueue<SelfAvatarProjectionReceipt>(maximumRecentReceipts);

  Future<void> _mutationTail = Future<void>.value();
  late final AvatarEmotionTimeline _emotions = AvatarEmotionTimeline(
    onRestored: _queueEmotionRestore,
  );
  bool _speaking = false;
  double _lipAmplitude = 0;
  int _speechGeneration = 0;
  int _rendererGeneration = 0;
  int _lastSequence = 0;
  bool _rendererReady = false;
  bool _sealed = false;
  bool _receiptStreamClosed = false;

  int get accountGeneration => _accountGeneration;
  int get rendererGeneration => _rendererGeneration;
  int get speechGeneration => _speechGeneration;
  bool get isSealed => _sealed;
  bool get rendererReady => _rendererReady;

  Stream<SelfAvatarProjectionReceipt> get receipts => _receiptController.stream;

  List<SelfAvatarProjectionReceipt> get recentReceipts =>
      List<SelfAvatarProjectionReceipt>.unmodifiable(_recentReceipts);

  Future<SelfAvatarProjectionReceipt> bindRenderer({
    required int accountGeneration,
    required int rendererGeneration,
    required bool ready,
    required int sequence,
  }) {
    if (rendererGeneration < 0) {
      throw ArgumentError.value(rendererGeneration, 'rendererGeneration');
    }
    if (sequence <= 0) throw ArgumentError.value(sequence, 'sequence');
    if (_sealed || isClosed) {
      return Future<SelfAvatarProjectionReceipt>.value(
        _emitRejected(
          inputKind: SelfAvatarProjectionInputKind.rendererReady,
          disposition: SelfAvatarProjectionDisposition.rejectedSealed,
          mode: FeatureRolloutMode.off,
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
          sequence: sequence,
        ),
      );
    }
    if (accountGeneration < 0 || sequence <= 0) {
      return Future<SelfAvatarProjectionReceipt>.value(
        _emitRejected(
          inputKind: SelfAvatarProjectionInputKind.rendererReady,
          disposition: SelfAvatarProjectionDisposition.rejectedInvalidInput,
          mode: _effectiveMode(),
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
          sequence: sequence,
        ),
      );
    }
    return _enqueue(
      () => _bindRenderer(
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        ready: ready,
        sequence: sequence,
      ),
    );
  }

  Future<SelfAvatarProjectionReceipt> project(SelfAvatarProjectionInput input) {
    if (_sealed || isClosed) {
      return Future<SelfAvatarProjectionReceipt>.value(
        _emitRejected(
          inputKind: input.kind,
          disposition: SelfAvatarProjectionDisposition.rejectedSealed,
          mode: FeatureRolloutMode.off,
          accountGeneration: input.accountGeneration,
          rendererGeneration: input.rendererGeneration,
          sequence: input.sequence,
          speechGeneration: input.speechGeneration,
        ),
      );
    }
    if (!_isInputWellFormed(input)) {
      return Future<SelfAvatarProjectionReceipt>.value(
        _emitRejected(
          inputKind: input.kind,
          disposition: SelfAvatarProjectionDisposition.rejectedInvalidInput,
          mode: _effectiveMode(),
          accountGeneration: input.accountGeneration,
          rendererGeneration: input.rendererGeneration,
          sequence: input.sequence,
          speechGeneration: input.speechGeneration,
        ),
      );
    }
    return _enqueue(() => _project(input));
  }

  Future<void> waitForIdle() => _mutationTail;

  Future<void> sealAndDrain() async {
    _sealed = true;
    _emotions.close();
    await _mutationTail;
  }

  Future<SelfAvatarProjectionReceipt> _enqueue(
    Future<SelfAvatarProjectionReceipt> Function() operation,
  ) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<SelfAvatarProjectionReceipt> _bindRenderer({
    required int accountGeneration,
    required int rendererGeneration,
    required bool ready,
    required int sequence,
  }) async {
    final mode = _effectiveMode();
    if (accountGeneration != _accountGeneration) {
      return _emitRejected(
        inputKind: SelfAvatarProjectionInputKind.rendererReady,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleAccount,
        mode: mode,
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        sequence: sequence,
      );
    }
    if (rendererGeneration < _rendererGeneration) {
      return _emitRejected(
        inputKind: SelfAvatarProjectionInputKind.rendererReady,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleRenderer,
        mode: mode,
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        sequence: sequence,
      );
    }
    if (sequence <= _lastSequence) {
      return _emitRejected(
        inputKind: SelfAvatarProjectionInputKind.rendererReady,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleSequence,
        mode: mode,
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        sequence: sequence,
      );
    }

    final generationChanged = rendererGeneration != _rendererGeneration;
    final becameReady = ready && (generationChanged || !_rendererReady);
    _lastSequence = sequence;
    _rendererGeneration = rendererGeneration;
    _rendererReady = ready;
    if (generationChanged || !ready) {
      _emotions.cancelTransient(notify: false);
    }
    if (generationChanged) _lipAmplitude = 0;
    final dispatch = SelfAvatarProjectionDispatch(
      inputKind: SelfAvatarProjectionInputKind.rendererReady,
      sequence: sequence,
      expression: becameReady ? _expression : null,
      mouthOpen: becameReady && _speaking ? _visibleMouthOpen : null,
      framing: becameReady ? 'full' : null,
    );
    return _applyMode(
      mode: mode,
      inputKind: SelfAvatarProjectionInputKind.rendererReady,
      sequence: sequence,
      dispatch: dispatch,
    );
  }

  Future<SelfAvatarProjectionReceipt> _project(
    SelfAvatarProjectionInput input,
  ) async {
    final mode = _effectiveMode();
    if (input.accountGeneration != _accountGeneration) {
      return _emitRejected(
        inputKind: input.kind,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleAccount,
        mode: mode,
        accountGeneration: input.accountGeneration,
        rendererGeneration: input.rendererGeneration,
        sequence: input.sequence,
        speechGeneration: input.speechGeneration,
      );
    }
    if (input.rendererGeneration != _rendererGeneration) {
      return _emitRejected(
        inputKind: input.kind,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleRenderer,
        mode: mode,
        accountGeneration: input.accountGeneration,
        rendererGeneration: input.rendererGeneration,
        sequence: input.sequence,
        speechGeneration: input.speechGeneration,
      );
    }
    if (input.sequence <= _lastSequence) {
      return _emitRejected(
        inputKind: input.kind,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleSequence,
        mode: mode,
        accountGeneration: input.accountGeneration,
        rendererGeneration: input.rendererGeneration,
        sequence: input.sequence,
        speechGeneration: input.speechGeneration,
      );
    }
    _lastSequence = input.sequence;

    final dispatch = _reduce(input);
    if (dispatch == null) {
      return _emitRejected(
        inputKind: input.kind,
        disposition: SelfAvatarProjectionDisposition.rejectedStaleSpeech,
        mode: mode,
        accountGeneration: input.accountGeneration,
        rendererGeneration: input.rendererGeneration,
        sequence: input.sequence,
        speechGeneration: input.speechGeneration,
      );
    }
    return _applyMode(
      mode: mode,
      inputKind: input.kind,
      sequence: input.sequence,
      speechGeneration: input.speechGeneration,
      dispatch: dispatch,
    );
  }

  SelfAvatarProjectionDispatch? _reduce(SelfAvatarProjectionInput input) {
    switch (input) {
      case SelfAvatarEmotionProjectionInput(
        :final params,
        :final duration,
        :final semanticLabel,
        :final persistent,
        :final automatic,
      ):
        _emotions.set(
          params,
          duration: duration,
          semanticLabel: semanticLabel,
          persistent: persistent,
          automatic: automatic,
        );
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          expression: _expression,
        );
      case SelfAvatarEmotionResetProjectionInput():
        _emotions.cancelTransient(notify: false);
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          expression: _expression,
        );
      case SelfAvatarMemeProjectionInput():
        _emotions.set(EmotionParams.love, semanticLabel: 'love');
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          expression: _expression,
        );
      case SelfAvatarSpeakingProjectionInput(
        :final isSpeaking,
        :final generation,
      ):
        if (isSpeaking) {
          if (generation < _speechGeneration) return null;
          _speechGeneration = generation;
          _speaking = true;
        } else {
          if (generation != _speechGeneration) return null;
          _speaking = false;
          _lipAmplitude = 0;
        }
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          expression: _expression,
          stopLipSync: !isSpeaking,
          framing: 'full',
        );
      case SelfAvatarLipFrameProjectionInput(
        :final amplitude,
        :final generation,
      ):
        if (!_speaking || generation != _speechGeneration) return null;
        _lipAmplitude = amplitude.clamp(0.0, 1.0).toDouble();
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          mouthOpen: _visibleMouthOpen,
        );
      case SelfAvatarLipEnvelopeProjectionInput(
        :final envelope,
        :final frameRate,
        :final generation,
      ):
        if (!_speaking || generation != _speechGeneration) return null;
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          lipEnvelope: envelope
              .map((value) => value.clamp(0.0, 1.0).toDouble())
              .toList(growable: false),
          lipFrameRate: frameRate,
        );
      case SelfAvatarVisemeTrackProjectionInput(
        :final track,
        :final generation,
      ):
        if (!_speaking || generation != _speechGeneration) return null;
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          visemeTrack: track,
        );
      case SelfAvatarSpeechPlaybackClockProjectionInput(:final clock):
        return SelfAvatarProjectionDispatch(
          inputKind: input.kind,
          sequence: input.sequence,
          speechPlaybackClock: clock,
        );
    }
  }

  Future<SelfAvatarProjectionReceipt> _applyMode({
    required FeatureRolloutMode mode,
    required SelfAvatarProjectionInputKind inputKind,
    required int sequence,
    required SelfAvatarProjectionDispatch dispatch,
    int? speechGeneration,
  }) async {
    final summary = _summarize(dispatch);
    if (mode == FeatureRolloutMode.off) {
      return _emit(
        inputKind: inputKind,
        disposition: SelfAvatarProjectionDisposition.legacyPreserved,
        mode: mode,
        sequence: sequence,
        speechGeneration: speechGeneration,
        summary: summary,
      );
    }
    if (mode == FeatureRolloutMode.shadow) {
      var comparison = SelfAvatarProjectionShadowComparison.unavailable;
      final comparator = _shadowComparator;
      if (comparator != null) {
        try {
          comparison = await comparator.compare(summary);
        } on Object {
          comparison = SelfAvatarProjectionShadowComparison.unavailable;
        }
      }
      final currentMode = _effectiveMode();
      if (currentMode != mode) {
        return _emit(
          inputKind: inputKind,
          disposition: currentMode == FeatureRolloutMode.off
              ? SelfAvatarProjectionDisposition.legacyPreserved
              : SelfAvatarProjectionDisposition.shadowUnavailable,
          mode: currentMode,
          sequence: sequence,
          speechGeneration: speechGeneration,
          summary: summary,
        );
      }
      final disposition = switch (comparison) {
        SelfAvatarProjectionShadowComparison.matched =>
          SelfAvatarProjectionDisposition.shadowMatched,
        SelfAvatarProjectionShadowComparison.diverged =>
          SelfAvatarProjectionDisposition.shadowDiverged,
        SelfAvatarProjectionShadowComparison.unavailable =>
          SelfAvatarProjectionDisposition.shadowUnavailable,
      };
      return _emit(
        inputKind: inputKind,
        disposition: disposition,
        mode: mode,
        sequence: sequence,
        speechGeneration: speechGeneration,
        summary: summary,
      );
    }
    if (_effectiveMode() != FeatureRolloutMode.enforce ||
        !_rendererReady ||
        dispatch.commandCount == 0) {
      return _emit(
        inputKind: inputKind,
        disposition: SelfAvatarProjectionDisposition.rendererNotReady,
        mode: mode,
        sequence: sequence,
        speechGeneration: speechGeneration,
        summary: summary,
      );
    }
    try {
      await _dispatchSink.dispatch(dispatch);
      return _emit(
        inputKind: inputKind,
        disposition: SelfAvatarProjectionDisposition.enforced,
        mode: mode,
        sequence: sequence,
        speechGeneration: speechGeneration,
        summary: summary,
      );
    } on Object {
      return _emit(
        inputKind: inputKind,
        disposition: SelfAvatarProjectionDisposition.dispatchFailed,
        mode: mode,
        sequence: sequence,
        speechGeneration: speechGeneration,
        summary: summary,
      );
    }
  }

  FeatureRolloutMode _effectiveMode() {
    if (_sealed || isClosed) return FeatureRolloutMode.off;
    try {
      return _mode();
    } on Object {
      return FeatureRolloutMode.off;
    }
  }

  static bool _isInputWellFormed(SelfAvatarProjectionInput input) {
    if (input.accountGeneration < 0 ||
        input.rendererGeneration < 0 ||
        input.sequence <= 0 ||
        (input.speechGeneration != null && input.speechGeneration! <= 0)) {
      return false;
    }
    return switch (input) {
      SelfAvatarEmotionProjectionInput(:final params, :final duration) =>
        _emotionIsFinite(params) &&
            (duration == null || duration > Duration.zero),
      SelfAvatarLipFrameProjectionInput(:final amplitude) => amplitude.isFinite,
      SelfAvatarLipEnvelopeProjectionInput(:final envelope) => envelope.every(
        (value) => value.isFinite,
      ),
      SelfAvatarVisemeTrackProjectionInput() ||
      SelfAvatarSpeechPlaybackClockProjectionInput() => true,
      SelfAvatarEmotionResetProjectionInput() ||
      SelfAvatarMemeProjectionInput() ||
      SelfAvatarSpeakingProjectionInput() => true,
    };
  }

  static bool _emotionIsFinite(EmotionParams params) =>
      params.eyeOpen.isFinite &&
      params.eyeShape.isFinite &&
      params.browAngle.isFinite &&
      params.mouthCurve.isFinite &&
      params.mouthOpen.isFinite &&
      params.cheekFlush.isFinite &&
      params.bodyHueShift.isFinite &&
      params.tremor.isFinite &&
      params.pupilX.isFinite &&
      params.pupilY.isFinite &&
      params.intensity.isFinite;

  AvatarExpressionParams get _expression =>
      emotionToAvatarParams(_emotions.value, semanticLabel: _emotions.label);

  // A TTS-owned zero is a closed/silent frame, even when the semantic mood
  // has an authored open mouth. Never impose that pose as an audio minimum.
  double get _visibleMouthOpen => _lipAmplitude.clamp(0.0, 1.0).toDouble();

  void _queueEmotionRestore() {
    final revision = _emotions.revision;
    final rendererGeneration = _rendererGeneration;
    final restored = _mutationTail.then((_) async {
      if (_sealed ||
          isClosed ||
          revision != _emotions.revision ||
          rendererGeneration != _rendererGeneration) {
        return;
      }
      // This is an internal state transition, not a new external input. Keep
      // the external sequence watermark so the owner's next input stays valid.
      await _applyMode(
        mode: _effectiveMode(),
        inputKind: SelfAvatarProjectionInputKind.emotionRestore,
        sequence: _lastSequence,
        dispatch: SelfAvatarProjectionDispatch(
          inputKind: SelfAvatarProjectionInputKind.emotionRestore,
          sequence: _lastSequence,
          expression: _expression,
        ),
      );
    });
    _mutationTail = restored.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
  }

  SelfAvatarProjectionReceipt _emitRejected({
    required SelfAvatarProjectionInputKind inputKind,
    required SelfAvatarProjectionDisposition disposition,
    required FeatureRolloutMode mode,
    required int accountGeneration,
    required int rendererGeneration,
    required int sequence,
    int? speechGeneration,
  }) => _record(
    SelfAvatarProjectionReceipt(
      inputKind: inputKind,
      disposition: disposition,
      mode: mode,
      accountGeneration: accountGeneration,
      rendererGeneration: rendererGeneration,
      sequence: sequence,
      speechGeneration: speechGeneration,
      fingerprint: '',
      commandCount: 0,
      channels: const <SelfAvatarProjectionChannel>{},
    ),
  );

  SelfAvatarProjectionReceipt _emit({
    required SelfAvatarProjectionInputKind inputKind,
    required SelfAvatarProjectionDisposition disposition,
    required FeatureRolloutMode mode,
    required int sequence,
    required SelfAvatarProjectionPlanSummary summary,
    int? speechGeneration,
  }) => _record(
    SelfAvatarProjectionReceipt(
      inputKind: inputKind,
      disposition: disposition,
      mode: mode,
      accountGeneration: _accountGeneration,
      rendererGeneration: _rendererGeneration,
      sequence: sequence,
      speechGeneration: speechGeneration,
      fingerprint: summary.fingerprint,
      commandCount: summary.commandCount,
      channels: summary.channels,
    ),
  );

  SelfAvatarProjectionReceipt _record(SelfAvatarProjectionReceipt receipt) {
    if (_recentReceipts.length == maximumRecentReceipts) {
      _recentReceipts.removeFirst();
    }
    _recentReceipts.addLast(receipt);
    if (!_receiptStreamClosed) _receiptController.add(receipt);
    return receipt;
  }

  static SelfAvatarProjectionPlanSummary _summarize(
    SelfAvatarProjectionDispatch dispatch,
  ) {
    final normalized = <String, Object?>{
      'kind': dispatch.inputKind.name,
      if (dispatch.expression != null)
        'expression': dispatch.expression!.toJson(),
      if (dispatch.mouthOpen != null) 'mouth': dispatch.mouthOpen,
      if (dispatch.lipEnvelope.isNotEmpty)
        'lip': <String, Object?>{
          'frameRate': dispatch.lipFrameRate,
          'values': dispatch.lipEnvelope,
        },
      if (dispatch.visemeTrack != null)
        'visemeTrack': dispatch.visemeTrack!.toRendererJson(),
      if (dispatch.speechPlaybackClock != null)
        'playbackClock': dispatch.speechPlaybackClock!.toJson(),
      if (dispatch.stopLipSync) 'stop': true,
      if (dispatch.framing != null) 'framing': dispatch.framing,
    };
    final digest = sha256
        .convert(utf8.encode(jsonEncode(normalized)))
        .toString();
    return SelfAvatarProjectionPlanSummary(
      inputKind: dispatch.inputKind,
      sequence: dispatch.sequence,
      fingerprint: digest.substring(0, 16),
      commandCount: dispatch.commandCount,
      channels: dispatch.channels,
    );
  }

  @override
  void onClose() {
    _sealed = true;
    _emotions.close();
    unawaited(
      _mutationTail.whenComplete(() async {
        if (_receiptStreamClosed) return;
        _receiptStreamClosed = true;
        await _receiptController.close();
      }),
    );
    super.onClose();
  }
}
