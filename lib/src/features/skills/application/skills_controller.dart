import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'skill_user_groups.dart';

class SkillsController extends AppController {
  final AgentRuntimeRegistry _registry = appServices
      .find<AgentRuntimeRegistry>();
  final AgentCoreController _core = appServices.find<AgentCoreController>();

  /// IDs currently enabled for the user's self agent.  Mirrors what's
  /// persisted in shared_preferences; the UI binds to this for instant
  /// feedback while the registry persists in the background.
  final enabled = <String>{}.obs;

  /// True while reloadSkills is running.
  final isApplying = false.obs;

  String get _selfId => _core.profile.value?.userId ?? 'self';

  bool _ownsPreferenceScope(String selfId) =>
      !isClosed &&
      !_registry.isClosed &&
      !_registry.isRetiring &&
      !_core.isClosed &&
      _selfId == selfId &&
      identical(appServices.maybeFind<AgentRuntimeRegistry>(), _registry) &&
      identical(appServices.maybeFind<AgentCoreController>(), _core);

  @override
  void onInit() {
    super.onInit();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    final selfId = _selfId;
    isApplying.value = true;
    try {
      final initial = await _registry.readEnabledSkills(selfId);
      if (_ownsPreferenceScope(selfId)) enabled.assignAll(initial);
    } finally {
      if (_ownsPreferenceScope(selfId)) isApplying.value = false;
    }
  }

  Future<void> toggle(String id, bool on) async {
    final spec = SkillCatalog.byId(id);
    if (!_ownsPreferenceScope(_selfId) ||
        spec == null ||
        spec.isCore ||
        spec.isComingSoon ||
        isApplying.value) {
      return;
    }
    if (on) {
      if (!spec.isAvailable) return;
      final snapshots = appServices.maybeFind<AppCapabilitySnapshotService>();
      if (snapshots != null &&
          (snapshots.isClosed ||
              !snapshots.value.allows(
                AppCapabilityKey.skill(id),
                requireVisible: true,
              ))) {
        return;
      }
    }
    final next = {...enabled};
    if (on) {
      next.add(id);
    } else {
      next.remove(id);
    }
    await _apply(next);
  }

  bool isEnabled(String id) => enabled.contains(id);

  bool isGroupEnabled(String groupId) {
    final group = SkillUserGroupCatalog.byId(groupId);
    return group != null &&
        (group.isCore ||
            group.optionalSpecs.every((spec) => isEnabled(spec.id)));
  }

  Future<void> toggleGroup(String groupId, bool on) async {
    final group = SkillUserGroupCatalog.byId(groupId);
    if (!_ownsPreferenceScope(_selfId) ||
        group == null ||
        group.isCore ||
        isApplying.value) {
      return;
    }
    if (on) {
      final snapshots = appServices.maybeFind<AppCapabilitySnapshotService>();
      if (snapshots?.isClosed == true || !group.canEnable(snapshots?.value)) {
        return;
      }
    }
    final ids = group.optionalSpecs.map((spec) => spec.id).toSet();
    final next = {...enabled};
    on ? next.addAll(ids) : next.removeAll(ids);
    await _apply(next);
  }

  Future<void> _apply(Set<String> next) async {
    final previous = {...enabled};
    final selfId = _selfId;
    enabled.assignAll(next);
    isApplying.value = true;
    try {
      // One persisted set prevents partial activation of a combined skill.
      await _registry.setEnabledSkills(selfId, next);
    } catch (_) {
      if (_ownsPreferenceScope(selfId)) {
        Set<String>? persisted;
        try {
          // Preferences may already have committed before kernel reload fails.
          persisted = await _registry.readEnabledSkills(selfId);
        } catch (_) {
          // If storage itself is unavailable, retain this account's last known
          // set. Never let the recovery callback mutate a replacement account.
        }
        if (_ownsPreferenceScope(selfId)) {
          enabled.assignAll(persisted ?? previous);
        }
      }
      rethrow;
    } finally {
      if (_ownsPreferenceScope(selfId)) isApplying.value = false;
    }
  }
}
