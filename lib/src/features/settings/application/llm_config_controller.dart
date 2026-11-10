import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/direct_vendor_llm_client.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';

/// Unforgeable receipt captured while one account owns the BYOK controller.
///
/// Long-lived UI surfaces retain this receipt and present it again on save.
/// A callback from an old route therefore cannot silently target whichever
/// account happens to be active when the callback eventually runs.
final class LLMConfigAccountSession {
  const LLMConfigAccountSession._({
    required this.mount,
    required this.controllerGeneration,
  });

  final AccountStorageScopeMount mount;
  final int controllerGeneration;
}

class LLMConfigController extends AppController {
  LLMConfigController({
    SecureStorageService? storage,
    AccountStorageScopeService? storageScopes,
    this.localEdition = false,
  }) : _storage = storage ?? appServices.find<SecureStorageService>(),
       _injectedStorageScopes = storageScopes;

  static const String _scopedKeySegment = 'llm.byok.v1';
  static const List<String> _configKeys = <String>[
    LLMDirectCloudConfig.storageKey,
    GlobalConstant.keyLlmApiKey,
    GlobalConstant.keyLlmBaseUrl,
    GlobalConstant.keyLlmModel,
    GlobalConstant.keyLlmCloudEnabled,
  ];

  /// Local edition saves credentials without background provider probes.
  final bool localEdition;
  final SecureStorageService _storage;
  final AccountStorageScopeService? _injectedStorageScopes;

  AccountStorageScopeService get _storageScopes =>
      _injectedStorageScopes ?? appServices.find<AccountStorageScopeService>();

  final apiKey = ''.obs;
  final baseUrl = LLMDefaults.baseUrl.obs;
  final model = LLMDefaults.model.obs;
  final cloudEnabled = false.obs;

  bool get cloudUsable =>
      cloudEnabled.value &&
      (apiKey.value.trim().isNotEmpty ||
          (localEdition && _isLocalEndpoint(baseUrl.value)));

  bool get usesLocalEndpoint =>
      localEdition && cloudEnabled.value && _isLocalEndpoint(baseUrl.value);

  static bool _isLocalEndpoint(String url) {
    final uri = Uri.tryParse(url);
    return uri != null &&
        const {'localhost', '127.0.0.1', '::1'}.contains(uri.host);
  }

  LLMConfigAccountSession? _activeSession;
  LLMConfigAccountSession? _retiringSession;
  CloudLLMHealthService? _activeHealthService;
  CloudLLMHealthAccountSession? _activeHealthSession;
  CloudLLMHealthService? _retiringHealthService;
  CloudLLMHealthAccountSession? _retiringHealthSession;
  int _controllerGeneration = 0;
  Future<void>? _loadFuture;
  Future<void>? _drainFuture;
  Future<void> _saveTail = Future<void>.value();
  final Set<Future<void>> _operations = <Future<void>>{};

  /// Removes the unowned pre-account keys without assigning them to the next
  /// signer. This runs on the signed-out bootstrap path before any direct
  /// cloud producer is initialized.
  Future<void> quarantineLegacyConfig() async {
    if (_activeSession != null || _retiringSession != null) {
      throw StateError(
        'Cannot quarantine BYOK config while an account owns it.',
      );
    }
    _resetReactiveConfig();
    await _deleteCompatibilityProjectionStrict();
  }

  /// Activates one account namespace and publishes its values to the legacy
  /// logical keys used by existing direct-cloud consumers.
  ///
  /// The compatibility projection exists only while this account is mounted;
  /// [deactivateAccountAndDrain] removes it before another account can mount.
  Future<void> activateAccount(AccountStorageScopeMount mount) {
    _storageScopes.requireCurrent(mount);
    final current = _activeSession;
    if (current != null &&
        current.mount.generation == mount.generation &&
        current.mount.scope == mount.scope) {
      return ensureConfigLoaded();
    }
    if (current != null || _retiringSession != null) {
      throw StateError(
        'Cannot activate BYOK config until the previous account is drained.',
      );
    }

    final session = LLMConfigAccountSession._(
      mount: mount,
      controllerGeneration: ++_controllerGeneration,
    );
    _activeSession = session;
    _resetReactiveConfig();
    return _loadFuture = _track(_activate(session));
  }

  /// Returns the receipt that a route must retain for every later save.
  LLMConfigAccountSession requireActiveAccountSession() {
    final session = _activeSession;
    if (session == null || !_isActive(session)) {
      throw StateError('No active account owns the BYOK configuration.');
    }
    return session;
  }

  bool isAccountSessionActive(LLMConfigAccountSession session) {
    return _isActive(session);
  }

