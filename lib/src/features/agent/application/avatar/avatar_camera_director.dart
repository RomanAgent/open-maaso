import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_command_arbiter.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_projection_production_authority.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

/// Owns conversational framing for the main self-avatar presentation.
///
/// Explicit shots survive speech events until interaction has been quiet for
/// [idleDelay]. World, live, capture and miniature portals own their cameras.
/// The production authority remains the only transport writer in enforce mode.
class AvatarCameraDirector extends AppService with WidgetsBindingObserver {
  AvatarCameraDirector({
    ActiveAvatarRuntime? avatarRuntime,
    bool Function()? mountIsCurrent,
    bool Function()? externalCameraActive,
    String? Function()? currentRoute,
    DateTime Function()? now,
    this.idleDelay = const Duration(seconds: 45),
  }) : _avatarOverride = avatarRuntime,
       _mountIsCurrent = mountIsCurrent ?? (() => true),
       _externalCameraActive = externalCameraActive ?? (() => false),
       _readRoute = currentRoute ?? (() => appNavigation.currentRoute),
       _now = now ?? DateTime.now {
    if (idleDelay <= Duration.zero) {
      throw ArgumentError.value(idleDelay, 'idleDelay');
    }
  }

  final ActiveAvatarRuntime? _avatarOverride;
  final bool Function() _mountIsCurrent;
  final bool Function() _externalCameraActive;
  final DateTime Function() _now;
  final Duration idleDelay;
  String? Function() _readRoute;
  final _subscriptions = <StreamSubscription<dynamic>>[];
  Worker? _backendWorker;
  Worker? _readyWorker;
  Worker? _presenceWorker;
  StreamSubscription<AvatarFurnitureState>? _furnitureSubscription;
  bool _sleepingShot = false;
  bool _workingShot = false;
  Listenable? _routeChanges;
  Listenable? _externalCameraChanges;
  Timer? _idleTimer;
  Future<void> _tail = Future<void>.value();
  Future<void>? _drain;
  AvatarRuntime? _renderer;
  String? _manualMode;
  String? _lastApplied;
  String? _pendingSignature;
  Future<Map<String, dynamic>>? _pending;
  DateTime? _lastActivity;
  DateTime? _lastPresenceActivity;
  DateTime? _deferredHomeActivity;
  bool _speaking = false;
  bool _userSpeaking = false;
  bool _engaged = false;
  bool _foreground = true;
  bool _presentationActive = false;
  bool _started = false;
  bool _sealed = false;
  int _generation = 0;
  int _manualVersion = 0;

  /// This is ownership, not visibility: legacy writers must also stand down
  /// while the app is in the background or a different camera owns the view.
  bool get isActive => _started && !_sealed && _mountIsCurrent();

  ActiveAvatarRuntime? get _activeAvatar =>
      _avatarOverride ?? appServices.maybeFind<ActiveAvatarRuntime>();

  bool get _canPresent =>
      isActive &&
      _foreground &&
      Uri.tryParse(_readRoute() ?? '')?.path == AppRouteCatalog.home &&
      !_externalCameraActive();

  @override
  void onInit() {
    super.onInit();
    _started = true;
    final binding = WidgetsBinding.instance;
    binding.addObserver(this);
    _foreground =
        binding.lifecycleState == null ||
        binding.lifecycleState == AppLifecycleState.resumed;
    bool mine(ClawEvent event) =>
        event.agentId == null || event.agentId == 'self';
    _subscriptions.addAll(<StreamSubscription<dynamic>>[
      EventBus().on<SpeakingStatusEvent>().where(mine).listen((event) {
        if (_speaking == event.isSpeaking) return;
        _speaking = event.isSpeaking;
        _observeInteraction(force: event.isSpeaking);
      }),
      EventBus().on<UserSpeakingStartedEvent>().listen((_) {
        _userSpeaking = true;
        _observeInteraction();
      }),
      EventBus().on<UserSpeakingEndedEvent>().listen((_) {
        if (!_userSpeaking) return;
        _userSpeaking = false;
        _observeInteraction();
      }),
    ]);
    final active = _activeAvatar;
    _bindRenderer(active?.current);
    if (active != null) {
      _backendWorker = ever<AvatarBackendKind>(active.backend, (_) {
        _bindRenderer(active.current);
      });
    }
    if (appNavigation.isConfigured) {
      bindRouteListener(appNavigation.router.routerDelegate);
    } else {
      _refreshPresentation();
    }
  }

