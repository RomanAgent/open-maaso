import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// These protocols are opt-in model requests, never a Maaso backend session.
enum OfflineModelProtocol { openAiCompatible, anthropic, gemini }

class OfflineModelProvider {
  const OfflineModelProvider({
    required this.id,
    required this.label,
    required this.protocol,
    required this.baseUrl,
    required this.defaultModel,
    required this.documentationUrl,
  });

  final String id;
  final String label;
  final OfflineModelProtocol protocol;
  final String baseUrl;
  final String defaultModel;
  final String documentationUrl;

  // Public vendor endpoints and editable example model IDs. Model access and
  // regional endpoints are account-specific; saving never probes a provider.
  static const presets = <OfflineModelProvider>[
    OfflineModelProvider(
      id: 'openai',
      label: 'OpenAI',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://api.openai.com/v1',
      defaultModel: 'gpt-4.1-mini',
      documentationUrl:
          'https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create',
    ),
    OfflineModelProvider(
      id: 'anthropic',
      label: 'Anthropic Claude',
      protocol: OfflineModelProtocol.anthropic,
      baseUrl: 'https://api.anthropic.com/v1',
      defaultModel: 'claude-sonnet-5-5',
      documentationUrl:
          'https://platform.claude.com/docs/en/api/messages/create',
    ),
    OfflineModelProvider(
      id: 'gemini',
      label: 'Google Gemini',
      protocol: OfflineModelProtocol.gemini,
      baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
      defaultModel: 'gemini-3.8-flash',
      documentationUrl:
          'https://ai.google.dev/gemini-api/docs/generate-content/text-generation',
    ),
    OfflineModelProvider(
      id: 'deepseek',
      label: 'DeepSeek',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://api.deepseek.com',
      defaultModel: 'deepseek-flash',
      documentationUrl: 'https://api-docs.deepseek.com/',
    ),
    OfflineModelProvider(
      id: 'qwen',
      label: '通义千问 / Qwen',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
      defaultModel: 'qwen-plus',
      documentationUrl:
          'https://www.alibabacloud.com/help/en/model-studio/compatibility-of-openai-with-dashscope',
    ),
    OfflineModelProvider(
      id: 'doubao',
      label: '豆包 / 火山方舟',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://ark.cn-beijing.volces.com/api/v3',
      defaultModel: 'doubao-seed-2-1-pro-260915',
      documentationUrl:
          'https://console.volcengine.com/ark/region:cn-beijing/docs/base-url-and-authentication',
    ),
    OfflineModelProvider(
      id: 'moonshot',
      label: 'Kimi / Moonshot',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://api.moonshot.cn/v1',
      defaultModel: 'kimi-k3.1-pro',
      documentationUrl: 'https://platform.kimi.com/docs/api/chat',
    ),
    OfflineModelProvider(
      id: 'zhipu',
      label: '智谱 GLM',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://open.bigmodel.cn/api/paas/v4',
      defaultModel: 'glm-5.3',
      documentationUrl: 'https://docs.bigmodel.cn/cn/api/introduction',
    ),
    OfflineModelProvider(
      id: 'siliconflow',
      label: '硅基流动 / SiliconFlow',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://api.siliconflow.cn/v1',
      defaultModel: 'Qwen/Qwen3-8B',
      documentationUrl: 'https://docs.siliconflow.cn/docs/userguide/quickstart',
    ),
    OfflineModelProvider(
      id: 'groq',
      label: 'Groq',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'https://api.groq.com/openai/v1',
      defaultModel: 'openai/gpt-oss-120b',
      documentationUrl: 'https://console.groq.com/docs/openai',
    ),
    OfflineModelProvider(
      id: 'ollama',
      label: 'Ollama / 本机模型服务',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: 'http://127.0.0.1:11434/v1',
      defaultModel: 'qwen3:8b',
      documentationUrl: 'https://docs.ollama.com/api/openai-compatibility',
    ),
    OfflineModelProvider(
      id: 'custom',
      label: '自定义 OpenAI 兼容服务',
      protocol: OfflineModelProtocol.openAiCompatible,
      baseUrl: '',
      defaultModel: '',
      documentationUrl:
          'https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create',
    ),
  ];

  static OfflineModelProvider fromId(String id) {
    for (final provider in presets) {
      if (provider.id == id) return provider;
    }
    throw const OfflineModelException('unknown_provider');
  }
}

