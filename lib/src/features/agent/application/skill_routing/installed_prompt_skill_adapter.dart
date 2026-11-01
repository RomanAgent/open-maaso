import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';

class InstalledPromptSkillAdapter {
  const InstalledPromptSkillAdapter();

  static String descriptorIdForSkill(MarketplaceSkill skill) {
    final key = skill.skillKey.trim();
    return 'marketplace:${_stableId(key.isEmpty ? 'version:${skill.skillVersionId}' : key)}';
  }

  PromptSkillSnapshot project(
    Iterable<InstalledSkillCard> cards, {
    required AppLocale locale,
  }) {
    final entries = <PromptSkillEntry>[];
    for (final card in cards) {
      final skill = card.skill;
      if (skill.isRetiredOfficialSkill || skill.hasRetiredWorldPermissions) {
        continue;
      }
      if (skill.requiresLocalizedPromptContent &&
          skill.contentLocale != locale.code) {
        continue;
      }
      final instruction = _bounded(skill.instruction, 480);
      if (instruction.isEmpty) continue;
      final rawSkillKey = skill.skillKey.trim();
      final skillKey = _bounded(rawSkillKey, 100);
      final title = _bounded(skill.title.isEmpty ? skillKey : skill.title, 120);
      final summary = _bounded(skill.summary, 240);
      final examples = _boundedValues(
        skill.examples,
        maxItems: 4,
        maxLength: 160,
      );
      final id = descriptorIdForSkill(skill);
      final fragment = StringBuffer()
        ..write(
          '- $title [${skill.category.wireValue}, ${card.mastery.wireValue}]: '
          '$instruction',
        );
      if (examples.isNotEmpty) {
        fragment
          ..writeln()
          ..write(
            '  ${AgentPromptCatalog.text('skill.community.example', locale: locale, params: <String, Object?>{'example': examples.first})}',
          );
      }
      final promptFragment = fragment.toString().trim();
      final revision = _revision(<Object?>[
        locale.code,
        skill.skillVersionId,
        skill.manifestDigest,
        card.mastery.wireValue,
        title,
        summary,
        instruction,
        ...examples,
      ]);
      entries.add(
        PromptSkillEntry(
          source: PromptSkillSource.marketplace,
          descriptor: SkillDescriptor(
            id: id,
            summary: summary.isEmpty ? instruction : summary,
            terms: <String>[title, summary, skillKey, skill.category.wireValue],
            positiveExamples: examples,
            promptCost:
                (promptFragment.length +
                        PromptSkillSnapshot.perEntryPromptOverhead)
                    .clamp(1, 4096)
                    .toInt(),
          ),
          promptFragment: promptFragment,
          contentRevision: revision,
        ),
      );
    }

    return PromptSkillSnapshot.fromEntries(entries, locale: locale);
  }
}

List<String> _boundedValues(
  Iterable<String> values, {
  required int maxItems,
  required int maxLength,
}) {
  final result = <String>[];
  final seen = <String>{};
  for (final value in values) {
    final bounded = _bounded(value, maxLength);
    if (bounded.isEmpty || !seen.add(bounded)) continue;
    result.add(bounded);
    if (result.length >= maxItems) break;
  }
  return List.unmodifiable(result);
}

String _bounded(String value, int maxLength) {
  final normalized = value.replaceAll(RegExp(r'\s+'), ' ').trim();
  final runes = normalized.runes;
  if (runes.length <= maxLength) return normalized;
  return String.fromCharCodes(runes.take(maxLength)).trimRight();
}

String _revision(Iterable<Object?> values) => sha256
    .convert(utf8.encode(values.map((value) => value ?? '').join('\u001f')))
    .toString();

String _stableId(String value) =>
    sha256.convert(utf8.encode(value)).toString().substring(0, 32);
