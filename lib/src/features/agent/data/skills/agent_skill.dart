/// Base class for host capabilities exposed to the agent.
///
/// Skills are executed through structured JSON actions. The model sees method
/// names and optional JSON Schemas from [SkillManager], not script snippets.
abstract class AgentSkill {
  String get namespace => 'skill';

  /// Unique skill name used for routing and generated tool names.
  String get skillName;

  /// Short capability description shown in the structured-action prompt.
  String get description;

  /// Method name to Dart handler. Handlers keep the existing positional
  /// argument shape so local and cloud callers can share implementations.
  Map<String, dynamic Function(List<dynamic>)> get methods;

  /// Optional JSON Schema per method for model-visible `skill.call` arguments.
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => null;

  /// Optional method descriptions shown beside schema-backed tools.
  Map<String, String> get nativeMethodDescriptions => const {};
}
