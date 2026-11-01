import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_agent_space.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

enum AgentSpacePhase { initial, entering, active, failure, leaving }

@immutable
class AgentSpaceState {
  const AgentSpaceState(this.phase, {this.message});

  final AgentSpacePhase phase;
  final String? message;
}

/// A local presentation lifetime. Account mounting grants display; the cloud
/// conversation execution lease never decides whether this room is visible.
class AgentSpaceController extends AppService {
  AgentSpaceController({
    required ActiveAvatarRuntime avatar,
    Future<void> Function()? prepareAvatar,
    bool Function()? isCurrent,
    bool Function()? homeRouteIsCurrent,
    this.readyTimeout = const Duration(seconds: 22),
  }) : _avatar = avatar,
       _prepareAvatar = prepareAvatar,
       _isCurrent = isCurrent ?? (() => true),
       _homeRouteIsCurrent = homeRouteIsCurrent ?? _defaultHomeRouteIsCurrent;

  final ActiveAvatarRuntime _avatar;
  final Future<void> Function()? _prepareAvatar;
  final bool Function() _isCurrent;
  final bool Function() _homeRouteIsCurrent;
  final Duration readyTimeout;
  final state = ValueNotifier<AgentSpaceState>(
    const AgentSpaceState(AgentSpacePhase.initial),
  );
  Future<void> _nativeTail = Future<void>.value();
  Future<void>? _enterPending;
  Future<void>? _leavePending;
  AvatarRuntime? _renderer;
  String? _session;
  int _generation = 0;
  bool _closed = false;
  bool _resumed = true;
  bool _currentPage = true;
  Object? _activitySource;
  void Function()? _cancelReadyWait;
  bool? _homeVisibility;
  ({AvatarRuntime renderer, String session})? _animatedNativeTransition;
  ({AvatarRuntime renderer, String session})? _forcedRetirementOwner;
  Future<void>? _forcedRetirement;
  bool _forcedRetirementFailed = false;
  ({AvatarRuntime renderer, int modelEpoch})? _homeReturnFrame;
  ({AvatarRuntime renderer, String session, int modelEpoch, int generation})?
  _pendingHomeReturn;
  Object? _homeActivitySource;

  static bool _defaultHomeRouteIsCurrent() =>
      !appNavigation.isConfigured ||
      Uri.tryParse(appNavigation.currentRoute)?.path == AppRouteCatalog.home;

  bool get _presentable => !_closed && _currentPage && _isCurrent();
  bool get isCurrentPresentation => !_closed && _isCurrent();

  /// Home chrome may already be mounted while this exact room still owns the
  /// rendered actor and camera. This is not a completed Home-frame receipt.
  bool get isReturningHome => hasPendingHomeReturn(_avatar.current);

  bool hasPendingHomeReturn(AvatarRuntime? renderer) {
    final pending = _pendingHomeReturn;
    return pending != null &&
        !_closed &&
        _resumed &&
        _isCurrent() &&
        pending.generation == _generation &&
        identical(pending.renderer, renderer) &&
        identical(pending.renderer, _avatar.current) &&
        identical(pending.renderer, _renderer) &&
        pending.session == _session &&
        pending.modelEpoch == pending.renderer.modelLoadEpoch &&
        pending.renderer.isReady.value;
  }

  /// The destination page observes the same native return without acquiring
  /// its body/camera. Losing Home or foreground retires that exact session.
  void setHomeActivity({
    required bool resumed,
    required bool currentPage,
    required Object source,
  }) {
    if (_closed) return;
    if (_pendingHomeReturn == null) {
      if (currentPage && !resumed) discardHomeReturnFrame();
      return;
    }
    if (currentPage &&
        resumed &&
        _homeRouteIsCurrent() &&
        hasPendingHomeReturn(_avatar.current)) {
      _homeActivitySource = source;
      _currentPage = false;
      _resumed = true;
      return;
    }
    if (!currentPage &&
        _homeActivitySource != null &&
        !identical(_homeActivitySource, source)) {
      return;
    }
    if (!currentPage &&
        _homeActivitySource == null &&
        resumed &&
        _homeRouteIsCurrent() &&
        isReturningHome) {
      return;
    }
    _resumed = resumed;
    _cancelHomeReturn();
  }

