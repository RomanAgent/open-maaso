import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/project_source_transport.dart';

typedef MaasoAccessTokenProvider = Future<String?> Function();

class MaasoThinProxyLLMClient
    implements
        LLMClient,
        PresentationStreamingLLMClient,
        PrivacyAdmissionLLMClient,
        StructuredOutputLLMClient,
        ProjectSourceLLMClient {
  MaasoThinProxyLLMClient({
    required Uri baseUri,
    required String model,
    required MaasoAccessTokenProvider accessTokenProvider,
    http.Client? httpClient,
  }) : _baseUri = _normalizeBase(baseUri),
       _model = model,
       _accessTokenProvider = accessTokenProvider,
       _httpClient = httpClient ?? http.Client(),
       _ownsClient = httpClient == null;

  final Uri _baseUri;
  final String _model;
  final MaasoAccessTokenProvider _accessTokenProvider;
  final http.Client _httpClient;
  final bool _ownsClient;

  static const _standardStreamProtocol = 'maaso.sse.v1';
  static const _presentationStreamProtocol = 'maaso.sse.v2.presentation';
  static const _maxSseEventBytes = 256 * 1024;

  @override
  Duration get defaultTimeout => const Duration(seconds: 90);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    final buffer = StringBuffer();
    await for (final chunk in streamChat(messages, timeout: timeout)) {
      buffer.write(chunk);
    }
    return buffer.toString();
  }

  @override
  Future<String> chatWithAdmission(
    List<Message> messages, {
    Duration? timeout,
    required void Function() onAdmitted,
  }) async {
    final buffer = StringBuffer();
    await for (final event in _streamChatEvents(
      messages,
      timeout: timeout,
      streamProtocol: _standardStreamProtocol,
      exposeDone: false,
      onAdmitted: onAdmitted,
    )) {
      buffer.write(event.deltaText);
    }
    return buffer.toString();
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) {
    return chat([
      Message.system(AgentPromptCatalog.text('provider.json_system')),
      Message.user(prompt),
    ], timeout: timeout);
  }

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) async {
    final buffer = StringBuffer();
    await for (final event in _streamChatEvents(
      messages,
      timeout: timeout,
      streamProtocol: _standardStreamProtocol,
      exposeDone: false,
      jsonObject: true,
      onAdmitted: onAdmitted,
    )) {
      buffer.write(event.deltaText);
    }
    return buffer.toString();
  }

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    final transport = _ownsClient ? http.Client() : _httpClient;
    final cancellation = ProjectSourceCancellation(
      shouldCancel,
      onCancelled: _ownsClient ? transport.close : null,
    );
    final buffer = StringBuffer();
    ProjectSourceTermination? termination;
    LLMOutputFacts? facts;
    try {
      final events = _streamChatEvents(
        messages,
        timeout: timeout ?? projectSourceDefaultIdleTimeout,
        streamProtocol: _standardStreamProtocol,
        exposeDone: false,
        jsonObject: true,
        projectSource: true,
        sourceTransport: transport,
        onProjectFacts: (value) => facts = value,
        onProjectTermination: (value) => termination = value,
        onAdmitted: () async {
          cancellation.requireCurrent();
          await onAdmitted?.call();
          cancellation.requireCurrent();
        },
      );
      await for (final event in cancellation.bind(events)) {
        cancellation.requireCurrent();
        buffer.write(event.deltaText);
      }
      cancellation.requireCurrent();
      final terminal = termination;
      if (terminal == null) {
        throw const LLMResponseIntegrityException.publicFailure(
          'modelStreamInterrupted',
          retryable: true,
        );
      }
      return ProjectSourceResponse(
        visibleText: buffer.toString(),
        termination: terminal,
        facts: facts,
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
    } on FormatException {
      throw const LLMResponseIntegrityException.invalidResponse();
    } finally {
      cancellation.dispose();
      if (_ownsClient) transport.close();
    }
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    final content = await chat(messages, timeout: timeout);
    return ChatTurnResult(content: content, toolCalls: const []);
  }

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    await for (final event in streamChatEvents(messages, timeout: timeout)) {
      final delta = event.deltaText;
      if (delta.isNotEmpty) yield delta;
    }
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => _streamChatEvents(
    messages,
    timeout: timeout,
    streamProtocol: _standardStreamProtocol,
    exposeDone: false,
  );

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => _streamChatEvents(
    messages,
    timeout: timeout,
    streamProtocol: _presentationStreamProtocol,
    exposeDone: true,
  );

  Stream<LLMStreamEvent> _streamChatEvents(
    List<Message> messages, {
    required String streamProtocol,
    required bool exposeDone,
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool jsonObject = false,
    bool projectSource = false,
    http.Client? sourceTransport,
    void Function(LLMOutputFacts)? onProjectFacts,
    void Function(ProjectSourceTermination)? onProjectTermination,
  }) async* {
    final request = http.Request(
      'POST',
      _baseUri.resolve('/v1/proxy/llm/stream'),
    );
    request.headers.addAll({
      'Content-Type': 'application/json; charset=utf-8',
      'Accept': 'text/event-stream',
      // Older clients do not accept the telemetry event in every protocol.
      'X-Maaso-Usage': 'provider-v1',
    });
    final token = (await _accessTokenProvider())?.trim();
    if (token != null && token.isNotEmpty) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    final sentMaxTokens = projectSource
        ? null
        : jsonObject
        ? 8192
        : _maxTokensFor(messages);
    request.body = jsonEncode({
      // One identity per provider dispatch, not per user turn or SSE event.
      // Tool/JSON calls in the same turn are separate metered requests. This
      // client sends the body once and does not retry an uncertain dispatch.
      'turnId': const Uuid().v4(),
      'model': _model,
      'messages': messages.map((m) => m.toJson()).toList(),
      'temperature': 0.2,
      'maxTokens': ?sentMaxTokens,
      'streamProtocol': streamProtocol,
      if (jsonObject) 'outputFormat': 'json_object',
      if (projectSource) 'generationMode': 'project_source',
    });

    // Token refresh can await after the outer privacy check. Re-check the
    // owning operation at the last local boundary before any HTTP dispatch.
    await onAdmitted?.call();
    final response = await (sourceTransport ?? _httpClient)
        .send(request)
        .timeout(timeout ?? defaultTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      final body = <int>[];
      try {
        await for (final chunk in response.stream.timeout(
          timeout ?? defaultTimeout,
        )) {
          if (body.length + chunk.length > 16384) break;
          body.addAll(chunk);
        }
      } on TimeoutException {
        if (!projectSource) rethrow;
        // We already received a rejection. A broken error body cannot turn
        // authentication, membership or quota denial into a transient failure.
        throw HostedLLMFailure.fromHttp(response.statusCode, '');
      } on http.ClientException {
        if (!projectSource) rethrow;
        throw HostedLLMFailure.fromHttp(response.statusCode, '');
      }
      final responseBody = utf8.decode(body, allowMalformed: true);
      if (jsonObject) {
        final diagnostic = _structuredHttpFailure(
          response.statusCode,
          responseBody,
          projectSource: projectSource,
          retryAfter: response.headers['retry-after'],
        );
        if (diagnostic != null) throw diagnostic;
      }
      throw HostedLLMFailure.fromHttp(response.statusCode, responseBody);
    }

    if ((jsonObject &&
            response.headers['x-maaso-output-format'] != 'json_object') ||
        (projectSource &&
            response.headers['x-maaso-generation-mode'] != 'project_source')) {
      // An older server may ignore the request field. Never mistake its text
      // output for an accepted native JSON request or replay it invisibly.
      await response.stream.listen((_) {}).cancel();
      throw const LLMResponseIntegrityException.publicFailure(
        'structuredOutputUnsupported',
      );
    }

    final admittedHeader = response.headers['x-maaso-max-output-tokens'];
    final tokenFacts = LLMOutputFacts.fromBounded(
      sentMaxOutputTokens: sentMaxTokens,
      admittedMaxOutputTokens:
          admittedHeader != null &&
              RegExp(r'^[0-9]{1,7}$').hasMatch(admittedHeader)
          ? int.tryParse(admittedHeader)
          : null,
    );
    onProjectFacts?.call(tokenFacts);

    var eventLines = <String>[];
    var completeJsonOutput = false;
    var incompleteSourceOutput = false;
    var structuredEventCount = 0;
    var structuredWireBytes = 0;
    final lines = _boundedSseLines(
      jsonObject
          ? response.stream.timeout(timeout ?? defaultTimeout)
          : response.stream,
    );
    await for (final line in lines) {
      if (line.isNotEmpty) {
        eventLines.add(line);
        continue;
      }
      if (eventLines.isEmpty) continue;
      final event = _sseEvent(eventLines.join('\n'));
      eventLines = <String>[];
      if (event == null) continue;
      // Usage is provider telemetry only. The metered HTTP boundary records it;
      // it grants no reply, tool, completion, or presentation authority.
      if (event.event == 'usage') continue;
      if (jsonObject) {
        structuredEventCount++;
        structuredWireBytes += utf8.encode(event.data).length;
        if (!projectSource &&
            (structuredEventCount > 8192 ||
                structuredWireBytes > 1024 * 1024)) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        if (event.event == 'completion') {
          if (completeJsonOutput || incompleteSourceOutput) {
            throw const LLMResponseIntegrityException.invalidResponse();
          }
          final completion = event.jsonPayload;
          final finishReason = completion?['finishReason'];
          final status = completion?['status'];
          if (projectSource) {
            if (finishReason == 'content_filter' || status == 'blocked') {
              throw const LLMResponseIntegrityException.publicFailure(
                'modelSafetyBlocked',
              );
            }
            if (finishReason == 'length' && status == 'truncated') {
              onProjectTermination?.call(ProjectSourceTermination.knownLength);
              return;
            }
          }
          if (finishReason == 'length' || status == 'truncated') {
            throw LLMResponseIntegrityException.outputTruncated(
              facts: tokenFacts,
            );
          }
          if (finishReason == 'content_filter' || status == 'blocked') {
            throw const LLMResponseIntegrityException.publicFailure(
              'modelSafetyBlocked',
            );
          }
          if (finishReason != 'stop' || status != 'complete') {
            if (projectSource &&
                status == 'incomplete' &&
                finishReason is String) {
              // The server sends completion before its typed error. Preserve
              // that final classification instead of prematurely converting a
              // permanent rejection into a retryable transport interruption.
              incompleteSourceOutput = true;
              continue;
            }
            throw const LLMResponseIntegrityException.publicFailure(
              'modelStreamInterrupted',
            );
          }
          completeJsonOutput = true;
          continue;
        }
        if (event.event == 'error') {
          throw _structuredStreamFailure(
            event.jsonPayload?['code'],
            facts: tokenFacts,
            projectSource: projectSource,
            retryable: event.jsonPayload?['retryable'],
          );
        }
        if (event.event == 'done') {
          if (event.data.trim() != '[DONE]') {
            throw const LLMResponseIntegrityException.invalidResponse();
          }
          if (!completeJsonOutput) {
            throw LLMResponseIntegrityException.publicFailure(
              'modelStreamInterrupted',
              retryable: projectSource,
            );
          }
          if (projectSource) {
            onProjectTermination?.call(ProjectSourceTermination.complete);
          }
          return;
        }
        if (event.event == 'trace') continue;
        if (event.event != 'reply.delta' ||
            completeJsonOutput ||
            incompleteSourceOutput ||
            event.jsonPayload?['delta'] is! String) {
          throw const LLMResponseIntegrityException.invalidResponse();
        }
        yield event;
        continue;
      }
      if (event.event == 'error') {
        // In-stream provider errors are unstructured prose, not admission
        // codes. Do not interpret or expose their raw payload.
        throw const HostedLLMFailure(HostedLLMFailureKind.unavailable);
      }
      if (exposeDone) {
        if (event.event == 'done') {
          if (event.data.trim() != '[DONE]') {
            throw StateError('Invalid Maaso presentation done marker.');
          }
          yield event;
          return;
        }
        if (event.data.trim() == '[DONE]') {
          throw StateError('Invalid Maaso presentation terminal event.');
        }
      } else if (event.isDone) {
        return;
      }
      yield event;
    }
    if (jsonObject) {
      throw LLMResponseIntegrityException.publicFailure(
        'modelStreamInterrupted',
        retryable: projectSource,
      );
    }
    if (exposeDone) {
      throw StateError('Maaso presentation stream ended before protocol done.');
    }
  }

  static LLMResponseIntegrityException? _structuredHttpFailure(
    int status,
    String body, {
    bool projectSource = false,
    String? retryAfter,
  }) {
    LLMResponseIntegrityException? gatewayFailure([Object? permission]) =>
        projectSource &&
            const {502, 503, 504}.contains(status) &&
            (permission == null || permission == true)
        ? LLMResponseIntegrityException.publicFailure(
            'modelUnavailable',
            retryable: true,
            retryAfter: modelRetryAfter(retryAfter),
          )
        : null;
    try {
      final value = jsonDecode(body);
      if (value is! Map) return gatewayFailure();
      final nested = value['data'];
      final code = value['code'] ?? (nested is Map ? nested['code'] : null);
      if (code == null) {
        // A reverse proxy may return a bare gateway error. An application
        // code, including an unknown one, must never enter this fallback.
        return gatewayFailure(
          value['retryable'] ?? (nested is Map ? nested['retryable'] : null),
        );
      }
      if (projectSource) {
        final transient = switch ((status, code)) {
          (429, 'MODEL_RATE_LIMITED') => 'modelRateLimited',
          (>= 500 && <= 599, 'MODEL_PROVIDER_ERROR') => 'modelUnavailable',
          (
            >= 500 && <= 599,
            'MODEL_TRANSPORT_ERROR' || 'MODEL_STREAM_INCOMPLETE',
          ) =>
            'modelStreamInterrupted',
          _ => null,
        };
        if (transient != null) {
          final permission =
              value['retryable'] ??
              (nested is Map ? nested['retryable'] : null);
          final allowed = permission == null || permission == true;
          return LLMResponseIntegrityException.publicFailure(
            transient,
            retryable: allowed,
            retryAfter: allowed ? modelRetryAfter(retryAfter) : null,
          );
        }
      }
      return switch ((status, code)) {
        (429, 'GENERATION_CREDIT_INSUFFICIENT') =>
          const LLMResponseIntegrityException.publicFailure(
            'generationCreditInsufficient',
          ),
        (503, 'GENERATION_PROFILE_UNAVAILABLE') =>
          const LLMResponseIntegrityException.publicFailure(
            'generationProfileUnavailable',
          ),
        (
          400 || 422,
          'OUTPUT_FORMAT_UNSUPPORTED' || 'GENERATION_MODE_UNSUPPORTED',
        ) =>
          const LLMResponseIntegrityException.publicFailure(
            'structuredOutputUnsupported',
          ),
        (503, 'MODEL_AUTHENTICATION') =>
          const LLMResponseIntegrityException.publicFailure(
            'modelAuthentication',
          ),
        (429, 'MODEL_RATE_LIMITED') =>
          const LLMResponseIntegrityException.publicFailure('modelRateLimited'),
        (400, 'MODEL_CONTEXT_LIMIT') =>
          const LLMResponseIntegrityException.publicFailure(
            'modelContextLimit',
          ),
        (429, 'MODEL_QUOTA_EXCEEDED') =>
          const LLMResponseIntegrityException.publicFailure(
            'modelQuotaExceeded',
          ),
        _ => null,
      };
    } on FormatException {
      return gatewayFailure();
    }
  }

  static LLMResponseIntegrityException _structuredStreamFailure(
    Object? code, {
    LLMOutputFacts? facts,
    bool projectSource = false,
    Object? retryable,
  }) {
    if (projectSource) {
      final transient = switch (code) {
        'MODEL_STREAM_INCOMPLETE' ||
        'MODEL_TRANSPORT_ERROR' => 'modelStreamInterrupted',
        'MODEL_PROVIDER_ERROR' => 'modelUnavailable',
        'MODEL_RATE_LIMITED' => 'modelRateLimited',
        _ => null,
      };
      if (transient != null) {
        return LLMResponseIntegrityException.publicFailure(
          transient,
          retryable: retryable == true,
        );
      }
      final rejection = switch (code) {
        'MODEL_AUTHENTICATION' => 'modelAuthentication',
        'MODEL_CONTEXT_LIMIT' => 'modelContextLimit',
        'MODEL_QUOTA_EXCEEDED' => 'modelQuotaExceeded',
        'GENERATION_CREDIT_INSUFFICIENT' => 'generationCreditInsufficient',
        'GENERATION_PROFILE_UNAVAILABLE' => 'generationProfileUnavailable',
        'GENERATION_MODE_UNSUPPORTED' => 'structuredOutputUnsupported',
        _ => null,
      };
      if (rejection != null) {
        return LLMResponseIntegrityException.publicFailure(rejection);
      }
    }
    return switch (code) {
      'MODEL_OUTPUT_TRUNCATED' => LLMResponseIntegrityException.outputTruncated(
        facts: facts,
      ),
      'MODEL_SAFETY_BLOCKED' =>
        const LLMResponseIntegrityException.publicFailure('modelSafetyBlocked'),
      'OUTPUT_FORMAT_UNSUPPORTED' =>
        const LLMResponseIntegrityException.publicFailure(
          'structuredOutputUnsupported',
        ),
      'MODEL_STREAM_INCOMPLETE' || 'MODEL_TRANSPORT_ERROR' =>
        const LLMResponseIntegrityException.publicFailure(
          'modelStreamInterrupted',
        ),
      'MODEL_PROVIDER_ERROR' =>
        const LLMResponseIntegrityException.publicFailure('modelUnavailable'),
      _ => const LLMResponseIntegrityException.invalidResponse(),
    };
  }

  static Stream<String> _boundedSseLines(Stream<List<int>> bytes) async* {
    var lineBytes = <int>[];
    var eventBytes = 0;
    await for (final chunk in bytes) {
      for (final byte in chunk) {
        eventBytes++;
        if (eventBytes > _maxSseEventBytes) {
          throw StateError('Maaso thin proxy SSE event exceeded its limit.');
        }
        if (byte != 0x0a) {
          lineBytes.add(byte);
          continue;
        }
        if (lineBytes.isNotEmpty && lineBytes.last == 0x0d) {
          lineBytes.removeLast();
        }
        final line = utf8.decode(lineBytes, allowMalformed: false);
        lineBytes = <int>[];
        yield line;
        if (line.isEmpty) eventBytes = 0;
      }
    }
    if (lineBytes.isNotEmpty) {
      yield utf8.decode(lineBytes, allowMalformed: false);
    }
  }

  void close() {
    if (_ownsClient) _httpClient.close();
  }

  static Uri _normalizeBase(Uri uri) {
    final text = uri.toString();
    return text.endsWith('/') ? uri : Uri.parse('$text/');
  }

  static LLMStreamEvent? _sseEvent(String rawEvent) {
    String? eventName;
    final dataLines = <String>[];
    for (final line in rawEvent.split('\n')) {
      if (line.startsWith(':')) continue;
      if (line.startsWith('event:')) {
        final parsed = line.substring(6).trim();
        if (parsed.isNotEmpty) eventName = parsed;
        continue;
      }
      if (!line.startsWith('data:')) continue;
      dataLines.add(line.substring(5).trimLeft());
    }
    if (dataLines.isEmpty) return null;
    if (eventName == null || eventName.isEmpty) {
      throw StateError(
        'Maaso thin proxy stream missing Maaso SSE event name. '
        'Expected event: reply.delta/body.intent/task.signal/done.',
      );
    }
    return LLMStreamEvent(event: eventName, data: dataLines.join('\n').trim());
  }

  static int _maxTokensFor(List<Message> messages) {
    for (final message in messages) {
      if (message.content.contains('[maaso_mode:low_latency_voice]')) {
        return 384;
      }
    }
    return 8192;
  }
}
