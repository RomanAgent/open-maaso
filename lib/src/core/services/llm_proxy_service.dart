import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/direct_vendor_llm_client.dart';
import 'package:maaso/src/offline/offline_model_client.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/realtime_agent_config.dart';
import 'package:maaso/src/core/services/model_prompt_logger.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/llm/presentation_stream_limits.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

/// Output ceiling for cloud generations (~tokens; chars ≈ tokens×3-4). Generous
/// so a full card isn't truncated today; SP-A templates shrink output so this
/// can drop later. A ceiling, never a target — small turns are unaffected.
const int kCloudMaxOutputTokens = 8192;

/// Per-provider request-body knobs, plus the universal [kCloudMaxOutputTokens]
/// ceiling merged into every cloud request.
///   • Volcano Ark (Doubao): `thinking.type:"disabled"` suppresses the reasoning
///     preamble (saves 1-3s TTFT); non-thinking models silently ignore it.
/// Other providers get no extra knobs (DeepSeek picks reasoning by model name,
/// Anthropic uses a different surface, OpenAI's reasoning_effort is model-gated).
@visibleForTesting
Map<String, dynamic> cloudExtraBodyFor(String baseUrl, String model) {
  final u = baseUrl.toLowerCase();
  if (u.contains('volces.com') || u.contains('volcengineapi')) {
    return const {
      'thinking': {'type': 'disabled'},
      'max_tokens': kCloudMaxOutputTokens,
    };
  }
  return const {'max_tokens': kCloudMaxOutputTokens};
}

/// Shared LLM client factory.
///
/// All [AgentRuntime]s consume [LiveLLMClient] (below) — a thin shim that
/// re-reads BYOK config on every call, so changing Provider in Settings
/// takes effect immediately without rebuilding the agent kernel.
class LLMProxyService extends AppService {
  LLMProxyService({
    FutureOr<void> Function(LLMClient client)? cachedClientCloser,
    this.localEdition = false,
  }) : _cachedClientCloser = cachedClientCloser ?? _closeDefaultCachedClient;

  final bool localEdition;
  final SecureStorageService _storage = appServices
      .find<SecureStorageService>();
  final FutureOr<void> Function(LLMClient client) _cachedClientCloser;

  // Cache identities contain only irreversible configuration/owner
  // fingerprints. Raw API keys and account access tokens must never be kept in
  // a cache key that survives the request-local stack frame.
  String? _cacheKey;
  LLMClient? _cached;
  LLMClient? _pendingClose;
  final Set<Future<void>> _clientResolutions = <Future<void>>{};
  Future<void>? _accountDrainFuture;
  int _cacheGeneration = 0;
  bool _accountDrainActive = false;
  MaasoAuthSession? _refreshingProxySession;
  Future<bool>? _proxySessionRefresh;

  late final LiveLLMClient liveClient = LiveLLMClient(this);

  @visibleForTesting
  String? get cacheKeyForTesting => _cacheKey;

  @visibleForTesting
  LLMClient? get cachedClientForTesting => _cached;

  @visibleForTesting
  bool get accountDrainActiveForTesting => _accountDrainActive;

