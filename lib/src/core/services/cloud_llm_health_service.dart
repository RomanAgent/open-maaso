import 'dart:async';
import 'dart:convert';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'daily_token_usage_service.dart';

/// Lifecycle of the cloud LLM connection, surfaced to routing + Settings.
///
///   unknown → checking → available | unavailable
///
/// Only [available] permits the cloud main path; [unavailable] keeps the app
/// on the on-device fallback.  [disabled] is the user toggling cloud off — no
/// probe runs and no error is shown.
enum CloudLLMStatus { disabled, unknown, checking, available, unavailable }

/// Immutable snapshot of the last health verdict.  [reason] is a machine code
/// (e.g. `unauthorized`, `timeout`) the UI maps to a localized string; null
/// reason on [available] means a clean `ok`.
class CloudLLMHealth {
  final CloudLLMStatus status;
  final String? reason;
  final DateTime? checkedAt;
  final int? latencyMs;
  final int? httpStatus;

  const CloudLLMHealth({
    required this.status,
    this.reason,
    this.checkedAt,
    this.latencyMs,
    this.httpStatus,
  });

  const CloudLLMHealth.unknown() : this(status: CloudLLMStatus.unknown);
}

typedef CloudLLMHealthProbe =
    Future<CloudLLMHealth> Function(
      String apiKey,
      String baseUrl,
      String model,
    );

/// Unforgeable ownership receipt for one mounted account's health runtime.
///
/// The service is device-global, so every asynchronous probe must retain this
/// receipt and revalidate it before publishing or persisting a result.
final class CloudLLMHealthAccountSession {
  const CloudLLMHealthAccountSession._({
    required this.accountScopeKey,
    required this.generation,
  });

  final String accountScopeKey;
  final int generation;
}

/// Immutable BYOK values captured by the owning account controller.
///
/// Health probes never re-read the device-global compatibility projection, so
/// a partially written or newly switched projection cannot change an already
/// admitted account operation.
final class CloudLLMHealthProbeConfig {
  const CloudLLMHealthProbeConfig({
    required this.enabled,
    required this.apiKey,
    required this.baseUrl,
    required this.model,
  });

  final bool enabled;
  final String apiKey;
  final String baseUrl;
  final String model;
}

/// Non-secret, account-scoped cache used to avoid a cold-start health probe.
///
/// Keeping this boundary injectable lets lifecycle tests hold a physical cache
/// write open and prove that account teardown drains it before another account
/// can activate.
abstract interface class CloudLLMHealthCache {
  Future<CloudLLMHealth?> load(String accountScopeKey);

  Future<void> save(String accountScopeKey, CloudLLMHealth health);
}

final class SharedPreferencesCloudLLMHealthCache
    implements CloudLLMHealthCache {
  static const _cacheKeySegment = 'cloud_health.v1';
  static const _kStatus = 'status';
  static const _kReason = 'reason';
  static const _kCheckedAt = 'checked_at';
  static const _kLatency = 'latency';

  @override
  Future<CloudLLMHealth?> load(String accountScopeKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final statusName = prefs.getString(_key(accountScopeKey, _kStatus));
      if (statusName == null) return null;
      CloudLLMStatus? status;
      for (final candidate in CloudLLMStatus.values) {
        if (candidate.name == statusName) {
          status = candidate;
          break;
        }
      }
      if (status == null) return null;
      final reason = prefs.getString(_key(accountScopeKey, _kReason));
      final checkedMs = prefs.getInt(_key(accountScopeKey, _kCheckedAt)) ?? 0;
      final latency = prefs.getInt(_key(accountScopeKey, _kLatency)) ?? -1;
      return CloudLLMHealth(
        status: status,
        reason: (reason == null || reason.isEmpty) ? null : reason,
        checkedAt: checkedMs > 0
            ? DateTime.fromMillisecondsSinceEpoch(checkedMs)
            : null,
        latencyMs: latency >= 0 ? latency : null,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> save(String accountScopeKey, CloudLLMHealth health) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(accountScopeKey, _kStatus),
        health.status.name,
      );
      await prefs.setString(
        _key(accountScopeKey, _kReason),
        health.reason ?? '',
      );
      await prefs.setInt(
        _key(accountScopeKey, _kCheckedAt),
        health.checkedAt?.millisecondsSinceEpoch ?? 0,
      );
      await prefs.setInt(
        _key(accountScopeKey, _kLatency),
        health.latencyMs ?? -1,
      );
    } catch (_) {
      // This cache is only an optimization. A failed write causes a fresh
      // probe on the next activation, while lifecycle still waits for the
      // attempted write to settle.
    }
  }

  static String _key(String accountScopeKey, String suffix) {
    return '$accountScopeKey.$_cacheKeySegment.$suffix';
  }
}

