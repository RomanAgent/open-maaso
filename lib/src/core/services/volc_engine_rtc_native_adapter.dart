import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:volc_engine_rtc/codegen/pack/api.dart' as rtc_pack;
import 'package:volc_engine_rtc/codegen/pack/keytype.dart'
    show RoomState, RoomStateChangeReason;
import 'package:volc_engine_rtc/volc_engine_rtc.dart';

typedef VolcRtcEngineFactory =
    Future<RTCEngine> Function(RTCVideoContext context);
typedef VolcRtcEngineDestroyer = Future<void> Function(RTCEngine engine);
typedef VolcRtcRoomJoiner =
    Future<int?> Function(
      RTCRoom room,
      VolcRtcJoinConfig config, {
      required bool publishAudio,
      required bool publishVideo,
      required bool autoSubscribeAudio,
      required bool autoSubscribeVideo,
    });

class VolcEngineRtcNativeAdapter implements VolcRtcNativeAdapter {
  VolcEngineRtcNativeAdapter({
    IRTCEngineEventHandler? engineEventHandler,
    IRTCRoomEventHandler? roomEventHandler,
    this.publishAudio = true,
    this.publishVideo = false,
    this.autoSubscribeAudio = true,
    this.autoSubscribeVideo = false,
    this.roomStateTimeout = const Duration(seconds: 5),
    VolcRtcEngineFactory? createEngine,
    VolcRtcEngineDestroyer? destroyEngine,
    VolcRtcRoomJoiner? joinRoom,
  }) : _engineEventHandler = engineEventHandler ?? IRTCEngineEventHandler(),
       _externalRoomEventHandler = roomEventHandler,
       _createEngine = createEngine ?? RTCEngine.createRTCEngine,
       _destroyEngine = destroyEngine ?? _destroyRtcEngine,
       _joinRoom = joinRoom ?? _joinRtcRoom;

  final IRTCEngineEventHandler _engineEventHandler;
  final IRTCRoomEventHandler? _externalRoomEventHandler;
  final bool publishAudio;
  final bool publishVideo;
  final bool autoSubscribeAudio;
  final bool autoSubscribeVideo;
  final Duration roomStateTimeout;
  final VolcRtcEngineFactory _createEngine;
  final VolcRtcEngineDestroyer _destroyEngine;
  final VolcRtcRoomJoiner _joinRoom;

  RTCEngine? _engine;
  RTCRoom? _room;
  Future<void>? _joinOperation;
  Future<void>? _retirementFuture;
  Future<void>? _interruptFuture;
  Future<void>? _resourceCleanupFuture;
  int _generation = 0;
  bool _retiring = false;
  bool _audioCaptureMayBeActive = false;
  bool _videoCaptureMayBeActive = false;
  _VolcRtcRoomCycle? _roomCycle;
  final StreamController<VolcRtcTerminalEvent> _terminalEvents =
      StreamController<VolcRtcTerminalEvent>.broadcast();
  bool _terminalEventsClosed = false;
  bool _terminalRetirementScheduled = false;

  @override
  Stream<VolcRtcTerminalEvent> get terminalEvents => _terminalEvents.stream;

  @override
  Future<void> join(VolcRtcJoinConfig config) {
    if (_retiring ||
        _terminalRetirementScheduled ||
        _joinOperation != null ||
        _retirementFuture != null ||
        _resourceCleanupFuture != null) {
      return Future<void>.error(
        StateError('The Volc RTC adapter is already changing sessions.'),
      );
    }
    final generation = ++_generation;
    late final Future<void> joining;
    joining = _joinOnce(config, generation).whenComplete(() {
      if (identical(_joinOperation, joining)) _joinOperation = null;
    });
    _joinOperation = joining;
    return joining;
  }

