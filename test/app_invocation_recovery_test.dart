import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_result_store.dart';
import 'package:sembast/sembast.dart';

import 'support/app_invocation_recovery_fixture.dart';

void main() {
  late InvocationRecoveryFixture f;
  InvocationRecoveryFixture? ownedFixture;
  setUp(() => ownedFixture = null);
  tearDown(() async => ownedFixture?.close());
  Future<InvocationRecoveryFixture> create({
    bool completed = true,
    bool action = true,
    bool withImage = false,
    bool persistImage = true,
  }) async {
    final created = await InvocationRecoveryFixture.create(
      completed: completed,
      action: action,
      withImage: withImage,
      persistImage: persistImage,
    );
    ownedFixture = created;
    return created;
  }

  test(
    'message metadata roundtrips without becoming model context or authority',
    () async {
      f = await create();
      final message = ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: 'Visible result',
        timestamp: DateTime.utc(2026),
        turnOrigin: 'user',
        invocationReference: f.reference,
      );
      final restored = ChatMessage.fromJson(message.toJson());
      expect(restored.invocationReference!.toJson(), f.reference.toJson());
      expect(restored.isModelContextEligible, isTrue);
      expect(restored.modelContextText, 'Visible result');
      expect(
        AppInvocationChatReference.tryParse({
          ...f.reference.toJson(),
          'grant': true,
        }),
        isNull,
      );
      expect(
        AppInvocationChatReference.tryParse({
          ...f.reference.toJson(),
          'sourceDigest': '../bad',
        }),
        isNull,
      );
      expect(
        ChatMessage.fromJson({
          ...message.toJson(),
          'invocationReference': {'schemaVersion': 99},
        }).invocationReference,
        isNull,
      );
    },
  );

  test(
    'forged source, title, request, account and session claims fail journal checks',
    () async {
      f = await create();
      for (final change in [
        {'sourceId': 'different'},
        {'sourceTitle': 'Forged title'},
        {'requestId': 'different-request'},
        {'scopeKey': 'other-account'},
        {'sessionId': 'other-session'},
        {'contractDigest': '0' * 64},
      ]) {
        await expectLater(
          f.recovery.inspect(f.altered(change), sessionId: 'self'),
          throwsStateError,
        );
      }
      final view = await f.recovery.inspect(f.reference, sessionId: 'self');
      expect(view.status, AppInvocationChatStatus.resultUnavailable);
      expect(view.canFetchResult, isTrue);
      expect(view.canRestoreDraft, isTrue);
    },
  );

  test(
    'unknown recovery only reads original request and never reserves another action',
    () async {
      f = await create(completed: false);
      final input = await f.recovery.prepareRecovery(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      expect(await input.loadResult(), isNull);
      await f.restartProcess();
      final restored = await f.recovery.prepareRecovery(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      expect(await restored.loadResult(), isNull);
      expect(
        (await f.recovery.inspect(f.reference, sessionId: 'self')).status,
        AppInvocationChatStatus.outcomeUnknown,
      );
      expect(
        await stringMapStoreFactory
            .store('app_invocation_actions.v1')
            .count(f.database.raw),
        1,
      );
      final asserted = await f.recovery.referenceForInvocation(
        invocationId: f.run.invocationId,
        sessionId: 'self',
        requestId: 'request-1',
        status: AppInvocationChatStatus.completed,
      );
      expect(asserted!.status, AppInvocationChatStatus.outcomeUnknown);
    },
  );

  test(
    'completed receipt recovers after process restart and publication reuses original message',
    () async {
      f = await create();
      await f.restartProcess();
      final input = await f.recovery.prepareRecovery(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      final result = (await input.loadResult())!;
      ChatMessage message(PreparedInvocationResult prepared, String turn) =>
          ChatMessage(
            sessionId: 'self',
            senderId: 'self',
            receiverId: 'user',
            content: prepared.summary,
            timestamp: DateTime.utc(2026),
            turnOrigin: 'user',
            turnId: turn,
            utteranceId: prepared.utteranceId,
            sequence: 0,
            deliveryStatus: 'published',
            attachments: prepared.attachments,
            invocationReference: prepared.invocationReference,
            idempotencyKey: prepared.idempotencyKey,
          );
      final original = await f.database.publishConversationUtterance(
        message(result, 'recovery-1'),
        publication: result,
      );
      await f.database.sealConversationTurn(
        sessionId: 'self',
        turnId: 'recovery-1',
      );
      final retry = (await input.loadResult())!;
      final existing = await f.database.publishConversationUtterance(
        message(retry, 'recovery-2'),
        publication: retry,
      );
      expect(existing!.id, original!.id);
      expect(existing.turnId, 'recovery-1');
      expect((await f.database.getMessages('self')), hasLength(1));
      expect(
        await stringMapStoreFactory
            .store('app_invocation_actions.v1')
            .count(f.database.raw),
        1,
      );
    },
  );

  test(
    'draft restores original PNG bytes, preview and exact source without executing',
    () async {
      f = await create(withImage: true);
      final original = f.originalSource;
      final draft = await f.recovery.loadDraft(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      expect(draft.text, f.snapshot.text);
      expect(
        draft.selection!.identity.sourceDigest,
        f.descriptor.identity.sourceDigest,
      );
      expect(draft.images.single.bytes, f.inputImage!.bytes);
      expect(draft.images.single.mime, 'image/png');
      expect(draft.images.single.attachment.thumbnailJpeg, isNotEmpty);
      expect(f.originalSource, original);
      expect(
        await stringMapStoreFactory
            .store('app_invocation_actions.v1')
            .count(f.database.raw),
        1,
      );
    },
  );

  test(
    'missing or changed source preserves draft but cannot silently select another version',
    () async {
      f = await create();
      f.widget.spec['js'] = 'void 1;';
      final draft = await f.recovery.loadDraft(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      expect(draft.text, f.snapshot.text);
      expect(draft.selection, isNull);
      expect(draft.sourceUnavailable, isTrue);
      final input = await f.recovery.prepareRecovery(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      expect(await input.loadResult(), isNotNull);
    },
  );

  test(
    'missing image fails the whole draft restore without fabricating a thumbnail',
    () async {
      f = await create(withImage: true, persistImage: false);
      await expectLater(
        f.recovery.loadDraft(
          f.reference,
          sessionId: 'self',
          isOwnerCurrent: () => true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'failure before any action still restores the journaled input but offers no receipt query',
    () async {
      f = await create(action: false);
      final view = await f.recovery.inspect(f.reference, sessionId: 'self');
      expect(view.status, AppInvocationChatStatus.failed);
      expect(view.canFetchResult, isFalse);
      expect(view.canRestoreDraft, isTrue);
      expect(
        (await f.recovery.loadDraft(
          f.reference,
          sessionId: 'self',
          isOwnerCurrent: () => true,
        )).text,
        f.snapshot.text,
      );
    },
  );

  test(
    'account retirement revokes already prepared recovery handles',
    () async {
      f = await create();
      final input = await f.recovery.prepareRecovery(
        f.reference,
        sessionId: 'self',
        isOwnerCurrent: () => true,
      );
      f.mount = 'mount-2';
      expect(input.isCurrent, isFalse);
      await expectLater(input.loadResult(), throwsStateError);
      await expectLater(
        f.recovery.inspect(f.reference, sessionId: 'self'),
        throwsStateError,
      );
    },
  );

  test(
    'drain waits for source lookup and a cancelled draft never reaches a new owner',
    () async {
      f = await create();
      final entered = Completer<void>(),
          source = Completer<List<AgentWidget>>();
      f.onLoadLocal = () {
        entered.complete();
        return source.future;
      };
      final loading = expectLater(
        f.recovery.loadDraft(
          f.reference,
          sessionId: 'self',
          isOwnerCurrent: () => true,
        ),
        throwsStateError,
      );
      await entered.future;
      var drained = false;
      final drain = f.recovery.deactivateAndDrain().then((_) => drained = true);
      await Future<void>.delayed(Duration.zero);
      expect(drained, isFalse);
      source.complete(f.locals);
      await loading;
      await drain;
      expect(drained, isTrue);
      expect(await f.database.getMessages('self'), isEmpty);
    },
  );
}
