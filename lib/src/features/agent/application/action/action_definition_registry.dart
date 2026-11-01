import 'action_definition.dart';

/// Registration-order registry for host-owned action contracts.
///
/// Existing Maaso skill names can collide after tool-name sanitization. The
/// compatibility path therefore exposes [registerIfAbsent], whose first-match
/// semantics mirror `SkillManager`. New explicit registrations should use
/// [register], which rejects ambiguity.
class ActionDefinitionRegistry {
  final Map<String, ActionDefinition> _firstById = <String, ActionDefinition>{};
  final List<ActionDefinition> _definitions = <ActionDefinition>[];
  List<ActionDefinition>? _snapshot;

  List<ActionDefinition> get definitions =>
      _snapshot ??= List<ActionDefinition>.unmodifiable(_definitions);

  ActionDefinition? find(String id) => _firstById[id.trim()];

  bool contains(String id) => _firstById.containsKey(id.trim());

  void register(ActionDefinition definition) {
    final id = _validatedId(definition.id);
    if (_firstById.containsKey(id)) {
      throw StateError('Duplicate action definition: $id');
    }
    _add(id, definition);
  }

  bool registerIfAbsent(ActionDefinition definition) {
    final id = _validatedId(definition.id);
    if (_firstById.containsKey(id)) return false;
    _add(id, definition);
    return true;
  }

  ActionDefinition require(String id) {
    final normalized = id.trim();
    final definition = _firstById[normalized];
    if (definition == null) {
      throw StateError('Unknown action definition: $normalized');
    }
    return definition;
  }

  void _add(String id, ActionDefinition definition) {
    _firstById[id] = definition;
    _definitions.add(definition);
    _snapshot = null;
  }

  static String _validatedId(String raw) {
    final id = raw.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(raw, 'definition.id', 'must not be empty');
    }
    if (id.length > 128 || !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(id)) {
      throw ArgumentError.value(
        raw,
        'definition.id',
        'must use 1-128 ASCII identifier characters',
      );
    }
    return id;
  }
}