  Future<void> _joinOnce(VolcRtcJoinConfig config, int generation) async {
    try {
      await _cleanupResources();
      _requireCurrentJoin(generation);

      final engine = await _createEngine(
        RTCVideoContext(appId: config.appId, eventHandler: _engineEventHandler),
      );
      _engine = engine;
      _requireCurrentJoin(generation);

      await _configureRealtimeVoiceAudio(engine);
      _requireCurrentJoin(generation);

      if (publishAudio) {
        _audioCaptureMayBeActive = true;
        final result = await engine.startAudioCapture();
        _requireSuccess(result, 'start Volc RTC audio capture');
        _requireCurrentJoin(generation);
      }
      if (publishVideo) {
        _videoCaptureMayBeActive = true;
        final result = await engine.startVideoCapture();
        _requireSuccess(result, 'start Volc RTC video capture');
        _requireCurrentJoin(generation);
      }

      final room = await engine.createRTCRoom(config.roomId);
      if (room == null) {
        throw StateError('create Volc RTC room failed: ${config.roomId}');
      }
      final cycle = _VolcRtcRoomCycle(
        room: room,
        roomId: config.roomId,
        agentUserId: autoSubscribeAudio ? config.agentUserId : null,
      );
      try {
        final result = await room.setRTCRoomEventHandler(
          _roomEventHandlerFor(cycle),
        );
        _requireSuccess(result, 'configure Volc RTC room events');
      } catch (_) {
        _attachRoom(cycle);
        rethrow;
      }
      _attachRoom(cycle);
      _requireCurrentJoin(generation);

      final result = await _joinRoom(
        room,
        config,
        publishAudio: publishAudio,
        publishVideo: publishVideo,
        // Admit the Agent stream explicitly so a muted cold join cannot leak
        // audio while waiting for a post-join volume command.
        autoSubscribeAudio: autoSubscribeAudio && !cycle.controlsAgentAudio,
        autoSubscribeVideo: autoSubscribeVideo,
      );
      _requireSuccess(result, 'join Volc RTC room');
      cycle.joinInvocationAccepted = true;
      cycle.leaveRequired = true;
      _requireCurrentJoin(generation);
      await _awaitRoomJoin(cycle);
      _requireCurrentJoin(generation);
      await _syncAgentAudio(cycle);
      _requireCurrentJoin(generation);
    } catch (joinError, joinStackTrace) {
      try {
        await _cleanupResources();
      } catch (cleanupError, cleanupStackTrace) {
        Error.throwWithStackTrace(
          StateError(
            'Volc RTC join failed and cleanup is incomplete: '
            '$joinError; cleanup: $cleanupError',
          ),
          cleanupStackTrace,
        );
      }
      Error.throwWithStackTrace(joinError, joinStackTrace);
    }
  }

  void _attachRoom(_VolcRtcRoomCycle cycle) {
    if (_room != null) {
      throw StateError('Cannot replace an RTC room before it is retired.');
    }
    _room = cycle.room;
    _roomCycle = cycle;
    if (cycle.controlsAgentAudio) {
      cycle.unregisterSoundStopper = MaasoTtsPlugin.registerSoundStopper(
        () => _syncAgentAudio(cycle),
      );
      cycle.soundWorker = ever<bool>(MaasoTtsPlugin.soundEnabled, (enabled) {
        if (!enabled) return; // The mute barrier awaits its own sync operation.
        unawaited(
          _syncAgentAudio(cycle).catchError((Object error) {
            TurnTrace.event('rtc.agent_audio.sync_failed', details: '$error');
          }),
        );
      });
    }
  }

