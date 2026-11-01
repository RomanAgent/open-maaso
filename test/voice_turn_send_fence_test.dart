import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/voice_turn_send_fence.dart';

void main() {
  test(
    'priority signal has no idle gap between reservation and send',
    () async {
      final changes = <bool>[];
      final fence = VoiceTurnSendFence(onBusyChanged: changes.add);
      final reserved = fence.reserve()!;
      final completing = Completer<void>();
      final sending = fence.launch(reserved, () => completing.future)!;
      expect(changes, [true]);
      completing.complete();
      await sending;
      expect(changes, [true, false]);
      final cancelled = fence.reserve()!;
      fence.cancelReservation(cancelled);
      expect(changes, [true, false, true, false]);
    },
  );
  test('reservation blocks duplicate submission before launch', () {
    final fence = VoiceTurnSendFence();
    final first = fence.reserve();

    expect(first, isNotNull);
    expect(fence.isBusy, isTrue);
    expect(fence.reserve(), isNull);

    fence.cancelReservation(first!);
    expect(fence.isBusy, isFalse);
    expect(fence.reserve(), isNotNull);
  });

  test(
    'launch snapshots synchronously and stays busy through completion',
    () async {
      final fence = VoiceTurnSendFence();
      final reservation = fence.reserve()!;
      final done = Completer<void>();
      var invoked = false;

      final tracked = fence.launch(reservation, () {
        invoked = true;
        return done.future;
      });

      expect(invoked, isTrue);
      expect(tracked, isNotNull);
      expect(fence.isBusy, isTrue);
      expect(fence.reserve(), isNull);

      done.complete();
      await tracked;
      expect(fence.isBusy, isFalse);
    },
  );

  test('waitForActive observes the launched turn snapshot', () async {
    final fence = VoiceTurnSendFence();
    final done = Completer<void>();
    fence.launch(fence.reserve()!, () => done.future);

    var waited = false;
    final waiting = fence.waitForActive().then((_) => waited = true);
    await Future<void>.delayed(Duration.zero);
    expect(waited, isFalse);

    done.complete();
    await waiting;
    expect(waited, isTrue);
  });

  test(
    'async failure is consumed, reported once, and releases the fence',
    () async {
      final fence = VoiceTurnSendFence();
      final errors = <Object>[];
      final tracked = fence.launch(
        fence.reserve()!,
        () => Future<void>.error(StateError('turn failed')),
        onError: (error, _) => errors.add(error),
      );

      await tracked;
      expect(errors, hasLength(1));
      expect(errors.single, isA<StateError>());
      expect(fence.isBusy, isFalse);
    },
  );

  test('a stale reservation cannot launch or cancel the current one', () {
    final fence = VoiceTurnSendFence();
    final stale = fence.reserve()!;
    fence.cancelReservation(stale);
    final current = fence.reserve()!;

    expect(fence.launch(stale, () async {}), isNull);
    fence.cancelReservation(stale);
    expect(fence.owns(current), isTrue);
  });
}
