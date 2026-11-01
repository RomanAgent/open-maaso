import 'dart:async';

import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

enum SurfaceInteractionOperation { edit, revert }

extension on SurfaceInteractionOperation {
  String get methodName => switch (this) {
    SurfaceInteractionOperation.edit => 'editSurface',
    SurfaceInteractionOperation.revert => 'revertSurface',
  };
}

final class SurfaceInteractionRequest {
  const SurfaceInteractionRequest({
    required this.operation,
    required this.targetSurfaceId,
  });

  final SurfaceInteractionOperation operation;
  final String targetSurfaceId;

  String get methodName => operation.methodName;

  String get cacheKey => '${operation.name}:$targetSurfaceId';
}

/// Recognizes a narrow, user-authored request to operate on the visible
/// Surface. Informational questions and negated commands never create
/// authority.
final class SurfaceInteractionAuthority {
  const SurfaceInteractionAuthority._();

  static SurfaceInteractionRequest? resolve({
    required String text,
    required String activeSurfaceId,
  }) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty || _isNegated(normalized)) return null;
    if (_isAmbiguousCommandQuestion(normalized)) return null;
    if (_isInformationalQuestion(normalized)) return null;

    final operation = _operation(normalized);
    if (operation == null) return null;
    final targetId = activeSurfaceId.trim();
    if (targetId.isEmpty) return null;
    return SurfaceInteractionRequest(
      operation: operation,
      targetSurfaceId: targetId,
    );
  }

  static SurfaceInteractionOperation? _operation(String text) {
    if (_matchesEnglishCommand(text, r'(?:revert|undo|roll\s+back|restore)') ||
        _matchesChineseCommand(text, r'(?:撤销|还原|恢复上一版|回退)')) {
      return SurfaceInteractionOperation.revert;
    }
    if (_matchesEnglishCommand(
          text,
          r'(?:edit|change|update|revise|rewrite|adjust|fix|add|append|insert|remove|delete|replace)',
        ) ||
        _matchesChineseCommand(
          text,
          r'(?:修改|编辑|改一下|改成|调整|更新|再加|加一|添加|增加|新增|删掉|删除|去掉|移除|替换|补充)',
        )) {
      return SurfaceInteractionOperation.edit;
    }
    return null;
  }

  static bool _isNegated(String text) =>
      RegExp(
        r'(?:不要|不用|无需|别|先别|暂不)(?:再|帮我|给我|请你){0,3}(?:修改|编辑|改|调整|更新|加|添加|增加|新增|删掉|删除|去掉|移除|替换|补充|撤销|还原)',
      ).hasMatch(text.replaceAll(RegExp(r'\s+'), '')) ||
      RegExp(
        r"\b(?:don['’]?t|do\s+not|never|not)\s+(?:\w+\s+){0,3}(?:edit|change|update|revise|rewrite|adjust|fix|add|append|insert|remove|delete|replace|revert|undo)\b",
      ).hasMatch(text) ||
      RegExp(
        r'(?:不要|不用|无需|别|先别|暂不)(?:先|再|帮我|给我|请你){0,3}(?:保存|存储|持久化|落盘|应用|提交)',
      ).hasMatch(text.replaceAll(RegExp(r'\s+'), '')) ||
      RegExp(
        r'(?:不要|不用|无需|别|先别|暂不)(?:先|再|帮我|给我|请你){0,3}(?:重新)?(?:打开|展示|显示|弹出|呈现)',
      ).hasMatch(text.replaceAll(RegExp(r'\s+'), '')) ||
      RegExp(
        r"\b(?:don['’]?t|do\s+not|never)\s+(?:\w+\s+){0,3}(?:save|persist|store|apply|commit|show|open|reopen|display|present)\b|\bwithout\s+(?:saving|persisting|storing|applying|committing|showing|opening|reopening|displaying|presenting)\b",
      ).hasMatch(text);

  static bool _isAmbiguousCommandQuestion(String text) {
    if (RegExp(
          r'\b(?:or|versus|vs\.?)\b.{0,80}\b(?:which|what)\b.{0,32}\b(?:better|safer|cheaper|faster|easier|best)\b|'
          r'[—–:;,]\s*(?:what|how|why|when|where|which|who)\b',
        ).hasMatch(text) ||
        RegExp(
          r'(?:还是|或者).{0,80}(?:更好|更安全|更便宜|更快|更容易|哪个好|哪种好|怎么选|选哪个|会怎样)',
        ).hasMatch(text)) {
      return true;
    }
    if (!RegExp(r'[?？]\s*$').hasMatch(text)) return false;
    if (RegExp(r'\b(?:what|how|why|when|where|which|who)\b').hasMatch(text) ||
        RegExp(
          r'(?:什么|哪里|哪儿|怎么|如何|为什么|多少|多久|多长|哪个|哪些|难不难|还是|或者.{0,20}(?:更好|更安全|更便宜|会怎样))',
        ).hasMatch(text)) {
      return true;
    }
    final explicitRequest =
        RegExp(
          r'^(?:please|kindly|can you|could you|would you|will you|help me)\b',
        ).hasMatch(text) ||
        RegExp(r'^(?:请|麻烦|帮我|给我|替我|可以|能不能)').hasMatch(text);
    return !explicitRequest;
  }

  static bool _isInformationalQuestion(String text) {
    if (RegExp(r'^(?:what|how|why|when|where|which|who)\b').hasMatch(text)) {
      return true;
    }
    if (RegExp(
      r'^(?:(?:can|could|would) you )?(?:tell|explain|describe|teach)\b',
    ).hasMatch(text)) {
      return true;
    }
    return RegExp(r'^(?:什么是|如何|怎么|为什么|怎样|告诉我怎么|解释如何|教我怎么)').hasMatch(text) ||
        RegExp(
          r'(?:要|需要|应该|可以|能|会|得).*(?:什么|多久|多长|怎么|如何|哪些|多少)[?？]?$',
        ).hasMatch(text) ||
        RegExp(
          r'(?:是什么|有什么|有哪些|是多少|有多少|多久|多长|怎么做|如何做|为什么|哪个|哪些)[?？]?$',
        ).hasMatch(text) ||
        RegExp(r'(?:是|有|需不需要|可不可以|能不能|会不会).*(?:吗|么|呢)[?？]?$').hasMatch(text);
  }

  static bool _matchesEnglishCommand(String text, String verbPattern) => RegExp(
    '^(?:(?:please|kindly)\\s+)?$verbPattern\\b|'
    '^(?:can|could|would|will)\\s+you\\s+(?:please\\s+)?$verbPattern\\b',
  ).hasMatch(text);

  static bool _matchesChineseCommand(String text, String verbPattern) => RegExp(
    '^(?:(?:请|麻烦)(?:你)?(?:帮我|给我|替我)?|'
    '(?:可以|能不能)(?:请你)?(?:帮我|给我|替我)?|'
    '(?:帮我|给我|替我))?$verbPattern|'
    '^(?:把|将|在)(?:这个|当前)?(?:页面|界面|小程序).{0,12}$verbPattern',
  ).hasMatch(text);
}

