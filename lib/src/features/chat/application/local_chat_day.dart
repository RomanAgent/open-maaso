import 'dart:async';

import 'package:flutter/widgets.dart';

/// The device's local calendar day, represented by an inclusive/exclusive
/// instant range. Calendar construction also handles 23/25-hour DST days.
@immutable
class LocalChatDay {
  LocalChatDay.at(DateTime instant) : this._fromLocal(instant.toLocal());

  LocalChatDay._fromLocal(DateTime local)
    : start = DateTime(local.year, local.month, local.day),
      end = DateTime(local.year, local.month, local.day + 1);

  final DateTime start;
  final DateTime end;

  bool contains(DateTime timestamp) =>
      !timestamp.isBefore(start) && timestamp.isBefore(end);

  @override
  bool operator ==(Object other) =>
      other is LocalChatDay && start == other.start && end == other.end;

  @override
  int get hashCode => Object.hash(start, end);
}

/// Refreshes local-day UI at midnight and on resume, without touching history.
/// The bounded foreground check also notices a device clock/time-zone change.
class LocalChatDayClock extends ChangeNotifier with WidgetsBindingObserver {
  LocalChatDayClock({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now {
    _day = LocalChatDay.at(now);
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  final DateTime Function() _clock;
  late LocalChatDay _day;
  Timer? _timer;
  bool _disposed = false;
  bool _paused = false;

  DateTime get now => _clock();
  LocalChatDay get day => _day;

  void refresh({bool force = false}) {
    if (_disposed) return;
    final current = LocalChatDay.at(now);
    final changed = current != _day;
    _day = current;
    if (changed || force) notifyListeners();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || _paused) return;
    final remaining = _day.end.difference(now);
    final delay = remaining <= Duration.zero
        ? const Duration(milliseconds: 1)
        : remaining < const Duration(minutes: 1)
        ? remaining
        : const Duration(minutes: 1);
    _timer = Timer(delay, refresh);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _paused = state != AppLifecycleState.resumed;
    if (_paused) {
      _timer?.cancel();
    } else {
      refresh(force: true);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
