import 'dart:async';

/// Fixed logical steps, with no elapsed-time accumulator or catch-up queue.
/// A slow checkpoint skips wall-clock timer callbacks rather than submitting
/// overlapping rules work. Authority and persistence stay in the session.
final class SurfacePlayRealtimeClock {
  SurfacePlayRealtimeClock({
    required Future<void> Function() onTick,
    required bool Function() canTick,
    required void Function(Object, StackTrace) onError,
    Timer Function(Duration, void Function(Timer))? schedulePeriodic,
  }) : _onTick = onTick,
       _canTick = canTick,
       _onError = onError,
       _schedulePeriodic = schedulePeriodic ?? Timer.periodic;
  static const tickInterval = Duration(microseconds: 1000000 ~/ 30);
  final Future<void> Function() _onTick;
  final bool Function() _canTick;
  final void Function(Object, StackTrace) _onError;
  final Timer Function(Duration, void Function(Timer)) _schedulePeriodic;
  Timer? _timer;
  Future<void>? _inFlight;
  bool _closed = false;
  int _generation = 0;
  int ticksStarted = 0, ticksSkipped = 0;
  bool get isRunning => !_closed && _timer?.isActive == true;
  bool get hasInFlightTick => _inFlight != null;
  void start() {
    if (_closed || isRunning || !_canTick()) return;
    _timer = _schedulePeriodic(tickInterval, (_) => _pump());
  }

  void _pump() {
    if (_closed || !_canTick()) {
      stopNow();
      return;
    }
    if (_inFlight != null) {
      ticksSkipped++;
      return;
    }
    final generation = _generation;
    ticksStarted++;
    late Future<void> work;
    work = Future<void>.sync(_onTick)
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace trace) {
            if (!_closed && generation == _generation) {
              stopNow();
              _onError(error, trace);
            }
          },
        )
        .whenComplete(() {
          if (identical(_inFlight, work)) _inFlight = null;
        });
    _inFlight = work;
  }

  void stopNow() {
    _generation++;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    stopNow();
    await _inFlight;
  }
}
