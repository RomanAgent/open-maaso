import 'dart:async';
import 'package:flutter/foundation.dart';

typedef VoiceInputRetirementRetry = Future<void> Function();
typedef VoiceInputOwnerRetirement = Future<void> Function();

/// Process-wide fence for retiring shared microphone, VAD, and ASR resources.
///
/// Maaso has two composer implementations, but both use the same singleton
/// capture services. A replacement composer must therefore wait for teardown
/// from either implementation before it can start another recording session.
final voiceInputRetirementCoordinator = VoiceInputRetirementCoordinator();

final class VoiceInputRetirementCoordinator {
  final Map<Object, _TrackedVoiceInputRetirement> _pending =
      Map<Object, _TrackedVoiceInputRetirement>.identity();
  _VoiceInputLease? _activeLease;
  Future<void>? _handoff;
  final ValueNotifier<int> priorityRevision = ValueNotifier(0);
  final ValueNotifier<int> sessionIntentRevision = ValueNotifier(0);
  String? _voiceSessionScopeKey;
  bool _voiceSessionRequested = false;

  String? get voiceSessionScopeKey => _voiceSessionScopeKey;

  /// Account mounting supplies identity; UI pages never select another scope.
  void mountVoiceSessionScope(String scopeKey) {
    if (_voiceSessionScopeKey == scopeKey) return;
    _voiceSessionScopeKey = scopeKey;
    _voiceSessionRequested = false;
    sessionIntentRevision.value++;
  }

  /// Account retirement revokes intent even while old capture is draining.
  void clearVoiceSessionIntent() {
    _voiceSessionScopeKey = null;
    _voiceSessionRequested = false;
    sessionIntentRevision.value++;
  }

  bool voiceSessionRequestedFor(String scopeKey) =>
      _voiceSessionRequested && _voiceSessionScopeKey == scopeKey;

  /// Only a successfully admitted capture owner may preserve a user's choice.
  void confirmVoiceSessionIntent(Object owner, String? scopeKey) {
    if (!isOwner(owner) ||
        scopeKey == null ||
        scopeKey != _voiceSessionScopeKey ||
        _voiceSessionRequested) {
      return;
    }
    _voiceSessionRequested = true;
    sessionIntentRevision.value++;
  }

  void endVoiceSessionIntent(Object owner) {
    if (!isOwner(owner) || !_voiceSessionRequested) return;
    _voiceSessionRequested = false;
    sessionIntentRevision.value++;
  }

  /// No audio or transcript crosses this admission boundary.
  bool get hasPendingUserInput =>
      _activeLease?.hasPendingUserInput?.call() ?? false;

  void notifyPriorityChanged(Object owner) {
    if (isOwner(owner)) priorityRevision.value++;
  }

  bool get isRetiring => _pending.isNotEmpty;

  bool isOwner(Object owner) => identical(_activeLease?.owner, owner);

  /// Serializes admission across both composer implementations. If another
  /// composer owns the shared capture stack, its registered retirement is
  /// awaited before the lease is transferred. A failed or stuck retirement
  /// keeps the old lease and therefore fails closed.
  Future<bool> acquire({
    required Object owner,
    required VoiceInputOwnerRetirement retireCurrentOwner,
    bool Function()? hasPendingUserInput,
  }) async {
    final inFlightHandoff = _handoff;
    if (inFlightHandoff != null) {
      await inFlightHandoff;
      return acquire(
        owner: owner,
        retireCurrentOwner: retireCurrentOwner,
        hasPendingUserInput: hasPendingUserInput,
      );
    }

    final handoffDone = Completer<void>();
    _handoff = handoffDone.future;
    try {
      await waitForIdle();
      final current = _activeLease;
      if (current != null && identical(current.owner, owner)) {
        _activeLease = _VoiceInputLease(
          owner: owner,
          retirement: retireCurrentOwner,
          hasPendingUserInput: hasPendingUserInput,
        );
        priorityRevision.value++;
        return true;
      }
      if (current != null) {
        await current.retirement();
        await waitForIdle();
        if (identical(_activeLease, current)) return false;
        if (_activeLease != null) return false;
      }
      if (_pending.isNotEmpty) return false;
      _activeLease = _VoiceInputLease(
        owner: owner,
        retirement: retireCurrentOwner,
        hasPendingUserInput: hasPendingUserInput,
      );
      priorityRevision.value++;
      return true;
    } finally {
      if (identical(_handoff, handoffDone.future)) _handoff = null;
      if (!handoffDone.isCompleted) handoffDone.complete();
    }
  }

  void release(Object owner) {
    if (identical(_activeLease?.owner, owner)) {
      _activeLease = null;
      priorityRevision.value++;
    }
  }

