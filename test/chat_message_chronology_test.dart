import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  late DBService database;
  final messages = intMapStoreFactory.store('chat_messages');

  setUp(() async {
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'chat-chronology-${DateTime.now().microsecondsSinceEpoch}.db',
    );
  });
  tearDown(() async => database.close());

  test(
    'new local and UTC messages persist the same unambiguous instant',
    () async {
      final local = DateTime(2026, 9, 3, 10, 56, 12, 345, 678);
      final localMessage = _message('local reply', local);
      final utcMessage = _message('UTC reply', local.toUtc());
      final localId = await database.saveChatMessage(localMessage);
      final utcId = await database.saveChatMessage(utcMessage);
      final localRaw = (await messages.record(localId).get(database.raw))!;
      final utcRaw = (await messages.record(utcId).get(database.raw))!;

      expect(localRaw['timestamp'], utcRaw['timestamp']);
      expect(localRaw['timestamp'], endsWith('Z'));
      expect(
        DateTime.parse(localRaw['timestamp'] as String).isAtSameMomentAs(local),
        isTrue,
      );
      expect(
        ChatMessage.fromJson(localRaw).timestamp.isAtSameMomentAs(local),
        isTrue,
      );
      expect(localMessage.timestamp, local);
    },
  );

  test(
    'legacy mixed timestamps sort by instant before recent history is selected',
    () async {
      final firstUser = DateTime.utc(2026, 9, 3, 2, 53);
      final firstReply = firstUser.add(const Duration(seconds: 2));
      final rawRows = [
        _row('question one', firstUser.toIso8601String(), user: true),
        _row('answer one', firstReply.toLocal().toIso8601String()),
        _row('question two', '2026-09-03T02:56:00.000Z', user: true),
        _row('answer two', '2026-09-03T10:56:02.000+08:00'),
      ];
      for (final row in rawRows) {
        await messages.add(database.raw, row);
      }
      await messages.add(database.raw, {
        ..._row('another session', '2026-09-04T12:00:00.000Z'),
        'sessionId': 'other',
      });
      final before = await messages.find(database.raw);

      final recent = await database.getRecentMessages('self', limit: 2);
      final all = await database.getMessages('self');
      expect(all.map((message) => message.content), [
        'question one',
        'answer one',
        'question two',
        'answer two',
      ]);
      expect(recent.map((message) => message.content), [
        'question two',
        'answer two',
      ]);
      expect(
        modelContextTail(all, limit: 3).map((message) => message.content),
        ['answer one', 'question two', 'answer two'],
      );
      final after = await messages.find(database.raw);
      expect(
        after.map((record) => record.value),
        before.map((record) => record.value),
      );
      expect(await database.getRecentMessages('self', limit: 0), isEmpty);
    },
  );

  test(
    'equal instants use record order and retain consecutive messages from one role',
    () async {
      final rows = [
        _row('first user', '2026-09-03T10:56:00+08:00', user: true),
        _row('second user', '2026-09-03T02:56:00.000Z', user: true),
        _row('reply', '2026-09-03T02:56:00.000001Z'),
        _row('follow-up reply', '2026-09-03T02:56:01Z'),
      ];
      for (final row in rows) {
        await messages.add(database.raw, row);
      }
      final all = await database.getMessages('self');
      expect(all.map((message) => message.content), [
        'first user',
        'second user',
        'reply',
        'follow-up reply',
      ]);
      expect(all.map((message) => message.isUserMessage), [
        true,
        true,
        false,
        false,
      ]);
      for (var limit = 1; limit <= rows.length; limit++) {
        final recent = await database.getRecentMessages('self', limit: limit);
        expect(
          recent.map((message) => message.id),
          all.skip(all.length - limit).map((message) => message.id),
        );
      }
    },
  );

  test(
    'missing and malformed legacy timestamps remain readable without sort exceptions',
    () async {
      await messages.add(database.raw, _row('invalid', 'not-a-timestamp'));
      final missing = _row('missing', '')..remove('timestamp');
      await messages.add(database.raw, missing);
      await messages.add(database.raw, _row('valid', '2026-09-03T02:56:00Z'));

      final all = await database.getMessages('self');
      final recent = await database.getRecentMessages('self', limit: 3);
      expect(all, hasLength(3));
      expect(
        recent.map((message) => message.id),
        all.map((message) => message.id),
      );
      expect(
        all
            .where((message) => message.content != 'valid')
            .every(
              (message) =>
                  message.timestamp.difference(DateTime.now()).abs() <
                  const Duration(seconds: 5),
            ),
        isTrue,
      );
    },
  );
}

ChatMessage _message(String content, DateTime timestamp, {bool user = false}) =>
    ChatMessage(
      sessionId: 'self',
      senderId: user ? 'user' : 'self',
      receiverId: user ? 'self' : 'user',
      content: content,
      timestamp: timestamp,
      isUserMessage: user,
    );

Map<String, Object?> _row(
  String content,
  String timestamp, {
  bool user = false,
}) => {
  ..._message(content, DateTime.utc(2026), user: user).toJson(),
  'timestamp': timestamp,
};
