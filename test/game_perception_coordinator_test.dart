import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart';
import 'package:maaso/src/features/widgets_hub/application/game_frame_processor.dart';
import 'package:maaso/src/features/widgets_hub/application/game_perception_coordinator.dart';
import 'package:maaso/src/features/widgets_hub/data/game_perception_gateway.dart';

ProcessedGameFrame _frame(int value, {int bytes = 16}) => ProcessedGameFrame(
  jpegBytes: Uint8List(bytes),
  contentHash: 'frame-$value',
  width: 640,
  height: 320,
  fingerprint: Uint8List.fromList(List.filled(1024, value)),
);
void _flush(FakeAsync time) {
  time.flushMicrotasks();
  time.elapse(Duration.zero);
  time.flushMicrotasks();
}

void main() {
  test(
    'static sampling is independent of model calls and observations expire',
    () {
      fakeAsync((time) {
        final gateway = _FakeGateway();
        final seen = <GameVisualObservation>[];
        var captures = 0;
        final coordinator = GamePerceptionCoordinator(
          capture: () async {
            captures++;
            return Uint8List.fromList([20]);
          },
          gateway: gateway,
          isCurrent: () => true,
          onObservation: seen.add,
          question: () => '',
          locale: () => 'en',
          now: () => DateTime.utc(2026).add(time.elapsed),
          processor: (b) async => _frame(b[0]),
        );
        coordinator.start();
        _flush(time);
        expect(gateway.calls, hasLength(1));
        gateway.calls.single.succeed();
        _flush(time);
        expect(coordinator.latest, isNotNull);
        expect(seen, hasLength(1));
        time.elapse(const Duration(seconds: 20));
        _flush(time);
        expect(captures, greaterThan(2));
        expect(gateway.calls, hasLength(1));
        expect(seen, hasLength(1));
        expect(coordinator.latest, isNull);
        coordinator.close();
        _flush(time);
      });
    },
  );
  test(
    'one physical request and latest pending frame; older image stays historical',
    () {
      fakeAsync((time) {
        final gateway = _FakeGateway();
        final seen = <GameVisualObservation>[];
        var value = 0;
        final coordinator = GamePerceptionCoordinator(
          capture: () async => Uint8List.fromList([value]),
          gateway: gateway,
          isCurrent: () => true,
          onObservation: seen.add,
          question: () => '',
          locale: () => 'en',
          now: () => DateTime.utc(2026).add(time.elapsed),
          processor: (b) async => _frame(b[0]),
        );
        coordinator.start();
        _flush(time);
        final first = gateway.calls.single;
        value = 100;
        time.elapse(const Duration(seconds: 2));
        _flush(time);
        value = 200;
        time.elapse(const Duration(seconds: 2));
        _flush(time);
        expect(gateway.calls, hasLength(1));
        first.succeed();
        _flush(time);
        expect(seen.single.isCurrentFrame, isFalse);
        expect(coordinator.latest, isNull);
        expect(gateway.calls, hasLength(2));
        expect(gateway.calls.last.frame.contentHash, 'frame-200');
        gateway.calls.last.succeed();
        _flush(time);
        expect(coordinator.latest!.sourceMediaId, 'frame-200');
        expect(
          coordinator.latest!.capturedAt,
          DateTime.utc(2026).add(const Duration(seconds: 4)),
        );
        coordinator.close();
        _flush(time);
      });
    },
  );
  test(
    'round invalidation cancels but waits for drain and rejects late results',
    () {
      fakeAsync((time) {
        final gateway = _FakeGateway();
        final seen = <GameVisualObservation>[];
        final coordinator = GamePerceptionCoordinator(
          capture: () async => Uint8List.fromList([100]),
          gateway: gateway,
          isCurrent: () => true,
          onObservation: seen.add,
          question: () => '',
          locale: () => 'en',
          now: () => DateTime.utc(2026).add(time.elapsed),
          processor: (b) async => _frame(b[0]),
          minimumDispatchInterval: Duration.zero,
        );
        coordinator.start();
        _flush(time);
        final old = gateway.calls.single;
        coordinator.invalidateRound();
        _flush(time);
        expect(old.cancelled, isTrue);
        expect(gateway.calls, hasLength(1));
        old.succeed();
        _flush(time);
        expect(seen, isEmpty);
        expect(gateway.calls, hasLength(2));
        var closed = false;
        coordinator.close().then((_) => closed = true);
        _flush(time);
        expect(gateway.calls.last.cancelled, isTrue);
        expect(closed, isFalse);
        gateway.calls.last.fail('GAME_PERCEPTION_CANCELLED');
        _flush(time);
        expect(closed, isTrue);
        expect(coordinator.status, GamePerceptionStatus.stopped);
        expect(seen, isEmpty);
      });
    },
  );
  test(
    'membership denial and unsupported capture stop work; busy is temporary',
    () {
      fakeAsync((time) {
        final gateway = _FakeGateway();
        var captures = 0;
        final coordinator = GamePerceptionCoordinator(
          capture: () async {
            captures++;
            return Uint8List.fromList([100]);
          },
          gateway: gateway,
          isCurrent: () => true,
          onObservation: (_) {},
          question: () => '',
          locale: () => 'en',
          now: () => DateTime.utc(2026).add(time.elapsed),
          processor: (b) async => _frame(b[0]),
        );
        coordinator.start();
        _flush(time);
        gateway.calls.single.fail(
          'GAME_PERCEPTION_BUSY',
          retry: const Duration(seconds: 10),
        );
        _flush(time);
        time.elapse(const Duration(seconds: 9));
        _flush(time);
        expect(gateway.calls, hasLength(1));
        time.elapse(const Duration(seconds: 1));
        _flush(time);
        expect(gateway.calls, hasLength(2));
        gateway.calls.last.fail('GAME_PERCEPTION_MEMBERSHIP_REQUIRED');
        _flush(time);
        expect(coordinator.status, GamePerceptionStatus.membershipRequired);
        final before = captures;
        time.elapse(const Duration(minutes: 2));
        _flush(time);
        expect(captures, before);
        coordinator.close();
        _flush(time);
        final unsupported = GamePerceptionCoordinator(
          capture: () async {
            fail('unsupported source captured');
          },
          gateway: gateway,
          isCurrent: () => true,
          onObservation: (_) {},
          question: () => '',
          locale: () => 'en',
          isCaptureSupported: () => false,
        );
        unsupported.start();
        _flush(time);
        expect(unsupported.status, GamePerceptionStatus.unsupported);
        unsupported.close();
        _flush(time);
      });
    },
  );
  test(
    'question wait is bounded, user input can request a frame while yielding',
    () {
      fakeAsync((time) {
        final gateway = _FakeGateway();
        final coordinator = GamePerceptionCoordinator(
          capture: () async => Uint8List.fromList([100]),
          gateway: gateway,
          isCurrent: () => true,
          onObservation: (_) {},
          question: () => 'What is this?',
          locale: () => 'en',
          shouldYield: () => true,
          now: () => DateTime.utc(2026).add(time.elapsed),
          processor: (b) async => _frame(b[0]),
        );
        coordinator.start();
        _flush(time);
        expect(gateway.calls, isEmpty);
        GameVisualObservation? reply;
        var completed = false;
        coordinator
            .refreshForUserQuestion(waitBudget: const Duration(seconds: 1))
            .then((v) {
              reply = v;
              completed = true;
            });
        _flush(time);
        expect(gateway.calls, hasLength(1));
        time.elapse(const Duration(seconds: 1));
        _flush(time);
        expect(completed, isTrue);
        expect(reply, isNull);
        gateway.calls.single.succeed();
        _flush(time);
        expect(coordinator.latest, isNotNull);
        coordinator.close();
        _flush(time);
      });
    },
  );

  for (final denial in {
    'GAME_PERCEPTION_MEMBERSHIP_REQUIRED':
        GamePerceptionStatus.membershipRequired,
    'GAME_PERCEPTION_PREMIUM_REQUIRED': GamePerceptionStatus.premiumRequired,
  }.entries) {
    test(
      '${denial.key} halts uploads until an explicit new session revalidates access',
      () {
        fakeAsync((time) {
          final gateway = _FakeGateway();
          var captures = 0;
          final observations = <GameVisualObservation>[];
          GamePerceptionCoordinator create() => GamePerceptionCoordinator(
            capture: () async {
              captures++;
              return Uint8List.fromList([100]);
            },
            gateway: gateway,
            isCurrent: () => true,
            onObservation: observations.add,
            question: () => '',
            locale: () => 'en',
            now: () => DateTime.utc(2026).add(time.elapsed),
            processor: (bytes) async => _frame(bytes[0]),
          );
          final first = create()..start();
          _flush(time);
          gateway.calls.single.fail(denial.key);
          _flush(time);
          expect(first.status, denial.value);
          expect(first.latest, isNull);
          var questionFinished = false;
          first.refreshForUserQuestion().then((value) {
            expect(value, isNull);
            questionFinished = true;
          });
          _flush(time);
          expect(questionFinished, isTrue);
          final before = captures;
          time.elapse(const Duration(minutes: 2));
          _flush(time);
          expect(captures, before);
          expect(gateway.calls, hasLength(1));
          expect(observations, isEmpty);
          first.close();
          _flush(time);

          // The client does not infer a tier or cache a permanent denial. A new
          // user-enabled session obtains a new authoritative server outcome.
          final reopened = create()..start();
          _flush(time);
          expect(gateway.calls, hasLength(2));
          gateway.calls.last.succeed();
          _flush(time);
          expect(reopened.status, GamePerceptionStatus.observing);
          expect(reopened.latest, isNotNull);
          expect(observations, hasLength(1));
          reopened.close();
          _flush(time);
        });
      },
    );
  }
  test(
    'human priority keeps local sampling and cancels only background HTTP',
    () {
      fakeAsync((time) {
        final gateway = _FakeGateway();
        final priority = ValueNotifier(false);
        var value = 0, changes = 0;
        final coordinator = GamePerceptionCoordinator(
          capture: () async => Uint8List.fromList([value]),
          gateway: gateway,
          isCurrent: () => true,
          onObservation: (_) {},
          question: () => '',
          locale: () => 'en',
          shouldYield: () => priority.value,
          priorityChanges: priority,
          onFrameChanged: () => changes++,
          now: () => DateTime.utc(2026).add(time.elapsed),
          processor: (b) async => _frame(b[0]),
          minimumDispatchInterval: Duration.zero,
        );
        coordinator.start();
        _flush(time);
        final background = gateway.calls.single;
        priority.value = true;
        _flush(time);
        expect(background.cancelled, isTrue);
        value = 200;
        time.elapse(const Duration(seconds: 2));
        _flush(time);
        expect(changes, 1);
        expect(gateway.calls, hasLength(1));
        coordinator.refreshForUserQuestion();
        _flush(time);
        expect(gateway.calls, hasLength(1));
        background.fail('GAME_PERCEPTION_CANCELLED');
        _flush(time);
        expect(gateway.calls, hasLength(2));
        final manual = gateway.calls.last;
        priority.value = false;
        priority.value = true;
        _flush(time);
        expect(manual.cancelled, isFalse);
        value = 100;
        time.elapse(const Duration(seconds: 5));
        _flush(time);
        expect(changes, 2);
        expect(gateway.calls, hasLength(2));
        manual.succeed();
        _flush(time);
        coordinator.close();
        _flush(time);
        priority.dispose();
      });
    },
  );
  test('a question rechecks the screen before reusing a fresh observation', () {
    fakeAsync((time) {
      final gateway = _FakeGateway();
      final seen = <GameVisualObservation>[];
      var value = 0, captures = 0;
      final coordinator = GamePerceptionCoordinator(
        capture: () async {
          captures++;
          return Uint8List.fromList([value]);
        },
        gateway: gateway,
        isCurrent: () => true,
        onObservation: seen.add,
        question: () => '',
        locale: () => 'en',
        now: () => DateTime.utc(2026).add(time.elapsed),
        processor: (b) async => _frame(b[0]),
      );
      coordinator.start();
      _flush(time);
      gateway.calls.single.succeed();
      _flush(time);
      final original = coordinator.latest;
      time.elapse(const Duration(seconds: 1));
      GameVisualObservation? cached;
      coordinator.refreshForUserQuestion().then((value) => cached = value);
      _flush(time);
      expect(captures, 2);
      expect(identical(cached, original), isTrue);
      expect(gateway.calls, hasLength(1));
      expect(seen, hasLength(1));
      value = 200;
      time.elapse(const Duration(seconds: 1));
      GameVisualObservation? fresh;
      var completed = false;
      coordinator.refreshForUserQuestion().then((value) {
        completed = true;
        fresh = value;
      });
      _flush(time);
      expect(captures, 3);
      expect(completed, isFalse);
      expect(coordinator.latest, isNull);
      time.elapse(const Duration(seconds: 1));
      _flush(time);
      expect(gateway.calls, hasLength(2));
      gateway.calls.last.succeed();
      _flush(time);
      expect(fresh!.sourceMediaId, 'frame-200');
      expect(
        fresh!.capturedAt,
        DateTime.utc(2026).add(const Duration(seconds: 2)),
      );
      coordinator.close();
      _flush(time);
    });
  });
  test('snapshot encoding latency does not make an image appear newer', () {
    fakeAsync((time) {
      final capture = Completer<Uint8List?>();
      final gateway = _FakeGateway();
      final coordinator = GamePerceptionCoordinator(
        capture: () => capture.future,
        gateway: gateway,
        isCurrent: () => true,
        onObservation: (_) {},
        question: () => '',
        locale: () => 'en',
        now: () => DateTime.utc(2026).add(time.elapsed),
        processor: (b) async => _frame(b[0]),
      );
      coordinator.start();
      _flush(time);
      time.elapse(const Duration(seconds: 2));
      capture.complete(Uint8List.fromList([100]));
      _flush(time);
      gateway.calls.single.succeed();
      _flush(time);
      expect(coordinator.latest!.capturedAt, DateTime.utc(2026));
      expect(
        coordinator.latest!.analyzedAt,
        DateTime.utc(2026).add(const Duration(seconds: 2)),
      );
      coordinator.close();
      _flush(time);
    });
  });
  test('late capture after close never reaches the processor or network', () {
    fakeAsync((time) {
      final capture = Completer<Uint8List?>();
      final gateway = _FakeGateway();
      final coordinator = GamePerceptionCoordinator(
        capture: () => capture.future,
        gateway: gateway,
        isCurrent: () => true,
        onObservation: (_) {
          fail('closed observation');
        },
        question: () => '',
        locale: () => 'en',
        processor: (_) async {
          fail('closed pixels processed');
        },
      );
      coordinator.start();
      _flush(time);
      var closed = false;
      coordinator.close().then((_) => closed = true);
      _flush(time);
      expect(closed, isFalse);
      capture.complete(Uint8List.fromList([1]));
      _flush(time);
      expect(closed, isTrue);
      expect(gateway.calls, isEmpty);
    });
  });
}

class _FakeGateway extends GamePerceptionGateway {
  _FakeGateway()
    : super(
        baseUri: Uri.parse('https://synthetic.invalid/'),
        accessToken: () async => 'synthetic',
        authorize: () async {},
        isCurrent: () => true,
      );
  final calls = <_Call>[];
  @override
  Future<GamePerceptionResult> analyze({
    required ProcessedGameFrame frame,
    required String question,
    required String locale,
    required Future<void> cancelled,
    required bool Function() requestIsCurrent,
    Duration deadline = const Duration(seconds: 8),
  }) {
    final call = _Call(frame);
    calls.add(call);
    cancelled.then((_) => call.cancelled = true);
    return call.result.future;
  }
}

class _Call {
  _Call(this.frame);
  final ProcessedGameFrame frame;
  final result = Completer<GamePerceptionResult>();
  bool cancelled = false;
  void succeed() => result.complete(
    GamePerceptionResult(
      description: 'Visible frame ${frame.contentHash}',
      modelId: 'vision',
      sourceMediaId: frame.contentHash,
    ),
  );
  void fail(String code, {Duration? retry}) =>
      result.completeError(GamePerceptionException(code, retryAfter: retry));
}
