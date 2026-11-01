import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late DBService database;
  var serial = 0;
  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'publication-payload-${serial++}.db',
    );
  });
  tearDown(() => database.close());
  ChatMessage message({
    String text = 'Result',
    List<ChatAttachment> attachments = const [],
    AppletChatReference? reference,
  }) => ChatMessage(
    sessionId: 'self',
    senderId: 'self',
    receiverId: 'user',
    content: text,
    timestamp: DateTime.now(),
    turnOrigin: 'user',
    turnId: 'turn',
    utteranceId: 'unit',
    sequence: 0,
    deliveryStatus: 'published',
    attachments: attachments,
    appletReference: reference,
  );
  ChatAttachment attachment(String id) =>
      ChatAttachment(id: id * 64, kind: 'image', byteLength: 1);
  AppletChatReference reference(Map<String, Object?> args) =>
      AppletChatReference(
        id: 'work',
        title: 'Tool',
        scopeKey: 'account',
        revision: 1,
        sourceSha256: 'a' * 64,
        actions: [
          {'name': 'custom.run', 'arguments': args},
        ],
      );

  test(
    'structurally equal attachments/cards deduplicate despite map insertion order',
    () async {
      final one = await database.publishConversationUtterance(
        message(
          attachments: [attachment('a')],
          reference: reference({
            'x': 1,
            'y': [2, 3],
          }),
        ),
      );
      final two = await database.publishConversationUtterance(
        message(
          attachments: [attachment('a')],
          reference: reference({
            'y': [2, 3],
            'x': 1,
          }),
        ),
      );
      expect(two!.id, one!.id);
      expect(await database.getMessages('self'), hasLength(1));
    },
  );
  test(
    'same turn identity with different attachment order/hash or card arguments conflicts',
    () async {
      await database.publishConversationUtterance(
        message(
          attachments: [attachment('a'), attachment('b')],
          reference: reference({'x': 1}),
        ),
      );
      await expectLater(
        database.publishConversationUtterance(
          message(
            attachments: [attachment('b'), attachment('a')],
            reference: reference({'x': 1}),
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        database.publishConversationUtterance(
          message(
            attachments: [attachment('a'), attachment('c')],
            reference: reference({'x': 1}),
          ),
        ),
        throwsStateError,
      );
      await expectLater(
        database.publishConversationUtterance(
          message(
            attachments: [attachment('a'), attachment('b')],
            reference: reference({'x': 2}),
          ),
        ),
        throwsStateError,
      );
    },
  );
  test(
    'same utterance cannot change its invocation origin or status',
    () async {
      AppInvocationChatReference reference(AppInvocationChatStatus status) =>
          AppInvocationChatReference(
            scopeKey: 'account',
            sessionId: 'self',
            invocationId: 'invoke-1',
            sourceId: 'work',
            revisionId: 'v1',
            sourceDigest: 'a' * 64,
            contractDigest: 'b' * 64,
            sourceTitle: 'Tool',
            status: status,
            requestId: 'req-1',
          );
      final first = message()
        ..invocationReference = reference(AppInvocationChatStatus.failed);
      await database.publishConversationUtterance(first);
      final retry = message()
        ..invocationReference = reference(
          AppInvocationChatStatus.outcomeUnknown,
        );
      await expectLater(
        database.publishConversationUtterance(retry),
        throwsStateError,
      );
    },
  );

  test(
    'media-only publication is legal but empty payload is rejected',
    () async {
      await expectLater(
        database.publishConversationUtterance(message(text: '')),
        throwsArgumentError,
      );
      final published = await database.publishConversationUtterance(
        message(text: '', attachments: [attachment('a')]),
      );
      expect(published!.content, '');
      expect(published.attachments, hasLength(1));
    },
  );
}
