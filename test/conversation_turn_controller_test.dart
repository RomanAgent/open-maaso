import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/data/models/execution_result.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:sembast/sembast_memory.dart';

const _deadline = Duration(seconds: 3);

void main() {
  late DBService database;
  ConversationTurnController? controller;

  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path:
          'conversation-controller-${DateTime.now().microsecondsSinceEpoch}.db',
    );
    controller = null;
  });
  tearDown(() async {
    await controller?.retireAndDrain().timeout(_deadline);
    await database.close();
  });

  test(
    'Stop is idempotent when the output hook synchronously reenters',
    () async {
      final entered = Completer<void>();
      ConversationTurnHandle? active;
      Future<void>? nested;
      controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {
          nested = active?.cancel();
        },
        runChat: (context, history) async {
          entered.complete();
          await context.cancelled;
          return ExecutionResult.success('');
        },
      );
      active = controller!.submit('question', database: database);
      await entered.future;
      final stopped = active.cancel();
      expect(nested, same(stopped));
      await stopped.timeout(_deadline);
      expect((await active.done).cancelled, isTrue);
      expect(await database.getMessages('self'), hasLength(1));
    },
  );

  test('concurrent retirement callers share one cleanup operation', () async {
    var stops = 0;
    final entered = Completer<void>();
    controller = _controller(
      (context, history) async {
        entered.complete();
        await context.cancelled;
        return ExecutionResult.success('');
      },
      stopOutput: () async {
        stops++;
      },
    );
    final handle = controller!.submit('question', database: database);
    await entered.future;
    final first = controller!.retireAndDrain();
    final second = controller!.retireAndDrain();
    expect(second, same(first));
    await first.timeout(_deadline);
    expect((await handle.done).cancelled, isTrue);
    expect(stops, 2); // Initial admission and the single retirement stop.
  });

  test(
    'three delivered utterances persist without an aggregate fourth',
    () async {
      final observed = <ChatMessage>[];
      controller = _controller((context, history) async {
        expect(history, isEmpty);
        await context.deliver(_threeUtterances());
        return ExecutionResult.success('compatibility aggregate only');
      }, onMessage: observed.add);

      final handle = controller!.submit('今天吃什么？', database: database);
      final result = await handle.done.timeout(_deadline);
      final rows = await database.getMessages('self');
      final assistants = rows.where((row) => !row.isUserMessage).toList();

      expect(result.execution.isSuccess, isTrue);
      expect(result.cancelled, isFalse);
      expect(rows, hasLength(4));
      expect(assistants.map((row) => row.content), [
        '今天呀，嗯，我想想',
        '猪脚饭？',
        '或者看你想吃啥，我都行',
      ]);
      expect(assistants.map((row) => row.sequence), [0, 1, 2]);
      expect(assistants.map((row) => row.utteranceId).toSet(), hasLength(3));
      expect(rows.every((row) => row.turnId == handle.turnId), isTrue);
      expect(
        result.publishedMessages.map((row) => row.id),
        assistants.map((row) => row.id),
      );
      expect(
        result.execution.stdout,
        assistants.map((row) => row.content).join('\n'),
      );
      expect(observed.map((row) => row.id), rows.map((row) => row.id));
      expect(controller!.hasActiveTurn, isFalse);
    },
  );

  test(
    'immediate cancellation and duplicate token retain one accepted user',
    () async {
      var modelCalls = 0;
      controller = _controller((context, history) async {
        modelCalls++;
        return ExecutionResult.success('should not run');
      });

      final first = controller!.submit(
        '  first input  ',
        database: database,
        submissionToken: 'submission-one',
      );
      final duplicate = controller!.submit(
        'first input',
        database: database,
        submissionToken: 'submission-one',
      );
      final cancellation = first.cancel();
      await cancellation.timeout(_deadline);
      final result = await first.done.timeout(_deadline);
      final repeated = controller!.submit(
        'first input',
        database: database,
        submissionToken: 'submission-one',
      );

      expect(identical(first, duplicate), isTrue);
      expect(identical(first, repeated), isTrue);
      expect(modelCalls, 0);
      expect(result.cancelled, isTrue);
      expect(result.userMessage!.content, 'first input');
      expect(result.publishedMessages, isEmpty);
      final rows = await database.getMessages('self');
      expect(rows, hasLength(1));
      expect(rows.single.isUserMessage, isTrue);
      expect(rows.single.turnId, first.turnId);
    },
  );

  test(
    'a stalled old model cannot block B or publish when it returns late',
    () async {
      final aEntered = Completer<void>();
      final releaseA = Completer<void>();
      final aReturned = Completer<void>();
      controller = _controller((context, history) async {
        if (context.text == 'A') {
          aEntered.complete();
          await releaseA.future;
          await context.deliver([_unit('late A words')]);
          aReturned.complete();
          return ExecutionResult.success('late A aggregate');
        }
        await context.deliver([_unit('B answer')]);
        return ExecutionResult.success('B aggregate');
      });

      try {
        final a = controller!.submit('A', database: database);
        await aEntered.future.timeout(_deadline);
        final b = controller!.submit('B', database: database);
        final bResult = await b.done.timeout(_deadline);
        final aResult = await a.done.timeout(_deadline);

        expect(releaseA.isCompleted, isFalse);
        expect(aResult.cancelled, isTrue);
        expect(aResult.publishedMessages, isEmpty);
        expect(bResult.execution.stdout, 'B answer');
        releaseA.complete();
        await aReturned.future.timeout(_deadline);

        expect((await database.getMessages('self')).map((row) => row.content), [
          'A',
          'B',
          'B answer',
        ]);
      } finally {
        if (!releaseA.isCompleted) releaseA.complete();
      }
    },
  );

  test('published A is sealed before the successor user is saved', () async {
    final firstVisible = Completer<void>();
    final order = <String>[];
    controller = _controller(
      (context, history) async {
        if (context.text == 'A') {
          await context.deliver([
            _unit('first A', ConversationAfter.continueReply),
            _unit('unpublished A supplement'),
          ]);
        } else {
          await context.deliver([_unit('B answer')]);
        }
        return ExecutionResult.success('unused aggregate');
      },
      briefPause: const Duration(seconds: 30),
      onMessage: (message) {
        order.add(
          '${message.isUserMessage ? 'user' : 'assistant'}:${message.content}',
        );
        if (message.content == 'first A') firstVisible.complete();
      },
      onClosed: (context) => order.add('seal:${context.text}'),
    );

    final a = controller!.submit('A', database: database);
    await firstVisible.future.timeout(_deadline);
    final b = controller!.submit('B', database: database);
    await b.done.timeout(_deadline);
    final aResult = await a.done.timeout(_deadline);

    expect(order, [
      'user:A',
      'assistant:first A',
      'seal:A',
      'user:B',
      'assistant:B answer',
      'seal:B',
    ]);
    expect(aResult.cancelled, isTrue);
    expect(aResult.publishedMessages.single.content, 'first A');
    expect((await database.getMessages('self')).map((row) => row.content), [
      'A',
      'first A',
      'B',
      'B answer',
    ]);
  });

  test(
    'takeover drains an in-flight append before sealing and admitting B',
    () async {
      final writeEntered = Completer<void>();
      final releaseWrite = Completer<void>();
      var holdAssistantWrite = false;
      var held = false;
      final order = <String>[];
      final messages = intMapStoreFactory.store('chat_messages');
      messages.addOnChangesListener(database.raw, (transaction, changes) async {
        if (holdAssistantWrite && !held) {
          held = true;
          order.add('A-write-pending');
          writeEntered.complete();
          await releaseWrite.future;
          order.add('A-write-released');
        }
      });
      controller = _controller(
        (context, history) async {
          if (context.text == 'A') holdAssistantWrite = true;
          await context.deliver([_unit('${context.text} answer')]);
          return ExecutionResult.success('unused aggregate');
        },
        onMessage: (message) => order.add('visible:${message.content}'),
        onClosed: (context) => order.add('seal:${context.text}'),
      );

      try {
        final a = controller!.submit('A', database: database);
        await writeEntered.future.timeout(_deadline);
        final b = controller!.submit('B', database: database);
        expect(order, ['visible:A', 'A-write-pending']);
        releaseWrite.complete();
        await b.done.timeout(_deadline);
        final old = await a.done.timeout(_deadline);

        expect(old.cancelled, isTrue);
        expect(old.publishedMessages, isEmpty);
        expect(order, [
          'visible:A',
          'A-write-pending',
          'A-write-released',
          'seal:A',
          'visible:B',
          'visible:B answer',
          'seal:B',
        ]);
        expect((await database.getMessages('self')).map((row) => row.content), [
          'A',
          'B',
          'B answer',
        ]);
      } finally {
        if (!releaseWrite.isCompleted) releaseWrite.complete();
      }
    },
  );

  test('cancelling an old handle does not stop the successor output', () async {
    final aEntered = Completer<void>();
    final bEntered = Completer<void>();
    final releaseA = Completer<void>();
    final releaseB = Completer<void>();
    var stops = 0;
    controller = _controller((context, history) async {
      if (context.text == 'A') {
        aEntered.complete();
        await releaseA.future;
      } else {
        bEntered.complete();
        await releaseB.future;
      }
      await context.deliver([_unit('${context.text} answer')]);
      return ExecutionResult.success('unused aggregate');
    }, stopOutput: () async => stops++);

    try {
      final a = controller!.submit('A', database: database);
      await aEntered.future.timeout(_deadline);
      final b = controller!.submit('B', database: database);
      await bEntered.future.timeout(_deadline);
      final beforeOldCancel = stops;
      await a.cancel().timeout(_deadline);
      await a.cancel().timeout(_deadline);

      expect(stops, beforeOldCancel);
      expect(b.isCurrent, isTrue);
      expect(b.isCancelled, isFalse);
      releaseB.complete();
      expect((await b.done.timeout(_deadline)).execution.stdout, 'B answer');
    } finally {
      if (!releaseA.isCompleted) releaseA.complete();
      if (!releaseB.isCompleted) releaseB.complete();
    }
  });

  test(
    'retirement drains every accepted user even before admission finishes',
    () async {
      var modelCalls = 0;
      controller = _controller((context, history) async {
        modelCalls++;
        return ExecutionResult.success('must not generate after retirement');
      });
      final handles = [
        controller!.submit('accepted A', database: database),
        controller!.submit('accepted B', database: database),
        controller!.submit('accepted C', database: database),
      ];

      await controller!.retireAndDrain().timeout(_deadline);
      final results = await Future.wait(handles.map((handle) => handle.done));
      final rows = await database.getMessages('self');

      expect(rows.map((row) => row.content), [
        'accepted A',
        'accepted B',
        'accepted C',
      ]);
      expect(rows.every((row) => row.isUserMessage), isTrue);
      expect(rows.map((row) => row.turnId).toSet(), hasLength(3));
      expect(results.every((result) => result.userMessage != null), isTrue);
      expect(results.every((result) => result.cancelled), isTrue);
      expect(modelCalls, 0);
      expect(
        () => controller!.submit('too late', database: database),
        throwsStateError,
      );
    },
  );

  test(
    'the next model receives one prior user and all three utterances',
    () async {
      List<Message>? nextHistory;
      controller = _controller((context, history) async {
        if (context.text == 'first question') {
          await context.deliver(_threeUtterances());
        } else {
          nextHistory = history;
          expect(context.text, 'current question');
          await context.deliver([_unit('new answer')]);
        }
        return ExecutionResult.success('unused aggregate');
      });

      await controller!
          .submit('first question', database: database)
          .done
          .timeout(_deadline);
      await controller!
          .submit('current question', database: database)
          .done
          .timeout(_deadline);

      expect(nextHistory!.map((message) => message.role), [
        'user',
        'assistant',
        'assistant',
        'assistant',
      ]);
      expect(nextHistory!.map((message) => message.content), [
        'first question',
        '今天呀，嗯，我想想',
        '猪脚饭？',
        '或者看你想吃啥，我都行',
      ]);
      expect(
        nextHistory!.any((message) => message.content == 'current question'),
        isFalse,
      );
    },
  );

  test('character budget retains or drops an entire logical turn', () {
    final rows = [
      _row('older question', turnId: 'old', user: true),
      _row('older answer', turnId: 'old'),
      _row('what?', turnId: 'three', user: true),
      _row('one', turnId: 'three'),
      _row('two', turnId: 'three'),
      _row('three', turnId: 'three'),
      _row('user', turnId: 'last', user: true),
      _row('reply', turnId: 'last'),
    ];

    final exact = conversationHistory(rows, characterBudget: 25);
    expect(exact.map((message) => message.content), [
      'what?',
      'one',
      'two',
      'three',
      'user',
      'reply',
    ]);
    expect(exact.map((message) => message.role), [
      'user',
      'assistant',
      'assistant',
      'assistant',
      'user',
      'assistant',
    ]);
    expect(
      conversationHistory(
        rows,
        characterBudget: 24,
      ).map((message) => message.content),
      ['user', 'reply'],
    );
    expect(conversationHistory(rows, characterBudget: 8), isEmpty);
    expect(
      conversationHistory(rows, turnLimit: 1).map((message) => message.content),
      ['user', 'reply'],
    );
  });

  test('history drops a truncated leading turn without alternating roles', () {
    final rows = [
      _row('orphaned middle utterance', turnId: 'truncated'),
      _row('orphaned final utterance', turnId: 'truncated'),
      _row('complete question', turnId: 'complete', user: true),
      _row('first answer', turnId: 'complete'),
      _row('second answer', turnId: 'complete'),
    ];

    final history = conversationHistory(rows);
    expect(history.map((message) => message.content), [
      'complete question',
      'first answer',
      'second answer',
    ]);
    expect(history.map((message) => message.role), [
      'user',
      'assistant',
      'assistant',
    ]);
  });

  test(
    'failed user persistence ends the turn without calling the model',
    () async {
      final messages = intMapStoreFactory.store('chat_messages');
      messages.addOnChangesListener(database.raw, (transaction, changes) {
        throw StateError('user write failed');
      });
      var modelCalls = 0;
      controller = _controller((context, history) async {
        modelCalls++;
        return ExecutionResult.success('must not generate');
      });

      final result = await controller!
          .submit('cannot persist', database: database)
          .done
          .timeout(_deadline);

      expect(result.execution.isSuccess, isFalse);
      expect(result.execution.stderr, isNotEmpty);
      expect(result.userMessage, isNull);
      expect(result.publishedMessages, isEmpty);
      expect(modelCalls, 0);
      expect(await database.getMessages('self'), isEmpty);
      expect(controller!.hasActiveTurn, isFalse);
    },
  );

  test(
    'failed publication is an error and the next admission remains usable',
    () async {
      var rejectWrites = false;
      final messages = intMapStoreFactory.store('chat_messages');
      messages.addOnChangesListener(database.raw, (transaction, changes) {
        if (rejectWrites) throw StateError('assistant write failed');
      });
      controller = _controller((context, history) async {
        rejectWrites = context.text == 'failing turn';
        await context.deliver([_unit('${context.text} answer')]);
        return ExecutionResult.success('must not become a success fallback');
      });

      final failed = await controller!
          .submit('failing turn', database: database)
          .done
          .timeout(_deadline);
      expect(failed.execution.isSuccess, isFalse);
      expect(failed.execution.stderr, isNotEmpty);
      expect(failed.publishedMessages, isEmpty);
      expect(
        (await database.getMessages('self')).single.content,
        'failing turn',
      );
      expect(controller!.hasActiveTurn, isFalse);

      rejectWrites = false;
      final next = await controller!
          .submit('next turn', database: database)
          .done
          .timeout(_deadline);
      expect(next.execution.isSuccess, isTrue);
      expect(next.execution.stdout, 'next turn answer');
      expect((await database.getMessages('self')).map((row) => row.content), [
        'failing turn',
        'next turn',
        'next turn answer',
      ]);
    },
  );

  test(
    'a failed durable seal does not report the delivered turn as successful',
    () async {
      final seals = StoreRef<String, bool>('conversation_turn_seals');
      seals.addOnChangesListener(database.raw, (transaction, changes) {
        throw StateError('seal write failed');
      });
      controller = _controller((context, history) async {
        await context.deliver([_unit('already committed words')]);
        return ExecutionResult.success('unused aggregate');
      });

      final result = await controller!
          .submit('question', database: database)
          .done
          .timeout(_deadline);

      expect(result.execution.isSuccess, isFalse);
      expect(result.execution.stderr, 'conversation_persistence_failed');
      expect(
        result.publishedMessages.single.content,
        'already committed words',
      );
      expect((await database.getMessages('self')).map((row) => row.content), [
        'question',
        'already committed words',
      ]);
      expect(controller!.hasActiveTurn, isFalse);
    },
  );
}

