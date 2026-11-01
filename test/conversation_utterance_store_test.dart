import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late DBService database;

  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'utterances-${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });
  tearDown(() => database.close());

  test('utterance metadata round-trips and legacy rows keep their shape', () {
    final original = _utterance('published words');
    final decoded = ChatMessage.fromJson(original.toJson());

    expect(decoded.turnId, 'turn-1');
    expect(decoded.utteranceId, 'utterance-0');
    expect(decoded.sequence, 0);
    expect(decoded.deliveryStatus, 'published');
    expect(decoded.isModelContextEligible, isTrue);

    final legacy = _utterance('legacy', withMetadata: false);
    final encoded = legacy.toJson();
    for (final field in [
      'turnId',
      'utteranceId',
      'sequence',
      'deliveryStatus',
    ]) {
      expect(encoded, isNot(contains(field)));
    }
    final legacyDecoded = ChatMessage.fromJson(encoded);
    expect(legacyDecoded.turnId, isNull);
    expect(legacyDecoded.utteranceId, isNull);
    expect(legacyDecoded.sequence, isNull);
    expect(legacyDecoded.deliveryStatus, isNull);
    expect(legacyDecoded.isModelContextEligible, isTrue);
  });

  test('published and interrupted text are eligible but drafts are not', () {
    for (final status in ['published', 'interrupted']) {
      expect(
        _utterance('visible', deliveryStatus: status).isModelContextEligible,
        isTrue,
      );
    }
    for (final status in ['draft', 'queued', 'future_status']) {
      expect(
        _utterance(
          'not delivered',
          deliveryStatus: status,
        ).isModelContextEligible,
        isFalse,
      );
    }
    final synthetic = _utterance('synthetic')
      ..turnOrigin = ChatMessageTurnOrigins.proactivePresence;
    expect(synthetic.isModelContextEligible, isFalse);
  });

  test(
    'publication returns a durable message without changing save semantics',
    () async {
      final stored = await database.publishConversationUtterance(
        _utterance('today, let me think'),
      );

      expect(stored, isNotNull);
      expect(stored!.id, isNotNull);
      expect(stored.content, 'today, let me think');
      expect(stored.deliveryStatus, 'published');
      expect((await database.getMessages('self')).single.id, stored.id);

      final ordinary = _utterance('ordinary', withMetadata: false);
      final first = await database.saveChatMessage(ordinary);
      final second = await database.saveChatMessage(ordinary);
      expect(first, isNot(second));
      expect(await database.getMessages('self'), hasLength(3));
    },
  );

  test(
    'concurrent duplicate publication returns the same record once',
    () async {
      final results = await Future.wait([
        database.publishConversationUtterance(_utterance('pork knuckle rice?')),
        database.publishConversationUtterance(_utterance('pork knuckle rice?')),
        database.publishConversationUtterance(_utterance('pork knuckle rice?')),
      ]);

      expect(results.every((message) => message != null), isTrue);
      expect(results.map((message) => message!.id).toSet(), hasLength(1));
      expect(await database.getMessages('self'), hasLength(1));
    },
  );

  test(
    'same utterance identity cannot replace committed content or sequence',
    () async {
      final original = await database.publishConversationUtterance(
        _utterance('first answer'),
      );

      await expectLater(
        database.publishConversationUtterance(_utterance('changed answer')),
        throwsStateError,
      );
      await expectLater(
        database.publishConversationUtterance(
          _utterance('first answer', sequence: 1),
        ),
        throwsStateError,
      );
      final rows = await database.getMessages('self');
      expect(rows, hasLength(1));
      expect(rows.single.id, original!.id);
      expect(rows.single.content, 'first answer');
      expect(rows.single.sequence, 0);
    },
  );

  test('different utterance identities may publish identical text', () async {
    await database.publishConversationUtterance(_utterance('hmm'));
    await database.publishConversationUtterance(
      _utterance('hmm', utteranceId: 'utterance-1', sequence: 1),
    );

    final rows = await database.getMessages('self');
    expect(rows.map((message) => message.content), ['hmm', 'hmm']);
    expect(rows.map((message) => message.id).toSet(), hasLength(2));
    expect(rows.map((message) => message.sequence), [0, 1]);
  });

  test('a later retry retains the original timestamp and record', () async {
    final original = await database.publishConversationUtterance(
      _utterance('same delivered text'),
    );
    final retry = _utterance('same delivered text')
      ..timestamp = DateTime.utc(2026, 9, 4);
    final stored = await database.publishConversationUtterance(retry);

    expect(stored!.id, original!.id);
    expect(stored.timestamp, original.timestamp);
    expect(await database.getMessages('self'), hasLength(1));
  });

  test('publication rejects invisible text and incomplete metadata', () async {
    final invalid = [
      _utterance('legacy cannot use publication', withMetadata: false),
      _utterance('not visible', deliveryStatus: 'queued'),
      _utterance('a user message', user: true),
      _utterance('invalid sequence', sequence: -1),
      _utterance('missing turn')..turnId = null,
      _utterance('missing utterance')..utteranceId = null,
      _utterance('   '),
    ];
    for (final message in invalid) {
      await expectLater(
        database.publishConversationUtterance(message),
        throwsArgumentError,
      );
    }
    expect(await database.getMessages('self'), isEmpty);
  });

  test(
    'seal is idempotent and rejects new and duplicate publications',
    () async {
      final original = await database.publishConversationUtterance(
        _utterance('already visible'),
      );
      await database.sealConversationTurn(sessionId: 'self', turnId: 'turn-1');
      await database.sealConversationTurn(sessionId: 'self', turnId: 'turn-1');

      expect(
        await database.publishConversationUtterance(
          _utterance('already visible'),
        ),
        isNull,
      );
      expect(
        await database.publishConversationUtterance(
          _utterance('late words', utteranceId: 'utterance-1', sequence: 1),
        ),
        isNull,
      );
      final rows = await database.getMessages('self');
      expect(rows, hasLength(1));
      expect(rows.single.id, original!.id);
    },
  );

  test('session and turn boundaries isolate identities and seals', () async {
    await database.sealConversationTurn(sessionId: 'self', turnId: 'turn-1');
    final otherSession = await database.publishConversationUtterance(
      _utterance('other session', sessionId: 'peer'),
    );
    final otherTurn = await database.publishConversationUtterance(
      _utterance('new turn', turnId: 'turn-2'),
    );

    expect(otherSession, isNotNull);
    expect(otherTurn, isNotNull);
    expect(
      (await database.getMessages('peer')).single.content,
      'other session',
    );
    expect((await database.getMessages('self')).single.content, 'new turn');
  });

  test(
    'a seal remains effective after reopening the account database',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'maaso-utterance-',
      );
      DBService? persistent;
      try {
        final path = '${directory.path}/conversation.db';
        persistent = await DBService().init(
          factory: databaseFactoryIo,
          path: path,
        );
        await persistent.sealConversationTurn(
          sessionId: 'self',
          turnId: 'turn-1',
        );
        await persistent.close();
        persistent = await DBService().init(
          factory: databaseFactoryIo,
          path: path,
        );

        expect(
          await persistent.publishConversationUtterance(
            _utterance('stale retry'),
          ),
          isNull,
        );
        expect(await persistent.getMessages('self'), isEmpty);
      } finally {
        await persistent?.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('cancellation before admission leaves no message', () async {
    expect(
      await database.publishConversationUtterance(
        _utterance('cancelled'),
        shouldContinue: () => false,
      ),
      isNull,
    );
    expect(await database.getMessages('self'), isEmpty);
  });

  test(
    'cancellation while awaiting the transaction is checked again',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = database.raw.transaction((transaction) async {
        entered.complete();
        await release.future;
      });
      await entered.future;

      var active = true;
      final publication = database.publishConversationUtterance(
        _utterance('must not be committed'),
        shouldContinue: () => active,
      );
      active = false;
      release.complete();
      await blocker;

      expect(await publication, isNull);
      expect(await database.getMessages('self'), isEmpty);
    },
  );

  test('cancellation during the store append rolls back the write', () async {
    var active = true;
    var sawPendingWrite = false;
    final messages = intMapStoreFactory.store('chat_messages');
    messages.addOnChangesListener(database.raw, (transaction, changes) {
      sawPendingWrite = true;
      active = false;
    });

    final stored = await database.publishConversationUtterance(
      _utterance('must roll back'),
      shouldContinue: () => active,
    );

    expect(sawPendingWrite, isTrue);
    expect(stored, isNull);
    expect(await database.getMessages('self'), isEmpty);
  });

  test('a storage failure propagates and leaves no visible row', () async {
    final failure = StateError('injected store failure');
    final messages = intMapStoreFactory.store('chat_messages');
    messages.addOnChangesListener(database.raw, (transaction, changes) {
      throw failure;
    });

    await expectLater(
      database.publishConversationUtterance(_utterance('failed commit')),
      throwsA(same(failure)),
    );
    expect(await database.getMessages('self'), isEmpty);
  });

  test('publication snapshots mutable input before awaiting storage', () async {
    final original = _utterance('original visible text');
    final pending = database.publishConversationUtterance(original);
    original.content = 'mutated while storage was pending';
    original.utteranceId = 'mutated-id';

    final stored = await pending;
    expect(stored!.content, 'original visible text');
    expect(stored.utteranceId, 'utterance-0');
    expect(
      (await database.getMessages('self')).single.content,
      'original visible text',
    );
  });

  test('a seal queued before publication rejects it atomically', () async {
    final sealing = database.sealConversationTurn(
      sessionId: 'self',
      turnId: 'turn-1',
    );
    final publishing = database.publishConversationUtterance(
      _utterance('too late'),
    );
    await sealing;

    expect(await publishing, isNull);
    expect(await database.getMessages('self'), isEmpty);
  });

  test('history keeps every adjacent utterance of selected logical turns', () {
    final rows = [
      _utterance('legacy one', withMetadata: false),
      _utterance('legacy two', withMetadata: false),
      _utterance('what should we eat?', user: true),
      _utterance('today, let me think'),
      _utterance('pork knuckle rice?', utteranceId: 'utterance-1', sequence: 1),
      _utterance(
        'or whatever you prefer',
        utteranceId: 'utterance-2',
        sequence: 2,
      ),
      _utterance('actually, noodles', user: true, turnId: 'turn-2'),
    ];

    expect(modelContextTail(rows, limit: 2).map((message) => message.content), [
      'what should we eat?',
      'today, let me think',
      'pork knuckle rice?',
      'or whatever you prefer',
      'actually, noodles',
    ]);
    expect(
      modelContextTail(rows, limit: 1).single.content,
      'actually, noodles',
    );
    expect(modelContextTail(rows, limit: 0), isEmpty);
  });

  test('history groups only adjacent rows within the same session', () {
    final rows = [
      _utterance('first self row', user: true),
      _utterance('peer question', sessionId: 'peer', user: true),
      _utterance('peer answer', sessionId: 'peer'),
      _utterance('later self row', utteranceId: 'utterance-1', sequence: 1),
    ];

    expect(modelContextTail(rows, limit: 2).map((message) => message.content), [
      'peer question',
      'peer answer',
      'later self row',
    ]);
    expect(modelContextTail(rows, limit: 1).single.content, 'later self row');
  });

  test('legacy history limits and role ordering remain unchanged', () {
    final rows = [
      _utterance('one', user: true, withMetadata: false),
      _utterance('two', user: true, withMetadata: false),
      _utterance('three', withMetadata: false),
      _utterance('four', withMetadata: false),
    ];

    final tail = modelContextTail(rows, limit: 3);
    expect(tail.map((message) => message.content), ['two', 'three', 'four']);
    expect(tail.map((message) => message.isUserMessage), [true, false, false]);
  });

  test(
    'history excludes unpublished content before selecting logical turns',
    () {
      final rows = [
        _utterance('question', user: true),
        _utterance('visible prefix', deliveryStatus: 'interrupted'),
        _utterance(
          'never published',
          utteranceId: 'utterance-1',
          sequence: 1,
          deliveryStatus: 'queued',
        ),
        _utterance('newer draft', turnId: 'turn-2', deliveryStatus: 'draft'),
      ];

      expect(
        modelContextTail(rows, limit: 1).map((message) => message.content),
        ['question', 'visible prefix'],
      );
    },
  );
}

ChatMessage _utterance(
  String content, {
  String sessionId = 'self',
  String turnId = 'turn-1',
  String utteranceId = 'utterance-0',
  int sequence = 0,
  String deliveryStatus = 'published',
  bool user = false,
  bool withMetadata = true,
}) => ChatMessage(
  sessionId: sessionId,
  senderId: user ? 'user' : sessionId,
  receiverId: user ? sessionId : 'user',
  content: content,
  timestamp: DateTime.utc(2026, 9, 3, 12).add(Duration(seconds: sequence)),
  isUserMessage: user,
  turnOrigin: ChatMessageTurnOrigins.user,
  turnId: withMetadata ? turnId : null,
  utteranceId: withMetadata && !user ? utteranceId : null,
  sequence: withMetadata && !user ? sequence : null,
  deliveryStatus: withMetadata && !user ? deliveryStatus : null,
);