  /// Awaits loading for the currently activated account.
  Future<void> ensureConfigLoaded() {
    final load = _loadFuture;
    if (load == null) {
      return Future<void>.error(
        StateError('BYOK configuration has no active account.'),
      );
    }
    return load;
  }

  Future<void> _activate(LLMConfigAccountSession session) async {
    // Unknown legacy data is never imported into the newly signed-in account.
    await _deleteCompatibilityProjectionStrict();

    final key = await _storage.read(
      _scopedKey(session, GlobalConstant.keyLlmApiKey),
    );
    final enabled = await _storage.readBool(
      _scopedKey(session, GlobalConstant.keyLlmCloudEnabled),
    );
    final url = await _storage.read(
      _scopedKey(session, GlobalConstant.keyLlmBaseUrl),
    );
    final configuredModel = await _storage.read(
      _scopedKey(session, GlobalConstant.keyLlmModel),
    );

    _requireActive(session);
    final snapshot = _normalizeLocalSnapshot(
      _LLMConfigSnapshot(
        apiKey: key ?? '',
        baseUrl: url ?? LLMDefaults.baseUrl,
        model: configuredModel ?? LLMDefaults.model,
        cloudEnabled: enabled ?? false,
      ),
      allowKeylessLoopback: url != null && configuredModel != null,
    );
    _applySnapshot(snapshot);
    if (localEdition) {
      // Migrate saved Cloud-off configurations into API-key readiness, and
      // durably retain that derived state for every existing compatibility reader.
      await _persistSnapshot(session, snapshot);
    } else {
      await _writeCompatibilityProjectionStrict(snapshot);
    }
    _requireActive(session);
    _refreshCloudHealth(session, snapshot);
  }

  /// Attaches a lazily registered health runtime to the mounted account.
  ///
  /// AgentPipelineRuntimeService and Settings may create the permanent health
  /// service after BYOK activation. This method binds it before its first
  /// bootstrap and tracks that bootstrap inside the account drain barrier.
  void activateCloudHealthForCurrentAccount({
    required LLMConfigAccountSession session,
  }) {
    _requireActive(session);
    if (localEdition) return;
    final health = appServices.maybeFind<CloudLLMHealthService>();
    if (health == null) return;
    final wasActive = _hasActiveHealthBinding(health);
    final healthSession = _ensureHealthBinding(session, health);
    if (wasActive) return;
    _trackBackground(
      health.bootstrap(
        session: healthSession,
        config: _healthConfig(_currentSnapshot()),
      ),
    );
  }

  /// Runs the Settings recheck through the exact account receipt retained by
  /// the route, so teardown waits for it and stale pages cannot target B.
  Future<void> recheckCloudHealth({required LLMConfigAccountSession session}) {
    _requireActive(session);
    if (localEdition) return Future<void>.value();
    final health = appServices.maybeFind<CloudLLMHealthService>();
    if (health == null) return Future<void>.value();
    final healthSession = _ensureHealthBinding(session, health);
    return _track(
      health.checkNow(
        session: healthSession,
        config: _healthConfig(_currentSnapshot()),
      ),
    );
  }

  Future<void> saveConfig(
    String key,
    String url,
    String configuredModel, {
    required LLMConfigAccountSession session,
    bool? enabled,
  }) {
    _requireActive(session);
    final snapshot = _normalizeLocalSnapshot(
      _LLMConfigSnapshot(
        apiKey: key,
        baseUrl: url,
        model: configuredModel,
        cloudEnabled: enabled ?? cloudEnabled.value,
      ),
    );
    _applySnapshot(snapshot);

    final operation = _saveTail.then<void>(
      (_) => _persistSnapshot(session, snapshot),
    );
    _saveTail = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return _track(operation);
  }

  Future<void> _persistSnapshot(
    LLMConfigAccountSession session,
    _LLMConfigSnapshot snapshot,
  ) async {
    if (localEdition && _isActive(session)) {
      // Stop direct readers before any partial local save (including key
      // removal) can publish a new configuration. Retirement drains this work.
      if (!await _storage.delete(LLMDirectCloudConfig.storageKey)) {
        throw StateError('Failed to invalidate the model configuration.');
      }
    }
    await _writeRequired(
      _scopedKey(session, GlobalConstant.keyLlmApiKey),
      snapshot.apiKey,
    );
    await _writeRequired(
      _scopedKey(session, GlobalConstant.keyLlmBaseUrl),
      snapshot.baseUrl,
    );
    await _writeRequired(
      _scopedKey(session, GlobalConstant.keyLlmModel),
      snapshot.model,
    );
    await _writeBoolRequired(
      _scopedKey(session, GlobalConstant.keyLlmCloudEnabled),
      snapshot.cloudEnabled,
    );

    // An admitted A save may finish after A starts retiring. Its scoped write
    // is safe and is drained, but it must never recreate the global projection.
    if (!_isActive(session)) return;
    await _writeCompatibilityProjectionStrict(snapshot);
    if (!_isActive(session)) return;

    if (!localEdition &&
        snapshot.cloudEnabled &&
        snapshot.apiKey.trim().isNotEmpty &&
        appServices.isRegistered<LocalLLMService>()) {
      Log.i('🧠 [LocalLLM] cloud key saved — warming local filler prompt');
      // Keep settings save snappy; this only seeds the transient filler path.
      unawaited(appServices.find<LocalLLMService>().warmupFiller());
    }

    _refreshCloudHealth(session, snapshot);
  }