  IRTCRoomEventHandler _roomEventHandlerFor(_VolcRtcRoomCycle cycle) {
    final external = _externalRoomEventHandler;
    return IRTCRoomEventHandler(
      onLeaveRoom: (stats) async {
        _observeRoomExit(cycle);
        await external?.onLeaveRoom?.call(stats);
      },
      onRoomStateChangedWithReason: (roomId, uid, state, reason) async {
        _observeRoomState(cycle, roomId, state, reason);
        await external?.onRoomStateChangedWithReason?.call(
          roomId,
          uid,
          state,
          reason,
        );
      },
      onRoomStateChanged: (roomId, uid, state, extraInfo) async {
        _observeLegacyRoomState(cycle, roomId, state);
        await external?.onRoomStateChanged?.call(roomId, uid, state, extraInfo);
      },
      onStreamStateChanged: external?.onStreamStateChanged,
      onAVSyncStateChange: external?.onAVSyncStateChange,
      onRoomStats: external?.onRoomStats,
      onRoomEvent: external?.onRoomEvent,
      onUserJoined: external?.onUserJoined,
      onUserLeave: external?.onUserLeave,
      onVideoPublishStateChanged: external?.onVideoPublishStateChanged,
      onAudioPublishStateChanged: external?.onAudioPublishStateChanged,
      onVideoSubscribeStateChanged: external?.onVideoSubscribeStateChanged,
      onAudioSubscribeStateChanged: external?.onAudioSubscribeStateChanged,
      onLocalStreamStats: external?.onLocalStreamStats,
      onRemoteStreamStats: external?.onRemoteStreamStats,
      onStreamPublishSuccess: external?.onStreamPublishSuccess,
      onAVSyncEvent: external?.onAVSyncEvent,
      onUserPublishStreamVideo: external?.onUserPublishStreamVideo,
      onUserPublishStreamAudio: (streamId, info, isPublish) async {
        try {
          // Publications may arrive before handler installation or join finishes.
          if (cycle.controlsAgentAudio && !cycle.exitObserved) {
            if (isPublish) {
              cycle.audioPublishers[streamId] = info.userId;
            } else {
              cycle.audioPublishers.remove(streamId);
              cycle.audioSubscriptions.remove(streamId);
            }
            await _syncAgentAudio(cycle);
          }
        } finally {
          await external?.onUserPublishStreamAudio?.call(
            streamId,
            info,
            isPublish,
          );
        }
      },
      onRoomMessageReceived: external?.onRoomMessageReceived,
      onRoomBinaryMessageReceived: external?.onRoomBinaryMessageReceived,
      onUserMessageReceived: external?.onUserMessageReceived,
      onUserBinaryMessageReceived: external?.onUserBinaryMessageReceived,
      onUserMessageSendResult: external?.onUserMessageSendResult,
      onRoomMessageSendResult: external?.onRoomMessageSendResult,
      onVideoStreamBanned: external?.onVideoStreamBanned,
      onAudioStreamBanned: external?.onAudioStreamBanned,
      onForwardStreamStateChanged: external?.onForwardStreamStateChanged,
      onForwardStreamEvent: external?.onForwardStreamEvent,
      onNetworkQuality: external?.onNetworkQuality,
      onSetRoomExtraInfoResult: external?.onSetRoomExtraInfoResult,
      onRoomExtraInfoUpdate: external?.onRoomExtraInfoUpdate,
      onRoomStreamExtraInfoUpdate: external?.onRoomStreamExtraInfoUpdate,
      onUserVisibilityChanged: external?.onUserVisibilityChanged,
      onSubtitleStateChanged: external?.onSubtitleStateChanged,
      onSubtitleMessageReceived: external?.onSubtitleMessageReceived,
      onRoomWarning: external?.onRoomWarning,
      onTokenWillExpire: external?.onTokenWillExpire,
      onPublishPrivilegeTokenWillExpire:
          external?.onPublishPrivilegeTokenWillExpire,
      onSubscribePrivilegeTokenWillExpire:
          external?.onSubscribePrivilegeTokenWillExpire,
      onStreamSubscribed: external?.onStreamSubscribed,
    );
  }

  void _observeRoomState(
    _VolcRtcRoomCycle cycle,
    String roomId,
    RoomState state,
    RoomStateChangeReason reason,
  ) {
    if (!_isCurrentCycle(cycle, roomId)) return;
    switch (state) {
      case RoomState.success:
        if (!cycle.joinState.isCompleted) {
          cycle.joinConfirmed = true;
          cycle.joinState.complete();
        }
      case RoomState.failed:
        if (!cycle.joinState.isCompleted) {
          if (reason == RoomStateChangeReason.join_room_failed) return;
          cycle.joinFailure = StateError(
            'Volc RTC room join failed: ${reason.name}',
          );
          cycle.joinState.complete();
        } else if (_isTerminalReason(reason) && !cycle.leaveRequestStarted) {
          _reportTerminal(cycle, reason.name);
        }
      case RoomState.left:
        final expectedLeave = cycle.leaveRequestStarted;
        _observeRoomExit(cycle, roomId: roomId);
        if (cycle.joinConfirmed &&
            !expectedLeave &&
            reason != RoomStateChangeReason.leave_room) {
          _reportTerminal(cycle, reason.name);
        }
    }
  }