/// One-turn, one-shot authority for one non-creation FreeformSurface method.
///
/// Mutating methods are bound to the visible Surface id. `showSurface` and
/// `reopenSurface` are deliberately absent: the former must use
/// `surface.show`, while the latter has a legacy project-body fallback that
/// can create content and therefore remains unavailable to model actions.
final class SurfaceInteractionGrant {
  SurfaceInteractionGrant._({
    required ExecutableHostGrant executableHostGrant,
    required AgentSkill? surfaceSkill,
    required String? proofTool,
    required String? agentId,
    required String? appletScopeKey,
    required SurfaceInteractionRequest? request,
    required _SurfaceInteractionCheckpoint? checkpoint,
    bool consumed = false,
  }) : _executableHostGrant = executableHostGrant,
       _surfaceSkill = surfaceSkill,
       _proofTool = proofTool,
       _agentId = agentId,
       _appletScopeKey = appletScopeKey,
       _request = request,
       _checkpoint = checkpoint,
       _consumed = consumed;

  static SurfaceInteractionGrant get none => SurfaceInteractionGrant._(
    executableHostGrant: ExecutableHostGrant.none,
    surfaceSkill: null,
    proofTool: null,
    agentId: null,
    appletScopeKey: null,
    request: null,
    checkpoint: null,
    consumed: true,
  );

  final ExecutableHostGrant _executableHostGrant;
  final AgentSkill? _surfaceSkill;
  final String? _proofTool;
  final String? _agentId;
  final String? _appletScopeKey;
  final SurfaceInteractionRequest? _request;
  final _SurfaceInteractionCheckpoint? _checkpoint;
  bool _consumed;

