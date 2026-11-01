import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'avatar_background_task_work_contract.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

enum AvatarCommandChannel { mouth, expression, gaze, bodyGesture, framing }

enum AvatarCommandSource {
  ttsMouth,
  explicitUser,
  explicitAgent,
  scene,
  auto,
  idle,
}

enum AvatarCommandReceiptDisposition {
  dispatched,
  retainedBehindHigherPriority,
  capabilityFallback,
  capabilityUnavailable,
  rendererNotReady,
  rendererOwnedByAnotherArbiter,
  rendererResetRequired,
  released,
  expired,
  noLease,
  rejectedStaleAccount,
  rejectedStaleRenderer,
  rejectedStaleCommand,
  rejectedInvalidSource,
  rejectedInvalidCommand,
  rejectedSealed,
  dispatchFailed,
}

sealed class AvatarChannelCommand {
  const AvatarChannelCommand();

  AvatarCommandChannel get channel;

  Map<String, Object?> toCanonicalJson();
}

final class AvatarMouthCommand extends AvatarChannelCommand {
  AvatarMouthCommand(double value)
    : value = _finiteUnit(value, argumentName: 'value');

  final double value;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.mouth;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'value': value,
  };
}

/// A bounded TTS-owned lip envelope. It deliberately shares the mouth
/// channel with [AvatarMouthCommand], so expression commands can never race
/// or override lip state.
final class AvatarLipEnvelopeCommand extends AvatarChannelCommand {
  AvatarLipEnvelopeCommand(List<double> envelope, {this.frameRate = 30})
    : envelope = List<double>.unmodifiable(
        envelope.map((value) => _finiteUnit(value, argumentName: 'envelope')),
      ) {
    if (this.envelope.isEmpty || this.envelope.length > maximumEnvelopeFrames) {
      throw ArgumentError.value(
        this.envelope.length,
        'envelope',
        'must contain between 1 and $maximumEnvelopeFrames frames',
      );
    }
    if (frameRate < 1 || frameRate > 120) {
      throw ArgumentError.value(
        frameRate,
        'frameRate',
        'must be within 1..120',
      );
    }
  }

  static const int maximumEnvelopeFrames = 7200;

  final List<double> envelope;
  final int frameRate;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.mouth;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'envelope': envelope,
    'frameRate': frameRate,
  };
}

/// Sparse VRM five-vowel track owned by the TTS mouth channel.
///
/// The scalar envelope remains the timing/intensity source. [cues] only mark
/// changes between silence and Aa/Ih/Ou/Ee/Oh, keeping the authenticated
/// renderer payload bounded while allowing Unity to coarticulate locally.
final class AvatarVisemeTrackCommand extends AvatarChannelCommand {
  const AvatarVisemeTrackCommand(this.track);

  final LipSyncVisemeTrack track;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.mouth;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'format': LipSyncVisemeTrack.wireFormat,
    'envelope': track.envelope,
    'cues': track.cues.map((cue) => cue.toJson()).toList(growable: false),
    'frameRate': track.frameRate,
  };
}

/// Correlated playback calibration remains on the TTS-owned mouth channel.
/// It cannot be issued by an expression or a body gesture owner.
final class AvatarSpeechPlaybackClockCommand extends AvatarChannelCommand {
  const AvatarSpeechPlaybackClockCommand(this.clock);

  final SpeechPlaybackClock clock;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.mouth;

  @override
  Map<String, Object?> toCanonicalJson() => {
    'channel': channel.name,
    'playbackClock': clock.toJson(),
  };
}

final class AvatarExpressionCommand extends AvatarChannelCommand {
  const AvatarExpressionCommand(this.params);

  final AvatarExpressionParams params;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.expression;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'params': params.toJson(),
  };
}

final class AvatarGazeCommand extends AvatarChannelCommand {
  const AvatarGazeCommand(this.gaze);

  final AvatarGaze gaze;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.gaze;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'gaze': gaze.toJson(),
  };
}

final class AvatarBodyGestureCommand extends AvatarChannelCommand {
  AvatarBodyGestureCommand(
    String gesture, {
    this.workSessionId,
    this.workPhase,
    this.energy,
    this.intensity,
    this.emotion,
  }) : gesture = _boundedIdentifier(gesture, argumentName: 'gesture') {
    final hasPerformance = energy != null;
    if ((!hasPerformance &&
            (intensity != null ||
                emotion != null ||
                this.gesture == 'speech')) ||
        (hasPerformance &&
            (!performanceEnergies.contains(energy) ||
                intensity == null ||
                !intensity!.isFinite ||
                intensity! < 0 ||
                intensity! > 1 ||
                !performanceEmotions.contains(emotion) ||
                workSessionId != null ||
                workPhase != null))) {
      throw ArgumentError('invalid_avatar_performance_command');
    }
    if ((workSessionId == null) != (workPhase == null) ||
        (workSessionId != null &&
            (!RegExp(r'^[a-f0-9]{64}$').hasMatch(workSessionId!) ||
                this.gesture !=
                    (workPhase == AvatarBackgroundTaskWorkPhase.start
                        ? 'work_desk'
                        : 'stand_up')))) {
      throw ArgumentError('invalid_background_work_command');
    }
  }

  final String gesture;
  final String? workSessionId;
  final AvatarBackgroundTaskWorkPhase? workPhase;
  final String? energy;
  final double? intensity;
  final String? emotion;

  static const performanceEnergies = {'gentle', 'moderate', 'high'};
  static const performanceEmotions = {
    'neutral',
    'calm',
    'happy',
    'excited',
    'sad',
    'comforting',
    'curious',
    'thinking',
    'surprised',
    'angry',
  };

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.bodyGesture;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'gesture': gesture,
    if (workSessionId != null) 'workSessionId': workSessionId,
    if (workPhase != null) 'workPhase': workPhase!.name,
    if (energy != null) ...{
      'energy': energy,
      'intensity': intensity,
      'emotion': emotion,
    },
  };
}

final class AvatarFramingCommand extends AvatarChannelCommand {
  AvatarFramingCommand(String mode)
    : mode = _boundedIdentifier(mode, argumentName: 'mode');

  final String mode;

  @override
  AvatarCommandChannel get channel => AvatarCommandChannel.framing;

  @override
  Map<String, Object?> toCanonicalJson() => <String, Object?>{
    'channel': channel.name,
    'mode': mode,
  };
}

final class AvatarCommandCapabilities {
  AvatarCommandCapabilities({
    required Set<AvatarCommandChannel> supportedChannels,
    Set<String>? supportedBodyGestures,
  }) : supportedChannels = Set<AvatarCommandChannel>.unmodifiable(
         supportedChannels,
       ),
       supportedBodyGestures = Set<String>.unmodifiable(
         (supportedBodyGestures ?? const <String>{}).map(
           (value) =>
               _boundedIdentifier(value, argumentName: 'supportedBodyGestures'),
         ),
       ) {
    final gestures = this.supportedBodyGestures;
    if (gestures.length > maximumSupportedBodyGestures) {
      throw ArgumentError.value(
        gestures.length,
        'supportedBodyGestures',
        'must contain at most $maximumSupportedBodyGestures entries',
      );
    }
  }

  static const int maximumSupportedBodyGestures = 32;

  static final all = AvatarCommandCapabilities(
    supportedChannels: AvatarCommandChannel.values.toSet(),
  );

  final Set<AvatarCommandChannel> supportedChannels;

  /// Body gestures are fail-closed: omitted means none are supported.
  final Set<String> supportedBodyGestures;

  bool supportsChannel(AvatarCommandChannel channel) =>
      supportedChannels.contains(channel);

  bool supports(AvatarChannelCommand command) {
    if (!supportsChannel(command.channel)) return false;
    return command is! AvatarBodyGestureCommand ||
        supportedBodyGestures.contains(command.gesture);
  }
}

final class AvatarCommandLeaseRequest {
  AvatarCommandLeaseRequest({
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.commandGeneration,
    required String leaseId,
    required this.source,
    required this.command,
    required this.ttl,
  }) : leaseId = _boundedIdentifier(leaseId, argumentName: 'leaseId') {
    if (accountGeneration < 0) {
      throw ArgumentError.value(accountGeneration, 'accountGeneration');
    }
    if (rendererGeneration < 0) {
      throw ArgumentError.value(rendererGeneration, 'rendererGeneration');
    }
    if (commandGeneration <= 0) {
      throw ArgumentError.value(commandGeneration, 'commandGeneration');
    }
    if (ttl <= Duration.zero || ttl > AvatarCommandArbiter.maximumLeaseTtl) {
      throw ArgumentError.value(ttl, 'ttl');
    }
  }

  final int accountGeneration;
  final int rendererGeneration;
  final int commandGeneration;
  final String leaseId;
  final AvatarCommandSource source;
  final AvatarChannelCommand command;
  final Duration ttl;
}

final class AvatarCommandReleaseRequest {
  const AvatarCommandReleaseRequest({
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.commandGeneration,
    required this.channel,
    required this.source,
  });

  final int accountGeneration;
  final int rendererGeneration;
  final int commandGeneration;
  final AvatarCommandChannel channel;
  final AvatarCommandSource source;
}

/// One renderer-neutral channel mutation. A null [command] clears the channel.
final class AvatarCommandDispatch {
  const AvatarCommandDispatch({
    required this.rendererId,
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.channel,
    required this.source,
    required this.commandGeneration,
    required this.command,
  });

  final String rendererId;
  final int accountGeneration;
  final int rendererGeneration;
  final AvatarCommandChannel channel;
  final AvatarCommandSource? source;
  final int? commandGeneration;
  final AvatarChannelCommand? command;

  bool get clearsChannel => command == null;
}

