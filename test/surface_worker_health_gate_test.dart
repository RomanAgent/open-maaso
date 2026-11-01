import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';

void main() {
  test(
    'queues concurrent validation claims instead of superseding them',
    () async {
      final gate = SurfaceWorkerHealthGate();
      addTearDown(gate.onClose);
      gate.beginPresentation();

      var secondCanBegin = true;
      final second = gate.beginPresentationWhenAvailable(
        canBegin: () => secondCanBegin,
      );
      var secondCompleted = false;
      unawaited(second.then((_) => secondCompleted = true));
      await Future<void>.delayed(Duration.zero);
      expect(secondCompleted, isFalse);

      gate.cancelPresentation();
      expect(await second, isTrue);
      expect(gate.hasValidationClaim, isTrue);

      secondCanBegin = false;
      final cancelled = gate.beginPresentationWhenAvailable(
        canBegin: () => secondCanBegin,
      );
      gate.cancelPresentation();
      expect(await cancelled, isFalse);
      expect(gate.hasValidationClaim, isFalse);
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();

  late SurfaceWorkerHealthGate gate;

  setUp(() {
    gate = SurfaceWorkerHealthGate();
  });

  tearDown(() {
    gate.closeLifecycle();
  });

  test('ready resolves only the current worker session', () async {
    gate.beginPresentation();
    final waiting = gate.waitForFirstFrame(
      session: 7,
      document: '<html>worker</html>',
      timeout: const Duration(seconds: 1),
    );

    expect(gate.activeRequest.value?.session, 7);
    expect(
      gate.acceptLifecycleMessage(
        jsonEncode(const <String, Object?>{
          'version': 1,
          'session': 7,
          'status': 'ready',
          'reason': 'first_frame_ready',
        }),
        currentSession: 7,
      ),
      isTrue,
    );
    expect(gate.releaseValidationHost(7), isTrue);

    await waiting;
    expect(gate.activeRequest.value, isNull);
  });

  test(
    'accepted lifecycle freezes timeout until host cleanup releases',
    () async {
      gate.beginPresentation();
      final waiting = gate.waitForFirstFrame(
        session: 8,
        document: '<html>slow cleanup</html>',
        timeout: const Duration(milliseconds: 20),
      );

      expect(
        gate.acceptLifecycleMessage(
          '{"version":1,"session":8,"status":"ready",'
          '"reason":"first_frame_ready"}',
          currentSession: 8,
        ),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(gate.activeRequest.value?.session, 8);
      expect(gate.releaseValidationHost(8), isTrue);
      await waiting;
    },
  );

  test('stale lifecycle messages cannot resolve a newer session', () async {
    gate.beginPresentation();
    var resolved = false;
    final waiting = gate
        .waitForFirstFrame(
          session: 9,
          document: '<html>new worker</html>',
          timeout: const Duration(seconds: 1),
        )
        .then((_) => resolved = true);

    expect(
      gate.acceptLifecycleMessage(
        jsonEncode(const <String, Object?>{
          'version': 1,
          'session': 8,
          'status': 'ready',
          'reason': 'first_frame_ready',
        }),
        currentSession: 9,
      ),
      isFalse,
    );
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);

    expect(
      gate.acceptLifecycleMessage(
        jsonEncode(const <String, Object?>{
          'version': 1,
          'session': 9,
          'status': 'ready',
          'reason': 'first_frame_ready',
        }),
        currentSession: 9,
      ),
      isTrue,
    );
    expect(gate.releaseValidationHost(9), isTrue);
    await waiting;
    expect(resolved, isTrue);
  });

  test('fatal rejects with a fixed typed reason and no source text', () async {
    gate.beginPresentation();
    final waiting = gate.waitForFirstFrame(
      session: 11,
      document: '<script>SECRET_SOURCE</script>',
      timeout: const Duration(seconds: 1),
    );
    final assertion = expectLater(
      waiting,
      throwsA(
        isA<SurfaceWorkerFirstFrameException>()
            .having(
              (error) => error.reason,
              'reason',
              SurfaceWorkerFatalReason.invalidDrawCommands,
            )
            .having(
              (error) => error.toString(),
              'safe message',
              allOf(
                contains('invalid_draw_commands'),
                isNot(contains('SECRET')),
              ),
            ),
      ),
    );

    expect(
      gate.acceptLifecycleMessage(
        jsonEncode(const <String, Object?>{
          'version': 1,
          'session': 11,
          'status': 'fatal',
          'reason': 'invalid_draw_commands',
        }),
        currentSession: 11,
      ),
      isTrue,
    );
    expect(gate.releaseValidationHost(11), isTrue);
    await assertion;
    expect(gate.activeRequest.value, isNull);
  });

  test('missing attached validation view fails on a bounded timeout', () async {
    gate.beginPresentation();
    final stopwatch = Stopwatch()..start();

    await expectLater(
      gate.waitForFirstFrame(
        session: 13,
        document: '<html>no view</html>',
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(
        isA<SurfaceWorkerFirstFrameException>().having(
          (error) => error.kind,
          'kind',
          SurfaceWorkerFirstFrameFailureKind.timeout,
        ),
      ),
    );

    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 1)));
    expect(gate.activeRequest.value, isNull);
  });

  test('lifecycle parser rejects primitives, extra keys, and bad reasons', () {
    expect(SurfaceWorkerLifecycleMessage.tryParse('1'), isNull);
    expect(
      SurfaceWorkerLifecycleMessage.tryParse(
        '{"version":1,"session":1,"status":"ready",'
        '"reason":"first_frame_ready","extra":true}',
      ),
      isNull,
    );
    expect(
      SurfaceWorkerLifecycleMessage.tryParse(
        '{"version":1,"session":1,"status":"fatal",'
        '"reason":"raw generated source"}',
      ),
      isNull,
    );
  });

  test(
    'validation and visible rendering hold exactly one host claim',
    () async {
      final firstVisibleHost = Object();
      final secondVisibleHost = Object();
      gate.beginPresentation();

      expect(gate.claimVisibleHost(firstVisibleHost, 17), isFalse);
      final waiting = gate.waitForFirstFrame(
        session: 17,
        document: '<html>worker</html>',
        timeout: const Duration(seconds: 1),
      );
      expect(gate.claimVisibleHost(firstVisibleHost, 17), isFalse);
      expect(
        gate.acceptLifecycleMessage(
          '{"version":1,"session":17,"status":"ready",'
          '"reason":"first_frame_ready"}',
          currentSession: 17,
        ),
        isTrue,
      );
      expect(gate.releaseValidationHost(17), isTrue);
      await waiting;

      expect(gate.claimVisibleHost(firstVisibleHost, 17), isTrue);
      expect(gate.claimVisibleHost(secondVisibleHost, 17), isFalse);
      gate.releaseVisibleHost(firstVisibleHost);
      expect(gate.claimVisibleHost(secondVisibleHost, 17), isTrue);
    },
  );

  test('cancel before wait releases suppression for the prior session', () {
    final visibleHost = Object();
    expect(gate.claimVisibleHost(visibleHost, 23), isTrue);
    final revisionBeforeClaim = gate.visibleLeaseRevision.value;

    gate.beginPresentation();
    expect(gate.shouldSuppressVisibleSession(23), isTrue);
    gate.cancelPresentation();

    expect(
      gate.visibleLeaseRevision.value,
      greaterThan(revisionBeforeClaim + 1),
    );
    expect(gate.shouldSuppressVisibleSession(23), isFalse);
    expect(gate.claimVisibleHost(visibleHost, 23), isTrue);
  });
}
