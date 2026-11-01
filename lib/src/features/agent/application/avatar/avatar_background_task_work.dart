import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/widgets.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';

import 'avatar_projection_production_authority.dart';
import 'avatar_runtime.dart';
export 'avatar_background_task_work_contract.dart';

typedef ApplyBackgroundTaskWork =
    Future<AvatarProductionBehaviorResult> Function(
      String sessionId,
      AvatarBackgroundTaskWorkPhase phase,
      bool Function() shouldContinue,
    );

/// Opaque intent for one current job. Renderer ownership is captured only when
/// this Home presentation can start; no session metadata reaches the model.
class AvatarBackgroundTaskWorkOwner {
  AvatarBackgroundTaskWorkOwner._({
    required this.jobId,
    required this.attempt,
    required this.scopeKey,
    required this.sessionId,
    required this.isCurrent,
    AvatarRuntime? renderer,
  }) : _waitingRenderer = renderer;

  final String jobId;
  final int attempt;
  final String scopeKey;
  final String sessionId;
  final bool Function() isCurrent;
  AvatarRuntime? _waitingRenderer;
  _TaskWorkBinding? _binding;
  bool _startQueued = false;
  bool _startAttempted = false;
  bool _applied = false;
  bool _observedOwner = false;
  bool _retired = false;
  bool _released = false;
  bool _releaseQueued = false;
  bool _suspended = false;
  int _suspensionGeneration = 0;
  String? _lastTrace;
}

enum _TaskWorkLane { override, authority, host }

final class _TaskWorkBinding {
  _TaskWorkBinding(this.renderer, this.authority, this.lane)
    : rendererEpoch = renderer.modelLoadEpoch,
      presentationEpoch = renderer.backgroundTaskWorkPresentationEpoch,
      authorityEpoch = lane == _TaskWorkLane.host
          ? authority?.hostTaskWorkAuthorityGeneration
          : authority?.rendererGeneration;

  final AvatarRuntime renderer;
  final int rendererEpoch;
  final int presentationEpoch;
  final AvatarProjectionProductionAuthority? authority;
  final int? authorityEpoch;
  final _TaskWorkLane lane;
}

/// Waits only for the current foreground Home job's existing renderer. It never
/// prepares/downloads an avatar or revives a retired job after navigation.
class AvatarBackgroundTaskWorkController with WidgetsBindingObserver {
  AvatarBackgroundTaskWorkController({
    this.agentId = 'self',
    AvatarRuntime? Function()? runtimeProvider,
    AvatarProjectionProductionAuthority? Function()? authorityProvider,
    bool Function()? canPresent,
    bool Function(AvatarRuntime renderer)? isReturningHome,
    bool Function(AvatarRuntime renderer)? isTemporarilyBlocked,
    ApplyBackgroundTaskWork? applyWork,
  }) : _runtimeProvider =
           runtimeProvider ??
           (() => appServices.maybeFind<ActiveAvatarRuntime>()?.current),
       _authorityProvider =
           authorityProvider ??
           (() => AvatarProductionOwnership.currentFor(agentId)),
       _canPresent =
           canPresent ??
           (() =>
               Uri.tryParse(appNavigation.currentRoute)?.path ==
               AppRouteCatalog.home),
       _isReturningHome =
           isReturningHome ??
           ((renderer) =>
               appServices
                   .maybeFind<AgentSpaceController>()
                   ?.hasPendingHomeReturn(renderer) ??
               false),
       _isTemporarilyBlocked = isTemporarilyBlocked ?? ((_) => false),
       _applyWork = applyWork;

  final AvatarRuntime? Function() _runtimeProvider;
  final String agentId;
  final AvatarProjectionProductionAuthority? Function() _authorityProvider;
  final bool Function() _canPresent;
  final bool Function(AvatarRuntime renderer) _isReturningHome;
  final bool Function(AvatarRuntime renderer) _isTemporarilyBlocked;
  final ApplyBackgroundTaskWork? _applyWork;
  final _workers = <Worker>[];
  StreamSubscription<AvatarFurnitureState>? _furniture;
  AvatarRuntime? _observedRenderer;
  Listenable? _routeChanges;
  Timer? _readinessTimer;
  AvatarBackgroundTaskWorkOwner? _owner;
  final Set<AvatarBackgroundTaskWorkOwner> _pendingReleases = Set.identity();
  bool _foreground = true;
  bool _observing = false;
  bool _closed = false;
  int _sequence = 0;
  Future<void> _tail = Future<void>.value();

  AvatarBackgroundTaskWorkOwner? get activeOwner => _owner;