  void bindRouteListener(
    Listenable? changes, {
    String? Function()? currentRoute,
  }) {
    if (_sealed) return;
    _routeChanges?.removeListener(_refreshPresentation);
    _routeChanges = changes;
    if (currentRoute != null) _readRoute = currentRoute;
    _routeChanges?.addListener(_refreshPresentation);
    _refreshPresentation();
  }

  void bindPresence(AgentPresenceService presence) {
    if (_sealed) return;
    _presenceWorker?.dispose();
    DateTime? activity(AgentPresenceState state) {
      final turn = state.lastUserInteractionAt;
      final input = state.lastInputActivityAt;
      if (turn == null) return input;
      return input != null && input.isAfter(turn) ? input : turn;
    }

    final boundAt = _now();
    _lastPresenceActivity = activity(presence.state.value);
    _presenceWorker = ever<AgentPresenceState>(presence.state, (state) {
      final latest = activity(state);
      if (latest == null || latest == _lastPresenceActivity) return;
      _lastPresenceActivity = latest;
      // Presence restores its persisted snapshot after the first frame. Those
      // old timestamps must not be mistaken for a new conversation.
      if (latest.isBefore(boundAt)) return;
      _observeInteraction();
    });
  }

  /// A native return may continue after Home is visible. Its completion, rather
  /// than route navigation alone, hands the camera back to this director.
  void bindExternalCameraChanges(Listenable? changes) {
    if (_sealed) return;
    _externalCameraChanges?.removeListener(_refreshPresentation);
    _externalCameraChanges = changes;
    _externalCameraChanges?.addListener(_refreshPresentation);
    _refreshPresentation();
  }

