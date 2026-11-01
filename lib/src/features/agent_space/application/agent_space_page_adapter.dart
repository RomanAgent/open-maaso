import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

abstract interface class AgentSpacePageTarget {
  bool get canExitAgentSpace;
  void exitAgentSpace();
}

/// Exposes only the same safe exit control shown on the mounted room page.
class AgentSpacePageAdapter implements AppControlPageAdapter {
  AgentSpacePageAdapter({
    required AgentUiControlCoordinator coordinator,
    required AgentSpacePageTarget target,
  }) : _coordinator = coordinator,
       _target = target;

  final AgentUiControlCoordinator _coordinator;
  final AgentSpacePageTarget _target;
  bool _mounted = true;

  @override
  String get route => AppRouteCatalog.agentSpace;

  @override
  final List<AppControlPageAction> appControlActions = [
    AppControlPageAction(
      id: 'exit',
      description: 'Leave the visible personal Agent space and return Home.',
      argumentsSchema: const {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'route': {'const': AppRouteCatalog.home},
        },
        'required': ['route'],
        'additionalProperties': false,
      },
      risk: ActionRisk.localMutation,
      consequencePolicy: ActionConsequencePolicy.reversible,
    ),
  ];

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    if (actionId != 'exit' || arguments.isNotEmpty) {
      return const AgentUiControlResult.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'Invalid Agent space action.',
      );
    }
    if (!_mounted || !_target.canExitAgentSpace) return _notReady();
    final stepped = await _coordinator
        .runStep<AgentUiControlResult<Map<String, Object?>>>(
          lease: lease,
          stepId: 'app_control.agent_space.exit',
          command: (context) async {
            context.checkpoint();
            executionContext.checkpoint();
            if (!_mounted || !_target.canExitAgentSpace) return _notReady();
            _target.exitAgentSpace();
            return const AgentUiControlResult.success({
              'route': AppRouteCatalog.home,
            });
          },
        );
    return stepped.isSuccess
        ? stepped.value!
        : stepped.asFailure<Map<String, Object?>>();
  }

  void detach() => _mounted = false;

  static AgentUiControlResult<Map<String, Object?>> _notReady() =>
      const AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'The Agent space exit is not visible on the active page.',
      );
}
