import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';

class SkillIndexLookup {
  const SkillIndexLookup({
    required this.normalizedQuery,
    required this.queryTokens,
    required this.candidates,
    required this.truncated,
  });

  final String normalizedQuery;
  final Set<String> queryTokens;
  final List<SkillDescriptor> candidates;
  final bool truncated;
}

/// Immutable local inverted index. Construction and lookup are deterministic:
/// descriptor order never changes a result, and equally rare postings are
/// visited in lexical-token order.
class SkillIndex {
  factory SkillIndex(Iterable<SkillDescriptor> descriptors) {
    final ordered = descriptors.toList()
      ..sort((a, b) {
        final normalized = a.normalizedId.compareTo(b.normalizedId);
        return normalized != 0 ? normalized : a.id.compareTo(b.id);
      });
    final ids = <String>{};
    for (final descriptor in ordered) {
      if (!ids.add(descriptor.normalizedId)) {
        throw ArgumentError('Duplicate skill descriptor id: ${descriptor.id}');
      }
    }

    final mutablePostings = <String, List<int>>{};
    for (var index = 0; index < ordered.length; index++) {
      for (final lexeme in ordered[index].indexLexemes) {
        (mutablePostings[lexeme] ??= <int>[]).add(index);
      }
    }
    return SkillIndex._(
      descriptors: List.unmodifiable(ordered),
      descriptorsById: Map<String, SkillDescriptor>.unmodifiable({
        for (final descriptor in ordered) descriptor.normalizedId: descriptor,
      }),
      postings: Map<String, List<int>>.unmodifiable({
        for (final entry in mutablePostings.entries)
          entry.key: List<int>.unmodifiable(entry.value),
      }),
    );
  }

  const SkillIndex._({
    required this.descriptors,
    required Map<String, SkillDescriptor> descriptorsById,
    required this.postings,
  }) : _descriptorsById = descriptorsById;

  final List<SkillDescriptor> descriptors;
  final Map<String, SkillDescriptor> _descriptorsById;
  final Map<String, List<int>> postings;

  SkillDescriptor? descriptorById(String id) =>
      _descriptorsById[SkillLexicalText.normalize(id)];

  SkillIndexLookup lookup(String query, {int maxCandidates = 256}) {
    if (maxCandidates <= 0) {
      throw ArgumentError.value(
        maxCandidates,
        'maxCandidates',
        'must be greater than zero',
      );
    }
    final normalized = SkillLexicalText.normalize(query);
    final queryTokens = SkillLexicalText.tokens(normalized);
    final postingEntries =
        <MapEntry<String, List<int>>>[
          for (final token in queryTokens)
            if (postings[token] case final matches?) MapEntry(token, matches),
        ]..sort((a, b) {
          final rarity = a.value.length.compareTo(b.value.length);
          return rarity != 0 ? rarity : a.key.compareTo(b.key);
        });

    final candidateIndexes = <int>{};
    var truncated = false;
    for (final entry in postingEntries) {
      for (final descriptorIndex in entry.value) {
        if (candidateIndexes.length >= maxCandidates) {
          truncated = true;
          break;
        }
        candidateIndexes.add(descriptorIndex);
      }
      if (candidateIndexes.length >= maxCandidates) break;
    }

    return SkillIndexLookup(
      normalizedQuery: normalized,
      queryTokens: Set.unmodifiable(queryTokens),
      candidates: List.unmodifiable([
        for (final index in candidateIndexes) descriptors[index],
      ]),
      truncated: truncated,
    );
  }
}
