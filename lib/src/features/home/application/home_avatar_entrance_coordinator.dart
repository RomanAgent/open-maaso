import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

enum HomeAvatarEntrancePhase {
  idle,
  waiting,
  preparing,
  entering,
  completed,
  cancelled,
  failed,
}

/// A captured local account presentation and its exact renderer/model scope.
/// Callbacks reject replacement/reacquisition without granting execution rights.
final class HomeAvatarEntranceFence {
  HomeAvatarEntranceFence({
    required bool Function() isCurrent,
    bool Function()? modelIsCurrent,
  }) : _isCurrent = isCurrent,
       _modelIsCurrent = modelIsCurrent ?? (() => true);

  final bool Function() _isCurrent;
  final bool Function() _modelIsCurrent;
  bool get isCurrent => _isCurrent() && modelIsCurrent;

  /// Cleanup may hide the same model after account/route authority is lost.
  /// It must never move or hide a replacement selected on that same runtime.
  bool get modelIsCurrent => _modelIsCurrent();
}

/// Remembers the model generation actually shown for one account mount. Home
/// routes can be disposed by deep links or replacement navigation while the
/// model store is open; the next Home still needs to recognize a new model.
/// Expando keeps the account owner weakly referenced and avoids process-global
/// replay flags leaking between accounts.
final class HomeAvatarSelectionPresentationLedger {
  static final Expando<_PresentedSelection> _presented = Expando();

  static HomeAvatarModelPresentationSignature? lastPresented(
    Object owner,
    int accountGeneration,
  ) {
    final receipt = _presented[owner];
    return receipt?.accountGeneration == accountGeneration
        ? receipt?.modelSignature
        : null;
  }

  static void record(
    Object owner, {
    required int accountGeneration,
    required HomeAvatarModelPresentationSignature modelSignature,
  }) {
    _presented[owner] = _PresentedSelection(accountGeneration, modelSignature);
  }
}

final class _PresentedSelection {
  const _PresentedSelection(this.accountGeneration, this.modelSignature);

  final int accountGeneration;
  final HomeAvatarModelPresentationSignature modelSignature;
}

/// A renderer replacement is a new presentation even when both instances
/// happen to report the same model-load epoch (such as two fresh runtimes at 0).
final class HomeAvatarModelPresentationSignature {
  const HomeAvatarModelPresentationSignature({
    required this.selectionGeneration,
    required this.modelLoadEpoch,
    required this.renderer,
  });

  final int selectionGeneration;
  final int modelLoadEpoch;
  final AvatarRuntime? renderer;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HomeAvatarModelPresentationSignature &&
          selectionGeneration == other.selectionGeneration &&
          modelLoadEpoch == other.modelLoadEpoch &&
          identical(renderer, other.renderer);

  @override
  int get hashCode => Object.hash(
    selectionGeneration,
    modelLoadEpoch,
    identityHashCode(renderer),
  );
}

/// Presents a fenced Home pose, optionally with a launch entrance. Ownership stays
/// with AppAgentShell; this controller never changes local-avatar visibility.
///
/// Keep the actor hidden until [visible]. Home may leave the room and its chat
/// controls visible during model loading. A rendered `prepare` receipt lets the
/// owner enable local visibility while Unity still holds the actor hidden;
/// `enter` then positions it outside the viewport before revealing it.
final class HomeAvatarEntranceCoordinator {
  HomeAvatarEntranceCoordinator({
    required this.avatar,
    required this.captureFence,
    required this.canAnimate,
    required this.consumeEntrance,
    this.revealPreparedAvatar,
    this.duration = const Duration(milliseconds: 1565),
    this.reduceMotion = false,
  }) {
    if (duration.inMilliseconds < 300 || duration.inMilliseconds > 3000) {
      throw ArgumentError.value(duration, 'duration', 'Must be 300..3000ms');
    }
  }

  final ActiveAvatarRuntime avatar;
  final HomeAvatarEntranceFence? Function() captureFence;
  final bool Function() canAnimate;

  /// Called only after Unity has rendered the hidden preparation frame. The
  /// owner may now enable local visibility while native keeps the actor hidden
  /// until the ensuing enter/restore command.
  final Future<void> Function()? revealPreparedAvatar;

  /// The process session returns true at most once. Every presentation must
  /// consult it, including model replacement and interrupted presentation.
  final bool Function() consumeEntrance;
  final Duration duration;

  /// Updated from platform accessibility settings; captured once per attempt.
  bool reduceMotion;
  final phase = ValueNotifier(HomeAvatarEntrancePhase.idle);

  static int _nextCycle = 0;
  int _requestSequence = 0;
  bool _requested = false;
  bool _disposed = false;
  _EntranceAttempt? _attempt;
  _EntranceAttempt? _hiddenAttempt;
  Future<void> _cleanup = Future<void>.value();
  String? _failureCode;
  String? _failureStage;

  String? get failureCode => _failureCode;
  String? get failureStage => _failureStage;