  /// Synchronously fences new saves, awaits all already admitted operations,
  /// then strictly removes the active compatibility projection.
  ///
  /// A failed delete retains [_retiringSession], so lifecycle retry attempts
  /// only the remaining idempotent cleanup and B cannot activate meanwhile.
  Future<void> deactivateAccountAndDrain() {
    final inFlight = _drainFuture;
    if (inFlight != null) return inFlight;

    var session = _retiringSession;
    if (session == null) {
      session = _activeSession;
      if (session == null) return Future<void>.value();
      _retiringSession = session;
      _activeSession = null;
      _retiringHealthService = _activeHealthService;
      _retiringHealthSession = _activeHealthSession;
      _activeHealthService = null;
      _activeHealthSession = null;
      _loadFuture = null;
      _controllerGeneration++;
      _resetReactiveConfig();
    }

    final healthDrain = _beginHealthDrain();

    late final Future<void> drain;
    drain = _drainOnce(session, healthDrain).whenComplete(() {
      if (identical(_drainFuture, drain)) _drainFuture = null;
    });
    _drainFuture = drain;
    return drain;
  }

  Future<void> _drainOnce(
    LLMConfigAccountSession session,
    Future<void>? healthDrain,
  ) async {
    await Future.wait<void>(<Future<void>>[
      _awaitOperations(),
      ?healthDrain,
    ], eagerError: false);
    _retiringHealthService = null;
    _retiringHealthSession = null;
    await _deleteCompatibilityProjectionStrict();
    if (identical(_retiringSession, session)) {
      _retiringSession = null;
    }
  }

  Future<void> _awaitOperations() async {
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
  }

  Future<void> _track(Future<void> operation) {
    _operations.add(operation);
    operation.then<void>(
      (_) => _operations.remove(operation),
      onError: (Object _, StackTrace _) {
        _operations.remove(operation);
      },
    );
    return operation;
  }

