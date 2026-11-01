import 'dart:convert';

import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

/// One-turn authority to create exactly one generated surface.
///
/// A non-empty grant can only be derived from a current, registry-issued
/// [ExecutableHostGrant] for the real `FreeformSurface` host. It is also bound
/// to one Agent, one Applet ownership scope and one experience type. The
/// executor performs the final one-shot consumption immediately before any
/// quota, persistence or presentation side effect.
final class SurfaceExecutionGrant {
  SurfaceExecutionGrant._({
    required ExecutableHostGrant executableHostGrant,
    required AgentSkill? surfaceSkill,
    required String? proofTool,
    required String? agentId,
    required String? appletScopeKey,
    required SurfaceExperienceType? experienceType,
    bool consumed = false,
  }) : _executableHostGrant = executableHostGrant,
       _surfaceSkill = surfaceSkill,
       _proofTool = proofTool,
       _agentId = agentId,
       _appletScopeKey = appletScopeKey,
       _experienceType = experienceType,
       _consumed = consumed;

  static SurfaceExecutionGrant get none => SurfaceExecutionGrant._(
    executableHostGrant: ExecutableHostGrant.none,
    surfaceSkill: null,
    proofTool: null,
    agentId: null,
    appletScopeKey: null,
    experienceType: null,
    consumed: true,
  );

  final ExecutableHostGrant _executableHostGrant;
  final AgentSkill? _surfaceSkill;
  final String? _proofTool;
  final String? _agentId;
  final String? _appletScopeKey;
  final SurfaceExperienceType? _experienceType;
  bool _consumed;

  static SurfaceExecutionGrant issue({
    required ExecutableHostGrant executableHostGrant,
    required String agentId,
    required String appletScopeKey,
    required SurfaceExperienceType experienceType,
  }) {
    final normalizedAgentId = agentId.trim();
    final normalizedScopeKey = appletScopeKey.trim();
    if (normalizedAgentId.isEmpty ||
        normalizedScopeKey.isEmpty ||
        !executableHostGrant.isCurrent ||
        !executableHostGrant.allowsSkillName('FreeformSurface')) {
      return none;
    }

    AgentSkill? surfaceSkill;
    for (final skill in executableHostGrant.activatedSkills) {
      if (skill.skillName == 'FreeformSurface') {
        surfaceSkill = skill;
        break;
      }
    }
    if (surfaceSkill == null) return none;

    String? proofTool;
    for (final method in surfaceSkill.methods.keys) {
      final tool = SkillManager.nativeToolName(surfaceSkill, method);
      final binding = executableHostGrant.authorize(
        agentId: normalizedAgentId,
        tool: tool,
      );
      if (binding != null && identical(binding.skill, surfaceSkill)) {
        proofTool = tool;
        break;
      }
    }
    if (proofTool == null) return none;

    return SurfaceExecutionGrant._(
      executableHostGrant: executableHostGrant,
      surfaceSkill: surfaceSkill,
      proofTool: proofTool,
      agentId: normalizedAgentId,
      appletScopeKey: normalizedScopeKey,
      experienceType: experienceType,
    );
  }

  bool get authorityIsCurrent {
    final skill = _surfaceSkill;
    return skill != null &&
        _proofTool != null &&
        _agentId != null &&
        _appletScopeKey != null &&
        _experienceType != null &&
        _executableHostGrant.isCurrent &&
        _executableHostGrant.allowsSkillName('FreeformSurface');
  }

  bool get isCurrent => !_consumed && authorityIsCurrent;

  bool get isEmpty => !isCurrent;

  void requireAuthorityCurrent() {
    if (!authorityIsCurrent) throw const SurfaceNotGrantedException();
  }

  bool allows({
    required String agentId,
    required String appletScopeKey,
    required SurfaceExperienceType experienceType,
    required AgentSkill? registeredSurfaceSkill,
  }) {
    final skill = _surfaceSkill;
    final proofTool = _proofTool;
    if (!isCurrent ||
        skill == null ||
        proofTool == null ||
        agentId.trim() != _agentId ||
        appletScopeKey.trim() != _appletScopeKey ||
        experienceType != _experienceType ||
        !identical(registeredSurfaceSkill, skill)) {
      return false;
    }
    final binding = _executableHostGrant.authorize(
      agentId: agentId.trim(),
      tool: proofTool,
    );
    return binding != null && identical(binding.skill, skill);
  }

  /// Atomically consumes this one-shot authority in the current isolate.
  ///
  /// Consumption lives on the grant rather than an executor so handing the
  /// same object to two executors cannot replay a single user authorization.
  bool tryConsume({
    required String agentId,
    required String appletScopeKey,
    required SurfaceExperienceType experienceType,
    required AgentSkill? registeredSurfaceSkill,
  }) {
    if (!allows(
      agentId: agentId,
      appletScopeKey: appletScopeKey,
      experienceType: experienceType,
      registeredSurfaceSkill: registeredSurfaceSkill,
    )) {
      return false;
    }
    _consumed = true;
    return true;
  }
}

final class SurfaceNotGrantedException implements Exception {
  const SurfaceNotGrantedException();

  @override
  String toString() =>
      jsonEncode(<String, Object?>{'error': 'surface_not_granted'});
}