  bool get visible =>
      (phase.value == HomeAvatarEntrancePhase.entering ||
          phase.value == HomeAvatarEntrancePhase.completed) &&
      _attempt != null &&
      _current(_attempt!);

  /// Adopt only a current, already-rendered Home handoff. No native entrance
  /// command or hide/reveal is needed; normal launches still use begin().
  bool adoptPresentedFrame(bool Function(AvatarRuntime renderer) consume) {
    if (_disposed ||
        !canAnimate() ||
        _hiddenAttempt != null ||
        (_attempt?.dispatched == true && _attempt?.completed != true)) {
      return false;
    }
    final renderer = avatar.current;
    if (renderer == null || !renderer.isReady.value) return false;
    final epoch = renderer.modelLoadEpoch;
    final fence = captureFence();
    if (fence == null ||
        !fence.isCurrent ||
        !fence.modelIsCurrent ||
        !consume(renderer)) {
      return false;
    }
    if (!identical(avatar.current, renderer) ||
        renderer.modelLoadEpoch != epoch ||
        !renderer.isReady.value ||
        !fence.isCurrent ||
        !fence.modelIsCurrent) {
      return false;
    }
    final attempt =
        _EntranceAttempt(
            renderer,
            fence,
            'home-return-${++_nextCycle}',
            reduceMotion,
          )
          ..operation = Future<void>.value()
          ..completed = true;
    _attempt = attempt;
    _requested = true;
    _failureCode = null;
    _failureStage = null;
    consumeEntrance();
    TurnTrace.event(
      'home.avatar_entry.adopted_space_return',
      details: 'modelEpoch=$epoch',
    );
    phase.value = HomeAvatarEntrancePhase.completed;
    return true;
  }

  /// Begins a fresh presentation transaction; the launch session decides
  /// whether it may walk in or must restore directly to the Home pose.
  void begin() {
    if (_disposed) return;
    _requested = false;
    _stop(HomeAvatarEntrancePhase.waiting);
    _failureCode = null;
    _failureStage = null;
    _requested = true;
    unawaited(reconcile());
  }

  /// Recheck after ownership, renderer, viewport, or Home visibility changes.
  /// Missing authority/readiness waits without sending any Unity command.
  Future<void> reconcile() async {
    if (_disposed || !_requested) return;
    final existing = _attempt;
    if (existing != null) {
      if (_current(existing)) return existing.operation;
      _stop(HomeAvatarEntrancePhase.waiting);
    }
    if (!canAnimate()) return;
    final renderer = avatar.current;
    if (renderer == null || !renderer.isReady.value) return;
    final fence = captureFence();
    if (fence == null || !fence.isCurrent) return;
    final attempt = _EntranceAttempt(
      renderer,
      fence,
      'home-entry-${DateTime.now().microsecondsSinceEpoch}-${++_nextCycle}',
      reduceMotion,
    );
    _attempt = attempt;
    // Assign the operation before notifications can synchronously reconcile.
    final receipt = Completer<void>();
    attempt.operation = receipt.future;
    unawaited(_run(attempt).whenComplete(receipt.complete));
    return receipt.future;
  }

  /// Synchronously covers Home, then releases only this transaction. A stale
  /// cancellation cannot override a handoff that has since taken presentation.
  Future<void> cancel() {
    _requested = false;
    if (!_disposed) _stop(HomeAvatarEntrancePhase.cancelled);
    return _cleanup;
  }

  bool _rendererCurrent(_EntranceAttempt attempt) =>
      identical(avatar.current, attempt.renderer) &&
      attempt.renderer.modelLoadEpoch == attempt.modelLoadEpoch &&
      attempt.fence.modelIsCurrent &&
      attempt.renderer.isReady.value;

  bool _current(_EntranceAttempt attempt) =>
      !_disposed &&
      _requested &&
      identical(_attempt, attempt) &&
      _rendererCurrent(attempt) &&
      // Losing foreground/native attachment readiness pauses animation, but
      // must not revoke an already-rendered frame from the iOS app switcher.
      // Pending entrance work still needs animation authority; completed frames
      // retain the same account/model fences and explicit cancellation checks.
      (attempt.completed || canAnimate()) &&
      attempt.fence.isCurrent;