/// Verifies that the saved BYOK cloud config can actually complete a minimal
/// chat round-trip, **without** dragging in the full [AgentRuntime] chain
/// (prompt, memory, TTS, filler, avatar).  It pokes the thinnest possible
/// `/chat/completions` request and classifies the outcome.
///
/// Routing reads [cloudPermittedForRouting]; Settings binds to [health].
class CloudLLMHealthService extends AppService {
  CloudLLMHealthService({
    CloudLLMHealthProbe? probe,
    CloudLLMHealthCache? cache,
  }) : _probeOverride = probe,
       _cache = cache ?? SharedPreferencesCloudLLMHealthCache();

  final CloudLLMHealthProbe? _probeOverride;
  final CloudLLMHealthCache _cache;

  /// Reactive verdict — Settings + routing observe this.
  final Rx<CloudLLMHealth> health = const CloudLLMHealth.unknown().obs;

  // ── tunables ──
  static const Duration _probeTimeout = Duration(seconds: 5);
  // After a transient *runtime* call failure we don't hammer the cloud — but
  // we do let it retry once the cooldown lapses (key/quota may have recovered).
  static const Duration _runtimeCooldown = Duration(seconds: 30);
  static const Duration _rateLimitCooldown = Duration(seconds: 60);
  // On launch a recent successful probe is trusted without re-blocking the UI.
  static const Duration _trustWindow = Duration(minutes: 10);

  /// Reasons that warrant an automatic retry after a cooldown (the cloud may
  /// recover on its own).  Hard config errors (bad key, wrong model) are NOT
  /// here — those need the user to fix Settings.
  static const _transientReasons = {
    'timeout',
    'network',
    'rate_limited',
    'server_error',
    'unexpected_status',
    'cloud_error',
  };

  /// Monotonic guard so a slow probe can never clobber a newer verdict.
  int _checkSeq = 0;

  CloudLLMHealthAccountSession? _activeSession;
  CloudLLMHealthAccountSession? _retiringSession;
  int _accountGeneration = 0;
  Future<void>? _drainFuture;
  final Set<Future<void>> _operations = <Future<void>>{};
  Object? _retainedOperationError;
  StackTrace? _retainedOperationStackTrace;

  /// When non-null, a transient failure is in cooldown — the cloud is blocked
  /// until this instant, then one retry is permitted.
  DateTime? _retryAfter;

  CloudLLMHealth get current => health.value;

  bool get cloudAvailable => health.value.status == CloudLLMStatus.available;

  /// Whether the cloud main path may be used right now.  We only *block* on
  /// positive evidence the cloud is broken: a confirmed `unavailable` that is
  /// still inside its cooldown.  `unknown` / `checking` stay optimistic so a
  /// cold start never forces every first message onto the local brain.
  bool get cloudPermittedForRouting {
    final h = health.value;
    switch (h.status) {
      case CloudLLMStatus.disabled:
        return false;
      case CloudLLMStatus.unavailable:
        final r = _retryAfter;
        return r != null && DateTime.now().isAfter(r);
      case CloudLLMStatus.available:
      case CloudLLMStatus.unknown:
      case CloudLLMStatus.checking:
        return true;
    }
  }

  // ──────────────────────── public API ────────────────────────

