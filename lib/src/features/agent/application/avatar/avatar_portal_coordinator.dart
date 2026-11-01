import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

enum AvatarPortalPhase {
  dormant,
  preparing,
  waitingForFirstFrame,
  visible,
  suspended,
  releasing,
  failed,
}

final class AvatarPortalCoordinator extends ChangeNotifier {
  AvatarPortalCoordinator({
    required ActiveAvatarRuntime avatarRuntime,
    required AvatarPortalGateway gateway,
    this.runtimeReadyTimeout = const Duration(seconds: 3),
    this.firstFrameTimeout = const Duration(seconds: 3),
  }) : _avatarRuntime = avatarRuntime,
       _gateway = gateway {
    _eventSubscription = gateway.events.listen(_handlePortalEvent);
  }

  final ActiveAvatarRuntime _avatarRuntime;
  final AvatarPortalGateway _gateway;
  final Duration runtimeReadyTimeout;
  final Duration firstFrameTimeout;

  late final StreamSubscription<AvatarPortalEvent> _eventSubscription;
  AvatarPortalPhase _phase = AvatarPortalPhase.dormant;
  AvatarPortalLease? _lease;
  AvatarPortalFailure? _failure;
  Completer<AvatarPortalEvent>? _firstFrameCompleter;
  Future<AvatarPortalLease>? _summonFuture;
  int _nextGeneration = 0;
  int _activeGeneration = 0;
  AvatarPortalProfile? _activeProfile;
  int? _activeTargetFps;
  bool _activeIncludeWorld = false;
  int? _activeViewportWidth;
  int? _activeViewportHeight;
  ({
    AvatarPortalProfile profile,
    int targetFps,
    bool includeWorld,
    int? width,
    int? height,
  })?
  _pendingConfiguration;
  bool _closed = false;

  AvatarPortalPhase get phase => _phase;
  AvatarPortalLease? get lease => _lease;
  AvatarPortalFailure? get failure => _failure;
  bool get isBusy =>
      _phase == AvatarPortalPhase.preparing ||
      _phase == AvatarPortalPhase.waitingForFirstFrame ||
      _phase == AvatarPortalPhase.releasing;
  bool get isVisible => _phase == AvatarPortalPhase.visible;
  bool get capturesWorld => _activeGeneration > 0 && _activeIncludeWorld;

  bool usesCaptureConfiguration({
    required AvatarPortalProfile profile,
    required int targetFps,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  }) =>
      _lease != null &&
      _activeProfile == profile &&
      _activeTargetFps == targetFps &&
      _activeIncludeWorld == includeWorld &&
      _activeViewportWidth == viewportWidth &&
      _activeViewportHeight == viewportHeight;

  Future<AvatarPortalLease> summon({
    AvatarPortalProfile profile = AvatarPortalProfile.compactHigh,
    int targetFps = 30,
    bool includeWorld = false,
    int? viewportWidth,
    int? viewportHeight,
  }) {
    if (!AvatarPortalCapturePolicy.supportsTargetFps(targetFps)) {
      return Future<AvatarPortalLease>.error(
        const AvatarPortalFailure(
          'invalid_avatar_portal_target_fps',
          'Avatar portal target FPS must be 24, 30, or 60.',
        ),
      );
    }
    if (!AvatarPortalCapturePolicy.supportsSceneViewport(
      includeWorld: includeWorld,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
    )) {
      return Future<AvatarPortalLease>.error(
        const AvatarPortalFailure(
          'invalid_avatar_portal_viewport',
          'World capture requires a bounded viewport size.',
        ),
      );
    }
    final configuration = (
      profile: profile,
      targetFps: targetFps,
      includeWorld: includeWorld,
      width: viewportWidth,
      height: viewportHeight,
    );
    final existingLease = _lease;
    if ((_phase == AvatarPortalPhase.visible ||
            _phase == AvatarPortalPhase.suspended) &&
        existingLease != null &&
        usesCaptureConfiguration(
          profile: profile,
          targetFps: targetFps,
          includeWorld: includeWorld,
          viewportWidth: viewportWidth,
          viewportHeight: viewportHeight,
        )) {
      return Future<AvatarPortalLease>.value(existingLease);
    }
    final pending = _summonFuture;
    if (pending != null) {
      if (_pendingConfiguration == configuration) return pending;
      return pending.then(
        (_) => summon(
          profile: profile,
          targetFps: targetFps,
          includeWorld: includeWorld,
          viewportWidth: viewportWidth,
          viewportHeight: viewportHeight,
        ),
      );
    }
    final needsReplacement =
        existingLease != null &&
        (_phase == AvatarPortalPhase.visible ||
            _phase == AvatarPortalPhase.suspended);
    final future = needsReplacement
        ? _replace(
            profile,
            targetFps,
            includeWorld,
            viewportWidth,
            viewportHeight,
          )
        : _summon(
            profile,
            targetFps,
            includeWorld,
            viewportWidth,
            viewportHeight,
          );
    _summonFuture = future;
    _pendingConfiguration = configuration;
    future.then<void>(
      (_) {
        if (identical(_summonFuture, future)) {
          _summonFuture = null;
          _pendingConfiguration = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(_summonFuture, future)) {
          _summonFuture = null;
          _pendingConfiguration = null;
        }
      },
    );
    return future;
  }

