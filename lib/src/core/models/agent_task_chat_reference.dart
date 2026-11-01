/// A durable, account-scoped reference to one task across execution attempts.
final class AgentTaskChatReference {
  const AgentTaskChatReference({
    required this.taskId,
    required this.scopeKey,
    required this.agentId,
  });

  final String taskId;
  final String scopeKey;
  final String agentId;

  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'scopeKey': scopeKey,
    'agentId': agentId,
  };

  static AgentTaskChatReference? tryParse(Object? value) {
    if (value is! Map) return null;
    final taskId = value['taskId'];
    final scope = value['scopeKey'];
    final agent = value['agentId'];
    if (taskId is! String ||
        !RegExp(r'^job_[0-9]+_[0-9]+$').hasMatch(taskId) ||
        scope is! String ||
        scope.length > 512 ||
        agent is! String ||
        agent.isEmpty ||
        agent.length > 128) {
      return null;
    }
    return AgentTaskChatReference(
      taskId: taskId,
      scopeKey: scope,
      agentId: agent,
    );
  }
}