  /// Resolve the current OpenAIProvider from secure storage.
  /// Returns null when BYOK isn't set up yet (onboarding incomplete).
  Future<LLMClient?> ensureClient() {
    if (_accountDrainActive) return Future<LLMClient?>.value();
    final generation = _cacheGeneration;
    final privacy = appServices.maybeFind<PrivacyService>();
    final operation = _ensureClientForGeneration(generation).then((client) {
      if (client == null) return null;
      if (localEdition) {
        final key = _cacheKey;
        return privacyGuardedLLMClient(client, () async {
          if (!_canResolveClient(generation) || key == null) {
            throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
          }
          final config = await LLMDirectCloudConfig.readFrom(_storage);
          if (!_canResolveClient(generation) ||
              config == null ||
              !config.enabled ||
              _directCacheKey(config) != key) {
            throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
          }
        });
      }
      return privacyGuardedLLMClient(client, () async {
        void requireCurrent() {
          if (!_canResolveClient(generation) ||
              privacy == null ||
              !privacy.isCurrent ||
              !identical(privacy, appServices.maybeFind<PrivacyService>())) {
            throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
          }
        }

        requireCurrent();
        if (client is OpenAIProvider) {
          await privacy!.requireCloud(
            origin: Uri.parse(client.baseUrl),
            scope: PrivacyScopes.cloudText,
          );
        } else if (client is MaasoThinProxyLLMClient) {
          await privacy!.requireConsent(
            recipientId: 'ark',
            scope: PrivacyScopes.cloudText,
          );
        } else {
          throw const PrivacyException('PRIVACY_UNAVAILABLE');
        }
        requireCurrent();
      });
    });
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _clientResolutions.remove(tracked));
    _clientResolutions.add(tracked);
    return operation;
  }

  Future<LLMClient?> _ensureClientForGeneration(int generation) async {
    if (!_canResolveClient(generation)) return null;
    switch (_pipelineMode) {
      case AgentPipelineMode.localFull:
        return null;
      case AgentPipelineMode.directCloud:
        return _ensureDirectCloudClient(generation);
      case AgentPipelineMode.proxyDefault:
      case AgentPipelineMode.volcRealtimeAudio:
        final model =
            await _storage.read(GlobalConstant.keyLlmModel) ??
            LLMDefaults.model;
        if (!_canResolveClient(generation)) return null;
        return _ensureMaasoThinProxyClient(model, generation);
    }
  }

  AgentPipelineMode get _pipelineMode => localEdition
      ? AgentPipelineMode.directCloud
      : appServices.isRegistered<MaasoAgentModeService>()
      ? appServices.find<MaasoAgentModeService>().pipelineMode.value
      : AgentPipelineMode.defaultMode;

  Future<LLMClient?> _ensureDirectCloudClient(int generation) async {
    final config = await LLMDirectCloudConfig.readFrom(_storage);
    if (config == null || !config.enabled || !_canResolveClient(generation)) {
      return null;
    }

    final apiKey = config.apiKey;
    final vendorConfig = localEdition ? directVendorConfig(config) : null;
    final localEndpoint =
        vendorConfig != null &&
        OfflineProviderConfig.isLoopback(vendorConfig.endpoint);
    if ((apiKey.isEmpty && !localEndpoint) || !_canResolveClient(generation)) {
      return null;
    }
    final baseUrl = config.baseUrl;
    final model = config.model;

    final key = _directCacheKey(config);
    if (key == _cacheKey && _cached != null) return _cached;

    final LLMClient client =
        vendorConfig != null &&
            vendorConfig.provider.protocol !=
                OfflineModelProtocol.openAiCompatible
        ? DirectVendorLLMClient(config: config)
        : OpenAIProvider(
            apiKey: apiKey,
            baseUrl: baseUrl,
            model: model,
            extraBody: cloudExtraBodyFor(baseUrl, model),
            httpClient: appServices
                .maybeFind<DailyTokenUsageService>()
                ?.createClient(),
          );
    _cacheKey = key;
    _cached = client;
    return client;
  }

  Future<LLMClient?> _ensureMaasoThinProxyClient(
    String model,
    int generation,
  ) async {
    if (!appServices.isRegistered<RealtimeAgentConfig>() ||
        !appServices.isRegistered<AuthSessionService>()) {
      return null;
    }
    final config = appServices.find<RealtimeAgentConfig>();
    final baseUri = config.baseUri;
    if (!config.isReady || baseUri == null) return null;
    final auth = appServices.find<AuthSessionService>();
    final published = auth.session.value;
    if (published == null) return null;
    final accountUuid = published.accountUuid.trim();
    if (accountUuid.isEmpty || !_canResolveClient(generation)) return null;
    final token = await _resolveProxyAccessToken(
      auth: auth,
      config: config,
      baseUri: baseUri,
      accountUuid: accountUuid,
      generation: generation,
    );
    if (token == null ||
        !_canResolveClient(generation) ||
        !config.isReady ||
        config.baseUri != baseUri ||
        auth.session.value?.accountUuid.trim() != accountUuid) {
      return null;
    }

    final ownerFingerprint = _fingerprint(
      'maaso-proxy-owner-v1\u0000$accountUuid',
    );
    final key =
        'maaso-proxy|${_fingerprint('$baseUri\u0000$model')}|$ownerFingerprint';
    if (key == _cacheKey && _cached != null) return _cached;
    final client = MaasoThinProxyLLMClient(
      baseUri: baseUri,
      model: model,
      httpClient: appServices
          .maybeFind<DailyTokenUsageService>()
          ?.createClient(),
      accessTokenProvider: () async {
        final token = await _resolveProxyAccessToken(
          auth: auth,
          config: config,
          baseUri: baseUri,
          accountUuid: accountUuid,
          generation: generation,
        );
        // A cached transport may outlive its account or environment while
        // refreshing. Do not dispatch its old request without credentials.
        if (token == null) {
          throw const HostedLLMFailure(HostedLLMFailureKind.authentication);
        }
        return token;
      },
    );
    _cacheKey = key;
    _cached = client;
    return client;
  }

  Future<String?> _resolveProxyAccessToken({
    required AuthSessionService auth,
    required RealtimeAgentConfig config,
    required Uri baseUri,
    required String accountUuid,
    required int generation,
  }) async {
    bool isCurrent() =>
        _canResolveClient(generation) &&
        identical(auth, appServices.maybeFind<AuthSessionService>()) &&
        identical(config, appServices.maybeFind<RealtimeAgentConfig>()) &&
        config.isReady &&
        config.baseUri == baseUri &&
        auth.session.value?.accountUuid.trim() == accountUuid;

    if (!isCurrent()) return null;
    final published = auth.session.value!;
    if (!published.isValid) {
      // A mounted session can expire while Home stays open. Refresh only its
      // published credentials; raw storage/candidates must never activate a
      // new account here. Coalesce callers sharing that exact expired session.
      var refreshing = _proxySessionRefresh;
      if (refreshing == null ||
          !identical(_refreshingProxySession, published)) {
        _refreshingProxySession = published;
        TurnTrace.event('cloud.proxy_session.refresh');
        refreshing = auth.restoreOrRefresh();
        _proxySessionRefresh = refreshing;
      }
      bool refreshed;
      try {
        refreshed = await refreshing;
      } finally {
        if (identical(_proxySessionRefresh, refreshing)) {
          _proxySessionRefresh = null;
          _refreshingProxySession = null;
        }
      }
      if (!refreshed || !isCurrent()) return null;
    }
    final current = auth.session.value;
    if (!isCurrent() || current == null || !current.isValid) return null;
    final token = current.accessToken.trim();
    return token.isEmpty ? null : token;
  }

  /// Fences new cache resolutions, removes the active account's cached client
  /// synchronously, and waits for both admitted resolutions and client close.
  /// A failed close remains fenced and is retried by the next call.
  Future<void> deactivateAccountAndDrain() {
    final inFlight = _accountDrainFuture;
    if (inFlight != null) return inFlight;
    if (!_accountDrainActive) {
      _accountDrainActive = true;
      _cacheGeneration++;
      _detachCachedClient();
    }
    return _accountDrainFuture = _deactivateAccountAndDrainOnce();
  }

  Future<void> _deactivateAccountAndDrainOnce() async {
    var completed = false;
    try {
      while (_clientResolutions.isNotEmpty) {
        await Future.wait<void>(_clientResolutions.toList(growable: false));
      }
      _detachCachedClient();
      final pending = _pendingClose;
      if (pending != null) {
        await Future<void>.sync(() => _cachedClientCloser(pending));
        if (identical(_pendingClose, pending)) _pendingClose = null;
      }
      completed = true;
    } finally {
      _accountDrainFuture = null;
      if (completed) _accountDrainActive = false;
    }
  }

  void _detachCachedClient() {
    final client = _cached;
    _cacheKey = null;
    _cached = null;
    if (client == null || identical(client, _pendingClose)) return;
    if (_pendingClose != null) {
      throw StateError('An LLM proxy cache close is already pending.');
    }
    _pendingClose = client;
  }

  bool _canResolveClient(int generation) =>
      !_accountDrainActive && generation == _cacheGeneration;

  static String _directCacheKey(LLMDirectCloudConfig config) =>
      'direct-cloud|${_fingerprint('${config.apiKey}\u0000${config.baseUrl}\u0000${config.model}')}';

  static String _fingerprint(String value) =>
      sha256.convert(utf8.encode(value)).toString();

  static void _closeDefaultCachedClient(LLMClient client) {
    if (client is MaasoThinProxyLLMClient) client.close();
    if (client is DirectVendorLLMClient) client.close();
  }

  /// Direct LLM round-trip — bypasses the agent kernel (no skills/sandbox).
  /// Use [AgentRuntime.chat] for full orchestration.
  Future<String> chat(
    String prompt, {
    AppLocale? locale,
    List<Map<String, String>>? history,
  }) async {
    final turnLocale = locale ?? AgentPromptCatalog.currentLocale;
    final client = await ensureClient();
    if (client == null) {
      return AgentPromptCatalog.text(
        'app.home.api_key_missing_error',
        locale: turnLocale,
      );
    }

    final messages = <Message>[
      Message.system(
        AgentPromptCatalog.text(
          'provider.direct_chat_system',
          locale: turnLocale,
        ),
      ),
      if (history != null)
        ...history.map(
          (h) =>
              Message(role: h['role'] ?? 'user', content: h['content'] ?? ''),
        ),
      Message.user(prompt),
    ];
    try {
      ModelPromptLogger.logMessages(
        'cloud/direct-chat',
        _messageRecords(messages),
      );
      final sw = TurnTrace.stopwatch(
        'cloud.direct_chat',
        details: 'messages=${messages.length}',
      );
      final reply = await client.chat(messages);
      TurnTrace.done(
        'cloud.direct_chat',
        sw,
        details: 'reply_chars=${reply.length}',
      );
      return reply;
    } catch (e) {
      TurnTrace.event('cloud.direct_chat.error', details: 'error=$e');
      return AgentPromptCatalog.text(
        'app.home.direct_chat_error',
        locale: turnLocale,
      );
    }
  }
}

