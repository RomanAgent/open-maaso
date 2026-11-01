/// Presentation metadata for a native-created invocation message. Parsing this
/// record never grants permission: every recovery operation must verify it
/// against the current account's durable invocation journal.
enum AppInvocationChatStatus {
  working,
  completed,
  resultUnavailable,
  outcomeUnknown,
  cancelled,
  failed,
}

final class AppInvocationChatReference {
  AppInvocationChatReference({
    required this.scopeKey,
    required this.sessionId,
    required this.invocationId,
    required this.sourceId,
    required this.revisionId,
    required this.sourceDigest,
    required this.contractDigest,
    required this.sourceTitle,
    required this.status,
    this.requestId,
    this.resultId,
    this.inputSummary,
  }) {
    if (!_text(scopeKey, 2048) ||
        !_identifier(sessionId) ||
        !_identifier(invocationId) ||
        !_text(sourceId, 512) ||
        !_text(revisionId, 512) ||
        !_digest.hasMatch(sourceDigest) ||
        !_digest.hasMatch(contractDigest) ||
        !_text(sourceTitle, 160) ||
        (requestId != null && !_identifier(requestId!)) ||
        (resultId != null && !_identifier(resultId!)) ||
        (inputSummary != null && !_text(inputSummary!, 240)) ||
        (resultId != null && requestId == null) ||
        (status == AppInvocationChatStatus.completed && resultId == null)) {
      throw const FormatException('invalid_invocation_chat_reference');
    }
  }

  final String scopeKey, sessionId, invocationId;
  final String sourceId, revisionId, sourceDigest, contractDigest, sourceTitle;
  final String? requestId, resultId, inputSummary;
  final AppInvocationChatStatus status;
  static final _digest = RegExp(r'^[a-f0-9]{64}$');
  static final _id = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$');
  static bool _identifier(String value) => _id.hasMatch(value);
  static bool _text(String value, int limit) =>
      value.trim().isNotEmpty && value.length <= limit;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'scopeKey': scopeKey,
    'sessionId': sessionId,
    'invocationId': invocationId,
    'sourceId': sourceId,
    'revisionId': revisionId,
    'sourceDigest': sourceDigest,
    'contractDigest': contractDigest,
    'sourceTitle': sourceTitle,
    'status': status.name,
    if (requestId != null) 'requestId': requestId,
    if (resultId != null) 'resultId': resultId,
    if (inputSummary != null) 'inputSummary': inputSummary,
  };

  static AppInvocationChatReference? tryParse(Object? value) {
    if (value is! Map ||
        value['schemaVersion'] != 1 ||
        value.keys.any((key) => !_keys.contains(key))) {
      return null;
    }
    try {
      return AppInvocationChatReference(
        scopeKey: value['scopeKey'] as String,
        sessionId: value['sessionId'] as String,
        invocationId: value['invocationId'] as String,
        sourceId: value['sourceId'] as String,
        revisionId: value['revisionId'] as String,
        sourceDigest: value['sourceDigest'] as String,
        contractDigest: value['contractDigest'] as String,
        sourceTitle: value['sourceTitle'] as String,
        status: AppInvocationChatStatus.values.byName(
          value['status'] as String,
        ),
        requestId: value['requestId'] as String?,
        resultId: value['resultId'] as String?,
        inputSummary: value['inputSummary'] as String?,
      );
    } on Object {
      return null;
    }
  }

  static const _keys = {
    'schemaVersion',
    'scopeKey',
    'sessionId',
    'invocationId',
    'sourceId',
    'revisionId',
    'sourceDigest',
    'contractDigest',
    'sourceTitle',
    'status',
    'requestId',
    'resultId',
    'inputSummary',
  };
}
