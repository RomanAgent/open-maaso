import 'dart:async';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_launch_presentation_session.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';

enum LoginDoorwayStage {
  idle,
  preparing,
  preparationFailed,
  opening,
  entering,
  framing,
  completed,
  skipped,
  cancelled,
}

/// Presentation-only intent survives login and onboarding routes. Authentication,
/// runtime authority, and account mounting remain owned by their existing services.
final class LoginDoorwayCoordinator extends AppService {
  LoginDoorwayCoordinator({
    required this.currentScope,
    required this.currentGeneration,
    required this.accountMounted,
    required this.consumeEntrance,
    this.onFramed,
    this.readinessTimeout = const Duration(seconds: 60),
    this.preparationTimeout = const Duration(seconds: 15),
    this.preparationRetryDelay = const Duration(milliseconds: 350),
  });

  static LoginDoorwayCoordinator ensure() =>
      appServices.maybeFind<LoginDoorwayCoordinator>() ??
      appServices.put(
        LoginDoorwayCoordinator(
          currentScope: AppletLocalOwnership.currentScopeKey,
          currentGeneration: () =>
              appServices
                  .maybeFind<AccountSessionLifecycleService>()
                  ?.generation ??
              -1,
          accountMounted: () =>
              appServices
                  .maybeFind<AccountSessionLifecycleService>()
                  ?.isMounted ??
              false,
          consumeEntrance:
              AppLaunchPresentationSession.ensure().consumeAuthenticatedDoorway,
          onFramed: () => appServices
              .maybeFind<AvatarCameraDirector>()
              ?.resumeAfterExternalPresentation(),
        ),
        permanent: true,
      );

  final String Function() currentScope;
  final int Function() currentGeneration;
  final bool Function() accountMounted;
  final bool Function() consumeEntrance;
  final void Function()? onFramed;
  final Duration readinessTimeout;
  final Duration preparationTimeout;
  final Duration preparationRetryDelay;
  final phase = LoginDoorwayStage.idle.obs;
  String? _scope;
  int? _accountGeneration;
  String? _transitionId;
  AvatarRuntime? _renderer;
  bool Function()? _canPresent;
  bool _running = false;
  bool _skipping = false;
  bool _prepared = false;
  bool _nativeStarted = false;
  bool _framed = false;
  int _epoch = 0;
  int _request = 0;
  int _preparationRetries = 0;
  DateTime? _nextPreparationAttemptAt;
  Timer? _deadline;
  Timer? _readinessDeadline;
  Future<void>? _avatarPreparationInFlight;
  bool _waitForPreviousAvatarPreparation = false;
  AccountSessionLifecycleService? _lifecycle;

  bool get matchesAccount =>
      _scope != null &&
      accountMounted() &&
      _scope == currentScope() &&
      _accountGeneration == currentGeneration();
  bool get active =>
      matchesAccount &&
      switch (phase.value) {
        LoginDoorwayStage.preparing ||
        LoginDoorwayStage.opening ||
        LoginDoorwayStage.entering ||
        LoginDoorwayStage.framing => true,
        _ => false,
      };
  bool get completed =>
      matchesAccount &&
      (phase.value == LoginDoorwayStage.completed ||
          (phase.value == LoginDoorwayStage.skipped && _framed));
  bool get covered => !_prepared;
  bool get canRetryPreparation =>
      matchesAccount && phase.value == LoginDoorwayStage.preparationFailed;
  String? get transitionId => _transitionId;

  @override
  void onInit() {
    super.onInit();
    _lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    _lifecycle?.addListener(_accountChanged);
  }

  /// Called only after authenticateAndMount succeeds, before identity routing.
  /// Taking the process entrance is atomic even if Home has not mounted yet.
  void requestAuthenticated() {
    if (!accountMounted()) return;
    if (matchesAccount && _transitionId != null) return;
    _stopNative(AvatarDoorwayPhase.cancel);
    _deadline?.cancel();
    _deadline = null;
    _readinessDeadline?.cancel();
    _readinessDeadline = null;
    _epoch++;
    _running = false;
    _skipping = false;
    _prepared = false;
    _nativeStarted = false;
    _framed = false;
    _preparationRetries = 0;
    _nextPreparationAttemptAt = null;
    _avatarPreparationInFlight = null;
    _waitForPreviousAvatarPreparation = false;
    _scope = currentScope();
    _accountGeneration = currentGeneration();
    _transitionId =
        'login-doorway-${DateTime.now().microsecondsSinceEpoch}-$_epoch';
    _renderer = null;
    phase.value = consumeEntrance()
        ? LoginDoorwayStage.preparing
        : LoginDoorwayStage.skipped;
  }

