import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

enum HostedLLMFailureKind {
  quota,
  authentication,
  contextLimit,
  consent,
  membership,
  rateLimited,
  unavailable,
}

/// Keeps only a trusted category across runtime boundaries. Provider messages,
/// HTTP bodies, credentials and user content never become displayable errors.
class HostedLLMFailure implements Exception {
  const HostedLLMFailure(this.kind);

  final HostedLLMFailureKind kind;

  factory HostedLLMFailure.fromHttp(int status, String body) {
    Object? code;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) code = decoded['code'];
    } on FormatException {
      // Gateways may return HTML instead of the application envelope.
    }
    final kind = switch ((status, code)) {
      (429, 'MEMBERSHIP_QUOTA_EXHAUSTED') => HostedLLMFailureKind.quota,
      (401, _) => HostedLLMFailureKind.authentication,
      (400, 'MODEL_CONTEXT_LIMIT') => HostedLLMFailureKind.contextLimit,
      (403, 'MEMBERSHIP_REQUIRED') => HostedLLMFailureKind.membership,
      (
        403,
        'PRIVACY_CONSENT_REQUIRED' ||
            'PRIVACY_AGE_REQUIRED' ||
            'PRIVACY_POLICY_CHANGED',
      ) =>
        HostedLLMFailureKind.consent,
      (429, _) => HostedLLMFailureKind.rateLimited,
      _ => HostedLLMFailureKind.unavailable,
    };
    return HostedLLMFailure(kind);
  }

  String get runtimeReason => 'hosted_llm_failure:${kind.name}';

  static HostedLLMFailure? fromRuntimeReason(String? reason) {
    for (final kind in HostedLLMFailureKind.values) {
      final failure = HostedLLMFailure(kind);
      if (reason == failure.runtimeReason) return failure;
    }
    return null;
  }

  String userMessage(AppLocale locale) => AgentPromptCatalog.text(
    switch (kind) {
      HostedLLMFailureKind.quota => 'runtime.fallback.hosted_quota',
      HostedLLMFailureKind.authentication => 'runtime.fallback.hosted_auth',
      HostedLLMFailureKind.contextLimit => 'runtime.fallback.hosted_context',
      HostedLLMFailureKind.consent => 'runtime.fallback.hosted_consent',
      HostedLLMFailureKind.membership => 'runtime.fallback.hosted_membership',
      HostedLLMFailureKind.rateLimited => 'runtime.fallback.hosted_rate_limit',
      HostedLLMFailureKind.unavailable => 'runtime.fallback.hosted_unavailable',
    },
    locale: locale,
  );

  @override
  String toString() => runtimeReason;
}