  /// Foreground conversation must not replace a currently admitted job's body
  /// presentation, including the wait for its existing renderer to be ready.
  bool get hasCurrentWork {
    final owner = _owner;
    return owner != null && _intentCurrent(owner);
  }

  /// A newly admitted job may join this presentation only while its captured
  /// renderer/authority is still current. This never replays a retired owner.
  AvatarBackgroundTaskWorkOwner? get shareableOwner {
    final owner = _owner;
    if (owner == null || !_intentCurrent(owner)) return null;
    if (owner._binding != null &&
        (!_sameRenderer(owner) ||
            (owner._binding!.renderer.isReady.value &&
                !_laneReady(owner._binding!)))) {
      return null;
    }
    if (owner._waitingRenderer != null &&
        !identical(_runtimeProvider(), owner._waitingRenderer)) {
      return null;
    }
    return owner;
  }

  AvatarBackgroundTaskWorkOwner? begin({
    required String jobId,
    required int attempt,
    required String scopeKey,
    required bool Function() isCurrent,
  }) {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (_closed ||
        agentId != 'self' ||
        jobId.isEmpty ||
        attempt < 1 ||
        scopeKey.isEmpty ||
        !_canPresent() ||
        !isCurrent()) {
      return null;
    }
    final renderer = _runtimeProvider();
    final authority = _authorityProvider();
    if (renderer != null && !_authorityMatches(authority, renderer)) {
      return null;
    }
    if (!_observing && lifecycle != null) {
      _foreground = lifecycle == AppLifecycleState.resumed;
    }
    final previous = _owner;
    if (previous != null) _retire(previous);
    final owner = AvatarBackgroundTaskWorkOwner._(
      jobId: jobId,
      attempt: attempt,
      scopeKey: scopeKey,
      sessionId: sha256
          .convert(
            utf8.encode(
              '$scopeKey\u0000$jobId\u0000$attempt\u0000${++_sequence}',
            ),
          )
          .toString(),
      renderer: renderer,
      isCurrent: isCurrent,
    );
    _owner = owner;
    _watch(owner);
    if (previous != null) _queueRelease(previous);
    _reconcile(owner);
    return owner;
  }

  Future<void> end(AvatarBackgroundTaskWorkOwner? owner) {
    if (owner == null) return Future<void>.value();
    _retire(owner);
    return _queueRelease(owner);
  }

  Future<void> waitForIdle() => _tail;

  bool _authorityMatches(
    AvatarProjectionProductionAuthority? authority,
    AvatarRuntime renderer,
  ) =>
      authority == null ||
      (authority.agentId == agentId && identical(authority.renderer, renderer));

  bool _intentCurrent(AvatarBackgroundTaskWorkOwner owner) =>
      !_closed &&
      !owner._retired &&
      identical(_owner, owner) &&
      _canPresent() &&
      owner.isCurrent();

  bool _sameRenderer(AvatarBackgroundTaskWorkOwner owner) {
    final binding = owner._binding;
    return binding != null &&
        identical(_runtimeProvider(), binding.renderer) &&
        binding.renderer.modelLoadEpoch == binding.rendererEpoch &&
        binding.renderer.backgroundTaskWorkPresentationEpoch ==
            binding.presentationEpoch &&
        identical(_authorityProvider(), binding.authority) &&
        (binding.lane == _TaskWorkLane.host
                ? binding.authority?.hostTaskWorkAuthorityGeneration
                : binding.authority?.rendererGeneration) ==
            binding.authorityEpoch;
  }

  bool _laneReady(_TaskWorkBinding binding) => switch (binding.lane) {
    _TaskWorkLane.override =>
      _applyWork != null &&
          binding.renderer.supportsBackgroundTaskWorkPresentation,
    _TaskWorkLane.authority =>
      binding.authority?.phase == AvatarProductionAuthorityPhase.enforcing &&
          binding.renderer.supportsBackgroundTaskWorkPresentation,
    _TaskWorkLane.host =>
      binding.renderer.supportsHostBackgroundTaskWorkPresentation &&
          !AvatarProductionOwnership.ownsRenderer &&
          (binding.authority == null ||
              binding.authority?.phase ==
                  AvatarProductionAuthorityPhase.legacy ||
              binding.authority?.phase ==
                  AvatarProductionAuthorityPhase.shadow),
  };

  bool _current(AvatarBackgroundTaskWorkOwner owner) =>
      _intentCurrent(owner) &&
      _foreground &&
      _sameRenderer(owner) &&
      owner._binding!.renderer.isReady.value &&
      owner._binding!.renderer.presentationReady.value &&
      _laneReady(owner._binding!);

