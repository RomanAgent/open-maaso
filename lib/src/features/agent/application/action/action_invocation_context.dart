part of 'agent_action_executor.dart';

/// Host-issued execution identity for one already-granted structured tool call.
///
/// The context lives only in the async Zone that invokes the granted handler.
/// Direct/native callers therefore cannot inherit structured Host authority.
final class ActionInvocationContext {
  ActionInvocationContext._({
    required this.accountScope,
    required this.agentId,
    required this.runtimeGeneration,
    required this.callId,
    required this.tool,
    required this.skillName,
    required this.method,
    required String canonicalArgumentsJson,
    required ExecutableHostGrant executableHostGrant,
    required GrantedHostTool binding,
    required bool Function() accountFenceIsCurrent,
    required AccountStorageScopeBoundaryHold Function()
    acquireAccountBoundaryHold,
    required List<Future<void>> invalidationSignals,
  }) : _executableHostGrant = executableHostGrant,
       _binding = binding,
       _canonicalArgumentsJson = canonicalArgumentsJson,
       _accountFenceIsCurrent = accountFenceIsCurrent,
       _acquireAccountBoundaryHold = acquireAccountBoundaryHold,
       _invalidationSignals = invalidationSignals;

  static final Object _zoneKey = Object();

  final String accountScope;
  final String agentId;
  final int runtimeGeneration;
  final String callId;
  final String tool;
  final String skillName;
  final String method;
  final ExecutableHostGrant _executableHostGrant;
  final GrantedHostTool _binding;
  final String _canonicalArgumentsJson;
  final bool Function() _accountFenceIsCurrent;
  final AccountStorageScopeBoundaryHold Function() _acquireAccountBoundaryHold;
  final List<Future<void>> _invalidationSignals;
  final Completer<void> _closed = Completer<void>.sync();
  bool _active = true;

  late final Future<void> whenInvalidated = Future.any<void>(<Future<void>>[
    ..._invalidationSignals,
    _closed.future,
  ]);

  static ActionInvocationContext? get current =>
      Zone.current[_zoneKey] as ActionInvocationContext?;

  /// Issues a context only when [binding] is still the exact authorized tool.
  static ActionInvocationContext? _issue({
    required String accountScope,
    required String agentId,
    required int runtimeGeneration,
    required String callId,
    required String tool,
    required Map<String, Object?> arguments,
    required ExecutableHostGrant executableHostGrant,
    required GrantedHostTool binding,
    required bool Function() accountFenceIsCurrent,
    required AccountStorageScopeBoundaryHold Function()
    acquireAccountBoundaryHold,
    required List<Future<void>> invalidationSignals,
  }) {
    final normalizedAccountScope = accountScope.trim();
    final normalizedAgentId = agentId.trim();
    final normalizedCallId = callId.trim();
    final normalizedTool = tool.trim();
    final normalizedSkillName = binding.skill.skillName.trim();
    final normalizedMethod = binding.method.trim();
    final canonicalArgumentsJson = _canonicalInvocationArguments(arguments);
    if (normalizedAccountScope.isEmpty ||
        normalizedAccountScope.length > 512 ||
        normalizedAgentId.isEmpty ||
        normalizedAgentId.length > 256 ||
        runtimeGeneration < 0 ||
        normalizedCallId.isEmpty ||
        normalizedCallId.length > 256 ||
        normalizedTool.isEmpty ||
        normalizedTool.length > 256 ||
        normalizedSkillName.isEmpty ||
        normalizedMethod.isEmpty ||
        !identical(
          executableHostGrant.authorize(
            agentId: normalizedAgentId,
            tool: normalizedTool,
          ),
          binding,
        )) {
      return null;
    }
    return ActionInvocationContext._(
      accountScope: normalizedAccountScope,
      agentId: normalizedAgentId,
      runtimeGeneration: runtimeGeneration,
      callId: normalizedCallId,
      tool: normalizedTool,
      skillName: normalizedSkillName,
      method: normalizedMethod,
      canonicalArgumentsJson: canonicalArgumentsJson,
      executableHostGrant: executableHostGrant,
      binding: binding,
      accountFenceIsCurrent: accountFenceIsCurrent,
      acquireAccountBoundaryHold: acquireAccountBoundaryHold,
      invalidationSignals: List<Future<void>>.unmodifiable(invalidationSignals),
    );
  }

  /// Rechecks both the upstream Host grant and the captured account fence.
  bool get isCurrent {
    try {
      return _active &&
          _accountFenceIsCurrent() &&
          identical(
            _executableHostGrant.authorize(agentId: agentId, tool: tool),
            _binding,
          );
    } catch (_) {
      return false;
    }
  }

  bool matches({
    required String agentId,
    required String skillName,
    required String method,
  }) =>
      this.agentId == agentId.trim() &&
      this.skillName == skillName.trim() &&
      this.method == method.trim();

  /// Revalidates one exact Host registration and the arguments that reached
  /// its schema-checked handler. [GrantedHostTool] cannot be constructed by a
  /// package, and identity comparison prevents a same-named Skill from
  /// borrowing another registration's authority.
  bool matchesExactHostTool({
    required GrantedHostTool registeredTool,
    required String skillName,
    required String method,
    required Map<String, Object?> arguments,
  }) {
    if (!isCurrent ||
        !identical(_binding, registeredTool) ||
        this.skillName != skillName.trim() ||
        this.method != method.trim()) {
      return false;
    }
    try {
      return _canonicalArgumentsJson ==
          _canonicalInvocationArguments(arguments);
    } catch (_) {
      return false;
    }
  }

  AccountStorageScopeBoundaryHold? acquireAccountBoundaryHold() {
    if (!isCurrent) return null;
    try {
      final hold = _acquireAccountBoundaryHold();
      if (isCurrent) return hold;
      hold.release();
      return null;
    } catch (_) {
      return null;
    }
  }

  static Future<T> _run<T>(
    ActionInvocationContext context,
    Future<T> Function() action,
  ) => runZoned<Future<T>>(() async {
    if (!context._active) {
      throw StateError('action_invocation_context_consumed');
    }
    try {
      if (!context.isCurrent) {
        throw SkillNotGrantedException(context.skillName);
      }
      final result = await action();
      if (!context.isCurrent) {
        throw SkillNotGrantedException(context.skillName);
      }
      return result;
    } finally {
      // Any unawaited work that inherited this Zone sees a closed context once
      // the granted handler returns, so authority cannot outlive its call.
      context._active = false;
      if (!context._closed.isCompleted) context._closed.complete();
    }
  }, zoneValues: <Object, Object>{_zoneKey: context});
}

String _canonicalInvocationArguments(Map<String, Object?> arguments) {
  Object? canonicalize(Object? value) {
    if (value == null || value is bool || value is num || value is String) {
      return value;
    }
    if (value is List) {
      return <Object?>[for (final item in value) canonicalize(item)];
    }
    if (value is Map) {
      final entries = <String, Object?>{};
      final keys = value.keys.whereType<String>().toList(growable: false)
        ..sort();
      if (keys.length != value.length) {
        throw const FormatException('non_string_action_argument_key');
      }
      for (final key in keys) {
        entries[key] = canonicalize(value[key]);
      }
      return entries;
    }
    throw const FormatException('non_json_action_argument');
  }

  return jsonEncode(canonicalize(arguments));
}