/// LLMClient that defers to [LLMProxyService.ensureClient] on every call.
///
/// Lets long-lived agent runtimes pick up new BYOK config (key/baseUrl/model)
/// the moment the user saves Settings, without having to dispose + rebuild
/// the whole kernel.
class LiveLLMClient
    implements
        LLMClient,
        PresentationStreamingLLMClient,
        PrivacyAdmissionLLMClient,
        StructuredOutputLLMClient,
        StructuredOutputClientResolver,
        ProjectSourceLLMClient {
  LiveLLMClient(this._proxy);
  final LLMProxyService _proxy;

  @override
  // First-response headroom for long generations (e.g. a full card). The
  // stream's only timeout is time-to-first-response, not total generation.
  Duration get defaultTimeout => const Duration(seconds: 90);

  @override
  Future<LLMClient> resolveStructuredOutputClient() async {
    final healthSession = _captureCloudHealthSession();
    final client = await _proxy.ensureClient();
    if (client == null) throw StateError('chat.llm_api_key_missing'.tr);
    final generation = _proxy._cacheGeneration;
    final mode = _proxy._pipelineMode;
    final key = _proxy._cacheKey;
    final transport = _proxy._cached;
    final privacy = appServices.maybeFind<PrivacyService>();
    bool isSnapshotMounted() =>
        _proxy._canResolveClient(generation) &&
        _proxy._pipelineMode == mode &&
        key != null &&
        _proxy._cacheKey == key &&
        identical(_proxy._cached, transport) &&
        (_proxy.localEdition ||
            (privacy?.isCurrent == true &&
                identical(privacy, appServices.maybeFind<PrivacyService>())));

    Future<void> requireCurrent() async {
      void requireMounted() {
        if (!_proxy._canResolveClient(generation) ||
            _proxy._pipelineMode != mode ||
            key == null ||
            _proxy._cacheKey != key ||
            !identical(_proxy._cached, transport)) {
          throw const LLMResponseIntegrityException.publicFailure(
            'interrupted',
          );
        }
      }

      requireMounted();
      String? currentKey;
      if (mode == AgentPipelineMode.directCloud) {
        final config = await LLMDirectCloudConfig.readFrom(_proxy._storage);
        if (config != null &&
            config.enabled &&
            (config.apiKey.isNotEmpty || _proxy.localEdition)) {
          currentKey =
              'direct-cloud|${LLMProxyService._fingerprint('${config.apiKey}\u0000${config.baseUrl}\u0000${config.model}')}';
        }
      } else {
        final model =
            await _proxy._storage.read(GlobalConstant.keyLlmModel) ??
            LLMDefaults.model;
        final config = appServices.maybeFind<RealtimeAgentConfig>();
        final account = appServices
            .maybeFind<AuthSessionService>()
            ?.session
            .value
            ?.accountUuid
            .trim();
        final baseUri = config?.baseUri;
        if (config?.isReady == true &&
            baseUri != null &&
            account != null &&
            account.isNotEmpty) {
          final owner = LLMProxyService._fingerprint(
            'maaso-proxy-owner-v1\u0000$account',
          );
          currentKey =
              'maaso-proxy|${LLMProxyService._fingerprint('$baseUri\u0000$model')}|$owner';
        }
      }
      requireMounted();
      if (currentKey != key) {
        throw const LLMResponseIntegrityException.publicFailure('interrupted');
      }
    }

    await requireCurrent();
    return _PinnedStructuredOutputClient(
      client,
      healthSession,
      requireCurrent,
      defaultTimeout,
      isSnapshotMounted,
    );
  }

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) async => chatJsonObjectWithPrivacyAdmission(
    await resolveStructuredOutputClient(),
    messages,
    timeout: timeout,
    onAdmitted: onAdmitted ?? () {},
  );

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async => generateProjectSourceWithPrivacyAdmission(
    await resolveStructuredOutputClient(),
    messages,
    timeout: timeout,
    shouldCancel: shouldCancel,
    onAdmitted: onAdmitted ?? () {},
  );

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    final healthSession = _captureCloudHealthSession();
    final client = await _proxy.ensureClient();
    if (client == null) {
      throw StateError('chat.llm_api_key_missing'.tr);
    }
    ModelPromptLogger.logMessages('cloud/chat', _messageRecords(messages));
    final sw = TurnTrace.stopwatch(
      'cloud.chat',
      details: 'messages=${messages.length}',
    );
    try {
      final reply = await client.chat(messages, timeout: timeout);
      TurnTrace.done('cloud.chat', sw, details: 'reply_chars=${reply.length}');
      _reportCloudSuccess(healthSession);
      return reply;
    } catch (e) {
      TurnTrace.event('cloud.chat.error', details: 'error=$e');
      _reportCloudFailure(e, healthSession);
      rethrow;
    }
  }

  /// Narrow owned-turn callers defer final admission through configuration,
  /// privacy wrappers and the actual transport's authentication preparation.
  /// Plain chat/stream APIs remain independent of this optional capability.
  @override
  Future<String> chatWithAdmission(
    List<Message> messages, {
    Duration? timeout,
    required void Function() onAdmitted,
  }) async {
    final healthSession = _captureCloudHealthSession();
    final client = await _proxy.ensureClient();
    if (client == null) throw StateError('chat.llm_api_key_missing'.tr);
    var admitted = false;
    try {
      final reply = await chatWithPrivacyAdmission(
        client,
        messages,
        timeout: timeout,
        onAdmitted: () {
          onAdmitted();
          admitted = true;
        },
      );
      _reportCloudSuccess(healthSession);
      return reply;
    } catch (error) {
      // Rejected local admission never becomes a provider health failure.
      if (admitted) _reportCloudFailure(error, healthSession);
      rethrow;
    }
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    final healthSession = _captureCloudHealthSession();
    final client = await _proxy.ensureClient();
    if (client == null) {
      throw StateError('chat.llm_api_key_missing'.tr);
    }
    ModelPromptLogger.logPrompt('cloud/generate-json', prompt);
    final sw = TurnTrace.stopwatch(
      'cloud.generate_json',
      details: 'chars=${prompt.length}',
    );
    try {
      final reply = await client.generateJson(prompt, timeout: timeout);
      TurnTrace.done(
        'cloud.generate_json',
        sw,
        details: 'reply_chars=${reply.length}',
      );
      _reportCloudSuccess(healthSession);
      return reply;
    } catch (e) {
      TurnTrace.event('cloud.generate_json.error', details: 'error=$e');
      _reportCloudFailure(e, healthSession);
      rethrow;
    }
  }

  /// Forward streaming to the live underlying provider so OpenAI's real
  /// SSE stays end-to-end.  If the live provider doesn't override
  /// streamChat itself, its abstract default (single yield via [chat])
  /// kicks in transparently.
  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    final healthSession = _captureCloudHealthSession();
    final client = await _proxy.ensureClient();
    if (client == null) {
      throw StateError('chat.llm_api_key_missing'.tr);
    }
    ModelPromptLogger.logMessages(
      'cloud/stream-chat',
      _messageRecords(messages),
    );
    final sw = TurnTrace.stopwatch(
      'cloud.stream',
      details: 'messages=${messages.length}',
    );
    var sawFirstToken = false;
    var chunkCount = 0;
    var charCount = 0;
    try {
      await for (final chunk in client.streamChat(messages, timeout: timeout)) {
        chunkCount++;
        charCount += chunk.length;
        if (!sawFirstToken && chunk.isNotEmpty) {
          sawFirstToken = true;
          TurnTrace.event(
            'cloud.ttft',
            details: 'ms=${sw.elapsedMilliseconds} first_chars=${chunk.length}',
          );
        }
        yield chunk;
      }
      TurnTrace.done(
        'cloud.stream',
        sw,
        details:
            'chunks=$chunkCount chars=$charCount firstToken=$sawFirstToken',
      );
      _reportCloudSuccess(healthSession);
    } catch (e) {
      TurnTrace.event('cloud.stream.error', details: 'error=$e');
      _reportCloudFailure(e, healthSession);
      rethrow;
    }
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => _streamChatEvents(messages, timeout: timeout, presentation: false);

  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => _streamChatEvents(messages, timeout: timeout, presentation: true);

  Stream<LLMStreamEvent> _streamChatEvents(
    List<Message> messages, {
    required bool presentation,
    Duration? timeout,
  }) async* {
    final healthSession = _captureCloudHealthSession();
    final sw = TurnTrace.stopwatch(
      'cloud.stream_events',
      details: 'messages=${messages.length}',
    );
    var sawFirstToken = false;
    var eventCount = 0;
    var charCount = 0;
    var wireCharacterCount = 0;
    var controlEventCount = 0;
    try {
      final client = await _proxy.ensureClient();
      if (client == null) {
        throw StateError('chat.llm_api_key_missing'.tr);
      }
      ModelPromptLogger.logMessages(
        'cloud/stream-events',
        _messageRecords(messages),
      );
      final presentationClient =
          presentation && client is PresentationStreamingLLMClient
          ? client as PresentationStreamingLLMClient
          : null;
      final events = presentationClient != null
          ? presentationClient.streamPresentationChatEvents(
              messages,
              timeout: timeout,
            )
          : client.streamChatEvents(messages, timeout: timeout);
      var presentationDone = false;
      var reportedSuccess = false;
      await for (final event in events) {
        eventCount++;
        wireCharacterCount += event.data.length;
        final delta = event.deltaText;
        if (presentation && delta.isEmpty) controlEventCount++;
        if (presentation &&
            (eventCount > PresentationStreamLimits.maxEvents ||
                controlEventCount > PresentationStreamLimits.maxControlEvents ||
                wireCharacterCount >
                    PresentationStreamLimits.maxWireCharacters)) {
          throw StateError('Presentation stream exceeded its bounds.');
        }
        if (event.event == 'trace') {
          _logCloudStreamTrace(event);
          continue;
        }
        if (presentation && event.event == 'done') {
          if (event.data.trim() != '[DONE]') {
            throw StateError('Invalid presentation stream done marker.');
          }
          presentationDone = true;
          TurnTrace.done(
            'cloud.stream_events',
            sw,
            details:
                'events=$eventCount chars=$charCount '
                'firstToken=$sawFirstToken',
          );
          _reportCloudSuccess(healthSession);
          reportedSuccess = true;
          yield event;
          break;
        }
        charCount += delta.length;
        if (presentation &&
            charCount > PresentationStreamLimits.maxContentCharacters) {
          throw StateError('Presentation content exceeded its bounds.');
        }
        if (!sawFirstToken && delta.isNotEmpty) {
          sawFirstToken = true;
          TurnTrace.event(
            'cloud.ttft',
            details: 'ms=${sw.elapsedMilliseconds} first_chars=${delta.length}',
          );
        }
        yield event;
      }
      if (presentationClient != null && !presentationDone) {
        throw StateError('Presentation stream ended before protocol done.');
      }
      if (!reportedSuccess) {
        TurnTrace.done(
          'cloud.stream_events',
          sw,
          details:
              'events=$eventCount chars=$charCount firstToken=$sawFirstToken',
        );
        _reportCloudSuccess(healthSession);
      }
      if (presentation && presentationClient == null) {
        yield const LLMStreamEvent(event: 'done', data: '[DONE]');
      }
    } catch (e) {
      TurnTrace.event('cloud.stream_events.error', details: 'error=$e');
      _reportCloudFailure(e, healthSession);
      rethrow;
    }
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    final healthSession = _captureCloudHealthSession();
    final client = await _proxy.ensureClient();
    if (client == null) {
      throw StateError('chat.llm_api_key_missing'.tr);
    }
    ModelPromptLogger.logMessages(
      'cloud/chat-with-tools',
      _messageRecords(messages),
      meta: 'tools=${tools.length}',
    );
    if (tools.isNotEmpty) {
      ModelPromptLogger.logPrompt(
        'cloud/chat-with-tools/tools',
        const JsonEncoder.withIndent('  ').convert(tools),
      );
    }
    final sw = TurnTrace.stopwatch(
      'cloud.chat_with_tools',
      details: 'messages=${messages.length} tools=${tools.length}',
    );
    try {
      final result = await client.chatWithTools(
        messages,
        tools,
        timeout: timeout,
      );
      TurnTrace.done(
        'cloud.chat_with_tools',
        sw,
        details: 'result_chars=${result.toString().length}',
      );
      _reportCloudSuccess(healthSession);
      return result;
    } catch (e) {
      TurnTrace.event('cloud.chat_with_tools.error', details: 'error=$e');
      _reportCloudFailure(e, healthSession);
      rethrow;
    }
  }
}

