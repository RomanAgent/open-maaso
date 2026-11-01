import 'skills/app_invocation_skill.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/skills/alert_skill.dart';
import 'package:maaso/src/features/agent/data/skills/face_skill.dart';
import 'package:maaso/src/features/agent/data/skills/memory_skill.dart';

import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/skills/project_control_skill.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/agent/application/skills/applet_discovery_skill.dart';
import 'package:maaso/src/features/agent/application/skills/avatar_camera_skill.dart';
import 'package:maaso/src/features/agent/application/skills/device_handoff_skill.dart';
import 'package:maaso/src/features/agent/application/skills/behavior_skill.dart';
import 'package:maaso/src/features/agent/application/skills/ble_yoturetoys_skill.dart';
import 'package:maaso/src/features/agent/application/skills/bluetooth_skill.dart';
import 'package:maaso/src/features/agent/application/skills/freeform_surface_skill.dart';
import 'package:maaso/src/features/agent/application/skills/log_episode_skill.dart';
import 'package:maaso/src/features/agent/application/skills/log_milestone_skill.dart';
import 'package:maaso/src/features/agent/application/skills/scheduled_task_skill.dart';
import 'package:maaso/src/features/agent/application/skills/set_master_skill.dart';
import 'package:maaso/src/features/agent/application/skills/set_soul_skill.dart';
import 'package:maaso/src/features/agent/application/skills/set_world_skill.dart';
import 'package:maaso/src/features/agent/application/skills/companion_activity_skill.dart';
import 'package:maaso/src/features/agent/application/skills/http_skill.dart';
import 'package:maaso/src/features/agent/application/skills/show_card_skill.dart';
import 'package:maaso/src/features/agent/application/skills/todo_skill.dart';
import 'package:maaso/src/features/agent/application/skills/web_search_skill.dart';

/// Categories shown as filter pills in the Skills page.
enum SkillCategory { core, expression, social, knowledge, hardware, coming }

extension SkillCategoryX on SkillCategory {
  String get label {
    switch (this) {
      case SkillCategory.core:
        return 'skill_category.core';
      case SkillCategory.expression:
        return 'skill_category.expression';
      case SkillCategory.social:
        return 'skill_category.social';
      case SkillCategory.knowledge:
        return 'skill_category.knowledge';
      case SkillCategory.hardware:
        return 'skill_category.hardware';
      case SkillCategory.coming:
        return 'skill_category.coming';
    }
  }
}

/// Metadata + factory for a single skill listed in the catalog.
///
/// [factory] receives the owning agent's id so per-agent skills can tag their
/// events. Skills that don't care about agentId can just ignore it. [factory]
/// is null for marketplace placeholders (`isComingSoon = true`).
class SkillSpec implements LocalSkillManifestProvider {
  final String id;
  final String name;
  final String description;
  final IconData icon;
  final Color color;
  final SkillCategory category;

  /// Non-null marks this as a secondary ("二级") skill nested under the parent
  /// skill with this id (e.g. each BLE device skill sits under `bluetooth`).
  /// The Skills page indents these beneath their parent.
  final String? parentId;

  /// Core skills are always on — toggle is hidden / disabled in UI.
  final bool isCore;

  /// Marketplace placeholders that aren't actually installable yet.
  final bool isComingSoon;

  /// Returns null for placeholders.
  final AgentSkill Function(String agentId)? factory;

  /// Optional warning the UI surfaces under the toggle.
  final String? requirementHint;

  /// Small local-agent metadata. Null means the on-device agent must not see
  /// or invoke this skill; cloud AgentRuntime remains unchanged.
  @override
  final LocalSkillManifest? localManifest;

  /// Pure host routing metadata. Null means this entry cannot participate in
  /// lazy host activation; [factory] remains the legacy runtime contract.
  final HostSkillRoutingManifest? hostRouting;

  /// Runtime rollout visibility. A false or throwing predicate fails closed:
  /// the skill is omitted from prompts, local candidates, and Skills UI.
  final bool Function()? availability;

  /// Host capabilities required before this skill may be discovered or run.
  final Set<AppActionCapability> requiredPlatformCapabilities;