abstract interface class AvatarCommandDispatchSink {
  /// In-process implementations perform the renderer mutation inside
  /// [AvatarCommandDispatchOperation.applyIfCurrent]. Out-of-process sinks
  /// must use the operation's one-shot renderer permit and accept only the
  /// concrete renderer's exact post-mutation acknowledgement. A sink may await
  /// [AvatarCommandDispatchOperation.cancelled] to abort slower preparation.
  Future<AvatarCommandDispatchReceipt> dispatch(
    AvatarCommandDispatchOperation operation,
  );

  /// Reset or dispose the exact concrete renderer instance. The returned
  /// proof can only be produced by invoking [AvatarRendererResetOperation]
  /// around the real renderer mutation.
  Future<AvatarRendererResetReceipt> resetOrDispose(
    AvatarRendererResetOperation operation,
  );
}

/// Renderer acknowledgement produced only after the concrete mutation ran.
final class AvatarCommandDispatchReceipt {
  const AvatarCommandDispatchReceipt._({
    required this.ticket,
    required this.rendererId,
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.channel,
    required this.desiredFingerprint,
    required this.clearsChannel,
  });

  final int ticket;
  final String rendererId;
  final int accountGeneration;
  final int rendererGeneration;
  final AvatarCommandChannel channel;
  final String desiredFingerprint;
  final bool clearsChannel;
}

/// One cancellable, generation-fenced opportunity to mutate the renderer.
///
/// The synchronous callback passed to [applyIfCurrent] is the linearization
/// point. A timed-out, superseded, sealed, or stale renderer operation can
/// never call it successfully, even if the sink's Future completes later.
final class AvatarCommandDispatchOperation {
  AvatarCommandDispatchOperation._({
    required this.ticket,
    required this.dispatch,
    required this.validUntil,
    required this.rendererDeadline,
    required this.desiredFingerprint,
    required String rendererOwnerToken,
    required bool Function() isCurrent,
  }) : _rendererOwnerToken = rendererOwnerToken,
       _rendererPayloadJson = _canonicalRendererPayload(
         dispatch,
         validUntil: validUntil,
       ),
       _isCurrent = isCurrent;

  final int ticket;
  final AvatarCommandDispatch dispatch;
  final DateTime? validUntil;
  final DateTime rendererDeadline;
  final String desiredFingerprint;
  final String _rendererOwnerToken;
  final String _rendererPayloadJson;
  final bool Function() _isCurrent;
  final Completer<void> _cancelledSignal = Completer<void>();
  bool _revoked = false;
  bool _claimed = false;
  bool _mutationAttempted = false;
  bool _wasApplied = false;
  AvatarRendererMutationPermit? _rendererPermit;

  bool get isCurrent => !_revoked && _isCurrent();
  bool get mayHaveMutated => _mutationAttempted;
  bool get wasApplied => _wasApplied;
  bool get usedRendererPermit => _rendererPermit != null;
  Future<void> get cancelled => _cancelledSignal.future;

  /// Issues a one-shot, operation-bound permit for an out-of-process renderer.
  ///
  /// The permit is only minted while the operation is current. Sending it is
  /// considered a possible mutation because the renderer may execute even if
  /// its acknowledgement is delayed or lost. The sink must wait for the exact
  /// renderer acknowledgement and then call [acceptRendererReceipt].
  AvatarRendererMutationPermit? issueRendererMutationPermit() {
    if (_claimed || !isCurrent) return null;
    _claimed = true;
    _mutationAttempted = true;
    final permit = AvatarRendererMutationPermit._(
      ticket: ticket,
      rendererId: dispatch.rendererId,
      ownerToken: _rendererOwnerToken,
      commitToken: _newOpaqueToken(),
      accountGeneration: dispatch.accountGeneration,
      rendererGeneration: dispatch.rendererGeneration,
      channel: dispatch.channel,
      desiredFingerprint: desiredFingerprint,
      payloadJson: _rendererPayloadJson,
      payloadSha256: sha256
          .convert(utf8.encode(_rendererPayloadJson))
          .toString(),
      deadlineEpochMs: rendererDeadline.millisecondsSinceEpoch,
      clearsChannel: dispatch.clearsChannel,
    );
    _rendererPermit = permit;
    return permit;
  }

  /// Converts an exact Unity acknowledgement into the arbiter's trusted
  /// receipt. A stale, foreign, duplicate, or synthetic permit is rejected.
  AvatarCommandDispatchReceipt? acceptRendererReceipt(
    AvatarRendererMutationPermit permit,
  ) {
    if (!identical(_rendererPermit, permit) ||
        permit._accepted ||
        permit._commitToken.isEmpty) {
      return null;
    }
    permit._accepted = true;
    _wasApplied = true;
    return AvatarCommandDispatchReceipt._(
      ticket: ticket,
      rendererId: dispatch.rendererId,
      accountGeneration: dispatch.accountGeneration,
      rendererGeneration: dispatch.rendererGeneration,
      channel: dispatch.channel,
      desiredFingerprint: desiredFingerprint,
      clearsChannel: dispatch.clearsChannel,
    );
  }

  AvatarCommandDispatchReceipt? applyIfCurrent(
    void Function(AvatarCommandDispatch dispatch) apply,
  ) {
    if (_claimed || !isCurrent) return null;
    _claimed = true;
    _mutationAttempted = true;
    apply(dispatch);
    _wasApplied = true;
    return AvatarCommandDispatchReceipt._(
      ticket: ticket,
      rendererId: dispatch.rendererId,
      accountGeneration: dispatch.accountGeneration,
      rendererGeneration: dispatch.rendererGeneration,
      channel: dispatch.channel,
      desiredFingerprint: desiredFingerprint,
      clearsChannel: dispatch.clearsChannel,
    );
  }

  void _revoke() {
    if (_revoked) return;
    _revoked = true;
    if (!_cancelledSignal.isCompleted) _cancelledSignal.complete();
  }
}

/// Opaque one-shot authorization carried to the concrete Unity receiver.
///
/// Callers can serialize an issued permit but cannot construct one. The
/// receiver must validate every field, the payload digest, its per-channel
/// ticket high-water mark, and the deadline immediately before mutation.
final class AvatarRendererMutationPermit {
  AvatarRendererMutationPermit._({
    required this.ticket,
    required this.rendererId,
    required String ownerToken,
    required String commitToken,
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.channel,
    required this.desiredFingerprint,
    required this.payloadJson,
    required this.payloadSha256,
    required this.deadlineEpochMs,
    required this.clearsChannel,
  }) : _ownerToken = ownerToken,
       _commitToken = commitToken;

  final int ticket;
  final String rendererId;
  final String _ownerToken;
  final String _commitToken;
  final int accountGeneration;
  final int rendererGeneration;
  final AvatarCommandChannel channel;
  final String desiredFingerprint;
  final String payloadJson;
  final String payloadSha256;
  final int deadlineEpochMs;
  final bool clearsChannel;
  bool _accepted = false;

  Map<String, Object?> toTransportJson({required String requestId}) =>
      <String, Object?>{
        'protocolVersion': 1,
        'requestId': requestId,
        'ticket': ticket,
        'rendererId': rendererId,
        'ownerToken': _ownerToken,
        'commitToken': _commitToken,
        'accountGeneration': accountGeneration,
        'rendererGeneration': rendererGeneration,
        'channel': channel.name,
        'fingerprint': desiredFingerprint,
        'payloadJson': payloadJson,
        'payloadSha256': payloadSha256,
        'deadlineEpochMs': deadlineEpochMs,
        'clearsChannel': clearsChannel,
      };
}

/// One unforgeable opportunity to reset/dispose a concrete renderer instance.
final class AvatarRendererResetOperation {
  AvatarRendererResetOperation._({
    required this.requirementId,
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required this.rendererId,
    required this.retiredAccountGeneration,
    required this.retiredRendererGeneration,
    required this.targetAccountGeneration,
    required this.targetRendererGeneration,
    required _AvatarArbiterNonce targetArbiterNonce,
    required bool Function() isCurrent,
  }) : _rendererIdentity = rendererIdentity,
       _targetArbiterNonce = targetArbiterNonce,
       _isCurrent = isCurrent;

  final int requirementId;
  final _AvatarRendererInstanceIdentity _rendererIdentity;
  final String rendererId;
  final int retiredAccountGeneration;
  final int retiredRendererGeneration;
  final int targetAccountGeneration;
  final int targetRendererGeneration;
  final _AvatarArbiterNonce _targetArbiterNonce;
  final bool Function() _isCurrent;
  bool _revoked = false;
  bool _claimed = false;
  AvatarRendererResetPermit? _rendererPermit;

  bool get isCurrent => !_revoked && _isCurrent();

  AvatarRendererResetReceipt? resetOrDisposeIfCurrent(
    void Function() resetOrDispose,
  ) {
    if (_claimed || !isCurrent) return null;
    _claimed = true;
    resetOrDispose();
    return AvatarRendererResetReceipt._(
      requirementId: requirementId,
      rendererIdentity: _rendererIdentity,
      rendererId: rendererId,
      retiredAccountGeneration: retiredAccountGeneration,
      retiredRendererGeneration: retiredRendererGeneration,
      targetAccountGeneration: targetAccountGeneration,
      resetRendererGeneration: targetRendererGeneration,
      targetArbiterNonce: _targetArbiterNonce,
    );
  }

