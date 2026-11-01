import 'dart:convert';

import 'package:maaso/src/core/capability/app_capability_execution_context.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/scheduled_task_service.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';

class ScheduledTaskSkill extends AgentSkill {
  ScheduledTaskSkill({this.agentId});
  final String? agentId;

  @override
  String get skillName => 'ScheduledTask';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Create local-time reminders and daily tasks. With notification consent, '
      'the OS delivers them even when Maaso is backgrounded; foreground turns '
      'remain serialized through the normal Agent runtime.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'scheduleTask': _scheduleTask,
    'listTasks': _listTasks,
    'cancelTask': _cancelTask,
  };

  ScheduledTaskService? get _service =>
      appServices.isRegistered<ScheduledTaskService>()
      ? appServices.find<ScheduledTaskService>()
      : null;

  Future<String> _scheduleTask(List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    try {
      final raw = args[0];
      final j = raw is String ? jsonDecode(raw) : raw;
      if (j is! Map) return '{"error":"expected_object"}';
      final service = _service;
      if (service == null) return '{"error":"scheduler_unavailable"}';
      final capabilityContext = AppCapabilityExecutionContext.current;
      final actionContext = ActionInvocationContext.current;
      final bool Function()? commitFenceIsCurrent =
          capabilityContext == null && actionContext == null
          ? null
          : () =>
                (capabilityContext?.isCurrent ?? true) &&
                (actionContext?.isCurrent ?? true);
      return jsonEncode(
        _stableServiceResult(
          await service.schedule(
            when: j['when']?.toString() ?? '',
            prompt: j['prompt']?.toString() ?? '',
            repeat: j['repeat']?.toString() ?? 'once',
            commitFenceIsCurrent: commitFenceIsCurrent,
          ),
        ),
      );
    } catch (_) {
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  Future<String> _listTasks(List<dynamic> args) async {
    final service = _service;
    if (service == null) return '{"error":"scheduler_unavailable"}';
    return jsonEncode(await service.list());
  }

  Future<String> _cancelTask(List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    try {
      final raw = args[0];
      final j = raw is String ? jsonDecode(raw) : raw;
      final taskId = (j is Map) ? j['taskId']?.toString() ?? '' : '';
      final service = _service;
      if (service == null) return '{"error":"scheduler_unavailable"}';
      final capabilityContext = AppCapabilityExecutionContext.current;
      final actionContext = ActionInvocationContext.current;
      final bool Function()? commitFenceIsCurrent =
          capabilityContext == null && actionContext == null
          ? null
          : () =>
                (capabilityContext?.isCurrent ?? true) &&
                (actionContext?.isCurrent ?? true);
      return jsonEncode(
        _stableServiceResult(
          await service.cancel(
            taskId,
            commitFenceIsCurrent: commitFenceIsCurrent,
          ),
        ),
      );
    } catch (_) {
      return jsonEncode({'error': 'execution_failed'});
    }
  }

  Map<String, Object?> _stableServiceResult(Map<String, Object?> result) {
    final error = result['error'];
    if (error == null) return result;
    final code = switch (error.toString()) {
      'when must be HH:mm in 24-hour time' => 'invalid_when',
      'prompt required' => 'missing_prompt',
      'repeat must be once or daily' => 'invalid_repeat',
      'not found' => 'task_not_found',
      'invalid_when' ||
      'missing_prompt' ||
      'invalid_repeat' ||
      'task_not_found' ||
      'sign_in_required' ||
      'scope_changed' ||
      'scope_cleanup_failed' ||
      'capability_unavailable' ||
      'delivery_unavailable' ||
      'delivery_timeout' ||
      'delivery_schedule_failed' ||
      'delivery_cancel_failed' ||
      'persistence_failed' => error.toString(),
      _ => 'execution_failed',
    };
    return <String, Object?>{
      'error': code,
      if (result['cause'] != null) 'cause': result['cause'],
      if (result['rollback'] != null) 'rollback': result['rollback'],
    };
  }
}
