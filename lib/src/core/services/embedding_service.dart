import 'dart:collection';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';

import 'package:maaso/src/features/settings/application/llm_config_controller.dart';

/// Per-text embedding lookup, with a pluggable backend so we can swap from
/// cloud → on-device (ONNX bge-small) without touching callers.
///
/// P1 ships only [CloudEmbeddingBackend].  When ONNX lands, register an
/// `OnnxEmbeddingBackend` and flip [_backend] at startup.
class EmbeddingService extends AppService {
  EmbeddingService({EmbeddingBackend? backend, Object? Function()? contextKey})
    : _backend = backend,
      _contextKeyOverride = contextKey;

  EmbeddingBackend? _backend;
  final Object? Function()? _contextKeyOverride;
  Object? _cacheContext;
  Object _cacheGeneration = Object();

  /// Tiny FIFO cache — query strings repeat constantly (user's own input
  /// is usually re-embedded across the same loop), so even 64 slots saves
  /// most of the round-trips.
  final LinkedHashMap<String, List<double>> _cache =
      LinkedHashMap<String, List<double>>();
  static const _cacheCap = 64;

  /// Opaque process-local fence for consumers with their own query caches.
  Object get cacheGeneration {
    final context = _currentContext;
    if (_cacheContext != context) {
      _cache.clear();
      _cacheContext = context;
      _cacheGeneration = Object();
    }
    return _cacheGeneration;
  }

  /// Stable identity for persisted vectors. Custom service implementations
  /// override this when changing their model or vector coordinate space.
  String get embeddingSpaceId =>
      _backend?.spaceId ??
      sha256.convert(utf8.encode(runtimeType.toString())).toString();

  Object? get _currentContext {
    final override = _contextKeyOverride;
    if (override != null) {
      final owner = override();
      return owner == null ? null : (owner, _backend?.cacheContext);
    }
    final mount = appServices
        .maybeFind<AccountStorageScopeService>()
        ?.activeMount;
    // The service is process-wide, but every cached vector belongs to one
    // account mount and one provider configuration. No signed-out requests.
    return mount == null ? null : (mount, _backend?.cacheContext);
  }

  Future<EmbeddingService> init() async {
    _backend ??= CloudEmbeddingBackend();
    return this;
  }

  /// Returns the embedding vector, or **null** when no backend is available
  /// or the call failed.  Callers must treat null as "fall back to whatever
  /// you'd do without semantic search" — never as an error.
  Future<List<double>?> embed(String text) async {
    final t = text.trim();
    final backend = _backend;
    final context = _currentContext;
    if (t.isEmpty ||
        backend == null ||
        context == null ||
        !backend.isAvailable ||
        isClosed) {
      return null;
    }
    final generation = cacheGeneration;
    // Full input identity avoids collisions between different facts that
    // share a long prefix; keys never retain or log the source text.
    final key = sha256.convert(utf8.encode(t)).toString();
    final hit = _cache.remove(key);
    if (hit != null) {
      _cache[key] = hit; // bump to MRU
      return hit;
    }
    final v = await backend.embed(t);
    if (v == null ||
        context != _currentContext ||
        !identical(generation, cacheGeneration) ||
        !identical(backend, _backend) ||
        isClosed) {
      return null;
    }
    final immutable = List<double>.unmodifiable(v);
    _cache[key] = immutable;
    if (_cache.length > _cacheCap) _cache.remove(_cache.keys.first);
    return immutable;
  }

  /// True when calling [embed] is at least *expected* to work — we know a
  /// backend is wired and the user has API config set.  Cheap; safe to call
  /// per turn from EpisodeStore to decide between cosine and keyword paths.
  bool get isAvailable =>
      !isClosed && _currentContext != null && (_backend?.isAvailable ?? false);
}

abstract class EmbeddingBackend {
  Future<List<double>?> embed(String text);
  bool get isAvailable;
  Object get cacheContext => spaceId;
  String get spaceId =>
      sha256.convert(utf8.encode(runtimeType.toString())).toString();
}

