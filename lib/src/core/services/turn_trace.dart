import 'dart:async';

import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// Lightweight per-user-turn trace logger.
///
/// Phase 0 is observability only: keep the runtime behavior unchanged, but
/// stamp each hot-path event with a trace id and elapsed time so the console
/// tells one coherent story from user send to voice/avatar completion.
class TurnTrace {
  TurnTrace._(this.id, this.label) : startedAt = DateTime.now();

  final String id;
  final String label;
  final DateTime startedAt;

  static final Object _zoneKey = Object();
  static int _seq = 0;
  static TurnTrace? _lastActive;

  static TurnTrace? get current => Zone.current[_zoneKey] as TurnTrace?;

  /// Best-effort id for callbacks that arrive outside the original async zone
  /// (EventBus, TTS handlers, audio completion timers).
  static String get currentId => (current ?? _lastActive)?.id ?? 'no-trace';

  static Future<T> run<T>(String label, Future<T> Function() action) async {
    final trace = _start(label);
    return runZoned<Future<T>>(() async {
      try {
        final result = await action();
        trace._log('trace.end', details: 'status=ok');
        return result;
      } catch (e) {
        trace._log('trace.end', details: 'status=error error=$e');
        rethrow;
      }
    }, zoneValues: {_zoneKey: trace});
  }

  static void event(String name, {String? details}) {
    final trace = current ?? _lastActive ?? _start('orphan');
    trace._log(name, details: details);
  }

  static Stopwatch stopwatch(String name, {String? details}) {
    event('$name.start', details: details);
    return Stopwatch()..start();
  }

  static void done(String name, Stopwatch stopwatch, {String? details}) {
    stopwatch.stop();
    final suffix = details == null || details.isEmpty
        ? 'ms=${stopwatch.elapsedMilliseconds}'
        : 'ms=${stopwatch.elapsedMilliseconds} $details';
    event('$name.done', details: suffix);
  }

  static TurnTrace _start(String label) {
    final now = DateTime.now();
    final seq = _seq++;
    final id = '${now.millisecondsSinceEpoch.toRadixString(36)}-$seq';
    final trace = TurnTrace._(id, label);
    _lastActive = trace;
    trace._log('trace.start', details: 'label=$label');
    return trace;
  }

  void _log(String name, {String? details}) {
    _lastActive = this;
    final elapsedMs = DateTime.now().difference(startedAt).inMilliseconds;
    final tail = details == null || details.isEmpty ? '' : ' $details';
    Log.i('⏱️ [Trace/$id] +${elapsedMs}ms $name$tail');
  }
}