  void _trackBackground(Future<void> operation) {
    final guarded = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {
        Log.w('☁️ [CloudLLM/health] BYOK follow-up failed: $error');
      },
    );
    _track(guarded);
  }

  void _refreshCloudHealth(
    LLMConfigAccountSession session,
    _LLMConfigSnapshot snapshot,
  ) {
    if (localEdition) return;
    final health = appServices.maybeFind<CloudLLMHealthService>();
    if (health == null) return;
    final wasActive = _hasActiveHealthBinding(health);
    final healthSession = _ensureHealthBinding(session, health);
    final config = _healthConfig(snapshot);
    if (!wasActive) {
      _trackBackground(
        health.bootstrap(session: healthSession, config: config),
      );
      return;
    }
    if (!snapshot.cloudEnabled) {
      health.setDisabled(session: healthSession);
    } else if (snapshot.apiKey.trim().isEmpty) {
      health.setUnknown(session: healthSession);
    } else {
      health.setUnknown(session: healthSession);
      _trackBackground(health.checkNow(session: healthSession, config: config));
    }
  }

  bool _hasActiveHealthBinding(CloudLLMHealthService health) {
    final session = _activeHealthSession;
    return identical(_activeHealthService, health) &&
        session != null &&
        health.isAccountSessionActive(session);
  }

  CloudLLMHealthAccountSession _ensureHealthBinding(
    LLMConfigAccountSession session,
    CloudLLMHealthService health,
  ) {
    _requireActive(session);
    final current = _activeHealthSession;
    if (_hasActiveHealthBinding(health) && current != null) return current;
    if (_activeHealthService != null || current != null) {
      throw StateError('The active cloud health binding is inconsistent.');
    }
    final attached = health.activateAccount(
      accountScopeKey: session.mount.scope.storageNamespace,
    );
    _activeHealthService = health;
    _activeHealthSession = attached;
    return attached;
  }

  Future<void>? _beginHealthDrain() {
    final health = _retiringHealthService;
    final session = _retiringHealthSession;
    if (health == null && session == null) return null;
    if (health == null || session == null) {
      return Future<void>.error(
        StateError('The retiring cloud health binding is incomplete.'),
      );
    }
    return health.deactivateAccountAndDrain(session: session);
  }

  _LLMConfigSnapshot _currentSnapshot() {
    return _LLMConfigSnapshot(
      apiKey: apiKey.value,
      baseUrl: baseUrl.value,
      model: model.value,
      cloudEnabled: cloudEnabled.value,
    );
  }

  _LLMConfigSnapshot _normalizeLocalSnapshot(
    _LLMConfigSnapshot snapshot, {
    bool allowKeylessLoopback = true,
  }) {
    if (!localEdition) return snapshot;
    final config = apiOnlyModelConfiguration(
      LLMDirectCloudConfig(
        apiKey: snapshot.apiKey,
        baseUrl: snapshot.baseUrl,
        model: snapshot.model,
        enabled: snapshot.cloudEnabled,
      ),
      allowKeylessLoopback: allowKeylessLoopback,
    );
    return _LLMConfigSnapshot(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
      model: config.model,
      cloudEnabled: config.enabled,
    );
  }

  CloudLLMHealthProbeConfig _healthConfig(_LLMConfigSnapshot snapshot) {
    return CloudLLMHealthProbeConfig(
      enabled: snapshot.cloudEnabled,
      apiKey: snapshot.apiKey,
      baseUrl: snapshot.baseUrl,
      model: snapshot.model,
    );
  }

  bool _isActive(LLMConfigAccountSession session) {
    return identical(_activeSession, session) &&
        session.controllerGeneration == _controllerGeneration &&
        _storageScopes.isCurrent(session.mount);
  }

  void _requireActive(LLMConfigAccountSession session) {
    if (!_isActive(session)) {
      throw StateError('The BYOK account session is stale.');
    }
  }

  String _scopedKey(LLMConfigAccountSession session, String logicalKey) {
    return '${session.mount.scope.storageNamespace}.'
        '$_scopedKeySegment.$logicalKey';
  }

  Future<void> _writeCompatibilityProjectionStrict(
    _LLMConfigSnapshot snapshot,
  ) async {
    // Remove the previously committed envelope before touching compatibility
    // keys. Direct-cloud readers therefore see either one complete snapshot or
    // no usable config while a save is in progress or has failed.
    if (!await _storage.delete(LLMDirectCloudConfig.storageKey)) {
      throw StateError(
        'Failed to invalidate the direct-cloud configuration envelope.',
      );
    }
    await _writeRequired(GlobalConstant.keyLlmApiKey, snapshot.apiKey);
    await _writeRequired(GlobalConstant.keyLlmBaseUrl, snapshot.baseUrl);
    await _writeRequired(GlobalConstant.keyLlmModel, snapshot.model);
    await _writeBoolRequired(
      GlobalConstant.keyLlmCloudEnabled,
      snapshot.cloudEnabled,
    );
    await _writeRequired(
      LLMDirectCloudConfig.storageKey,
      LLMDirectCloudConfig(
        apiKey: snapshot.apiKey,
        baseUrl: snapshot.baseUrl,
        model: snapshot.model,
        enabled: snapshot.cloudEnabled,
      ).encode(),
    );
  }

  Future<void> _deleteCompatibilityProjectionStrict() async {
    final failed = <String>[];
    for (final key in _configKeys) {
      if (!await _storage.delete(key)) failed.add(key);
    }
    if (failed.isNotEmpty) {
      throw StateError(
        'Failed to clear the unscoped BYOK compatibility projection: '
        '${failed.join(', ')}',
      );
    }
  }

  Future<void> _writeRequired(String key, String value) async {
    if (!await _storage.write(key, value)) {
      throw StateError('Failed to persist BYOK configuration key $key.');
    }
  }

  Future<void> _writeBoolRequired(String key, bool value) async {
    if (!await _storage.writeBool(key, value)) {
      throw StateError('Failed to persist BYOK configuration key $key.');
    }
  }

  void _applySnapshot(_LLMConfigSnapshot snapshot) {
    apiKey.value = snapshot.apiKey;
    baseUrl.value = snapshot.baseUrl;
    model.value = snapshot.model;
    cloudEnabled.value = snapshot.cloudEnabled;
  }

  void _resetReactiveConfig() {
    _applySnapshot(const _LLMConfigSnapshot.defaults());
  }
}

final class _LLMConfigSnapshot {
  const _LLMConfigSnapshot({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    required this.cloudEnabled,
  });

  const _LLMConfigSnapshot.defaults()
    : apiKey = '',
      baseUrl = LLMDefaults.baseUrl,
      model = LLMDefaults.model,
      cloudEnabled = false;

  final String apiKey;
  final String baseUrl;
  final String model;
  final bool cloudEnabled;
}