  /// Issues the one-shot permit used by an out-of-process renderer reset.
  AvatarRendererResetPermit? issueRendererResetPermit({
    required DateTime deadline,
  }) {
    if (_claimed || !isCurrent) return null;
    _claimed = true;
    final payloadJson = jsonEncode(const <String, Object?>{'reset': true});
    final permit = AvatarRendererResetPermit._(
      requirementId: requirementId,
      rendererId: rendererId,
      targetOwnerToken: _targetArbiterNonce.transportToken,
      commitToken: _newOpaqueToken(),
      retiredAccountGeneration: retiredAccountGeneration,
      retiredRendererGeneration: retiredRendererGeneration,
      targetAccountGeneration: targetAccountGeneration,
      targetRendererGeneration: targetRendererGeneration,
      payloadJson: payloadJson,
      payloadSha256: sha256.convert(utf8.encode(payloadJson)).toString(),
      deadlineEpochMs: deadline.millisecondsSinceEpoch,
    );
    _rendererPermit = permit;
    return permit;
  }

  AvatarRendererResetReceipt? acceptRendererResetReceipt(
    AvatarRendererResetPermit permit,
  ) {
    if (!identical(_rendererPermit, permit) || permit._accepted) return null;
    permit._accepted = true;
    return AvatarRendererResetReceipt._(
      requirementId: requirementId,
      rendererIdentity: _rendererIdentity,
      rendererId: rendererId,
      retiredAccountGeneration: retiredAccountGeneration,
      retiredRendererGeneration: retiredRendererGeneration,
      targetAccountGeneration: targetAccountGeneration,
      resetRendererGeneration: targetRendererGeneration,
      targetArbiterNonce: _targetArbiterNonce,
    );
  }

  void _revoke() {
    _revoked = true;
  }
}

/// Opaque authorization for a real Unity neutralization and ownership reset.
final class AvatarRendererResetPermit {
  AvatarRendererResetPermit._({
    required this.requirementId,
    required this.rendererId,
    required String targetOwnerToken,
    required String commitToken,
    required this.retiredAccountGeneration,
    required this.retiredRendererGeneration,
    required this.targetAccountGeneration,
    required this.targetRendererGeneration,
    required this.payloadJson,
    required this.payloadSha256,
    required this.deadlineEpochMs,
  }) : _targetOwnerToken = targetOwnerToken,
       _commitToken = commitToken;

  final int requirementId;
  final String rendererId;
  final String _targetOwnerToken;
  final String _commitToken;
  final int retiredAccountGeneration;
  final int retiredRendererGeneration;
  final int targetAccountGeneration;
  final int targetRendererGeneration;
  final String payloadJson;
  final String payloadSha256;
  final int deadlineEpochMs;
  bool _accepted = false;

  Map<String, Object?> toTransportJson({required String requestId}) =>
      <String, Object?>{
        'protocolVersion': 1,
        'requestId': requestId,
        'requirementId': requirementId,
        'rendererId': rendererId,
        'targetOwnerToken': _targetOwnerToken,
        'commitToken': _commitToken,
        'retiredAccountGeneration': retiredAccountGeneration,
        'retiredRendererGeneration': retiredRendererGeneration,
        'targetAccountGeneration': targetAccountGeneration,
        'targetRendererGeneration': targetRendererGeneration,
        'payloadJson': payloadJson,
        'payloadSha256': payloadSha256,
        'deadlineEpochMs': deadlineEpochMs,
      };
}

/// A bounded observation. It deliberately excludes lease ids and payloads.
final class AvatarCommandReceipt {
  const AvatarCommandReceipt({
    required this.channel,
    required this.requestedSource,
    required this.selectedSource,
    required this.disposition,
    required this.accountGeneration,
    required this.rendererGeneration,
    required this.commandGeneration,
    required this.fingerprint,
    required this.activeLeaseCount,
  });

  final AvatarCommandChannel? channel;
  final AvatarCommandSource? requestedSource;
  final AvatarCommandSource? selectedSource;
  final AvatarCommandReceiptDisposition disposition;
  final int accountGeneration;
  final int rendererGeneration;
  final int? commandGeneration;
  final String fingerprint;
  final int activeLeaseCount;
}

typedef AvatarCommandClock = DateTime Function();
typedef AvatarLeaseExpiryScheduler =
    AvatarLeaseExpiryHandle Function(Duration delay, void Function() callback);

abstract interface class AvatarLeaseExpiryHandle {
  void cancel();
}

final class _AvatarRendererInstanceIdentity {
  _AvatarRendererInstanceIdentity(this.serial);

  final int serial;
  int rendererGenerationHighWater = -1;
  int retiredArbiterNonceHighWater = 0;

  String get label => 'renderer-instance-$serial';
}

final class _AvatarArbiterNonce {
  const _AvatarArbiterNonce(this.serial, this.transportToken);

  final int serial;
  final String transportToken;
}

final class _AvatarRendererOwnerLease {
  const _AvatarRendererOwnerLease({
    required this.serial,
    required this.rendererIdentity,
    required this.arbiterNonce,
    required this.accountGeneration,
    required this.rendererGeneration,
  });

  final int serial;
  final _AvatarRendererInstanceIdentity rendererIdentity;
  final _AvatarArbiterNonce arbiterNonce;
  final int accountGeneration;
  final int rendererGeneration;
}

/// Isolate-wide account-switch fence keyed by concrete sink instance identity.
final class _AvatarRendererRetirementGuard {
  final Map<_AvatarRendererInstanceIdentity, AvatarRendererResetRequirement>
  _pending =
      <_AvatarRendererInstanceIdentity, AvatarRendererResetRequirement>{};
  final Set<(_AvatarRendererInstanceIdentity, int)> _resetPermitted =
      <(_AvatarRendererInstanceIdentity, int)>{};
  final Map<_AvatarRendererInstanceIdentity, _AvatarRendererOwnerLease>
  _activeOwners =
      <_AvatarRendererInstanceIdentity, _AvatarRendererOwnerLease>{};
  int _requirementGeneration = 0;
  int _ownerGeneration = 0;

  _AvatarRendererOwnerLease? _claimOwner({
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required _AvatarArbiterNonce arbiterNonce,
    required int accountGeneration,
    required int rendererGeneration,
  }) {
    if (_pending.containsKey(rendererIdentity)) return null;
    if (arbiterNonce.serial <= rendererIdentity.retiredArbiterNonceHighWater) {
      return null;
    }
    final current = _activeOwners[rendererIdentity];
    if (current != null && !identical(current.arbiterNonce, arbiterNonce)) {
      return null;
    }
    if (current != null && current.accountGeneration != accountGeneration) {
      return null;
    }
    if (current == null &&
        rendererGeneration <= rendererIdentity.rendererGenerationHighWater) {
      return null;
    }
    if (current != null && rendererGeneration < current.rendererGeneration) {
      return null;
    }
    if (current != null && current.rendererGeneration == rendererGeneration) {
      return current;
    }
    final lease = _AvatarRendererOwnerLease(
      serial: ++_ownerGeneration,
      rendererIdentity: rendererIdentity,
      arbiterNonce: arbiterNonce,
      accountGeneration: accountGeneration,
      rendererGeneration: rendererGeneration,
    );
    _activeOwners[rendererIdentity] = lease;
    if (rendererGeneration > rendererIdentity.rendererGenerationHighWater) {
      rendererIdentity.rendererGenerationHighWater = rendererGeneration;
    }
    return lease;
  }

  bool _isActiveOwner(_AvatarRendererOwnerLease? lease) =>
      lease != null && identical(_activeOwners[lease.rendererIdentity], lease);

  void _releaseOwner(_AvatarRendererOwnerLease? lease) {
    if (lease == null || !_isActiveOwner(lease)) return;
    final identity = lease.rendererIdentity;
    if (lease.arbiterNonce.serial > identity.retiredArbiterNonceHighWater) {
      identity.retiredArbiterNonceHighWater = lease.arbiterNonce.serial;
    }
    _activeOwners.remove(lease.rendererIdentity);
  }

  AvatarRendererResetRequirement? _pendingFor(
    _AvatarRendererInstanceIdentity rendererIdentity,
  ) => _pending[rendererIdentity];

  bool _canBeginRetirement({
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required _AvatarArbiterNonce arbiterNonce,
    required int accountGeneration,
    required int rendererGeneration,
  }) {
    if (rendererGeneration < rendererIdentity.rendererGenerationHighWater) {
      return false;
    }
    final current = _activeOwners[rendererIdentity];
    return current == null ||
        (identical(current.arbiterNonce, arbiterNonce) &&
            current.accountGeneration == accountGeneration &&
            current.rendererGeneration == rendererGeneration);
  }

  AvatarRendererResetRequirement _beginRetirement({
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required int retiredAccountGeneration,
    required int retiredRendererGeneration,
    required Set<AvatarCommandChannel> dirtyChannels,
  }) {
    final current = _pending[rendererIdentity];
    if (current != null) {
      if (dirtyChannels.difference(current.dirtyChannels).isEmpty) {
        return current;
      }
      final expanded = AvatarRendererResetRequirement._(
        requirementId: current.requirementId,
        rendererIdentity: current._rendererIdentity,
        rendererId: current.rendererId,
        retiredAccountGeneration: current.retiredAccountGeneration,
        retiredRendererGeneration: current.retiredRendererGeneration,
        dirtyChannels: Set<AvatarCommandChannel>.unmodifiable(
          <AvatarCommandChannel>{...current.dirtyChannels, ...dirtyChannels},
        ),
      );
      _pending[rendererIdentity] = expanded;
      return expanded;
    }
    final requirement = AvatarRendererResetRequirement._(
      requirementId: ++_requirementGeneration,
      rendererIdentity: rendererIdentity,
      rendererId: rendererIdentity.label,
      retiredAccountGeneration: retiredAccountGeneration,
      retiredRendererGeneration: retiredRendererGeneration,
      dirtyChannels: Set<AvatarCommandChannel>.unmodifiable(dirtyChannels),
    );
    _pending[rendererIdentity] = requirement;
    return requirement;
  }

