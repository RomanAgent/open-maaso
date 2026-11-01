import 'dart:typed_data';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/app_invocation_chat_reference.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_draft_snapshot.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_result_store.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_store.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/data/models/execution_result.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late _PublicationDB database;
  late String databasePath;
  late AppInvocationStore journal;
  late ChatMediaService media;
  late AppInvocationResultStore results;
  late AppInvocationDescriptor descriptor;
  var current = true, mount = 'mount-A', serial = 0;
  AppInvocationStore makeJournal(String process) => AppInvocationStore(
    database: database.raw,
    scopeKey: 'account-A',
    mountId: 'mount-A',
    processId: process,
    committedImageReader: media.readInvocationOutput,
    isCurrent: () => current,
  );
  AppInvocationResultStore makeResults() => AppInvocationResultStore(
    database: database,
    invocationStore: journal,
    media: media,
    scopeKey: 'account-A',
    mountId: 'mount-A',
    currentMountId: () => mount,
    isCurrent: () => current,
  );
  Future<AppInvocationActionReceipt> receipt({
    List<AppInvocationProducedImage>? outputs,
    String token = 'submission-1',
  }) async {
    final draft = AppInvocationDraftSnapshot(
      scopeKey: 'account-A',
      text: 'Original draft',
      imageHandles: [],
      sourceOrigin: 'local',
      sourceId: descriptor.identity.sourceId,
      localWidgetId: 1,
      sourceType: 'applet',
      sourceTitle: 'Any tool',
      revisionId: descriptor.identity.revisionId,
      sourceDigest: descriptor.identity.sourceDigest,
      contractDigest: descriptor.contractDigest,
      adapterId: 'test-host',
      adapterVersion: '1',
    );
    final run = await journal.admit(
      submissionToken: token,
      turnId: 'turn-source',
      sessionId: 'self',
      descriptor: descriptor,
      adapterId: 'test-host',
      adapterVersion: '1',
      inputDigest: draft.inputDigest,
      draftSnapshot: draft,
      canContinue: () => current,
    );
    await journal.reserveAction(
      invocationId: run.invocationId,
      requestId: 'request-1',
      actionId: 'custom.run',
      arguments: {},
      observationId: 'observe-1',
      expectedStateVersion: 0,
      canContinue: () => current,
    );
    final value = AppInvocationActionReceipt(
      invocationId: run.invocationId,
      requestId: 'request-1',
      actionId: 'custom.run',
      identity: descriptor.identity,
      contractDigest: descriptor.contractDigest,
      status: AppInvocationActionStatus.completed,
      stateVersion: 1,
      result: {
        'count': 1,
        'nested': {'a': 1, 'b': true},
      },
      outputs: outputs ?? [_png()],
    );
    await journal.settle(value, canContinue: () => current);
    return value;
  }

  Future<PreparedInvocationResult> prepare(
    AppInvocationActionReceipt receipt, {
    String summary = '',
  }) => results.prepare(
    receipt: receipt,
    sourceTitle: 'Any tool',
    summary: summary,
  );
  ChatMessage message(
    PreparedInvocationResult result, {
    String turn = 'turn-1',
  }) => ChatMessage(
    sessionId: 'self',
    senderId: 'self',
    receiverId: 'user',
    content: result.summary,
    timestamp: DateTime.utc(2026),
    turnOrigin: 'user',
    turnId: turn,
    utteranceId: result.utteranceId,
    sequence: 0,
    deliveryStatus: 'published',
    attachments: result.attachments,
    appletReference: result.appletReference,
    invocationReference: result.invocationReference,
    idempotencyKey: result.idempotencyKey,
  );

  setUp(() async {
    current = true;
    mount = 'mount-A';
    databasePath = 'invocation-result-${serial++}.db';
    database = _PublicationDB();
    await database.init(factory: databaseFactoryMemory, path: databasePath);
    media = ChatMediaService(
      database: database.raw,
      isCurrent: () => current,
      baseUri: Uri.https('example.invalid'),
      accessToken: () async => 'unused',
    );
    journal = makeJournal('process-1');
    results = makeResults();
    descriptor = AppInvocationDescriptor.fromSurface(
      project: SurfaceProject.fromJson({
        'id': 'work',
        'rendering': 'webApp',
        'html': '<main>unchanged</main>',
        'manifest': {
          'actions': [
            {'name': 'custom.run', 'schema': <String, Object?>{}},
          ],
        },
      }),
      identity: AppInvocationIdentity(
        scopeKey: 'account-A',
        sourceId: 'work',
        revisionId: 'local:v1',
        sourceDigest: 'a' * 64,
      ),
    );
  });
  tearDown(() async {
    await results.deactivateAndDrain();
    journal.retire();
    await media.shutdown();
    await database.close();
  });

  test(
    'PNG originals, alpha, ordered metadata and empty-summary message commit together',
    () async {
      final source = await receipt();
      final result = await prepare(source);
      expect(await media.read(result.attachments.single), isNull);
      final committed = await database.publishConversationUtterance(
        message(result),
        publication: result,
      );
      expect(committed, isNotNull);
      final original = (await media.read(committed!.attachments.single))!;
      expect(original.mime, 'image/png');
      expect(original.bytes, orderedEquals(source.outputs.single.bytes));
      expect(image.decodePng(original.bytes)!.getPixel(0, 0).a, 0);
      final record = (await results.readResult(
        source.invocationId,
        result.resultId,
      ))!;
      expect(record['state'], 'committed');
      expect(record['messageId'], committed.id);
      expect(
        (record['manifest'] as Map)['identity'],
        descriptor.identity.toJson(),
      );
      expect(
        (await journal.readRun(source.invocationId)).value['resultId'],
        result.resultId,
      );
    },
  );

  test(
    'restart/recovery returns original message across a new turn without replay',
    () async {
      final source = await receipt();
      final prepared = await prepare(source, summary: 'Created one image.');
      final original = await database.publishConversationUtterance(
        message(prepared),
        publication: prepared,
      );
      await database.sealConversationTurn(sessionId: 'self', turnId: 'turn-1');
      await results.deactivateAndDrain();
      journal.retire();
      await media.shutdown();
      await database.close();
      database = _PublicationDB();
      await database.init(factory: databaseFactoryMemory, path: databasePath);
      media = ChatMediaService(
        database: database.raw,
        isCurrent: () => current,
        baseUri: Uri.https('example.invalid'),
        accessToken: () async => 'unused',
      );
      journal = makeJournal('process-2');
      results = makeResults();
      final recovered = await journal.readReceipt(
        source.invocationId,
        requestId: source.requestId,
      );
      final retry = await prepare(recovered!, summary: 'Created one image.');
      expect(retry.resultId, prepared.resultId);
      expect(
        retry.invocationReference.toJson(),
        prepared.invocationReference.toJson(),
      );
      final retried = await database.publishConversationUtterance(
        message(retry, turn: 'recovery-turn'),
        publication: retry,
      );
      expect(retried!.id, original!.id);
      expect(retried.turnId, 'turn-1');
      expect(await database.getMessages('self'), hasLength(1));
      expect(await media.read(retried.attachments.single), isNotNull);
      expect(
        await database.publishConversationUtterance(
          message(retry),
          publication: retry,
        ),
        isNull,
        reason: 'Recovery never unseals the original turn.',
      );
    },
  );

  test('recovery reuses staged wording and fixed output identities', () async {
    final source = await receipt();
    final first = await prepare(source, summary: 'Keep this exact wording.');
    final recovered = await results.prepareRecovery(
      invocationId: source.invocationId,
      requestId: source.requestId,
    );
    expect(recovered.summary, first.summary);
    expect(recovered.resultId, first.resultId);
    expect(
      recovered.invocationReference.toJson(),
      first.invocationReference.toJson(),
    );
    expect(recovered.attachments.single.id, first.attachments.single.id);
  });

  test(
    'completed journal receipt before staging can be received after a crash',
    () async {
      final source = await receipt();
      final first = await results.prepareRecovery(
        invocationId: source.invocationId,
        requestId: source.requestId,
      );
      expect(first.summary, contains('Any tool'));
      expect(
        first.invocationReference.status,
        AppInvocationChatStatus.completed,
      );
      final committed = await database.publishConversationUtterance(
        message(first),
        publication: first,
      );
      final second = await results.prepareRecovery(
        invocationId: source.invocationId,
        requestId: source.requestId,
      );
      final retry = await database.publishConversationUtterance(
        message(second, turn: 'recover-again'),
        publication: second,
      );
      expect(retry!.id, committed!.id);
      expect(second.summary, first.summary);
      expect(await database.getMessages('self'), hasLength(1));
    },
  );

  test('native result cannot move to another conversation session', () async {
    final prepared = await prepare(await receipt());
    final wrong = message(prepared)..sessionId = 'another-agent';
    await expectLater(
      database.publishConversationUtterance(wrong, publication: prepared),
      throwsStateError,
    );
    expect(await database.getMessages('another-agent'), isEmpty);
  });

  test(
    'native invocation source revocation inside commit rolls back the entire result',
    () async {
      final prepared = await prepare(await receipt(), summary: 'Done.');
      var sourceCurrent = true;
      database.afterCommit = () => sourceCurrent = false;
      final controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {},
        inputMergeWindow: Duration.zero,
        runChat: (context, history) async {
          context.bindInvocationOwnership(() => sourceCurrent);
          expect(
            () => context.bindInvocationOwnership(() => true),
            throwsStateError,
          );
          await context.deliverInvocationResult(prepared);
          return ExecutionResult.success('Done.');
        },
      );
      try {
        await controller.submit('Run tool', database: database).done;
        expect(
          (await database.getMessages(
            'self',
          )).where((row) => !row.isUserMessage),
          isEmpty,
        );
        expect(await media.read(prepared.attachments.single), isNull);
        expect(
          (await results.readResult(
            prepared.invocationId,
            prepared.resultId,
          ))!['state'],
          'collectingOutputs',
        );
      } finally {
        await controller.retireAndDrain();
      }
    },
  );

  test(
    'visible host/grant expiry during commit rolls back without recursive context guards',
    () async {
      final source = await receipt();
      var visible = true, baseWasCurrent = false;
      ConversationTurnContext? bound;
      final prepared = await results.prepare(
        receipt: source,
        sourceTitle: 'Any tool',
        summary: 'Done.',
        isOwnerCurrent: () => visible && (bound?.isCurrent ?? true),
      );
      database.afterCommit = () {
        visible = false;
        baseWasCurrent = bound!.isCurrent;
      };
      final controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {},
        inputMergeWindow: Duration.zero,
        runChat: (context, history) async {
          bound = context;
          await context.deliverInvocationResult(prepared);
          return ExecutionResult.success('Done.');
        },
      );
      try {
        await controller.submit('Run tool', database: database).done;
        expect(baseWasCurrent, isTrue);
        expect(prepared.isCurrent, isFalse);
        expect(
          (await database.getMessages(
            'self',
          )).where((row) => !row.isUserMessage),
          isEmpty,
        );
        expect(await media.read(prepared.attachments.single), isNull);
        expect(
          (await results.readResult(
            prepared.invocationId,
            prepared.resultId,
          ))!['state'],
          'collectingOutputs',
        );
      } finally {
        await controller.retireAndDrain();
      }
    },
  );

  test(
    'native final notice uses the existing queue and retains verified reference',
    () async {
      final source = await receipt();
      final ref = AppInvocationChatReference(
        scopeKey: 'account-A',
        sessionId: 'self',
        invocationId: source.invocationId,
        sourceId: source.identity.sourceId,
        revisionId: source.identity.revisionId,
        sourceDigest: source.identity.sourceDigest,
        contractDigest: source.contractDigest,
        sourceTitle: 'Any tool',
        status: AppInvocationChatStatus.resultUnavailable,
        requestId: source.requestId,
      );
      final controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {},
        inputMergeWindow: Duration.zero,
        runChat: (context, history) async {
          context.bindInvocationOwnership(() => true);
          await context.deliverInvocationNotice(
            text: 'Execution completed; result intake failed.',
            reference: ref,
            deliverUsing: (drafts) => context.deliverStream(drafts),
          );
          return ExecutionResult.success('notice');
        },
      );
      try {
        final outcome = await controller
            .submit(
              'Run tool',
              database: database,
              expectedAppletScopeKey: 'account-A',
            )
            .done;
        expect(outcome.execution.isSuccess, isTrue);
        final row = (await database.getMessages(
          'self',
        )).singleWhere((row) => !row.isUserMessage);
        expect(row.invocationReference!.toJson(), ref.toJson());
        expect(row.sequence, 0);
        expect(row.attachments, isEmpty);
      } finally {
        await controller.retireAndDrain();
      }
    },
  );

  test(
    'same result identity rejects changed summary/source/ordered bytes',
    () async {
      final source = await receipt();
      final prepared = await prepare(source, summary: 'Original');
      await database.publishConversationUtterance(
        message(prepared),
        publication: prepared,
      );
      await expectLater(
        prepare(source, summary: 'Different'),
        throwsStateError,
      );
      await expectLater(
        results.prepare(
          receipt: source,
          sourceTitle: 'Changed source',
          summary: 'Original',
        ),
        throwsStateError,
      );
      final forged = AppInvocationActionReceipt(
        invocationId: source.invocationId,
        requestId: source.requestId,
        actionId: source.actionId,
        identity: source.identity,
        contractDigest: source.contractDigest,
        status: source.status,
        stateVersion: source.stateVersion,
        result: source.result,
        outputs: [_png(color: 200)],
      );
      await expectLater(prepare(forged, summary: 'Original'), throwsStateError);
      expect(await database.getMessages('self'), hasLength(1));
    },
  );

  test(
    'invalid image keeps stable receiving identity and publishes no partial success',
    () async {
      final broken = AppInvocationProducedImage(
        producerOutputKey: 'bad-output',
        mime: 'image/png',
        bytes: Uint8List.fromList([1, 2, 3]),
      );
      final source = await receipt(outputs: [_png(), broken]);
      await expectLater(prepare(source), throwsFormatException);
      final staged = await stringMapStoreFactory
          .store('app_invocation_results.v1')
          .find(database.raw);
      expect(staged.single.value['state'], 'collectingOutputs');
      expect(
        await stringMapStoreFactory
            .store('app_invocation_output_ids.v1')
            .count(database.raw),
        2,
      );
      expect(
        await stringMapStoreFactory.store('chat_media.v1').count(database.raw),
        0,
      );
      expect(await database.getMessages('self'), isEmpty);
      await expectLater(prepare(source), throwsFormatException);
      expect(
        await stringMapStoreFactory
            .store('app_invocation_output_ids.v1')
            .count(database.raw),
        2,
      );
    },
  );

  test(
    'cancellation after media/receipt writes rolls back message and complete transaction',
    () async {
      final source = await receipt();
      final prepared = await prepare(source);
      var publish = true;
      final wrapper = _AfterCommit(prepared, () => publish = false);
      expect(
        await database.publishConversationUtterance(
          message(prepared),
          publication: wrapper,
          shouldContinue: () => publish,
        ),
        isNull,
      );
      expect(await database.getMessages('self'), isEmpty);
      expect(await media.read(prepared.attachments.single), isNull);
      expect(
        (await results.readResult(
          source.invocationId,
          prepared.resultId,
        ))!['state'],
        'collectingOutputs',
      );
      expect(
        (await journal.readRun(source.invocationId)).value['resultId'],
        isNull,
      );
    },
  );

  test(
    'deactivateAndDrain waits queued receipt reads before database shutdown',
    () async {
      final source = await receipt();
      final entered = Completer<void>(), release = Completer<void>();
      final blocker = database.raw.transaction((tx) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final preparing = prepare(source);
      final failure = expectLater(preparing, throwsStateError);
      var drained = false;
      final draining = results.deactivateAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      release.complete();
      await blocker;
      await failure;
      await draining;
      expect(drained, isTrue);
      expect(await database.getMessages('self'), isEmpty);
    },
  );

  test(
    'scope retirement fences prepared result without publishing bytes',
    () async {
      final source = await receipt();
      final prepared = await prepare(source);
      mount = 'mount-B';
      await expectLater(
        database.publishConversationUtterance(
          message(prepared),
          publication: prepared,
        ),
        throwsStateError,
      );
      expect(await database.getMessages('self'), isEmpty);
      expect(await media.read(prepared.attachments.single), isNull);
    },
  );

  test(
    'native result uses the existing Context coordinator and exact final draft once',
    () async {
      final prepared = await prepare(await receipt(), summary: 'Done.');
      var delegated = 0;
      final controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {},
        inputMergeWindow: Duration.zero,
        runChat: (context, history) async {
          await context.deliverInvocationResult(
            prepared,
            deliverUsing: (drafts) async {
              delegated++;
              await context.deliverStream(drafts);
            },
          );
          return ExecutionResult.success('Done.');
        },
      );
      try {
        final outcome = await controller
            .submit(
              'Run tool',
              database: database,
              expectedAppletScopeKey: 'account-A',
            )
            .done;
        expect(outcome.execution.isSuccess, isTrue);
        final rows = await database.getMessages('self');
        expect(rows, hasLength(2));
        expect(rows.last.attachments, hasLength(1));
        expect(rows.last.utteranceId, prepared.utteranceId);
        expect(rows.last.sequence, 0);
        expect(delegated, 1);
      } finally {
        await controller.retireAndDrain();
      }
    },
  );

  test(
    'a concurrent normal delivery cannot enter result draft validation',
    () async {
      final prepared = await prepare(await receipt(), summary: 'Done.');
      final stream = StreamController<ConversationUtteranceDraft>();
      final entered = Completer<void>();
      final controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {},
        inputMergeWindow: Duration.zero,
        runChat: (context, history) async {
          final delivery = context.deliverInvocationResult(
            prepared,
            deliverUsing: (_) {
              entered.complete();
              return context.deliverStream(stream.stream);
            },
          );
          await entered.future;
          await expectLater(
            context.deliver([ConversationUtteranceDraft(text: 'Conflicting')]),
            throwsStateError,
          );
          stream.add(ConversationUtteranceDraft(text: 'Done.'));
          await stream.close();
          await delivery;
          return ExecutionResult.success('Done.');
        },
      );
      try {
        final outcome = await controller
            .submit('Run tool', database: database)
            .done;
        expect(outcome.execution.isSuccess, isTrue);
        final rows = (await database.getMessages(
          'self',
        )).where((row) => !row.isUserMessage).toList();
        expect(rows, hasLength(1));
        expect(rows.single.content, 'Done.');
      } finally {
        await controller.retireAndDrain();
        await stream.close();
      }
    },
  );

  test(
    'extra persona draft cannot split one result into multiple messages',
    () async {
      final prepared = await prepare(await receipt(), summary: 'Done.');
      final controller = ConversationTurnController(
        agentId: 'self',
        isAvailable: () => true,
        stopOutput: () async {},
        inputMergeWindow: Duration.zero,
        runChat: (context, history) async {
          await context.deliverInvocationResult(
            prepared,
            deliverUsing: (_) => context.deliverStream(
              Stream.fromIterable([
                ConversationUtteranceDraft(text: 'Done.'),
                ConversationUtteranceDraft(text: 'Extra'),
              ]),
            ),
          );
          return ExecutionResult.success('Done.');
        },
      );
      try {
        final outcome = await controller
            .submit('Run tool', database: database)
            .done;
        expect(outcome.execution.isSuccess, isFalse);
        expect(
          (await database.getMessages(
            'self',
          )).where((row) => !row.isUserMessage),
          isEmpty,
        );
      } finally {
        await controller.retireAndDrain();
      }
    },
  );
}

