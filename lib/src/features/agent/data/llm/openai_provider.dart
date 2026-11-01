import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import '../models/message.dart';
import '../utils/logger.dart';
import 'llm_client.dart';
import 'llm_response_integrity.dart';
import 'project_source_transport.dart';

/// Concrete implementation for OpenAI models.
/// Supports GPT-4o, GPT-4o-mini, etc., and plugs into the agent routing
/// system.
class OpenAIProvider
    implements LLMClient, StructuredOutputLLMClient, ProjectSourceLLMClient {
  final String apiKey;
  final String model;

  /// Allows a custom Base URL, for plugging into various proxies or
  /// self-hosted compatible APIs (e.g. OneAPI).
  final String baseUrl;

  /// Extra top-level fields merged into every request body.  Lets the host
  /// app pass provider-specific knobs — e.g. Volcano Ark's
  /// `{"thinking": {"type": "disabled"}}` to skip the reasoning preamble
  /// (drops first-token latency by 1–3s on Doubao "thinking" models) —
  /// without forking this provider per backend.
  final Map<String, dynamic> extraBody;
  final http.Client? _httpClient;

  OpenAIProvider({
    required this.apiKey,
    this.model =
        'gpt-4o-mini', // default to a faster, cheaper model, good for most routine tasks
    this.baseUrl = 'https://api.openai.com/v1',
    this.extraBody = const {},
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  @override
  Duration get defaultTimeout => const Duration(seconds: 45);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    return _callOpenAIApi(messages, isJsonMode: false, timeout: timeout);
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    // 💡 OpenAI API requirement: when json_object mode is on, the system or
    // user prompt must explicitly ask the model to output JSON.
    final messages = [
      Message.system(AgentPromptCatalog.text('provider.json_system')),
      Message.user(prompt),
    ];
    return _callOpenAIApi(messages, isJsonMode: true, timeout: timeout);
  }

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) => _callOpenAIApi(
    messages,
    isJsonMode: true,
    timeout: timeout,
    onAdmitted: onAdmitted,
    requireTerminalReason: true,
  );

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    final idle = timeout ?? projectSourceDefaultIdleTimeout;
    final transport = _httpClient ?? http.Client();
    final ownsTransport = _httpClient == null;
    final cancellation = ProjectSourceCancellation(
      shouldCancel,
      onCancelled: ownsTransport ? transport.close : null,
    );
    final payload = <String, dynamic>{
      'model': model,
      'messages': messages.map((message) => message.toJson()).toList(),
      'temperature': 0.2,
      ...extraBody,
      'stream': true,
      'response_format': {'type': 'json_object'},
    };
    for (final key in const [
      'max_tokens',
      'max_completion_tokens',
      'max_output_tokens',
      'maxOutputTokens',
      'maxTokens',
      'thinking',
      'reasoning_effort',
    ]) {
      payload.remove(key);
    }
    final url = Uri.parse('$baseUrl/chat/completions');
    if (url.host == 'api.openai.com' ||
        url.host == 'ark.cn-beijing.volces.com') {
      payload['stream_options'] = {'include_usage': true};
    }
    // Freeze the request before admission. Compatibility negotiation changes
    // only the rejected transport option, never roles, source or configuration.
    final encodedPayload = jsonEncode(payload);
    Future<http.StreamedResponse> dispatch(String body) async {
      cancellation.requireCurrent();
      await onAdmitted?.call();
      cancellation.requireCurrent();
      final request = http.Request('POST', url)
        ..headers.addAll({
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $apiKey',
          'Accept': 'text/event-stream',
        })
        ..body = body;
      return cancellation.wait(transport.send(request).timeout(idle));
    }

    Future<String> rejectionBody(http.StreamedResponse response) async {
      final bytes = <int>[];
      try {
        await for (final chunk in cancellation.bind(
          response.stream.timeout(idle),
        )) {
          if (bytes.length + chunk.length > 16384) break;
          bytes.addAll(chunk);
        }
      } on TimeoutException {
        cancellation.requireCurrent();
        throw modelHttpFailure(response.statusCode);
      } on http.ClientException {
        cancellation.requireCurrent();
        throw modelHttpFailure(response.statusCode);
      }
      return utf8.decode(bytes, allowMalformed: true);
    }

    try {
      var response = await dispatch(encodedPayload);
      String? firstRejection;
      if (response.statusCode == 400) {
        firstRejection = await rejectionBody(response);
        if (_isExplicitSourceFormatRejection(firstRejection)) {
          // HTTP 400 rejects the request before source generation. Retry once
          // through this same source operation, with fresh permission/current
          // checks. A stream/network failure never enters this negotiation.
          final textualPayload = jsonDecode(encodedPayload) as Map;
          textualPayload.remove('response_format');
          response = await dispatch(jsonEncode(textualPayload));
          firstRejection = null;
        }
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = firstRejection ?? await rejectionBody(response);
        String? code;
        try {
          final decoded = jsonDecode(body);
          final error = decoded is Map ? decoded['error'] : null;
          if (error is Map) {
            if (error['code'] is String) code = error['code'] as String;
            if (response.statusCode == 400 &&
                (error['param'] == 'response_format' ||
                    error['param'] == 'response_format.type')) {
              throw const LLMResponseIntegrityException.publicFailure(
                'structuredOutputUnsupported',
              );
            }
          }
        } on FormatException {
          // Provider error prose is not source or public diagnostic data.
        }
        throw modelHttpFailure(
          response.statusCode,
          providerCode: code,
          sourceRetry: true,
          retryAfter: modelRetryAfter(response.headers['retry-after']),
        );
      }
      final input = cancellation.bind(response.stream.timeout(idle));
      if (!(response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      )) {
        final bytes = await input.expand((chunk) => chunk).toList();
        final decoded = jsonDecode(utf8.decode(bytes));
        if (decoded is! Map) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        final choices = decoded['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        final choice = choices.first as Map;
        final message = choice['message'];
        _requireSourceNotBlocked(choice['finish_reason'], message);
        if (message is! Map || message['content'] is! String) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        cancellation.requireCurrent();
        return _sourceResponse(
          message['content'] as String,
          choice['finish_reason'],
          decoded['usage'],
        );
      }
      final visible = StringBuffer();
      Object? finishReason;
      Object? usage;
      await for (final data in projectSourceSseData(input)) {
        cancellation.requireCurrent();
        if (data.trim() == '[DONE]') {
          return _sourceResponse(visible.toString(), finishReason, usage);
        }
        final decoded = jsonDecode(data);
        if (decoded is! Map || decoded.containsKey('error')) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        if (decoded['usage'] is Map) usage = decoded['usage'];
        final choices = decoded['choices'];
        if (choices is! List) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        if (choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        final delta = choice['delta'];
        _requireSourceNotBlocked(choice['finish_reason'], delta);
        final content = delta is Map ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          if (finishReason != null) {
            throw const LLMResponseIntegrityException.invalidResponse();
          }
          visible.write(content);
        }
        if (choice['finish_reason'] != null) {
          finishReason = choice['finish_reason'];
        }
      }
      throw const LLMResponseIntegrityException.publicFailure(
        'modelStreamInterrupted',
        retryable: true,
      );
    } on TimeoutException {
      cancellation.requireCurrent();
      throw const LLMResponseIntegrityException.publicFailure(
        'modelTimeout',
        retryable: true,
      );
    } on http.ClientException {
      cancellation.requireCurrent();
      throw const LLMResponseIntegrityException.publicFailure(
        'modelStreamInterrupted',
        retryable: true,
      );
    } on LLMResponseIntegrityException catch (error) {
      cancellation.requireCurrent();
      if (error.runtimeReason ==
          'generated_task_failure:modelStreamInterrupted') {
        // The shared SSE decoder also reports a truncated frame as an unknown
        // interruption. Discard the prefix and let the source owner retry.
        throw const LLMResponseIntegrityException.publicFailure(
          'modelStreamInterrupted',
          retryable: true,
        );
      }
      rethrow;
    } on FormatException {
      throw const LLMResponseIntegrityException.invalidResponse();
    } finally {
      cancellation.dispose();
      if (ownsTransport) transport.close();
    }
  }

  /// Only machine-readable format rejection can authorize source negotiation.
  /// Arbitrary provider prose, missing fields or conflicting error types do not
  /// prove that native JSON was the rejected option.
  static bool _isExplicitSourceFormatRejection(String body) {
    try {
      final decoded = jsonDecode(body);
      final error = decoded is Map ? decoded['error'] : null;
      if (error is! Map ||
          !const {
            'response_format',
            'response_format.type',
          }.contains(error['param']) ||
          !const {
            'unsupported_parameter',
            'unsupported_value',
            'unknown_parameter',
          }.contains(error['code']) ||
          error['type'] != null && error['type'] != 'invalid_request_error') {
        return false;
      }
      return true;
    } on FormatException {
      return false;
    }
  }

  static void _requireSourceNotBlocked(Object? finishReason, Object? message) {
    if (finishReason == 'content_filter' ||
        (message is Map &&
            message['refusal'] is String &&
            (message['refusal'] as String).trim().isNotEmpty)) {
      throw const LLMResponseIntegrityException.publicFailure(
        'modelSafetyBlocked',
      );
    }
  }

  static ProjectSourceResponse _sourceResponse(
    String visible,
    Object? finishReason,
    Object? usage,
  ) {
    final details = usage is Map ? usage['completion_tokens_details'] : null;
    final termination = switch (finishReason) {
      'stop' => ProjectSourceTermination.complete,
      'length' => ProjectSourceTermination.knownLength,
      _ => throw const LLMResponseIntegrityException.invalidResponse(),
    };
    return ProjectSourceResponse(
      visibleText: visible,
      termination: termination,
      facts: LLMOutputFacts.fromBounded(
        completionTokens: usage is Map ? usage['completion_tokens'] : null,
        reasoningTokens: details is Map ? details['reasoning_tokens'] : null,
      ),
    );
  }

  /// Core OpenAI API call logic.
  Future<String> _callOpenAIApi(
    List<Message> messages, {
    required bool isJsonMode,
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool requireTerminalReason = false,
  }) async {
    final url = Uri.parse('$baseUrl/chat/completions');

    // 1. Convert Message into the format the OpenAI API needs.
    // OpenAI's roles are very standard: 'system', 'user', 'assistant', which
    // map perfectly onto our Message model.
    final List<Map<String, String>> formattedMessages = messages.map((msg) {
      return {'role': msg.role, 'content': msg.content};
    }).toList();

    // 2. Build the request payload.
    final Map<String, dynamic> payload = {
      'model': model,
      'messages': formattedMessages,
      // You can add extra params here, e.g. temperature to tune divergence.
      'temperature': 0.2,
      ...extraBody,
    };

    // Turn on forced JSON output mode.
    if (isJsonMode) {
      payload['response_format'] = {'type': 'json_object'};
    }

    // This canonical Ark model always reasons and does not support disabled.
    // Keep the request-local generation policy separate from ordinary chat and
    // opaque endpoint IDs; never infer model capabilities from user content.
    if (requireTerminalReason &&
        model == 'glm-5-3-flash-260828' &&
        url.scheme == 'https' &&
        url.host == 'ark.cn-beijing.volces.com') {
      payload['thinking'] = {'type': 'enabled'};
      payload['reasoning_effort'] = 'low';
    }

    // 3. Send the network request.
    try {
      await onAdmitted?.call();
      final response = await (_httpClient?.post ?? http.post)(
        url,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(payload),
      ).timeout(timeout ?? defaultTimeout);

      // Handle character encoding (UTF-8).
      final responseBody = utf8.decode(response.bodyBytes);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final Map<String, dynamic> data = jsonDecode(responseBody);

        // Extract the generated text content.
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty && choices.first is Map) {
          final choice = choices.first as Map;
          final usage = data['usage'];
          final details = usage is Map
              ? usage['completion_tokens_details']
              : null;
          requireCompleteModelOutput(
            choice['finish_reason'],
            facts: LLMOutputFacts.fromBounded(
              sentMaxOutputTokens:
                  payload['max_completion_tokens'] ?? payload['max_tokens'],
              completionTokens: usage is Map
                  ? usage['completion_tokens']
                  : null,
              reasoningTokens: details is Map
                  ? details['reasoning_tokens']
                  : null,
            ),
          );
          final message = choice['message'];
          if (isJsonMode &&
              (choice['finish_reason'] == 'content_filter' ||
                  (message is Map &&
                      message['refusal'] is String &&
                      (message['refusal'] as String).trim().isNotEmpty))) {
            throw const LLMResponseIntegrityException.publicFailure(
              'modelSafetyBlocked',
            );
          }
          if (requireTerminalReason && choice['finish_reason'] != 'stop') {
            throw const LLMResponseIntegrityException.invalidResponse();
          }
          if (message is Map && message['content'] is String) {
            return message['content'] as String;
          }
        }
        throw const LLMResponseIntegrityException.invalidResponse();
      } else {
        String? providerCode;
        try {
          final body = jsonDecode(responseBody);
          if (body is Map && body['error'] is Map) {
            final error = body['error'] as Map;
            final value = error['code'];
            if (value is String) providerCode = value;
            // Compatible APIs do not all support native JSON. Recognize only
            // an explicit format-parameter rejection; never expose provider
            // prose or automatically issue a second ordinary-chat request.
            final parameter = error['param'];
            final description = error['message'];
            if (isJsonMode &&
                (response.statusCode == 400 || response.statusCode == 422) &&
                (parameter == 'response_format' ||
                    parameter == 'response_format.type' ||
                    (description is String &&
                        (description.contains('response_format') ||
                            description.contains('json_object')) &&
                        RegExp(
                          r'unsupported|not supported|not support|unknown parameter|unrecognized',
                          caseSensitive: false,
                        ).hasMatch(description)))) {
              throw const LLMResponseIntegrityException.publicFailure(
                'structuredOutputUnsupported',
              );
            }
          }
        } on FormatException {
          // Invalid provider prose is never exposed as a diagnostic.
        }
        throw modelHttpFailure(response.statusCode, providerCode: providerCode);
      }
    } catch (e) {
      Log.e('❌ [OpenAIProvider] Model call failed: $e');
      rethrow;
    }
  }

  // ───────────────── Native tool calling (OpenAI /v1/chat tools) ─────────────────

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    final url = Uri.parse('$baseUrl/chat/completions');
    final formatted = messages.map((m) => m.toJson()).toList();
    final payload = <String, dynamic>{
      'model': model,
      'messages': formatted,
      'temperature': 0.2,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
      ...extraBody,
    };

    try {
      final response = await (_httpClient?.post ?? http.post)(
        url,
        headers: {
          'Content-Type': 'application/json; charset=utf-8',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode(payload),
      ).timeout(timeout ?? defaultTimeout);

      final body = utf8.decode(response.bodyBytes);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw modelHttpFailure(response.statusCode);
      }
      final data = jsonDecode(body) as Map<String, dynamic>;
      final choices = data['choices'];
      if (choices is! List || choices.isEmpty || choices.first is! Map) {
        throw const LLMResponseIntegrityException.invalidResponse();
      }
      final choice = choices.first as Map;
      requireCompleteModelOutput(choice['finish_reason']);
      final message = choice['message'];
      if (message is! Map) {
        throw const LLMResponseIntegrityException.invalidResponse();
      }
      final content = (message['content'] as String?) ?? '';
      final rawCalls = message['tool_calls'] as List<dynamic>?;
      final calls = rawCalls == null
          ? const <ToolCall>[]
          : rawCalls
                .whereType<Map>()
                .map((m) => ToolCall.fromJson(m.cast<String, dynamic>()))
                .toList();
      return ChatTurnResult(content: content, toolCalls: calls);
    } catch (e) {
      Log.e('❌ [OpenAIProvider/tools] $e');
      rethrow;
    }
  }

  // ─────────────────── Streaming (Server-Sent Events) ───────────────────

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    final url = Uri.parse('$baseUrl/chat/completions');
    final formatted = messages
        .map((m) => {'role': m.role, 'content': m.content})
        .toList();
    final payload = <String, dynamic>{
      'model': model,
      'messages': formatted,
      'temperature': 0.2,
      'stream': true,
      ...extraBody,
    };
    if (url.host == 'api.openai.com' ||
        url.host == 'ark.cn-beijing.volces.com') {
      payload['stream_options'] = {'include_usage': true};
    }

    final req = http.Request('POST', url)
      ..headers.addAll({
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $apiKey',
        'Accept': 'text/event-stream',
      })
      ..body = jsonEncode(payload);

    final client = _httpClient ?? http.Client();
    final ownsClient = _httpClient == null;
    try {
      final response = await client
          .send(req)
          .timeout(timeout ?? defaultTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final body = await response.stream.bytesToString();
        throw Exception('OpenAI stream error [${response.statusCode}]: $body');
      }

      // Decode bytes → UTF-8 lines.  Note SSE may pack multiple events into
      // one HTTP chunk; split by newline manually so we don't lose any.
      String pending = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        pending += chunk;
        while (true) {
          final nl = pending.indexOf('\n');
          if (nl < 0) break;
          final line = pending.substring(0, nl).trim();
          pending = pending.substring(nl + 1);
          if (line.isEmpty || !line.startsWith('data:')) continue;
          final data = line.substring(5).trim();
          if (data == '[DONE]') return;
          try {
            final json = jsonDecode(data);
            final choices = json is Map ? json['choices'] as List? : null;
            if (choices != null && choices.isNotEmpty) {
              final delta = (choices.first as Map)['delta'] as Map?;
              final content = delta?['content'] as String?;
              if (content != null && content.isNotEmpty) {
                yield content;
              }
            }
          } catch (_) {
            // Ignore malformed lines — SSE keep-alive comments etc.
          }
        }
      }
    } catch (e) {
      Log.e('❌ [OpenAIProvider/stream] failed: $e');
      rethrow;
    } finally {
      if (ownsClient) client.close();
    }
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await for (final chunk in streamChat(messages, timeout: timeout)) {
      if (chunk.isEmpty) continue;
      yield LLMStreamEvent(
        event: 'reply.delta',
        data: jsonEncode({'delta': chunk}),
      );
    }
  }
}