  AvatarRendererResetRequirement _requireReset({
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required int retiredAccountGeneration,
    required int retiredRendererGeneration,
    required Set<AvatarCommandChannel> dirtyChannels,
  }) {
    var requirement = _beginRetirement(
      rendererIdentity: rendererIdentity,
      retiredAccountGeneration: retiredAccountGeneration,
      retiredRendererGeneration: retiredRendererGeneration,
      dirtyChannels: dirtyChannels,
    );
    if (requirement.retiredAccountGeneration == retiredAccountGeneration &&
        requirement.retiredRendererGeneration == retiredRendererGeneration &&
        (requirement.dirtyChannels.length != dirtyChannels.length ||
            !requirement.dirtyChannels.containsAll(dirtyChannels))) {
      requirement = AvatarRendererResetRequirement._(
        requirementId: requirement.requirementId,
        rendererIdentity: requirement._rendererIdentity,
        rendererId: requirement.rendererId,
        retiredAccountGeneration: requirement.retiredAccountGeneration,
        retiredRendererGeneration: requirement.retiredRendererGeneration,
        dirtyChannels: Set<AvatarCommandChannel>.unmodifiable(dirtyChannels),
      );
      _pending[rendererIdentity] = requirement;
    }
    _resetPermitted.add((rendererIdentity, requirement.requirementId));
    return requirement;
  }

  void _confirmNeutralClear(AvatarRendererResetRequirement requirement) {
    final current = _pending[requirement._rendererIdentity];
    if (current?.requirementId != requirement.requirementId) return;
    _pending.remove(requirement._rendererIdentity);
    _resetPermitted.remove((
      requirement._rendererIdentity,
      requirement.requirementId,
    ));
  }

  bool _canReset(AvatarRendererResetRequirement requirement) =>
      identical(_pending[requirement._rendererIdentity], requirement) &&
      _resetPermitted.contains((
        requirement._rendererIdentity,
        requirement.requirementId,
      ));

  _AvatarRendererOwnerLease? _consumeResetReceipt(
    AvatarRendererResetReceipt receipt,
  ) {
    final pending = _pending[receipt._rendererIdentity];
    final replacedOwner = _activeOwners[receipt._rendererIdentity];
    final targetAlreadyOwns =
        replacedOwner != null &&
        identical(replacedOwner.arbiterNonce, receipt._targetArbiterNonce);
    if (pending == null ||
        !_resetPermitted.contains((
          receipt._rendererIdentity,
          pending.requirementId,
        )) ||
        receipt.requirementId != pending.requirementId ||
        receipt.retiredAccountGeneration != pending.retiredAccountGeneration ||
        receipt.retiredRendererGeneration !=
            pending.retiredRendererGeneration ||
        receipt.resetRendererGeneration <= pending.retiredRendererGeneration ||
        receipt.resetRendererGeneration <=
            receipt._rendererIdentity.rendererGenerationHighWater ||
        (!targetAlreadyOwns &&
            receipt._targetArbiterNonce.serial <=
                receipt._rendererIdentity.retiredArbiterNonceHighWater)) {
      return null;
    }
    if (replacedOwner != null &&
        !identical(replacedOwner.arbiterNonce, receipt._targetArbiterNonce) &&
        replacedOwner.arbiterNonce.serial >
            receipt._rendererIdentity.retiredArbiterNonceHighWater) {
      receipt._rendererIdentity.retiredArbiterNonceHighWater =
          replacedOwner.arbiterNonce.serial;
    }
    _pending.remove(receipt._rendererIdentity);
    _resetPermitted.remove((receipt._rendererIdentity, pending.requirementId));
    final owner = _AvatarRendererOwnerLease(
      serial: ++_ownerGeneration,
      rendererIdentity: receipt._rendererIdentity,
      arbiterNonce: receipt._targetArbiterNonce,
      accountGeneration: receipt.targetAccountGeneration,
      rendererGeneration: receipt.resetRendererGeneration,
    );
    _activeOwners[receipt._rendererIdentity] = owner;
    receipt._rendererIdentity.rendererGenerationHighWater =
        receipt.resetRendererGeneration;
    return owner;
  }
}

final class AvatarRendererResetRequirement {
  const AvatarRendererResetRequirement._({
    required this.requirementId,
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required this.rendererId,
    required this.retiredAccountGeneration,
    required this.retiredRendererGeneration,
    required this.dirtyChannels,
  }) : _rendererIdentity = rendererIdentity;

  final int requirementId;
  final _AvatarRendererInstanceIdentity _rendererIdentity;
  final String rendererId;
  final int retiredAccountGeneration;
  final int retiredRendererGeneration;
  final Set<AvatarCommandChannel> dirtyChannels;
}

/// Trusted reset/dispose acknowledgement. Only a current
/// [AvatarRendererResetOperation] can construct one.
final class AvatarRendererResetReceipt {
  const AvatarRendererResetReceipt._({
    required this.requirementId,
    required _AvatarRendererInstanceIdentity rendererIdentity,
    required this.rendererId,
    required this.retiredAccountGeneration,
    required this.retiredRendererGeneration,
    required this.targetAccountGeneration,
    required this.resetRendererGeneration,
    required _AvatarArbiterNonce targetArbiterNonce,
  }) : _rendererIdentity = rendererIdentity,
       _targetArbiterNonce = targetArbiterNonce;

  final int requirementId;
  final _AvatarRendererInstanceIdentity _rendererIdentity;
  final String rendererId;
  final int retiredAccountGeneration;
  final int retiredRendererGeneration;
  final int targetAccountGeneration;
  final int resetRendererGeneration;
  final _AvatarArbiterNonce _targetArbiterNonce;
}

final class AvatarRendererResetRequiredException implements Exception {
  const AvatarRendererResetRequiredException(this.requirement);

  final AvatarRendererResetRequirement requirement;

  @override
  String toString() =>
      'AvatarRendererResetRequiredException(${requirement.rendererId}, '
      '${requirement.dirtyChannels.map((channel) => channel.name).join(',')})';
}

final class AvatarRendererResetFailedException implements Exception {
  const AvatarRendererResetFailedException(this.rendererId);

  final String rendererId;

  @override
  String toString() => 'AvatarRendererResetFailedException($rendererId)';
}

/// Account-scoped, renderer-neutral, per-channel command lease arbiter.
///
/// Priority is `TTS mouth > explicit user > explicit agent > scene > auto >
/// idle`. TTS is admitted only on the mouth channel. Every other command is
/// isolated to exactly one channel, so a body lease never waits for speech.
final class AvatarCommandArbiter extends AppService {
  AvatarCommandArbiter({
    required int accountGeneration,
    required AvatarCommandDispatchSink dispatchSink,
    AvatarCommandClock? clock,
    AvatarLeaseExpiryScheduler? scheduleExpiry,
    this.dispatchTimeout = const Duration(milliseconds: 500),
  }) : _accountGeneration = accountGeneration,
       _dispatchSink = dispatchSink,
       _rendererIdentity = _identityFor(dispatchSink),
       _arbiterNonce = _newArbiterNonce(),
       _retirementGuard = _sharedRetirementGuard,
       _clock = clock ?? DateTime.now,
       _scheduleExpiry = scheduleExpiry ?? _scheduleTimerExpiry,
       _receiptSalt = _newReceiptSalt() {
    if (accountGeneration < 0) {
      throw ArgumentError.value(accountGeneration, 'accountGeneration');
    }
    if (dispatchTimeout <= Duration.zero ||
        dispatchTimeout > const Duration(seconds: 5)) {
      throw ArgumentError.value(dispatchTimeout, 'dispatchTimeout');
    }
  }

  static const int maximumRecentReceipts = 64;
  static const Duration maximumLeaseTtl = Duration(minutes: 10);
  static final _AvatarRendererRetirementGuard _sharedRetirementGuard =
      _AvatarRendererRetirementGuard();
  static final Expando<_AvatarRendererInstanceIdentity> _rendererIdentities =
      Expando<_AvatarRendererInstanceIdentity>();
  static int _rendererIdentitySerial = 0;
  static int _arbiterNonceSerial = 0;

  final int _accountGeneration;
  final AvatarCommandDispatchSink _dispatchSink;
  final _AvatarRendererInstanceIdentity _rendererIdentity;
  final _AvatarArbiterNonce _arbiterNonce;
  final _AvatarRendererRetirementGuard _retirementGuard;
  final AvatarCommandClock _clock;
  final AvatarLeaseExpiryScheduler _scheduleExpiry;
  final String _receiptSalt;
  final Duration dispatchTimeout;
  final Map<AvatarCommandChannel, Map<AvatarCommandSource, _AvatarLease>>
  _leases = <AvatarCommandChannel, Map<AvatarCommandSource, _AvatarLease>>{};
  final Map<(AvatarCommandChannel, AvatarCommandSource), int>
  _lastCommandGenerations =
      <(AvatarCommandChannel, AvatarCommandSource), int>{};
  final Map<AvatarCommandChannel, _AppliedAvatarLease> _applied =
      <AvatarCommandChannel, _AppliedAvatarLease>{};
  final Set<AvatarCommandChannel> _dirtyChannels = <AvatarCommandChannel>{};
  final ListQueue<AvatarCommandReceipt> _recentReceipts =
      ListQueue<AvatarCommandReceipt>(maximumRecentReceipts);
  final Map<AvatarCommandChannel, AvatarCommandDispatchOperation>
  _inFlightDispatches =
      <AvatarCommandChannel, AvatarCommandDispatchOperation>{};

