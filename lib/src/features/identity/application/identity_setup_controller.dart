import 'package:maaso/src/core/foundation/app_framework.dart';

import '../domain/identity_profile.dart';
import '../domain/identity_local_state.dart';
import 'identity_service.dart';

/// The first-run form only fills missing public names. Editing an existing
/// profile is an explicit host-selected mode of the same form.
final class IdentitySetupController extends AppController {
  IdentitySetupController({
    required this.service,
    this.legacyAgentName,
    this.onlyMissing = true,
  });

  final IdentityService service;
  final String Function()? legacyAgentName;
  final bool onlyMissing;
  final playerName = ''.obs;
  final agentName = ''.obs;
  final loading = false.obs;
  final saving = false.obs;
  final ready = false.obs;
  final revision = 0.obs;
  final Rxn<IdentityFailure> error = Rxn<IdentityFailure>();
  bool _playerEdited = false;
  bool _agentEdited = false;
  bool _retired = false;
  bool _userHasControl = false;
  bool _legacyNameCaptured = false;
  String? _preservedLegacyName;

  bool get active => !_retired && service.isCurrent;
  bool get playerLocked => onlyMissing && service.setupPlayerName.isNotEmpty;
  bool get agentLocked =>
      onlyMissing &&
      (service.setupAgentName.isNotEmpty || _preservedLegacyName != null);
  bool get canSave =>
      active &&
      ready.value &&
      !loading.value &&
      !saving.value &&
      IdentityNames.validate(playerName.value) == null &&
      IdentityNames.validate(agentName.value) == null;
  bool get canPrepare =>
      active && ready.value && !saving.value && !_userHasControl;

  Future<void> initialize() async {
    if (!active || loading.value) return;
    loading.value = true;
    error.value = null;
    try {
      await service.restore();
      if (!active) return;
      if (onlyMissing && service.onboardingCompleted) {
        _seed();
        ready.value = true;
        return;
      }
      await service.load();
      if (!active) return;
      _seed();
      ready.value = true;
    } on IdentityException catch (failure) {
      if (!active) return;
      if (failure.failure == IdentityFailure.unavailable &&
          service.canSaveLocally) {
        _seed();
        ready.value = true;
      } else {
        error.value = failure.failure;
      }
    } catch (_) {
      if (active) error.value = IdentityFailure.unavailable;
    } finally {
      if (!_retired) loading.value = false;
    }
  }

  void _seed({bool conflict = false}) {
    if (!_legacyNameCaptured) {
      _legacyNameCaptured = true;
      final legacy = legacyAgentName?.call() ?? '';
      if (IdentityNames.validate(legacy) == null) {
        _preservedLegacyName = legacy.trim();
      }
    }
    if (conflict || !_playerEdited || playerLocked) {
      playerName.value = service.setupPlayerName;
    }
    if (conflict || !_agentEdited || agentLocked) {
      agentName.value = service.setupAgentName.isNotEmpty
          ? service.setupAgentName
          : onlyMissing || !conflict
          ? _preservedLegacyName ?? ''
          : '';
    }
    revision.value++;
  }

  void setUserControl(bool active) => _userHasControl = active;

  void setPlayerName(String value) {
    if (!active || playerLocked || saving.value) return;
    _playerEdited = true;
    playerName.value = value;
    error.value = null;
  }

  void setAgentName(String value) {
    if (!active || agentLocked || saving.value) return;
    _agentEdited = true;
    agentName.value = value;
    error.value = null;
  }

  /// Bounded local draft only. It never invokes IdentityService.save.
  bool prepareNames({required String player, required String agent}) {
    if (!canPrepare ||
        IdentityNames.validate(player) != null ||
        IdentityNames.validate(agent) != null) {
      return false;
    }
    if ((playerLocked && player.trim() != playerName.value) ||
        (agentLocked && agent.trim() != agentName.value)) {
      return false;
    }
    setPlayerName(player.trim());
    setAgentName(agent.trim());
    revision.value++;
    return true;
  }

  Future<IdentitySetupResult?> save() async {
    if (!canSave) return null;
    saving.value = true;
    error.value = null;
    try {
      final result = await service.saveSetup(
        playerName: playerName.value,
        agentName: agentName.value,
      );
      if (!active) return null;
      _seed();
      return result;
    } on IdentityException catch (failure) {
      if (!active) return null;
      error.value = failure.failure;
      if (failure.failure == IdentityFailure.conflict) {
        // Fetch the winner for review. Never retry a conflicting write silently.
        ready.value = false;
        try {
          await service.load();
          if (active) {
            _seed(conflict: true);
            ready.value = true;
          }
        } catch (_) {
          /* Leave the form blocked until an explicit reload. */
        }
      }
      return null;
    } catch (_) {
      if (active) error.value = IdentityFailure.unavailable;
      return null;
    } finally {
      if (!_retired) saving.value = false;
    }
  }

  @override
  void onClose() {
    _retired = true;
    super.onClose();
  }
}
