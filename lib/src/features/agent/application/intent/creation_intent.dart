enum CreationIntentMode {
  none,
  create,
  propose,
  confirm,
  edit,
  cancel,
  retry,
  status,
}

enum CreationIntentKind { game, utility }

/// Semantic decision from the current reply. This is data, never an executable
/// grant: only the owning human turn may admit it through the runtime.
final class CreationIntent {
  const CreationIntent._({
    required this.mode,
    this.kind,
    this.requirements = '',
    this.proposalId,
    this.projectId,
    this.taskId,
  });

  final CreationIntentMode mode;
  final CreationIntentKind? kind;
  final String requirements;
  final String? proposalId;
  final String? projectId;
  final String? taskId;

  factory CreationIntent.fromJson(Map<String, Object?> data) {
    if (data['type'] != 'creation.intent' || data['mode'] is! String) {
      throw const FormatException('invalid_creation_intent');
    }
    final mode = CreationIntentMode.values
        .where((mode) => mode.name == data['mode'])
        .firstOrNull;
    if (mode == null) throw const FormatException('invalid_creation_mode');
    final fields = <String>{'type', 'mode'};
    CreationIntentKind? kind;
    var requirements = '';
    String? proposalId, projectId, taskId;
    switch (mode) {
      case CreationIntentMode.none:
        break;
      case CreationIntentMode.create:
      case CreationIntentMode.propose:
        fields.addAll({'kind', 'requirements'});
        kind = CreationIntentKind.values
            .where((kind) => kind.name == data['kind'])
            .firstOrNull;
        if (kind == null) throw const FormatException('invalid_creation_kind');
        requirements = _requirements(data['requirements']);
      case CreationIntentMode.confirm:
        fields.addAll({'proposalId', 'requirements'});
        proposalId = _id(data['proposalId']);
        if (data.containsKey('requirements')) {
          if (data['requirements'] is! String) {
            throw const FormatException('invalid_creation_requirements');
          }
          requirements = (data['requirements'] as String).trim();
        }
      case CreationIntentMode.edit:
        fields.addAll({'projectId', 'requirements'});
        projectId = _id(data['projectId']);
        requirements = _requirements(data['requirements']);
      case CreationIntentMode.cancel:
      case CreationIntentMode.retry:
      case CreationIntentMode.status:
        fields.add('taskId');
        taskId = _id(data['taskId']);
    }
    if (data.keys.any((key) => !fields.contains(key))) {
      throw const FormatException('unknown_creation_field');
    }
    return CreationIntent._(
      mode: mode,
      kind: kind,
      requirements: requirements,
      proposalId: proposalId,
      projectId: projectId,
      taskId: taskId,
    );
  }

  Map<String, Object?> toJson() => {
    'type': 'creation.intent',
    'mode': mode.name,
    if (kind != null) 'kind': kind!.name,
    if (requirements.isNotEmpty || mode == CreationIntentMode.confirm)
      'requirements': requirements,
    if (proposalId != null) 'proposalId': proposalId,
    if (projectId != null) 'projectId': projectId,
    if (taskId != null) 'taskId': taskId,
  };

  static String _requirements(Object? value) {
    if (value is! String || value.trim().isEmpty) {
      throw const FormatException('invalid_creation_requirements');
    }
    return value.trim();
  }

  static String _id(Object? value) {
    if (value is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:/-]{0,159}$').hasMatch(value)) {
      throw const FormatException('invalid_creation_target');
    }
    return value;
  }
}
