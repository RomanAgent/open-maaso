import 'package:maaso/src/core/models/chat_message.dart';

/// A fully committed agent-initiated message that is safe for UI delivery.
///
/// Instances are created only after the outreach ledger has atomically stored
/// the matching [ChatMessage]. UI subscribers must render this event but must
/// never persist it a second time.
final class AgentInitiatedResponse {
  const AgentInitiatedResponse({
    required this.outreachId,
    required this.topicKey,
    required this.text,
    required this.committedAt,
    this.sourceEventId,
    this.turnOrigin = ChatMessageTurnOrigins.proactivePresence,
  });

  final String outreachId;
  final String? sourceEventId;
  final String topicKey;
  final String text;
  final DateTime committedAt;
  final String turnOrigin;
}