  void _reconcile(AvatarBackgroundTaskWorkOwner owner) {
    if (owner._retired || !identical(_owner, owner)) return;
    if (!_intentCurrent(owner)) {
      unawaited(end(owner));
      return;
    }
    final renderer = _runtimeProvider();
    if (owner._waitingRenderer != null &&
        renderer != null &&
        !identical(renderer, owner._waitingRenderer)) {
      _trace(owner, 'retired', 'renderer_changed');
      unawaited(end(owner));
      return;
    }
    if (owner._binding != null) {
      if (!_sameRenderer(owner)) {
        _trace(owner, 'retired', 'presentation_changed');
        unawaited(end(owner));
        return;
      }
      if (!_foreground ||
          !owner._binding!.renderer.isReady.value ||
          !owner._binding!.renderer.presentationReady.value) {
        // A hidden/native-detached presentation is not a terminal job. A fresh
        // same-session start on resume also restores host observation binding.
        _suspend(owner, 'presentation_not_ready');
        return;
      }
      if (!_laneReady(owner._binding!)) {
        _trace(owner, 'retired', 'presentation_changed');
        unawaited(end(owner));
        return;
      }
    } else {
      if (!_foreground) {
        _suspend(owner, 'app_backgrounded');
        return;
      }
      if (renderer == null) {
        _trace(owner, 'waiting', 'renderer_missing');
        return;
      }
      owner._waitingRenderer ??= renderer;
      _observeRenderer(owner, renderer);
      if (!renderer.isReady.value || !renderer.presentationReady.value) {
        _trace(owner, 'waiting', 'renderer_not_ready');
        return;
      }
      if (_isReturningHome(renderer)) {
        _trace(owner, 'waiting', 'space_returning');
        return;
      }
      final authority = _authorityProvider();
      if (!_authorityMatches(authority, renderer)) {
        _trace(owner, 'retired', 'foreign_renderer_authority');
        unawaited(end(owner));
        return;
      }
      final phase = authority?.phase;
      final lane = _applyWork != null
          ? _TaskWorkLane.override
          : phase == AvatarProductionAuthorityPhase.enforcing
          ? _TaskWorkLane.authority
          : !AvatarProductionOwnership.ownsRenderer &&
                (phase == null ||
                    phase == AvatarProductionAuthorityPhase.legacy ||
                    phase == AvatarProductionAuthorityPhase.shadow)
          ? _TaskWorkLane.host
          : null;
      if (lane == null) {
        _trace(owner, 'waiting', 'authority_not_ready');
        return;
      }
      final supported = lane == _TaskWorkLane.host
          ? renderer.supportsHostBackgroundTaskWorkPresentation
          : renderer.supportsBackgroundTaskWorkPresentation;
      if (!supported) {
        _trace(owner, 'waiting', 'work_protocol_not_ready');
        return;
      }
      owner._binding = _TaskWorkBinding(renderer, authority, lane);
    }
    if (_isReturningHome(owner._binding!.renderer)) {
      _trace(owner, 'waiting', 'space_returning');
      return;
    }
    owner._suspended = false;
    if (owner._applied || owner._startQueued) return;
    owner._startQueued = true;
    _enqueue(() async {
      try {
        if (!_current(owner)) return;
        if (_pendingReleases.any(
          (pending) =>
              !pending._released &&
              identical(pending._binding?.renderer, owner._binding!.renderer),
        )) {
          _trace(owner, 'waiting', 'previous_work_releasing');
          return;
        }
        final suspensionAtDispatch = owner._suspensionGeneration;
        final previouslyAttempted = owner._startAttempted;
        owner._startAttempted = true;
        final result = await _dispatch(
          owner,
          AvatarBackgroundTaskWorkPhase.start,
        );
        if (!_intentCurrent(owner) || !_sameRenderer(owner)) {
          _retire(owner);
          await _release(owner);
          return;
        }
        if (!_foreground ||
            !owner._binding!.renderer.isReady.value ||
            !owner._binding!.renderer.presentationReady.value) {
          _suspend(owner, 'presentation_not_ready');
        }
        if (result.applied) {
          owner._applied = _current(owner);
          _trace(owner, 'started', result.code);
        } else if (owner._suspensionGeneration > suspensionAtDispatch &&
            const {
              'session_ended',
              'deadline_expired',
              'mutation_failed',
              'dispatchFailed',
              'model_stale',
            }.contains(result.code)) {
          // Only a start that crossed this presentation's suspension boundary
          // gets a fresh ticket. Native still fences genuine ended sessions;
          // a fresh rejection with no newer boundary remains terminal.
          owner._applied = false;
          _trace(owner, 'suspended', 'start_boundary_interrupted');
        } else if (result.retryable) {
          // Waiting is a native pre-mutation rejection. Retain this exact job,
          // model, authority and session, rather than queueing a new owner.
          owner._startAttempted = previouslyAttempted;
          _trace(owner, 'waiting', result.code);
        } else {
          _trace(owner, 'rejected', result.code);
          _retire(owner);
          await _release(owner);
        }
      } on Object {
        _trace(owner, 'rejected', 'dispatch_failed');
        _retire(owner);
        await _release(owner);
      } finally {
        owner._startQueued = false;
      }
    });
  }