  void _cancelHomeReturn() {
    _pendingHomeReturn = null;
    _homeActivitySource = null;
    discardHomeReturnFrame();
    _leaveFromActivity();
  }

  /// A successful foreground exit already presented Home. Its next local Home
  /// may adopt that frame once instead of hiding/re-preparing the same avatar.
  bool consumeHomeReturnFrame(AvatarRuntime renderer) {
    final frame = _homeReturnFrame;
    _homeReturnFrame = null;
    return frame != null &&
        !_closed &&
        _isCurrent() &&
        _session == null &&
        identical(frame.renderer, renderer) &&
        identical(_avatar.current, renderer) &&
        frame.modelEpoch == renderer.modelLoadEpoch &&
        renderer.isReady.value &&
        _avatar.localAvatarVisible == true;
  }

  void discardHomeReturnFrame() => _homeReturnFrame = null;

  void setActivity({
    required bool resumed,
    required bool currentPage,
    required Object source,
  }) {
    if (_closed) return;
    if (currentPage) {
      if (_pendingHomeReturn != null &&
          (!resumed ||
              !identical(source, _activitySource) ||
              !hasPendingHomeReturn(_avatar.current))) {
        _cancelHomeReturn();
      }
      if (!resumed) discardHomeReturnFrame();
      _activitySource = source;
      _currentPage = true;
      _resumed = resumed;
      if (!resumed && (_enterPending != null || _session != null)) {
        _leaveFromActivity();
      }
      return;
    }
    if (_activitySource != null && !identical(source, _activitySource)) return;
    // Navigation transfers the native transaction to Home. An old Space
    // widget disposal cannot cancel it after the destination has claimed it.
    if (_homeActivitySource != null && isReturningHome && resumed) return;
    if (resumed &&
        _homeRouteIsCurrent() &&
        hasPendingHomeReturn(_avatar.current)) {
      _currentPage = false;
      _resumed = true;
      return;
    }
    _pendingHomeReturn = null;
    _homeActivitySource = null;
    _currentPage = false;
    _resumed = false;
    _leaveFromActivity();
  }

