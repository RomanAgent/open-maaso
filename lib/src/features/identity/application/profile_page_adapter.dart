import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import '../domain/companion_profile.dart';
import 'profile_controller.dart';

final class ProfilePageAdapter implements AppControlPageAdapter {
  ProfilePageAdapter({
    required this.route,
    required this.controller,
    required this.coordinator,
  });
  @override
  final String route;
  final ProfileController controller;
  final AgentUiControlCoordinator coordinator;
  bool _mounted = true;
  static const nicknameAction = 'prepare_profile_nickname';
  static const interestsAction = 'prepare_profile_interests';
  static final _actions = [
    for (final nickname in [true, false])
      AppControlPageAction(
        id: nickname ? nicknameAction : interestsAction,
        description: nickname
            ? 'Preview a user nickname in the visible edit form. Only the user can save it.'
            : 'Preview explicit user interests in the visible edit form. This does not save or infer interests from memories.',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            if (nickname)
              'nickname': {'type': 'string', 'minLength': 1, 'maxLength': 40}
            else
              'interests': {
                'type': 'array',
                'maxItems': 10,
                'uniqueItems': true,
                'items': {
                  'type': 'string',
                  'enum': CompanionProfile.interestIds,
                },
              },
          },
          'required': [nickname ? 'nickname' : 'interests'],
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
  ];
  @override
  List<AppControlPageAction> get appControlActions =>
      List.unmodifiable(_actions);
  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    if (!_mounted ||
        arguments.length != 1 ||
        (actionId != nicknameAction && actionId != interestsAction)) {
      return _failure();
    }
    if (actionId == nicknameAction && arguments['nickname'] is! String) {
      return _failure();
    }
    final interests = arguments['interests'];
    if (actionId == interestsAction &&
        (interests is! List || !interests.every((v) => v is String))) {
      return _failure();
    }
    final result = await coordinator.runStep<bool>(
      lease: lease,
      stepId: 'profile.$actionId',
      command: (context) async {
        context.checkpoint();
        executionContext.checkpoint();
        if (!_mounted) return false;
        return actionId == nicknameAction
            ? controller.prepareNickname(arguments['nickname'] as String)
            : controller.prepareInterests((interests as List).cast<String>());
      },
    );
    if (!result.isSuccess) return result.asFailure<Map<String, Object?>>();
    return result.value == true
        ? AgentUiControlResult.success({'prepared': true, 'saved': false})
        : _failure();
  }

  void detach() => _mounted = false;
  static AgentUiControlResult<Map<String, Object?>>
  _failure() => const AgentUiControlResult.failure(
    AgentUiControlResultStatus.pageNotReady,
    message:
        'Profile draft is unavailable. Saving requires the visible user button.',
  );
}
