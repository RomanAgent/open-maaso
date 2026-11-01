import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'people_safety_controller.dart';

final class PeopleSafetyPageAdapter implements AppControlPageAdapter {
  PeopleSafetyPageAdapter({
    required this.route,
    required this.controller,
    required this.coordinator,
  });
  @override
  final String route;
  final PeopleSafetyController controller;
  final AgentUiControlCoordinator coordinator;
  bool _mounted = true;
  static const refreshAction = 'refresh_blocks';
  static const prepareAction = 'prepare_unblock';
  @override
  List<AppControlPageAction> get appControlActions => _actions;
  static final _actions = List<AppControlPageAction>.unmodifiable([
    AppControlPageAction(
      id: refreshAction,
      description:
          'Refresh the visible list of accounts blocked by the current player.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'completed': {'const': true},
          'submitted': {'const': false},
        },
        'required': ['completed', 'submitted'],
        'additionalProperties': false,
      },
      risk: ActionRisk.readOnly,
      consequencePolicy: ActionConsequencePolicy.reversible,
    ),
    AppControlPageAction(
      id: prepareAction,
      description:
          'Preview unblocking one actor already in the visible blocked list. The player must press Confirm unblock.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {
          'actorId': {'type': 'string', 'minLength': 1, 'maxLength': 96},
          'actorKind': {
            'enum': ['user', 'agent'],
          },
        },
        'required': ['actorId', 'actorKind'],
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'completed': {'const': true},
          'submitted': {'const': false},
        },
        'required': ['completed', 'submitted'],
        'additionalProperties': false,
      },
      risk: ActionRisk.localMutation,
      consequencePolicy: ActionConsequencePolicy.prepareOnly,
    ),
  ]);
  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    if (!_mounted ||
        !controller.active ||
        controller.userControl ||
        (actionId != refreshAction && actionId != prepareAction)) {
      return _failure();
    }
    if (actionId == refreshAction && arguments.isNotEmpty ||
        actionId == prepareAction &&
            (arguments.length != 2 ||
                arguments['actorId'] is! String ||
                arguments['actorKind'] is! String)) {
      return _failure();
    }
    final result = await coordinator.runStep<bool>(
      lease: lease,
      stepId: 'people.$actionId',
      command: (context) async {
        context.checkpoint();
        executionContext.checkpoint();
        if (!_mounted || !controller.active || controller.userControl) {
          return false;
        }
        if (actionId == refreshAction) {
          final done = await executionContext.guardedCall(controller.refresh);
          context.checkpoint();
          return _mounted && done;
        }
        return controller.prepareUnblock(
          arguments['actorId'] as String,
          arguments['actorKind'] as String,
          fromAgent: true,
        );
      },
    );
    if (!result.isSuccess) return result.asFailure<Map<String, Object?>>();
    if (result.value != true) return _failure();
    return const AgentUiControlResult.success({
      'completed': true,
      'submitted': false,
    });
  }

  void detach() => _mounted = false;
  static AgentUiControlResult<Map<String, Object?>> _failure() =>
      const AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'The blocked accounts page is not ready for this action.',
      );
}