/// Calls `{baseUrl}/embeddings` with the user's chat API key.
///
/// OpenAI / Volcano / Ollama all speak the same shape; DeepSeek and Gemini
/// don't have OpenAI-compatible embeddings and will silently 404 — the
/// caller falls back to keyword scoring, no crash.
class CloudEmbeddingBackend implements EmbeddingBackend {
  CloudEmbeddingBackend({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 15),
            ),
          );

  final Dio _dio;

  LLMConfigController get _cfg => appServices.find<LLMConfigController>();

  String get _baseUrl => _cfg.baseUrl.value.trim();
  String get _apiKey => _cfg.apiKey.value.trim();

  /// Set once the provider proves it has no usable embeddings endpoint
  /// (404 / 400 / 405). That's a permanent condition for the configured
  /// provider, so we stop trying — no more per-recall round-trips, no more
  /// log spam, and [isAvailable] starts reporting false so callers skip
  /// straight to keyword scoring instead of awaiting a doomed network call.
  /// Keyed to the (baseUrl|apiKey) that failed so a Settings change re-arms it.
  String? _disabledFor;

  /// Heuristic model pick — saves the user from configuring yet another
  /// field.  When more providers need overrides, lift this into Settings.
  String get _model {
    final url = _baseUrl.toLowerCase();
    if (url.contains('volces.com')) return 'doubao-embedding-text-240715';
    if (url.contains('localhost') ||
        url.contains('127.0.0.1') ||
        url.contains('ollama')) {
      return 'bge-m3';
    }
    return 'text-embedding-3-small';
  }

  /// Identity of the current provider config — when the user edits baseUrl
  /// or key in Settings this changes, which re-arms a previously disabled
  /// backend (the new provider might support embeddings).
  String get _configFingerprint => '$_baseUrl|$_apiKey';

  @override
  Object get cacheContext =>
      (_configFingerprint, _model, _cfg.cloudEnabled.value);

  @override
  String get spaceId => sha256
      .convert(
        utf8.encode(
          jsonEncode(['cloud-embedding-space.v1', _baseUrl, _model, _apiKey]),
        ),
      )
      .toString();

  @override
  bool get isAvailable =>
      _cfg.cloudEnabled.value &&
      _baseUrl.isNotEmpty &&
      _apiKey.isNotEmpty &&
      _disabledFor != _configFingerprint;

  @override
  Future<List<double>?> embed(String text) async {
    if (!isAvailable) return null;
    final requestFingerprint = _configFingerprint;
    try {
      final resp = await _dio.post(
        '$_baseUrl/embeddings',
        options: Options(
          headers: {
            'Authorization': 'Bearer $_apiKey',
            'Content-Type': 'application/json',
          },
        ),
        data: {'model': _model, 'input': text},
      );
      final data = resp.data;
      if (data is! Map) return null;
      final list = data['data'];
      if (list is! List || list.isEmpty) return null;
      final emb = list.first['embedding'];
      if (emb is! List) return null;
      return emb.map((e) => (e as num).toDouble()).toList(growable: false);
    } on DioException catch (e) {
      final code = e.response?.statusCode;
      // 404 / 400 / 405 → this provider has no usable embeddings endpoint.
      // Permanent for this config: disable the backend so we don't re-issue
      // a doomed round-trip (and re-log) on every memory recall.  A Settings
      // change to baseUrl/apiKey re-arms it via the fingerprint check.
      if (code == 404 || code == 400 || code == 405) {
        _disabledFor = requestFingerprint;
        Log.w(
          'embedding unsupported by provider ($code) — disabling semantic '
          'search for this config, falling back to keyword scoring',
        );
      } else {
        // Transient (timeout, 5xx, network): log but keep trying next time.
        Log.w('embedding call failed ($code): ${e.message}');
      }
      return null;
    } catch (e) {
      Log.w('embedding call failed: $e');
      return null;
    }
  }
}