  void _bindRenderer(AvatarRuntime? renderer) {
    _readyWorker?.dispose();
    unawaited(_furnitureSubscription?.cancel());
    final furniture = renderer is AvatarFurnitureRuntime
        ? renderer as AvatarFurnitureRuntime
        : null;
    _sleepingShot = furniture?.furnitureState?.sleeping == true;
    _workingShot = _taskWorking(furniture?.furnitureState);
    _furnitureSubscription = furniture?.furnitureStates.listen((state) {
      if (_sealed || !identical(renderer, _renderer)) return;
      _workingShot = _taskWorking(state);
      if (state.sleeping) _sleepingShot = true;
      if (!state.transitioning && !state.sleeping) {
        final wasSleeping = _sleepingShot;
        _sleepingShot = false;
        if (wasSleeping) _observeInteraction(force: true);
      }
      unawaited(_applyCurrent(force: true));
    });
    _renderer = renderer;
    _clearConversation();
    if (renderer != null) {
      _readyWorker = ever<bool>(renderer.isReady, (_) {
        _sleepingShot = furniture?.furnitureState?.sleeping == true;
        _workingShot = _taskWorking(furniture?.furnitureState);
        _clearConversation();
        _refreshPresentation(force: true);
      });
    }
    _refreshPresentation(force: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _refreshPresentation();
  }

  void _refreshPresentation({bool force = false}) {
    if (_sealed) return;
    final active = _canPresent;
    if (!_foreground ||
        !isActive ||
        Uri.tryParse(_readRoute() ?? '')?.path != AppRouteCatalog.home) {
      _deferredHomeActivity = null;
    }
    if (!force && active == _presentationActive) return;
    final deferred = _deferredHomeActivity;
    _presentationActive = active;
    _clearConversation();
    if (!active) {
      _queueRelease();
      return;
    }
    final recentDeferred =
        deferred != null && _now().difference(deferred) < idleDelay;
    _engaged = _speaking || _userSpeaking || recentDeferred;
    if (_engaged) {
      _lastActivity = recentDeferred ? deferred : _now();
      _scheduleIdle();
    }
    unawaited(_applyCurrent(force: true));
  }

  void _clearConversation() {
    _generation++;
    _manualVersion++;
    _pendingSignature = null;
    _pending = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _manualMode = null;
    _lastApplied = null;
    _lastActivity = null;
    _deferredHomeActivity = null;
    _engaged = false;
  }

  void _observeInteraction({bool force = false}) {
    if (!_canPresent) {
      _refreshPresentation();
      if (isActive &&
          _foreground &&
          Uri.tryParse(_readRoute() ?? '')?.path == AppRouteCatalog.home &&
          _externalCameraActive()) {
        // Remember fresh Home interaction without issuing a shot into the
        // native walk. Ordinary framing may resume once its exact owner ends.
        _deferredHomeActivity = _now();
      }
      return;
    }
    if (!_presentationActive) _clearConversation();
    _presentationActive = true;
    _lastActivity = _now();
    _engaged = true;
    _scheduleIdle();
    unawaited(_applyCurrent(force: force));
  }

  void _scheduleIdle() {
    _idleTimer?.cancel();
    _idleTimer = null;
    if (_speaking || _userSpeaking || !_canPresent) return;
    final last = _lastActivity;
    if (last == null) return;
    final remaining = idleDelay - _now().difference(last);
    _idleTimer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () {
        _idleTimer = null;
        if (!_canPresent) {
          _refreshPresentation();
          return;
        }
        if (_speaking || _userSpeaking) return;
        if (_now().difference(_lastActivity ?? _now()) < idleDelay) {
          _scheduleIdle();
          return;
        }
        _manualMode = null;
        _manualVersion++;
        _engaged = false;
        unawaited(_applyCurrent());
      },
    );
  }

  Future<Map<String, dynamic>> setFraming(
    String mode, {
    String agentId = 'self',
  }) async {
    if (agentId != 'self') return _failure('camera_agent_unsupported');
    if (!const {'face', 'bust', 'full', 'auto'}.contains(mode)) {
      return _failure('camera_mode_invalid');
    }
    if (!_canPresent) return _failure('camera_presentation_unavailable');
    if (_renderer?.isReady.value != true) {
      return _failure('camera_renderer_not_ready');
    }
    if (!_presentationActive) _refreshPresentation();
    final version = ++_manualVersion;
    _manualMode = mode == 'auto' ? null : mode;
    _lastActivity = _now();
    _engaged = true;
    _scheduleIdle();
    final result = await _applyCurrent(force: true);
    if (result['ok'] != true) {
      if (version == _manualVersion) {
        _manualMode = null;
        _lastApplied = null;
      }
      return result;
    }
    return <String, dynamic>{
      ...result,
      'mode': mode,
      'automatic': mode == 'auto',
      'idleTimeoutSeconds': idleDelay.inSeconds,
    };
  }

  /// Resume the ordinary conversational/idle policy after a host-owned camera
  /// presentation, without briefly applying an intermediate full-body shot.
  void resumeAfterExternalPresentation() {
    if (!_canPresent || _renderer?.isReady.value != true) return;
    _clearConversation();
    _presentationActive = true;
    _observeInteraction(force: true);
  }

