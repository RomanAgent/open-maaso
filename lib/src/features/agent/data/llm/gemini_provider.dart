import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/message.dart';
import '../utils/logger.dart';
import 'llm_client.dart';
import 'llm_response_integrity.dart';
import 'project_source_transport.dart';

/// Concrete implementation of the Google Gemini model.
/// Recommended to use gemini-2.5-flash-preview or gemini-1.5-flash for their
/// exceptional speed and low cost—ideal for on-device Agent brains.
class GeminiProvider
    implements LLMClient, StructuredOutputLLMClient, ProjectSourceLLMClient {
  final String apiKey;
  final String model;
  final http.Client? _httpClient;

  GeminiProvider({
    required this.apiKey,
    this.model =
        'gemini-2.5-flash', // Defaults to the Flash model for maximum speed
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  @override
  Duration get defaultTimeout => const Duration(seconds: 30);

  /// Constructs the Gemini API URL
  String get _baseUrl =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey';

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    return _callGeminiApi(messages, isJsonMode: false, timeout: timeout);
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    // Wraps a single prompt into a single-turn conversation and enables JSON mode
    return _callGeminiApi(
      [Message.user(prompt)],
      isJsonMode: true,
      timeout: timeout,
    );
  }

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) => _callGeminiApi(
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
    final system = <Map<String, String>>[];
    final contents = <Map<String, Object>>[];
    for (final message in messages) {
      if (message.role == 'system') {
        system.add({'text': message.content});
      } else {
        contents.add({
          'role': message.role == 'assistant' ? 'model' : 'user',
          'parts': [
            {'text': message.content},
          ],
        });
      }
    }
    final payload = {
      'contents': contents,
      if (system.isNotEmpty) 'systemInstruction': {'parts': system},
      'generationConfig': {'responseMimeType': 'application/json'},
    };
    final uri = Uri.https(
      'generativelanguage.googleapis.com',
      '/v1beta/models/$model:streamGenerateContent',
      {'key': apiKey, 'alt': 'sse'},
    );
    final transport = _httpClient ?? http.Client();
    final ownsTransport = _httpClient == null;
    final cancellation = ProjectSourceCancellation(
      shouldCancel,
      onCancelled: ownsTransport ? transport.close : null,
    );
    final idle = timeout ?? projectSourceDefaultIdleTimeout;
    final request = http.Request('POST', uri)
      ..headers['Content-Type'] = 'application/json; charset=utf-8'
      ..body = jsonEncode(payload);
    final visible = StringBuffer();
    Object? finishReason;
    Object? usage;
    void accept(Object? value) {
      if (value is! Map || value.containsKey('error')) {
        throw const LLMResponseIntegrityException.invalidResponse();
      }
      final feedback = value['promptFeedback'];
      final blocked = feedback is Map ? feedback['blockReason'] : null;
      if (blocked is String &&
          blocked.isNotEmpty &&
          blocked != 'BLOCK_REASON_UNSPECIFIED') {
        throw const LLMResponseIntegrityException.publicFailure(
          'modelSafetyBlocked',
        );
      }
      if (value['usageMetadata'] is Map) usage = value['usageMetadata'];
      final candidates = value['candidates'];
      if (candidates is! List || candidates.isEmpty) return;
      final candidate = candidates.first;
      if (candidate is! Map) {
        throw const LLMResponseIntegrityException.invalidResponse();
      }
      final reason = candidate['finishReason'];
      if (const {
        'SAFETY',
        'RECITATION',
        'BLOCKLIST',
        'PROHIBITED_CONTENT',
        'SPII',
      }.contains(reason)) {
        throw const LLMResponseIntegrityException.publicFailure(
          'modelSafetyBlocked',
        );
      }
      final content = candidate['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is List) {
        for (final part in parts.whereType<Map>()) {
          if (part['thought'] == true || part['text'] is! String) continue;
          final text = part['text'] as String;
          if (text.isNotEmpty && finishReason != null) {
            throw const LLMResponseIntegrityException.invalidResponse();
          }
          visible.write(text);
        }
      }
      if (reason != null) finishReason = reason;
    }

    try {
      cancellation.requireCurrent();
      await onAdmitted?.call();
      cancellation.requireCurrent();
      final response = await cancellation.wait(
        transport.send(request).timeout(idle),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        await response.stream.listen((_) {}).cancel();
        final retryAfter = modelRetryAfter(response.headers['retry-after']);
        throw modelHttpFailure(
          response.statusCode,
          // A bare RESOURCE_EXHAUSTED/429 can also mean permanent quota.
          // Retry it only when the provider supplied a bounded wait hint.
          sourceRetry: response.statusCode != 429 || retryAfter != null,
          retryAfter: retryAfter,
        );
      }
      final input = cancellation.bind(response.stream.timeout(idle));
      if ((response.headers['content-type'] ?? '').contains(
        'text/event-stream',
      )) {
        await for (final data in projectSourceSseData(input)) {
          cancellation.requireCurrent();
          if (data.trim() == '[DONE]') break;
          accept(jsonDecode(data));
        }
      } else {
        final bytes = await input.expand((chunk) => chunk).toList();
        accept(jsonDecode(utf8.decode(bytes)));
      }
      cancellation.requireCurrent();
      final terminal = switch (finishReason) {
        'STOP' => ProjectSourceTermination.complete,
        'MAX_TOKENS' => ProjectSourceTermination.knownLength,
        _ => throw const LLMResponseIntegrityException.publicFailure(
          'modelStreamInterrupted',
          retryable: true,
        ),
      };
      final numeric = LLMOutputFacts.fromBounded(
        visibleOutputTokens: usage is Map
            ? (usage as Map)['candidatesTokenCount']
            : null,
        reasoningTokens: usage is Map
            ? (usage as Map)['thoughtsTokenCount']
            : null,
      );
      return ProjectSourceResponse(
        visibleText: visible.toString(),
        termination: terminal,
        facts: LLMOutputFacts.fromBounded(
          visibleOutputTokens: numeric.visibleOutputTokens,
          reasoningTokens: numeric.reasoningTokens,
          completionTokens:
              numeric.visibleOutputTokens != null &&
                  numeric.reasoningTokens != null
              ? numeric.visibleOutputTokens! + numeric.reasoningTokens!
              : null,
        ),
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

  /// Core Gemini API calling logic
  Future<String> _callGeminiApi(
    List<Message> messages, {
    required bool isJsonMode,
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool requireTerminalReason = false,
  }) async {
    // 1. Separate System Prompt from regular conversation history.
    // In Gemini's API specification, the system prompt must be placed
    // in the 'systemInstruction' field separately.
    String? systemInstruction;
    final List<Map<String, dynamic>> contents = [];

    for (var msg in messages) {
      if (msg.role == 'system') {
        systemInstruction = isJsonMode && systemInstruction != null
            ? '$systemInstruction\n\n${msg.content}'
            : msg.content;
      } else {
        // Gemini role definitions: 'user' for user, 'model' for AI
        final role = msg.role == 'assistant' ? 'model' : 'user';
        contents.add({
          'role': role,
          'parts': [
            {'text': msg.content},
          ],
        });
      }
    }

    // 2. Build the request Payload
    final Map<String, dynamic> payload = {'contents': contents};

    // Inject System Prompt
    if (systemInstruction != null && systemInstruction.isNotEmpty) {
      payload['systemInstruction'] = {
        'parts': [
          {'text': systemInstruction},
        ],
      };
    }

    // Enable JSON mode (requires Gemini to return a structured object)
    if (isJsonMode) {
      payload['generationConfig'] = {'responseMimeType': 'application/json'};
    }

    // 3. Send the network request
    try {
      await onAdmitted?.call();
      final response = await (_httpClient?.post ?? http.post)(
        Uri.parse(_baseUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(payload),
      ).timeout(timeout ?? defaultTimeout);

      if (response.statusCode >= 200 && response.statusCode < 300) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        final feedback = data['promptFeedback'];
        final blockReason = feedback is Map ? feedback['blockReason'] : null;
        if (isJsonMode &&
            blockReason is String &&
            blockReason.isNotEmpty &&
            blockReason != 'BLOCK_REASON_UNSPECIFIED') {
          throw const LLMResponseIntegrityException.publicFailure(
            'modelSafetyBlocked',
          );
        }

        // Extract the generated text content
        final candidates = data['candidates'];
        if (candidates is List &&
            candidates.isNotEmpty &&
            candidates.first is Map) {
          final candidate = candidates.first as Map;
          final usage = data['usageMetadata'];
          final usageFacts = LLMOutputFacts.fromBounded(
            visibleOutputTokens: usage is Map
                ? usage['candidatesTokenCount']
                : null,
            reasoningTokens: usage is Map ? usage['thoughtsTokenCount'] : null,
          );
          final visibleTokens = usageFacts.visibleOutputTokens;
          final thoughtTokens = usageFacts.reasoningTokens;
          final config = payload['generationConfig'];
          requireCompleteModelOutput(
            candidate['finishReason'],
            facts: LLMOutputFacts.fromBounded(
              sentMaxOutputTokens: config is Map
                  ? config['maxOutputTokens']
                  : null,
              visibleOutputTokens: visibleTokens,
              reasoningTokens: thoughtTokens,
              completionTokens: visibleTokens != null && thoughtTokens != null
                  ? visibleTokens + thoughtTokens
                  : null,
            ),
          );
          if (isJsonMode &&
              const {
                'SAFETY',
                'RECITATION',
                'BLOCKLIST',
                'PROHIBITED_CONTENT',
                'SPII',
              }.contains(candidate['finishReason'])) {
            throw const LLMResponseIntegrityException.publicFailure(
              'modelSafetyBlocked',
            );
          }
          if (requireTerminalReason && candidate['finishReason'] != 'STOP') {
            throw const LLMResponseIntegrityException.invalidResponse();
          }
          final content = candidate['content'];
          final parts = content is Map ? content['parts'] : null;
          if (parts is List) {
            final text = parts
                .whereType<Map>()
                .where(
                  (part) => part['thought'] != true && part['text'] is String,
                )
                .map((part) => part['text'] as String)
                .join();
            if (text.isNotEmpty) return text;
          }
        }
        throw const LLMResponseIntegrityException.invalidResponse();
      } else {
        throw modelHttpFailure(response.statusCode);
      }
    } catch (e) {
      Log.e('❌ [GeminiProvider] Model call failed: $e');
      rethrow;
    }
  }

  /// Gemini doesn't ship a clean SSE delta stream out of the box (its
  /// "streamGenerateContent" returns a JSON array stream).  For now we
  /// fall back to non-streaming — yields the full response as a single
  /// chunk so the streaming caller keeps working with no observable change.
  /// TODO: implement real Gemini SSE if/when needed.
  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
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

  /// Gemini's native function-calling lives at a different endpoint
  /// (`generateContent` with `tools: [{functionDeclarations: [...]}]`) and
  /// returns `functionCall` parts instead of OpenAI-style `tool_calls`.
  /// This adapter does not yet implement native function calling. Callers can
  /// select the validated JSON action-envelope path instead.
  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) {
    throw UnsupportedError(
      'GeminiProvider does not yet implement native tool calling.',
    );
  }
}