/// A task keeps one resolved model while every dispatch still consults its
/// live permission wrapper and mounted account/configuration generation.
final class _PinnedStructuredOutputClient extends LLMClient
    implements StructuredOutputLLMClient, ProjectSourceLLMClient {
  _PinnedStructuredOutputClient(
    this.inner,
    this.healthSession,
    this.requireCurrent,
    this.defaultTimeout,
    this.isSnapshotMounted,
  );

  final LLMClient inner;
  final CloudLLMHealthAccountSession? healthSession;
  final Future<void> Function() requireCurrent;
  final bool Function() isSnapshotMounted;

  @override
  final Duration defaultTimeout;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      inner.chat(messages, timeout: timeout);

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      inner.generateJson(prompt, timeout: timeout);

  @override
  Future<ProjectSourceResponse> generateProjectSource(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
    bool Function()? shouldCancel,
  }) async {
    var admitted = false;
    final sw = TurnTrace.stopwatch(
      'cloud.project_source',
      details: 'messages=${messages.length}',
    );
    try {
      await requireCurrent();
      final response = await generateProjectSourceWithPrivacyAdmission(
        inner,
        messages,
        timeout: timeout,
        shouldCancel: () =>
            !isSnapshotMounted() || shouldCancel?.call() == true,
        onAdmitted: () async {
          await requireCurrent();
          await onAdmitted?.call();
          admitted = true;
        },
      );
      await requireCurrent();
      TurnTrace.done(
        'cloud.project_source',
        sw,
        details:
            'chars=${response.visibleText.length} '
            'termination=${response.termination.name}',
      );
      _reportCloudSuccess(healthSession);
      return response;
    } catch (error) {
      TurnTrace.event('cloud.project_source.error', details: 'error=$error');
      if (admitted) _reportCloudFailure(error, healthSession);
      rethrow;
    }
  }

  @override
  Future<String> chatJsonObject(
    List<Message> messages, {
    Duration? timeout,
    FutureOr<void> Function()? onAdmitted,
  }) async {
    var admitted = false;
    final sw = TurnTrace.stopwatch(
      'cloud.chat_json_object',
      details: 'messages=${messages.length}',
    );
    try {
      await requireCurrent();
      final reply = await chatJsonObjectWithPrivacyAdmission(
        inner,
        messages,
        timeout: timeout,
        onAdmitted: () async {
          await requireCurrent();
          await onAdmitted?.call();
          admitted = true;
        },
      );
      await requireCurrent();
      TurnTrace.done(
        'cloud.chat_json_object',
        sw,
        details: 'reply_chars=${reply.length}',
      );
      _reportCloudSuccess(healthSession);
      return reply;
    } catch (error) {
      TurnTrace.event('cloud.chat_json_object.error', details: 'error=$error');
      if (admitted) _reportCloudFailure(error, healthSession);
      rethrow;
    }
  }
}