class OfflineProviderConfig {
  const OfflineProviderConfig({
    required this.providerId,
    this.enabled = false,
    required this.baseUrl,
    required this.model,
  });

  final String providerId;
  final bool enabled;
  final String baseUrl;
  final String model;

  OfflineModelProvider get provider => OfflineModelProvider.fromId(providerId);

  OfflineProviderConfig copyWith({
    String? providerId,
    bool? enabled,
    String? baseUrl,
    String? model,
  }) => OfflineProviderConfig(
    providerId: providerId ?? this.providerId,
    enabled: enabled ?? this.enabled,
    baseUrl: baseUrl ?? this.baseUrl,
    model: model ?? this.model,
  );

  /// Validation is synchronous and performs no DNS lookup or network probe.
  Uri get endpoint {
    final selected = provider;
    final uri = Uri.tryParse(baseUrl.trim());
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        RegExp(r'[\x00-\x20\\]').hasMatch(baseUrl.trim()) ||
        RegExp(
          r'/(?:\.|%2e){1,2}(?:/|$)',
          caseSensitive: false,
        ).hasMatch(baseUrl.trim()) ||
        uri.pathSegments.any(
          (s) => s == '.' || s == '..' || s.contains('/') || s.contains('\\'),
        ) ||
        !(uri.scheme == 'https' || (uri.scheme == 'http' && isLoopback(uri)))) {
      throw const OfflineModelException('invalid_endpoint');
    }
    final name = model.trim();
    if (name.isEmpty ||
        name.length > 200 ||
        RegExp(r'[\x00-\x20]').hasMatch(name)) {
      throw const OfflineModelException('invalid_model');
    }
    var path = uri.path.replaceAll(RegExp(r'/+$'), '');
    switch (selected.protocol) {
      case OfflineModelProtocol.openAiCompatible:
        if (!path.endsWith('/chat/completions')) path += '/chat/completions';
      case OfflineModelProtocol.anthropic:
        if (!path.endsWith('/messages')) path += '/messages';
      case OfflineModelProtocol.gemini:
        final modelName = name.startsWith('models/') ? name.substring(7) : name;
        if (!RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._-]{0,199}$',
        ).hasMatch(modelName)) {
          throw const OfflineModelException('invalid_model');
        }
        path += '/models/$modelName:generateContent';
    }
    return uri.replace(path: path);
  }

  static bool isLoopback(Uri uri) => const {
    'localhost',
    '127.0.0.1',
    '::1',
    '[::1]',
  }.contains(uri.host.toLowerCase());
}

class OfflineModelMessage {
  const OfflineModelMessage({required this.role, required this.content});
  final String role;
  final String content;
}

/// Only fixed, non-sensitive diagnostics cross the transport boundary.
class OfflineModelException implements Exception {
  const OfflineModelException(this.code, {this.statusCode});
  final String code;
  final int? statusCode;

  String get message => switch (code) {
    'disabled' => '在线模型尚未启用；本地功能仍可使用。',
    'missing_api_key' => '请先在设置中保存此模型服务的 API Key。',
    'invalid_api_key' => 'API Key 格式无效，请检查设置。',
    'invalid_endpoint' => '模型地址须为 HTTPS；本机回环地址可使用 HTTP，且不能含账号、查询或片段。',
    'invalid_model' => '请填写有效的模型名称。',
    'unknown_provider' => '请选择支持的模型服务商。',
    'invalid_messages' => '对话内容为空、过长或格式不受支持。',
    'busy' => '上一条模型请求尚未结束。',
    'cancelled' => '模型请求已取消。',
    'timeout' => '模型请求超时，请稍后重试。',
    'redirect_rejected' => '模型地址发生重定向；请直接配置最终的可信 API 地址。',
    'http_error' => '模型服务拒绝了请求（HTTP $statusCode），请检查地址、模型和密钥。',
    'response_too_large' => '模型回复超过本地接收上限。',
    'truncated_response' => '模型回复被截断，请简化需求或选择其他模型。',
    'invalid_response' => '模型服务返回了无法识别的响应。',
    'empty_response' => '模型没有返回可用的文本回复。',
    'closed' => '模型连接已关闭。',
    _ => '模型服务连接失败；请检查网络和模型设置。',
  };

  @override
  String toString() => message;
}