  const SkillSpec({
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.color,
    required this.category,
    this.parentId,
    this.isCore = false,
    this.isComingSoon = false,
    this.factory,
    this.requirementHint,
    this.localManifest,
    this.hostRouting,
    this.availability,
    this.requiredPlatformCapabilities = const <AppActionCapability>{},
  });

  bool get isAvailable {
    final predicate = availability;
    if (predicate == null) return true;
    try {
      return predicate();
    } on Object {
      return false;
    }
  }
}

bool _companionActivityAvailable() =>
    appServices.maybeFind<MaasoFeatureFlagService>()?.effectiveMode(
      MaasoFeatureFlag.companionActivity,
    ) ==
    FeatureRolloutMode.enforce;

HostSkillRoutingManifest _builtInHostRouting({
  required String skillName,
  required Iterable<String> methods,
  Iterable<String> nativeMethods = const <String>[],
  Iterable<String> terms = const <String>[],
  Iterable<String> positiveExamples = const <String>[],
  Iterable<String> negativeTerms = const <String>[],
  Iterable<String> negativeExamples = const <String>[],
  Iterable<String> pageScopes = const <String>[],
  Iterable<String> professions = const <String>[],
}) => HostSkillRoutingManifest(
  skillName: skillName,
  summary: skillName,
  summaryPromptKey: 'skill.$skillName.description',
  methods: methods,
  nativeMethods: nativeMethods,
  terms: terms,
  positiveExamples: positiveExamples,
  negativeTerms: negativeTerms,
  negativeExamples: negativeExamples,
  pageScopes: pageScopes,
  professions: professions,
);

/// All skills maaso knows about.
///
/// To add a new built-in skill: drop a [AgentSkill] in maaso,
/// then append one [SkillSpec] entry here.  No other code changes needed —
/// the Skills page + AgentRuntime read this list.
class SkillCatalog {
  static const _core = Color(0xFF007AFF);
  static const _blue = Color(0xFF007AFF);
  static const _graphite = Color(0xFF8E8E93);
  static const _indigo = Color(0xFF5856D6);
  static const _cyan = Color(0xFF5AC8FA);
  static const _pink = Color(0xFFFF2D55);