  Future<void> enter({
    bool animated = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) {
    if (!_presentable || !_resumed) return Future<void>.value();
    if (_pendingHomeReturn != null) _cancelHomeReturn();
    discardHomeReturnFrame();
    _forgetFailedForcedRetirement();
    final pending = _enterPending;
    if (pending != null) return pending;
    if (state.value.phase == AgentSpacePhase.active &&
        identical(_renderer, _avatar.current) &&
        _renderer?.isReady.value == true) {
      return Future<void>.value();
    }
    final generation = ++_generation;
    final operation = _enter(
      generation,
      animated: animated,
      targetViewportSafeArea: targetViewportSafeArea,
    );
    _enterPending = operation;
    void completed() {
      if (identical(operation, _enterPending)) _enterPending = null;
    }

    operation.then<void>(
      (_) => completed(),
      onError: (Object _, StackTrace _) => completed(),
    );
    return operation;
  }

  Future<void> _enter(
    int generation, {
    required bool animated,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    _publish(const AgentSpaceState(AgentSpacePhase.entering));
    AvatarRuntime? renderer;
    String? session;
    try {
      await _leavePending;
      if (!_admitted(generation)) return;
      final previousRenderer = _renderer;
      final previousSession = _session;
      if (previousRenderer is AvatarAgentSpaceRuntime &&
          previousSession != null) {
        // A failed move still owns its native room. Retire that exact session
        // before trying another entry, preserving the original Home preference.
        await _enqueue(
          () => _retireNativeSession(
            previousRenderer as AvatarRuntime,
            previousSession,
          ),
        );
        if (identical(_renderer, previousRenderer) &&
            _session == previousSession) {
          _renderer = null;
          _session = null;
        }
      }
      if (!_admitted(generation)) return;
      final active = _avatar.current;
      if (active == null || active is! AvatarAgentSpaceRuntime) {
        throw UnsupportedError('Local avatar space is unavailable');
      }
      renderer = active;
      await active.prepareRenderer();
      await _waitForReady(active, generation);
      if (!_admitted(generation, active)) return;
      await _prepareAvatar?.call();
      if (!_admitted(generation, active)) return;
      final admittedSession =
          'space_${DateTime.now().microsecondsSinceEpoch}_$generation';
      session = admittedSession;
      _renderer = active;
      _session = admittedSession;
      _homeVisibility ??= _avatar.localAvatarVisible ?? true;
      await _enqueue(() async {
        if (!_admitted(generation, active)) return;
        await _avatar.setLocalAvatarVisible(true);
        if (!_admitted(generation, active)) return;
        final owner = (renderer: active, session: admittedSession);
        if (animated) _animatedNativeTransition = owner;
        try {
          await (active as AvatarAgentSpaceRuntime).enterAgentSpace(
            sessionId: admittedSession,
            animated: animated,
            targetViewportSafeArea: targetViewportSafeArea,
          );
        } finally {
          if (_animatedNativeTransition == owner) {
            _animatedNativeTransition = null;
          }
        }
      });
      if (!_admitted(generation, active)) {
        await _release(active, admittedSession);
        return;
      }
      _publish(const AgentSpaceState(AgentSpacePhase.active));
    } catch (error) {
      final released = renderer == null || session == null
          ? true
          : await _release(renderer, session);
      if (_admitted(generation)) {
        if (released &&
            session != null &&
            _session == session &&
            identical(_renderer, renderer)) {
          _renderer = null;
          _session = null;
        }
        // A failed cleanup retains its session for the next retry or exit.
        // Do not lose that authority or overwrite its original Home visibility.
        if (_session == null) {
          final visibility = _homeVisibility;
          if (visibility != null && identical(renderer, _avatar.current)) {
            await _avatar.setLocalAvatarVisible(visibility);
          }
          _homeVisibility = null;
        }
        _publish(const AgentSpaceState(AgentSpacePhase.failure));
      }
    }
  }

  bool _admitted(int generation, [AvatarRuntime? renderer]) =>
      _presentable &&
      _resumed &&
      generation == _generation &&
      (renderer == null || identical(renderer, _avatar.current));

  Future<void> _waitForReady(AvatarRuntime renderer, int generation) async {
    if (renderer.isReady.value) return;
    final ready = Completer<void>();
    void cancel() {
      if (!ready.isCompleted) {
        ready.completeError(StateError('Avatar space entry was cancelled'));
      }
    }

    _cancelReadyWait = cancel;
    final worker = renderer.isReady.listen((value) {
      if (value && !ready.isCompleted) ready.complete();
    });
    try {
      if (renderer.isReady.value && !ready.isCompleted) ready.complete();
      await ready.future.timeout(readyTimeout);
      if (!_admitted(generation, renderer)) {
        throw StateError('Avatar space entry was cancelled');
      }
    } finally {
      worker.dispose();
      if (identical(_cancelReadyWait, cancel)) _cancelReadyWait = null;
    }
  }

  Future<void> handleScreenTap(double normalizedX, double normalizedY) async {
    final renderer = _renderer;
    final session = _session;
    final generation = _generation;
    if (!_presentable ||
        !_resumed ||
        state.value.phase != AgentSpacePhase.active ||
        renderer is! AvatarAgentSpaceRuntime ||
        !identical(renderer, _avatar.current) ||
        session == null ||
        !normalizedX.isFinite ||
        !normalizedY.isFinite ||
        normalizedX < 0 ||
        normalizedX > 1 ||
        normalizedY < 0 ||
        normalizedY > 1) {
      return;
    }
    try {
      await (renderer as AvatarAgentSpaceRuntime).moveAgentSpaceAtScreenPoint(
        sessionId: session,
        x: normalizedX,
        y: normalizedY,
      );
    } catch (error) {
      if (error is AvatarAgentSpaceCommandException &&
          error.method == 'requestAgentSpaceMoveAtScreenPoint' &&
          (error.code == 'outside_walkable_floor' ||
              error.code == 'path_blocked')) {
        return;
      }
      if (_admitted(generation, renderer as AvatarRuntime) &&
          identical(renderer, _renderer) &&
          _session == session) {
        _publish(const AgentSpaceState(AgentSpacePhase.failure));
      }
    }
  }

  Future<void> leave({
    bool animated = false,
    bool handoffToHome = false,
    AvatarViewportSafeArea? homeViewportSafeArea,
  }) {
    final pending = _leavePending;
    if (pending != null && animated) return pending;
    final generation = ++_generation;
    _cancelReadyWait?.call();
    _enterPending = null;
    final renderer = _renderer;
    final session = _session;
    final modelEpoch = renderer?.modelLoadEpoch;
    final homeVisibility = _homeVisibility;
    final effectiveAnimated =
        animated && (!handoffToHome || homeVisibility != false);
    if (pending == null &&
        handoffToHome &&
        renderer != null &&
        session != null &&
        !_closed &&
        _resumed &&
        _currentPage &&
        _isCurrent() &&
        identical(renderer, _avatar.current) &&
        renderer.isReady.value) {
      _pendingHomeReturn = (
        renderer: renderer,
        session: session,
        modelEpoch: modelEpoch!,
        generation: generation,
      );
    } else {
      _pendingHomeReturn = null;
      _homeActivitySource = null;
    }
    final returnToken = _pendingHomeReturn;
    if (session != null) discardHomeReturnFrame();
    _forgetFailedForcedRetirement();
    if (!effectiveAnimated && renderer != null && session != null) {
      _forceAnimatedTransitionToHome(
        renderer,
        session,
        targetViewportSafeArea: homeViewportSafeArea,
      );
    }
    if (pending != null) return pending;
    final mayReturnFrame =
        (animated || handoffToHome) &&
        _resumed &&
        _currentPage &&
        homeVisibility == true;
    _publish(const AgentSpaceState(AgentSpacePhase.leaving));
    final operation =
        _enqueue(() async {
          if (renderer is AvatarAgentSpaceRuntime && session != null) {
            await _retireNativeSession(
              renderer as AvatarRuntime,
              session,
              animated:
                  effectiveAnimated &&
                  generation == _generation &&
                  !_closed &&
                  _isCurrent() &&
                  identical(renderer, _avatar.current) &&
                  renderer.modelLoadEpoch == modelEpoch,
              allowImmediateFallback: handoffToHome,
              targetViewportSafeArea: homeViewportSafeArea,
            );
          }
          if (!_closed &&
              _isCurrent() &&
              identical(renderer, _avatar.current)) {
            if (homeVisibility != null &&
                _avatar.localAvatarVisible != homeVisibility) {
              await _avatar.setLocalAvatarVisible(homeVisibility);
            }
          }
          if (identical(_renderer, renderer) && _session == session) {
            _renderer = null;
            _session = null;
            _homeVisibility = null;
          }
          if (mayReturnFrame &&
              (returnToken == null || _pendingHomeReturn == returnToken) &&
              renderer != null &&
              session != null &&
              generation == _generation &&
              !_closed &&
              _isCurrent() &&
              identical(renderer, _avatar.current) &&
              renderer.modelLoadEpoch == modelEpoch &&
              renderer.isReady.value &&
              _avatar.localAvatarVisible == true &&
              (_forcedRetirementOwner !=
                      (renderer: renderer, session: session) ||
                  (handoffToHome && !_forcedRetirementFailed))) {
            _homeReturnFrame = (renderer: renderer, modelEpoch: modelEpoch!);
          }
        }).catchError((Object error, StackTrace stack) {
          if (_pendingHomeReturn == returnToken) {
            _pendingHomeReturn = null;
            _homeActivitySource = null;
          }
          // Keep the exact session and Home preference until cleanup is acknowledged.
          // Strict account drain must observe failure instead of resetting another scope.
          _publish(const AgentSpaceState(AgentSpacePhase.failure));
          Error.throwWithStackTrace(error, stack);
        });
    _leavePending = operation;
    void completed() {
      if (identical(operation, _leavePending)) _leavePending = null;
      if (_pendingHomeReturn == returnToken) {
        _pendingHomeReturn = null;
        _homeActivitySource = null;
      }
      if (!_closed && state.value.phase == AgentSpacePhase.leaving) {
        _publish(const AgentSpaceState(AgentSpacePhase.initial));
      }
    }

    operation.then<void>(
      (_) => completed(),
      onError: (Object _, StackTrace _) => completed(),
    );
    return operation;
  }

  Future<void> _retireNativeSession(
    AvatarRuntime renderer,
    String session, {
    bool animated = false,
    bool allowImmediateFallback = false,
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) async {
    if (renderer is! AvatarAgentSpaceRuntime) return;
    final owner = (renderer: renderer, session: session);
    if (_forcedRetirementOwner == owner) {
      await _forcedRetirement;
      return;
    }
    if (animated) _animatedNativeTransition = owner;
    try {
      await (renderer as AvatarAgentSpaceRuntime).leaveAgentSpace(
        sessionId: session,
        animated: animated,
        targetViewportSafeArea: targetViewportSafeArea,
      );
      if (_forcedRetirementOwner == owner) {
        await _forcedRetirement;
      }
    } on AvatarAgentSpaceCommandException catch (error) {
      if (error.method == 'leaveAgentSpace' &&
          error.code == 'space_transition_cancelled' &&
          _forcedRetirementOwner == owner) {
        // A cancelled animation alone proves no cleanup. Only the exact
        // immediate-exit receipt may settle this original operation.
        await _forcedRetirement;
        return;
      }
      final retiredOwner =
          _closed || !_isCurrent() || !identical(renderer, _avatar.current);
      // Only a matched native receipt proves the old session no longer owns this
      // renderer. A timeout/unready channel or current-owner refusal proves nothing.
      if (retiredOwner &&
          error.method == 'leaveAgentSpace' &&
          (error.code == 'session_mismatch' ||
              error.code == 'session_retired')) {
        return;
      }
      if (allowImmediateFallback &&
          animated &&
          _forcedRetirementOwner != owner &&
          error.method == 'leaveAgentSpace' &&
          error.code != 'session_mismatch' &&
          error.code != 'session_retired') {
        await _retireNativeSession(
          renderer,
          session,
          targetViewportSafeArea: targetViewportSafeArea,
        );
        return;
      }
      rethrow;
    } catch (_) {
      if (allowImmediateFallback &&
          animated &&
          _forcedRetirementOwner != owner) {
        await _retireNativeSession(
          renderer,
          session,
          targetViewportSafeArea: targetViewportSafeArea,
        );
        return;
      }
      rethrow;
    } finally {
      if (_animatedNativeTransition == owner) {
        _animatedNativeTransition = null;
      }
    }
  }

  void _forceAnimatedTransitionToHome(
    AvatarRuntime renderer,
    String session, {
    AvatarViewportSafeArea? targetViewportSafeArea,
  }) {
    final owner = (renderer: renderer, session: session);
    if (_animatedNativeTransition != owner ||
        _forcedRetirementOwner == owner ||
        renderer is! AvatarAgentSpaceRuntime) {
      return;
    }
    _forcedRetirementOwner = owner;
    // This is the one command allowed to interrupt the serialized receipt
    // tail: the same native session must stop before background/account drain.
    final operation = Future<void>.sync(
      () => (renderer as AvatarAgentSpaceRuntime).leaveAgentSpace(
        sessionId: session,
        targetViewportSafeArea: targetViewportSafeArea,
      ),
    );
    _forcedRetirement = operation;
    _forcedRetirementFailed = false;
    unawaited(
      operation.catchError((Object _) {
        if (_forcedRetirementOwner == owner) _forcedRetirementFailed = true;
      }),
    );
  }

  void _forgetFailedForcedRetirement() {
    if (_leavePending != null || !_forcedRetirementFailed) return;
    _forcedRetirementOwner = null;
    _forcedRetirement = null;
    _forcedRetirementFailed = false;
  }

  Future<bool> _release(AvatarRuntime renderer, String session) async {
    try {
      await _enqueue(() => _retireNativeSession(renderer, session));
      return true;
    } catch (_) {
      return false;
    }
  }

  void _leaveFromActivity() {
    unawaited(
      leave().catchError((Object error) {
        debugPrint('[AgentSpace] exit cleanup failed: $error');
      }),
    );
  }

  Future<void> _enqueue(Future<void> Function() action) {
    final operation = _nativeTail.then((_) => action());
    _nativeTail = operation.catchError((Object _) {});
    return operation;
  }

  void _publish(AgentSpaceState value) {
    if (!_closed) state.value = value;
  }

  Future<void> deactivateAndDrain() async {
    if (_closed) {
      await leave();
      await _nativeTail;
      return;
    }
    final entering = _enterPending;
    final leaving = leave();
    _closed = true;
    await Future.wait<void>([?entering, leaving]);
    await _nativeTail;
  }

  @override
  void onClose() {
    _leaveFromActivity();
    _closed = true;
    state.dispose();
    super.onClose();
  }
}
