import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

import 'identity_setup_controller.dart';
import '../../content_engagement/application/content_review_page_actions.dart';

/// Declares a visible local draft action. Public identity submission is owned
/// by the user's save button; there is no executable AppControl commit action.
final class IdentityPageAdapter implements AppControlPageAdapter {
  IdentityPageAdapter({
    required this.route,
    required this.controller,
    required this.coordinator,
    this.reviews,
  });

  @override
  final String route;
  final IdentitySetupController controller;
  final AgentUiControlCoordinator coordinator;
  final ContentReviewPageActions? reviews;
  bool _mounted = true;
  static const prepareAction = 'prepare_identity_names';

  @override
  List<AppControlPageAction> get appControlActions => [
    ..._actions,
    if (reviews != null) ...ContentReviewPageActions.actions,
  ];

  static final _actions = List<AppControlPageAction>.unmodifiable([
    AppControlPageAction(
      id: prepareAction,
      description:
          'Preview the player and Agent public names in this form for the user to save.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {
          'playerName': {'type': 'string', 'minLength': 1, 'maxLength': 40},
          'agentName': {'type': 'string', 'minLength': 1, 'maxLength': 40},
        },
        'required': ['playerName', 'agentName'],
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'prepared': {'const': true},
          'saved': {'const': false},
        },
        'required': ['prepared', 'saved'],
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
    if (!_mounted) return _failure();
    if (actionId != prepareAction && reviews != null) {
      return reviews!.execute(
        lease: lease,
        actionId: actionId,
        arguments: arguments,
        executionContext: executionContext,
      );
    }
    if (actionId != prepareAction ||
        arguments.length != 2 ||
        arguments['playerName'] is! String ||
        arguments['agentName'] is! String) {
      return _failure();
    }
    final result = await coordinator.runStep<bool>(
      lease: lease,
      stepId: 'identity.prepare_names',
      command: (context) async {
        context.checkpoint();
        executionContext.checkpoint();
        if (!_mounted) return false;
        return controller.prepareNames(
          player: arguments['playerName'] as String,
          agent: arguments['agentName'] as String,
        );
      },
    );
    if (!result.isSuccess) return result.asFailure<Map<String, Object?>>();
    if (result.value != true) return _failure();
    return AgentUiControlResult<Map<String, Object?>>.success({
      'prepared': true,
      'saved': false,
    });
  }

  void detach() => _mounted = false;

  static AgentUiControlResult<Map<String, Object?>> _failure() =>
      const AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'Identity form is not available for this draft.',
      );
}