  Future<AvatarPortalLease> _replace(
    AvatarPortalProfile profile,
    int targetFps,
    bool includeWorld,
    int? viewportWidth,
    int? viewportHeight,
  ) async {
    await release();
    return _summon(
      profile,
      targetFps,
      includeWorld,
      viewportWidth,
      viewportHeight,
    );
  }

  Future<AvatarPortalLease> _summon(
    AvatarPortalProfile profile,
    int targetFps,
    bool includeWorld,
    int? viewportWidth,
    int? viewportHeight,
  ) async {
    if (_closed) {
      throw const AvatarPortalFailure(
        'avatar_portal_closed',
        'The Avatar portal coordinator is closed.',
      );
    }
    final generation = _allocateGeneration();
    _activeGeneration = generation;
    _activeIncludeWorld = includeWorld;
    _lease = null;
    _failure = null;
    final firstFrameCompleter = Completer<AvatarPortalEvent>();
    _firstFrameCompleter = firstFrameCompleter;
    // A release can race native acquire before _summon reaches the first-frame
    // await below. Observe the source future immediately so that cancellation
    // is reported through the returned summon future instead of becoming an
    // uncaught asynchronous error.
    unawaited(
      firstFrameCompleter.future.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      ),
    );
    _setPhase(AvatarPortalPhase.preparing);
    try {
      await _waitForAvatarRuntime(generation);
      final lease = await _gateway.acquire(
        generation: generation,
        profile: profile,
        targetFps: targetFps,
        includeWorld: includeWorld,
        viewportWidth: viewportWidth,
        viewportHeight: viewportHeight,
      );
      if (_activeGeneration != generation) {
        throw const AvatarPortalFailure(
          'avatar_portal_cancelled',
          'The Avatar portal request was cancelled.',
        );
      }
      _lease = lease;
      _activeProfile = profile;
      _activeTargetFps = targetFps;
      _activeIncludeWorld = includeWorld;
      _activeViewportWidth = viewportWidth;
      _activeViewportHeight = viewportHeight;
      _setPhase(AvatarPortalPhase.waitingForFirstFrame);
      final event = await firstFrameCompleter.future.timeout(
        firstFrameTimeout,
        onTimeout: () => throw const AvatarPortalFailure(
          'avatar_portal_first_frame_timeout',
          'The Avatar portal did not render its first frame in time.',
        ),
      );
      if (_activeGeneration != generation ||
          event.textureId != lease.textureId ||
          event.width != lease.width ||
          event.height != lease.height) {
        throw const AvatarPortalFailure(
          'avatar_portal_first_frame_mismatch',
          'The Avatar portal first frame did not match its active lease.',
        );
      }
      _setPhase(AvatarPortalPhase.visible);
      return lease;
    } catch (error) {
      final failure = error is AvatarPortalFailure
          ? error
          : AvatarPortalFailure(
              'avatar_portal_failed',
              'The Avatar portal could not be prepared.',
              cause: error,
            );
      if (_activeGeneration == generation) {
        _failure = failure;
        _lease = null;
        _activeProfile = null;
        _activeTargetFps = null;
        _activeIncludeWorld = false;
        _activeViewportWidth = null;
        _activeViewportHeight = null;
        _activeGeneration = 0;
        _setPhase(AvatarPortalPhase.failed);
        try {
          await _gateway.release(generation);
        } catch (_) {
          // Preserve the original preparation failure.
        }
      }
      throw failure;
    } finally {
      if (_activeGeneration != generation) _firstFrameCompleter = null;
    }
  }

  Future<void> _waitForAvatarRuntime(int generation) async {
    final runtime = _avatarRuntime.current;
    if (runtime == null || runtime.backendKind != AvatarBackendKind.unity) {
      throw const AvatarPortalFailure(
        'avatar_portal_runtime_unavailable',
        'The active Unity Avatar runtime is unavailable.',
      );
    }
    if (runtime.isReady.value) return;
    try {
      await runtime.isReady.stream
          .where((ready) => ready)
          .first
          .timeout(runtimeReadyTimeout);
    } on TimeoutException catch (error) {
      if (_activeGeneration != generation) {
        throw const AvatarPortalFailure(
          'avatar_portal_cancelled',
          'The Avatar portal request was cancelled.',
        );
      }
      throw AvatarPortalFailure(
        'avatar_portal_runtime_timeout',
        'The active Unity Avatar runtime did not become ready in time.',
        cause: error,
      );
    }
  }

  Future<void> suspend() async {
    final lease = _lease;
    if (_phase != AvatarPortalPhase.visible || lease == null) return;
    await _gateway.suspend(lease.generation);
    if (_activeGeneration == lease.generation) {
      _setPhase(AvatarPortalPhase.suspended);
    }
  }

  Future<void> resume() async {
    final lease = _lease;
    if (_phase != AvatarPortalPhase.suspended || lease == null) return;
    await _waitForAvatarRuntime(lease.generation);
    await _gateway.resume(lease.generation);
    if (_activeGeneration == lease.generation) {
      _setPhase(AvatarPortalPhase.visible);
    }
  }

  Future<void> release() async {
    final generation = _activeGeneration;
    if (generation <= 0) {
      if (_phase != AvatarPortalPhase.dormant) {
        _lease = null;
        _activeProfile = null;
        _activeTargetFps = null;
        _activeIncludeWorld = false;
        _activeViewportWidth = null;
        _activeViewportHeight = null;
        _failure = null;
        _setPhase(AvatarPortalPhase.dormant);
      }
      return;
    }
    _activeGeneration = 0;
    _lease = null;
    _activeProfile = null;
    _activeTargetFps = null;
    _activeIncludeWorld = false;
    _activeViewportWidth = null;
    _activeViewportHeight = null;
    _failure = null;
    final completer = _firstFrameCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        const AvatarPortalFailure(
          'avatar_portal_cancelled',
          'The Avatar portal request was cancelled.',
        ),
      );
    }
    _firstFrameCompleter = null;
    _setPhase(AvatarPortalPhase.releasing);
    try {
      await _gateway.release(generation);
    } finally {
      if (_activeGeneration == 0) _setPhase(AvatarPortalPhase.dormant);
    }
  }

  void _handlePortalEvent(AvatarPortalEvent event) {
    final generation = _activeGeneration;
    if (generation <= 0) return;
    if (event.type == AvatarPortalEventType.firstFrame) {
      if (event.generation != generation) return;
      final completer = _firstFrameCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete(event);
      }
      return;
    }
    if (event.type == AvatarPortalEventType.released &&
        (event.generation == 0 || event.generation == generation)) {
      _activeGeneration = 0;
      _lease = null;
      _activeProfile = null;
      _activeTargetFps = null;
      _activeIncludeWorld = false;
      _activeViewportWidth = null;
      _activeViewportHeight = null;
      final failure = AvatarPortalFailure(
        'avatar_portal_released',
        event.reason == 'memoryPressure'
            ? 'The Avatar portal was released because memory is low.'
            : 'The Avatar portal lease was released.',
      );
      _failure = failure;
      final completer = _firstFrameCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.completeError(failure);
      }
      _firstFrameCompleter = null;
      _setPhase(AvatarPortalPhase.failed);
    }
  }

  int _allocateGeneration() {
    if (_nextGeneration >= 0x7fffffff) _nextGeneration = 0;
    _nextGeneration += 1;
    return _nextGeneration;
  }

  void _setPhase(AvatarPortalPhase next) {
    if (_phase == next || _closed) return;
    _phase = next;
    notifyListeners();
  }

  Future<void> close() async {
    if (_closed) return;
    await release();
    _closed = true;
    await _eventSubscription.cancel();
  }

  @override
  void dispose() {
    if (!_closed) {
      _closed = true;
      final generation = _activeGeneration;
      _activeGeneration = 0;
      _activeProfile = null;
      _activeTargetFps = null;
      _activeIncludeWorld = false;
      _activeViewportWidth = null;
      _activeViewportHeight = null;
      _eventSubscription.cancel();
      if (generation > 0) unawaited(_gateway.release(generation));
    }
    super.dispose();
  }
}
