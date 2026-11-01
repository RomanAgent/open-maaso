import 'agent_ui_control_state.dart';
import 'app_control_page_adapter.dart';

/// Routes a trusted AppControl command to exactly one app-owned executor.
///
/// Zero matches and ambiguous matches fail closed. The match is recalculated
/// immediately before execution so a route attachment cannot be borrowed from
/// a prior [supports] check.
final class AppControlHostCommandRouter
    implements AppControlHostCommandExecutor {
  AppControlHostCommandRouter(Iterable<AppControlHostCommandExecutor> delegates)
    : _delegates = List<AppControlHostCommandExecutor>.unmodifiable(delegates);

  final List<AppControlHostCommandExecutor> _delegates;

  @override
  bool supports(AppControlHostCommand command) => _singleMatch(command) != null;

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> execute({
    required AppControlHostCommand command,
    required AppControlActionExecutionContext executionContext,
  }) {
    final delegate = _singleMatch(command);
    if (delegate == null) {
      return Future<AgentUiControlResult<Map<String, Object?>>>.value(
        const AgentUiControlResult<Map<String, Object?>>.failure(
          AgentUiControlResultStatus.pageNotReady,
          message: 'No unique Host executor is ready for this page action.',
        ),
      );
    }
    return delegate.execute(
      command: command,
      executionContext: executionContext,
    );
  }

  AppControlHostCommandExecutor? _singleMatch(AppControlHostCommand command) {
    AppControlHostCommandExecutor? match;
    for (final delegate in _delegates) {
      bool supported;
      try {
        supported = delegate.supports(command);
      } catch (_) {
        supported = false;
      }
      if (!supported) continue;
      if (match != null) return null;
      match = delegate;
    }
    return match;
  }
}