  Future<void> _mutationTail = Future<void>.value();
  Future<void>? _sealFuture;
  bool _requireRendererResetForNextOwner = false;
  AvatarRendererResetRequirement? _retirementRequirement;
  _AvatarRendererOwnerLease? _ownerLease;
  AvatarLeaseExpiryHandle? _expiryHandle;
  int _expiryScheduleGeneration = 0;
  int _dispatchTicket = 0;
  int _rendererFenceGeneration = 0;
  int _rendererGeneration = 0;
  bool _rendererReady = false;
  AvatarCommandCapabilities _capabilities = AvatarCommandCapabilities.all;
  bool _sealed = false;

  int get accountGeneration => _accountGeneration;
  int get rendererGeneration => _rendererGeneration;
  bool get rendererReady => _rendererReady;
  bool get isSealed => _sealed;
  AvatarRendererResetRequirement? get pendingRendererReset =>
      _retirementGuard._pendingFor(_rendererIdentity);

  List<AvatarCommandReceipt> get recentReceipts =>
      List<AvatarCommandReceipt>.unmodifiable(_recentReceipts);

  /// Read-only observations cannot resurrect an old owner after a reset,
  /// renderer replacement, account switch, or retirement.
  bool acceptsRendererObservation({
    required String ownerToken,
    required int accountGeneration,
    required int rendererGeneration,
  }) =>
      !_sealed &&
      !isClosed &&
      _rendererReady &&
      _retirementGuard._isActiveOwner(_ownerLease) &&
      accountGeneration == _accountGeneration &&
      rendererGeneration == _rendererGeneration &&
      ownerToken == _arbiterNonce.transportToken;

  Future<List<AvatarCommandReceipt>> bindRenderer({
    required int accountGeneration,
    required int rendererGeneration,
    required bool ready,
    AvatarCommandCapabilities? capabilities,
  }) {
    if (_sealed || isClosed) {
      return Future<List<AvatarCommandReceipt>>.value(<AvatarCommandReceipt>[
        _reject(
          disposition: AvatarCommandReceiptDisposition.rejectedSealed,
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
        ),
      ]);
    }
    if (accountGeneration == _accountGeneration &&
        rendererGeneration >= _rendererGeneration) {
      _rendererFenceGeneration += 1;
      for (final operation in _inFlightDispatches.values) {
        operation._revoke();
      }
    }
    return _enqueue(
      () => _bindRenderer(
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        ready: ready,
        capabilities: capabilities ?? AvatarCommandCapabilities.all,
      ),
    );
  }

  Future<void> resetRendererForMount({
    required int accountGeneration,
    required int rendererGeneration,
  }) {
    if (_sealed || isClosed || accountGeneration != _accountGeneration) {
      return Future<void>.error(
        AvatarRendererResetFailedException(_rendererIdentity.label),
      );
    }
    _rendererFenceGeneration += 1;
    for (final operation in _inFlightDispatches.values) {
      operation._revoke();
    }
    return _enqueue(
      () => _resetRendererForMount(
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
      ),
    );
  }

  Future<AvatarCommandReceipt> acquire(AvatarCommandLeaseRequest request) {
    if (_sealed || isClosed) {
      return Future<AvatarCommandReceipt>.value(
        _reject(
          disposition: AvatarCommandReceiptDisposition.rejectedSealed,
          accountGeneration: request.accountGeneration,
          rendererGeneration: request.rendererGeneration,
          channel: request.command.channel,
          source: request.source,
          commandGeneration: request.commandGeneration,
        ),
      );
    }
    return _enqueue(() => _acquire(request));
  }

  Future<AvatarCommandReceipt> release(AvatarCommandReleaseRequest request) {
    if (_sealed || isClosed) {
      return Future<AvatarCommandReceipt>.value(
        _reject(
          disposition: AvatarCommandReceiptDisposition.rejectedSealed,
          accountGeneration: request.accountGeneration,
          rendererGeneration: request.rendererGeneration,
          channel: request.channel,
          source: request.source,
          commandGeneration: request.commandGeneration,
        ),
      );
    }
    return _enqueue(() => _release(request));
  }

  Future<List<AvatarCommandReceipt>> expireLeases() {
    if (_sealed || isClosed) {
      return Future<List<AvatarCommandReceipt>>.value(const []);
    }
    return _enqueue(_expireLeases);
  }

  Future<void> waitForIdle() => _mutationTail;

