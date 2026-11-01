import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/execution_handoff_startup_gate.dart';

void main() {
  test('ordinary startup proceeds without waiting for a handoff', () async {
    final state = ChangeNotifier();
    expect(
      await waitForExecutionHandoff(
        changes: state,
        isHandoffBusy: () => false,
        isAccountCurrent: () => true,
      ),
      isTrue,
    );
    state.dispose();
  });
  test('deferred startup stays silent until entry completes', () async {
    final busy = _ObservableValue(true);
    var started = false;
    final pending =
        waitForExecutionHandoff(
          changes: busy,
          isHandoffBusy: () => busy.value,
          isAccountCurrent: () => true,
        ).then((ready) {
          started = ready;
        });
    await Future<void>.delayed(Duration.zero);
    expect(started, isFalse);
    busy.value = false;
    await pending;
    expect(started, isTrue);
    expect(busy.hasActiveListeners, isFalse);
    busy.dispose();
  });
  test(
    'account retirement cancels deferred work and removes the listener',
    () async {
      final state = _ObservableValue(0);
      var current = true;
      var busy = true;
      final pending = waitForExecutionHandoff(
        changes: state,
        isHandoffBusy: () => busy,
        isAccountCurrent: () => current,
      );
      current = false;
      busy = false;
      state.value++;
      expect(await pending, isFalse);
      expect(state.hasActiveListeners, isFalse);
      state.dispose();
    },
  );
  test(
    'an invalid account never starts work even if the crossing is finished',
    () async {
      final state = ChangeNotifier();
      expect(
        await waitForExecutionHandoff(
          changes: state,
          isHandoffBusy: () => false,
          isAccountCurrent: () => throw StateError('retired'),
        ),
        isFalse,
      );
      state.dispose();
    },
  );
}

class _ObservableValue<T> extends ValueNotifier<T> {
  _ObservableValue(super.value);

  bool get hasActiveListeners => hasListeners;
}
