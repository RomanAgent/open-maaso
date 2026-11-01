import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'account_deletion_service.dart';

final class AccountDeletionPageAdapter implements AppControlPageAdapter {
  AccountDeletionPageAdapter({
    required this.route,
    required this.service,
    required this.coordinator,
  });
  @override
  final String route;
  final AccountDeletionService service;
  final AgentUiControlCoordinator coordinator;
  bool _mounted = true;
  @override
  List<AppControlPageAction> get appControlActions => [
    AppControlPageAction(
      id: 'prepare_deletion_review',
      description:
          'Show the deletion review destination. Account verification, acknowledgements and deletion require the human user.',
      argumentsSchema: const {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      resultSchema: const {'type': 'object'},
      risk: ActionRisk.localMutation,
      consequencePolicy: ActionConsequencePolicy.prepareOnly,
    ),
    AppControlPageAction(
      id: 'read_deletion_status',
      description:
          'Read a saved deletion state without exposing credentials or a receipt capability.',
      argumentsSchema: const {
        'type': 'object',
        'properties': <String, Object?>{},
        'additionalProperties': false,
      },
      resultSchema: const {'type': 'object'},
      risk: ActionRisk.readOnly,
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
    if (!_mounted ||
        arguments.isNotEmpty ||
        ![
          'prepare_deletion_review',
          'read_deletion_status',
        ].contains(actionId)) {
      return const AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message:
            'Deletion is available only through explicit human confirmation.',
      );
    }
    final result = await coordinator.runStep<Map<String, Object?>>(
      lease: lease,
      stepId: 'account_deletion.$actionId',
      command: (context) async {
        context.checkpoint();
        service.contextChanged();
        executionContext.checkpoint();
        if (!_mounted) throw StateError('Page detached');
        return {
          'prepared': true,
          'deletionRequested': false,
          'humanConfirmationRequired': true,
          'state': service.status?.state ?? 'not_requested',
        };
      },
    );
    return result;
  }

  void detach() => _mounted = false;
}