  static final List<SkillSpec> all = [
    SkillSpec(
      id: 'app_invocation',
      name: 'skill.app_invocation.name',
      description: 'skill.app_invocation.description',
      icon: Icons.apps_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => AppInvocationSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'AppInvocation',
        methods: ['describe', 'invoke', 'receipt', 'cancel'],
        nativeMethods: ['describe', 'invoke', 'receipt', 'cancel'],
        terms: [
          '使用所选小程序',
          '调用所选小游戏',
          'use selected app',
          'invoke selected game',
        ],
        positiveExamples: [
          '用我选择的小程序完成这个任务',
          'Use the app I selected for this task',
        ],
        negativeTerms: ['修改源码', 'publish app', 'edit source'],
      ),
    ),
    SkillSpec(
      id: 'project_control',
      name: 'skill.project_control.name',
      description: 'skill.project_control.description',
      icon: Icons.smart_toy_outlined,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => ProjectControlSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'ProjectControl',
        methods: ['describe', 'observe', 'act', 'receipt'],
        nativeMethods: ['describe', 'observe', 'act', 'receipt'],
        terms: ['操作小程序', '帮我使用小程序', 'operate this applet', 'project control'],
        positiveExamples: [
          '按我授权的目标操作当前小程序',
          'Use the current applet after I allow control',
        ],
        negativeTerms: ['不要操作', 'do not operate'],
      ),
    ),
    SkillSpec(
      id: 'app_control',
      name: 'skill.app_control.name',
      description: 'skill.app_control.description',
      icon: Icons.touch_app_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => AppControlSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'AppControl',
        methods: <String>['execute', 'listCapabilities'],
        nativeMethods: <String>['execute', 'listCapabilities'],
        terms: <String>[
          'app control',
          'control the app',
          'operate the app',
          'agent控制',
          '操作app',
          '自动填写',
          '自动输入',
          'app controls',
          'operate',
          '填写',
          '操作',
          '按钮',
        ],
        negativeTerms: <String>[
          '不用操作',
          '不要操作',
          '别操作',
          'do not operate',
          "don't operate",
        ],
        positiveExamples: <String>['打开设置页面'],
      ),
    ),
    SkillSpec(
      id: 'app_navigate',
      name: 'skill.app_navigate.name',
      description: 'skill.app_navigate.description',
      icon: Icons.explore_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => AppNavigateSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'AppNavigate',
        methods: <String>['openPage', 'listPages'],
        nativeMethods: <String>['openPage', 'listPages'],
        terms: <String>[
          '打开页面',
          '前往页面',
          '跳转',
          '导航',
          'go to page',
          'open page',
          'navigate',
          '带我去',
          '打开设置',
          '打开小游戏',
          '关系档案',
          '设置页',
          'take me to',
          'open a page',
          'open settings',
          'relationship profile',
        ],
        positiveExamples: <String>['打开设置', '带我去短视频页面'],
      ),
      // No localManifest: the on-device path uses the per-destination manifests
      // from navigationManifests(), wired in HomeController._tryLocalAgentRuntime.
    ),
    SkillSpec(
      id: 'set_soul',
      name: 'skill.set_soul.name',
      description: 'skill.set_soul.description',
      icon: Icons.person_pin_rounded,
      color: _indigo,
      category: SkillCategory.core,
      isCore: true,
      factory: (_) => SetSoulSkill(),
      hostRouting: _builtInHostRouting(
        skillName: 'SetSoul',
        methods: <String>['setSoul', 'getSoul'],
        terms: <String>['设定你的名字', '设定人设', '你的职业', 'set your persona'],
      ),
    ),
    SkillSpec(
      id: 'set_master',
      name: 'skill.set_master.name',
      description: 'skill.set_master.description',
      icon: Icons.person_outline_rounded,
      color: _indigo,
      category: SkillCategory.core,
      isCore: true,
      factory: (_) => SetMasterSkill(),
      hostRouting: _builtInHostRouting(
        skillName: 'SetMaster',
        methods: <String>['setMaster', 'getMaster'],
        terms: <String>['记住我的信息', '主人资料', 'remember my profile'],
      ),
    ),
    SkillSpec(
      id: 'set_world',
      name: 'skill.set_world.name',
      description: 'skill.set_world.description',
      icon: Icons.public_rounded,
      color: _indigo,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => SetWorldSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'SetWorld',
        methods: <String>['setWorld', 'getWorld'],
      ),
    ),
    SkillSpec(
      id: 'log_episode',
      name: 'skill.log_episode.name',
      description: 'skill.log_episode.description',
      icon: Icons.history_edu_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (_) => LogEpisodeSkill(),
      hostRouting: _builtInHostRouting(
        skillName: 'LogEpisode',
        methods: <String>['logEpisode'],
      ),
    ),
    SkillSpec(
      id: 'log_milestone',
      name: 'skill.log_milestone.name',
      description: 'skill.log_milestone.description',
      icon: Icons.favorite_rounded,
      color: _pink,
      category: SkillCategory.expression,
      isCore: true,
      factory: (_) => LogMilestoneSkill(),
      hostRouting: _builtInHostRouting(
        skillName: 'LogMilestone',
        methods: <String>['logMilestone', 'getRelationship'],
      ),
    ),
    SkillSpec(
      id: 'memory',
      name: 'skill.memory.name',
      description: 'skill.memory.description',
      icon: Icons.memory_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => MemorySkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'MemoryControl',
        methods: <String>['remember', 'forget'],
        terms: <String>[
          '记住',
          '别忘',
          '不要忘记',
          '存进记忆',
          '保存记忆',
          '忘掉',
          '忘记这条',
          'memory',
          'save my preference',
        ],
        negativeTerms: <String>[
          '别记住',
          '不要记住',
          '不用记',
          '不要保存',
          'do not remember',
          "don't remember",
          'do not save',
        ],
      ),
    ),
    SkillSpec(
      id: 'face',
      name: 'skill.face.name',
      description: 'skill.face.description',
      icon: Icons.face_retouching_natural_rounded,
      color: _blue,
      category: SkillCategory.expression,
      isCore: true,
      requiredPlatformCapabilities: const <AppActionCapability>{
        AppActionCapability.unityAvatar,
      },
      factory: (agentId) => FaceSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'FaceControl',
        methods: <String>['setEmotion'],
      ),
    ),
    SkillSpec(
      id: 'todo',
      name: 'skill.todo.name',
      description: 'skill.todo.description',
      icon: Icons.checklist_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => TodoSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'Todo',
        methods: <String>[
          'todo_add',
          'todo_addMany',
          'todo_complete',
          'todo_completeIndex',
          'todo_list',
          'todo_clear',
        ],
        terms: <String>[
          '待办',
          '任务清单',
          '步骤',
          '清单',
          'todo',
          'checklist',
          'to-do list',
          'to-do item',
        ],
      ),
      localManifest: const LocalSkillManifest(
        id: 'todo',
        skillName: 'Todo',
        method: 'todo_addMany',
        summary: 'Create a visible local checklist for multi-step work.',
        tags: ['todo', 'checklist', 'plan', 'task', '步骤', '计划', '待办'],
        risk: LocalSkillRisk.writeLocal,
        argsSchema: {
          'type': 'object',
          'properties': {
            'items': {
              'type': 'array',
              'items': {'type': 'string'},
              'minItems': 1,
            },
          },
          'required': ['items'],
          'additionalProperties': false,
        },
      ),
    ),
    SkillSpec(
      id: 'companion_activity',
      name: 'skill.companion_activity.name',
      description: 'skill.companion_activity.description',
      icon: Icons.emoji_events_rounded,
      color: _pink,
      category: SkillCategory.social,
      factory: (agentId) => CompanionActivitySkill(agentId: agentId),
      availability: _companionActivityAvailable,
      hostRouting: _builtInHostRouting(
        skillName: 'CompanionActivity',
        methods: <String>['activitySummary', 'activityBuildSurface'],
        nativeMethods: <String>['activitySummary', 'activityBuildSurface'],
        terms: <String>[
          '陪伴活动',
          '活动打卡',
          '任务积分',
          '连续完成',
          'companion activity',
          'activity streak',
        ],
        positiveExamples: <String>['查看今天的陪伴活动', '生成我的活动进度面板'],
      ),
      localManifest: const LocalSkillManifest(
        id: 'companion_activity_summary',
        skillName: 'CompanionActivity',
        method: 'activitySummary',
        summary: 'Read the current account-scoped companion activity summary.',
        tags: <String>['activity', 'streak', 'points', '陪伴活动', '打卡', '积分'],
        risk: LocalSkillRisk.read,
        argsSchema: <String, dynamic>{
          'type': 'object',
          'properties': <String, dynamic>{
            'asOf': <String, dynamic>{'type': 'string'},
          },
          'required': <String>['asOf'],
          'additionalProperties': false,
        },
      ),
    ),
    SkillSpec(
      id: 'behavior',
      name: 'skill.behavior.name',
      description: 'skill.behavior.description',
      icon: Icons.tune_rounded,
      color: _core,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => BehaviorSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'BehaviorConfig',
        methods: <String>[
          'setBehaviorParam',
          'getBehaviorParam',
          'getAllBehaviorParams',
          'setMultiStep',
          'setProactiveHardMuted',
          'resetBehaviorDefaults',
        ],
        terms: <String>[
          '别打扰我',
          '停止主动联系',
          '恢复主动联系',
          '在我的Agent中恢复主动联系',
          'do not disturb',
          'stop proactive contact',
          'resume proactive contact',
          'resume proactive contact in my agent',
          '主动',
          '勿扰',
          '行为设置',
          'behavior settings',
          'proactive messages',
        ],
      ),
    ),
    SkillSpec(
      id: 'device_handoff',
      name: 'skill.device_handoff.name',
      description: 'skill.device_handoff.description',
      icon: Icons.devices_rounded,
      color: _blue,
      category: SkillCategory.core,
      isCore: true,
      requiredPlatformCapabilities: const {AppActionCapability.unityAvatar},
      factory: (agentId) => DeviceHandoffSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'DeviceHandoff',
        methods: ['listDevices'],
        nativeMethods: ['listDevices'],
        terms: [
          '在线设备',
          '设备数量',
          '已连接的设备',
          '有哪些设备',
          'online devices',
          'connected devices',
          'device count',
          'list devices',
        ],
        positiveExamples: [
          '查看我的在线设备',
          '我的账号现在有几台设备在线',
          'List my online devices',
          'How many devices are online?',
        ],
        negativeTerms: ['连接蓝牙', '投影', 'connect bluetooth', 'projector'],
        pageScopes: ['home'],
      ),
    ),
    SkillSpec(
      id: 'avatar_camera',
      name: 'skill.avatar_camera.name',
      description: 'skill.avatar_camera.description',
      icon: Icons.portrait_rounded,
      color: _blue,
      category: SkillCategory.expression,
      isCore: true,
      requiredPlatformCapabilities: const <AppActionCapability>{
        AppActionCapability.unityAvatar,
      },
      factory: (agentId) => AvatarCameraSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'AvatarCamera',
        methods: <String>['setFraming'],
        nativeMethods: <String>['setFraming'],
        terms: <String>[
          '看看你的脸',
          '靠近一点',
          '镜头拉近',
          '上半身',
          '全身',
          '自动镜头',
          '恢复自动镜头',
          'show me your face',
          'close-up',
          'upper body',
          'full body',
          'automatic framing',
          'avatar framing',
          'zoom',
        ],
        positiveExamples: <String>[
          '让我看看你的脸',
          '镜头切到上半身',
          '我想看看你的全身',
          '恢复自动镜头',
          'Show me your face',
          'Show your upper body',
          'Show your full body',
          'Switch back to automatic framing',
        ],
        negativeTerms: <String>[
          '拍照',
          '录视频',
          '摄像头',
          'take a photo',
          'record video',
        ],
      ),
      localManifest: const LocalSkillManifest(
        id: 'avatar_camera',
        skillName: 'AvatarCamera',
        method: 'setFraming',
        summary:
            'Frame your avatar face, upper body, or full body when requested; '
            'auto restores automatic conversation framing.',
        tags: [
          'avatar',
          'framing',
          'face',
          'upper body',
          'full body',
          '自动镜头',
          '看看你的脸',
          '上半身',
          '全身',
        ],
        risk: LocalSkillRisk.writeLocal,
        argsSchema: AvatarCameraSkill.argumentsSchema,
      ),
    ),
    SkillSpec(
      id: 'show_card',
      name: 'skill.show_card.name',
      description: 'skill.show_card.description',
      icon: Icons.credit_card_rounded,
      color: _core,
      category: SkillCategory.expression,
      isCore: true,
      factory: (agentId) => ShowCardSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'ShowCard',
        methods: <String>['showSetupCard'],
        nativeMethods: <String>['showSetupCard'],
      ),
    ),
    SkillSpec(
      id: 'freeform_surface',
      name: 'skill.freeform_surface.name',
      description: 'skill.freeform_surface.description',
      icon: Icons.layers_rounded,
      color: _blue,
      category: SkillCategory.expression,
      isCore: true,
      requiredPlatformCapabilities: const <AppActionCapability>{
        AppActionCapability.embeddedSurface,
      },
      factory: (agentId) => FreeformSurfaceSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'FreeformSurface',
        methods: <String>[
          'showSurface',
          'editSurface',
          'listSurfaces',
          'reopenSurface',
          'revertSurface',
        ],
        terms: <String>[
          '生成界面',
          '生成卡片',
          '生成小程序',
          '生成小游戏',
          '五子棋',
          '可交互界面',
          'build applet',
          'generate game',
          'interactive surface',
          'create game',
          'build game',
          'edit game',
          '做个游戏',
        ],
        positiveExamples: <String>['帮我生成一个五子棋小游戏'],
        negativeTerms: <String>[
          '不要生成',
          '不用生成',
          '只聊天',
          'only want to chat',
          'do not generate',
          "don't generate",
          'do not create',
        ],
        negativeExamples: <String>['我只想聊天，不要做小程序'],
        pageScopes: <String>['home', 'widgets_hub'],
      ),
    ),
    SkillSpec(
      id: 'http',
      name: 'skill.http.name',
      description: 'skill.http.description',
      icon: Icons.cloud_download_rounded,
      color: _core,
      category: SkillCategory.expression,
      isCore: true,
      factory: (agentId) => HttpSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'Http',
        methods: <String>['get', 'post'],
        nativeMethods: <String>['get', 'post'],
        terms: <String>['http 请求', '调用接口', 'api request'],
        professions: <String>['程序员', 'developer'],
      ),
    ),
    SkillSpec(
      id: 'alert',
      name: 'skill.alert.name',
      description: 'skill.alert.description',
      icon: Icons.notifications_active_rounded,
      color: _pink,
      category: SkillCategory.expression,
      isCore: true,
      factory: (agentId) => AlertSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'AlertUser',
        methods: <String>['alertUser'],
      ),
    ),
    SkillSpec(
      id: 'web_search',
      name: 'skill.web_search.name',
      description: 'skill.web_search.description',
      icon: Icons.search_rounded,
      color: _blue,
      category: SkillCategory.knowledge,
      factory: (agentId) => WebSearchSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'WebSearch',
        methods: <String>['webSearch', 'imageSearch', 'readPage'],
        nativeMethods: <String>['webSearch', 'imageSearch', 'readPage'],
        terms: <String>[
          '联网搜索',
          '搜索网页',
          '查最新',
          '新闻',
          '实时信息',
          'search web',
          'latest news',
          '上网查',
          '查资料',
          'search the web',
          'look up',
          'news online',
          'with sources',
        ],
        negativeTerms: <String>['不要联网', '别联网', '不用搜索'],
        professions: <String>['记者', 'researcher', 'journalist'],
      ),
    ),
    SkillSpec(
      id: 'applet_discovery',
      name: 'skill.applet_discovery.name',
      description: 'skill.applet_discovery.description',
      icon: Icons.apps_rounded,
      color: _blue,
      category: SkillCategory.knowledge,
      isCore: true,
      factory: (agentId) => AppletDiscoverySkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'AppletDiscovery',
        methods: <String>['search', 'open', 'describeApplet', 'useApplet'],
        nativeMethods: <String>[
          'search',
          'open',
          'describeApplet',
          'useApplet',
        ],
        terms: <String>[
          '找小程序',
          '找小游戏',
          '推荐小游戏',
          '搜索小程序',
          '旅游小程序',
          '工具小程序',
          '打开小程序结果',
          'find applet',
          'find game',
          'travel applet',
          'utility applet',
          '旅游规划',
          '旅行规划',
          '行程规划',
          'plan a trip',
          'travel itinerary',
          '小工具',
          '现成',
          '小程序',
          'find an applet',
          'ready made',
          'applet',
        ],
        negativeTerms: <String>['生成小程序', '生成小游戏'],
      ),
    ),
    SkillSpec(
      id: 'scheduled_task',
      name: 'skill.scheduled_task.name',
      description: 'skill.scheduled_task.description',
      icon: Icons.alarm_rounded,
      color: _graphite,
      category: SkillCategory.core,
      isCore: true,
      factory: (agentId) => ScheduledTaskSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'ScheduledTask',
        methods: <String>['scheduleTask', 'listTasks', 'cancelTask'],
        terms: <String>[
          '提醒我',
          '提醒',
          '喊我',
          '定时任务',
          '闹钟',
          'remind me',
          'reminder',
          'schedule',
        ],
        negativeTerms: <String>[
          '不要设置提醒',
          '不用提醒',
          '别提醒',
          'do not set a reminder',
          "don't set a reminder",
        ],
      ),
      localManifest: const LocalSkillManifest(
        id: 'scheduled_task',
        skillName: 'ScheduledTask',
        method: 'scheduleTask',
        summary: 'Create a reminder or recurring scheduled task.',
        tags: ['remind', 'schedule', 'alarm', '提醒', '闹钟', '定时'],
        risk: LocalSkillRisk.sideEffect,
        argsSchema: {
          'type': 'object',
          'properties': {
            'when': {'type': 'string'},
            'prompt': {'type': 'string'},
            'repeat': {'type': 'string'},
          },
          'required': ['when', 'prompt'],
        },
      ),
    ),
    // —— Bluetooth (parent) + per-device sub-skills (二级) ——
    SkillSpec(
      id: 'bluetooth',
      name: 'skill.bluetooth.name',
      description: 'skill.bluetooth.description',
      icon: Icons.bluetooth_rounded,
      color: _cyan,
      category: SkillCategory.hardware,
      requiredPlatformCapabilities: const <AppActionCapability>{
        AppActionCapability.bluetooth,
      },
      factory: (agentId) => BluetoothSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'Bluetooth',
        methods: <String>[
          'bluetoothScan',
          'bluetoothConnect',
          'bluetoothDisconnect',
          'bluetoothStatus',
        ],
        nativeMethods: <String>[
          'bluetoothScan',
          'bluetoothConnect',
          'bluetoothDisconnect',
          'bluetoothStatus',
        ],
        terms: <String>['蓝牙', '连接设备', 'bluetooth', 'connect device'],
        pageScopes: <String>['projector'],
      ),
    ),
    SkillSpec(
      id: 'ble_yoturetoys_projector',
      parentId: 'bluetooth',
      name: 'skill.ble_yoturetoys.name',
      description: 'skill.ble_yoturetoys.description',
      icon: Icons.cast_rounded,
      color: _cyan,
      category: SkillCategory.hardware,
      requiredPlatformCapabilities: const <AppActionCapability>{
        AppActionCapability.bluetooth,
      },
      factory: (agentId) => BleYoturetoysSkill(agentId: agentId),
      hostRouting: _builtInHostRouting(
        skillName: 'BleYoturetoys',
        methods: <String>[
          'projectorTransferImage',
          'projectorSendGallery',
          'projectorSetVoice',
          'projectorStatus',
        ],
        nativeMethods: <String>[
          'projectorTransferImage',
          'projectorSendGallery',
          'projectorSetVoice',
          'projectorStatus',
        ],
        terms: <String>['投影仪', '投图', '投影照片', 'projector', 'project an image'],
        pageScopes: <String>['projector'],
      ),
      localManifest: const LocalSkillManifest(
        id: 'ble_yoturetoys_projector',
        skillName: 'BleYoturetoys',
        method: 'projectorTransferImage',
        summary:
            'Send a picture to the Yoturetoys AI Drawing Projector over Bluetooth.',
        tags: [
          '投影',
          'projector',
          '蓝牙',
          'bluetooth',
          '传图',
          'yoturetoys',
          '投影仪',
          '图库',
          '相册',
          '照片',
          'gallery',
          'photo',
        ],
        risk: LocalSkillRisk.sideEffect,
        argsSchema: {
          'type': 'object',
          'properties': {
            'image': {'type': 'string'},
            'quality': {'type': 'integer'},
          },
          'required': ['image'],
        },
      ),
    ),
  ];

  static SkillSpec? byId(String id) {
    for (final s in all) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Production skill requirements consumed by the unified snapshot resolver.
  static Map<String, Set<AppCapabilityKey>> get capabilityRequirements =>
      Map<String, Set<AppCapabilityKey>>.unmodifiable(
        <String, Set<AppCapabilityKey>>{
          for (final spec in all)
            if (spec.requiredPlatformCapabilities.isNotEmpty)
              spec.id: Set<AppCapabilityKey>.unmodifiable(<AppCapabilityKey>{
                for (final capability in spec.requiredPlatformCapabilities)
                  AppCapabilityKey.platformAction(capability),
              }),
        },
      );

  /// Runtime-visible catalog projection after fail-closed rollout predicates.
  static Iterable<SkillSpec> get available =>
      all.where((spec) => spec.isAvailable);

  /// IDs that are core (always on, can't be disabled).
  static Set<String> get coreIds =>
      all.where((s) => s.isCore).map((s) => s.id).toSet();

  /// Default enabled set for a fresh agent — all core + every non-coming
  /// optional skill enabled out of the box.
  static Set<String> get defaultEnabled =>
      available.where((s) => !s.isComingSoon).map((s) => s.id).toSet();

  /// Default preference set independent of a temporary rollout projection.
  /// Runtime registries still apply [available] before exposing or activating
  /// a host, but an off -> enforce transition does not lose the user's default.
  static Set<String> get defaultConfigured =>
      all.where((s) => !s.isComingSoon).map((s) => s.id).toSet();
}