  Future<void> sealAndDrain({bool requireRendererResetForNextOwner = false}) {
    if (requireRendererResetForNextOwner) {
      _requireRendererResetForNextOwner = true;
    }
    final current = _sealFuture;
    if (current != null) {
      return requireRendererResetForNextOwner
          ? current.then((_) => _ensureRendererResetForNextOwner())
          : current;
    }
    _sealed = true;
    _cancelExpiry();
    final retiringChannels = <AvatarCommandChannel>{
      ..._dirtyChannels,
      ..._inFlightDispatches.entries
          .where((entry) => !entry.value.dispatch.clearsChannel)
          .map((entry) => entry.key),
    };
    if (retiringChannels.isNotEmpty) {
      _retirementRequirement = _retirementGuard._beginRetirement(
        rendererIdentity: _rendererIdentity,
        retiredAccountGeneration: _accountGeneration,
        retiredRendererGeneration: _rendererGeneration,
        dirtyChannels: retiringChannels,
      );
    }
    for (final operation in _inFlightDispatches.values) {
      operation._revoke();
    }
    final sealing = _enqueue(_sealAndClear);
    _sealFuture = sealing;
    return requireRendererResetForNextOwner
        ? sealing.then((_) => _ensureRendererResetForNextOwner())
        : sealing;
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<List<AvatarCommandReceipt>> _bindRenderer({
    required int accountGeneration,
    required int rendererGeneration,
    required bool ready,
    required AvatarCommandCapabilities capabilities,
  }) async {
    if (accountGeneration != _accountGeneration) {
      return <AvatarCommandReceipt>[
        _reject(
          disposition: AvatarCommandReceiptDisposition.rejectedStaleAccount,
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
        ),
      ];
    }
    if (rendererGeneration < _rendererGeneration) {
      return <AvatarCommandReceipt>[
        _reject(
          disposition: AvatarCommandReceiptDisposition.rejectedStaleRenderer,
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
        ),
      ];
    }

    if (_retirementGuard._pendingFor(_rendererIdentity) != null) {
      return <AvatarCommandReceipt>[
        _reject(
          disposition: AvatarCommandReceiptDisposition.rendererResetRequired,
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
        ),
      ];
    }

    if (!_ownsRendererGeneration(_rendererGeneration)) {
      final claimed = _retirementGuard._claimOwner(
        rendererIdentity: _rendererIdentity,
        arbiterNonce: _arbiterNonce,
        accountGeneration: _accountGeneration,
        rendererGeneration: rendererGeneration,
      );
      if (claimed == null) {
        return <AvatarCommandReceipt>[
          _reject(
            disposition:
                AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
            accountGeneration: accountGeneration,
            rendererGeneration: rendererGeneration,
          ),
        ];
      }
      _ownerLease = claimed;
    }

    if (_rendererReady && !ready) {
      final receipts = await _neutralizeBeforeUnavailable();
      _rendererReady = false;
      _capabilities = capabilities;
      if (_dirtyChannels.isNotEmpty) {
        _requireRendererReset();
        receipts.add(
          _reject(
            disposition: AvatarCommandReceiptDisposition.rendererResetRequired,
            accountGeneration: accountGeneration,
            rendererGeneration: rendererGeneration,
          ),
        );
        return receipts;
      }
      _ownerLease = _retirementGuard._claimOwner(
        rendererIdentity: _rendererIdentity,
        arbiterNonce: _arbiterNonce,
        accountGeneration: _accountGeneration,
        rendererGeneration: rendererGeneration,
      );
      _rendererGeneration = rendererGeneration;
      _applied.clear();
      return receipts;
    }

    if (rendererGeneration != _rendererGeneration &&
        _dirtyChannels.isNotEmpty) {
      _requireRendererReset();
      return <AvatarCommandReceipt>[
        _reject(
          disposition: AvatarCommandReceiptDisposition.rendererResetRequired,
          accountGeneration: accountGeneration,
          rendererGeneration: rendererGeneration,
        ),
      ];
    } else if (rendererGeneration != _rendererGeneration) {
      _applied.clear();
    }

    if (rendererGeneration != _rendererGeneration) {
      final claimed = _retirementGuard._claimOwner(
        rendererIdentity: _rendererIdentity,
        arbiterNonce: _arbiterNonce,
        accountGeneration: _accountGeneration,
        rendererGeneration: rendererGeneration,
      );
      if (claimed == null) {
        return <AvatarCommandReceipt>[
          _reject(
            disposition:
                AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
            accountGeneration: accountGeneration,
            rendererGeneration: rendererGeneration,
          ),
        ];
      }
      _ownerLease = claimed;
    }

    _rendererGeneration = rendererGeneration;
    _rendererReady = ready;
    _capabilities = capabilities;

    final receipts = <AvatarCommandReceipt>[];
    for (final channel in AvatarCommandChannel.values) {
      if (_activeLeases(channel, _clock()).isEmpty &&
          !_dirtyChannels.contains(channel)) {
        continue;
      }
      receipts.add(
        await _reconcile(
          channel: channel,
          requestedSource: null,
          commandGeneration: null,
          successDisposition: AvatarCommandReceiptDisposition.dispatched,
        ),
      );
    }
    return receipts;
  }

  Future<void> _resetRendererForMount({
    required int accountGeneration,
    required int rendererGeneration,
  }) async {
    final requirement = _retirementGuard._pendingFor(_rendererIdentity);
    if (requirement == null ||
        !_retirementGuard._canReset(requirement) ||
        rendererGeneration <= requirement.retiredRendererGeneration) {
      throw AvatarRendererResetFailedException(_rendererIdentity.label);
    }
    late final AvatarRendererResetOperation operation;
    operation = AvatarRendererResetOperation._(
      requirementId: requirement.requirementId,
      rendererIdentity: _rendererIdentity,
      rendererId: _rendererIdentity.label,
      retiredAccountGeneration: requirement.retiredAccountGeneration,
      retiredRendererGeneration: requirement.retiredRendererGeneration,
      targetAccountGeneration: accountGeneration,
      targetRendererGeneration: rendererGeneration,
      targetArbiterNonce: _arbiterNonce,
      isCurrent: () =>
          identical(
            _retirementGuard._pendingFor(_rendererIdentity),
            requirement,
          ) &&
          _retirementGuard._canReset(requirement),
    );
    try {
      final receipt = await Future<AvatarRendererResetReceipt>.sync(
        () => _dispatchSink.resetOrDispose(operation),
      ).timeout(dispatchTimeout);
      final matches =
          receipt.requirementId == operation.requirementId &&
          identical(receipt._rendererIdentity, operation._rendererIdentity) &&
          receipt.rendererId == operation.rendererId &&
          receipt.retiredAccountGeneration ==
              operation.retiredAccountGeneration &&
          receipt.retiredRendererGeneration ==
              operation.retiredRendererGeneration &&
          receipt.targetAccountGeneration ==
              operation.targetAccountGeneration &&
          receipt.resetRendererGeneration ==
              operation.targetRendererGeneration &&
          identical(receipt._targetArbiterNonce, operation._targetArbiterNonce);
      final owner = matches && operation.isCurrent
          ? _retirementGuard._consumeResetReceipt(receipt)
          : null;
      if (owner == null) {
        throw AvatarRendererResetFailedException(_rendererIdentity.label);
      }
      _ownerLease = owner;
      _rendererGeneration = rendererGeneration;
      _dirtyChannels.clear();
      _applied.clear();
      _rendererReady = false;
    } on AvatarRendererResetFailedException {
      rethrow;
    } on Object {
      throw AvatarRendererResetFailedException(_rendererIdentity.label);
    } finally {
      operation._revoke();
    }
  }

  Future<List<AvatarCommandReceipt>> _neutralizeBeforeUnavailable() async {
    final receipts = <AvatarCommandReceipt>[];
    for (final channel in AvatarCommandChannel.values.where(
      _dirtyChannels.contains,
    )) {
      receipts.add(
        await _dispatch(
          channel: channel,
          requestedSource: null,
          selected: null,
          commandGeneration: null,
          successDisposition: AvatarCommandReceiptDisposition.released,
          forceNeutralClear: true,
        ),
      );
    }
    return receipts;
  }

  Future<AvatarCommandReceipt> _acquire(
    AvatarCommandLeaseRequest request,
  ) async {
    if (_sealed || isClosed) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedSealed,
        accountGeneration: request.accountGeneration,
        rendererGeneration: request.rendererGeneration,
        channel: request.command.channel,
        source: request.source,
        commandGeneration: request.commandGeneration,
      );
    }
    final rejection = _validateFence(
      accountGeneration: request.accountGeneration,
      rendererGeneration: request.rendererGeneration,
      channel: request.command.channel,
      source: request.source,
      commandGeneration: request.commandGeneration,
      strictIncrease: true,
    );
    if (rejection != null) return rejection;
    if ((request.source == AvatarCommandSource.ttsMouth) !=
        (request.command.channel == AvatarCommandChannel.mouth)) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedInvalidSource,
        accountGeneration: request.accountGeneration,
        rendererGeneration: request.rendererGeneration,
        channel: request.command.channel,
        source: request.source,
        commandGeneration: request.commandGeneration,
      );
    }

    final canonicalCommand = _canonicalCommand(request.command);
    if (canonicalCommand == null) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedInvalidCommand,
        accountGeneration: request.accountGeneration,
        rendererGeneration: request.rendererGeneration,
        channel: request.command.channel,
        source: request.source,
        commandGeneration: request.commandGeneration,
      );
    }

    final channel = canonicalCommand.channel;
    if (!_ownsRendererGeneration(_rendererGeneration)) {
      return _record(
        _receipt(
          channel: channel,
          requestedSource: request.source,
          selected: _eligibleLease(channel, _clock()),
          disposition:
              AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
          commandGeneration: request.commandGeneration,
        ),
      );
    }
    final key = (channel, request.source);
    _lastCommandGenerations[key] = request.commandGeneration;
    final channelLeases = _leases.putIfAbsent(
      channel,
      () => <AvatarCommandSource, _AvatarLease>{},
    );
    channelLeases[request.source] = _AvatarLease(
      leaseId: request.leaseId,
      source: request.source,
      commandGeneration: request.commandGeneration,
      command: canonicalCommand,
      expiresAt: _clock().add(request.ttl),
    );
    _rescheduleExpiry();
    return _reconcile(
      channel: channel,
      requestedSource: request.source,
      commandGeneration: request.commandGeneration,
      successDisposition: AvatarCommandReceiptDisposition.dispatched,
    );
  }

  Future<AvatarCommandReceipt> _release(
    AvatarCommandReleaseRequest request,
  ) async {
    if ((request.source == AvatarCommandSource.ttsMouth) !=
        (request.channel == AvatarCommandChannel.mouth)) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedInvalidSource,
        accountGeneration: request.accountGeneration,
        rendererGeneration: request.rendererGeneration,
        channel: request.channel,
        source: request.source,
        commandGeneration: request.commandGeneration,
      );
    }
    final rejection = _validateFence(
      accountGeneration: request.accountGeneration,
      rendererGeneration: request.rendererGeneration,
      channel: request.channel,
      source: request.source,
      commandGeneration: request.commandGeneration,
      strictIncrease: false,
    );
    if (rejection != null) return rejection;
    if (!_ownsRendererGeneration(_rendererGeneration)) {
      return _record(
        _receipt(
          channel: request.channel,
          requestedSource: request.source,
          selected: _eligibleLease(request.channel, _clock()),
          disposition:
              AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
          commandGeneration: request.commandGeneration,
        ),
      );
    }
    final lease = _leases[request.channel]?[request.source];
    if (lease == null) {
      return _record(
        _receipt(
          channel: request.channel,
          requestedSource: request.source,
          selected: _eligibleLease(request.channel, _clock()),
          disposition: AvatarCommandReceiptDisposition.noLease,
          commandGeneration: request.commandGeneration,
        ),
      );
    }
    if (lease.commandGeneration != request.commandGeneration) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedStaleCommand,
        accountGeneration: request.accountGeneration,
        rendererGeneration: request.rendererGeneration,
        channel: request.channel,
        source: request.source,
        commandGeneration: request.commandGeneration,
      );
    }
    _leases[request.channel]!.remove(request.source);
    _rescheduleExpiry();
    return _reconcile(
      channel: request.channel,
      requestedSource: request.source,
      commandGeneration: request.commandGeneration,
      successDisposition: AvatarCommandReceiptDisposition.released,
    );
  }

  Future<List<AvatarCommandReceipt>> _expireLeases({DateTime? cutoff}) async {
    final now = cutoff ?? _clock();
    final expiredChannels = <AvatarCommandChannel>{};
    for (final entry in _leases.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((_, lease) => !lease.expiresAt.isAfter(now));
      if (entry.value.length != before) expiredChannels.add(entry.key);
    }
    _rescheduleExpiry();
    final receipts = <AvatarCommandReceipt>[];
    for (final channel in expiredChannels) {
      receipts.add(
        await _reconcile(
          channel: channel,
          requestedSource: null,
          commandGeneration: null,
          successDisposition: AvatarCommandReceiptDisposition.expired,
        ),
      );
    }
    return receipts;
  }

  AvatarCommandReceipt? _validateFence({
    required int accountGeneration,
    required int rendererGeneration,
    required AvatarCommandChannel channel,
    required AvatarCommandSource source,
    required int commandGeneration,
    required bool strictIncrease,
  }) {
    if (accountGeneration != _accountGeneration) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedStaleAccount,
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        channel: channel,
        source: source,
        commandGeneration: commandGeneration,
      );
    }
    if (rendererGeneration != _rendererGeneration) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedStaleRenderer,
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        channel: channel,
        source: source,
        commandGeneration: commandGeneration,
      );
    }
    final last = _lastCommandGenerations[(channel, source)] ?? 0;
    final stale = strictIncrease
        ? commandGeneration <= last
        : commandGeneration < last;
    if (stale) {
      return _reject(
        disposition: AvatarCommandReceiptDisposition.rejectedStaleCommand,
        accountGeneration: accountGeneration,
        rendererGeneration: rendererGeneration,
        channel: channel,
        source: source,
        commandGeneration: commandGeneration,
      );
    }
    return null;
  }

  Future<AvatarCommandReceipt> _reconcile({
    required AvatarCommandChannel channel,
    required AvatarCommandSource? requestedSource,
    required int? commandGeneration,
    required AvatarCommandReceiptDisposition successDisposition,
  }) async {
    final now = _clock();
    final desired = _desiredLease(channel, now);
    final selected = _eligibleLease(channel, now);
    if (_retirementGuard._pendingFor(_rendererIdentity) != null) {
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: selected,
          disposition: AvatarCommandReceiptDisposition.rendererResetRequired,
          commandGeneration: commandGeneration,
        ),
      );
    }
    if (!_ownsRendererGeneration(_rendererGeneration)) {
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: selected,
          disposition:
              AvatarCommandReceiptDisposition.rendererOwnedByAnotherArbiter,
          commandGeneration: commandGeneration,
        ),
      );
    }
    if (!_rendererReady) {
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: selected,
          disposition: AvatarCommandReceiptDisposition.rendererNotReady,
          commandGeneration: commandGeneration,
        ),
      );
    }
    if (desired != null && selected == null) {
      if (_dirtyChannels.contains(channel)) {
        return _dispatch(
          channel: channel,
          requestedSource: requestedSource,
          selected: null,
          commandGeneration: commandGeneration,
          successDisposition:
              AvatarCommandReceiptDisposition.capabilityUnavailable,
        );
      }
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: null,
          disposition: AvatarCommandReceiptDisposition.capabilityUnavailable,
          commandGeneration: commandGeneration,
        ),
      );
    }

    if (selected == null) {
      if (_dirtyChannels.contains(channel)) {
        return _dispatch(
          channel: channel,
          requestedSource: requestedSource,
          selected: null,
          commandGeneration: commandGeneration,
          successDisposition: successDisposition,
        );
      }
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: null,
          disposition: successDisposition,
          commandGeneration: commandGeneration,
        ),
      );
    }

    final fingerprint = _fingerprint(selected.command);
    final prior = _applied[channel];
    if (prior != null &&
        prior.source == selected.source &&
        prior.commandGeneration == selected.commandGeneration &&
        prior.fingerprint == fingerprint) {
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: selected,
          disposition: requestedSource == null
              ? successDisposition
              : AvatarCommandReceiptDisposition.retainedBehindHigherPriority,
          commandGeneration: commandGeneration,
        ),
      );
    }

    final fallback = desired != null && desired != selected;
    return _dispatch(
      channel: channel,
      requestedSource: requestedSource,
      selected: selected,
      commandGeneration: commandGeneration,
      successDisposition: fallback
          ? AvatarCommandReceiptDisposition.capabilityFallback
          : successDisposition,
    );
  }

  Future<AvatarCommandReceipt> _dispatch({
    required AvatarCommandChannel channel,
    required AvatarCommandSource? requestedSource,
    required _AvatarLease? selected,
    required int? commandGeneration,
    required AvatarCommandReceiptDisposition successDisposition,
    bool allowWhenSealed = false,
    bool forceNeutralClear = false,
  }) async {
    final command = selected?.command;
    final desiredFingerprint = command == null ? '' : _fingerprint(command);
    final rendererFenceGeneration = _rendererFenceGeneration;
    final ownerLease = _ownerLease;
    final rendererDeadline = _earlierDeadline(
      _clock().add(dispatchTimeout),
      selected?.expiresAt,
    );
    final dispatch = AvatarCommandDispatch(
      rendererId: _rendererIdentity.label,
      accountGeneration: _accountGeneration,
      rendererGeneration: _rendererGeneration,
      channel: channel,
      source: selected?.source,
      commandGeneration: selected?.commandGeneration,
      command: command,
    );
    _dispatchTicket += 1;
    late final AvatarCommandDispatchOperation operation;
    operation = AvatarCommandDispatchOperation._(
      ticket: _dispatchTicket,
      dispatch: dispatch,
      validUntil: selected?.expiresAt,
      rendererDeadline: rendererDeadline,
      desiredFingerprint: desiredFingerprint,
      rendererOwnerToken: _arbiterNonce.transportToken,
      isCurrent: () =>
          identical(_inFlightDispatches[channel], operation) &&
          rendererFenceGeneration == _rendererFenceGeneration &&
          operation.dispatch.accountGeneration == _accountGeneration &&
          operation.dispatch.rendererGeneration == _rendererGeneration &&
          _retirementGuard._isActiveOwner(ownerLease) &&
          identical(_ownerLease, ownerLease) &&
          ownerLease!.accountGeneration == _accountGeneration &&
          ownerLease.rendererGeneration == _rendererGeneration &&
          !_clock().isAfter(rendererDeadline) &&
          _rendererReady &&
          (allowWhenSealed || !_sealed) &&
          _dispatchDesiredStateIsCurrent(
            channel: channel,
            selected: selected,
            allowWhenSealed: allowWhenSealed,
            forceNeutralClear: forceNeutralClear,
          ),
    );
    _inFlightDispatches[channel] = operation;
    try {
      final sinkFuture = Future<AvatarCommandDispatchReceipt>.sync(
        () => _dispatchSink.dispatch(operation),
      );
      unawaited(
        sinkFuture.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
      final receipt = await sinkFuture.timeout(dispatchTimeout);
      if (!operation.wasApplied ||
          !operation.isCurrent ||
          !_receiptMatchesOperation(receipt, operation)) {
        throw StateError('avatar_dispatch_not_applied');
      }
      if (selected != null) {
        _applied[channel] = _AppliedAvatarLease(
          source: selected.source,
          commandGeneration: selected.commandGeneration,
          fingerprint: _fingerprint(selected.command),
        );
        _dirtyChannels.add(channel);
      } else {
        _applied.remove(channel);
        _dirtyChannels.remove(channel);
      }
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: selected,
          disposition: successDisposition,
          commandGeneration: commandGeneration,
        ),
      );
    } on Object {
      // Entering the callback makes renderer state uncertain even if it throws
      // after only a partial write. Never retain a dedupe candidate without an
      // exact receipt. Non-neutral attempts become dirty; neutral attempts keep
      // the pre-existing dirty marker until their acknowledgement is verified.
      if (operation.mayHaveMutated) {
        _applied.remove(channel);
        if (selected != null) _dirtyChannels.add(channel);
        if (operation.usedRendererPermit) {
          _rendererReady = false;
          _requireRendererReset();
        }
      }
      return _record(
        _receipt(
          channel: channel,
          requestedSource: requestedSource,
          selected: selected,
          disposition: AvatarCommandReceiptDisposition.dispatchFailed,
          commandGeneration: commandGeneration,
        ),
      );
    } finally {
      if (identical(_inFlightDispatches[channel], operation)) {
        _inFlightDispatches.remove(channel);
      }
      operation._revoke();
    }
  }

  bool _dispatchDesiredStateIsCurrent({
    required AvatarCommandChannel channel,
    required _AvatarLease? selected,
    required bool allowWhenSealed,
    required bool forceNeutralClear,
  }) {
    if (selected == null) {
      if (!_dirtyChannels.contains(channel)) return false;
      return allowWhenSealed ||
          forceNeutralClear ||
          _eligibleLease(channel, _clock()) == null;
    }
    final now = _clock();
    if (!selected.expiresAt.isAfter(now) ||
        !identical(_leases[channel]?[selected.source], selected) ||
        !_capabilities.supports(selected.command)) {
      return false;
    }
    return identical(_eligibleLease(channel, now), selected);
  }

  static bool _receiptMatchesOperation(
    AvatarCommandDispatchReceipt receipt,
    AvatarCommandDispatchOperation operation,
  ) {
    final dispatch = operation.dispatch;
    return receipt.ticket == operation.ticket &&
        receipt.rendererId == dispatch.rendererId &&
        receipt.accountGeneration == dispatch.accountGeneration &&
        receipt.rendererGeneration == dispatch.rendererGeneration &&
        receipt.channel == dispatch.channel &&
        receipt.desiredFingerprint == operation.desiredFingerprint &&
        receipt.clearsChannel == dispatch.clearsChannel;
  }

  _AvatarLease? _desiredLease(AvatarCommandChannel channel, DateTime now) {
    final active = _activeLeases(channel, now);
    return active.isEmpty ? null : active.first;
  }

  _AvatarLease? _eligibleLease(AvatarCommandChannel channel, DateTime now) {
    for (final lease in _activeLeases(channel, now)) {
      if (_capabilities.supports(lease.command)) return lease;
    }
    return null;
  }

  List<_AvatarLease> _activeLeases(AvatarCommandChannel channel, DateTime now) {
    final active = (_leases[channel]?.values ?? const <_AvatarLease>[])
        .where((lease) => lease.expiresAt.isAfter(now))
        .toList(growable: false);
    active.sort((left, right) {
      final byPriority = _priority(
        right.source,
      ).compareTo(_priority(left.source));
      return byPriority != 0
          ? byPriority
          : right.commandGeneration.compareTo(left.commandGeneration);
    });
    return active;
  }

  AvatarCommandReceipt _receipt({
    required AvatarCommandChannel channel,
    required AvatarCommandSource? requestedSource,
    required _AvatarLease? selected,
    required AvatarCommandReceiptDisposition disposition,
    required int? commandGeneration,
  }) => AvatarCommandReceipt(
    channel: channel,
    requestedSource: requestedSource,
    selectedSource: selected?.source,
    disposition: disposition,
    accountGeneration: _accountGeneration,
    rendererGeneration: _rendererGeneration,
    commandGeneration: commandGeneration,
    fingerprint: selected == null ? '' : _fingerprint(selected.command),
    activeLeaseCount: _activeLeases(channel, _clock()).length,
  );

  AvatarCommandReceipt _reject({
    required AvatarCommandReceiptDisposition disposition,
    required int accountGeneration,
    required int rendererGeneration,
    AvatarCommandChannel? channel,
    AvatarCommandSource? source,
    int? commandGeneration,
  }) => _record(
    AvatarCommandReceipt(
      channel: channel,
      requestedSource: source,
      selectedSource: null,
      disposition: disposition,
      accountGeneration: accountGeneration,
      rendererGeneration: rendererGeneration,
      commandGeneration: commandGeneration,
      fingerprint: '',
      activeLeaseCount: channel == null
          ? 0
          : _activeLeases(channel, _clock()).length,
    ),
  );

  AvatarCommandReceipt _record(AvatarCommandReceipt receipt) {
    if (_recentReceipts.length == maximumRecentReceipts) {
      _recentReceipts.removeFirst();
    }
    _recentReceipts.addLast(receipt);
    return receipt;
  }

  static int _priority(AvatarCommandSource source) => switch (source) {
    AvatarCommandSource.ttsMouth => 5,
    AvatarCommandSource.explicitUser => 4,
    AvatarCommandSource.explicitAgent => 3,
    AvatarCommandSource.scene => 2,
    AvatarCommandSource.auto => 1,
    AvatarCommandSource.idle => 0,
  };

  String _fingerprint(AvatarChannelCommand command) => sha256
      .convert(
        utf8.encode('$_receiptSalt|${jsonEncode(command.toCanonicalJson())}'),
      )
      .toString()
      .substring(0, 16);

  Future<void> _sealAndClear() async {
    _cancelExpiry();
    _leases.clear();
    _lastCommandGenerations.clear();
    final channels = AvatarCommandChannel.values
        .where(_dirtyChannels.contains)
        .toList(growable: false);
    for (final channel in channels) {
      if (!_rendererReady) break;
      final receipt = await _dispatch(
        channel: channel,
        requestedSource: null,
        selected: null,
        commandGeneration: null,
        successDisposition: AvatarCommandReceiptDisposition.released,
        allowWhenSealed: true,
      );
      if (receipt.disposition ==
          AvatarCommandReceiptDisposition.dispatchFailed) {
        continue;
      }
    }
    if (_dirtyChannels.isNotEmpty) {
      throw AvatarRendererResetRequiredException(_requireRendererReset());
    }
    _applied.clear();
    if (_requireRendererResetForNextOwner) {
      _ensureRendererResetForNextOwner();
    } else {
      final retirement = _retirementRequirement;
      if (retirement != null &&
          retirement.retiredAccountGeneration == _accountGeneration &&
          retirement.retiredRendererGeneration == _rendererGeneration) {
        _retirementGuard._confirmNeutralClear(retirement);
      }
    }
    _retirementGuard._releaseOwner(_ownerLease);
    _ownerLease = null;
  }

  void _ensureRendererResetForNextOwner() {
    final pending = _retirementGuard._pendingFor(_rendererIdentity);
    if (pending != null &&
        pending.retiredAccountGeneration == _accountGeneration &&
        pending.retiredRendererGeneration == _rendererGeneration &&
        _retirementGuard._canReset(pending)) {
      _retirementRequirement = pending;
      return;
    }
    if (!_retirementGuard._canBeginRetirement(
      rendererIdentity: _rendererIdentity,
      arbiterNonce: _arbiterNonce,
      accountGeneration: _accountGeneration,
      rendererGeneration: _rendererGeneration,
    )) {
      return;
    }
    _retirementRequirement = _retirementGuard._requireReset(
      rendererIdentity: _rendererIdentity,
      retiredAccountGeneration: _accountGeneration,
      retiredRendererGeneration: _rendererGeneration,
      dirtyChannels: _dirtyChannels,
    );
  }

  bool _ownsRendererGeneration(int rendererGeneration) {
    final owner = _ownerLease;
    return _retirementGuard._isActiveOwner(owner) &&
        identical(owner?.arbiterNonce, _arbiterNonce) &&
        owner?.accountGeneration == _accountGeneration &&
        owner?.rendererGeneration == rendererGeneration;
  }

  AvatarRendererResetRequirement _requireRendererReset() =>
      _retirementGuard._requireReset(
        rendererIdentity: _rendererIdentity,
        retiredAccountGeneration: _accountGeneration,
        retiredRendererGeneration: _rendererGeneration,
        dirtyChannels: _dirtyChannels,
      );

  void _rescheduleExpiry() {
    _cancelExpiry();
    if (_sealed) return;
    DateTime? earliest;
    for (final channel in _leases.values) {
      for (final lease in channel.values) {
        if (earliest == null || lease.expiresAt.isBefore(earliest)) {
          earliest = lease.expiresAt;
        }
      }
    }
    if (earliest == null) return;
    final deadline = earliest;
    final now = _clock();
    final delay = deadline.difference(now);
    final generation = ++_expiryScheduleGeneration;
    _expiryHandle = _scheduleExpiry(
      delay.isNegative ? Duration.zero : delay,
      () {
        if (_sealed || generation != _expiryScheduleGeneration) return;
        _expiryHandle = null;
        unawaited(_enqueue(() => _expireLeases(cutoff: deadline)));
      },
    );
  }

  void _cancelExpiry() {
    _expiryScheduleGeneration += 1;
    _expiryHandle?.cancel();
    _expiryHandle = null;
  }

  @override
  void onClose() {
    unawaited(sealAndDrain().catchError((Object _, StackTrace _) {}));
    super.onClose();
  }

  static _AvatarRendererInstanceIdentity _identityFor(
    AvatarCommandDispatchSink sink,
  ) {
    final current = _rendererIdentities[sink];
    if (current != null) return current;
    final created = _AvatarRendererInstanceIdentity(++_rendererIdentitySerial);
    _rendererIdentities[sink] = created;
    return created;
  }

  static _AvatarArbiterNonce _newArbiterNonce() =>
      _AvatarArbiterNonce(++_arbiterNonceSerial, _newOpaqueToken());

  static AvatarLeaseExpiryHandle _scheduleTimerExpiry(
    Duration delay,
    void Function() callback,
  ) => _AvatarTimerExpiryHandle(Timer(delay, callback));

  static String _newReceiptSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}

