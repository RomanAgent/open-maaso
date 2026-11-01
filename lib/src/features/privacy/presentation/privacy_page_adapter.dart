import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_localization.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import '../application/privacy_service.dart';

/// The agent can refresh the visible status. A person's birth date and consent
/// are submitted only by the human form, with no AppControl write action.
final class PrivacyPageAdapter implements AppControlPageAdapter {
  PrivacyPageAdapter({required this.service, required this.coordinator});
  final PrivacyService service;
  final AgentUiControlCoordinator coordinator;
  bool _mounted = true;
  static const refreshAction = 'refresh_privacy_status';

  @override
  String get route => AppRouteCatalog.privacy;

  @override
  List<AppControlPageAction> get appControlActions => service.isInternalTest
      ? const []
      : [
          AppControlPageAction(
            id: refreshAction,
            description:
                'Refresh the visible privacy policy and permission status.',
            argumentsSchema: const {
              'type': 'object',
              'properties': {},
              'additionalProperties': false,
            },
            resultSchema: const {
              'type': 'object',
              'properties': {
                'ready': {'type': 'boolean'},
              },
              'required': ['ready'],
              'additionalProperties': false,
            },
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
        service.isInternalTest ||
        actionId != refreshAction ||
        arguments.isNotEmpty ||
        !service.isCurrent ||
        service.saving) {
      return _failure();
    }
    final result = await coordinator.runStep<bool>(
      lease: lease,
      stepId: 'privacy.refresh',
      command: (context) async {
        context.checkpoint();
        executionContext.checkpoint();
        if (!_mounted || !service.isCurrent) return false;
        await executionContext.guardedCall(service.refresh);
        context.checkpoint();
        return _mounted && service.isCurrent;
      },
    );
    if (!result.isSuccess) return result.asFailure<Map<String, Object?>>();
    if (result.value != true) return _failure();
    return AgentUiControlResult.success({
      'ready': service.publicPolicy?.ready == true,
    });
  }

  void detach() => _mounted = false;
  static AgentUiControlResult<Map<String, Object?>> _failure() =>
      AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'privacy.status_unavailable'.tr,
      );
}