AppInvocationProducedImage _png({int color = 50}) {
  final pixels = image.Image(width: 2, height: 2, numChannels: 4);
  pixels.setPixelRgba(0, 0, color, 100, 150, 0);
  pixels.setPixelRgba(1, 1, color, 20, 30, 255);
  return AppInvocationProducedImage(
    producerOutputKey: 'image-1',
    mime: 'image/png',
    bytes: Uint8List.fromList(image.encodePng(pixels)),
  );
}

class _AfterCommit implements ConversationPublicationTransaction {
  _AfterCommit(this.inner, this.after);
  final ConversationPublicationTransaction inner;
  final void Function() after;
  @override
  Future<T> trackPublication<T>(Future<T> Function() operation) =>
      inner.trackPublication(operation);
  @override
  bool usesDatabase(Database database) => inner.usesDatabase(database);
  @override
  Future<ChatMessage?> findExisting(Transaction tx, ChatMessage message) =>
      inner.findExisting(tx, message);
  @override
  Future<void> commit(
    Transaction tx,
    ChatMessage message, {
    required bool Function() mayPublish,
  }) async {
    await inner.commit(tx, message, mayPublish: mayPublish);
    after();
  }
}

class _PublicationDB extends DBService {
  void Function()? afterCommit;
  @override
  Future<ChatMessage?> publishConversationUtterance(
    ChatMessage message, {
    bool Function()? shouldContinue,
    ConversationPublicationTransaction? publication,
  }) => super.publishConversationUtterance(
    message,
    shouldContinue: shouldContinue,
    publication: publication == null || afterCommit == null
        ? publication
        : _AfterCommit(publication, afterCommit!),
  );
}
