import 'dart:async';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

abstract interface class StorePageTarget {
  bool get isReady;
  bool get isWorkshop;
  String get selectedSection;
  void selectSection(String section);
}

abstract interface class StoreCatalogTarget {
  bool get catalogReady;
  List<Map<String, Object?>> get visibleAssets;
  Future<void> searchAssets(
    String query,
    String sort,
    bool Function() authority,
  );
  Future<void> openAsset(String id, String version, bool Function() authority);
}

/// Only visible section navigation. Asset installation, selection, upload and
/// publication retain their existing, separately authorized contracts.
final class StorePageAdapter implements AppControlPageAdapter {
  StorePageAdapter({
    required this.route,
    required this.coordinator,
    required this.target,
  });
  @override
  final String route;
  final AgentUiControlCoordinator coordinator;
  final StorePageTarget target;
  bool _attached = true;
  static const sections = ['models', 'skills'];

  @override
  List<AppControlPageAction> get appControlActions => [
    for (final id in [
      'read_store_assets',
      'search_store_assets',
      'open_store_asset',
    ])
      AppControlPageAction(
        id: id,
        description: id == 'read_store_assets'
            ? 'Read the currently loaded asset cards with version IDs and explicit metric units.'
            : id == 'search_store_assets'
            ? 'Search the active asset type with bounded text and its native popularity or recent ordering.'
            : 'Open details for one currently loaded asset at its exact version. Installation and selection remain user-confirmed visible controls.',
        argumentsSchema: {
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            if (id == 'search_store_assets') ...{
              'query': {'type': 'string', 'maxLength': 160},
              'sort': {
                'type': 'string',
                'enum': ['popular', 'recent'],
              },
            },
            if (id == 'open_store_asset') ...{
              'id': {'type': 'string', 'maxLength': 96},
              'versionId': {'type': 'string', 'maxLength': 128},
            },
          },
          if (id != 'read_store_assets')
            'required': id == 'search_store_assets'
                ? ['query', 'sort']
                : ['id', 'versionId'],
        },
        resultSchema: const {'type': 'object'},
        risk: id == 'read_store_assets'
            ? ActionRisk.readOnly
            : ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.reversible,
      ),
    for (final select in [false, true])
      AppControlPageAction(
        id: select ? 'select_store_section' : 'read_store_sections',
        description: select
            ? 'Select the visible Models or Skills section.'
            : 'Read the visible store or workshop section. Does not load hidden asset inventories.',
        argumentsSchema: {
          'type': 'object',
          'properties': {
            if (select) 'section': {'type': 'string', 'enum': sections},
          },
          if (select) 'required': ['section'],
          'additionalProperties': false,
        },
        resultSchema: const {
          'type': 'object',
          'properties': {
            'section': {'type': 'string', 'enum': sections},
            'workshop': {'type': 'boolean'},
          },
          'required': ['section', 'workshop'],
          'additionalProperties': false,
        },
        risk: select ? ActionRisk.localMutation : ActionRisk.readOnly,
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
    if (const {
      'read_store_assets',
      'search_store_assets',
      'open_store_asset',
    }.contains(actionId)) {
      return _catalog(lease, actionId, arguments, executionContext);
    }
    final select = actionId == 'select_store_section';
    if ((!select && actionId != 'read_store_sections') ||
        (select
            ? arguments.length != 1 || !sections.contains(arguments['section'])
            : arguments.isNotEmpty)) {
      return const AgentUiControlResult.failure(
        AgentUiControlResultStatus.invalidState,
        message:
            'Only visible section navigation is available. Asset writes require their own controls.',
      );
    }
    bool ready() =>
        _attached &&
        target.isReady &&
        (coordinator.snapshot.targetRoute == null ||
            Uri.tryParse(coordinator.snapshot.targetRoute!)?.path == route);
    if (!ready()) return _unavailable();
    final result = await coordinator.runStep<Map<String, Object?>>(
      lease: lease,
      stepId: 'store.$actionId',
      command: (step) async {
        step.checkpoint();
        executionContext.checkpoint();
        if (!ready()) throw StateError('store_page_unavailable');
        if (select) target.selectSection(arguments['section'] as String);
        return {
          'section': target.selectedSection,
          'workshop': target.isWorkshop,
        };
      },
    );
    return result;
  }

  Future<AgentUiControlResult<Map<String, Object?>>> _catalog(
    AgentUiControlLease lease,
    String action,
    Map<String, Object?> arguments,
    AppControlActionExecutionContext execution,
  ) async {
    final candidate = target;
    final catalog = candidate is StoreCatalogTarget
        ? candidate as StoreCatalogTarget
        : null;
    final read = action == 'read_store_assets';
    final search = action == 'search_store_assets';
    final valid = read
        ? arguments.isEmpty
        : search
        ? arguments.length == 2 &&
              arguments['query'] is String &&
              (arguments['query'] as String).length <= 160 &&
              const {'popular', 'recent'}.contains(arguments['sort'])
        : arguments.length == 2 &&
              arguments['id'] is String &&
              (arguments['id'] as String).isNotEmpty &&
              (arguments['id'] as String).length <= 96 &&
              arguments['versionId'] is String &&
              (arguments['versionId'] as String).isNotEmpty &&
              (arguments['versionId'] as String).length <= 128;
    if (!valid) {
      return const AgentUiControlResult.failure(
        AgentUiControlResultStatus.invalidState,
      );
    }
    if (catalog == null || !catalog.catalogReady) {
      return _unavailable();
    }
    bool ready() =>
        _attached &&
        target.isReady &&
        (coordinator.snapshot.targetRoute == null ||
            Uri.tryParse(coordinator.snapshot.targetRoute!)?.path == route);
    if (!ready()) return _unavailable();
    return coordinator.runStep<Map<String, Object?>>(
      lease: lease,
      stepId: 'store.$action',
      command: (step) async {
        bool authority() {
          try {
            step.checkpoint();
            execution.checkpoint();
            return _attached;
          } catch (_) {
            return false;
          }
        }

        step.checkpoint();
        execution.checkpoint();
        if (!ready()) throw StateError('store_page_unavailable');
        if (search) {
          await catalog.searchAssets(
            arguments['query'] as String,
            arguments['sort'] as String,
            authority,
          );
          step.checkpoint();
          execution.checkpoint();
          if (!ready()) throw StateError('store_page_unavailable');
        } else if (!read) {
          final id = arguments['id'] as String;
          final version = arguments['versionId'] as String;
          if (!catalog.visibleAssets.any(
            (item) => item['id'] == id && item['versionId'] == version,
          )) {
            throw StateError('store_asset_not_visible');
          }
          unawaited(catalog.openAsset(id, version, authority));
        }
        return {
          'section': target.selectedSection,
          'workshop': target.isWorkshop,
          'assets': catalog.visibleAssets,
        };
      },
    );
  }

  void detach() => _attached = false;
  static AgentUiControlResult<Map<String, Object?>> _unavailable() =>
      const AgentUiControlResult.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'The store page is no longer visible.',
      );
}
