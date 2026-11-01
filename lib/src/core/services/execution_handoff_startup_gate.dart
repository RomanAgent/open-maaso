import 'dart:async';

import 'package:flutter/foundation.dart';

/// Waits outside the account's operation queue, so teardown never waits on
/// its own deferred startup. Losing the account wins over becoming visible.
Future<bool> waitForExecutionHandoff({
  required Listenable changes,
  required bool Function() isHandoffBusy,
  required bool Function() isAccountCurrent,
}) {
  bool current() {
    try {
      return isAccountCurrent();
    } catch (_) {
      return false;
    }
  }

  if (!current()) return Future<bool>.value(false);
  if (!isHandoffBusy()) return Future<bool>.value(true);
  final result = Completer<bool>();
  void changed() {
    if (result.isCompleted) return;
    if (!current()) {
      result.complete(false);
    } else if (!isHandoffBusy()) {
      result.complete(true);
    }
  }

  changes.addListener(changed);
  changed();
  return result.future.whenComplete(() => changes.removeListener(changed));
}
