import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';

enum PromptSkillSource { marketplace, learned }

/// Statistics retain only a source and a hash of the stable routing identity.
/// Never store a title, instruction, raw publisher key or version here.
String? promptSkillUsageKey(String descriptorId) {
  final source = descriptorId.startsWith('marketplace:')
      ? 'marketplace'
      : descriptorId.startsWith('learned:')
      ? 'learned'
      : null;
  if (source == null) return null;
  return '$source:${sha256.convert(utf8.encode(descriptorId))}';
}

/// A router descriptor paired with the bounded text that becomes model-visible
/// only after the descriptor is selected for the current turn.
class PromptSkillEntry {
  const PromptSkillEntry({
    required this.source,
    required this.descriptor,
    required this.promptFragment,
    required this.contentRevision,
  });

  final PromptSkillSource source;
  final SkillDescriptor descriptor;
  final String promptFragment;
  final String contentRevision;
}

/// Immutable, atomically replaceable prompt-only Skill projection.
///
/// The full entry catalog stays local. [renderForGrant] and [signatureFor]
/// inspect only the bounded per-turn grant, so a cache lookup and prompt render
/// remain O(Top-K) even when this snapshot contains tens of thousands of
/// entries.
class PromptSkillSnapshot implements TurnSkillSnapshotToken {
  factory PromptSkillSnapshot.fromEntries(
    Iterable<PromptSkillEntry> entries, {
    AppLocale? locale,
  }) {
    final ordered = entries.toList(
      growable: false,
    )..sort((left, right) => left.descriptor.id.compareTo(right.descriptor.id));
    final byId = <String, PromptSkillEntry>{};
    final normalizedIds = <String>{};
    for (final entry in ordered) {
      final requiredPrefix = switch (entry.source) {
        PromptSkillSource.marketplace => 'marketplace:',
        PromptSkillSource.learned => 'learned:',
      };
      if (!entry.descriptor.id.startsWith(requiredPrefix)) {
        throw ArgumentError(
          'Prompt-only Skill id must start with $requiredPrefix',
        );
      }
      if (!normalizedIds.add(entry.descriptor.normalizedId)) {
        throw ArgumentError(
          'Duplicate prompt Skill id: ${entry.descriptor.id}',
        );
      }
      byId[entry.descriptor.id] = entry;
    }
    final revisionInput = StringBuffer(
      'locale=${locale?.name ?? 'agnostic'}\u0002',
    );
    for (final entry in ordered) {
      revisionInput
        ..write(entry.descriptor.id)
        ..write('\u0000')
        ..write(entry.contentRevision)
        ..write('\u0001');
    }
    final revision = sha256
        .convert(utf8.encode(revisionInput.toString()))
        .toString();
    return PromptSkillSnapshot._(
      entries: List.unmodifiable(ordered),
      entriesById: Map.unmodifiable(byId),
      descriptors: List.unmodifiable(ordered.map((entry) => entry.descriptor)),
      locale: locale,
      revision: revision,
    );
  }

  const PromptSkillSnapshot._({
    required this.entries,
    required Map<String, PromptSkillEntry> entriesById,
    required this.descriptors,
    required this.locale,
    required this.revision,
  }) : _entriesById = entriesById;

  static const int perEntryPromptOverhead = 384;

  static const empty = PromptSkillSnapshot._(
    entries: <PromptSkillEntry>[],
    entriesById: <String, PromptSkillEntry>{},
    descriptors: <SkillDescriptor>[],
    locale: null,
    revision: 'empty',
  );

  final List<PromptSkillEntry> entries;
  final Map<String, PromptSkillEntry> _entriesById;
  final List<SkillDescriptor> descriptors;
  final AppLocale? locale;
  final String revision;

  bool get isEmpty => entries.isEmpty;

  PromptSkillEntry? entryById(String id) => _entriesById[id];

  String signatureFor(Iterable<String> selectedIds) {
    final ids = selectedIds.toSet().toList()..sort();
    final selected = <String>[];
    for (final id in ids) {
      final entry = _entriesById[id];
      if (entry != null) selected.add('$id:${entry.contentRevision}');
    }
    return selected.join('|');
  }

  String renderForGrant(TurnSkillGrant grant, {required AppLocale locale}) {
    if (grant.isEmpty) return '';
    final marketplace = <PromptSkillEntry>[];
    final learned = <PromptSkillEntry>[];
    for (final descriptor in grant.descriptors) {
      final entry = _entriesById[descriptor.id];
      if (entry == null) continue;
      switch (entry.source) {
        case PromptSkillSource.marketplace:
          marketplace.add(entry);
          break;
        case PromptSkillSource.learned:
          learned.add(entry);
          break;
      }
    }
    if (marketplace.isEmpty && learned.isEmpty) return '';

    final sections = <String>[];
    if (marketplace.isNotEmpty) {
      sections.add(
        <String>[
          AgentPromptCatalog.text('skill.community.header', locale: locale),
          AgentPromptCatalog.text(
            'skill.community.readonly_rule',
            locale: locale,
          ),
          ...marketplace.map((entry) => entry.promptFragment),
        ].join('\n').trim(),
      );
    }
    if (learned.isNotEmpty) {
      sections.add(
        <String>[
          AgentPromptCatalog.text(
            'runtime.learned.header',
            locale: locale,
            params: <String, Object?>{'count': learned.length},
          ),
          AgentPromptCatalog.text('runtime.learned.usage', locale: locale),
          ...learned.map((entry) => entry.promptFragment),
        ].join('\n').trim(),
      );
    }
    return sections.where((section) => section.isNotEmpty).join('\n\n');
  }

  static PromptSkillSnapshot merge(Iterable<PromptSkillSnapshot> snapshots) {
    final sources = snapshots.toList(growable: false);
    final entries = <PromptSkillEntry>[];
    AppLocale? locale;
    for (final snapshot in sources) {
      final snapshotLocale = snapshot.locale;
      if (snapshotLocale != null) {
        if (locale != null && locale != snapshotLocale) {
          throw ArgumentError('Cannot merge prompt Skill locales');
        }
        locale = snapshotLocale;
      }
      entries.addAll(snapshot.entries);
    }
    if (entries.isEmpty && locale == null) return empty;
    return PromptSkillSnapshot.fromEntries(entries, locale: locale);
  }
}