final class _AvatarTimerExpiryHandle implements AvatarLeaseExpiryHandle {
  const _AvatarTimerExpiryHandle(this.timer);

  final Timer timer;

  @override
  void cancel() => timer.cancel();
}

final class _AvatarLease {
  const _AvatarLease({
    required this.leaseId,
    required this.source,
    required this.commandGeneration,
    required this.command,
    required this.expiresAt,
  });

  final String leaseId;
  final AvatarCommandSource source;
  final int commandGeneration;
  final AvatarChannelCommand command;
  final DateTime expiresAt;
}

final class _AppliedAvatarLease {
  const _AppliedAvatarLease({
    required this.source,
    required this.commandGeneration,
    required this.fingerprint,
  });

  final AvatarCommandSource source;
  final int commandGeneration;
  final String fingerprint;
}

AvatarChannelCommand? _canonicalCommand(AvatarChannelCommand command) {
  if (command is AvatarExpressionCommand) {
    final params = command.params;
    final values = <double>[
      params.happy,
      params.sad,
      params.angry,
      params.surprised,
      params.love,
      params.relaxed,
      params.thinking,
      params.tired,
      params.mouthSmile,
      params.mouthOpen,
      params.eyeOpen,
      params.browConcern,
    ];
    if (values.any((value) => !value.isFinite)) return null;
    double unit(double value) => value.clamp(0.0, 1.0).toDouble();
    return AvatarExpressionCommand(
      AvatarExpressionParams(
        happy: unit(params.happy),
        sad: unit(params.sad),
        angry: unit(params.angry),
        surprised: unit(params.surprised),
        love: unit(params.love),
        relaxed: unit(params.relaxed),
        thinking: unit(params.thinking),
        tired: unit(params.tired),
        mouthSmile: unit(params.mouthSmile),
        mouthOpen: 0,
        eyeOpen: unit(params.eyeOpen),
        browConcern: unit(params.browConcern),
      ),
    );
  }
  if (command is AvatarGazeCommand) {
    final gaze = command.gaze;
    final values = <double>[
      gaze.eyeX,
      gaze.eyeY,
      gaze.headX,
      gaze.headY,
      gaze.headRoll,
      gaze.upperBodyX,
    ];
    if (values.any((value) => !value.isFinite)) return null;
    double axis(double value) => value.clamp(-1.0, 1.0).toDouble();
    return AvatarGazeCommand(
      AvatarGaze(
        eyeX: axis(gaze.eyeX),
        eyeY: axis(gaze.eyeY),
        headX: axis(gaze.headX),
        headY: axis(gaze.headY),
        headRoll: axis(gaze.headRoll),
        upperBodyX: axis(gaze.upperBodyX),
      ),
    );
  }
  return command;
}