  static SurfaceInteractionGrant issue({
    required ExecutableHostGrant executableHostGrant,
    required String agentId,
    required String appletScopeKey,
    required SurfaceInteractionRequest request,
    required SurfaceRuntime? surfaceRuntime,
  }) {
    final normalizedAgentId = agentId.trim();
    final normalizedScopeKey = appletScopeKey.trim();
    if (normalizedAgentId.isEmpty ||
        normalizedScopeKey.isEmpty ||
        request.targetSurfaceId.trim().isEmpty ||
        surfaceRuntime == null ||
        surfaceRuntime.isVisible.value != true ||
        surfaceRuntime.activeSurfaceId != request.targetSurfaceId ||
        surfaceRuntime.activeProject.value?.id != request.targetSurfaceId ||
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
    if (surfaceSkill == null ||
        !surfaceSkill.methods.containsKey(request.methodName)) {
      return none;
    }
    final proofTool = SkillManager.nativeToolName(
      surfaceSkill,
      request.methodName,
    );
    final binding = executableHostGrant.authorize(
      agentId: normalizedAgentId,
      tool: proofTool,
    );
    if (binding == null ||
        !identical(binding.skill, surfaceSkill) ||
        binding.method != request.methodName) {
      return none;
    }
    return SurfaceInteractionGrant._(
      executableHostGrant: executableHostGrant,
      surfaceSkill: surfaceSkill,
      proofTool: proofTool,
      agentId: normalizedAgentId,
      appletScopeKey: normalizedScopeKey,
      request: request,
      checkpoint: _SurfaceInteractionCheckpoint(
        runtime: surfaceRuntime,
        targetSurfaceId: request.targetSurfaceId,
        expectedSession: surfaceRuntime.activeSession,
        hostGrantIsCurrent: () => executableHostGrant.isCurrent,
      ),
    );
  }

  bool get authorityIsCurrent =>
      _surfaceSkill != null &&
      _proofTool != null &&
      _agentId != null &&
      _appletScopeKey != null &&
      _request != null &&
      _checkpoint?.isCurrent == true &&
      _executableHostGrant.isCurrent;

  bool get isCurrent => !_consumed && authorityIsCurrent;

  bool tryConsume({
    required String agentId,
    required String appletScopeKey,
    required String method,
    required Map<String, Object?> arguments,
    required AgentSkill registeredSurfaceSkill,
  }) {
    final request = _request;
    final skill = _surfaceSkill;
    final proofTool = _proofTool;
    if (!isCurrent ||
        request == null ||
        skill == null ||
        proofTool == null ||
        agentId.trim() != _agentId ||
        appletScopeKey.trim() != _appletScopeKey ||
        method != request.methodName ||
        !identical(registeredSurfaceSkill, skill)) {
      return false;
    }
    if (!arguments.containsKey('surfaceId')) return false;
    final aliases = <String>[
      arguments['surfaceId'].toString().trim(),
      if (arguments.containsKey('id')) arguments['id'].toString().trim(),
    ];
    if (aliases.any(
      (target) => target.isEmpty || target != request.targetSurfaceId,
    )) {
      return false;
    }
    final binding = _executableHostGrant.authorize(
      agentId: agentId.trim(),
      tool: proofTool,
    );
    if (binding == null ||
        !identical(binding.skill, skill) ||
        binding.method != method) {
      return false;
    }
    _consumed = true;
    return true;
  }

  Future<T> runGuarded<T>(FutureOr<T> Function() operation) async {
    final checkpoint = _checkpoint;
    if (!_consumed || !authorityIsCurrent) {
      throw const SurfaceNotGrantedException();
    }
    if (checkpoint == null) return await operation();
    return runZoned(
      () async {
        checkpoint.requireCurrent();
        return await operation();
      },
      zoneValues: <Object, Object>{
        SurfaceInteractionExecutionCheckpoint._zoneKey: checkpoint,
      },
    );
  }
}

/// Runtime checkpoint used by the real Surface handler while an authorized
/// edit or revert crosses asynchronous persistence boundaries.
final class SurfaceInteractionExecutionCheckpoint {
  const SurfaceInteractionExecutionCheckpoint._();

  static final Object _zoneKey = Object();

  static void requireCurrentIfPresent() {
    final checkpoint = Zone.current[_zoneKey];
    if (checkpoint is _SurfaceInteractionCheckpoint) {
      checkpoint.requireCurrent();
    }
  }

  static void acceptHostTransitionIfPresent({
    required SurfaceRuntime runtime,
    required int previousSession,
    required String surfaceId,
  }) {
    final checkpoint = Zone.current[_zoneKey];
    if (checkpoint is _SurfaceInteractionCheckpoint) {
      checkpoint.acceptHostTransition(
        runtime: runtime,
        previousSession: previousSession,
        surfaceId: surfaceId,
      );
    }
  }
}

final class _SurfaceInteractionCheckpoint {
  _SurfaceInteractionCheckpoint({
    required this.runtime,
    required this.targetSurfaceId,
    required int expectedSession,
    required this.hostGrantIsCurrent,
  }) : _expectedSession = expectedSession;

  final SurfaceRuntime runtime;
  final String targetSurfaceId;
  final bool Function() hostGrantIsCurrent;
  int _expectedSession;

  bool get isCurrent =>
      hostGrantIsCurrent() &&
      runtime.isVisible.value &&
      runtime.activeSession == _expectedSession &&
      runtime.activeSurfaceId == targetSurfaceId &&
      runtime.activeProject.value?.id == targetSurfaceId;

  void requireCurrent() {
    if (!isCurrent) throw const SurfaceNotGrantedException();
  }

  void acceptHostTransition({
    required SurfaceRuntime runtime,
    required int previousSession,
    required String surfaceId,
  }) {
    if (!identical(runtime, this.runtime) ||
        previousSession != _expectedSession ||
        runtime.activeSession != previousSession + 1 ||
        surfaceId != targetSurfaceId ||
        runtime.activeSurfaceId != targetSurfaceId ||
        runtime.activeProject.value?.id != targetSurfaceId ||
        !runtime.isVisible.value) {
      throw const SurfaceNotGrantedException();
    }
    _expectedSession = runtime.activeSession;
  }
}
