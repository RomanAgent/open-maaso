import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/connectivity_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';

/// Single source of truth for "which brain is active".
///
/// Policy (cloud-priority, NO parallel):
///   • When the cloud LLM is usable & healthy, it is the ONLY brain — the local
///     model is unloaded to free RAM/CPU.
///   • The local model only comes up when the cloud is **not enabled** or
///     **unavailable** (offline / unhealthy), acting purely as an offline
///     fallback. The user's local opt-in is preserved as a preference and
///     resumes automatically when the cloud goes away.
///
/// [cloudActive] mirrors `_cloudMainPathBlockReason()==null` in AgentRuntime so
/// the loading policy and the routing decision never disagree.
class LlmModeCoordinator extends AppService {
  final RxBool cloudActive = false.obs;

  final List<Worker> _workers = [];
  bool _applied = false;

  LlmModeCoordinator init() {
    // Compute the initial verdict synchronously BEFORE the boot controller's
    // auto-enable runs, so the local model is never loaded under cloud mode.
    _recompute();

    // React to anything that changes cloud usability.
    if (appServices.isRegistered<LLMConfigController>()) {
      final cfg = appServices.find<LLMConfigController>();
      _workers.add(ever(cfg.cloudEnabled, (_) => _recompute()));
      _workers.add(ever(cfg.apiKey, (_) => _recompute()));
    }
    if (appServices.isRegistered<CloudLLMHealthService>()) {
      _workers.add(
        ever(
          appServices.find<CloudLLMHealthService>().health,
          (_) => _recompute(),
        ),
      );
    }
    if (appServices.isRegistered<ConnectivityService>()) {
      _workers.add(
        ever(
          appServices.find<ConnectivityService>().isOnline,
          (_) => _recompute(),
        ),
      );
    }
    // Re-apply residency when the user flips local opt-in / save-memory.
    if (appServices.isRegistered<LocalLLMService>()) {
      final local = appServices.find<LocalLLMService>();
      _workers.add(ever(local.isEnabled, (_) => _recompute(force: true)));
      _workers.add(ever(local.saveMemory, (_) => _recompute(force: true)));
    }
    return this;
  }

  bool _computeCloudActive() {
    final online =
        !appServices.isRegistered<ConnectivityService>() ||
        appServices.find<ConnectivityService>().isOnline.value;
    final cloudUsable =
        appServices.isRegistered<LLMConfigController>() &&
        appServices.find<LLMConfigController>().cloudUsable;
    final permitted =
        !appServices.isRegistered<CloudLLMHealthService>() ||
        appServices.find<CloudLLMHealthService>().cloudPermittedForRouting;
    return online && cloudUsable && permitted;
  }

  void _recompute({bool force = false}) {
    final active = _computeCloudActive();
    final changed = !_applied || active != cloudActive.value;
    if (!changed && !force) return;
    _applied = true;
    cloudActive.value = active;
    if (!appServices.isRegistered<LocalLLMService>()) return;
    final svc = appServices.find<LocalLLMService>();
    // Local stays resident unless save-memory is ON *and* the cloud is active.
    final resident = !svc.saveMemory.value || !active;
    final localState = !svc.isEnabled.value
        ? 'disabled'
        : resident
        ? 'resident'
        : 'unloaded (save memory)';
    Log.i(
      '🧭 [LlmMode] cloudActive=$active localEnabled=${svc.isEnabled.value} '
      'saveMemory=${svc.saveMemory.value} → local model $localState',
    );
    // ignore: unawaited_futures
    svc.applyResident(resident);
  }

  @override
  void onClose() {
    for (final w in _workers) {
      w.dispose();
    }
    _workers.clear();
    super.onClose();
  }
}
