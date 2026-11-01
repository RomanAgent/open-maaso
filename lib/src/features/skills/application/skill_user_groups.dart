import 'package:flutter/material.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';

/// Product-facing groups only. Execution IDs, contracts and permission checks
/// remain owned by SkillCatalog and the runtime.
class SkillUserGroup {
  const SkillUserGroup({
    required this.id,
    required this.skillIds,
    required this.icon,
    this.configurationRoute,
  });

  final String id;
  final List<String> skillIds;
  final IconData icon;
  final String? configurationRoute;

  String get nameKey => 'skills.group.$id.name';
  String get descriptionKey => 'skills.group.$id.description';

  List<SkillSpec> get specs => [
    for (final id in skillIds) ?SkillCatalog.byId(id),
  ];

  List<SkillSpec> get optionalSpecs => [
    for (final spec in specs)
      if (!spec.isCore && !spec.isComingSoon) spec,
  ];

  bool get isCore => optionalSpecs.isEmpty;

  bool isVisible(AppCapabilitySnapshot? snapshot) => specs.any(
    (spec) =>
        !spec.isComingSoon &&
        spec.isAvailable &&
        (snapshot?.exposes(AppCapabilityKey.skill(spec.id)) ?? true),
  );

  bool canEnable(AppCapabilitySnapshot? snapshot) => optionalSpecs.every(
    (spec) =>
        spec.isAvailable &&
        (snapshot?.allows(
              AppCapabilityKey.skill(spec.id),
              requireVisible: true,
            ) ??
            true),
  );

  /// Read the original skill names so consolidation preserves old counters.
  /// A duplicate routing name never adds the same execution twice.
  SkillUsageSummary usage(SkillUsageService service) {
    var started = 0;
    var succeeded = 0;
    var failed = 0;
    DateTime? lastUsed;
    final names = <String>{
      for (final spec in specs) ?spec.hostRouting?.skillName,
    };
    for (final name in names) {
      final summary = service.forSkill(name);
      started += summary.started;
      succeeded += summary.succeeded;
      failed += summary.failed;
      if (summary.lastUsed case final used?) {
        if (lastUsed == null || used.isAfter(lastUsed)) lastUsed = used;
      }
    }
    return SkillUsageSummary(
      started: started,
      succeeded: succeeded,
      failed: failed,
      lastUsed: lastUsed,
    );
  }
}

class SkillUserGroupCatalog {
  const SkillUserGroupCatalog._();

  static const all = <SkillUserGroup>[
    SkillUserGroup(
      id: 'creation',
      skillIds: ['freeform_surface', 'creator'],
      icon: Icons.auto_awesome_rounded,
    ),
    SkillUserGroup(
      id: 'web_search',
      skillIds: ['web_search'],
      icon: Icons.travel_explore_rounded,
    ),
    SkillUserGroup(
      id: 'applet_discovery',
      skillIds: ['applet_discovery'],
      icon: Icons.widgets_outlined,
    ),
    SkillUserGroup(
      id: 'app_operations',
      skillIds: ['app_control', 'app_navigate'],
      icon: Icons.touch_app_rounded,
    ),
    SkillUserGroup(
      id: 'memory',
      skillIds: [
        'set_master',
        'set_world',
        'log_episode',
        'log_milestone',
        'memory',
      ],
      icon: Icons.memory_rounded,
      configurationRoute: AppRouteCatalog.memoryLedger,
    ),
    SkillUserGroup(
      id: 'persona',
      skillIds: ['set_soul', 'behavior'],
      icon: Icons.person_pin_rounded,
      configurationRoute: '${AppRouteCatalog.memoryWall}?section=profile',
    ),
    SkillUserGroup(
      id: 'tasks',
      skillIds: ['todo', 'scheduled_task', 'alert'],
      icon: Icons.checklist_rounded,
    ),
    SkillUserGroup(
      id: 'projection',
      skillIds: ['bluetooth', 'ble_yoturetoys_projector'],
      icon: Icons.cast_rounded,
    ),
    SkillUserGroup(
      id: 'companion_activity',
      skillIds: ['companion_activity'],
      icon: Icons.favorite_border_rounded,
    ),
  ];

  /// These remain runtime capabilities rather than user-installable skills.
  static const internalSkillIds = <String>{
    'face',
    'avatar_camera',
    'http',
    'show_card',
    'device_handoff',
    'project_control',
  };

  static SkillUserGroup? byId(String id) {
    for (final group in all) {
      if (group.id == id) return group;
    }
    return null;
  }
}
