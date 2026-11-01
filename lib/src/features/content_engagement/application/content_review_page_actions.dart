import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

import 'content_review_controller.dart';

/// Delegated by the existing identity route adapter. It never replaces the
/// route's registry entry and has no public-write or submit action.
class ContentReviewPageActions {
  ContentReviewPageActions({
    required this.coordinator,
    required this.open,
    required this.controller,
  });
  final AgentUiControlCoordinator coordinator;
  final bool Function() open;
  final ContentReviewController? Function() controller;
  bool _mounted = true;
  static const openAction = 'open_my_reviews';
  static const refreshAction = 'refresh_my_reviews';
  static const prepareAction = 'prepare_review_appeal';
  static final actions = List<AppControlPageAction>.unmodifiable([
    for (final id in [openAction, refreshAction])
      AppControlPageAction(
        id: id,
        description: id == openAction
            ? 'Open the visible review and appeal panel.'
            : 'Refresh the current account review statuses in the visible panel.',
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
          'Prepare a visible appeal reason for one rejected review. The player must press Submit appeal.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {
          'reviewId': {'type': 'string', 'minLength': 1, 'maxLength': 40},
          'reason': {'type': 'string', 'minLength': 1, 'maxLength': 600},
        },
        'required': ['reviewId', 'reason'],
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
  Future<AgentUiControlResult<Map<String, Object?>>> execute({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    final prepare = actionId == prepareAction;
    if (!_mounted ||
        !const {openAction, refreshAction, prepareAction}.contains(actionId) ||
        (prepare
            ? arguments.length != 2 ||
                  arguments['reviewId'] is! String ||
                  arguments['reason'] is! String ||
                  (arguments['reason'] as String).trim().isEmpty ||
                  (arguments['reason'] as String).runes.length > 600 ||
                  (arguments['reviewId'] as String).runes.length > 40
            : arguments.isNotEmpty)) {
      return _failure();
    }
    final result = await coordinator.runStep<bool>(
      lease: lease,
      stepId: 'reviews.$actionId',
      command: (context) async {
        context.checkpoint();
        executionContext.checkpoint();
        if (!_mounted) return false;
        final c = controller();
        if (c?.userControl == true) return false;
        if (actionId == openAction) return open();
        if (c == null || !c.active) return false;
        if (actionId == refreshAction) {
          final done = await executionContext.guardedCall(c.refresh);
          context.checkpoint();
          return _mounted && done;
        }
        return c.prepare(
          arguments['reviewId'] as String,
          arguments['reason'] as String,
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
        message: 'The review panel is not ready for this action.',
      );
}
