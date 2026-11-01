import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';

void main() {
  ChatMessage message({
    bool isUserMessage = false,
    String content = 'hello',
    String? turnOrigin,
    String? idempotencyKey,
    String? outreachId,
  }) => ChatMessage(
    id: 7,
    sessionId: 'self',
    senderId: isUserMessage ? 'user' : 'self',
    receiverId: isUserMessage ? 'self' : 'user',
    content: content,
    timestamp: DateTime.utc(2026, 8, 26, 12, 30),
    isUserMessage: isUserMessage,
    turnOrigin: turnOrigin,
    idempotencyKey: idempotencyKey,
    outreachId: outreachId,
  );

  test(
    'optional provenance fields round-trip without changing legacy shape',
    () {
      final original = message(
        turnOrigin: ChatMessageTurnOrigins.proactivePresence,
        idempotencyKey: 'message:outreach-1',
        outreachId: 'outreach-1',
      );

      final encoded = original.toJson();
      final decoded = ChatMessage.fromJson(encoded, id: original.id);

      expect(decoded.id, original.id);
      expect(decoded.turnOrigin, ChatMessageTurnOrigins.proactivePresence);
      expect(decoded.idempotencyKey, 'message:outreach-1');
      expect(decoded.outreachId, 'outreach-1');
      expect(decoded.isModelContextEligible, isFalse);

      final legacyShape = message().toJson();
      expect(legacyShape, isNot(contains('turnOrigin')));
      expect(legacyShape, isNot(contains('idempotencyKey')));
      expect(legacyShape, isNot(contains('outreachId')));
    },
  );

  test('fromJson tolerates absent blank and non-string optional fields', () {
    final decoded = ChatMessage.fromJson(<String, Object?>{
      'sessionId': 'self',
      'senderId': 'self',
      'receiverId': 'user',
      'content': 'legacy reply',
      'timestamp': DateTime.utc(2026, 8, 26).toIso8601String(),
      'isUserMessage': false,
      'turnOrigin': '  ',
      'idempotencyKey': 42,
      'outreachId': null,
    });

    expect(decoded.turnOrigin, isNull);
    expect(decoded.idempotencyKey, isNull);
    expect(decoded.outreachId, isNull);
    expect(decoded.isModelContextEligible, isTrue);
  });

  test('all known origins have explicit model-context eligibility', () {
    final expected = <String, bool>{
      ChatMessageTurnOrigins.user: true,
      ChatMessageTurnOrigins.voice: true,
      ChatMessageTurnOrigins.proactivePresence: false,
      ChatMessageTurnOrigins.notificationInteraction: false,
      ChatMessageTurnOrigins.system: false,
      ChatMessageTurnOrigins.followUp: false,
      ChatMessageTurnOrigins.live: false,
    };

    expect(ChatMessageTurnOrigins.known.toSet(), expected.keys.toSet());
    for (final entry in expected.entries) {
      expect(
        message(turnOrigin: entry.key).isModelContextEligible,
        entry.value,
        reason: 'assistant message origin=${entry.key}',
      );
      expect(
        message(
          isUserMessage: true,
          turnOrigin: entry.key,
        ).isModelContextEligible,
        entry.value,
        reason: 'user-side message origin=${entry.key}',
      );
    }
  });

  test('unknown explicit origin fails closed', () {
    expect(
      message(turnOrigin: 'futureSyntheticOrigin').isModelContextEligible,
      isFalse,
    );
    expect(
      message(
        isUserMessage: true,
        turnOrigin: 'futureSyntheticOrigin',
      ).isModelContextEligible,
      isFalse,
    );
  });

  test('legacy messages preserve history except for proactive seed marker', () {
    expect(message(isUserMessage: true).isModelContextEligible, isTrue);
    expect(
      message(content: 'ordinary assistant reply').isModelContextEligible,
      isTrue,
    );
    expect(
      message(content: '  🌱 old proactive reply').isModelContextEligible,
      isFalse,
    );
    expect(
      message(
        content: '🌱old text without marker space',
      ).isModelContextEligible,
      isTrue,
    );
  });

  test('model context filters synthetic rows before taking the tail', () {
    final rows = <ChatMessage>[
      message(content: 'old user', isUserMessage: true),
      message(content: 'old reply'),
      message(
        content: 'synthetic one',
        turnOrigin: ChatMessageTurnOrigins.proactivePresence,
      ),
      message(
        content: 'synthetic two',
        turnOrigin: ChatMessageTurnOrigins.system,
      ),
      message(content: 'new user', isUserMessage: true),
      message(content: 'new reply'),
    ];

    expect(
      modelContextTail(rows, limit: 4).map((item) => item.content),
      <String>['old user', 'old reply', 'new user', 'new reply'],
    );
    expect(modelContextTail(rows, limit: 0), isEmpty);
  });
}