String _canonicalRendererPayload(
  AvatarCommandDispatch dispatch, {
  required DateTime? validUntil,
}) {
  final command = dispatch.command;
  final payload = command == null
      ? <String, Object?>{'channel': dispatch.channel.name, 'clear': true}
      : command.toCanonicalJson();
  if (command is AvatarBodyGestureCommand && command.energy != null) {
    final leaseExpiresAtEpochMs = validUntil?.millisecondsSinceEpoch;
    if (leaseExpiresAtEpochMs == null || leaseExpiresAtEpochMs <= 0) {
      throw ArgumentError('missing_avatar_performance_lease_expiry');
    }
    // Renderer mutation ACK time and body ownership lifetime are different:
    // a normal 500ms dispatch deadline must not shorten a 3.5s performance.
    // Only the renderer payload gains this trusted, digest-bound transport
    // field; the command's semantic payload/fingerprint remains five fields.
    payload['leaseExpiresAtEpochMs'] = leaseExpiresAtEpochMs;
  }
  return jsonEncode(payload);
}

DateTime _earlierDeadline(DateTime dispatchDeadline, DateTime? leaseDeadline) {
  if (leaseDeadline == null || dispatchDeadline.isBefore(leaseDeadline)) {
    return dispatchDeadline;
  }
  return leaseDeadline;
}

String _newOpaqueToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64UrlEncode(bytes).replaceAll('=', '');
}

double _finiteUnit(double value, {required String argumentName}) {
  if (!value.isFinite) throw ArgumentError.value(value, argumentName);
  return value.clamp(0.0, 1.0).toDouble();
}

String _boundedIdentifier(String value, {required String argumentName}) {
  final normalized = value.trim().toLowerCase();
  if (normalized.isEmpty ||
      normalized.length > 64 ||
      !RegExp(r'^[a-z0-9][a-z0-9._:-]*$').hasMatch(normalized)) {
    throw ArgumentError.value(value, argumentName);
  }
  return normalized;
}
