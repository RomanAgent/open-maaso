import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
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
      path: 'conversation-batch-${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });
  tearDown(() async {
    await controller?.retireAndDrain().timeout(_deadline);
    controller = null;
    await database.close();
  });

  ConversationTurnController makeController(
    RunConversationChat runChat, {
    Duration mergeWindow = const Duration(milliseconds: 40),
    Duration typingWindow = const Duration(milliseconds: 160),
    Duration maximumWait = const Duration(milliseconds: 300),
    void Function(ChatMessage)? onMessage,
    Future<void> Function()? stopOutput,
  }) => ConversationTurnController(
    agentId: 'self',
    runChat: runChat,
    stopOutput: stopOutput ?? () async {},
    isAvailable: () => true,
    inputMergeWindow: mergeWindow,
    typingQuietWindow: typingWindow,
    maximumInputWait: maximumWait,
    briefPause: Duration.zero,
    invitationPause: Duration.zero,
    onMessage: onMessage,
  );

  test(
    'one batch saves each raw row and generates once without fake history',
    () async {
      var modelCalls = 0;
      var stops = 0;
      final callbacks = <String>[];
      controller = makeController((context, history) async {
        modelCalls++;
        expect(context.text, '今天好累\n项目又改了\n先别给我建议');
        expect(context.inputTexts, ['今天好累', '项目又改了', '先别给我建议']);
        expect(
          context.userMessages.map((row) => row.content),
          context.inputTexts,
        );
        expect(context.userMessages.map((row) => row.id).toSet(), hasLength(3));
        expect(context.userMessages.every((row) => row.id != null), isTrue);
        expect(context.userMessages.map((row) => row.turnId).toSet(), {
          context.turnId,
        });
        expect(context.userMessage!.content, '先别给我建议');
        expect(history, isEmpty);
        expect(() => context.inputTexts.add('forged'), throwsUnsupportedError);
        expect(() => context.userMessages.clear(), throwsUnsupportedError);
        context.userMessages.first.content = 'observer mutation';
        expect(context.text, startsWith('今天好累\n'));
        return ExecutionResult.success('行，先听你说。');
      }, stopOutput: () async => stops++);

      final handles = <ConversationTurnHandle>[];
      for (final text in ['今天好累', '项目又改了', '先别给我建议']) {
        handles.add(
          controller!.submit(
            text,
            database: database,
            onMessage: (message) => callbacks.add('$text:${message.content}'),
          ),
        );
      }
      final results = await Future.wait(
        handles.map((handle) => handle.done),
      ).timeout(_deadline);
      expect(modelCalls, 1);
      expect(stops, 1);
      expect(results.map((result) => result.turnId).toSet(), hasLength(1));
      expect(results.every((result) => !result.cancelled), isTrue);
      expect(results.last.userMessages, hasLength(3));
      expect(callbacks, [
        '今天好累:今天好累',
        '项目又改了:项目又改了',
        '先别给我建议:先别给我建议',
        '先别给我建议:行，先听你说。',
      ]);
      expect((await database.getMessages('self')).map((row) => row.content), [
        '今天好累',
        '项目又改了',
        '先别给我建议',
        '行，先听你说。',
      ]);
    },
  );

  test(
    'typing extends the quiet window and drafts never become user sources',
    () async {
      var called = false;
      controller = makeController((context, history) async {
        called = true;
        expect(context.inputTexts, ['等我说完', '还有一件事']);
        return ExecutionResult.success('嗯，听着呢。');
      });
      final first = controller!.submit('等我说完', database: database);
      first.updateDraft('还');
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(called, isFalse);
      first.updateDraft('还有一件事');
      final second = controller!.submit('还有一件事', database: database);
      await second.done.timeout(_deadline);
      expect(second.turnId, first.turnId);
      expect(called, isTrue);
      expect(
        (await database.getMessages(
          'self',
        )).where((row) => row.isUserMessage).map((row) => row.content),
        ['等我说完', '还有一件事'],
      );
    },
  );

  test(
    'a long pause resumes and repeated edits cannot postpone forever',
    () async {
      final entered = Completer<void>();
      controller = makeController((context, history) async {
        entered.complete();
        expect(context.text, '已经发出的消息');
        return ExecutionResult.success('回应已发送的部分');
      }, maximumWait: const Duration(milliseconds: 130));
      final handle = controller!.submit('已经发出的消息', database: database);
      var edits = 0;
      final typing = Timer.periodic(const Duration(milliseconds: 15), (_) {
        handle.updateDraft('还没发出的草稿${edits++}');
      });
      try {
        await entered.future.timeout(const Duration(milliseconds: 500));
        await handle.done.timeout(_deadline);
        expect(edits, greaterThan(1));
        expect(
          (await database.getMessages(
            'self',
          )).where((row) => row.isUserMessage).single.content,
          '已经发出的消息',
        );
      } finally {
        typing.cancel();
      }
    },
  );

  test(
    'explicit response-now flushes the batch and prevents later merging',
    () async {
      final entered = <String>[];
      controller = makeController(
        (context, history) async {
          entered.add(context.text);
          return ExecutionResult.success('收到');
        },
        mergeWindow: const Duration(seconds: 1),
        maximumWait: const Duration(seconds: 2),
      );
      final first = controller!.submit('先说这些', database: database);
      final second = controller!.submit(
        '现在答吧',
        database: database,
        respondImmediately: true,
      );
      await second.done.timeout(const Duration(milliseconds: 400));
      expect(first.turnId, second.turnId);
      expect(entered, ['先说这些\n现在答吧']);
      final third = controller!.submit('下一件事', database: database);
      controller!.flushPendingInput();
      await third.done.timeout(const Duration(milliseconds: 400));
      expect(third.turnId, isNot(first.turnId));
    },
  );

  test(
    'a generation snapshot is stable when the next input cancels it',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      late ConversationTurnContext oldContext;
      controller = makeController((context, history) async {
        if (context.inputTexts.first == '第一句') {
          oldContext = context;
          entered.complete();
          await release.future;
          await context.deliver([ConversationUtteranceDraft(text: '过期回答')]);
        } else {
          return ExecutionResult.success('回应新输入');
        }
        return ExecutionResult.success('');
      });
      final first = controller!.submit('第一句', database: database);
      await entered.future.timeout(_deadline);
      final second = controller!.submit('新输入', database: database);
      try {
        await second.done.timeout(_deadline);
        expect(oldContext.inputTexts, ['第一句']);
        expect(oldContext.userMessages.single.content, '第一句');
        expect((await first.done.timeout(_deadline)).cancelled, isTrue);
        expect(second.turnId, isNot(first.turnId));
        expect((await database.getMessages('self')).map((row) => row.content), [
          '第一句',
          '新输入',
          '回应新输入',
        ]);
      } finally {
        release.complete();
      }
    },
  );

  test(
    'cancelling during admission retains every accepted raw message',
    () async {
      var modelCalls = 0;
      controller = makeController((context, history) async {
        modelCalls++;
        return ExecutionResult.success('unused');
      });
      final first = controller!.submit(
        '一',
        database: database,
        submissionToken: 'one',
      );
      final duplicate = controller!.submit(
        '一',
        database: database,
        submissionToken: 'one',
      );
      final second = controller!.submit('二', database: database);
      expect(duplicate, same(first));
      await second.cancel().timeout(_deadline);
      final result = await first.done.timeout(_deadline);
      expect(result.cancelled, isTrue);
      expect(result.userMessages.map((row) => row.content), ['一', '二']);
      expect((await database.getMessages('self')).map((row) => row.content), [
        '一',
        '二',
      ]);
      expect(modelCalls, 0);
    },
  );

  test(
    'an older merged submission cannot cancel or edit the latest owner',
    () async {
      controller = makeController((context, history) async {
        expect(context.inputTexts, ['一', '二']);
        return ExecutionResult.success('reply');
      });
      final first = controller!.submit('一', database: database);
      final second = controller!.submit('二', database: database);
      expect(first.isCurrent, isFalse);
      expect(second.isCurrent, isTrue);
      await first.cancel();
      first.updateDraft('stale entry draft');
      final result = await second.done.timeout(_deadline);
      expect(result.cancelled, isFalse);
      expect(result.execution.stdout, 'reply');
    },
  );

  test('different source origins and scopes cannot share a batch', () async {
    final generated = <String>[];
    controller = makeController((context, history) async {
      generated.add(context.text);
      return ExecutionResult.success('done');
    });
    final first = controller!.submit(
      '文本',
      database: database,
      expectedAppletScopeKey: 'A',
    );
    final second = controller!.submit(
      '语音',
      database: database,
      origin: TurnOrigin.voice,
      expectedAppletScopeKey: 'A',
    );
    final third = controller!.submit(
      '另一个账号',
      database: database,
      origin: TurnOrigin.voice,
      expectedAppletScopeKey: 'B',
    );
    await third.done.timeout(_deadline);
    expect({first.turnId, second.turnId, third.turnId}, hasLength(3));
    expect(generated, ['另一个账号']);
    expect(
      (await database.getMessages(
        'self',
      )).where((row) => row.isUserMessage).map((row) => row.content),
      ['文本', '语音', '另一个账号'],
    );
  });

  test('changed extra context starts a separate turn', () async {
    controller = makeController((context, history) async {
      expect(history.first.content, 'new browsing context');
      expect(context.text, '第二条');
      return ExecutionResult.success('done');
    });
    final first = controller!.submit(
      '第一条',
      database: database,
      extraContext: [Message.system('old browsing context')],
    );
    final second = controller!.submit(
      '第二条',
      database: database,
      extraContext: [Message.system('new browsing context')],
    );
    await second.done.timeout(_deadline);
    expect(first.turnId, isNot(second.turnId));
  });

  test(
    'a revoked delivery guard keeps the published prefix and drops the rest',
    () async {
      var version = 1;
      controller = makeController((context, history) async {
        context.bindDeliveryGuard(() => version == 1);
        await context.deliver(
          [
            ConversationUtteranceDraft(
              text: '已发布',
              after: ConversationAfter.continueReply,
            ),
            ConversationUtteranceDraft(text: '已失效，不能再发'),
          ],
          onPublished: (_) {
            version = 2;
          },
        );
        return ExecutionResult.success('unused aggregate');
      });
      final result = await controller!
          .submit('消息', database: database)
          .done
          .timeout(_deadline);
      expect(result.publishedMessages.single.content, '已发布');
      expect((await database.getMessages('self')).map((row) => row.content), [
        '消息',
        '已发布',
      ]);
    },
  );

  test('a throwing delivery guard fails closed', () async {
    controller = makeController((context, history) async {
      context.bindDeliveryGuard(() => throw StateError('policy unavailable'));
      await context.deliver([ConversationUtteranceDraft(text: '不能发布')]);
      return ExecutionResult.success('cannot fall back either');
    });
    final result = await controller!
        .submit('消息', database: database)
        .done
        .timeout(_deadline);
    expect(result.publishedMessages, isEmpty);
    expect((await database.getMessages('self')).single.isUserMessage, isTrue);
  });
}
