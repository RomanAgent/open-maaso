import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/models/learned_skill.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';

class LearnedPromptSkillAdapter {
  const LearnedPromptSkillAdapter();

  PromptSkillSnapshot project(
    Iterable<LearnedSkill> skills, {
    required AppLocale locale,
  }) {
    final entries = <PromptSkillEntry>[];
    for (final skill in skills) {
      final sourceId = skill.id.trim();
      if (sourceId.isEmpty) continue;
      final displayId = _bounded(sourceId, 100);
      final name = _bounded(skill.name.isEmpty ? displayId : skill.name, 120);
      final summary = _bounded(skill.summary, 240);
      final triggers = _boundedValues(
        skill.triggers,
        maxItems: 8,
        maxLength: 80,
      );
      final effectiveSummary = summary.isEmpty
          ? AgentPromptCatalog.text(
              'runtime.learned.no_description',
              locale: locale,
            )
          : summary;
      final fragment = StringBuffer()
        ..writeln(
          AgentPromptCatalog.text(
            'runtime.learned.entry',
            locale: locale,
            params: <String, Object?>{
              'id': displayId,
              'name': name,
              'summary': effectiveSummary,
            },
          ),
        );
      if (triggers.isNotEmpty) {
        fragment.write(
          AgentPromptCatalog.text(
            'runtime.learned.triggers',
            locale: locale,
            params: <String, Object?>{'triggers': triggers.join(' / ')},
          ),
        );
      }
      final promptFragment = fragment.toString().trim();
      entries.add(
        PromptSkillEntry(
          source: PromptSkillSource.learned,
          descriptor: SkillDescriptor(
            id: 'learned:${_stableId(sourceId)}',
            summary: effectiveSummary,
            terms: <String>[displayId, name, ...triggers],
            positiveExamples: triggers,
            promptCost:
                (promptFragment.length +
                        PromptSkillSnapshot.perEntryPromptOverhead)
                    .clamp(1, 4096)
                    .toInt(),
          ),
          promptFragment: promptFragment,
          contentRevision: _revision(<Object?>[
            locale.code,
            sourceId,
            name,
            effectiveSummary,
            ...triggers,
          ]),
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