/// A text-only, one-request-at-a-time BYOK boundary. Construction and settings
/// validation are network-free. There are no retries, redirects or probes.
class OfflineModelClient {
  OfflineModelClient({
    http.Client? client,
    this.timeout = const Duration(seconds: 90),
    this.maxResponseBytes = 2 * 1024 * 1024,
  }) : _client = client ?? http.Client() {
    if (timeout <= Duration.zero ||
        timeout > const Duration(minutes: 3) ||
        maxResponseBytes < 1 ||
        maxResponseBytes > 4 * 1024 * 1024) {
      throw ArgumentError('Invalid bounded model request limits.');
    }
  }

  final http.Client _client;
  final Duration timeout;
  final int maxResponseBytes;
  Completer<void>? _activeAbort;
  int _generation = 0;
  bool _closed = false;

  bool get busy => _activeAbort != null;

  Future<String> complete({
    required OfflineProviderConfig config,
    required String apiKey,
    required List<OfflineModelMessage> messages,
  }) async {
    if (_closed) throw const OfflineModelException('closed');
    if (!config.enabled) throw const OfflineModelException('disabled');
    if (busy) throw const OfflineModelException('busy');
    final uri = config.endpoint;
    final credential = apiKey.trim();
    if (credential.isEmpty && !OfflineProviderConfig.isLoopback(uri)) {
      throw const OfflineModelException('missing_api_key');
    }
    if (credential.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(credential)) {
      throw const OfflineModelException('invalid_api_key');
    }
    if (messages.isEmpty ||
        messages.length > 100 ||
        messages.any(
          (m) =>
              !const {'system', 'user', 'assistant'}.contains(m.role) ||
              m.content.trim().isEmpty,
        ) ||
        !messages.any((m) => m.role == 'user')) {
      throw const OfflineModelException('invalid_messages');
    }
    final payload = _body(config, messages);
    final bytes = utf8.encode(jsonEncode(payload));
    if (bytes.length > 1024 * 1024) {
      throw const OfflineModelException('invalid_messages');
    }
    final abort = Completer<void>();
    final generation = ++_generation;
    _activeAbort = abort;
    try {
      return await _request(
        config,
        uri,
        credential,
        bytes,
        abort,
        generation,
      ).timeout(
        timeout,
        onTimeout: () {
          if (!abort.isCompleted) abort.complete();
          throw const OfflineModelException('timeout');
        },
      );
    } on OfflineModelException {
      rethrow;
    } catch (_) {
      // Transport exceptions can contain URLs, credentials or response bodies.
      throw OfflineModelException(
        generation != _generation ? 'cancelled' : 'transport_error',
      );
    } finally {
      if (identical(_activeAbort, abort)) _activeAbort = null;
    }
  }

  Future<String> _request(
    OfflineProviderConfig config,
    Uri uri,
    String apiKey,
    List<int> body,
    Completer<void> abort,
    int generation,
  ) async {
    final request =
        http.AbortableRequest('POST', uri, abortTrigger: abort.future)
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers['content-type'] = 'application/json'
          ..headers['accept'] = 'application/json'
          ..bodyBytes = body;
    if (apiKey.isNotEmpty) {
      switch (config.provider.protocol) {
        case OfflineModelProtocol.openAiCompatible:
          request.headers['authorization'] = 'Bearer $apiKey';
        case OfflineModelProtocol.anthropic:
          request.headers['x-api-key'] = apiKey;
        case OfflineModelProtocol.gemini:
          request.headers['x-goog-api-key'] = apiKey;
      }
    }
    if (config.provider.protocol == OfflineModelProtocol.anthropic) {
      request.headers['anthropic-version'] = '2026-10-21';
    }
    final response = await _client.send(request);
    _requireCurrent(generation);
    if (response.statusCode >= 300 && response.statusCode < 400) {
      if (!abort.isCompleted) abort.complete();
      throw const OfflineModelException('redirect_rejected');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      if (!abort.isCompleted) abort.complete();
      throw OfflineModelException(
        'http_error',
        statusCode: response.statusCode,
      );
    }
    if ((response.contentLength ?? 0) > maxResponseBytes) {
      if (!abort.isCompleted) abort.complete();
      throw const OfflineModelException('response_too_large');
    }
    final result = BytesBuilder(copy: false);
    await for (final chunk in response.stream) {
      _requireCurrent(generation);
      if (result.length + chunk.length > maxResponseBytes) {
        if (!abort.isCompleted) abort.complete();
        throw const OfflineModelException('response_too_large');
      }
      result.add(chunk);
    }
    _requireCurrent(generation);
    Object? json;
    try {
      json = jsonDecode(utf8.decode(result.takeBytes()));
    } on FormatException {
      throw const OfflineModelException('invalid_response');
    }
    return _readText(config.provider.protocol, json);
  }

