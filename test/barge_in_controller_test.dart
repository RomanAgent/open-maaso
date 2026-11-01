import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/barge_in_controller.dart';
import 'package:maaso/src/features/agent/application/speech/speech_playback_lease.dart';

import '../tool/conversation_acceptance_report.dart';

void main() {
  late List<String> calls;
  late List<BargeInDiagnosticEvent> diagnostics;
  late _PlaybackHarness output;
  late BargeInController controller;

  BargeInController create({
    bool enabled = true,
    Duration pauseTimeout = const Duration(seconds: 2),
    Duration controlTimeout = const Duration(seconds: 2),
    Duration candidateTimeout = const Duration(seconds: 8),
    Duration recognitionPendingTimeout = const Duration(seconds: 3),
    Duration recognizingTimeout = const Duration(seconds: 15),
    BargeInDiagnosticObserver? diagnosticObserver,
  }) => BargeInController(
    enabled: () => enabled,
    capturePlayback: output.capture,
    pauseTimeout: pauseTimeout,
    controlTimeout: controlTimeout,
    candidateTimeout: candidateTimeout,
    recognitionPendingTimeout: recognitionPendingTimeout,
    recognizingTimeout: recognizingTimeout,
    diagnosticObserver: diagnosticObserver ?? diagnostics.add,
  );

  setUp(() {
    calls = <String>[];
    diagnostics = <BargeInDiagnosticEvent>[];
    output = _PlaybackHarness(calls);
    controller = create();
  });

  tearDown(() => controller.onClose());

  test('begin captures and pauses the exact current output', () async {
    final lease = await controller.beginCandidate(agentId: 'agent-a');

    expect(lease, isNotNull);
    expect(lease!.agentId, 'agent-a');
    expect(lease.playbackGeneration, output.current.generation);
    expect(lease.turnId, output.current.turnId);
    expect(lease.utteranceId, output.current.utteranceId);
    expect(controller.active.value, isTrue);
    expect(controller.phase, BargeInPhase.candidate);
    expect(controller.currentLease, same(lease));
    expect(output.current.paused, isTrue);
    expect(calls, ['pause:output-1']);
  });

  test(
    'pause error after a native side effect still stops exact output',
    () async {
      final failure = StateError('pause reply failed');
      output.current.pauseError = failure;
      output.current.pauseSideEffectBeforeError = true;

      await expectLater(
        controller.beginCandidate(agentId: 'agent-a'),
        throwsA(same(failure)),
      );
      await _until(() => output.current.stopped);

      expect(output.current.paused, isFalse);
      expect(calls, ['pause:output-1', 'stop:output-1:barge_in_pause_failed']);
      expect(calls.where((call) => call.startsWith('resume:')), isEmpty);
      expect(
        diagnostics.map((event) => event.kind),
        contains(BargeInDiagnosticKind.controlFailed),
      );
    },
  );

  test('begin is inert when disabled or no identified output exists', () async {
    controller = create(enabled: false);
    expect(await controller.beginCandidate(agentId: 'agent-a'), isNull);
    expect(calls, isEmpty);

    controller.onClose();
    output.current.current = false;
    controller = create();
    expect(await controller.beginCandidate(agentId: 'agent-a'), isNull);
    expect(controller.active.value, isFalse);
    expect(calls, isEmpty);
  });

  test('begin twice reuses the candidate without pausing twice', () async {
    final first = await controller.beginCandidate();
    final second = await controller.beginCandidate();

    expect(second, same(first));
    expect(calls, ['pause:output-1']);
  });

  test(
    'legacy begin and resolve entry points retain exact lease control',
    () async {
      await controller.begin(agentId: 'agent-a');

      expect(await controller.resolve('嗯'), BargeInOutcome.resumed);
      expect(calls, ['pause:output-1', 'resume:output-1']);
    },
  );

  test('empty input resumes the captured output', () async {
    final lease = (await controller.beginCandidate())!;
    final outcome = await controller.resolveCandidate(lease, '   ');

    expect(outcome, BargeInOutcome.resumed);
    expect(output.current.paused, isFalse);
    expect(output.current.stopped, isFalse);
    expect(controller.phase, BargeInPhase.idle);
    expect(calls, ['pause:output-1', 'resume:output-1']);
  });

  test('backchannel resumes the captured output', () async {
    final lease = (await controller.beginCandidate())!;
    final outcome = await controller.resolveCandidate(lease, '嗯嗯');

    expect(outcome, BargeInOutcome.resumed);
    expect(calls, ['pause:output-1', 'resume:output-1']);
  });

  test('likely self echo resumes instead of interrupting', () async {
    output.current.spokenText = '今天呀，嗯，我想想。猪脚饭？';
    final lease = (await controller.beginCandidate())!;
    final outcome = await controller.resolveCandidate(lease, '嗯，我想想，猪脚饭？');

    expect(outcome, BargeInOutcome.resumed);
    expect(calls, ['pause:output-1', 'resume:output-1']);
  });

  test('semantic speech stops only the captured output', () async {
    final lease = (await controller.beginCandidate())!;
    final outcome = await controller.resolveCandidate(lease, '等等，换个话题');

    expect(outcome, BargeInOutcome.interrupted);
    expect(output.current.stopped, isTrue);
    expect(output.current.paused, isFalse);
    expect(calls, ['pause:output-1', 'stop:output-1:semantic_barge_in']);
  });

  test('candidate diagnostics measure audible pause before ASR', () async {
    final pauseGate = Completer<void>();
    output.current.pauseGate = pauseGate;
    final beginning = controller.beginCandidate(agentId: 'agent-a');
    await _until(
      () => diagnostics.any(
        (event) => event.kind == BargeInDiagnosticKind.candidateCaptured,
      ),
    );
    expect(
      diagnostics.map((event) => event.kind),
      isNot(contains(BargeInDiagnosticKind.outputPaused)),
    );

    pauseGate.complete();
    final lease = (await beginning)!;
    expect(diagnostics.take(2).map((event) => event.kind), [
      BargeInDiagnosticKind.candidateCaptured,
      BargeInDiagnosticKind.outputPaused,
    ]);

    final stopGate = Completer<void>();
    output.current.stopGate = stopGate;
    expect(controller.markRecognitionPending(lease), isTrue);
    expect(controller.markRecognizing(lease), isTrue);

    final resolving = controller.resolveCandidate(
      lease,
      'private-semantic-transcript',
      agentId: 'agent-a',
    );
    await _until(
      () => diagnostics.any(
        (event) => event.kind == BargeInDiagnosticKind.semanticTakeover,
      ),
    );
    expect(
      diagnostics.map((event) => event.kind),
      isNot(contains(BargeInDiagnosticKind.outputRetired)),
    );

    stopGate.complete();
    expect(await resolving, BargeInOutcome.interrupted);
    expect(diagnostics.map((event) => event.kind), <BargeInDiagnosticKind>[
      BargeInDiagnosticKind.candidateCaptured,
      BargeInDiagnosticKind.outputPaused,
      BargeInDiagnosticKind.recognitionPending,
      BargeInDiagnosticKind.recognitionStarted,
      BargeInDiagnosticKind.semanticTakeover,
      BargeInDiagnosticKind.outputRetired,
    ]);
  });

  test(
    'resume diagnostics distinguish empty, self echo, and backchannel',
    () async {
      Future<List<BargeInDiagnosticKind>> resolve({
        required String spokenText,
        required String transcript,
      }) async {
        controller.onClose();
        diagnostics = <BargeInDiagnosticEvent>[];
        output = _PlaybackHarness(calls = <String>[]);
        output.current.spokenText = spokenText;
        controller = create();
        final lease = (await controller.beginCandidate())!;
        expect(
          await controller.resolveCandidate(lease, transcript),
          BargeInOutcome.resumed,
        );
        return diagnostics.map((event) => event.kind).toList();
      }

      expect(
        await resolve(spokenText: 'anything', transcript: '   '),
        <BargeInDiagnosticKind>[
          BargeInDiagnosticKind.candidateCaptured,
          BargeInDiagnosticKind.outputPaused,
          BargeInDiagnosticKind.resumeEmpty,
          BargeInDiagnosticKind.outputResumed,
        ],
      );
      expect(
        await resolve(
          spokenText: 'private spoken self echo marker',
          transcript: 'spoken self echo marker',
        ),
        <BargeInDiagnosticKind>[
          BargeInDiagnosticKind.candidateCaptured,
          BargeInDiagnosticKind.outputPaused,
          BargeInDiagnosticKind.resumeSelfEcho,
          BargeInDiagnosticKind.outputResumed,
        ],
      );
      expect(
        await resolve(spokenText: 'anything', transcript: '嗯'),
        <BargeInDiagnosticKind>[
          BargeInDiagnosticKind.candidateCaptured,
          BargeInDiagnosticKind.outputPaused,
          BargeInDiagnosticKind.resumeBackchannel,
          BargeInDiagnosticKind.outputResumed,
        ],
      );
      expect(
        diagnostics.map((event) => event.kind),
        isNot(contains(BargeInDiagnosticKind.semanticTakeover)),
      );
    },
  );

  test(
    'diagnostics are fixed-schema, bounded, and redact conversation data',
    () async {
      const spokenMarker = 'private-spoken-marker';
      const transcriptMarker = 'private-transcript-marker';
      output.current.spokenText = spokenMarker;
      final lease = (await controller.beginCandidate(agentId: 'agent-a'))!;

      expect(
        await controller.resolveCandidate(
          lease,
          transcriptMarker,
          agentId: 'agent-a',
        ),
        BargeInOutcome.interrupted,
      );

      final encoded = jsonEncode(
        diagnostics.map((event) => event.toJson()).toList(growable: false),
      );
      for (final privateValue in <String>[
        spokenMarker,
        transcriptMarker,
        'agent-a',
        'output-1',
        'turn-100',
      ]) {
        expect(encoded, isNot(contains(privateValue)));
      }
      for (final event in diagnostics) {
        expect(event.toJson().keys, <String>{
          'schemaVersion',
          'event',
          'phase',
          'candidate',
          'ms',
        });
        expect(event.candidateSequence, greaterThan(0));
        expect(event.elapsedMilliseconds, inInclusiveRange(0, 60000));
      }
      expect(
        BargeInDiagnosticKind.candidateCaptured.traceName,
        'interrupt.received',
      );
      expect(BargeInDiagnosticKind.outputPaused.traceName, 'output.stopped');

      final report = buildConversationAcceptanceReport([
        jsonEncode(
          diagnostics.map((event) => event.toJson()).toList(growable: false),
        ),
      ]);
      final metrics = Map<String, Object?>.from(report['metrics']! as Map);
      final stopLatency = Map<String, Object?>.from(
        metrics['stopLatencyMs']! as Map,
      );
      final captured = diagnostics.firstWhere(
        (event) => event.kind == BargeInDiagnosticKind.candidateCaptured,
      );
      final paused = diagnostics.firstWhere(
        (event) => event.kind == BargeInDiagnosticKind.outputPaused,
      );
      expect(stopLatency['status'], 'available');
      expect(
        stopLatency['p50'],
        paused.elapsedMilliseconds - captured.elapsedMilliseconds,
      );
    },
  );

  test('observer failures cannot change production control outcomes', () async {
    controller.onClose();
    controller = create(
      diagnosticObserver: (_) => throw StateError('private-observer-error'),
    );

    final lease = (await controller.beginCandidate())!;
    expect(
      await controller.resolveCandidate(lease, 'semantic interruption'),
      BargeInOutcome.interrupted,
    );
    expect(output.current.stopped, isTrue);
  });

  test('resolve without a candidate is inert', () async {
    expect(await controller.resolve('anything'), BargeInOutcome.none);
    expect(calls, isEmpty);
  });

  test('pause failure rolls back to idle', () async {
    final failure = StateError('pause failed');
    output.current.pauseError = failure;

    await expectLater(
      controller.beginCandidate(agentId: 'agent-a'),
      throwsA(same(failure)),
    );

    expect(controller.active.value, isFalse);
    expect(controller.phase, BargeInPhase.idle);
    expect(controller.currentLease, isNull);
    await _until(() => output.current.stopped);
    expect(calls, ['pause:output-1', 'stop:output-1:barge_in_pause_failed']);
  });

  test('pause deadline retires the exact output without hanging', () async {
    controller = create(pauseTimeout: const Duration(milliseconds: 10));
    final gate = Completer<void>();
    final captured = output.current;
    captured.pauseGate = gate;

    final beginning = controller.beginCandidate();
    await _until(() => calls.contains('pause:output-1'));

    expect(await beginning, isNull);
    await _until(() => captured.stopped);
    expect(controller.active.value, isFalse);
    expect(controller.phase, BargeInPhase.idle);
    expect(controller.currentLease, isNull);
    expect(calls, ['pause:output-1', 'stop:output-1:barge_in_recovery']);

    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(captured.paused, isFalse);
  });

  test('close does not wait forever for an in-flight pause', () async {
    controller = create(pauseTimeout: const Duration(seconds: 1));
    final gate = Completer<void>();
    final captured = output.current;
    captured.pauseGate = gate;
    final beginning = controller.beginCandidate();
    await _until(() => calls.contains('pause:output-1'));

    controller.onClose();

    expect(controller.active.value, isFalse);
    expect(controller.phase, BargeInPhase.idle);
    expect(await beginning, isNull);
    await _until(() => captured.stopped);
    expect(calls, ['pause:output-1', 'stop:output-1:barge_in_recovery']);
  });

  test('ambiguous pause cleanup never resumes after stop failure', () async {
    controller = create(pauseTimeout: const Duration(milliseconds: 10));
    final gate = Completer<void>();
    output.current.pauseGate = gate;
    output.current.stopError = StateError('stop failed');

    expect(await controller.beginCandidate(), isNull);
    await _until(() => calls.length == 2);

    expect(calls, ['pause:output-1', 'stop:output-1:barge_in_recovery']);
    expect(calls.where((call) => call.startsWith('resume:')), isEmpty);
  });

  test(
    'output replacement during pause cannot create a stale candidate',
    () async {
      final gate = Completer<void>();
      output.current.pauseGate = gate;
      final beginning = controller.beginCandidate();
      await _until(() => calls.isNotEmpty);

      output.replace();
      gate.complete();

      expect(await beginning, isNull);
      expect(controller.active.value, isFalse);
      expect(controller.currentLease, isNull);
      expect(output.current.paused, isFalse);
    },
  );

  test('candidate timeout resumes and retires its lease', () async {
    controller = create(candidateTimeout: const Duration(milliseconds: 10));
    final lease = (await controller.beginCandidate())!;

    await _until(() => controller.phase == BargeInPhase.idle);

    expect(calls, ['pause:output-1', 'resume:output-1']);
    expect(controller.active.value, isFalse);
    expect(controller.phase, BargeInPhase.idle);
    expect(
      diagnostics.map((event) => event.kind),
      containsAllInOrder(<BargeInDiagnosticKind>[
        BargeInDiagnosticKind.deadlineExceeded,
        BargeInDiagnosticKind.resumeRecovery,
        BargeInDiagnosticKind.outputResumed,
      ]),
    );
    final diagnosticCount = diagnostics.length;
    expect(
      await controller.resolveCandidate(lease, '迟到的识别结果'),
      BargeInOutcome.none,
    );
    expect(diagnostics, hasLength(diagnosticCount));
  });

  test('recognition pending has its own recovery timeout', () async {
    controller = create(
      candidateTimeout: const Duration(seconds: 1),
      recognitionPendingTimeout: const Duration(milliseconds: 10),
    );
    final lease = (await controller.beginCandidate())!;

    expect(controller.markRecognitionPending(lease), isTrue);
    expect(controller.phase, BargeInPhase.recognitionPending);
    await _until(() => controller.phase == BargeInPhase.idle);

    expect(controller.phase, BargeInPhase.idle);
    expect(output.current.paused, isFalse);
  });

  test('recognition failure explicitly recovers the captured output', () async {
    final lease = (await controller.beginCandidate())!;
    expect(controller.markRecognitionPending(lease), isTrue);

    expect(await controller.recoverCandidate(lease), BargeInOutcome.resumed);
    expect(controller.phase, BargeInPhase.idle);
    expect(output.current.paused, isFalse);
    expect(calls, ['pause:output-1', 'resume:output-1']);
  });

  test(
    'recognizing replaces the pending deadline with an independent one',
    () async {
      controller = create(
        recognitionPendingTimeout: const Duration(milliseconds: 15),
        recognizingTimeout: const Duration(milliseconds: 200),
      );
      final lease = (await controller.beginCandidate())!;
      expect(controller.markRecognitionPending(lease), isTrue);
      expect(controller.markRecognizing(lease), isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(controller.phase, BargeInPhase.recognizing);
      expect(output.current.paused, isTrue);
      expect(calls, ['pause:output-1']);

      expect(
        await controller.resolveCandidate(lease, '嗯'),
        BargeInOutcome.resumed,
      );
    },
  );

  test('recognizing timeout resumes and late ASR is inert', () async {
    controller = create(recognizingTimeout: const Duration(milliseconds: 10));
    final lease = (await controller.beginCandidate())!;
    expect(controller.markRecognizing(lease), isTrue);

    await _until(() => controller.phase == BargeInPhase.idle);

    expect(controller.phase, BargeInPhase.idle);
    expect(
      await controller.resolveCandidate(lease, '迟到的语义内容'),
      BargeInOutcome.none,
    );
    expect(calls, ['pause:output-1', 'resume:output-1']);
  });

  test('hung recovery resume is bounded and retires exact output', () async {
    controller = create(controlTimeout: const Duration(milliseconds: 10));
    final lease = (await controller.beginCandidate())!;
    output.current.resumeGate = Completer<void>();

    expect(await controller.recoverCandidate(lease), BargeInOutcome.none);
    await _until(() => output.current.stopped);

    expect(controller.phase, BargeInPhase.idle);
    expect(controller.active.value, isFalse);
    expect(calls, [
      'pause:output-1',
      'resume:output-1',
      'stop:output-1:barge_in_control_timeout',
    ]);
  });

  test('hung semantic stop is bounded and clears resolving state', () async {
    controller = create(controlTimeout: const Duration(milliseconds: 10));
    final lease = (await controller.beginCandidate())!;
    output.current.stopGate = Completer<void>();

    expect(
      await controller.resolveCandidate(lease, '等等，换一个'),
      BargeInOutcome.none,
    );

    expect(controller.phase, BargeInPhase.idle);
    expect(controller.active.value, isFalse);
    expect(calls, [
      'pause:output-1',
      'stop:output-1:semantic_barge_in',
      'stop:output-1:barge_in_control_timeout',
    ]);
    expect(
      diagnostics.map((event) => event.kind),
      containsAllInOrder(<BargeInDiagnosticKind>[
        BargeInDiagnosticKind.semanticTakeover,
        BargeInDiagnosticKind.deadlineExceeded,
      ]),
    );
    expect(
      diagnostics.map((event) => event.kind),
      isNot(contains(BargeInDiagnosticKind.outputRetired)),
    );
    output.current.stopGate!.complete();
    await _until(
      () => diagnostics.any(
        (event) => event.kind == BargeInDiagnosticKind.outputRetired,
      ),
    );
    expect(
      diagnostics.where(
        (event) => event.kind == BargeInDiagnosticKind.outputRetired,
      ),
      hasLength(1),
    );
  });

  test('late candidate cannot control a replacement output', () async {
    final first = (await controller.beginCandidate())!;
    await controller.cancelCandidate(first);
    final replacement = output.replace(agentId: 'agent-b');
    final second = (await controller.beginCandidate(agentId: 'agent-b'))!;
    final beforeLateWork = List<String>.of(calls);

    expect(
      await controller.resolveCandidate(first, '这是旧的识别结果'),
      BargeInOutcome.none,
    );
    await controller.cancelCandidate(first);

    expect(calls, beforeLateWork);
    expect(replacement.stopped, isFalse);
    expect(controller.currentLease, same(second));
    expect(controller.phase, BargeInPhase.candidate);
    expect(
      await controller.resolveCandidate(second, '嗯'),
      BargeInOutcome.resumed,
    );
  });

  test(
    'replacement during resolve is never stopped by the old lease',
    () async {
      final lease = (await controller.beginCandidate())!;
      final old = output.current;
      final replacement = output.replace();

      expect(
        await controller.resolveCandidate(lease, '这是一个真正的新问题'),
        BargeInOutcome.none,
      );
      expect(old.stopped, isFalse);
      expect(replacement.stopped, isFalse);
      expect(replacement.paused, isFalse);
      expect(calls, ['pause:output-1']);
    },
  );

  test('a caller cannot replace the captured agent identity', () async {
    final lease = (await controller.beginCandidate(agentId: 'agent-a'))!;
    final outcome = await controller.resolveCandidate(
      lease,
      '嗯',
      agentId: 'other',
    );

    expect(lease.agentId, 'agent-a');
    expect(outcome, BargeInOutcome.resumed);
    expect(calls, ['pause:output-1', 'resume:output-1']);
  });

  test(
    'failed resume stops the same lease and clears the controller',
    () async {
      final failure = StateError('resume failed');
      output.current.resumeError = failure;
      final lease = (await controller.beginCandidate())!;

      await expectLater(
        controller.resolveCandidate(lease, ''),
        throwsA(same(failure)),
      );

      expect(output.current.stopped, isTrue);
      expect(output.current.paused, isFalse);
      expect(controller.phase, BargeInPhase.idle);
      expect(calls, [
        'pause:output-1',
        'resume:output-1',
        'stop:output-1:barge_in_recovery',
      ]);
    },
  );

  test(
    'cancel stops the captured lease so playback cannot stay paused',
    () async {
      final lease = (await controller.beginCandidate())!;
      expect(output.current.paused, isTrue);

      await controller.cancelCandidate(lease);

      expect(output.current.paused, isFalse);
      expect(output.current.stopped, isTrue);
      expect(controller.phase, BargeInPhase.idle);
      expect(calls, ['pause:output-1', 'stop:output-1:barge_in_cancelled']);
    },
  );

  test('cancel is bounded when the exact stop never completes', () async {
    controller = create(controlTimeout: const Duration(milliseconds: 10));
    final lease = (await controller.beginCandidate())!;
    output.current.stopGate = Completer<void>();

    await controller.cancelCandidate(lease);

    expect(controller.phase, BargeInPhase.idle);
    expect(controller.active.value, isFalse);
    expect(calls, [
      'pause:output-1',
      'stop:output-1:barge_in_cancelled',
      'stop:output-1:barge_in_control_timeout',
    ]);
  });

  test(
    'cancel during an in-flight pause aborts and stops exact output',
    () async {
      final gate = Completer<void>();
      output.current.pauseGate = gate;
      final beginning = controller.beginCandidate();
      await _until(() => calls.contains('pause:output-1'));
      final lease = controller.currentLease!;

      await controller.cancelCandidate(lease);

      expect(await beginning, isNull);
      expect(output.current.stopped, isTrue);
      expect(controller.phase, BargeInPhase.idle);
      expect(calls, ['pause:output-1', 'stop:output-1:barge_in_cancelled']);
    },
  );

  test(
    'cancel wins over an in-flight resolve and leaves no paused audio',
    () async {
      final gate = Completer<void>();
      output.current.resumeGate = gate;
      final lease = (await controller.beginCandidate())!;
      final resolving = controller.resolveCandidate(lease, '嗯');
      await _until(() => calls.contains('resume:output-1'));

      await controller.cancelCandidate(lease);
      gate.complete();

      expect(await resolving, BargeInOutcome.none);
      expect(output.current.stopped, isTrue);
      expect(output.current.paused, isFalse);
      expect(calls, [
        'pause:output-1',
        'resume:output-1',
        'stop:output-1:barge_in_cancelled',
      ]);
    },
  );

  test('cancel stop failure resumes before surfacing the error', () async {
    final failure = StateError('stop failed');
    output.current.stopError = failure;
    final lease = (await controller.beginCandidate())!;

    await expectLater(
      controller.cancelCandidate(lease),
      throwsA(same(failure)),
    );

    expect(output.current.paused, isFalse);
    expect(controller.phase, BargeInPhase.idle);
    expect(calls, [
      'pause:output-1',
      'stop:output-1:barge_in_cancelled',
      'resume:output-1',
    ]);
  });

  test('close stops a paused lease and clears state', () async {
    await controller.beginCandidate();
    expect(output.current.paused, isTrue);

    controller.onClose();
    await _until(() => output.current.stopped);

    expect(output.current.paused, isFalse);
    expect(controller.active.value, isFalse);
    expect(controller.phase, BargeInPhase.idle);
  });

  test(
    'close waits for an in-flight pause then stops that exact lease',
    () async {
      final gate = Completer<void>();
      final captured = output.current;
      captured.pauseGate = gate;
      final beginning = controller.beginCandidate();
      await _until(() => calls.length == 1);

      controller.onClose();
      gate.complete();
      expect(await beginning, isNull);
      await _until(() => captured.stopped);

      expect(captured.paused, isFalse);
      expect(calls, ['pause:output-1', 'stop:output-1:barge_in_recovery']);
    },
  );

  test('all stage timeouts must be positive', () {
    expect(() => create(pauseTimeout: Duration.zero), throwsArgumentError);
    expect(() => create(controlTimeout: Duration.zero), throwsArgumentError);
    expect(
      () => create(recognitionPendingTimeout: Duration.zero),
      throwsArgumentError,
    );
    expect(
      () => create(recognizingTimeout: Duration.zero),
      throwsArgumentError,
    );
  });
}

Future<void> _until(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 1),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('Condition did not complete before $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
}

final class _PlaybackHarness {
  _PlaybackHarness(this.calls) {
    current = _FakeSpeechPlaybackLease(
      calls: calls,
      generation: _nextGeneration++,
      utteranceId: 'output-1',
      agentId: 'agent-a',
    );
  }

  final List<String> calls;
  int _nextGeneration = 100;
  int _nextOutput = 2;
  late _FakeSpeechPlaybackLease current;

  SpeechPlaybackLease? capture({String? agentId}) {
    if (!current.current ||
        (agentId != null &&
            current.agentId != null &&
            current.agentId != agentId)) {
      return null;
    }
    return current;
  }

  _FakeSpeechPlaybackLease replace({String? agentId = 'agent-a'}) {
    current.current = false;
    final utteranceId = 'output-$_nextOutput';
    _nextOutput++;
    current = _FakeSpeechPlaybackLease(
      calls: calls,
      generation: _nextGeneration++,
      utteranceId: utteranceId,
      agentId: agentId,
    );
    return current;
  }
}

final class _FakeSpeechPlaybackLease implements SpeechPlaybackLease {
  _FakeSpeechPlaybackLease({
    required this.calls,
    required this.generation,
    required this.utteranceId,
    required this.agentId,
  });

  final List<String> calls;
  @override
  final int generation;
  @override
  final String utteranceId;
  @override
  final String? agentId;
  @override
  String spokenText = '今天吃猪脚饭怎么样？';
  @override
  String get turnId => 'turn-$generation';

  bool current = true;
  bool paused = false;
  bool stopped = false;
  Object? pauseError;
  bool pauseSideEffectBeforeError = false;
  Object? resumeError;
  Object? stopError;
  Completer<void>? pauseGate;
  Completer<void>? resumeGate;
  Completer<void>? stopGate;

  @override
  Future<bool> pause() async {
    if (!current) return false;
    calls.add('pause:$utteranceId');
    await pauseGate?.future;
    if (!current) return false;
    if (pauseSideEffectBeforeError) paused = true;
    final error = pauseError;
    if (error != null) throw error;
    paused = true;
    return true;
  }

  @override
  Future<bool> resume() async {
    if (!current) return false;
    calls.add('resume:$utteranceId');
    await resumeGate?.future;
    if (!current) return false;
    final error = resumeError;
    if (error != null) throw error;
    paused = false;
    return true;
  }

  @override
  Future<bool> stop([String reason = 'interrupted']) async {
    if (!current) return false;
    calls.add('stop:$utteranceId:$reason');
    await stopGate?.future;
    if (!current) return false;
    final error = stopError;
    if (error != null) throw error;
    paused = false;
    stopped = true;
    current = false;
    return true;
  }
}