  Future<void> _run(_EntranceAttempt attempt) async {
    try {
      await _cleanup;
      if (!_current(attempt)) return;
      // An earlier lease loss leaves its own transaction held hidden. Releasing
      // it is safe only after a fresh, valid authority has been captured. The
      // exact transition ID prevents touching a newer handoff/account reset.
      final hidden = _hiddenAttempt;
      if (hidden != null) {
        _hiddenAttempt = null;
        if (_rendererCurrent(hidden)) {
          try {
            await _send(hidden, AvatarPresencePhase.restore);
          } on AvatarPresenceTransitionException catch (error) {
            if (error.code != 'transition_mismatch' &&
                error.code != 'stale_request') {
              rethrow;
            }
          }
        }
      }
      if (!_current(attempt)) return;
      // Consume only after cleanup, readiness and ownership have all passed.
      // Reduced motion also consumes the launch, so disabling it later cannot
      // unexpectedly introduce an entrance while returning to Home.
      final launchEligible = consumeEntrance();
      final animate = launchEligible && !attempt.reduceMotion;
      phase.value = HomeAvatarEntrancePhase.preparing;
      if (!_current(attempt)) return;
      attempt.dispatched = true;
      await _send(attempt, AvatarPresencePhase.prepare);
      if (!_current(attempt)) {
        _invalidate(attempt);
        return;
      }
      attempt.stage = 'reveal';
      await revealPreparedAvatar?.call();
      if (!_current(attempt)) {
        _invalidate(attempt);
        return;
      }
      if (animate) {
        phase.value = HomeAvatarEntrancePhase.entering;
        // A UI listener may cancel or lose authority while uncovering the stage.
        if (!_current(attempt)) {
          _invalidate(attempt);
          return;
        }
      }
      // Reduced motion still waits for a rendered restore receipt. Do not
      // uncover the stage between hidden preparation and the final home pose.
      await _send(
        attempt,
        animate ? AvatarPresencePhase.enter : AvatarPresencePhase.restore,
      );
      if (!_current(attempt)) {
        _invalidate(attempt);
        return;
      }
      attempt.completed = true;
      TurnTrace.event(
        'home.avatar_entry.completed',
        details: 'stage=${attempt.stage} modelEpoch=${attempt.modelLoadEpoch}',
      );
      phase.value = HomeAvatarEntrancePhase.completed;
    } catch (error) {
      if (identical(_attempt, attempt) && !_disposed) {
        if (error is AvatarPresenceTransitionException &&
            error.code == 'scene_takeover') {
          // Native has already restored and retired this exact entrance before
          // applying the new scene. Do not show a failure or send late cleanup.
          attempt.dispatched = false;
          _requested = false;
          _stop(HomeAvatarEntrancePhase.cancelled);
          return;
        }
        if (!_current(attempt)) {
          _invalidate(attempt);
          return;
        }
        final nativeCode = error is AvatarPresenceTransitionException
            ? error.code
            : attempt.stage == 'reveal'
            ? 'local_visibility_failed'
            : 'presence_transport_failed';
        _failureCode = RegExp(r'^[a-z][a-z0-9_]{0,63}$').hasMatch(nativeCode)
            ? nativeCode
            : 'native_failure';
        _failureStage = attempt.stage;
        TurnTrace.event(
          'home.avatar_entry.failed',
          details:
              'stage=$_failureStage code=$_failureCode modelEpoch=${attempt.modelLoadEpoch}',
        );
        _requested = false;
        _stop(HomeAvatarEntrancePhase.failed);
      }
    }
  }

  void _invalidate(_EntranceAttempt attempt) {
    if (identical(_attempt, attempt) && !_disposed) {
      _stop(HomeAvatarEntrancePhase.waiting);
    }
  }

  void _stop(HomeAvatarEntrancePhase next) {
    final attempt = _attempt;
    _attempt = null;
    phase.value = next;
    if (attempt == null || !attempt.dispatched || attempt.completed) return;
    _cleanup = _cleanup.then((_) async {
      if (!_rendererCurrent(attempt)) return;
      final authorized = attempt.fence.isCurrent;
      if (!authorized) _hiddenAttempt = attempt;
      try {
        await _send(
          attempt,
          authorized
              ? AvatarPresencePhase.restore
              : AvatarPresencePhase.holdHidden,
        );
      } catch (_) {
        // Commands are bounded by Unity's rendered-receipt deadline. Home stays
        // covered on failure, and this exact ID cannot cancel another owner.
      }
    });
  }

  Future<void> _send(_EntranceAttempt attempt, AvatarPresencePhase action) {
    attempt.stage = action.name;
    TurnTrace.event(
      'home.avatar_entry.requested',
      details: 'stage=${action.name} modelEpoch=${attempt.modelLoadEpoch}',
    );
    return attempt.renderer.transitionPresence(
      AvatarPresenceTransition(
        requestId: '${attempt.id}-${++_requestSequence}',
        transitionId: attempt.id,
        phase: action,
        edge: AvatarPresenceEdge.right,
        durationMs: duration.inMilliseconds,
        doNotInterrupt: true,
      ),
    );
  }

  void dispose() {
    if (_disposed) return;
    unawaited(cancel());
    _disposed = true;
    phase.dispose();
  }
}

final class _EntranceAttempt {
  _EntranceAttempt(this.renderer, this.fence, this.id, this.reduceMotion)
    : modelLoadEpoch = renderer.modelLoadEpoch;
  final AvatarRuntime renderer;
  final HomeAvatarEntranceFence fence;
  final String id;
  final bool reduceMotion;
  final int modelLoadEpoch;
  String stage = 'waiting';
  late Future<void> operation;
  bool dispatched = false;
  bool completed = false;
}
