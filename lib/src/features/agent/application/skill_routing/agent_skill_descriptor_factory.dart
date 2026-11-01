import 'dart:convert';

import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/prompts/agent_skill_prompt_metadata.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

/// Projects an executable host skill into compact router-only metadata.
///
/// The projection is built once with the runtime kernel. It never invokes a
/// handler and it does not put the complete catalog into a model prompt.
class AgentSkillDescriptorFactory {
  const AgentSkillDescriptorFactory._();

  static SkillDescriptor fromManifest(
    HostSkillRoutingManifest manifest, {
    AppLocale? locale,
  }) {
    final summaryKey = manifest.summaryPromptKey;
    final summary = summaryKey == null
        ? manifest.summary
        : AgentPromptCatalog.text(summaryKey, locale: locale);
    return SkillDescriptor(
      id: manifest.skillName,
      summary: summary,
      terms: <String>{
        manifest.skillName,
        ..._camelTerms(manifest.skillName),
        ..._routingMethods(manifest.methods),
        ...manifest.terms,
      },
      positiveExamples: manifest.positiveExamples,
      negativeTerms: manifest.negativeTerms,
      negativeExamples: manifest.negativeExamples,
      pageScopes: manifest.pageScopes,
      professions: manifest.professions,
      promptCost: manifest.promptCost,
    );
  }

  static SkillDescriptor fromSkill(AgentSkill skill, {AppLocale? locale}) {
    final description = AgentSkillPromptMetadata.description(
      skill,
      locale: locale,
    );
    final schemas = skill.modelStructuredActionPromptSchemas;
    final methods = skill.methods.keys.toList()..sort();
    final promptCost =
        96 +
        description.length +
        methods.fold<int>(0, (sum, method) {
          final schema = schemas.schemaFor(method);
          return sum +
              SkillManager.nativeToolName(skill, method).length +
              (schema == null ? 0 : jsonEncode(schema).length);
        });
    final metadata = _metadata[skill.skillName] ?? _SkillRoutingMetadata.empty;
    return SkillDescriptor(
      id: skill.skillName,
      summary: description,
      terms: <String>{
        skill.skillName,
        ..._camelTerms(skill.skillName),
        ..._routingMethods(methods),
        ...metadata.terms,
      },
      positiveExamples: metadata.positiveExamples,
      negativeTerms: metadata.negativeTerms,
      negativeExamples: metadata.negativeExamples,
      pageScopes: metadata.pageScopes,
      professions: metadata.professions,
      promptCost: promptCost.clamp(96, 4096),
    );
  }

  static Iterable<String> _camelTerms(String value) sync* {
    final separated = value.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (match) => '${match.group(1)} ${match.group(2)}',
    );
    yield separated;
    yield separated.replaceAll(' ', '_');
  }

  /// Transport verbs are executable names, not sufficient user intent. Their
  /// schemas stay available after a skill is selected by capability evidence.
  static Iterable<String> _routingMethods(Iterable<String> methods) =>
      methods.where(
        (method) => !const {
          'get',
          'post',
          'open',
          'search',
          'execute',
          'request',
          'cancel',
        }.contains(method.toLowerCase()),
      );

  static const Map<String, _SkillRoutingMetadata> _metadata =
      <String, _SkillRoutingMetadata>{
        'AppNavigate': _SkillRoutingMetadata(
          terms: <String>[
            '打开页面',
            '前往页面',
            '跳转',
            '导航',
            'go to page',
            'open page',
            'navigate',
          ],
          positiveExamples: <String>['打开设置', '带我去短视频页面'],
        ),
        'AppletDiscovery': _SkillRoutingMetadata(
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
          ],
          negativeTerms: <String>['生成小程序', '生成小游戏'],
        ),
        'DeviceHandoff': _SkillRoutingMetadata(
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
        ),
        'AvatarCamera': _SkillRoutingMetadata(
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
        'BehaviorConfig': _SkillRoutingMetadata(
          terms: <String>[
            '别打扰我',
            '停止主动联系',
            '恢复主动联系',
            '在我的Agent中恢复主动联系',
            'do not disturb',
            'stop proactive contact',
            'resume proactive contact',
            'resume proactive contact in my agent',
          ],
        ),
        'FreeformSurface': _SkillRoutingMetadata(
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
          ],
          positiveExamples: <String>['帮我生成一个五子棋小游戏'],
          negativeTerms: <String>['不要生成', '不用生成', '只聊天'],
          negativeExamples: <String>['我只想聊天，不要做小程序'],
          pageScopes: <String>['home', 'widgets_hub'],
        ),
        'WebSearch': _SkillRoutingMetadata(
          terms: <String>[
            '联网搜索',
            '搜索网页',
            '查最新',
            '新闻',
            '实时信息',
            'search web',
            'latest news',
          ],
          negativeTerms: <String>['不要联网', '别联网', '不用搜索'],
          professions: <String>['记者', 'researcher', 'journalist'],
        ),
        'ScheduledTask': _SkillRoutingMetadata(
          terms: <String>['提醒我', '定时任务', '闹钟', 'remind me', 'schedule'],
        ),
        'Todo': _SkillRoutingMetadata(
          terms: <String>['待办', '任务清单', '步骤', 'todo', 'checklist'],
        ),
        'BleYoturetoys': _SkillRoutingMetadata(
          terms: <String>['投影仪', '投图', '投影照片', 'projector'],
          pageScopes: <String>['projector'],
        ),
        'Bluetooth': _SkillRoutingMetadata(
          terms: <String>['蓝牙', '连接设备', 'bluetooth', 'connect device'],
          pageScopes: <String>['projector'],
        ),
        'SetSoul': _SkillRoutingMetadata(
          terms: <String>['设定你的名字', '设定人设', '你的职业', 'set your persona'],
        ),
        'SetMaster': _SkillRoutingMetadata(
          terms: <String>['记住我的信息', '主人资料', 'remember my profile'],
        ),
        'Http': _SkillRoutingMetadata(
          terms: <String>['http 请求', '调用接口', 'api request'],
          professions: <String>['程序员', 'developer'],
        ),
      };
}

class _SkillRoutingMetadata {
  const _SkillRoutingMetadata({
    this.terms = const <String>[],
    this.positiveExamples = const <String>[],
    this.negativeTerms = const <String>[],
    this.negativeExamples = const <String>[],
    this.pageScopes = const <String>[],
    this.professions = const <String>[],
  });

  static const empty = _SkillRoutingMetadata();

  final List<String> terms;
  final List<String> positiveExamples;
  final List<String> negativeTerms;
  final List<String> negativeExamples;
  final List<String> pageScopes;
  final List<String> professions;
}
