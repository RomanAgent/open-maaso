import 'dart:async';

typedef VoiceTurnSendErrorHandler =
    void Function(Object error, StackTrace stackTrace);

/// Serializes turn submissions while allowing capture to reopen first.
///
/// A caller reserves the next generation before it tears down and reopens the
/// microphone. It then launches the callback synchronously so controller APIs
/// that snapshot a shared text field do so before the field is cleared again.
/// Completion from an older generation can never clear a newer reservation.
final class VoiceTurnSendFence {
  VoiceTurnSendFence({void Function(bool busy)? onBusyChanged})
    : _onBusyChanged = onBusyChanged;

  final void Function(bool busy)? _onBusyChanged;
  int _generation = 0;
  VoiceTurnSendReservation? _reservation;
  Future<void>? _active;

  bool get isBusy => _reservation != null || _active != null;
  Future<void>? get active => _active;

  VoiceTurnSendReservation? reserve() {
    if (isBusy) return null;
    final reservation = VoiceTurnSendReservation._(++_generation);
    _reservation = reservation;
    _onBusyChanged?.call(true);
    return reservation;
  }

  bool owns(VoiceTurnSendReservation reservation) =>
      identical(_reservation, reservation) &&
      reservation.generation == _generation;

  /// Starts [operation] immediately and retains an error-consuming future.
  ///
  /// Returning the tracked future lets semantic barge-in wait for the old turn
  /// to finish without creating an unhandled asynchronous error.
  Future<void>? launch(
    VoiceTurnSendReservation reservation,
    Future<void> Function() operation, {
    VoiceTurnSendErrorHandler? onError,
  }) {
    if (!owns(reservation)) return null;

    late final Future<void> operationFuture;
    try {
      operationFuture = operation();
    } on Object catch (error, stackTrace) {
      _notifyError(onError, error, stackTrace);
      operationFuture = Future<void>.value();
    }

    _reservation = null;
    final generation = reservation.generation;
    late final Future<void> tracked;
    tracked = operationFuture
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stackTrace) {
            _notifyError(onError, error, stackTrace);
          },
        )
        .whenComplete(() {
          if (generation == _generation && identical(_active, tracked)) {
            _active = null;
            _onBusyChanged?.call(false);
          }
        });
    _active = tracked;
    unawaited(tracked);
    return tracked;
  }

  void cancelReservation(VoiceTurnSendReservation reservation) {
    if (!owns(reservation)) return;
    _reservation = null;
    _onBusyChanged?.call(false);
  }

  /// Waits for the currently launched turn. A later turn is a new generation
  /// and is intentionally outside this snapshot.
  Future<void> waitForActive() async {
    final active = _active;
    if (active != null) await active;
  }

  static void _notifyError(
    VoiceTurnSendErrorHandler? onError,
    Object error,
    StackTrace stackTrace,
  ) {
    if (onError == null) return;
    try {
      onError(error, stackTrace);
    } on Object {
      // Error reporting must never turn an already-consumed send failure into
      // another unhandled future.
    }
  }
}

final class VoiceTurnSendReservation {
  const VoiceTurnSendReservation._(this.generation);

  final int generation;
}
