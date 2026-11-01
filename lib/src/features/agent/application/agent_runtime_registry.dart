import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/agent/data/context/user_profile_manager.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/action/action_contract_v2_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_delivery_rollout_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/action/production_action_definition_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_capability_rollout_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_production_metrics_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_catalog_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/skills/data/installed_skill_locale_refresher.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_service.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';

/// Owns every [AgentRuntime] alive in the app, keyed by agentId, plus the
/// persistent per-agent skill enable/disable preferences.
class AgentRuntimeRegistry extends AppService {
  AgentRuntimeRegistry({
    String storageKeyPrefix = '',
    ActionContractV2Service? actionContract,
    ProductionActionDefinitionCatalog? productionActionCatalog,
    ConversationDeliveryRolloutService? conversationRollout,
    bool requirePinnedActionContract = false,
    bool useAppServicesActionContractFallback = false,
    bool hostExecutionEnabled = true,
  }) : _storageKeyPrefix = storageKeyPrefix.trim(),
       _hostExecutionEnabled = hostExecutionEnabled,
       _actionContract = actionContract,
       _productionActionCatalog = productionActionCatalog,
       _conversationRollout = conversationRollout,
       _requirePinnedActionContract = requirePinnedActionContract,
       _useAppServicesActionContractFallback =
           useAppServicesActionContractFallback {
    _conversationRolloutSubscription = conversationRollout?.changes.listen(
      _onConversationRolloutChanged,
    );
  }

  final Map<String, AgentRuntime> _runtimes = {};
  final InstalledSkillLocaleRefreshQueue _installedSkillLocaleRefreshQueue =
      InstalledSkillLocaleRefreshQueue();
  final Set<Future<void>> _accountOperations = <Future<void>>{};
  StreamSubscription<PromptSkillCatalogUpdate>? _promptCatalogSubscription;
  StreamSubscription<ConversationDeliveryRolloutSnapshot>?
  _conversationRolloutSubscription;
  Future<void>? _shutdownFuture;
  bool _globalsReady = false;
  bool _retiring = false;
  bool _hostExecutionEnabled;
  int _hostGeneration = 0;
  Future<void>? _hostSuspension;
  final Map<String, Future<AgentRuntime>> _pendingRuntimes = {};
  final String _storageKeyPrefix;
  final ActionContractV2Service? _actionContract;
  final ProductionActionDefinitionCatalog? _productionActionCatalog;
  final ConversationDeliveryRolloutService? _conversationRollout;
  final bool _requirePinnedActionContract;
  final bool _useAppServicesActionContractFallback;

  String _skillPrefsKey(String agentId) => _storageKeyPrefix.isEmpty
      ? 'enabledSkills.$agentId'
      : '$_storageKeyPrefix.preferences.enabledSkills.${_agentKeyDigest(agentId)}';

  static String _agentKeyDigest(String agentId) => sha256
      .convert(
        utf8.encode(
          'com.futurpals.maaso.preferences.enabled-skills.v1\u0000'
          '${agentId.trim()}',
        ),
      )
      .toString();

  /// Returns the runtime if it exists, otherwise null.
  AgentRuntime? get(String agentId) =>
      canHostExecution ? _runtimes[agentId] : null;

  bool get isRetiring => _retiring;

  /// Observes this device's mounted runtimes, pending creation and admitted
  /// account work without ensuring a runtime or changing shared execution.
  bool get isIdleForDiagnostics =>
      !_retiring &&
      _hostSuspension == null &&
      _pendingRuntimes.isEmpty &&
      _accountOperations.isEmpty &&
      _runtimes.values.every((runtime) => runtime.isIdleForDiagnostics);

  bool get canHostExecution => !_retiring && _hostExecutionEnabled;

  /// Restores this device's account-scoped runtime admission after a drain.
  /// Ordinary turns do not require another device's shared execution lease.
  void activateHostedExecution() {
    _requireActive();
    if (_hostSuspension != null ||
        (!_hostExecutionEnabled && _runtimes.isNotEmpty)) {
      throw StateError('Previous Agent execution is still draining.');
    }
    _hostExecutionEnabled = true;
  }