  CloudLLMHealthAccountSession activateAccount({
    required String accountScopeKey,
  }) {
    final normalizedScopeKey = accountScopeKey.trim();
    if (normalizedScopeKey.isEmpty) {
      throw ArgumentError.value(
        accountScopeKey,
        'accountScopeKey',
        'must not be empty',
      );
    }
    final current = _activeSession;
    if (current != null && current.accountScopeKey == normalizedScopeKey) {
      return current;
    }
    if (current != null || _retiringSession != null) {
      throw StateError(
        'Cannot activate cloud health until the previous account is drained.',
      );
    }

    final session = CloudLLMHealthAccountSession._(
      accountScopeKey: normalizedScopeKey,
      generation: ++_accountGeneration,
    );
    _activeSession = session;
    _retryAfter = null;
    ++_checkSeq;
    _set(const CloudLLMHealth.unknown());
    return session;
  }

  bool isAccountSessionActive(CloudLLMHealthAccountSession session) {
    return _isActive(session);
  }

  /// Captures the ownership receipt that must accompany any later runtime
  /// outcome. The caller must do this before its first asynchronous boundary.
  CloudLLMHealthAccountSession? get activeAccountSession => _activeSession;

  /// Synchronously prevents new work, then waits for every admitted probe and
  /// cache write. An operation failure retains the retiring receipt so a
  /// lifecycle retry must complete before another account can activate.
  Future<void> deactivateAccountAndDrain({
    required CloudLLMHealthAccountSession session,
  }) {
    final inFlight = _drainFuture;
    if (inFlight != null) return inFlight;

    final retiring = _retiringSession;
    if (retiring != null) {
      if (!identical(retiring, session)) {
        throw StateError('The cloud health retirement receipt is stale.');
      }
    } else {
      if (!_isActive(session)) {
        // A completed drain is idempotent for its original receipt.
        if (_activeSession == null) return Future<void>.value();
        throw StateError('The cloud health account receipt is stale.');
      }
      _retiringSession = session;
      _activeSession = null;
      _accountGeneration++;
      ++_checkSeq;
      _retryAfter = null;
      _set(const CloudLLMHealth(status: CloudLLMStatus.disabled));
    }

    late final Future<void> drain;
    drain = _drainOnce(session).whenComplete(() {
      if (identical(_drainFuture, drain)) _drainFuture = null;
    });
    _drainFuture = drain;
    return drain;
  }

  /// User flipped cloud off — clear any error and rest in [disabled].
  void setDisabled({required CloudLLMHealthAccountSession session}) {
    _requireActive(session);
    ++_checkSeq;
    _retryAfter = null;
    _set(const CloudLLMHealth(status: CloudLLMStatus.disabled));
    Log.i('☁️ [CloudLLM/health] disabled (cloud off)');
  }

  /// Cloud is on but there's no key to probe with.
  void setUnknown({required CloudLLMHealthAccountSession session}) {
    _requireActive(session);
    ++_checkSeq;
    _retryAfter = null;
    _set(const CloudLLMHealth(status: CloudLLMStatus.unknown));
  }

  /// Run a fresh probe now.  Safe to call from Settings save, the "recheck"
  /// button, or startup — the [_checkSeq] guard makes the latest call win.
  ///
  /// [silent] skips the visible `checking` transition — used by the startup
  /// re-verify so a trusted-cache `available` doesn't flicker to a spinner.
  Future<void> checkNow({
    required CloudLLMHealthAccountSession session,
    required CloudLLMHealthProbeConfig config,
    bool silent = false,
  }) {
    _requireActive(session);
    final seq = ++_checkSeq;
    return _track(_checkNow(session, seq, config: config, silent: silent));
  }

