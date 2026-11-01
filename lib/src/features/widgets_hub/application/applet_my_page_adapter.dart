import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

/// Narrow capabilities matching visible My Applets rows and the Edit menu.
/// Publication and deletion remain human-confirmed page operations.
abstract interface class AppletMyPageTarget {
  bool get isReady;
  List<AgentWidget> get visibleLocalApplets;
  Future<void> openApplet(
    AgentWidget item, {
    required bool Function() canContinue,
  });
  Future<void> openVersionHistory(
    AgentWidget item, {
    required bool Function() canContinue,
  });
  Future<bool> prepareAppletEdit(
    AgentWidget item, {
    required bool Function() canContinue,
  });
}

final class AppletMyPageAdapter implements AppControlPageAdapter {
  AppletMyPageAdapter({required this.coordinator, required this.target});
  final AgentUiControlCoordinator coordinator;
  final AppletMyPageTarget target;
  bool _mounted = true;

  @override
  String get route => AppRouteCatalog.myApplets;

  @override
  List<AppControlPageAction> get appControlActions => [
    AppControlPageAction(
      id: 'read_my_applets',
      description:
          'Read the current owner’s visible, locally available applets.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {},
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'items': {
            'type': 'array',
            'maxItems': 100,
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'integer'},
                'title': {'type': 'string'},
              },
              'required': ['id', 'title'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['items'],
        'additionalProperties': false,
      },
      risk: ActionRisk.readOnly,
      consequencePolicy: ActionConsequencePolicy.reversible,
    ),
    AppControlPageAction(
      id: 'read_applet_versions',
      description:
          'Read locally saved immutable versions of one visible applet. Does not read or execute its source.',
      argumentsSchema: const {
        'type': 'object',
        'properties': {
          'id': {'type': 'integer', 'minimum': 1, 'maximum': 2147483647},
        },
        'required': ['id'],
        'additionalProperties': false,
      },
      resultSchema: const {
        'type': 'object',
        'properties': {
          'versions': {
            'type': 'array',
            'maxItems': 100,
            'items': {
              'type': 'object',
              'properties': {
                'id': {'type': 'string'},
                'number': {'type': 'integer'},
                'current': {'type': 'boolean'},
              },
              'required': ['id', 'number', 'current'],
              'additionalProperties': false,
            },
          },
        },
        'required': ['versions'],
        'additionalProperties': false,
      },
      risk: ActionRisk.readOnly,
      consequencePolicy: ActionConsequencePolicy.reversible,
    ),
    for (final action in [
      'open_applet',
      'prepare_edit',
      'open_version_history',
    ])
      AppControlPageAction(
        id: action,
        description: action == 'open_applet'
            ? 'Open an existing visible applet.'
            : action == 'open_version_history'
            ? 'Open the visible version history. Restoring still requires the human confirmation control.'
            : 'Select an existing applet for editing in Home. Does not send a message or change its source.',
        argumentsSchema: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'integer', 'minimum': 1, 'maximum': 2147483647},
          },
          'required': ['id'],
          'additionalProperties': false,
        },
        resultSchema: const {
          'type': 'object',
          'properties': {
            'accepted': {'type': 'boolean'},
          },
          'required': ['accepted'],
          'additionalProperties': false,
        },
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.prepareOnly,
      ),
  ];

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    final id = arguments['id'];
    if (![
          'read_my_applets',
          'open_applet',
          'prepare_edit',
          'read_applet_versions',
          'open_version_history',
        ].contains(actionId) ||
        (actionId == 'read_my_applets'
            ? arguments.isNotEmpty
            : arguments.length != 1 ||
                  id is! int ||
                  id < 1 ||
                  id > 2147483647)) {
      return const AgentUiControlResult.failure(
        AgentUiControlResultStatus.invalidState,
        message:
            'Unsupported applet action or arguments. Publishing and deletion require the visible confirmation controls.',
      );
    }
    if (!_mounted ||
        !target.isReady ||
        (coordinator.snapshot.targetRoute != null &&
            coordinator.snapshot.targetRoute != route)) {
      return _unavailable();
    }
    final result = await coordinator
        .runStep<AgentUiControlResult<Map<String, Object?>>>(
          lease: lease,
          stepId: 'my_applets.$actionId',
          command: (step) async {
            bool canContinue() {
              step.checkpoint();
              executionContext.checkpoint();
              return _mounted && target.isReady;
            }

            if (!canContinue()) return _unavailable();
            final items = target.visibleLocalApplets;
            if (actionId == 'read_my_applets') {
              return AgentUiControlResult.success({
                'items': [
                  for (final item in items.take(100))
                    if (item.id != null) {'id': item.id, 'title': item.title},
                ],
              });
            }
            final matches = items.where((item) => item.id == id);
            if (matches.isEmpty) return _unavailable();
            final item = matches.first;
            if (actionId == 'read_applet_versions') {
              try {
                final history = SurfaceVersionHistory.read(
                  item.spec,
                  title: item.title,
                );
                return AgentUiControlResult.success({
                  'versions': [
                    for (final version in history.versions.reversed.take(100))
                      {
                        'id': version.id,
                        'number': version.number,
                        'current': version.id == history.current.id,
                      },
                  ],
                });
              } catch (_) {
                return _unavailable();
              }
            }
            if (actionId == 'open_version_history') {
              await target.openVersionHistory(item, canContinue: canContinue);
              return const AgentUiControlResult.success({'accepted': true});
            }
            if (actionId == 'prepare_edit') {
              final accepted = await target.prepareAppletEdit(
                item,
                canContinue: canContinue,
              );
              return AgentUiControlResult.success({'accepted': accepted});
            }
            await target.openApplet(item, canContinue: canContinue);
            return const AgentUiControlResult.success({'accepted': true});
          },
        );
    if (!result.isSuccess) return result.asFailure<Map<String, Object?>>();
    return result.value ?? _unavailable();
  }

  void detach() => _mounted = false;

  static AgentUiControlResult<Map<String, Object?>> _unavailable() =>
      const AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'The applet is no longer available on this page.',
      );
}
