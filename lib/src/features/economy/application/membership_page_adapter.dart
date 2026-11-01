import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'membership_selection_controller.dart';

final class MembershipPageAdapter implements AppControlPageAdapter {
  MembershipPageAdapter({
    required this.route,
    required this.controller,
    required this.coordinator,
  });
  @override
  final String route;
  final MembershipSelectionController controller;
  final AgentUiControlCoordinator coordinator;
  bool _mounted = true;
  static const prepareAction = 'prepare_membership_plan';
  static final _actions = List<AppControlPageAction>.unmodifiable([
    AppControlPageAction(
      id: prepareAction,
      description:
          'Select a visible membership plan for human review. Does not buy, restore, cancel, or request a charge.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {
          'tier': {
            'type': 'string',
            'enum': ['free', 'basic', 'plus', 'pro_v2'],
          },
        },
        'required': ['tier'],
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'prepared': {'const': true},
          'charged': {'const': false},
        },
        'required': ['prepared', 'charged'],
        'additionalProperties': false,
      },
      risk: ActionRisk.localMutation,
      consequencePolicy: ActionConsequencePolicy.prepareOnly,
    ),
  ]);
  @override
  List<AppControlPageAction> get appControlActions => _actions;
  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    if (!_mounted ||
        actionId != prepareAction ||
        arguments.length != 1 ||
        arguments['tier'] is! String) {
      return _failure();
    }
    final result = await coordinator.runStep<bool>(
      lease: lease,
      stepId: 'membership.prepare',
      command: (context) async {
        context.checkpoint();
        executionContext.checkpoint();
        return _mounted && controller.prepare(arguments['tier'] as String);
      },
    );
    if (!result.isSuccess) return result.asFailure<Map<String, Object?>>();
    return result.value == true
        ? AgentUiControlResult.success({'prepared': true, 'charged': false})
        : _failure();
  }

  void detach() => _mounted = false;
  static AgentUiControlResult<Map<String, Object?>>
  _failure() => const AgentUiControlResult.failure(
    AgentUiControlResultStatus.pageNotReady,
    message:
        'Membership selection is unavailable. Only the user can start payment.',
  );
}