ConversationTurnController _controller(
  RunConversationChat runChat, {
  Future<void> Function()? stopOutput,
  void Function(ChatMessage)? onMessage,
  void Function(ConversationTurnContext)? onClosed,
  Duration briefPause = Duration.zero,
}) => ConversationTurnController(
  agentId: 'self',
  runChat: runChat,
  stopOutput: stopOutput ?? () async {},
  isAvailable: () => true,
  onMessage: onMessage,
  onClosed: onClosed,
  briefPause: briefPause,
  invitationPause: Duration.zero,
  // These tests isolate publication and cancellation; batching has its own
  // suite with the production quiet-window behavior enabled.
  inputMergeWindow: Duration.zero,
);

ConversationUtteranceDraft _unit(
  String text, [
  ConversationAfter after = ConversationAfter.finish,
]) => ConversationUtteranceDraft(text: text, after: after);

List<ConversationUtteranceDraft> _threeUtterances() => [
  _unit('今天呀，嗯，我想想', ConversationAfter.continueReply),
  _unit('猪脚饭？', ConversationAfter.continueReply),
  _unit('或者看你想吃啥，我都行'),
];

ChatMessage _row(String content, {required String turnId, bool user = false}) =>
    ChatMessage(
      sessionId: 'self',
      senderId: user ? 'user' : 'self',
      receiverId: user ? 'self' : 'user',
      content: content,
      timestamp: DateTime.utc(2026, 9, 3),
      isUserMessage: user,
      turnOrigin: ChatMessageTurnOrigins.user,
      turnId: turnId,
      deliveryStatus: 'published',
    );