  /// Fence synchronously, then drain only hosted Agents, preserving page work.
  Future<void> suspendHostedExecution() {
    if (_hostSuspension != null) return _hostSuspension!;
    _hostExecutionEnabled = false;
    _hostGeneration++;
    final runtimes = _runtimes.values.toList(growable: false);
    final pending = _pendingRuntimes.values.toList(growable: false);
    final drains = runtimes.map((runtime) async {
      await runtime.retireAndDrain();
      // Failed drains retain their objects for lifecycle rollback/retry.
      if (identical(_runtimes[runtime.agentId], runtime)) {
        _runtimes.remove(runtime.agentId);
      }
    });
    final future = Future.wait<void>([
      ...drains,
      for (final creation in pending)
        creation.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]).then<void>((_) {});
    _hostSuspension = future.whenComplete(() => _hostSuspension = null);
    return _hostSuspension!;
  }

  void _requireHostGeneration(int generation) {
    _requireActive();
    if (!canHostExecution || generation != _hostGeneration) {
      throw StateError('Agent execution belongs to another device.');
    }
  }

  /// Tracks a controller-level account operation, including work that happens
  /// after [AgentRuntime.chat] returns (for example, persisting the assistant
  /// message). Calls admitted after retirement are ignored.
  Future<void> runAccountOperation(Future<void> Function() operation) {
    if (_retiring) return Future<void>.value();
    return _trackAccountOperation(operation);
  }

  /// Admits account work that must report retirement to its caller rather
  /// than silently becoming a no-op (for example, starting a live session).
  Future<T> runRequiredAccountOperation<T>(Future<T> Function() operation) {
    _requireActive();
    return _trackAccountOperation(operation);
  }

  /// Read which skill IDs are enabled for [agentId].  Defaults to the
  /// catalog's default set on first access.
  Future<Set<String>> readEnabledSkills(String agentId) async {
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList(_skillPrefsKey(agentId));
    if (ids == null) return SkillCatalog.defaultConfigured;
    // Always keep core skills enabled, drop unknown ids (catalog shrunk).
    final known = SkillCatalog.all
        .where((s) => !s.isComingSoon)
        .map((s) => s.id)
        .toSet();
    final enabled = {...ids.where(known.contains), ...SkillCatalog.coreIds};
    if (ids.length != enabled.length || !enabled.containsAll(ids)) {
      await prefs.setStringList(_skillPrefsKey(agentId), enabled.toList());
    }
    return enabled;
  }

  /// Persist enabled skill IDs for [agentId] and, if the runtime is alive,
  /// hot-reload its kernel so the new skill set takes effect immediately.
  Future<void> setEnabledSkills(String agentId, Set<String> ids) async {
    final prefs = await SharedPreferences.getInstance();
    final known = SkillCatalog.all
        .where((s) => !s.isComingSoon)
        .map((s) => s.id)
        .toSet();
    final merged = {...ids.where(known.contains), ...SkillCatalog.coreIds};
    await prefs.setStringList(_skillPrefsKey(agentId), merged.toList());

    final runtime = _runtimes[agentId];
    if (runtime != null) {
      await runtime.reloadSkills(merged);
    }
  }

  /// Ensure a runtime exists for [profile.userId].
  Future<AgentRuntime> ensure(AgentProfile profile) {
    final generation = _hostGeneration;
    _requireHostGeneration(generation);
    final pending = _pendingRuntimes[profile.userId];
    if (pending != null) return pending;
    late final Future<AgentRuntime> creation;
    creation = _trackAccountOperation(() => _ensureRuntime(profile, generation))
        .whenComplete(() {
          if (identical(_pendingRuntimes[profile.userId], creation)) {
            _pendingRuntimes.remove(profile.userId);
          }
        });
    _pendingRuntimes[profile.userId] = creation;
    return creation;
  }

