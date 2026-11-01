import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_response_trace.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/application/speech/speech_utterance_handle.dart';
import 'package:maaso/src/features/agent/data/models/execution_result.dart';
import 'package:sembast/sembast_memory.dart';

const _deadline = Duration(seconds: 3);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('milestones are monotonic elapsed times and recorded only once', () {
    var elapsed = Duration.zero;
    final events = <String>[];
    final trace = ConversationResponseTrace(
      turnId: 'turn-a',
      elapsed: () => elapsed,
      onEvent: (name, {details}) => events.add('$name $details'),
    );

    elapsed = const Duration(microseconds: 120);
    trace.recordPublished();
    elapsed = const Duration(microseconds: 180);
    trace.recordPublished();
    trace.recordAudioStarted();
    elapsed = const Duration(microseconds: 300);
    trace.recordAudioStarted();
    trace.finish(ConversationResponseOutcome.completed);
    trace.finish(ConversationResponseOutcome.failed);
    trace.recordPublished();
    trace.recordAudioStarted();

    expect(events, [
      'conversation.response.first_text turn=turn-a boundary=published '
          'elapsed_us=120',
      'conversation.response.first_audio turn=turn-a '
          'boundary=playback_handle_started elapsed_us=180',
      'conversation.response.completed turn=turn-a outcome=completed '
          'elapsed_us=300 first_text_us=120 first_audio_us=180',
    ]);
  });

  test('missing measurements stay unavailable instead of becoming zero', () {
    final events = <String>[];
    final trace = ConversationResponseTrace(
      turnId: 'cancelled-turn',
      elapsed: () => const Duration(microseconds: 50),
      onEvent: (name, {details}) => events.add('$name $details'),
    );
    trace.finish(ConversationResponseOutcome.cancelled);
    trace.recordPublished();
    trace.recordAudioStarted();

    expect(events, [
      'conversation.response.completed turn=cancelled-turn outcome=cancelled '
          'elapsed_us=50 first_text_us=unavailable first_audio_us=unavailable',
    ]);
  });

  test('a broken diagnostics sink cannot interrupt delivery', () {
    final trace = ConversationResponseTrace(
      turnId: 'turn-with-broken-observer',
      onEvent: (_, {details}) => throw StateError('observer failed'),
    );
    expect(trace.recordPublished, returnsNormally);
    expect(trace.recordAudioStarted, returnsNormally);
    expect(
      () => trace.finish(ConversationResponseOutcome.failed),
      returnsNormally,
    );
  });

  group('conversation wiring', () {
    late DBService database;
    ConversationTurnController? controller;

    setUp(() async {
      database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'response-trace-${DateTime.now().microsecondsSinceEpoch}.db',
      );
    });

    tearDown(() async {
      await controller?.retireAndDrain().timeout(_deadline);
      controller = null;
      await database.close();
    });

    test(
      'every text turn is measured and text-only audio stays unavailable',
      () async {
        final logs = <String>[];
        await _capture(logs, () async {
          controller = _controller((context, _) async {
            return ExecutionResult.success('published reply');
          });
          for (var index = 0; index < 2; index++) {
            final handle = controller!.submit(
              'input $index',
              database: database,
              respondImmediately: true,
            );
            final result = await handle.done.timeout(_deadline);
            expect(result.publishedMessages, hasLength(1));
            final text = _events(logs, handle.turnId, 'first_text');
            final done = _events(logs, handle.turnId, 'completed');
            expect(text, hasLength(1));
            expect(text.single, contains('boundary=published'));
            expect(_events(logs, handle.turnId, 'first_audio'), isEmpty);
            expect(done, hasLength(1));
            expect(done.single, contains('outcome=completed'));
            expect(done.single, contains('first_audio_us=unavailable'));
            expect(done.single, isNot(contains('first_text_us=unavailable')));
          }
        });
      },
    );

    test('audio milestone waits for the playback started receipt', () async {
      final logs = <String>[];
      final queued = Completer<_Speech>();
      final started = Completer<void>();
      await _capture(logs, () async {
        controller = _controller((context, _) async {
          await context.deliver(
            [ConversationUtteranceDraft(text: 'spoken reply')],
            speak: (utterance) {
              final speech = _Speech(context.turnId, utterance.utteranceId);
              queued.complete(speech);
              return speech;
            },
            onSpeechStarted: (_) => started.complete(),
          );
          return ExecutionResult.success('');
        });
        final handle = controller!.submit(
          'question',
          database: database,
          respondImmediately: true,
        );
        final speech = await queued.future.timeout(_deadline);
        expect(_events(logs, handle.turnId, 'first_text'), hasLength(1));
        expect(_events(logs, handle.turnId, 'first_audio'), isEmpty);
        expect(_events(logs, handle.turnId, 'completed'), isEmpty);

        speech.playbackStarted.complete(true);
        await started.future.timeout(_deadline);
        final audio = _events(logs, handle.turnId, 'first_audio');
        expect(audio, hasLength(1));
        expect(audio.single, contains('boundary=playback_handle_started'));
        speech.playbackTerminal.complete(SpeechTerminal.completed);
        await handle.done.timeout(_deadline);
        expect(_events(logs, handle.turnId, 'completed'), hasLength(1));
      });
    });

    test(
      'failed generation reports a terminal event without fake first text',
      () async {
        final logs = <String>[];
        await _capture(logs, () async {
          controller = _controller(
            (_, _) async => throw StateError('model failed'),
          );
          final handle = controller!.submit(
            'question',
            database: database,
            respondImmediately: true,
          );
          final result = await handle.done.timeout(_deadline);
          expect(result.execution.isSuccess, isFalse);
          expect(_events(logs, handle.turnId, 'first_text'), isEmpty);
          final done = _events(logs, handle.turnId, 'completed');
          expect(done, hasLength(1));
          expect(done.single, contains('outcome=failed'));
          expect(done.single, contains('first_text_us=unavailable'));
        });
      },
    );

    test(
      'cancelled generation does not contribute milestones to its successor',
      () async {
        final logs = <String>[];
        final entered = Completer<void>();
        await _capture(logs, () async {
          controller = _controller((context, _) async {
            if (context.text == 'old question') {
              entered.complete();
              await context.cancelled;
              return ExecutionResult.success('stale reply');
            }
            return ExecutionResult.success('new reply');
          });
          final old = controller!.submit(
            'old question',
            database: database,
            respondImmediately: true,
          );
          await entered.future.timeout(_deadline);
          await old.cancel().timeout(_deadline);
          expect((await old.done.timeout(_deadline)).cancelled, isTrue);
          final next = controller!.submit(
            'new question',
            database: database,
            respondImmediately: true,
          );
          await next.done.timeout(_deadline);
          expect(_events(logs, old.turnId, 'first_text'), isEmpty);
          expect(_events(logs, old.turnId, 'first_audio'), isEmpty);
          expect(
            _events(logs, old.turnId, 'completed').single,
            contains('outcome=cancelled'),
          );
          expect(_events(logs, next.turnId, 'first_text'), hasLength(1));
          expect(_events(logs, next.turnId, 'completed'), hasLength(1));
        });
      },
    );
  });
}