  Future<void> _checkNow(
    CloudLLMHealthAccountSession session,
    int seq, {
    required CloudLLMHealthProbeConfig config,
    required bool silent,
  }) async {
    if (!config.enabled) {
      _retryAfter = null;
      _set(const CloudLLMHealth(status: CloudLLMStatus.disabled));
      return;
    }
    final apiKey = config.apiKey.trim();
    if (apiKey.isEmpty) {
      _retryAfter = null;
      _set(const CloudLLMHealth(status: CloudLLMStatus.unknown));
      return;
    }

    if (!silent) {
      _set(
        CloudLLMHealth(
          status: CloudLLMStatus.checking,
          reason: health.value.reason,
          checkedAt: health.value.checkedAt,
        ),
      );
    }
    Log.i(
      '☁️ [CloudLLM/health] checking${silent ? ' (silent)' : ''} '
      'baseUrl=${config.baseUrl} model=${config.model}',
    );

    final probe = _probeOverride ?? _probe;
    final result = await probe(apiKey, config.baseUrl, config.model);
    if (!_isOperationCurrent(session, seq)) return;

    _retryAfter =
        result.status == CloudLLMStatus.unavailable &&
            result.reason != null &&
            _transientReasons.contains(result.reason)
        ? DateTime.now().add(
            result.reason == 'rate_limited'
                ? _rateLimitCooldown
                : _runtimeCooldown,
          )
        : null;
    _set(result);
    _log(result);
    await _persist(session, seq, result);
  }

  /// Startup path: trust a recent good cache to avoid a cold-start stall, then
  /// silently re-verify in the background; otherwise probe straight away.
  Future<void> bootstrap({
    required CloudLLMHealthAccountSession session,
    required CloudLLMHealthProbeConfig config,
  }) {
    _requireActive(session);
    final seq = ++_checkSeq;
    return _track(_bootstrap(session, seq, config));
  }

  Future<void> _bootstrap(
    CloudLLMHealthAccountSession session,
    int seq,
    CloudLLMHealthProbeConfig config,
  ) async {
    if (!config.enabled) {
      _retryAfter = null;
      _set(const CloudLLMHealth(status: CloudLLMStatus.disabled));
      return;
    }
    if (config.apiKey.trim().isEmpty) {
      _retryAfter = null;
      _set(const CloudLLMHealth(status: CloudLLMStatus.unknown));
      return;
    }

    final cached = await _loadCache(session, seq);
    if (!_isOperationCurrent(session, seq)) return;
    if (cached != null &&
        cached.status == CloudLLMStatus.available &&
        cached.checkedAt != null &&
        DateTime.now().difference(cached.checkedAt!) < _trustWindow) {
      _set(cached);
      Log.i(
        '☁️ [CloudLLM/health] trusting cached available '
        '(age=${DateTime.now().difference(cached.checkedAt!).inSeconds}s) — silent recheck',
      );
      await _checkNow(session, seq, config: config, silent: true);
      return;
    }
    await _checkNow(session, seq, config: config, silent: false);
  }

  /// A real cloud call (from the agent runtime) just failed — downgrade with a
  /// short cooldown so the next turns fall back locally instead of repeatedly
  /// timing out.  Cooldown lapses let the cloud prove itself again.
  void reportRuntimeFailure(
    Object error, {
    required CloudLLMHealthAccountSession session,
  }) {
    if (!_isActive(session)) return;
    final h = health.value;
    if (h.status == CloudLLMStatus.disabled) return;
    final reason = _classifyError(error);
    // Only downgrade on a failure we can pin on a real connectivity / auth /
    // model problem.  Ambiguous errors (a cancelled turn, a parse hiccup) land
    // as `cloud_error` and must NOT knock the cloud offline.
    if (reason == 'cloud_error') return;
    final seq = ++_checkSeq;
    _retryAfter = DateTime.now().add(
      reason == 'rate_limited' ? _rateLimitCooldown : _runtimeCooldown,
    );
    _set(
      CloudLLMHealth(
        status: CloudLLMStatus.unavailable,
        reason: reason,
        checkedAt: DateTime.now(),
      ),
    );
    Log.w(
      '☁️ [CloudLLM/health] runtime failure → unavailable reason=$reason '
      'cooldown=${(_retryAfter!.difference(DateTime.now())).inSeconds}s',
    );
    _observeBackground(_track(_persist(session, seq, health.value)));
  }