  Future<AgentRuntime> _ensureRuntime(
    AgentProfile profile,
    int generation,
  ) async {
    _validateActionContractDependencies();
    final metrics = appServices.maybeFind<AgentProductionMetricsService>();
    final ensureStopwatch = metrics == null ? null : (Stopwatch()..start());
    var outcome = AgentRuntimeEnsureOutcome.error;
    try {
      await _bootGlobalsOnce();
      _requireHostGeneration(generation);
      final promptCatalog = _promptCatalog;
      if (promptCatalog != null) _listenToPromptCatalog(promptCatalog);
      final promptSnapshot =
          promptCatalog?.snapshotForAgent(profile.userId) ??
          PromptSkillSnapshot.empty;

      final llm = appServices.find<LLMProxyService>();
      // Probe once so the proxy cache is warm when cloud is configured.  A null
      // result is no longer fatal: AgentRuntime can run the local answer brain
      // without a cloud model.
      await llm.ensureClient();
      _requireHostGeneration(generation);

      final existing = _runtimes[profile.userId];
      if (existing != null) {
        existing.updateProfile(profile);
        await existing.reloadPromptSkillSnapshot(promptSnapshot);
        _requireHostGeneration(generation);
        warmPromptSkills(profile.userId);
        outcome = AgentRuntimeEnsureOutcome.reused;
        return existing;
      }

      final runtime = AgentRuntime(
        agentId: profile.userId,
        profile: profile,
        llmClient: llm.liveClient,
        semanticCreationEnabled: true,
        productionMetrics: metrics,
        capabilityRollout: appServices
            .maybeFind<AgentCapabilityRolloutService>(),
        actionContract: _actionContract,
        productionActionCatalog: _productionActionCatalog,
        requirePinnedActionContract: _requirePinnedActionContract,
        useAppServicesActionContractFallback:
            _useAppServicesActionContractFallback,
        conversationDeliveryAdmissionProvider: _conversationRollout == null
            ? null
            : () {
                final snapshot = _conversationRollout.currentSnapshot();
                return ConversationDeliveryAdmission(
                  mode: snapshot.mode,
                  isCurrent: () => _conversationRollout.isCurrent(snapshot),
                );
              },
      );
      try {
        final enabled = await readEnabledSkills(profile.userId);
        _requireHostGeneration(generation);
        await runtime.init(enabledSkillIds: enabled);
        _requireHostGeneration(generation);
        await runtime.reloadPromptSkillSnapshot(promptSnapshot);
        _requireHostGeneration(generation);
      } catch (_) {
        await runtime.retireAndDrain();
        rethrow;
      }
      _runtimes[profile.userId] = runtime;
      warmPromptSkills(profile.userId);
      outcome = AgentRuntimeEnsureOutcome.created;
      return runtime;
    } finally {
      if (metrics != null && ensureStopwatch != null) {
        metrics.recordRuntimeEnsure(ensureStopwatch.elapsed, outcome);
      }
    }
  }

  void _validateActionContractDependencies() {
    final serviceAvailable = _actionContract != null;
    final catalogAvailable = _productionActionCatalog != null;
    if (serviceAvailable != catalogAvailable ||
        (_requirePinnedActionContract && !serviceAvailable)) {
      throw StateError('action_contract_dependencies_unavailable');
    }
  }

  Future<T> _trackAccountOperation<T>(Future<T> Function() operation) {
    final settled = Completer<void>();
    final tracked = settled.future;
    _accountOperations.add(tracked);
    late Future<T> result;
    try {
      result = Future<T>.sync(operation);
    } catch (error, stackTrace) {
      _accountOperations.remove(tracked);
      settled.complete();
      return Future<T>.error(error, stackTrace);
    }
    return result.whenComplete(() {
      _accountOperations.remove(tracked);
      if (!settled.isCompleted) settled.complete();
    });
  }

  void _requireActive() {
    if (_retiring) {
      throw StateError('Agent runtime registry is retiring.');
    }
  }

  /// Tear down a single agent runtime.
  void disposeAgent(String agentId) {
    _runtimes.remove(agentId)?.dispose();
  }