ConversationTurnController _controller(RunConversationChat runChat) =>
    ConversationTurnController(
      agentId: 'self',
      runChat: runChat,
      isAvailable: () => true,
      stopOutput: () async {},
      inputMergeWindow: Duration.zero,
      briefPause: Duration.zero,
      invitationPause: Duration.zero,
    );

Future<T> _capture<T>(List<String> logs, Future<T> Function() action) =>
    runZoned<Future<T>>(
      action,
      zoneSpecification: ZoneSpecification(
        print: (self, parent, zone, line) => logs.add(line),
      ),
    );

List<String> _events(List<String> logs, String turnId, String event) => logs
    .where(
      (line) =>
          line.contains('conversation.response.$event ') &&
          line.contains('turn=$turnId '),
    )
    .toList();

class _Speech implements SpeechUtteranceHandle {
  _Speech(this.turnId, this.utteranceId);

  @override
  final String turnId;
  @override
  final String utteranceId;
  final playbackStarted = Completer<bool>();
  final playbackTerminal = Completer<SpeechTerminal>();

  @override
  Future<bool> get started => playbackStarted.future;
  @override
  Future<SpeechTerminal> get terminal => playbackTerminal.future;
  @override
  Future<void> get drained async {
    await terminal;
  }

  @override
  Future<void> cancel([String reason = 'cancelled']) async {
    if (!playbackStarted.isCompleted) playbackStarted.complete(false);
    if (!playbackTerminal.isCompleted) {
      playbackTerminal.complete(SpeechTerminal.cancelled);
    }
  }
}
