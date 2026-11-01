import 'dart:collection';

/// Pure metadata for routing to one executable host Skill.
///
/// A manifest never owns a handler or factory, so a large built-in catalog can
/// be indexed without constructing any host Skill instances.
class HostSkillRoutingManifest {
  factory HostSkillRoutingManifest({
    required String skillName,
    required String summary,
    String? summaryPromptKey,
    Iterable<String> methods = const <String>[],
    Iterable<String> nativeMethods = const <String>[],
    Iterable<String> terms = const <String>[],
    Iterable<String> positiveExamples = const <String>[],
    Iterable<String> negativeTerms = const <String>[],
    Iterable<String> negativeExamples = const <String>[],
    Iterable<String> pageScopes = const <String>[],
    Iterable<String> professions = const <String>[],
    int? promptCost,
  }) {
    final normalizedSkillName = _requiredIdentifier(skillName, 'skillName');
    final normalizedSummary = summary.trim();
    final normalizedSummaryPromptKey = _optionalText(summaryPromptKey);
    if (normalizedSummary.isEmpty && normalizedSummaryPromptKey == null) {
      throw ArgumentError('summary or summaryPromptKey must be provided');
    }
    if (promptCost != null && promptCost <= 0) {
      throw ArgumentError.value(promptCost, 'promptCost', 'must be positive');
    }
    final normalizedMethods = _identifiers(methods, 'methods');
    final normalizedNativeMethods = _identifiers(
      nativeMethods,
      'nativeMethods',
    );
    final methodSet = normalizedMethods.toSet();
    for (final method in normalizedNativeMethods) {
      if (!methodSet.contains(method)) {
        throw ArgumentError.value(
          method,
          'nativeMethods',
          'must also be declared in methods',
        );
      }
    }
    return HostSkillRoutingManifest._(
      skillName: normalizedSkillName,
      summary: normalizedSummary,
      summaryPromptKey: normalizedSummaryPromptKey,
      methods: normalizedMethods,
      nativeMethods: normalizedNativeMethods,
      nativeToolNames: List<String>.unmodifiable(
        normalizedNativeMethods.map(
          (method) => nativeToolName(normalizedSkillName, method),
        ),
      ),
      terms: _values(terms),
      positiveExamples: _values(positiveExamples),
      negativeTerms: _values(negativeTerms),
      negativeExamples: _values(negativeExamples),
      pageScopes: _values(pageScopes),
      professions: _values(professions),
      promptCost: promptCost,
    );
  }

  const HostSkillRoutingManifest._({
    required this.skillName,
    required this.summary,
    required this.summaryPromptKey,
    required this.methods,
    required this.nativeMethods,
    required this.nativeToolNames,
    required this.terms,
    required this.positiveExamples,
    required this.negativeTerms,
    required this.negativeExamples,
    required this.pageScopes,
    required this.professions,
    required this.promptCost,
  });

  final String skillName;
  final String summary;
  final String? summaryPromptKey;
  final List<String> methods;
  final List<String> nativeMethods;
  final List<String> nativeToolNames;
  final List<String> terms;
  final List<String> positiveExamples;
  final List<String> negativeTerms;
  final List<String> negativeExamples;
  final List<String> pageScopes;
  final List<String> professions;
  final int? promptCost;

  /// Mirrors the existing host tool-name wire contract without loading a
  /// Skill. Activation revalidates the manifest against the real factory.
  static String nativeToolName(String skillName, String method) {
    final raw = 'skill_${skillName.trim()}_${method.trim()}';
    final sanitized = raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return sanitized.length > 64 ? sanitized.substring(0, 64) : sanitized;
  }

  static String _requiredIdentifier(String raw, String name) {
    final value = raw.trim();
    if (value.isEmpty || value.length > 128) {
      throw ArgumentError.value(raw, name, 'must contain 1-128 characters');
    }
    return value;
  }

  static List<String> _identifiers(Iterable<String> raw, String name) {
    final seen = <String>{};
    final values = <String>[];
    for (final item in raw) {
      final value = _requiredIdentifier(item, name);
      if (!seen.add(value)) {
        throw ArgumentError.value(item, name, 'contains a duplicate value');
      }
      values.add(value);
    }
    return List<String>.unmodifiable(values);
  }

  static List<String> _values(Iterable<String> raw) {
    final values = SplayTreeSet<String>();
    for (final item in raw) {
      final value = item.trim();
      if (value.isNotEmpty) values.add(value);
    }
    return List<String>.unmodifiable(values);
  }

  static String? _optionalText(String? raw) {
    final value = raw?.trim() ?? '';
    return value.isEmpty ? null : value;
  }
}
