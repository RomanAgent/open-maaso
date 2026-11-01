import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/features/agent/application/companion/agent_initiated_response.dart';

void main() {
  test('typed proactive response carries the durable commit identity', () {
    final committedAt = DateTime.utc(2026, 8, 26, 15, 30);
    final response = AgentInitiatedResponse(
      outreachId: 'outreach-1',
      sourceEventId: 'presence:milestone:1',
      topicKey: 'relationship-milestone',
      text: '今天值得记住。',
      committedAt: committedAt,
    );

    expect(response.outreachId, 'outreach-1');
    expect(response.sourceEventId, 'presence:milestone:1');
    expect(response.topicKey, 'relationship-milestone');
    expect(response.text, '今天值得记住。');
    expect(response.committedAt, committedAt);
    expect(response.turnOrigin, ChatMessageTurnOrigins.proactivePresence);
  });
}