  void track({
    required Object key,
    required Future<void> retirement,
    VoiceInputRetirementRetry? retry,
  }) {
    final tracked = _TrackedVoiceInputRetirement(
      retirement: retirement,
      retry: retry,
    );
    _pending[key] = tracked;
    unawaited(
      retirement.then<void>(
        (_) {
          if (identical(_pending[key], tracked)) _pending.remove(key);
        },
        onError: (Object _, StackTrace _) {
          // Keep failed, retryable retirement work fenced. [waitForIdle]
          // performs one real retry per admission attempt.
        },
      ),
    );
  }

  /// Waits for all captured teardown work. A failed retryable operation gets
  /// one retry per call; if that retry also fails it remains fenced so a later
  /// admission can try again instead of starting over live resources.
  Future<void> waitForIdle() async {
    final attemptedRetries = Set<Object>.identity();
    while (_pending.isNotEmpty) {
      Object? firstError;
      StackTrace? firstStackTrace;
      final snapshot = _pending.entries.toList(growable: false);
      for (final mapEntry in snapshot) {
        final key = mapEntry.key;
        final tracked = mapEntry.value;
        if (!identical(_pending[key], tracked)) continue;
        try {
          await tracked.retirement;
          if (identical(_pending[key], tracked)) _pending.remove(key);
        } catch (error, stackTrace) {
          if (!identical(_pending[key], tracked)) continue;
          final retry = tracked.retry;
          if (retry != null && attemptedRetries.add(key)) {
            final replacement = Future<void>.sync(retry);
            track(key: key, retirement: replacement, retry: retry);
            continue;
          }
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }
    }
  }
}

final class _VoiceInputLease {
  const _VoiceInputLease({
    required this.owner,
    required this.retirement,
    this.hasPendingUserInput,
  });

  final Object owner;
  final VoiceInputOwnerRetirement retirement;
  final bool Function()? hasPendingUserInput;
}

final class _TrackedVoiceInputRetirement {
  const _TrackedVoiceInputRetirement({
    required this.retirement,
    required this.retry,
  });

  final Future<void> retirement;
  final VoiceInputRetirementRetry? retry;
}

/// Tracks in-flight operations that can still touch the shared capture stack.
/// The owning composer closes admission before [drain] and releases its
/// process-wide lease only after every tracked operation has settled.
final class VoiceInputOperationFence {
  final Set<Future<void>> _pending = Set<Future<void>>.identity();

  bool get isActive => _pending.isNotEmpty;

  Future<void> track(Future<void> operation) {
    late final Future<void> tracked;
    tracked = operation.whenComplete(() => _pending.remove(tracked));
    _pending.add(tracked);
    return tracked;
  }

  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait<void>(
        _pending.toList(growable: false),
        eagerError: false,
      );
    }
  }
}

/// Defers a follow-up operation until the current capture-stack work has
/// settled, then revalidates ownership/session state before it can run.
///
/// Callers must not await this from inside an operation tracked by [operations]
/// because that would wait on itself. Scheduling the returned future without
/// awaiting it lets the tracked segment complete first.
Future<bool> runVoiceInputAfterOperationDrain({
  required VoiceInputOperationFence operations,
  required bool Function() isCurrent,
  required Future<void> Function() action,
}) async {
  await operations.drain();
  if (!isCurrent()) return false;
  await action();
  return true;
}

/// Runs every teardown step, then rethrows the first failure with its original
/// stack. This prevents a failed VAD/subscription stop from skipping mic stop
/// or recognizer cancellation.
Future<void> runVoiceInputCleanupSteps(
  Iterable<FutureOr<void> Function()> steps,
) async {
  Object? firstError;
  StackTrace? firstStackTrace;
  for (final step in steps) {
    try {
      await step();
    } catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}

/// Cancels resources that can unblock tracked operations, drains those
/// operations, then performs a second captured-handle cleanup pass.
///
/// The first pass intentionally must succeed before [operations] is awaited:
/// a native recognizer start can remain pending until cancellation. Once the
/// drain has begun, its errors no longer skip the final compensating cleanup.
Future<void> retireVoiceInputResourcesWithOperationDrain({
  required Future<void> Function() retireResources,
  required VoiceInputOperationFence operations,
}) async {
  await retireResources();

  Object? firstError;
  StackTrace? firstStackTrace;
  try {
    await operations.drain();
  } catch (error, stackTrace) {
    firstError = error;
    firstStackTrace = stackTrace;
  }
  try {
    await retireResources();
  } catch (error, stackTrace) {
    firstError ??= error;
    firstStackTrace ??= stackTrace;
  }
  if (firstError != null) {
    Error.throwWithStackTrace(firstError, firstStackTrace!);
  }
}
