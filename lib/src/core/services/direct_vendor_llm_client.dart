import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/offline/offline_model_client.dart';

/// Resolves native vendor protocols from the configured public API origin.
/// Custom gateways retain the original OpenAI-compatible contract.
OfflineProviderConfig directVendorConfig(LLMDirectCloudConfig config) {
  final host = Uri.tryParse(config.baseUrl)?.host.toLowerCase();
  final providerId = switch (host) {
    'api.anthropic.com' => 'anthropic',
    'generativelanguage.googleapis.com' => 'gemini',
    'localhost' || '127.0.0.1' || '::1' => 'ollama',
    _ => 'custom',
  };
  return OfflineProviderConfig(
    providerId: providerId,
    enabled: config.enabled,
    baseUrl: config.baseUrl,
    model: config.model,
  );
}

/// Native Anthropic/Gemini transport behind the original Agent LLM boundary.
/// OpenAI-compatible providers continue using the existing streaming provider.
/// Responses grant no action authority; the existing runtime validates JSON.
final class DirectVendorLLMClient extends LLMClient
    implements StructuredOutputLLMClient, ProjectSourceLLMClient {
  DirectVendorLLMClient({required this.config, OfflineModelClient? transport})
    : _transport = transport ?? OfflineModelClient();

  final LLMDirectCloudConfig config;
  final OfflineModelClient _transport;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    // Native tool calls are disabled by default. Preserve explicit tool-result
    // provenance if a previous conversation contains results from another model.
    final normalized = <OfflineModelMessage>[
      for (final message in messages)
        if (message.content.trim().isNotEmpty)
          OfflineModelMessage(
            role: message.role == 'tool' ? 'user' : message.role,
            content: message.role == 'tool'
                ? jsonEncode({
                    'kind': 'tool_result',
                    'tool_call_id': message.toolCallId,
                    'content': message.content,
                  })
                : message.content,
          ),
    ];
    final operation = _transport.complete(
      config: directVendorConfig(config),
      apiKey: config.apiKey,
      messages: normalized,
    );
    if (timeout == null) return operation;
    return operation.timeout(
      timeout,
      onTimeout: () {
        _transport.cancel();
        throw const OfflineModelException('timeout');
      },
    );
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      chatJsonObject([
        Message.system('Return one valid JSON object only.'),
        Message.user(prompt),
      ], timeout: timeout);

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) async {
    await onAdmitted?.call();
    final response = await chat(messages, timeout: timeout);
    try {
      if (jsonDecode(response) is! Map<String, dynamic>) {
        throw const FormatException();
      }
    } on FormatException {
      throw const LLMResponseIntegrityException.invalidResponse();
    }
    return response;
  }

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    void requireCurrent() {
      if (shouldCancel?.call() == true) {
        _transport.cancel();
        throw const LLMResponseIntegrityException.publicFailure('interrupted');
      }
    }

    requireCurrent();
    await onAdmitted?.call();
    requireCurrent();
    final response = await chat(messages, timeout: timeout);
    requireCurrent();
    return ProjectSourceResponse(
      visibleText: response,
      termination: ProjectSourceTermination.complete,
    );
  }

  void close() => _transport.close();
}
