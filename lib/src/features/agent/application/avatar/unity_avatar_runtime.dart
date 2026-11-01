import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/data/models/lip_sync_viseme.dart';
import 'package:maaso/src/features/agent/data/models/speech_playback_clock.dart';

import 'avatar_agent_space.dart';
import 'unity_avatar_transport.dart';
import 'unity_avatar_presence_transitions.dart';
import 'unity_avatar_doorway_transitions.dart';
import 'unity_avatar_phone_interactions.dart';
import 'unity_avatar_command_dispatch_sink.dart';
import 'unity_avatar_transport_factory.dart';

class UnityAvatarRuntime extends AppService
    implements
        AvatarRuntime,
        AvatarAgentSpaceRuntime,
        AvatarFurnitureRuntime,
        AvatarVisemeRuntime,
        AvatarSpeechPlaybackRuntime,
        AvatarConversationPhaseRuntime,
        AvatarScreenAttentionRuntime,
        AvatarCapabilityRuntime {
  UnityAvatarRuntime({
    MethodChannel? channel,
    UnityAvatarTransport? transport,
    Duration avatarLoadTimeout = const Duration(minutes: 2),
    Duration agentSpaceTimeout = const Duration(seconds: 15),
  }) : _channel = _resolveUnityAvatarTransport(channel, transport),
       _avatarLoadTimeout = avatarLoadTimeout,
       _agentSpaceTimeout = agentSpaceTimeout {
    _commandDispatchSink = UnityAvatarCommandDispatchSink(
      transport: _channel,
      rendererReady: () => isReady.value,
    );
    _channel.setMethodCallHandler(_handleNativeCall);
  }

  static const channelName = 'maaso/unity_avatar';
  static const viewType = 'maaso/unity_avatar_view';
  static const _notReadyActionMethods = <String>{
    'playPrimitive',
    'playAnimationClip',
    'setHandIkTarget',
    'playMotion',
    'playMotionSequence',
  };

  final UnityAvatarTransport _channel;
  bool _localAvatarVisible = false;
  final bool _requiresPresentationReceipt =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  final RxBool _nativePresentationReady = false.obs;
  bool _nativeViewAttached = false;
  String? _nativePresentationId;
  static int _nextNativePresentationId = 0;

  @override
  RxBool get presentationReady =>
      _requiresPresentationReceipt ? _nativePresentationReady : isReady;

  void _invalidateNativePresentation() {
    _nativePresentationId = null;
    _nativeViewAttached = false;
    _nativePresentationReady.value = false;
  }

  @override
  Future<void> setLocalAvatarVisible(bool visible) async {
    _localAvatarVisible = visible;
    await _invoke('setLocalAvatarVisible', {'visible': visible});
  }

  late final _phoneInteractions = UnityAvatarPhoneInteractions(
    _channel,
    () => isReady.value,
  );
  late final _presenceTransitions = UnityAvatarPresenceTransitions(
    _channel,
    () => isReady.value,
  );
  late final _doorwayTransitions = UnityAvatarDoorwayTransitions(
    _channel,
    () => isReady.value,
  );
  @override
  bool get supportsLoginDoorway => true;
  @override
  Future<void> transitionLoginDoorway(AvatarDoorwayTransition request) =>
      _doorwayTransitions.run(request);
  final Duration _avatarLoadTimeout;
  final Duration _agentSpaceTimeout;
  late final UnityAvatarCommandDispatchSink _commandDispatchSink;
  final _furnitureStates = StreamController<AvatarFurnitureState>.broadcast();
  AvatarFurnitureState? _furnitureState;
  String? _furnitureOwner;
  Map<String, dynamic>? _furnitureObservation;
  @override
  AvatarFurnitureState? get furnitureState {
    _syncHostTaskWorkAuthority();
    final observation = _furnitureObservation;
    if (observation?['method'] == 'backgroundTaskWorkState') {
      return !isClosed &&
              !_commandDispatchSink.isClosed &&
              !AvatarProductionOwnership.blocksLegacyAvatarMutation &&
              observation?['loadRequestId'] == _loadedAvatarRequestId &&
              observation?['sessionId'] == _hostTaskWorkObservationSession
          ? _furnitureState
          : null;
    }
    return _furnitureObservation != null &&
            AvatarProductionOwnership.currentFor(
                  'self',
                )?.acceptsRendererObservation(_furnitureObservation!) ==
                true
        ? _furnitureState
        : null;
  }

  @override
  Stream<AvatarFurnitureState> get furnitureStates => _furnitureStates.stream;
  final _capabilityProfiles =
      StreamController<AvatarCapabilityProfile>.broadcast();
  final Map<String, Completer<void>> _pendingAvatarLoads = {};
  final Set<String> _pendingAvatarLoadsRequiringUnityProfile = {};
  final Map<String, String> _pendingAvatarLoadSignatures = {};
  ({String modelUrl, Map<String, dynamic> config})?
  _pendingAccountBoundaryAvatarReset;
  final Map<
    String,
    ({
      String method,
      String sessionId,
      int epoch,
      Completer<void> receipt,
      int viewportGeneration,
      int viewportSequence,
      AvatarViewportSafeArea? viewportTarget,
    })
  >
  _pendingAgentSpace = {};
  String? _agentSpaceViewportSession;
  AvatarViewportSafeArea? _agentSpaceHomeViewport;
  int _agentSpaceViewportGeneration = 0;
  int _agentSpaceViewportSequence = 0;
  int _agentSpaceLatestViewportReceipt = 0;
  int _nextCommandRequest = 0;
  int _rendererReadinessGeneration = 0;
  int _modelLoadEpoch = 0;
  @override
  int get modelLoadEpoch => _modelLoadEpoch;

  @override
  bool get supportsBackgroundTaskWorkPresentation =>
      isReady.value &&
      (_backgroundTaskWorkVersion == 1 || _backgroundTaskWorkVersion == 2);

  @override
  bool get supportsHostBackgroundTaskWorkPresentation {
    _syncHostTaskWorkAuthority();
    return !isClosed &&
        !_commandDispatchSink.isClosed &&
        isReady.value &&
        _backgroundTaskWorkVersion == 2 &&
        _loadedAvatarRequestId != null;
  }

  int _backgroundTaskWorkVersion = 0;
  int _backgroundTaskWorkPresentationEpoch = 0;
  @override
  int get backgroundTaskWorkPresentationEpoch =>
      _backgroundTaskWorkPresentationEpoch;
  String? _loadedAvatarSignature;
  String? _loadedAvatarRequestId;
  String? _hostTaskWorkSessionId;
  String? _hostTaskWorkObservationSession;
  int _hostTaskWorkObservationSequence = 0;
  int _nextHostTaskWorkSequence = 0;
  bool _hostTaskWorkAuthorityBound = false;
  AvatarProjectionProductionAuthority? _hostTaskWorkAuthority;
  int? _hostTaskWorkAuthorityGeneration;
  final _pendingHostTaskWorks =
      <
        String,
        ({
          String sessionId,
          String loadRequestId,
          int epoch,
          int sequence,
          AvatarBackgroundTaskWorkPhase phase,
          Completer<AvatarBackgroundTaskWorkResult> receipt,
        })
      >{};
  static const _hostTaskWorkFailureCodes = {
    'invalid_command',
    'deadline_expired',
    'model_stale',
    'stale_sequence',
    'session_ended',
    'session_mismatch',
    'authority_owned',
    'not_ready',
    'presentation_busy',
    'user_pose_owned',
    'work_unavailable',
    'mutation_failed',
  };
  AvatarCapabilityProfile _activeCapabilityProfile =
      AvatarCapabilityProfile.unknown;
  AvatarExpressionParams? _latestExpression;
  AvatarViewportSafeArea? _latestViewportSafeArea;
  AvatarWorldLighting? _latestWorldLighting;

  @override
  final isReady = false.obs;

  @override
  AvatarBackendKind get backendKind => AvatarBackendKind.unity;

  @override
  AvatarCapabilityProfile get activeCapabilityProfile =>
      _activeCapabilityProfile;

  /// One stable sink for the entire lifetime of this concrete Unity runtime.
  /// Account-scoped arbiters must reuse it so renderer ownership fences survive
  /// account switches and arbiter replacement.
  AvatarCommandDispatchSink get commandDispatchSink => _commandDispatchSink;

  @override
  Stream<AvatarCapabilityProfile> get capabilityProfileChanges =>
      _capabilityProfiles.stream;

  Future<dynamic> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'presentationState':
        if (!_requiresPresentationReceipt || _commandDispatchSink.isClosed) {
          return false;
        }
        final state = call.arguments;
        if (state is! Map ||
            _nativePresentationId == null ||
            state['presentationId'] != _nativePresentationId ||
            state['attached'] is! bool) {
          return false;
        }
        _nativeViewAttached = state['attached'] == true;
        _nativePresentationReady.value = isReady.value && _nativeViewAttached;
        return true;
      case 'ready':
        if (_commandDispatchSink.isClosed) return false;
        final readinessGeneration = ++_rendererReadinessGeneration;
        bool stillReady() =>
            readinessGeneration == _rendererReadinessGeneration &&
            !_commandDispatchSink.isClosed &&
            isReady.value;
        // Publishing ready immediately starts the production authority's new
        // epoch. Its sink must already accept the exact reset/bind receipts;
        // native visibility replay may still be awaiting the platform thread.
        _commandDispatchSink.markRendererReady();
        isReady.value = true;
        _nativePresentationReady.value = _nativeViewAttached;
        await setLocalAvatarVisible(_localAvatarVisible);
        if (!stillReady()) return false;
        await setExpressionParams(
          _latestExpression ?? const AvatarExpressionParams(),
        );
        if (!stillReady()) return false;
        final latestSafeArea = _latestViewportSafeArea;
        if (latestSafeArea != null) {
          await setViewportSafeArea(latestSafeArea);
          if (!stillReady()) return false;
        }
        final latestWorldLighting = _latestWorldLighting;
        if (latestWorldLighting != null) {
          await setWorldLighting(latestWorldLighting);
          if (!stillReady()) return false;
        }
        final pendingReset = _pendingAccountBoundaryAvatarReset;
        if (pendingReset != null) {
          _pendingAccountBoundaryAvatarReset = null;
          unawaited(
            loadAvatar(pendingReset.modelUrl, pendingReset.config).catchError((
              Object error,
              StackTrace stackTrace,
            ) {
              _debugLog(
                '[AvatarLoad] deferred account-boundary reset failed '
                'errorType=${error.runtimeType}',
              );
            }),
          );
        }
        return true;
      case 'unready':
        // Retire every suspended ready replay before notifying observers.
        // A late platform return must not consume a later avatar reset or
        // restore presentation state belonging to the retired renderer.
        _rendererReadinessGeneration++;
        _invalidateHostTaskWork();
        _invalidateNativePresentation();
        isReady.value = false;
        _invalidateAgentSpace('renderer_unready');
        _phoneInteractions.invalidate('renderer_unready');
        _presenceTransitions.invalidate('renderer_unready');
        _doorwayTransitions.invalidate('renderer_unready');
        _furnitureState = null;
        _furnitureOwner = null;
        _commandDispatchSink.markRendererUnavailable();
        final reason = call.arguments is Map
            ? (call.arguments as Map)['reason']?.toString().trim() ?? ''
            : '';
        if (reason != 'detached' && reason != 'bfcache') {
          _backgroundTaskWorkVersion = 0;
          _backgroundTaskWorkPresentationEpoch++;
          _loadedAvatarSignature = null;
          _loadedAvatarRequestId = null;
          _modelLoadEpoch++;
          // A fresh Unity scene begins with its bundled Agent. Do not replay
          // the previous model's visibility before the selected model is
          // loaded and Home has prepared its hidden entrance frame.
          _localAvatarVisible = false;
          _publishCapabilityProfile(AvatarCapabilityProfile.unknown);
          _invalidatePendingRendererCommands(
            reason.isEmpty ? 'renderer_unready' : reason,
          );
        }
        return true;
      case 'log':
        debugPrint('[UnityAvatar] ${call.arguments}');
        return true;
      case 'error':
        debugPrint('[UnityAvatar] error ${call.arguments}');
        return true;
      case 'commandResult':
        final result = _decodeNativeMap(call.arguments);
        if (result == null) return false;
        final liveMethod = result['method']?.toString() ?? '';
        if (liveMethod == 'setBackgroundTaskWork') {
          return _handleHostTaskWorkResult(result);
        }
        if (liveMethod == 'backgroundTaskWorkState') {
          return _handleHostTaskWorkState(result);
        }
        if (liveMethod == 'furnitureState') {
          final authority = AvatarProductionOwnership.currentFor('self');
          if (authority?.acceptsRendererObservation(result) != true) {
            return false;
          }
          final state = AvatarFurnitureState.parse(result);
          if (state == null) return false;
          final owner = result['ownerToken'] as String;
          if (_furnitureOwner == owner &&
              state.sequence <= (_furnitureState?.sequence ?? 0)) {
            return false;
          }
          _furnitureObservation = result;
          _furnitureOwner = owner;
          _furnitureState = state;
          _furnitureStates.add(state);
          return true;
        }
        if (liveMethod == 'enterAgentSpace' ||
            liveMethod == 'leaveAgentSpace' ||
            liveMethod == 'requestAgentSpaceMoveAtScreenPoint') {
          return _handleAgentSpaceResult(result);
        }
        if (liveMethod == 'setPhoneInteraction') {
          return _phoneInteractions.handleResult(result);
        }
        if (liveMethod == 'transitionPresence') {
          return _presenceTransitions.handleResult(result);
        }
        if (liveMethod == 'transitionLoginDoorway') {
          return _doorwayTransitions.handleResult(result);
        }
        if (liveMethod == UnityAvatarCommandDispatchSink.commandMethod ||
            liveMethod == UnityAvatarCommandDispatchSink.resetMethod) {
          return _commandDispatchSink.handleCommandResult(result);
        }
        if (result['method'] == 'loadAvatar') {
          final requestId = result['requestId']?.toString() ?? '';
          final completer = _pendingAvatarLoads.remove(requestId);
          final requiresUnityProfile = _pendingAvatarLoadsRequiringUnityProfile
              .remove(requestId);
          final sha256 = result['assetSha256']?.toString().trim() ?? '';
          _debugLog(
            '[AvatarLoad] result request=$requestId ok=${result['ok']} '
            'code=${result['code'] ?? '-'} '
            'cacheHit=${result['cacheHit'] ?? '-'} '
            'sha=${sha256.isEmpty ? '-' : (sha256.length <= 12 ? sha256 : sha256.substring(0, 12))}',
          );
          if (completer == null || completer.isCompleted) {
            _debugLog(
              '[AvatarLoad] ignored unmatched result request=$requestId '
              'pending=${_pendingAvatarLoads.keys.join(',')}',
            );
            return false;
          }
          if (result['ok'] == true) {
            try {
              final rawProfile = result['capabilityProfile'];
              if (rawProfile != null || requiresUnityProfile) {
                final profile = AvatarCapabilityProfile.fromJson(rawProfile);
                if (requiresUnityProfile &&
                    (profile.source != AvatarCapabilitySource.unity ||
                        profile.state == AvatarCapabilityState.unknown)) {
                  throw StateError(
                    'Remote Avatar load requires an authoritative Unity capability profile',
                  );
                }
                if (profile.hasBlockers) {
                  throw StateError(
                    'Unity activated an incompatible Avatar profile',
                  );
                }
                _publishCapabilityProfile(profile);
              }
              // Only a matched successful native load can advertise this
              // protocol. A descriptor, generic ready or old export cannot.
              _backgroundTaskWorkVersion =
                  result['backgroundTaskWorkVersion'] is int &&
                      const {1, 2}.contains(result['backgroundTaskWorkVersion'])
                  ? result['backgroundTaskWorkVersion'] as int
                  : 0;
              _loadedAvatarRequestId = requestId;
              completer.complete();
            } on StateError catch (error, stackTrace) {
              completer.completeError(error, stackTrace);
            }
          } else {
            final message =
                result['message']?.toString().trim() ??
                'Unity avatar load failed';
            final code = result['code']?.toString().trim() ?? '';
            completer.completeError(
              StateError(code.isEmpty ? message : '$message ($code)'),
            );
          }
          return true;
        }
        return false;
      default:
        return null;
    }
  }

  static Map<String, dynamic>? _decodeNativeMap(Object? arguments) {
    if (arguments is Map) {
      return Map<String, dynamic>.from(arguments);
    }
    if (arguments is! String || arguments.length > 32 * 1024) return null;
    try {
      final decoded = jsonDecode(arguments);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } on FormatException {
      return null;
    }
  }

  @override
  Future<AvatarBackgroundTaskWorkResult> setBackgroundTaskWork({
    required String sessionId,
    required AvatarBackgroundTaskWorkPhase phase,
  }) async {
    _syncHostTaskWorkAuthority();
    AvatarBackgroundTaskWorkResult rejected(String code) =>
        AvatarBackgroundTaskWorkResult(
          AvatarBackgroundTaskWorkDisposition.rejected,
          code: code,
        );
    if (isClosed || _commandDispatchSink.isClosed) {
      return rejected('work_unavailable');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(sessionId)) {
      return rejected('invalid_command');
    }
    if (AvatarProductionOwnership.blocksLegacyAvatarMutation) {
      return rejected('authority_owned');
    }
    final loadRequestId = _loadedAvatarRequestId;
    if (!supportsHostBackgroundTaskWorkPresentation || loadRequestId == null) {
      return rejected('work_unavailable');
    }
    if (phase == AvatarBackgroundTaskWorkPhase.start) {
      if (!presentationReady.value) {
        return const AvatarBackgroundTaskWorkResult(
          AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
          code: 'not_ready',
        );
      }
      if (_hostTaskWorkSessionId != null &&
          _hostTaskWorkSessionId != sessionId) {
        return rejected('user_pose_owned');
      }
      if (_hostTaskWorkObservationSession != sessionId) {
        _hostTaskWorkObservationSequence = 0;
      }
      _hostTaskWorkSessionId = sessionId;
      _hostTaskWorkObservationSession = sessionId;
      final authority = AvatarProductionOwnership.currentFor('self');
      _hostTaskWorkAuthorityBound = true;
      _hostTaskWorkAuthority = authority;
      _hostTaskWorkAuthorityGeneration = authority?.rendererGeneration;
    }
    final sequence = ++_nextHostTaskWorkSequence;
    final requestId = 'task-work-$sequence';
    final epoch = backgroundTaskWorkPresentationEpoch;
    final receipt = Completer<AvatarBackgroundTaskWorkResult>();
    _pendingHostTaskWorks[requestId] = (
      sessionId: sessionId,
      loadRequestId: loadRequestId,
      epoch: epoch,
      sequence: sequence,
      phase: phase,
      receipt: receipt,
    );
    final issuedAt = DateTime.now().millisecondsSinceEpoch;
    try {
      await _channel.invokeMethod<void>('setBackgroundTaskWork', {
        'requestId': requestId,
        'sessionId': sessionId,
        'phase': phase.name,
        'loadRequestId': loadRequestId,
        'sequence': sequence,
        'issuedAtEpochMs': issuedAt,
        'deadlineEpochMs': issuedAt + 10000,
      });
      final result = await receipt.future.timeout(
        const Duration(seconds: 5),
        onTimeout: () => rejected('mutation_failed'),
      );
      if (loadRequestId != _loadedAvatarRequestId ||
          epoch != backgroundTaskWorkPresentationEpoch) {
        return rejected('model_stale');
      }
      if (phase == AvatarBackgroundTaskWorkPhase.end && result.applied) {
        if (_hostTaskWorkSessionId == sessionId) {
          _hostTaskWorkSessionId = null;
        }
      } else if (phase == AvatarBackgroundTaskWorkPhase.start &&
          !result.applied &&
          result.code != 'mutation_failed' &&
          _hostTaskWorkSessionId == sessionId) {
        _hostTaskWorkSessionId = null;
      }
      return result;
    } on MissingPluginException {
      if (_hostTaskWorkSessionId == sessionId) {
        _hostTaskWorkSessionId = null;
      }
      return rejected('work_unavailable');
    } on PlatformException catch (error) {
      if (error.code == 'not_ready' && _hostTaskWorkSessionId == sessionId) {
        _hostTaskWorkSessionId = null;
      }
      return error.code == 'not_ready'
          ? const AvatarBackgroundTaskWorkResult(
              AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
              code: 'not_ready',
            )
          : rejected('mutation_failed');
    } finally {
      _pendingHostTaskWorks.remove(requestId);
      if (phase == AvatarBackgroundTaskWorkPhase.end &&
          _hostTaskWorkSessionId == sessionId) {
        _hostTaskWorkSessionId = null;
      }
    }
  }

  bool _handleHostTaskWorkResult(Map<String, dynamic> result) {
    _syncHostTaskWorkAuthority();
    if (!setEquals(result.keys.toSet(), const {
      'method',
      'requestId',
      'sessionId',
      'phase',
      'loadRequestId',
      'sequence',
      'ok',
      'code',
    })) {
      return false;
    }
    final pending = _pendingHostTaskWorks[result['requestId']];
    final code = result['code'];
    if (pending == null ||
        pending.receipt.isCompleted ||
        result['sessionId'] != pending.sessionId ||
        result['phase'] != pending.phase.name ||
        result['loadRequestId'] != pending.loadRequestId ||
        result['sequence'] is! int ||
        result['sequence'] != pending.sequence ||
        result['ok'] is! bool ||
        code is! String ||
        (result['ok'] == true
            ? code.isNotEmpty
            : !_hostTaskWorkFailureCodes.contains(code))) {
      return false;
    }
    final stale =
        pending.loadRequestId != _loadedAvatarRequestId ||
        pending.epoch != backgroundTaskWorkPresentationEpoch ||
        AvatarProductionOwnership.blocksLegacyAvatarMutation;
    final disposition = stale
        ? AvatarBackgroundTaskWorkDisposition.rejected
        : result['ok'] == true
        ? AvatarBackgroundTaskWorkDisposition.applied
        : const {'not_ready', 'presentation_busy'}.contains(code)
        ? AvatarBackgroundTaskWorkDisposition.waitingForPresentation
        : AvatarBackgroundTaskWorkDisposition.rejected;
    pending.receipt.complete(
      AvatarBackgroundTaskWorkResult(
        disposition,
        code: stale ? 'model_stale' : code,
      ),
    );
    return true;
  }

  bool _handleHostTaskWorkState(Map<String, dynamic> result) {
    _syncHostTaskWorkAuthority();
    if (!setEquals(result.keys.toSet(), const {
          'method',
          'requestId',
          'sessionId',
          'loadRequestId',
          'phase',
          'furnitureId',
          'sceneId',
          'sequence',
          'workSessionId',
        }) ||
        AvatarProductionOwnership.blocksLegacyAvatarMutation ||
        !supportsHostBackgroundTaskWorkPresentation ||
        _hostTaskWorkObservationSession == null ||
        result['loadRequestId'] != _loadedAvatarRequestId ||
        result['sessionId'] != _hostTaskWorkObservationSession ||
        result['requestId'] is! String ||
        (result['requestId'] as String).isEmpty ||
        (result['requestId'] as String).length > 128) {
      return false;
    }
    final state = AvatarFurnitureState.parse(result);
    if (state == null ||
        state.sequence <= _hostTaskWorkObservationSequence ||
        (state.workSessionId != null &&
            (state.workSessionId != _hostTaskWorkObservationSession ||
                state.workSessionId != _hostTaskWorkSessionId))) {
      return false;
    }
    final endedByHost =
        state.workSessionId == null &&
        _hostTaskWorkSessionId == result['sessionId'] &&
        !_pendingHostTaskWorks.values.any(
          (pending) =>
              pending.sessionId == result['sessionId'] &&
              pending.phase == AvatarBackgroundTaskWorkPhase.end,
        );
    if (endedByHost) {
      // This is the native work-owner channel, unlike incidental generic pose
      // observations. An unsolicited owner release fences this session, so a
      // later foreground readiness change cannot replay over a user's pose.
      final authority = _hostTaskWorkAuthority;
      final authorityGeneration = _hostTaskWorkAuthorityGeneration;
      final authorityBound = _hostTaskWorkAuthorityBound;
      _backgroundTaskWorkPresentationEpoch++;
      _invalidateHostTaskWork();
      // Keep the final read-only pose observable, but never accept another
      // active-owner observation until a fresh admitted start binds it.
      _hostTaskWorkObservationSession = result['sessionId'] as String;
      _hostTaskWorkAuthority = authority;
      _hostTaskWorkAuthorityGeneration = authorityGeneration;
      _hostTaskWorkAuthorityBound = authorityBound;
    }
    _hostTaskWorkObservationSequence = state.sequence;
    _furnitureObservation = result;
    _furnitureOwner = null;
    _furnitureState = state;
    _furnitureStates.add(state);
    return true;
  }

  void _syncHostTaskWorkAuthority() {
    if (!_hostTaskWorkAuthorityBound) return;
    final current = AvatarProductionOwnership.currentFor('self');
    if (!identical(current, _hostTaskWorkAuthority) ||
        current?.rendererGeneration != _hostTaskWorkAuthorityGeneration ||
        AvatarProductionOwnership.blocksLegacyAvatarMutation) {
      _invalidateHostTaskWork();
    }
  }

  void _invalidateHostTaskWork() {
    for (final pending in _pendingHostTaskWorks.values) {
      if (!pending.receipt.isCompleted) {
        pending.receipt.complete(
          const AvatarBackgroundTaskWorkResult(
            AvatarBackgroundTaskWorkDisposition.rejected,
            code: 'model_stale',
          ),
        );
      }
    }
    _pendingHostTaskWorks.clear();
    _hostTaskWorkSessionId = null;
    _hostTaskWorkObservationSession = null;
    _hostTaskWorkObservationSequence = 0;
    _hostTaskWorkAuthorityBound = false;
    _hostTaskWorkAuthority = null;
    _hostTaskWorkAuthorityGeneration = null;
    if (_furnitureObservation?['method'] == 'backgroundTaskWorkState') {
      _furnitureObservation = null;
      _furnitureState = null;
    }
  }

  void _publishCapabilityProfile(AvatarCapabilityProfile profile) {
    _activeCapabilityProfile = profile;
    if (!_capabilityProfiles.isClosed) {
      _capabilityProfiles.add(profile);
    }
  }

  @override
  Future<void> setExpressionParams(AvatarExpressionParams params) async {
    if (AvatarProductionOwnership.blocksLegacyAvatarMutation) {
      _debugLog('setExpression skipped: ticketed avatar owner is active');
      return;
    }
    _latestExpression = params;
    await _invoke('setExpression', params.toJson());
  }

  @override
  Future<void> setMouthOpen(double value) {
    return _invoke('setMouthOpen', {'value': value.clamp(0.0, 1.0).toDouble()});
  }

  @override
  Future<void> setGaze(AvatarGaze gaze) {
    return _invoke('setGaze', gaze.toJson());
  }

  @override
  Future<void> clearGaze() => _invoke('clearGaze');

  @override
  Future<void> startLipSync(List<double> envelope, {int frameRate = 30}) {
    if (envelope.isEmpty) return Future.value();
    return _invoke('startLipSync', {
      'envelope': envelope,
      'frameRate': frameRate.clamp(1, 120),
    });
  }

  @override
  Future<void> startVisemeTrack(LipSyncVisemeTrack track) {
    return _invoke('startVisemeTimeline', track.toRendererJson());
  }

  @override
  Future<void> syncSpeechPlaybackClock(SpeechPlaybackClock clock) {
    if (AvatarProductionOwnership.blocksLegacyAvatarMutation) {
      return Future<void>.value();
    }
    if (!isReady.value || !presentationReady.value) {
      return Future<void>.value();
    }
    return _invoke('syncSpeechPlaybackClock', clock.toJson());
  }

  @override
  Future<void> setConversationPhase(String phase, {required int sequence}) {
    if (AvatarProductionOwnership.blocksLegacyAvatarMutation) {
      return Future<void>.value();
    }
    if (!isReady.value || !presentationReady.value) {
      return Future<void>.value();
    }
    if (!const {
          'listening',
          'thinking',
          'speaking',
          'stopped',
        }.contains(phase) ||
        sequence <= 0) {
      return Future<void>.error(ArgumentError('Invalid conversation phase'));
    }
    return _invoke('setConversationPhase', {
      'phase': phase,
      'sequence': sequence,
    });
  }

  @override
  Future<void> stopLipSync() => _invoke('stopLipSync');

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) {
    return _invoke('playPrimitive', {
      'type': type,
      'options': opts ?? const <String, dynamic>{},
    });
  }

  @override
  Future<void> playAnimationClip(String id, [Map<String, dynamic>? opts]) {
    return _invoke('playAnimationClip', {
      'id': id,
      'options': opts ?? const <String, dynamic>{},
    });
  }

  @override
  Future<void> setHandIkTarget(String target, [Map<String, dynamic>? opts]) {
    return _invoke('setHandIkTarget', {
      'target': target,
      'options': opts ?? const <String, dynamic>{},
    });
  }

  @override
  Future<void> setBodyPose(AvatarBodyPose pose) {
    return _invoke('setBodyPose', pose.toJson());
  }

  @override
  Future<void> transitionPresence(AvatarPresenceTransition request) =>
      _presenceTransitions.run(request);

  @override
  Future<void> setPhoneInteraction({
    required String interactionId,
    required AvatarPhoneInteractionPhase phase,
  }) => _phoneInteractions.run(interactionId: interactionId, phase: phase);

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) {
    return _invoke('playMotion', {
      'type': type,
      'options': opts ?? const <String, dynamic>{},
    });
  }

  @override
  Future<void> playMotionSequence(List<AvatarMotionStep> steps) {
    if (steps.isEmpty) return Future.value();
    return _invoke('playMotionSequence', {
      'steps': steps.map((step) => step.toJson()).toList(growable: false),
    });
  }

  @override
  Future<void> setFraming(String mode) => _invoke('setFraming', {'mode': mode});

  @override
  Future<void> setViewportSafeArea(AvatarViewportSafeArea safeArea) {
    _latestViewportSafeArea = safeArea;
    return _invoke('setViewportSafeArea', safeArea.toJson());
  }

  Future<void> setWorldTimeOfDay(String timeOfDay) {
    return _invoke('setWorldTimeOfDay', {
      'timeOfDay': timeOfDay.trim().isEmpty ? 'afternoon' : timeOfDay.trim(),
    });
  }

  @override
  Future<void> setWorldLighting(AvatarWorldLighting lighting) async {
    _latestWorldLighting = lighting;
    await setWorldTimeOfDay(lighting.name);
  }

  Future<void> setWorldCamera(String mode) {
    return _invoke('setWorldCamera', {
      'mode': mode.trim().isEmpty ? 'hero_full_body' : mode.trim(),
    });
  }

  @override
  Future<void> setWorldFraming(AvatarWorldFraming framing) =>
      setWorldCamera(framing.wireValue);

  @override
  Future<void> reactToScreenTap({
    required double normalizedX,
    required double normalizedY,
  }) {
    return _invoke('reactToScreenTap', {
      'x': normalizedX.clamp(0.0, 1.0).toDouble(),
      'y': normalizedY.clamp(0.0, 1.0).toDouble(),
    });
  }

  @override
  Future<void> enterAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) => _agentSpaceCommand(
    'enterAgentSpace',
    sessionId,
    _agentSpaceTransitionArguments(animated, targetViewportSafeArea),
    targetViewportSafeArea,
  );

  @override
  Future<void> leaveAgentSpace({
    required String sessionId,
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) => _agentSpaceCommand(
    'leaveAgentSpace',
    sessionId,
    _agentSpaceTransitionArguments(animated, targetViewportSafeArea),
    targetViewportSafeArea,
  );

  Map<String, Object> _agentSpaceTransitionArguments(
    bool animated,
    AvatarViewportSafeArea? target,
  ) {
    if (target != null &&
        (!target.top.isFinite ||
            !target.bottom.isFinite ||
            target.top < 0 ||
            target.top > .45 ||
            target.bottom < 0 ||
            target.bottom > .45)) {
      throw ArgumentError('Invalid personal-room viewport');
    }
    return {
      if (animated) 'animated': true,
      if (target != null) 'viewportTop': target.top,
      if (target != null) 'viewportBottom': target.bottom,
    };
  }

  @override
  Future<void> moveAgentSpaceAtScreenPoint({
    required String sessionId,
    required double x,
    required double y,
  }) {
    if (!x.isFinite || !y.isFinite || x < 0 || x > 1 || y < 0 || y > 1) {
      throw ArgumentError('Invalid personal-room screen point');
    }
    return _agentSpaceCommand('requestAgentSpaceMoveAtScreenPoint', sessionId, {
      'x': x,
      'y': y,
    });
  }

  Future<void> _agentSpaceCommand(
    String method,
    String sessionId, [
    Map<String, Object> arguments = const {},
    AvatarViewportSafeArea? targetViewportSafeArea,
  ]) async {
    final match = RegExp(r'[A-Za-z0-9._:-]{1,128}').matchAsPrefix(sessionId);
    if (match == null || match.end != sessionId.length) {
      throw ArgumentError('Invalid personal-room session');
    }
    if (!isReady.value || _commandDispatchSink.isClosed) {
      throw StateError('Personal-room renderer is unavailable');
    }
    final isTransition = method != 'requestAgentSpaceMoveAtScreenPoint';
    if (method == 'enterAgentSpace' &&
        _agentSpaceViewportSession != sessionId) {
      _agentSpaceViewportSession = sessionId;
      _agentSpaceHomeViewport = _latestViewportSafeArea;
      ++_agentSpaceViewportGeneration;
    }
    final viewportSequence = isTransition
        ? ++_agentSpaceViewportSequence
        : _agentSpaceViewportSequence;
    final viewportTarget =
        targetViewportSafeArea ??
        (method == 'leaveAgentSpace' && _agentSpaceViewportSession == sessionId
            ? _agentSpaceHomeViewport
            : null);
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextCommandRequest++}';
    final receipt = Completer<void>();
    _observePendingReceipt(receipt);
    _pendingAgentSpace[requestId] = (
      method: method,
      sessionId: sessionId,
      epoch: _rendererReadinessGeneration,
      receipt: receipt,
      viewportGeneration: _agentSpaceViewportGeneration,
      viewportSequence: viewportSequence,
      viewportTarget: viewportTarget,
    );
    try {
      await _channel.invokeMethod<void>(method, <String, Object>{
        'requestId': requestId,
        'sessionId': sessionId,
        ...arguments,
      });
      // A normal exit includes a legal walking route, the pocket door and the
      // final camera route. Forced cleanup and all other commands keep their
      // existing deadline instead of waiting for that visible journey.
      final timeout =
          method == 'leaveAgentSpace' && arguments['animated'] == true
          ? _agentSpaceTimeout * 2
          : _agentSpaceTimeout;
      await receipt.future.timeout(timeout);
    } finally {
      _pendingAgentSpace.remove(requestId);
    }
  }

  bool _handleAgentSpaceResult(Map<String, dynamic> result) {
    final pending = _pendingAgentSpace[result['requestId']];
    if (pending == null ||
        pending.receipt.isCompleted ||
        pending.epoch != _rendererReadinessGeneration ||
        !isReady.value ||
        result['method'] != pending.method ||
        result['sessionId'] != pending.sessionId ||
        result['ok'] is! bool ||
        result['code'] is! String ||
        result.length != 5 ||
        !result.keys.toSet().containsAll(const {
          'method',
          'requestId',
          'sessionId',
          'ok',
          'code',
        }) ||
        (result['ok'] == true
            ? result['code'] != ''
            : !avatarAgentSpaceFailureCodes.contains(result['code']))) {
      return false;
    }
    if (result['ok'] == true) {
      if (pending.method != 'requestAgentSpaceMoveAtScreenPoint' &&
          pending.viewportGeneration == _agentSpaceViewportGeneration &&
          pending.viewportSequence >= _agentSpaceLatestViewportReceipt) {
        // Cache only the renderer's completed transition, before waking its
        // caller. A delayed entry receipt must not undo a completed exit.
        _agentSpaceLatestViewportReceipt = pending.viewportSequence;
        if (pending.viewportTarget != null) {
          _latestViewportSafeArea = pending.viewportTarget;
        }
        if (pending.method == 'leaveAgentSpace' &&
            _agentSpaceViewportSession == pending.sessionId) {
          _agentSpaceViewportSession = null;
          _agentSpaceHomeViewport = null;
          ++_agentSpaceViewportGeneration;
        }
      }
      pending.receipt.complete();
    } else {
      pending.receipt.completeError(
        AvatarAgentSpaceCommandException(
          method: pending.method,
          code: result['code'] as String,
        ),
      );
    }
    return true;
  }

  void _invalidateAgentSpace(String reason) {
    _agentSpaceViewportSession = null;
    _agentSpaceHomeViewport = null;
    ++_agentSpaceViewportGeneration;
    for (final pending in _pendingAgentSpace.values) {
      if (!pending.receipt.isCompleted) {
        pending.receipt.completeError(
          StateError('Personal-room renderer unavailable ($reason)'),
        );
      }
    }
    _pendingAgentSpace.clear();
  }

  void _retireAgentSpaceForPresentationChange(String reason) {
    // The native takeover cancels this room and restores its captured Home
    // projection. Retire its Dart receipts before dispatch: an old success
    // already sent by Unity must not publish its room viewport for the new
    // model or scene while the takeover is still awaiting its own receipt.
    if (_agentSpaceViewportSession != null) {
      _latestViewportSafeArea = _agentSpaceHomeViewport;
    }
    _invalidateAgentSpace(reason);
  }

  @override
  Future<void> resetAvatarForAccountBoundary(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {
    if (isReady.value) {
      await loadAvatar(modelUrl, config);
      return;
    }
    _loadedAvatarSignature = null;
    _modelLoadEpoch++;
    _pendingAccountBoundaryAvatarReset = (
      modelUrl: modelUrl,
      config: Map<String, dynamic>.unmodifiable(config),
    );
    _debugLog(
      '[AvatarLoad] deferred account-boundary reset reason=renderer_not_ready',
    );
  }

  @override
  Future<void> loadAvatar(
    String modelUrl, [
    Map<String, dynamic> config = const {},
  ]) async {
    if (_pendingAccountBoundaryAvatarReset != null) {
      _pendingAccountBoundaryAvatarReset = null;
      _debugLog('[AvatarLoad] superseded deferred account-boundary reset');
    }
    final descriptorProfile = AvatarCapabilityProfile.fromJson(
      config['capabilityProfile'],
    );
    if (descriptorProfile.hasBlockers) {
      throw StateError('Avatar capability profile is incompatible');
    }
    final signature = _avatarLoadSignature(modelUrl, config);
    if (_loadedAvatarSignature == signature) {
      _debugLog('[AvatarLoad] skipped already-loaded avatar');
      return;
    }
    for (final entry in _pendingAvatarLoadSignatures.entries) {
      if (entry.value != signature) continue;
      final pending = _pendingAvatarLoads[entry.key];
      if (pending != null && !pending.isCompleted) {
        _debugLog('[AvatarLoad] joined pending request=${entry.key}');
        await pending.future;
        return;
      }
    }
    final requestId =
        '${DateTime.now().microsecondsSinceEpoch}-${_nextCommandRequest++}';
    final payload = <String, Object?>{
      'requestId': requestId,
      'modelUrl': modelUrl,
      'config': config,
    };
    final expectedSha256 =
        config['approvedAssetSha256']?.toString().trim() ?? '';
    _debugLog(
      '[AvatarLoad] dispatch request=$requestId '
      'model=${config['assetName'] ?? config['avatar'] ?? 'unknown'} '
      'sha=${expectedSha256.isEmpty ? '-' : (expectedSha256.length <= 12 ? expectedSha256 : expectedSha256.substring(0, 12))}',
    );
    for (final key in const ['resource', 'path', 'streamingAsset']) {
      final value = config[key];
      if (value is String && value.trim().isNotEmpty) {
        payload[key] = value.trim();
      }
    }
    for (final pending in _pendingAvatarLoads.values) {
      if (!pending.isCompleted) {
        pending.completeError(StateError('Unity avatar load was superseded'));
      }
    }
    _pendingAvatarLoads.clear();
    _pendingAvatarLoadSignatures.clear();
    _pendingAvatarLoadsRequiringUnityProfile.clear();
    _pendingAccountBoundaryAvatarReset = null;
    final completer = Completer<void>();
    _invalidateHostTaskWork();
    _loadedAvatarRequestId = null;
    _backgroundTaskWorkVersion = 0;
    _backgroundTaskWorkPresentationEpoch++;
    _observePendingReceipt(completer);
    _pendingAvatarLoads[requestId] = completer;
    _pendingAvatarLoadSignatures[requestId] = signature;
    if (Uri.tryParse(modelUrl.trim())?.scheme.toLowerCase() == 'https') {
      _pendingAvatarLoadsRequiringUnityProfile.add(requestId);
    }
    _retireAgentSpaceForPresentationChange('avatar_load_dispatched');
    try {
      await _channel.invokeMethod<void>('loadAvatar', payload);
    } on MissingPluginException {
      _pendingAvatarLoads.remove(requestId);
      _pendingAvatarLoadSignatures.remove(requestId);
      _pendingAvatarLoadsRequiringUnityProfile.remove(requestId);
      throw StateError('Unity avatar loading is unavailable');
    } on PlatformException catch (error) {
      _pendingAvatarLoads.remove(requestId);
      _pendingAvatarLoadSignatures.remove(requestId);
      _pendingAvatarLoadsRequiringUnityProfile.remove(requestId);
      throw StateError(error.message ?? 'Unity avatar loading failed');
    }
    try {
      await completer.future.timeout(
        _avatarLoadTimeout,
        onTimeout: () => throw StateError('Unity avatar loading timed out'),
      );
      _loadedAvatarSignature = signature;
      _debugLog('[AvatarLoad] completed request=$requestId');
    } catch (error) {
      _debugLog('[AvatarLoad] failed request=$requestId error=$error');
      rethrow;
    } finally {
      _pendingAvatarLoads.remove(requestId);
      _pendingAvatarLoadSignatures.remove(requestId);
      _pendingAvatarLoadsRequiringUnityProfile.remove(requestId);
    }
  }

  String _avatarLoadSignature(String modelUrl, Map<String, dynamic> config) => [
    modelUrl.trim(),
    config['approvedAssetSha256']?.toString().trim().toLowerCase() ?? '',
    config['assetFormat']?.toString().trim().toLowerCase() ?? '',
    config['assetName']?.toString().trim() ?? '',
    config['avatar']?.toString().trim() ?? '',
  ].join('|');

  @override
  Future<void> pause() {
    _invalidateNativePresentation();
    return _invoke('pause');
  }

  @override
  Future<void> resume() => _invoke('resume');

  Future<void> prepareView() {
    if (_commandDispatchSink.isClosed) return Future<void>.value();
    if (!_requiresPresentationReceipt) return _invoke('prepareView');
    final presentationId = _nativePresentationId ??=
        'native-view-${++_nextNativePresentationId}';
    return _invoke('prepareView', {'presentationId': presentationId});
  }

  final Set<Object> _nativeViewOwners = Set<Object>.identity();
  static UnityAvatarRuntime? _nativeViewRuntime;

  /// Shared iOS underlay ownership survives overlapping Login/Home mounts.
  void retainNativeView(Object owner) {
    _nativeViewRuntime = this;
    _nativeViewOwners.add(owner);
  }

  Future<void> releaseNativeView(Object owner) async {
    if (_nativeViewOwners.remove(owner) && _nativeViewOwners.isEmpty) {
      // Login and Home can exchange owners during one Flutter frame. Wait
      // until that frame's synchronous widget changes finish before detaching.
      await Future<void>.value();
      if (_nativeViewOwners.isEmpty && identical(_nativeViewRuntime, this)) {
        _nativeViewRuntime = null;
        _invalidateNativePresentation();
        await _invoke('releaseView');
      }
    }
  }

  @override
  Future<void> prepareRenderer() => prepareView();

  Future<void> _invoke(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    const protectedAvatarChannelMethods = <String>{
      'setExpression',
      'setMouthOpen',
      'setGaze',
      'clearGaze',
      'startLipSync',
      'startVisemeTimeline',
      'stopLipSync',
      'playPrimitive',
      'playAnimationClip',
      'setHandIkTarget',
      'setBodyPose',
      'playMotion',
      'playMotionSequence',
      'setFraming',
      'reactToScreenTap',
    };
    const unsupportedWhileTicketed = <String>{
      'playPrimitive',
      'playAnimationClip',
      'setHandIkTarget',
      'setBodyPose',
      'playMotion',
      'playMotionSequence',
    };
    if (protectedAvatarChannelMethods.contains(method) &&
        AvatarProductionOwnership.blocksLegacyAvatarMutation) {
      _debugLog('$method skipped: ticketed avatar owner is active');
      if (unsupportedWhileTicketed.contains(method)) {
        throw PlatformException(
          code: 'avatar_authority_owned',
          message: 'Ticketed avatar ownership is active',
        );
      }
      return;
    }
    try {
      if (method == 'prepareView') {
        _debugLog('prepareView request');
      }
      await _channel.invokeMethod<void>(method, arguments);
      if (method == 'prepareView') {
        _debugLog('prepareView sent');
      }
    } on MissingPluginException {
      // Unity native host is optional until the Unity Library export is wired.
      _debugLog('$method skipped: native plugin unavailable');
      return;
    } on PlatformException catch (error) {
      _debugLog('$method failed: ${error.message}');
      if (error.code == 'not_ready' &&
          _notReadyActionMethods.contains(method)) {
        rethrow;
      }
      return;
    }
  }

  void _invalidatePendingRendererCommands(String reason) {
    _invalidateHostTaskWork();
    _invalidateAgentSpace(reason);
    _phoneInteractions.invalidate(reason);
    _presenceTransitions.invalidate(reason);
    _doorwayTransitions.invalidate(reason);
    final message = 'Unity avatar renderer restarted ($reason)';
    for (final completer in _pendingAvatarLoads.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError(message));
      }
    }
    _pendingAvatarLoads.clear();
    _pendingAvatarLoadSignatures.clear();
    _pendingAvatarLoadsRequiringUnityProfile.clear();
  }

  void _observePendingReceipt<T>(Completer<T> completer) {
    // Native/Web transports may synchronously report renderer loss while the
    // dispatch Future is still pending. Install an error listener immediately
    // so completing the receipt cannot escape as an uncaught asynchronous
    // error before the operation reaches its own `await completer.future`.
    unawaited(completer.future.then<void>((_) {}, onError: (Object _) {}));
  }

  void _debugLog(String message) {
    if (!kDebugMode) return;
    debugPrint('[UnityAvatar] $message');
  }

  @override
  void onClose() {
    _invalidateHostTaskWork();
    _loadedAvatarRequestId = null;
    _backgroundTaskWorkVersion = 0;
    _invalidateAgentSpace('runtime_closed');
    _rendererReadinessGeneration++;
    _phoneInteractions.close();
    _presenceTransitions.close();
    _doorwayTransitions.close();
    _commandDispatchSink.close();
    _invalidateNativePresentation();
    for (final completer in _pendingAvatarLoads.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('Unity avatar runtime closed'));
      }
    }
    _pendingAvatarLoads.clear();
    _pendingAvatarLoadSignatures.clear();
    _pendingAvatarLoadsRequiringUnityProfile.clear();
    _pendingAccountBoundaryAvatarReset = null;
    unawaited(_capabilityProfiles.close());
    unawaited(_furnitureStates.close());
    _channel.dispose();
    super.onClose();
  }
}

UnityAvatarTransport _resolveUnityAvatarTransport(
  MethodChannel? channel,
  UnityAvatarTransport? transport,
) {
  if (channel != null && transport != null) {
    throw ArgumentError('channel and transport cannot both be provided');
  }
  return transport ?? createUnityAvatarTransport(channel: channel);
}
