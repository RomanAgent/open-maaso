import 'dart:math';

enum ContentConsumptionKind { game, applet }

class ContentConsumptionTarget {
  const ContentConsumptionTarget(this.kind, this.contentId);
  final ContentConsumptionKind kind;
  final String contentId;
}

class ContentConsumptionSession {
  const ContentConsumptionSession({
    required this.sessionId,
    required this.sequence,
    required this.state,
    required this.activeMillis,
    required this.expiresAt,
  });
  final String sessionId;
  final int sequence;
  final String state;
  final int activeMillis;
  final DateTime expiresAt;
}

abstract interface class ContentEngagementGateway {
  String get contextKey;
  Future<ContentConsumptionSession> start(
    ContentConsumptionTarget target,
    String requestId,
  );
  Future<ContentConsumptionSession> pulse(
    String sessionId,
    int sequence,
    String event,
    int progress,
  );
  Future<ContentConsumptionSession> finish(String sessionId, int sequence);
}

class ContentEngagementException implements Exception {
  const ContentEngagementException(this.code);
  final String code;
  @override
  String toString() => code;
}

String newContentRequestId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}