/// Feed the live cloud round-trip outcome back to [CloudLLMHealthService] so a
/// real failure downgrades routing to the local fallback (and a success
/// restores the cloud path) — guarded so it's a no-op if the service isn't up.
CloudLLMHealthAccountSession? _captureCloudHealthSession() {
  if (!appServices.isRegistered<CloudLLMHealthService>()) return null;
  return appServices.find<CloudLLMHealthService>().activeAccountSession;
}

void _reportCloudSuccess(CloudLLMHealthAccountSession? session) {
  if (session == null || !appServices.isRegistered<CloudLLMHealthService>()) {
    return;
  }
  appServices.find<CloudLLMHealthService>().reportRuntimeSuccess(
    session: session,
  );
}

void _reportCloudFailure(Object error, CloudLLMHealthAccountSession? session) {
  if (session == null || !appServices.isRegistered<CloudLLMHealthService>()) {
    return;
  }
  appServices.find<CloudLLMHealthService>().reportRuntimeFailure(
    error,
    session: session,
  );
}

void _logCloudStreamTrace(LLMStreamEvent event) {
  final payload = event.jsonPayload;
  if (payload == null) {
    TurnTrace.event('cloud.proxy_trace', details: event.data);
    return;
  }
  final name = payload['name']?.toString().trim();
  final details = payload.entries
      .where((entry) => entry.key != 'name')
      .map((entry) => '${entry.key}=${entry.value}')
      .join(' ');
  TurnTrace.event(
    name == null || name.isEmpty ? 'cloud.proxy_trace' : name,
    details: details.isEmpty ? 'source=maaso_proxy' : details,
  );
}

List<({String role, String content})> _messageRecords(List<Message> messages) {
  return [for (final m in messages) (role: m.role, content: m.content)];
}
