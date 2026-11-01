/// Optional numeric evidence from the dispatched request and provider receipt.
/// Missing, malformed or out-of-range values remain unavailable, never zero.
/// No provider body, source text, identifiers or reasoning text is retained.
final class LLMOutputFacts {
  const LLMOutputFacts._({
    this.sentMaxOutputTokens,
    this.admittedMaxOutputTokens,
    this.completionTokens,
    this.reasoningTokens,
    this.visibleOutputTokens,
  });

  factory LLMOutputFacts.fromBounded({
    Object? sentMaxOutputTokens,
    Object? admittedMaxOutputTokens,
    Object? completionTokens,
    Object? reasoningTokens,
    Object? visibleOutputTokens,
  }) => LLMOutputFacts._(
    sentMaxOutputTokens: _boundedInteger(sentMaxOutputTokens, minimum: 1),
    admittedMaxOutputTokens: _boundedInteger(
      admittedMaxOutputTokens,
      minimum: 1,
    ),
    completionTokens: _boundedInteger(completionTokens),
    reasoningTokens: _boundedInteger(reasoningTokens),
    visibleOutputTokens: _boundedInteger(visibleOutputTokens),
  );

  static const maxTokenFact = 1024 * 1024;
  final int? sentMaxOutputTokens;
  final int? admittedMaxOutputTokens;
  final int? completionTokens;
  final int? reasoningTokens;
  final int? visibleOutputTokens;

  Map<String, int> toJson() => {
    'sentMaxOutputTokens': ?sentMaxOutputTokens,
    'admittedMaxOutputTokens': ?admittedMaxOutputTokens,
    'completionTokens': ?completionTokens,
    'reasoningTokens': ?reasoningTokens,
    'visibleOutputTokens': ?visibleOutputTokens,
  };

  static int? _boundedInteger(Object? value, {int minimum = 0}) =>
      value is int && value >= minimum && value <= maxTokenFact ? value : null;
}

/// Stable diagnostics for responses that must not be executed as complete
/// structured output. Provider bodies and hidden reasoning are never retained.
class LLMResponseIntegrityException implements Exception {
  const LLMResponseIntegrityException.outputTruncated({this.facts})
    : runtimeReason = 'generated_task_failure:modelOutputTruncated',
      retryable = false,
      retryAfter = null;

  const LLMResponseIntegrityException.invalidResponse()
    : facts = null,
      runtimeReason = 'generated_task_failure:responseInvalid',
      retryable = false,
      retryAfter = null;

  const LLMResponseIntegrityException.publicFailure(
    String code, {
    this.retryable = false,
    this.retryAfter,
  }) : facts = null,
       runtimeReason = 'generated_task_failure:$code';

  final String runtimeReason;
  final LLMOutputFacts? facts;

  /// A source transport may explicitly classify a transient request failure.
  /// This never makes a partial response executable or retries ordinary chat.
  final bool retryable;
  final Duration? retryAfter;

  @override
  String toString() => runtimeReason;
}

LLMResponseIntegrityException modelHttpFailure(
  int statusCode, {
  String? providerCode,
  bool sourceRetry = false,
  Duration? retryAfter,
}) {
  final code = switch (providerCode) {
    'insufficient_quota' => 'modelQuotaExceeded',
    'context_length_exceeded' => 'modelContextLimit',
    _ => switch (statusCode) {
      401 || 403 => 'modelAuthentication',
      429 => 'modelRateLimited',
      >= 500 => 'modelUnavailable',
      _ => 'responseInvalid',
    },
  };
  final retryable =
      sourceRetry && (code == 'modelRateLimited' || code == 'modelUnavailable');
  return LLMResponseIntegrityException.publicFailure(
    code,
    retryable: retryable,
    retryAfter: retryable ? retryAfter : null,
  );
}

/// Retain only a bounded delta-seconds hint, never provider header prose.
/// Other Retry-After forms fall back to the source operation's own backoff.
Duration? modelRetryAfter(String? header) {
  final value = header?.trim();
  if (value == null || !RegExp(r'^[0-9]{1,3}$').hasMatch(value)) return null;
  final seconds = int.tryParse(value);
  return seconds != null && seconds <= 300 ? Duration(seconds: seconds) : null;
}

void requireCompleteModelOutput(Object? finishReason, {LLMOutputFacts? facts}) {
  if (finishReason == 'length' || finishReason == 'MAX_TOKENS') {
    throw LLMResponseIntegrityException.outputTruncated(facts: facts);
  }
}
