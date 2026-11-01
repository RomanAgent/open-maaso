/// Shared, deterministic language guard for creation requests.
///
/// Callers keep their own positive intent rules, while this fail-closed guard
/// prevents a negated creation verb from being treated as authorization.
class CreationIntentLanguage {
  const CreationIntentLanguage._();

  static const _chineseCreationVerbs = <String>[
    '做一个',
    '写一个',
    '做个',
    '写个',
    '生成',
    '创建',
    '制作',
    '开发',
    '做',
    '写',
  ];

  static const _englishCreationVerbs = <String>[
    'generate',
    'create',
    'develop',
    'build',
    'make',
    'write',
  ];

  static bool isNegatedCreation(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return false;

    final compact = normalized.replaceAll(
      RegExp(r'[\s，。！？、；：,.!?;:\-—~～]'),
      '',
    );
    final chineseVerbPattern = _chineseCreationVerbs
        .map(RegExp.escape)
        .join('|');
    final startsWithAbilityQuestion = RegExp(
      '^能不能(?:请你)?(?:帮我|给我|替我|帮忙)?(?:$chineseVerbPattern)',
    ).hasMatch(compact);
    final chineseNegationInput = startsWithAbilityQuestion
        ? compact.substring('能不能'.length)
        : compact;
    if (RegExp(
      '(?:不要|不用|不需要|无需|别|不想|不能|避免)'
      '(?:再|给我|帮我|替我|帮忙|让你|请你){0,3}'
      '(?:$chineseVerbPattern)',
    ).hasMatch(chineseNegationInput)) {
      return true;
    }

    final englishVerbPattern = _englishCreationVerbs
        .map(RegExp.escape)
        .join('|');
    return RegExp(
      "\\b(?:don['’]?t|do\\s+not|never|not)\\s+"
      '(?:[a-z]+\\s+){0,4}(?:$englishVerbPattern)\\b',
    ).hasMatch(normalized);
  }

  /// Whether the request explicitly rejects an unavoidable side effect of
  /// the current creation pipeline.
  ///
  /// Generated Applets and Surfaces are both persisted and presented. Until
  /// an ephemeral preview path exists, a request that rejects either effect
  /// cannot safely authorize creation.
  static bool isNegatedRequiredSideEffect(String text) {
    final normalized = text
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (normalized.isEmpty) return false;

    final compact = normalized.replaceAll(RegExp(r'\s+'), '');
    if (RegExp(
      r'(?:不要|不用|无需|别|先别|暂不)(?:先|再|帮我|给我|请你){0,3}(?:保存|存储|持久化|落盘|应用|提交)',
    ).hasMatch(compact)) {
      return true;
    }
    if (RegExp(
      r'(?:不要|不用|无需|别|先别|暂不)(?:先|再|帮我|给我|请你){0,3}(?:重新)?(?:打开|展示|显示|弹出|呈现)',
    ).hasMatch(compact)) {
      return true;
    }
    return RegExp(
      r"\b(?:don['’]?t|do\s+not|never)\s+(?:\w+\s+){0,3}(?:save|persist|store|apply|commit|show|open|reopen|display|present)\b|\bwithout\s+(?:saving|persisting|storing|applying|committing|showing|opening|reopening|displaying|presenting)\b",
    ).hasMatch(normalized);
  }
}
