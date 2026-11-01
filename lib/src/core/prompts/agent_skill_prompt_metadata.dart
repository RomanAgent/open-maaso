import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';

/// Localizes only host-owned, model-visible Skill metadata.
///
/// Stable tool names, method names, enum values, JSON keys, and third-party
/// author content remain unchanged. Every built-in natural-language field is
/// required to exist in both prompt bundles, so a missing translation cannot
/// silently produce a mixed-language prompt.
class AgentSkillPromptMetadata {
  const AgentSkillPromptMetadata._();

  static const Set<String> builtInSkillNames = <String>{
    'AlertUser',
    'AppControl',
    'AppInvocation',
    'ProjectControl',
    'AppNavigate',
    'AppletDiscovery',
    'AvatarCamera',
    'BehaviorConfig',
    'BleYoturetoys',
    'Bluetooth',
    'CompanionActivity',
    'DeviceHandoff',
    'FaceControl',
    'FreeformSurface',
    'Http',
    'LogEpisode',
    'LogMilestone',
    'MemoryControl',
    'ScheduledTask',
    'SetMaster',
    'SetSoul',
    'SetWorld',
    'ShowCard',
    'Todo',
    'WebSearch',
  };

  static String description(AgentSkill skill, {AppLocale? locale}) {
    if (!builtInSkillNames.contains(skill.skillName)) {
      return skill.description;
    }
    return AgentPromptCatalog.text(
      'skill.${skill.skillName}.description',
      locale: locale,
    );
  }

  static String methodDescription(
    AgentSkill skill,
    String method, {
    AppLocale? locale,
  }) {
    if (!builtInSkillNames.contains(skill.skillName)) {
      final authored = skill.nativeMethodDescriptions[method];
      if (authored != null) return authored;
      final description = skill.description;
      return description.isEmpty ? '[$method]' : '$description\n[$method]';
    }
    return AgentPromptCatalog.text(
      'skill.${skill.skillName}.method.$method',
      locale: locale,
    );
  }

  static Map<String, dynamic> schema(
    AgentSkill skill,
    String method,
    Map<String, dynamic> source, {
    AppLocale? locale,
  }) => _node(skill, method, source, const <String>[], locale: locale);

  static Map<String, dynamic> _node(
    AgentSkill skill,
    String method,
    Map<String, dynamic> source,
    List<String> path, {
    AppLocale? locale,
  }) {
    final copy = <String, dynamic>{};
    for (final entry in source.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key == 'description' && value is String) {
        if (!builtInSkillNames.contains(skill.skillName)) {
          copy[key] = value;
        } else {
          copy[key] = AgentPromptCatalog.text(
            'skill.${skill.skillName}.schema.$method.${path.join('.')}',
            locale: locale,
          );
        }
        continue;
      }
      if (key == 'properties' && value is Map) {
        copy[key] = <String, dynamic>{
          for (final property in value.entries)
            '${property.key}': property.value is Map
                ? _node(
                    skill,
                    method,
                    Map<String, dynamic>.from(property.value as Map),
                    <String>[...path, '${property.key}'],
                    locale: locale,
                  )
                : property.value,
        };
        continue;
      }
      if ((key == 'items' || key == 'additionalProperties') && value is Map) {
        copy[key] = _node(
          skill,
          method,
          Map<String, dynamic>.from(value),
          path,
          locale: locale,
        );
        continue;
      }
      if (value is Map) {
        copy[key] = _node(
          skill,
          method,
          Map<String, dynamic>.from(value),
          path,
          locale: locale,
        );
      } else if (value is List) {
        copy[key] = List<dynamic>.from(value);
      } else {
        copy[key] = value;
      }
    }
    return copy;
  }
}
