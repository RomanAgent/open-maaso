import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';

/// Projects installed declarative Skills into a strictly read-only prompt
/// appendix. These cards are behavioral guidance only; they never register a
/// host tool, action, or executable handler.
class InstalledSkillPromptProvider {
  InstalledSkillPromptProvider({required InstalledSkillRegistry registry})
    : _registry = registry;

  final InstalledSkillRegistry _registry;

  Future<String> promptForAgent(String agentId, {AppLocale? locale}) async {
    final cards = await _registry.installedForAgent(agentId);
    if (cards.isEmpty) return '';
    final resolvedLocale = locale == null || locale == AppLocale.system
        ? AgentPromptCatalog.currentLocale
        : locale;
    final skillLines = StringBuffer();
    for (final card in cards) {
      final skill = card.skill;
      if (skill.isRetiredOfficialSkill || skill.hasRetiredWorldPermissions)
        continue;
      if (skill.requiresLocalizedPromptContent &&
          skill.contentLocale != resolvedLocale.code) {
        continue;
      }
      final instruction = _bounded(skill.instruction, 480);
      if (instruction.isEmpty) continue;
      skillLines.writeln(
        '- ${skill.title} [${skill.category.wireValue}, ${card.mastery.wireValue}]: $instruction',
      );
      if (skill.examples.isNotEmpty) {
        skillLines.writeln(
          '  ${AgentPromptCatalog.text('skill.community.example', locale: resolvedLocale, params: {'example': _bounded(skill.examples.first, 240)})}',
        );
      }
    }
    if (skillLines.isEmpty) return '';

    return (StringBuffer()
          ..writeln(
            AgentPromptCatalog.text(
              'skill.community.header',
              locale: resolvedLocale,
            ),
          )
          ..writeln(
            AgentPromptCatalog.text(
              'skill.community.readonly_rule',
              locale: resolvedLocale,
            ),
          )
          ..write(skillLines))
        .toString()
        .trim();
  }
}

String _bounded(String value, int maxLength) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (normalized.length <= maxLength) return normalized;
  return normalized.substring(0, maxLength).trimRight();
}