  void _observeLegacyRoomState(
    _VolcRtcRoomCycle cycle,
    String roomId,
    int state,
  ) {
    if (!_isCurrentCycle(cycle, roomId)) return;
    if (state == RoomState.success.$value) {
      if (!cycle.joinState.isCompleted) {
        cycle.joinConfirmed = true;
        cycle.joinState.complete();
      }
      return;
    }
    final expectedLeave = cycle.leaveRequestStarted;
    if (!cycle.joinState.isCompleted) {
      cycle.joinFailure = StateError('Volc RTC room join failed: $state');
      cycle.joinState.complete();
      return;
    }
    if (state == RoomState.left.$value) {
      _observeRoomExit(cycle, roomId: roomId);
    }
    if (cycle.joinConfirmed && !expectedLeave) {
      _reportTerminal(cycle, 'room_state_$state');
    }
  }

  void _observeRoomExit(_VolcRtcRoomCycle cycle, {String? roomId}) {
    if (!_isCurrentCycle(cycle, roomId)) return;
    cycle.exitObserved = true;
    if (!cycle.exitState.isCompleted) cycle.exitState.complete();
    if (!cycle.joinState.isCompleted) {
      cycle.joinFailure ??= StateError(
        'Volc RTC room exited before join completed.',
      );
      cycle.joinState.complete();
    }
  }

  bool _isCurrentCycle(_VolcRtcRoomCycle cycle, [String? roomId]) =>
      identical(_roomCycle, cycle) &&
      identical(_room, cycle.room) &&
      (roomId == null || roomId == cycle.roomId);

  void _reportTerminal(_VolcRtcRoomCycle cycle, String reason) {
    if (!_isCurrentCycle(cycle) || cycle.terminalReported) return;
    cycle.terminalReported = true;
    _terminalRetirementScheduled = true;
    scheduleMicrotask(() {
      final retirement = leave();
      if (!_terminalEventsClosed) {
        _terminalEvents.add(
          VolcRtcTerminalEvent(roomId: cycle.roomId, reason: reason),
        );
      }
      unawaited(
        retirement.then<void>(
          (_) => _terminalRetirementScheduled = false,
          onError: (Object _, StackTrace _) {
            _terminalRetirementScheduled = false;
          },
        ),
      );
    });
  }

  static bool _isTerminalReason(RoomStateChangeReason reason) =>
      switch (reason) {
        RoomStateChangeReason.join_room ||
        RoomStateChangeReason.reconnect ||
        RoomStateChangeReason.leave_room ||
        RoomStateChangeReason.join_room_failed => false,
        _ => true,
      };

  Future<void> _configureRealtimeVoiceAudio(RTCEngine engine) async {
    // Must run before mic capture so speaker playback is handled as AI-call audio,
    // not media playback that can leak back into cloud ASR.
    final result = await engine.setAudioScenario(AudioScenarioType.aiclient);
    _requireSuccess(result, 'configure Volc RTC AI audio scenario');
  }