  void _requireCurrent(int generation) {
    if (_closed || generation != _generation) {
      throw const OfflineModelException('cancelled');
    }
  }

  void cancel() {
    ++_generation;
    final abort = _activeAbort;
    _activeAbort = null;
    if (abort != null && !abort.isCompleted) abort.complete();
  }

  void close() {
    if (_closed) return;
    _closed = true;
    cancel();
    _client.close();
  }

  static Map<String, Object?> _body(
    OfflineProviderConfig config,
    List<OfflineModelMessage> messages,
  ) {
    final system = messages
        .where((m) => m.role == 'system')
        .map((m) => m.content)
        .join('\n\n');
    final conversation = messages.where((m) => m.role != 'system');
    return switch (config.provider.protocol) {
      OfflineModelProtocol.openAiCompatible => {
        'model': config.model.trim(),
        'messages': messages
            .map((m) => {'role': m.role, 'content': m.content})
            .toList(),
        'stream': false,
        if (config.providerId == 'openai')
          'max_completion_tokens': 8192
        else
          'max_tokens': 8192,
      },
      OfflineModelProtocol.anthropic => {
        'model': config.model.trim(),
        'max_tokens': 8192,
        if (system.isNotEmpty) 'system': system,
        'messages': conversation
            .map((m) => {'role': m.role, 'content': m.content})
            .toList(),
      },
      OfflineModelProtocol.gemini => {
        if (system.isNotEmpty)
          'systemInstruction': {
            'parts': [
              {'text': system},
            ],
          },
        'contents': conversation
            .map(
              (m) => {
                'role': m.role == 'assistant' ? 'model' : 'user',
                'parts': [
                  {'text': m.content},
                ],
              },
            )
            .toList(),
        'generationConfig': {'maxOutputTokens': 8192},
      },
    };
  }

  static String _readText(OfflineModelProtocol protocol, Object? response) {
    if (response is! Map<String, dynamic>) {
      throw const OfflineModelException('invalid_response');
    }
    String text;
    bool terminalComplete;
    switch (protocol) {
      case OfflineModelProtocol.openAiCompatible:
        final choices = response['choices'];
        if (choices is! List || choices.isEmpty || choices.first is! Map) {
          throw const OfflineModelException('empty_response');
        }
        final choice = choices.first as Map;
        if (choice['finish_reason'] == 'length') {
          throw const OfflineModelException('truncated_response');
        }
        final message = choice['message'];
        if (message is! Map) {
          throw const OfflineModelException('invalid_response');
        }
        text = _textParts(message['content']);
        terminalComplete =
            choice['finish_reason'] == 'stop' && message['refusal'] == null;
      case OfflineModelProtocol.anthropic:
        if (response['stop_reason'] == 'max_tokens') {
          throw const OfflineModelException('truncated_response');
        }
        text = _textParts(response['content']);
        terminalComplete = const {
          'end_turn',
          'stop_sequence',
        }.contains(response['stop_reason']);
      case OfflineModelProtocol.gemini:
        final candidates = response['candidates'];
        if (candidates is! List ||
            candidates.isEmpty ||
            candidates.first is! Map) {
          throw const OfflineModelException('empty_response');
        }
        final candidate = candidates.first as Map;
        if (candidate['finishReason'] == 'MAX_TOKENS') {
          throw const OfflineModelException('truncated_response');
        }
        final content = candidate['content'];
        if (content is! Map) {
          throw const OfflineModelException('empty_response');
        }
        text = _textParts(content['parts']);
        terminalComplete = candidate['finishReason'] == 'STOP';
    }
    if (text.trim().isEmpty) {
      throw const OfflineModelException('empty_response');
    }
    if (!terminalComplete) {
      throw const OfflineModelException('invalid_response');
    }
    return text.trim();
  }

  static String _textParts(Object? content) {
    if (content is String) return content;
    if (content is! List) return '';
    return content
        .whereType<Map>()
        .where(
          (part) =>
              part['text'] is String &&
              part['thought'] != true &&
              (part['type'] == null || part['type'] == 'text'),
        )
        .map((part) => part['text'] as String)
        .join('\n');
  }
}