  /// Runs after identity/privacy routing permits entry. Cold renderer/model
  /// loading has its own budget; it must not consume the camera prepare budget.
  /// Failure keeps the authenticated Login presentation available for retry.
  void reconcile({
    required AvatarRuntime? renderer,
    required bool Function() canPresent,
    required bool reduceMotion,
    Future<void> Function()? prepareAvatar,
  }) {
    _accountChanged();
    if (!active) return;
    if (_renderer != null &&
        (!identical(renderer, _renderer) || !_renderer!.isReady.value)) {
      // A model can briefly become unready while the selected account Avatar
      // is loading. Let the preparation attempt settle and retry before any
      // native camera phase has been acknowledged.
      if (_prepared) interrupt();
      return;
    }
    if (_nativeStarted && !canPresent()) {
      if (_prepared) interrupt();
      return;
    }
    if (reduceMotion || (renderer != null && !renderer.supportsLoginDoorway)) {
      Log.w(
        '[LoginDoorway] skipped code=${reduceMotion ? 'reduce_motion' : 'renderer_unsupported'}',
      );
      unawaited(skip());
      return;
    }
    // A prior timed-out attempt may still be loading the selected Avatar.
    // Wait for that operation to settle before spending a new readiness budget
    // or calling prepareAvatar again. Its epoch cannot start a native phase.
    if (_waitForPreviousAvatarPreparation) return;
    if (!_prepared && _readinessDeadline == null && _deadline == null) {
      final epoch = _epoch;
      _readinessDeadline = Timer(readinessTimeout, () {
        if (epoch == _epoch) _failPreparation('readiness_timeout');
      });
    }
    final retryAt = _nextPreparationAttemptAt;
    if (retryAt != null && DateTime.now().isBefore(retryAt)) return;
    if (_running ||
        renderer == null ||
        !renderer.isReady.value ||
        !canPresent()) {
      return;
    }
    _renderer = renderer;
    _canPresent = canPresent;
    _running = true;
    final epoch = _epoch;
    unawaited(_run(renderer, epoch, prepareAvatar));
  }

  bool _current(AvatarRuntime renderer, int epoch) =>
      !isClosed &&
      active &&
      epoch == _epoch &&
      identical(renderer, _renderer) &&
      renderer.isReady.value &&
      (_canPresent?.call() ?? false);

  bool _continue(AvatarRuntime renderer, int epoch) {
    if (_current(renderer, epoch)) return true;
    if (epoch == _epoch && active) interrupt();
    return false;
  }

  Future<void> _run(
    AvatarRuntime renderer,
    int epoch,
    Future<void> Function()? prepareAvatar,
  ) async {
    var preparingAvatar = true;
    try {
      if (prepareAvatar != null) {
        final avatarPreparation = Future<void>.sync(prepareAvatar);
        _avatarPreparationInFlight = avatarPreparation;
        try {
          await avatarPreparation;
        } finally {
          if (identical(_avatarPreparationInFlight, avatarPreparation)) {
            _avatarPreparationInFlight = null;
            _waitForPreviousAvatarPreparation = false;
          }
        }
      }
      preparingAvatar = false;
      if (!_current(renderer, epoch)) {
        if (epoch == _epoch && active) {
          _retryPreparation('renderer_not_ready');
        }
        return;
      }
      _readinessDeadline?.cancel();
      _readinessDeadline = null;
      _deadline ??= Timer(preparationTimeout, () {
        if (epoch == _epoch) _failPreparation('preparation_timeout');
      });
      _nativeStarted = true;
      await _send(renderer, AvatarDoorwayPhase.prepare);
      if (!_continue(renderer, epoch)) return;
      _prepared = true;
      _deadline?.cancel();
      _deadline = null;
      phase.value = LoginDoorwayStage.opening;
      await _send(renderer, AvatarDoorwayPhase.open, durationMs: 650);
      if (!_continue(renderer, epoch)) return;
      phase.value = LoginDoorwayStage.entering;
      await _send(renderer, AvatarDoorwayPhase.enter, durationMs: 1200);
      if (!_continue(renderer, epoch)) return;
      phase.value = LoginDoorwayStage.framing;
      await _send(renderer, AvatarDoorwayPhase.frame, durationMs: 300);
      if (!_continue(renderer, epoch)) return;
      _deadline?.cancel();
      _deadline = null;
      _framed = true;
      phase.value = LoginDoorwayStage.completed;
      if (matchesAccount) onFramed?.call();
    } catch (error) {
      if (epoch == _epoch && matchesAccount) {
        final code = error is AvatarDoorwayTransitionException
            ? error.code
            : error.runtimeType.toString();
        if (!_prepared &&
            (preparingAvatar || _retryableNativePreparation(code))) {
          _retryPreparation(code);
        } else if (!_prepared) {
          _failPreparation(code);
        } else {
          Log.w('[LoginDoorway] terminal phase=${phase.value.name} code=$code');
          await skip();
        }
      }
    } finally {
      if (epoch == _epoch) _running = false;
    }
  }

  bool _retryableNativePreparation(String code) => switch (code) {
    'presentation_unavailable' ||
    'entry_already_owned' ||
    'camera_unavailable' ||
    'home_framing_unavailable' ||
    'interior_camera_route_unavailable' ||
    'not_ready' ||
    'renderer_replaced' ||
    'timeout' => true,
    _ => false,
  };