  Future<void> refreshInstalledSkills(String agentId) async {
    final promptCatalog = _promptCatalog;
    if (promptCatalog == null) return;
    _listenToPromptCatalog(promptCatalog);
    final locale =
        appServices.maybeFind<LocaleConfigService>()?.resolvedAppLocale ??
        AppLocale.en;
    final snapshot = await promptCatalog.refreshInstalled(
      agentId,
      locale: locale,
    );
    final runtime = _runtimes[agentId];
    if (runtime != null) await runtime.reloadPromptSkillSnapshot(snapshot);
  }

  /// Starts an installed Skill snapshot read outside the first-turn path.
  void warmPromptSkills(String agentId) {
    if (_retiring) return;
    final id = agentId.trim();
    final promptCatalog = _promptCatalog;
    if (id.isEmpty || promptCatalog == null) return;
    _listenToPromptCatalog(promptCatalog);
    final locale =
        appServices.maybeFind<LocaleConfigService>()?.resolvedAppLocale ??
        AppLocale.en;
    Timer.run(() {
      if (_retiring) return;
      unawaited(
        runAccountOperation(() => _warmPromptSkills(promptCatalog, id, locale)),
      );
    });
  }

  Future<void> _warmPromptSkills(
    PromptSkillCatalogService catalog,
    String agentId,
    AppLocale locale,
  ) async {
    try {
      await catalog.warmAgent(agentId, locale: locale);
    } catch (error, stackTrace) {
      debugPrint(
        '[PromptSkillCatalog] warm failed for $agentId: $error\n$stackTrace',
      );
    }
  }

  /// Permanently fences this account registry and waits for every admitted
  /// controller operation and runtime turn before account services disappear.
  /// Concurrent and repeated callers share the same retryable shutdown.
  Future<void> shutdown() {
    _retiring = true;
    _hostExecutionEnabled = false;
    _hostGeneration++;
    return _shutdownFuture ??= _shutdownOnce();
  }

  Future<void> _shutdownOnce() async {
    var completed = false;
    try {
      _installedSkillLocaleRefreshQueue.invalidate();
      final conversationRolloutSubscription = _conversationRolloutSubscription;
      if (conversationRolloutSubscription != null) {
        await conversationRolloutSubscription.cancel();
        if (identical(
          _conversationRolloutSubscription,
          conversationRolloutSubscription,
        )) {
          _conversationRolloutSubscription = null;
        }
      }
      final runtimeDrains = _runtimes.values
          .map((runtime) => runtime.retireAndDrain())
          .toList(growable: false);

      while (_accountOperations.isNotEmpty) {
        await Future.wait<void>(_accountOperations.toList(growable: false));
      }
      await Future.wait<void>(runtimeDrains);
      await _hostSuspension;

      final promptCatalogSubscription = _promptCatalogSubscription;
      if (promptCatalogSubscription != null) {
        await promptCatalogSubscription.cancel();
        if (identical(_promptCatalogSubscription, promptCatalogSubscription)) {
          _promptCatalogSubscription = null;
        }
      }
      _runtimes.clear();
      UserProfileManager().deactivate(storageKeyPrefix: _storageKeyPrefix);
      _globalsReady = false;
      completed = true;
    } finally {
      if (!completed) _shutdownFuture = null;
    }
  }

  void _onConversationRolloutChanged(
    ConversationDeliveryRolloutSnapshot snapshot,
  ) {
    if (_retiring) return;
    for (final runtime in _runtimes.values.toList(growable: false)) {
      unawaited(
        _trackAccountOperation(
          runtime.revokeConversationDelivery,
        ).catchError((Object _, StackTrace _) {}),
      );
    }
  }

  /// Invalidates every in-memory Marketplace appendix before a locale commit.
  ///
  /// This is deliberately synchronous: during the following database read or
  /// network refresh, a new turn sees no appendix instead of stale official
  /// content from the previous language. Author content is restored by the
  /// locale-aware rebuild immediately after the locale is committed.
  void invalidateInstalledSkillPrompts() {
    _installedSkillLocaleRefreshQueue.invalidate();
    final promptCatalog = _promptCatalog;
    for (final entry in _runtimes.entries) {
      final runtime = entry.value;
      runtime.invalidateInstalledSkillPrompt();
      if (promptCatalog != null) {
        final snapshot = promptCatalog.invalidateInstalled(entry.key);
        unawaited(runtime.reloadPromptSkillSnapshot(snapshot));
      }
    }
  }