  Future<Map<String, dynamic>> _applyCurrent({bool force = false}) {
    final currentFurniture = _renderer is AvatarFurnitureRuntime
        ? (_renderer as AvatarFurnitureRuntime).furnitureState
        : null;
    // Model/ownership revocation need not change renderer readiness.
    _workingShot = _taskWorking(currentFurniture);
    final mode = _manualMode ?? (_engaged ? 'bust' : 'full');
    final framing = _sleepingShot
        ? 'sleeping_top'
        : _workingShot && _manualMode == null
        ? 'desk_over_shoulder'
        : switch (mode) {
            'face' => 'head',
            'bust' => 'upper_body',
            _ => 'hero_full_body',
          };
    final source = _manualMode != null
        ? AvatarCommandSource.explicitUser
        // Confirmed work keeps one camera lane across focus, typing, speech
        // and idle. Those interactions must not release/reacquire the same
        // rear camera simply because ordinary conversation became engaged.
        : _workingShot || _engaged
        ? AvatarCommandSource.auto
        : AvatarCommandSource.idle;
    final renderer = _renderer;
    final authority = AvatarProductionOwnership.currentFor('self');
    final signature =
        '$framing/${source.name}/${authority?.rendererGeneration}';
    if (!_canPresent ||
        renderer?.isReady.value != true ||
        !identical(renderer, _activeAvatar?.current)) {
      return Future.value(_failure('camera_presentation_unavailable'));
    }
    if (_pendingSignature == signature && _pending != null) return _pending!;
    if (!force && _pending == null && _lastApplied == signature) {
      return Future.value(<String, dynamic>{'ok': true, 'framing': framing});
    }
    final generation = ++_generation;
    bool current() =>
        generation == _generation &&
        _canPresent &&
        identical(renderer, _activeAvatar?.current) &&
        renderer?.isReady.value == true;
    final operation = _tail.then<Map<String, dynamic>>((_) async {
      if (!current()) return _failure('camera_request_superseded');
      try {
        if (AvatarProductionOwnership.ownsRenderer) {
          if (authority == null) {
            return _failure('camera_authority_unavailable');
          }
          final result = await authority.applyCameraFraming(
            mode: framing,
            source: source,
            shouldContinue: current,
          );
          if (!result.applied) {
            // A blocked request can retain a lease. Failed skill calls must
            // not silently move the camera later when a scene releases it.
            await authority.releaseCameraFraming();
            return _failure('camera_${result.disposition.name}');
          }
        } else {
          await renderer!.setFraming(framing);
        }
        if (!current()) return _failure('camera_request_superseded');
        _lastApplied = signature;
        TurnTrace.event(
          'avatar.camera',
          details: 'mode=$framing source=${source.name}',
        );
        return <String, dynamic>{'ok': true, 'framing': framing};
      } catch (_) {
        _lastApplied = null;
        return _failure('camera_dispatch_failed');
      }
    });
    _pendingSignature = signature;
    _pending = operation;
    _tail = operation.then<void>((_) {
      if (identical(_pending, operation)) {
        _pending = null;
        _pendingSignature = null;
      }
    });
    return operation;
  }

  static bool _taskWorking(AvatarFurnitureState? state) =>
      state?.phase == AvatarFurniturePhase.working &&
      state?.furnitureId == 'desk' &&
      state?.workSessionId != null;

  Map<String, dynamic> _failure(String code) => <String, dynamic>{
    'ok': false,
    'error': code,
  };

  void _queueRelease() {
    final authority = AvatarProductionOwnership.currentFor('self');
    if (authority == null) return;
    _tail = _tail.then((_) async {
      try {
        await authority.releaseCameraFraming();
      } catch (_) {
        // Account retirement also clears the authority's exact renderer epoch.
      }
    });
  }

  Future<void> waitForIdle() => _tail;

  Future<void> sealAndDrain() {
    return _drain ??= _sealAndDrain();
  }

  Future<void> _sealAndDrain() async {
    _sealed = true;
    _clearConversation();
    WidgetsBinding.instance.removeObserver(this);
    _routeChanges?.removeListener(_refreshPresentation);
    _externalCameraChanges?.removeListener(_refreshPresentation);
    _backendWorker?.dispose();
    _readyWorker?.dispose();
    _presenceWorker?.dispose();
    unawaited(_furnitureSubscription?.cancel());
    await Future.wait(
      _subscriptions.map((subscription) => subscription.cancel()),
    );
    _queueRelease();
    await _tail;
  }

  @override
  void onClose() {
    unawaited(sealAndDrain());
    super.onClose();
  }
}
