import 'dart:collection';

/// Immutable metadata used by the local Skill Router.
///
/// This deliberately contains no handler and performs no I/O. A descriptor may
/// represent a built-in, installed, learned, or page-scoped skill without
/// loading the skill implementation into the turn prompt.
class SkillDescriptor {
  factory SkillDescriptor({
    required String id,
    required String summary,
    Iterable<String> terms = const <String>[],
    Iterable<String> positiveExamples = const <String>[],
    Iterable<String> negativeTerms = const <String>[],
    Iterable<String> negativeExamples = const <String>[],
    Iterable<String> pageScopes = const <String>[],
    Iterable<String> professions = const <String>[],
    int? promptCost,
  }) {
    final normalizedId = id.trim();
    if (normalizedId.isEmpty) {
      throw ArgumentError.value(id, 'id', 'must not be empty');
    }
    final normalizedSummary = summary.trim();
    final normalizedTerms = _normalizedValues(terms);
    final normalizedPositiveExamples = _normalizedValues(positiveExamples);
    final normalizedNegativeTerms = _normalizedValues(negativeTerms);
    final normalizedNegativeExamples = _normalizedValues(negativeExamples);
    final normalizedPageScopes = _normalizedValues(pageScopes);
    final normalizedProfessions = _normalizedValues(professions);
    final termTokens = <String>{
      for (final term in normalizedTerms) ...SkillLexicalText.tokens(term),
    };
    final summaryTokens = SkillLexicalText.tokens(normalizedSummary);
    final resolvedPromptCost =
        promptCost ??
        _defaultPromptCost(
          normalizedSummary,
          normalizedTerms,
          normalizedPositiveExamples,
        );
    if (resolvedPromptCost <= 0) {
      throw ArgumentError.value(
        resolvedPromptCost,
        'promptCost',
        'must be greater than zero',
      );
    }

    final indexLexemes = <String>{
      ...SkillLexicalText.tokens(normalizedId),
      ...summaryTokens,
      ...termTokens,
      for (final value in normalizedPositiveExamples)
        ...SkillLexicalText.tokens(value),
    }.toList()..sort();

    return SkillDescriptor._(
      id: normalizedId,
      summary: normalizedSummary,
      terms: normalizedTerms,
      positiveExamples: normalizedPositiveExamples,
      negativeTerms: normalizedNegativeTerms,
      negativeExamples: normalizedNegativeExamples,
      pageScopes: normalizedPageScopes,
      professions: normalizedProfessions,
      promptCost: resolvedPromptCost,
      indexLexemes: List.unmodifiable(indexLexemes),
      termTokens: Set.unmodifiable(termTokens),
      summaryTokens: summaryTokens,
    );
  }

  const SkillDescriptor._({
    required this.id,
    required this.summary,
    required this.terms,
    required this.positiveExamples,
    required this.negativeTerms,
    required this.negativeExamples,
    required this.pageScopes,
    required this.professions,
    required this.promptCost,
    required List<String> indexLexemes,
    required this.termTokens,
    required this.summaryTokens,
  }) : _indexLexemes = indexLexemes;

  final String id;
  final String summary;
  final List<String> terms;
  final List<String> positiveExamples;
  final List<String> negativeTerms;
  final List<String> negativeExamples;

  /// Stable page-scope identifiers, not localized page titles.
  final List<String> pageScopes;

  /// Profession identifiers used only as a weak ranking prior.
  final List<String> professions;

  /// Estimated serialized prompt cost. Until a prompt builder is connected,
  /// callers may override this with their schema/description character cost.
  final int promptCost;

  final List<String> _indexLexemes;
  final Set<String> termTokens;
  final Set<String> summaryTokens;

  String get normalizedId => SkillLexicalText.normalize(id);

  List<String> get indexLexemes => _indexLexemes;

  static List<String> _normalizedValues(Iterable<String> values) {
    final normalized = SplayTreeSet<String>();
    for (final value in values) {
      final item = SkillLexicalText.normalize(value);
      if (item.isNotEmpty) normalized.add(item);
    }
    return List.unmodifiable(normalized);
  }

  static int _defaultPromptCost(
    String summary,
    Iterable<String> terms,
    Iterable<String> positiveExamples,
  ) {
    var cost = 64 + summary.length;
    for (final term in terms) {
      cost += term.length;
    }
    for (final example in positiveExamples) {
      cost += example.length;
    }
    return cost;
  }
}

/// Shared deterministic lexical normalization for indexing and scoring.
class SkillLexicalText {
  const SkillLexicalText._();

  static final RegExp _segments = RegExp(
    r'[a-z0-9]+|[\u3400-\u4dbf\u4e00-\u9fff]+',
  );
  static final RegExp _cjk = RegExp(r'[\u3400-\u4dbf\u4e00-\u9fff]');
  static const _stopWords = <String>{
    'a',
    'an',
    'and',
    'are',
    'as',
    'at',
    'be',
    'been',
    'but',
    'by',
    'can',
    'for',
    'from',
    'has',
    'have',
    'how',
    'i',
    'if',
    'in',
    'into',
    'is',
    'it',
    'its',
    'me',
    'my',
    'of',
    'on',
    'only',
    'or',
    'our',
    'that',
    'the',
    'their',
    'them',
    'there',
    'these',
    'they',
    'this',
    'those',
    'to',
    'use',
    'was',
    'we',
    'what',
    'when',
    'where',
    'which',
    'who',
    'will',
    'with',
    'would',
    'you',
    'your',
  };

  static String normalize(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\u3400-\u4dbf\u4e00-\u9fff]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();

  /// Emits Latin words plus 2-4 character CJK n-grams. The n-grams let a
  /// descriptor term such as “五子棋” match a longer unsegmented Chinese turn.
  static Set<String> tokens(String value) {
    final normalized = normalize(value);
    if (normalized.isEmpty) return const <String>{};
    final out = SplayTreeSet<String>();
    for (final match in _segments.allMatches(normalized)) {
      final segment = match.group(0)!;
      if (!_cjk.hasMatch(segment)) {
        if (!_stopWords.contains(segment)) out.add(segment);
        continue;
      }
      final runes = segment.runes.toList(growable: false);
      if (runes.length == 1) {
        out.add(segment);
        continue;
      }
      if (runes.length <= 8) out.add(segment);
      final maxN = runes.length < 4 ? runes.length : 4;
      for (var n = 2; n <= maxN; n++) {
        for (var start = 0; start <= runes.length - n; start++) {
          out.add(String.fromCharCodes(runes.sublist(start, start + n)));
        }
      }
    }
    return Set.unmodifiable(out);
  }

  static bool containsPhrase(String normalizedText, String normalizedPhrase) {
    if (normalizedText.isEmpty || normalizedPhrase.isEmpty) return false;
    if (_cjk.hasMatch(normalizedPhrase)) {
      return normalizedText
          .replaceAll(' ', '')
          .contains(normalizedPhrase.replaceAll(' ', ''));
    }
    return ' $normalizedText '.contains(' $normalizedPhrase ');
  }
}