  void _retryPreparation(String code) {
    if (!active || _prepared) return;
    _renderer = null;
    _canPresent = null;
    _nativeStarted = false;
    _nextPreparationAttemptAt = DateTime.now().add(preparationRetryDelay);
    _transitionId =
        'login-doorway-${DateTime.now().microsecondsSinceEpoch}-$_epoch-${++_preparationRetries}';
    Log.w('[LoginDoorway] preparation retry=$_preparationRetries code=$code');
  }

  void _failPreparation(String code) {
    if (!active || _prepared) return;
    _epoch++;
    _deadline?.cancel();
    _deadline = null;
    _readinessDeadline?.cancel();
    _readinessDeadline = null;
    if (_nativeStarted) _stopNative(AvatarDoorwayPhase.cancel);
    _renderer = null;
    _canPresent = null;
    _running = false;
    _skipping = false;
    _nativeStarted = false;
    _nextPreparationAttemptAt = null;
    Log.w('[LoginDoorway] preparation failed code=$code');
    phase.value = LoginDoorwayStage.preparationFailed;
  }

  /// Retry only presentation for the same authenticated account. The already
  /// claimed entrance is retained and no login request is submitted again.
  void retryPreparation() {
    if (!canRetryPreparation) return;
    _epoch++;
    _waitForPreviousAvatarPreparation = _avatarPreparationInFlight != null;
    _prepared = false;
    _framed = false;
    _preparationRetries = 0;
    _transitionId =
        'login-doorway-${DateTime.now().microsecondsSinceEpoch}-$_epoch';
    phase.value = LoginDoorwayStage.preparing;
  }

  Future<void> _send(
    AvatarRuntime renderer,
    AvatarDoorwayPhase stage, {
    int durationMs = 0,
  }) => renderer.transitionLoginDoorway(
    AvatarDoorwayTransition(
      requestId: '$_transitionId-${++_request}',
      transitionId: _transitionId!,
      phase: stage,
      durationMs: durationMs,
    ),
  );

  Future<void> skip() async {
    if (!active || _skipping) return;
    _skipping = true;
    final renderer = _renderer;
    final epoch = ++_epoch;
    _deadline?.cancel();
    _deadline = null;
    _readinessDeadline?.cancel();
    _readinessDeadline = null;
    _nextPreparationAttemptAt = null;
    _avatarPreparationInFlight = null;
    _waitForPreviousAvatarPreparation = false;
    try {
      if (_prepared &&
          renderer?.isReady.value == true &&
          (_canPresent?.call() ?? false)) {
        await _send(renderer!, AvatarDoorwayPhase.skip);
        if (epoch == _epoch && matchesAccount) _framed = true;
      } else if (_nativeStarted) {
        _stopNative(AvatarDoorwayPhase.cancel);
      }
    } catch (_) {
      _stopNative(AvatarDoorwayPhase.cancel);
    } finally {
      if (epoch == _epoch && matchesAccount) {
        _running = false;
        _skipping = false;
        phase.value = LoginDoorwayStage.skipped;
        if (_framed && matchesAccount) onFramed?.call();
      }
    }
  }

  /// Backgrounding/route loss uses a stable terminal state; it never replays the
  /// full doorway or advances a camera while the application is hidden.
  void interrupt() {
    if (!active) return;
    _epoch++;
    _deadline?.cancel();
    _deadline = null;
    _readinessDeadline?.cancel();
    _readinessDeadline = null;
    _nextPreparationAttemptAt = null;
    _avatarPreparationInFlight = null;
    _waitForPreviousAvatarPreparation = false;
    _running = false;
    _skipping = false;
    _stopNative(AvatarDoorwayPhase.cancel);
    phase.value = LoginDoorwayStage.skipped;
  }

  void _accountChanged() {
    if (_scope == null || matchesAccount) return;
    _epoch++;
    _deadline?.cancel();
    _deadline = null;
    _readinessDeadline?.cancel();
    _readinessDeadline = null;
    _nextPreparationAttemptAt = null;
    _avatarPreparationInFlight = null;
    _waitForPreviousAvatarPreparation = false;
    _running = false;
    _skipping = false;
    _stopNative(AvatarDoorwayPhase.cancel);
    phase.value = LoginDoorwayStage.cancelled;
    _scope = null;
    _renderer = null;
  }

  void _stopNative(AvatarDoorwayPhase stage) {
    final renderer = _renderer;
    if (renderer == null || !renderer.isReady.value || _transitionId == null) {
      return;
    }
    unawaited(_send(renderer, stage).catchError((Object _) {}));
  }

  @override
  void onClose() {
    _epoch++;
    _deadline?.cancel();
    _readinessDeadline?.cancel();
    _avatarPreparationInFlight = null;
    _waitForPreviousAvatarPreparation = false;
    _lifecycle?.removeListener(_accountChanged);
    _stopNative(AvatarDoorwayPhase.cancel);
    super.onClose();
  }
}