  Future<void> _syncAgentAudio(_VolcRtcRoomCycle cycle) {
    final operation = cycle.audioSyncTail.then((_) async {
      if (!identical(_roomCycle, cycle) ||
          !cycle.joinConfirmed ||
          _retiring ||
          cycle.exitObserved ||
          cycle.leaveRequestStarted) {
        return;
      }
      for (final streamId in cycle.audioPublishers.keys.toList()) {
        if (_retiring || cycle.exitObserved || cycle.leaveRequestStarted) {
          return;
        }
        final publisher = cycle.audioPublishers[streamId];
        if (publisher == null) continue;
        final subscribe =
            publisher != cycle.agentUserId || MaasoTtsPlugin.soundEnabled.value;
        if (cycle.audioSubscriptions[streamId] == subscribe) continue;
        final result = await cycle.room.subscribeStreamAudio(
          streamId: streamId,
          subscribe: subscribe,
        );
        _requireSuccess(result, 'update Volc RTC Agent audio subscription');
        cycle.audioSubscriptions[streamId] = subscribe;
      }
    });
    cycle.audioSyncTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  @override
  Future<void> leave() {
    _generation++;
    final pending = _retirementFuture;
    if (pending != null) return pending;

    final joining = _joinOperation;
    late final Future<void> retirement;
    retirement = _retireAroundJoin(joining).whenComplete(() {
      if (identical(_retirementFuture, retirement)) {
        _retirementFuture = null;
      }
    });
    _retirementFuture = retirement;
    return retirement;
  }

  Future<void> _retireAroundJoin(Future<void>? joining) async {
    if (joining != null) {
      try {
        await _interruptResources();
      } catch (_) {
        // The final pass below retries every still-live captured resource.
      }
      try {
        await joining;
      } catch (_) {
        // A stale/failed join is expected after leave closes its generation.
      }
    }
    await _cleanupResources();
  }

  Future<void> _interruptResources() {
    final pending = _interruptFuture;
    if (pending != null) return pending;

    late final Future<void> interrupt;
    interrupt = _interruptOnce().whenComplete(() {
      if (identical(_interruptFuture, interrupt)) _interruptFuture = null;
    });
    _interruptFuture = interrupt;
    return interrupt;
  }

  Future<void> _interruptOnce() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() step) async {
      try {
        await step();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    final engine = _engine;
    if (engine != null && _audioCaptureMayBeActive) {
      await attempt(() async {
        final result = await engine.stopAudioCapture();
        _requireSuccess(result, 'interrupt Volc RTC audio capture');
      });
    }
    if (engine != null && _videoCaptureMayBeActive) {
      await attempt(() async {
        final result = await engine.stopVideoCapture();
        _requireSuccess(result, 'interrupt Volc RTC video capture');
      });
    }
    final cycle = _roomCycle;
    if (cycle != null && cycle.leaveRequired) {
      await attempt(() async {
        await _requestRoomLeave(cycle, 'interrupt Volc RTC room');
      });
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> _cleanupResources() {
    final pending = _resourceCleanupFuture;
    if (pending != null) return pending;

    late final Future<void> cleanup;
    final interrupt = _interruptFuture;
    cleanup =
        () async {
          if (interrupt != null) {
            try {
              await interrupt;
            } catch (_) {
              // The serialized final pass retries every interrupted stage.
            }
          }
          await _retireOnce();
        }().whenComplete(() {
          if (identical(_resourceCleanupFuture, cleanup)) {
            _resourceCleanupFuture = null;
          }
        });
    _resourceCleanupFuture = cleanup;
    return cleanup;
  }

  Future<void> _retireOnce() async {
    final audioCycle = _roomCycle;
    audioCycle?.unregisterSoundStopper?.call();
    audioCycle?.soundWorker?.dispose();
    if (audioCycle != null) await audioCycle.audioSyncTail;
    Object? captureError;
    StackTrace? captureStackTrace;
    Object? roomError;
    StackTrace? roomStackTrace;
    Object? engineError;
    StackTrace? engineStackTrace;
    Future<void> attemptCapture(Future<void> Function() step) async {
      try {
        await step();
      } catch (error, stackTrace) {
        captureError ??= error;
        captureStackTrace ??= stackTrace;
      }
    }

    final engine = _engine;
    if (engine != null && _audioCaptureMayBeActive) {
      await attemptCapture(() async {
        final result = await engine.stopAudioCapture();
        _requireSuccess(result, 'stop Volc RTC audio capture');
        _audioCaptureMayBeActive = false;
      });
    }
    if (engine != null && _videoCaptureMayBeActive) {
      await attemptCapture(() async {
        final result = await engine.stopVideoCapture();
        _requireSuccess(result, 'stop Volc RTC video capture');
        _videoCaptureMayBeActive = false;
      });
    }

    final cycle = _roomCycle;
    final room = cycle?.room;
    if (cycle != null && cycle.leaveRequired) {
      try {
        await _requestRoomLeave(cycle, 'leave Volc RTC room');
        await _awaitRoomExit(cycle);
        cycle.leaveRequired = false;
      } catch (error, stackTrace) {
        roomError = error;
        roomStackTrace = stackTrace;
      }
    }
    if (room != null && !cycle!.leaveRequired) {
      try {
        await room.destroy();
        if (_isCurrentCycle(cycle)) {
          _room = null;
          _roomCycle = null;
        }
      } catch (error, stackTrace) {
        roomError ??= error;
        roomStackTrace ??= stackTrace;
      }
    }

    if (engine != null && _room == null) {
      try {
        await _destroyEngine(engine);
        if (identical(_engine, engine)) {
          _engine = null;
          _audioCaptureMayBeActive = false;
          _videoCaptureMayBeActive = false;
        }
        captureError = null;
        captureStackTrace = null;
      } catch (error, stackTrace) {
        engineError = error;
        engineStackTrace = stackTrace;
      }
    }

    final error = roomError ?? engineError ?? captureError;
    final stackTrace = roomStackTrace ?? engineStackTrace ?? captureStackTrace;
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  Future<void> _requestRoomLeave(
    _VolcRtcRoomCycle cycle,
    String operation,
  ) async {
    if (!_isCurrentCycle(cycle) ||
        cycle.exitObserved ||
        cycle.leaveRequestAdmitted) {
      return;
    }
    cycle.leaveRequestStarted = true;
    try {
      final result = await cycle.room.leaveRoom();
      _requireSuccess(result, operation);
      cycle.leaveRequestAdmitted = true;
    } catch (_) {
      if (!cycle.exitObserved) cycle.leaveRequestStarted = false;
      rethrow;
    }
  }

  Future<void> _awaitRoomJoin(_VolcRtcRoomCycle cycle) async {
    if (!_isCurrentCycle(cycle)) {
      throw StateError('Volc RTC room join cycle is stale.');
    }
    if (!cycle.joinInvocationAccepted) {
      throw StateError('Volc RTC room join was not admitted.');
    }
    try {
      await cycle.joinState.future.timeout(roomStateTimeout);
    } on TimeoutException {
      throw TimeoutException(
        'Timed out waiting for Volc RTC room join confirmation.',
        roomStateTimeout,
      );
    }
    final failure = cycle.joinFailure;
    if (failure != null) throw failure;
    if (!cycle.joinConfirmed) {
      throw StateError('Volc RTC room join was not confirmed.');
    }
  }

  Future<void> _awaitRoomExit(_VolcRtcRoomCycle cycle) async {
    if (!_isCurrentCycle(cycle)) {
      throw StateError('Volc RTC room exit cycle is stale.');
    }
    if (cycle.exitObserved) return;
    try {
      await cycle.exitState.future.timeout(roomStateTimeout);
    } on TimeoutException {
      throw TimeoutException(
        'Timed out waiting for Volc RTC room exit confirmation.',
        roomStateTimeout,
      );
    }
  }

  void _requireCurrentJoin(int generation) {
    if (generation != _generation) {
      throw StateError('The Volc RTC join was retired before completion.');
    }
  }

  @override
  Future<void> dispose() async {
    _retiring = true;
    await leave();
    if (!_terminalEventsClosed) {
      _terminalEventsClosed = true;
      await _terminalEvents.close();
    }
  }

  static void _requireSuccess(int? result, String operation) {
    if (result != null && result != 0) {
      throw StateError('$operation failed: $result');
    }
  }
}

final class _VolcRtcRoomCycle {
  _VolcRtcRoomCycle({
    required this.room,
    required this.roomId,
    this.agentUserId,
  });

  final RTCRoom room;
  final String roomId;
  final String? agentUserId;
  bool get controlsAgentAudio => agentUserId?.isNotEmpty == true;
  final Map<String, String?> audioPublishers = {};
  final Map<String, bool> audioSubscriptions = {};
  Future<void> audioSyncTail = Future<void>.value();
  void Function()? unregisterSoundStopper;
  Worker? soundWorker;
  final Completer<void> joinState = Completer<void>();
  final Completer<void> exitState = Completer<void>();
  Object? joinFailure;
  bool joinInvocationAccepted = false;
  bool joinConfirmed = false;
  bool leaveRequired = false;
  bool leaveRequestStarted = false;
  bool leaveRequestAdmitted = false;
  bool exitObserved = false;
  bool terminalReported = false;
}

Future<void> _destroyRtcEngine(RTCEngine _) async {
  await rtc_pack.RTCEngine.destroyRTCEngine();
}

Future<int?> _joinRtcRoom(
  RTCRoom room,
  VolcRtcJoinConfig config, {
  required bool publishAudio,
  required bool publishVideo,
  required bool autoSubscribeAudio,
  required bool autoSubscribeVideo,
}) => room.joinRoom(
  token: config.token,
  userInfo: UserInfo(userId: config.userId, extraInfo: ''),
  userVisibility: true,
  roomConfig: RoomConfig(
    isPublishAudio: publishAudio,
    isPublishVideo: publishVideo,
    isAutoSubscribeAudio: autoSubscribeAudio,
    isAutoSubscribeVideo: autoSubscribeVideo,
  ),
);