  /// A real cloud call just succeeded — clear any downgrade so routing returns
  /// to the cloud main path immediately.
  void reportRuntimeSuccess({required CloudLLMHealthAccountSession session}) {
    if (!_isActive(session)) return;
    final h = health.value;
    if (h.status == CloudLLMStatus.available ||
        h.status == CloudLLMStatus.disabled) {
      return;
    }
    final seq = ++_checkSeq;
    _retryAfter = null;
    _set(
      CloudLLMHealth(
        status: CloudLLMStatus.available,
        checkedAt: DateTime.now(),
      ),
    );
    Log.i('☁️ [CloudLLM/health] runtime success → available');
    _observeBackground(_track(_persist(session, seq, health.value)));
  }

  // ──────────────────────── probe + classify ────────────────────────

  Future<CloudLLMHealth> _probe(
    String apiKey,
    String baseUrl,
    String model,
  ) async {
    final url = Uri.parse('$baseUrl/chat/completions');
    final payload = <String, dynamic>{
      'model': model,
      'messages': [
        {
          'role': 'system',
          'content': AgentPromptCatalog.text('app.health.system'),
        },
        {'role': 'user', 'content': AgentPromptCatalog.text('app.health.user')},
      ],
      'max_tokens': 3,
      'temperature': 0,
    };
    final sw = Stopwatch()..start();
    final transport =
        appServices.maybeFind<DailyTokenUsageService>()?.createClient() ??
        http.Client();
    try {
      final resp = await transport
          .post(
            url,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $apiKey',
            },
            body: jsonEncode(payload),
          )
          .timeout(_probeTimeout);
      sw.stop();
      final latency = sw.elapsedMilliseconds;
      final code = resp.statusCode;
      final body = utf8.decode(resp.bodyBytes);

      if (code >= 200 && code < 300) {
        final content = _extractContent(body).toLowerCase();
        if (content.contains('ok')) {
          return CloudLLMHealth(
            status: CloudLLMStatus.available,
            checkedAt: DateTime.now(),
            latencyMs: latency,
            httpStatus: code,
          );
        }
        // Connected, but the model didn't echo `ok` — protocol/behavior is off,
        // yet a real chat would still produce content, so keep it usable.
        return CloudLLMHealth(
          status: CloudLLMStatus.available,
          reason: 'degraded',
          checkedAt: DateTime.now(),
          latencyMs: latency,
          httpStatus: code,
        );
      }

      final reason = switch (code) {
        401 || 403 => 'unauthorized',
        429 => 'rate_limited',
        404 => _mentionsModel(body) ? 'model_not_found' : 'not_found',
        400 => _mentionsModel(body) ? 'model_not_found' : 'bad_request',
        >= 500 => 'server_error',
        _ => 'unexpected_status',
      };
      return CloudLLMHealth(
        status: CloudLLMStatus.unavailable,
        reason: reason,
        checkedAt: DateTime.now(),
        latencyMs: latency,
        httpStatus: code,
      );
    } on TimeoutException {
      sw.stop();
      return CloudLLMHealth(
        status: CloudLLMStatus.unavailable,
        reason: 'timeout',
        checkedAt: DateTime.now(),
        latencyMs: sw.elapsedMilliseconds,
      );
    } catch (_) {
      sw.stop();
      return CloudLLMHealth(
        status: CloudLLMStatus.unavailable,
        reason: 'network',
        checkedAt: DateTime.now(),
        latencyMs: sw.elapsedMilliseconds,
      );
    } finally {
      transport.close();
    }
  }

  String _extractContent(String body) {
    try {
      final data = jsonDecode(body);
      if (data is Map) {
        final choices = data['choices'];
        if (choices is List && choices.isNotEmpty) {
          final msg = choices.first;
          if (msg is Map) {
            final c = msg['message'] is Map ? msg['message']['content'] : null;
            if (c != null) return c.toString();
          }
        }
      }
    } catch (_) {}
    return '';
  }

  bool _mentionsModel(String body) => body.toLowerCase().contains('model');

  /// Best-effort mapping of a thrown runtime error → a reason code.  Errors
  /// here are stringified exceptions (e.g. "OpenAI API error [401]: …").
  String _classifyError(Object e) {
    final s = e.toString().toLowerCase();
    if (s.contains('401') || s.contains('403') || s.contains('unauth')) {
      return 'unauthorized';
    }
    if (s.contains('429')) return 'rate_limited';
    if (s.contains('404') || (s.contains('400') && s.contains('model'))) {
      return 'model_not_found';
    }
    if (s.contains('timeout') || s.contains('timed out')) return 'timeout';
    if (s.contains('socket') ||
        s.contains('connection') ||
        s.contains('network') ||
        s.contains('failed host') ||
        s.contains('handshake')) {
      return 'network';
    }
    if (s.contains('500') || s.contains('502') || s.contains('503')) {
      return 'server_error';
    }
    return 'cloud_error';
  }

  // ──────────────────────── state + cache ────────────────────────

  void _set(CloudLLMHealth h) => health.value = h;

  void _log(CloudLLMHealth h) {
    if (h.status == CloudLLMStatus.available) {
      final tag = h.reason == null ? '' : ' reason=${h.reason}';
      Log.i('☁️ [CloudLLM/health] available latency=${h.latencyMs}ms$tag');
    } else if (h.status == CloudLLMStatus.unavailable) {
      final st = h.httpStatus == null ? '' : ' status=${h.httpStatus}';
      Log.w('☁️ [CloudLLM/health] unavailable reason=${h.reason}$st');
    }
  }

  Future<void> _persist(
    CloudLLMHealthAccountSession session,
    int seq,
    CloudLLMHealth h,
  ) async {
    if (!_isOperationCurrent(session, seq)) return;
    await _cache.save(session.accountScopeKey, h);
    if (!_isOperationCurrent(session, seq)) return;
  }

  Future<CloudLLMHealth?> _loadCache(
    CloudLLMHealthAccountSession session,
    int seq,
  ) async {
    if (!_isOperationCurrent(session, seq)) return null;
    final cached = await _cache.load(session.accountScopeKey);
    if (!_isOperationCurrent(session, seq)) return null;
    return cached;
  }

  Future<void> _track(Future<void> operation) {
    _operations.add(operation);
    operation.then<void>(
      (_) => _operations.remove(operation),
      onError: (Object error, StackTrace stackTrace) {
        _operations.remove(operation);
        _retainedOperationError ??= error;
        _retainedOperationStackTrace ??= stackTrace;
      },
    );
    return operation;
  }

  void _observeBackground(Future<void> operation) {
    unawaited(
      operation.catchError((Object error, StackTrace stackTrace) {
        Log.w('☁️ [CloudLLM/health] background operation failed: $error');
      }),
    );
  }

  Future<void> _drainOnce(CloudLLMHealthAccountSession session) async {
    while (_operations.isNotEmpty) {
      final snapshot = _operations.toList(growable: false);
      await Future.wait<void>(
        snapshot.map(
          (operation) => operation.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
        ),
        eagerError: false,
      );
    }

    final error = _retainedOperationError;
    final stackTrace = _retainedOperationStackTrace;
    if (error != null) {
      _retainedOperationError = null;
      _retainedOperationStackTrace = null;
      if (stackTrace != null) Error.throwWithStackTrace(error, stackTrace);
      throw error;
    }
    if (identical(_retiringSession, session)) {
      _retiringSession = null;
    }
  }

  bool _isActive(CloudLLMHealthAccountSession session) {
    return identical(_activeSession, session) &&
        session.generation == _accountGeneration;
  }

  bool _isOperationCurrent(CloudLLMHealthAccountSession session, int seq) {
    return _isActive(session) && seq == _checkSeq;
  }

  void _requireActive(CloudLLMHealthAccountSession session) {
    if (!_isActive(session)) {
      throw StateError('The cloud health account receipt is stale.');
    }
  }
}