  void _suspend(AvatarBackgroundTaskWorkOwner owner, String reason) {
    if (!owner._suspended) owner._suspensionGeneration++;
    owner._suspended = true;
    owner._applied = false;
    _trace(owner, 'suspended', reason);
  }

  Future<AvatarBackgroundTaskWorkResult> _dispatch(
    AvatarBackgroundTaskWorkOwner owner,
    AvatarBackgroundTaskWorkPhase phase,
  ) async {
    bool admitted() => phase == AvatarBackgroundTaskWorkPhase.start
        ? _current(owner)
        : _sameRenderer(owner);
    if (!admitted()) {
      return const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.rejected,
        code: 'stale_presentation',
      );
    }
    final binding = owner._binding!;
    if (phase == AvatarBackgroundTaskWorkPhase.start &&
        _isTemporarilyBlocked(binding.renderer)) {
      // Retain this admitted job while a phone overlay releases its hands.
      // The existing readiness reconciliation resumes it without another job,
      // an extra timer, or a native start which would be rejected as busy.
      return const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
        code: 'phone_releasing',
      );
    }
    if (phase == AvatarBackgroundTaskWorkPhase.start &&
        _isReturningHome(binding.renderer)) {
      // Home controls are already usable, but the same actor still belongs to
      // its scene return. Retain the intent and let the existing 250ms poll
      // retry; never send a ticket which native may safely consume as a no-op.
      return const AvatarBackgroundTaskWorkResult(
        AvatarBackgroundTaskWorkDisposition.waitingForPresentation,
        code: 'space_returning',
      );
    }
    if (binding.lane == _TaskWorkLane.host) {
      return binding.renderer.setBackgroundTaskWork(
        sessionId: owner.sessionId,
        phase: phase,
      );
    }
    final override = _applyWork;
    final result = override != null
        ? await override(owner.sessionId, phase, admitted)
        : await binding.authority!.applyBackgroundTaskWork(
            sessionId: owner.sessionId,
            phase: phase,
            shouldContinue: admitted,
          );
    return AvatarBackgroundTaskWorkResult(
      result.applied
          ? AvatarBackgroundTaskWorkDisposition.applied
          : AvatarBackgroundTaskWorkDisposition.rejected,
      code: result.disposition.name,
    );
  }

  Future<void> _release(AvatarBackgroundTaskWorkOwner owner) async {
    if (owner._released) return;
    if (!owner._startAttempted) {
      await _finishRelease(owner);
      return;
    }
    final binding = owner._binding;
    if (!_sameRenderer(owner)) {
      await _finishRelease(owner);
      return;
    }
    if (!_foreground ||
        !binding!.renderer.isReady.value ||
        !binding.renderer.presentationReady.value) {
      if (_closed) await _finishRelease(owner);
      return;
    }
    try {
      final furniture = binding.renderer is AvatarFurnitureRuntime
          ? binding.renderer as AvatarFurnitureRuntime
          : null;
      final state = furniture?.furnitureState;
      if (binding.lane != _TaskWorkLane.host &&
          owner._observedOwner &&
          state != null &&
          state.workSessionId != owner.sessionId &&
          !_incidentalUnownedState(state)) {
        await _finishRelease(owner);
        return;
      }
      final result = await _dispatch(owner, AvatarBackgroundTaskWorkPhase.end);
      _trace(owner, result.applied ? 'ended' : 'end_skipped', result.code);
      if (!_closed &&
          (result.retryable ||
              const {
                'mutation_failed',
                'dispatchFailed',
                'not_ready',
                'work_unavailable',
              }.contains(result.code))) {
        // The exact terminal session is retried, never restarted. A lost
        // receipt is not proof that native has consumed the end command.
        return;
      }
      await _finishRelease(owner);
    } on Object {
      _trace(owner, 'end_skipped', 'dispatch_failed');
      if (_closed) await _finishRelease(owner);
    }
  }

  Future<void> _finishRelease(AvatarBackgroundTaskWorkOwner owner) async {
    if (owner._released) return;
    owner._released = true;
    _pendingReleases.remove(owner);
    if (owner._binding?.lane == _TaskWorkLane.authority) {
      await owner._binding?.authority?.releaseBackgroundTaskWorkLease(
        owner.sessionId,
      );
    }
    if (_owner == null && _pendingReleases.isEmpty) _unwatch();
  }

  Future<void> _queueRelease(AvatarBackgroundTaskWorkOwner owner) {
    if (owner._released || owner._releaseQueued) return _tail;
    owner._releaseQueued = true;
    return _enqueue(() async {
      try {
        await _release(owner);
      } finally {
        owner._releaseQueued = false;
      }
    });
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return _tail;
  }

  void _watch(AvatarBackgroundTaskWorkOwner owner) {
    if (_routeChanges == null && appNavigation.isConfigured) {
      _routeChanges = appNavigation.router.routerDelegate;
      _routeChanges!.addListener(_presentationChanged);
    }
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    // Load capability and model epochs need not change either ready Rx. This
    // check observes existing state only, and is cancelled with the job intent.
    _readinessTimer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      _presentationChanged();
    });
    final renderer = _runtimeProvider();
    if (renderer != null) _observeRenderer(owner, renderer);
  }

  void _observeRenderer(
    AvatarBackgroundTaskWorkOwner owner,
    AvatarRuntime renderer,
  ) {
    if (identical(renderer, _observedRenderer)) return;
    _observedRenderer = renderer;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    unawaited(_furniture?.cancel());
    _workers.add(ever<bool>(renderer.isReady, (_) => _reconcile(owner)));
    if (!identical(renderer.presentationReady, renderer.isReady)) {
      _workers.add(
        ever<bool>(renderer.presentationReady, (_) => _reconcile(owner)),
      );
    }
    final furniture = renderer is AvatarFurnitureRuntime
        ? renderer as AvatarFurnitureRuntime
        : null;
    _furniture = furniture?.furnitureStates.listen((state) {
      if (owner._retired || !identical(_owner, owner)) return;
      if (state.workSessionId == owner.sessionId) {
        owner._observedOwner = true;
      } else if (owner._observedOwner) {
        if (_intentCurrent(owner) &&
            _sameRenderer(owner) &&
            _incidentalUnownedState(state)) {
          // Generic foreground pose observations are not a cancellation of
          // the generation job. Keep this owner without replaying its start;
          // the native task presentation keeps the seated pose authoritative.
          _trace(owner, 'retained', 'foreground_pose_observation');
          return;
        }
        _trace(owner, 'retired', 'user_posture_takeover');
        unawaited(end(owner));
      }
    });
  }

  static bool _incidentalUnownedState(AvatarFurnitureState state) =>
      state.workSessionId == null &&
      (state.furnitureId == 'desk' ||
          state.phase == AvatarFurniturePhase.standing);

  void _presentationChanged() {
    for (final pending in _pendingReleases.toList(growable: false)) {
      unawaited(_queueRelease(pending));
    }
    final owner = _owner;
    if (owner != null) _reconcile(owner);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _presentationChanged();
  }

  void _trace(AvatarBackgroundTaskWorkOwner owner, String state, String code) {
    final safeCode = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,63}$').hasMatch(code)
        ? code
        : code.isEmpty
        ? 'none'
        : 'native_failure';
    final signature = '$state/$safeCode';
    if (owner._lastTrace == signature) return;
    owner._lastTrace = signature;
    TurnTrace.event(
      'task.work.$state',
      details: 'reason=$safeCode attempt=${owner.attempt}',
    );
  }

  void _retire(AvatarBackgroundTaskWorkOwner owner) {
    owner._retired = true;
    if (owner._startAttempted && !owner._released) {
      _pendingReleases.add(owner);
    }
    if (!identical(_owner, owner)) return;
    _owner = null;
    _unwatch();
  }

  void _unwatch() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    unawaited(_furniture?.cancel());
    _furniture = null;
    _observedRenderer = null;
    if (_pendingReleases.isEmpty) {
      _readinessTimer?.cancel();
      _readinessTimer = null;
      _routeChanges?.removeListener(_presentationChanged);
      _routeChanges = null;
      if (_observing) WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  Future<void> dispose() {
    _closed = true;
    final owner = _owner;
    if (owner != null) unawaited(end(owner));
    for (final pending in _pendingReleases.toList(growable: false)) {
      unawaited(_queueRelease(pending));
    }
    return _tail;
  }
}
