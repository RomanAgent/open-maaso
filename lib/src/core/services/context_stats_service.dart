import 'package:maaso/src/core/foundation/app_framework.dart';

/// One snapshot of the LLM context window after a chat turn.
///
/// Estimated tokens use chars/3.5 as a rough middle ground between English
/// (~chars/4) and CJK (~chars/2).  Good enough for a usage bar; not meant
/// to match the model's tokenizer exactly.
class ContextSnapshot {
  final String? modelName;
  final int modelContextWindow; // total budget, e.g. 128_000
  final int systemPromptChars;
  final int userInputChars;
  final int responseChars;
  final int turnCount;
  final DateTime updatedAt;

  const ContextSnapshot({
    required this.modelName,
    required this.modelContextWindow,
    required this.systemPromptChars,
    required this.userInputChars,
    required this.responseChars,
    required this.turnCount,
    required this.updatedAt,
  });

  factory ContextSnapshot.empty() => ContextSnapshot(
    modelName: null,
    modelContextWindow: 128000,
    systemPromptChars: 0,
    userInputChars: 0,
    responseChars: 0,
    turnCount: 0,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  );

  int get totalChars => systemPromptChars + userInputChars + responseChars;
  int get estimatedTokens => (totalChars / 3.5).round();
  int get systemTokens => (systemPromptChars / 3.5).round();
  int get inputTokens => (userInputChars / 3.5).round();
  int get responseTokens => (responseChars / 3.5).round();
  double get utilization =>
      modelContextWindow == 0 ? 0 : estimatedTokens / modelContextWindow;
}

/// Tracks the most recent context-window usage for the user-facing
/// "Context" panel in Settings.  Updated from [AgentRuntime.chat] after
/// each turn — no live token telemetry from the provider, just a
/// char-based estimate.
class ContextStatsService extends AppService {
  final Rx<ContextSnapshot> snapshot = ContextSnapshot.empty().obs;

  /// Replace the snapshot with fresh measurements.  Called by AgentRuntime.
  void record({
    required String? modelName,
    required int systemPromptChars,
    required int userInputChars,
    required int responseChars,
  }) {
    final cur = snapshot.value;
    snapshot.value = ContextSnapshot(
      modelName: modelName,
      modelContextWindow: contextWindowFor(modelName),
      systemPromptChars: systemPromptChars,
      userInputChars: userInputChars,
      responseChars: responseChars,
      turnCount: cur.turnCount + 1,
      updatedAt: DateTime.now(),
    );
  }

  /// Best-effort lookup of a model's context window from its name.
  /// Defaults to 128 000 — a safe modern baseline.  Add entries as needed.
  static int contextWindowFor(String? model) {
    if (model == null) return 128000;
    final m = model.toLowerCase();
    if (m.contains('gemini-2') || m.contains('gemini-1.5')) return 1000000;
    if (m.contains('gemini')) return 32000;
    if (m.contains('claude') && m.contains('haiku')) return 200000;
    if (m.contains('claude') && m.contains('sonnet')) return 200000;
    if (m.contains('claude') && m.contains('opus')) return 200000;
    if (m.contains('claude')) return 200000;
    if (m.contains('gpt-4o') || m.contains('gpt-4.1')) return 128000;
    if (m.contains('gpt-4-turbo')) return 128000;
    if (m.contains('gpt-4')) return 8192;
    if (m.contains('gpt-3.5')) return 16000;
    if (m.contains('deepseek')) return 128000;
    if (m.contains('doubao')) return 128000;
    if (m.contains('qwen') && m.contains('long')) return 1000000;
    if (m.contains('qwen')) return 32000;
    if (m.contains('llama-3') || m.contains('llama3')) return 8192;
    return 128000;
  }
}
