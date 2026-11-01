import 'agent_skill.dart';

/// Immutable, prompt-only JSON Schemas for structured `skill.call` actions.
///
/// This type deliberately cannot be passed to `SkillManager`'s native tool
/// registry. A schema in this set describes model output, but grants no
/// authority to execute a handler through generic tool-calling channels.
final class StructuredActionPromptSchemas {
  StructuredActionPromptSchemas(Map<String, Map<String, dynamic>> schemas)
    : _schemas = Map<String, Map<String, dynamic>>.unmodifiable(
        <String, Map<String, dynamic>>{
          for (final entry in schemas.entries)
            _methodName(entry.key): Map<String, dynamic>.unmodifiable(
              entry.value,
            ),
        },
      );

  const StructuredActionPromptSchemas._empty()
    : _schemas = const <String, Map<String, dynamic>>{};

  static const StructuredActionPromptSchemas none =
      StructuredActionPromptSchemas._empty();

  final Map<String, Map<String, dynamic>> _schemas;

  bool get isEmpty => _schemas.isEmpty;

  List<String> get methodNames => List<String>.unmodifiable(_schemas.keys);

  Map<String, dynamic>? schemaFor(String method) => _schemas[method];

  static String _methodName(String raw) {
    final method = raw.trim();
    if (method.isEmpty || method != raw) {
      throw ArgumentError.value(raw, 'schemas', 'method must be normalized');
    }
    return method;
  }
}

/// Opt-in contract for methods that are visible only to structured actions.
///
/// Implementing this interface replaces the default prompt projection. It
/// does not add anything to [AgentSkill.nativeToolSchemas].
abstract interface class StructuredActionPromptSchemaProvider {
  StructuredActionPromptSchemas get structuredActionPromptSchemas;
}

/// Projects one Skill into structured-action prompt metadata.
///
/// Existing native Skills keep their current structured prompt automatically.
/// Prompt-only providers opt into a distinct value type and remain invisible
/// to `SkillManager.toNativeTools` and `SkillManager.invokeTool`.
extension AgentSkillStructuredActionPromptProjection on AgentSkill {
  StructuredActionPromptSchemas get modelStructuredActionPromptSchemas {
    final skill = this;
    if (skill is StructuredActionPromptSchemaProvider) {
      return (skill as StructuredActionPromptSchemaProvider)
          .structuredActionPromptSchemas;
    }
    final native = skill.nativeToolSchemas;
    if (native == null || native.isEmpty) {
      return StructuredActionPromptSchemas.none;
    }
    return StructuredActionPromptSchemas(native);
  }
}