  /// Re-fetches locale-aware official Skill projections, then re-renders the
  /// prompt wrapper. Marketplace author content round-trips unchanged.
  Future<void> refreshInstalledSkillPrompts({
    Iterable<String> agentIds = const <String>[],
  }) async {
    final expectedLocale =
        appServices.maybeFind<LocaleConfigService>()?.resolvedAppLocale ??
        AppLocale.en;
    final targets = <String>{
      ..._runtimes.keys,
      ...agentIds.map((id) => id.trim()).where((id) => id.isNotEmpty),
    };
    await _installedSkillLocaleRefreshQueue.run(
      beforeWait: (isCurrent) => _reloadInstalledSkillPrompts(
        targets: targets,
        expectedLocale: expectedLocale,
        isCurrent: isCurrent,
      ),
      operation: (isCurrent) => _refreshInstalledSkillPrompts(
        targets: targets,
        expectedLocale: expectedLocale,
        isCurrent: isCurrent,
      ),
    );
  }

  Future<void> _reloadInstalledSkillPrompts({
    required Set<String> targets,
    required AppLocale expectedLocale,
    required bool Function() isCurrent,
  }) async {
    final promptCatalog = _promptCatalog;
    if (promptCatalog == null) return;
    _listenToPromptCatalog(promptCatalog);
    for (final agentId in targets) {
      if (!isCurrent()) return;
      final snapshot = await promptCatalog.refreshInstalled(
        agentId,
        locale: expectedLocale,
        shouldApply: isCurrent,
      );
      if (!isCurrent()) return;
      final runtime = _runtimes[agentId];
      if (runtime != null) {
        await runtime.reloadPromptSkillSnapshot(snapshot);
      }
    }
  }

  Future<void> _refreshInstalledSkillPrompts({
    required Set<String> targets,
    required AppLocale expectedLocale,
    required bool Function() isCurrent,
  }) async {
    final canRefreshMarketplace =
        appServices.isRegistered<InstalledSkillRegistry>() &&
        appServices.isRegistered<SkillMarketplaceService>();
    final localeRefresher = canRefreshMarketplace
        ? InstalledSkillLocaleRefresher(
            registry: appServices.find<InstalledSkillRegistry>(),
            loadSkill: appServices.find<SkillMarketplaceService>().getSkill,
          )
        : null;

    for (final agentId in targets) {
      if (!isCurrent()) return;
      final result = await localeRefresher?.refreshForAgent(
        agentId,
        expectedLocale: expectedLocale,
        shouldApply: isCurrent,
      );
      if (!isCurrent() || result?.superseded == true) return;
      if (result?.hasFailures == true) {
        debugPrint(
          '[SkillLocale] kept cached content for '
          '${result!.failures.length} Skill(s) after refresh failure',
        );
      }
      await _reloadInstalledSkillPrompts(
        targets: <String>{agentId},
        expectedLocale: expectedLocale,
        isCurrent: isCurrent,
      );
    }
  }

  @override
  void onClose() {
    unawaited(
      shutdown().catchError((Object error, StackTrace stackTrace) {
        debugPrint(
          '[AgentRuntimeRegistry] asynchronous shutdown failed: '
          '$error\n$stackTrace',
        );
      }),
    );
    super.onClose();
  }

  Future<void> _bootGlobalsOnce() async {
    if (_globalsReady) return;
    await UserProfileManager().init(storageKeyPrefix: _storageKeyPrefix);
    _globalsReady = true;
  }

  PromptSkillCatalogService? get _promptCatalog =>
      appServices.maybeFind<PromptSkillCatalogService>();

  void _listenToPromptCatalog(PromptSkillCatalogService catalog) {
    _promptCatalogSubscription ??= catalog.updates.listen((update) {
      if (_retiring) return;
      final runtime = _runtimes[update.agentId];
      if (runtime != null) {
        unawaited(runtime.reloadPromptSkillSnapshot(update.snapshot));
      }
    });
  }
}
