import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

import 'memory_ledger_controller.dart';

/// The bounded visible-page authority exposed to Memory Ledger AppControl.
///
/// This interface intentionally contains no persistence callback. Governance
/// writes remain behind the trusted Host command executor.
abstract interface class MemoryLedgerPageTarget {
  bool get isMemoryLedgerPageReady;
  MemoryLedgerFilter get memoryLedgerFilter;

  bool applyMemoryLedgerFilter(MemoryLedgerFilter filter);

  bool canApplyVisibleMemoryAction({
    required MemoryGovernanceAction action,
    required int episodeId,
    required int expectedHeadEpisodeId,
    required int expectedRevision,
    required String expectedMemory,
  });

  void requestMemoryLedgerRefresh();
}

/// Single typed source of truth for governance controls exposed by the page
/// and accepted by the trusted Host executor.
abstract final class MemoryLedgerActionEligibility {
  static List<MemoryGovernanceAction> actionsFor({
    required bool isHead,
    required EpisodeReviewState reviewState,
    required EpisodeSourceType sourceType,
    bool allowsTextEdit = true,
  }) {
    if (!isHead) return const <MemoryGovernanceAction>[];
    final actions = switch ((reviewState, sourceType)) {
      (EpisodeReviewState.pending, _) => const <MemoryGovernanceAction>[
        MemoryGovernanceAction.accept,
        MemoryGovernanceAction.edit,
        MemoryGovernanceAction.reject,
      ],
      (EpisodeReviewState.accepted, EpisodeSourceType.legacyUnknown) =>
        const <MemoryGovernanceAction>[
          MemoryGovernanceAction.accept,
          MemoryGovernanceAction.edit,
          MemoryGovernanceAction.delete,
        ],
      (EpisodeReviewState.accepted, _) => const <MemoryGovernanceAction>[
        MemoryGovernanceAction.edit,
        MemoryGovernanceAction.delete,
      ],
      (EpisodeReviewState.rejected, _) || (EpisodeReviewState.tombstoned, _) =>
        const <MemoryGovernanceAction>[MemoryGovernanceAction.restore],
    };
    return allowsTextEdit
        ? actions
        : actions
              .where((action) => action != MemoryGovernanceAction.edit)
              .toList(growable: false);
  }

  static bool allows({
    required MemoryGovernanceAction action,
    required bool isHead,
    required EpisodeReviewState reviewState,
    required EpisodeSourceType sourceType,
    bool allowsTextEdit = true,
  }) => actionsFor(
    isHead: isHead,
    reviewState: reviewState,
    sourceType: sourceType,
    allowsTextEdit: allowsTextEdit,
  ).contains(action);
}

/// AppControl adapter for the currently mounted Memory Ledger page.
final class MemoryLedgerPageAdapter implements AppControlPageAdapter {
  MemoryLedgerPageAdapter({
    required AgentUiControlCoordinator uiCoordinator,
    required MemoryLedgerPageTarget target,
  }) : _uiCoordinator = uiCoordinator,
       _target = target;

  static const String routePath = AppRouteCatalog.memoryLedger;
  static const String setFilterAction = 'set_filter';
  static const String acceptMemoryAction = 'accept_memory';
  static const String editMemoryAction = 'edit_memory';
  static const String rejectMemoryAction = 'reject_memory';
  static const String deleteMemoryAction = 'delete_memory';
  static const String restoreMemoryAction = 'restore_memory';
  static const String semanticTarget = 'memory:ledger';
  static const String _filterStepId = 'app_control.memory_ledger.set_filter';

  final AgentUiControlCoordinator _uiCoordinator;
  final MemoryLedgerPageTarget _target;
  bool _mounted = true;

  @override
  String get route => routePath;

  bool get isMounted => _mounted;

  static final List<AppControlPageAction>
  _appControlActions = List<AppControlPageAction>.unmodifiable(
    <AppControlPageAction>[
      AppControlPageAction(
        id: setFilterAction,
        description: 'Change the visible Memory Ledger review-state filter.',
        argumentsSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'filter': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'all',
                'needs_review',
                'accepted',
                'rejected',
                'deleted',
              ],
            },
          },
          'required': <String>['filter'],
          'additionalProperties': false,
        },
        resultSchema: const <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'filter': <String, Object?>{
              'type': 'string',
              'enum': <String>[
                'all',
                'needs_review',
                'accepted',
                'rejected',
                'deleted',
              ],
            },
          },
          'required': <String>['filter'],
          'additionalProperties': false,
        },
        risk: ActionRisk.readOnly,
        consequencePolicy: ActionConsequencePolicy.reversible,
      ),
      _governanceAction(
        id: acceptMemoryAction,
        description: 'Accept the exact visible pending memory revision.',
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.destructive,
      ),
      _governanceAction(
        id: editMemoryAction,
        description:
            'Replace the exact visible memory text with an approved revision.',
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.exactTextCommit,
        includesExactText: true,
      ),
      _governanceAction(
        id: rejectMemoryAction,
        description: 'Reject the exact visible memory revision.',
        risk: ActionRisk.destructive,
        consequencePolicy: ActionConsequencePolicy.destructive,
      ),
      _governanceAction(
        id: deleteMemoryAction,
        description: 'Tombstone the exact visible memory revision.',
        risk: ActionRisk.destructive,
        consequencePolicy: ActionConsequencePolicy.destructive,
      ),
      _governanceAction(
        id: restoreMemoryAction,
        description: 'Restore the exact visible rejected or deleted memory.',
        risk: ActionRisk.localMutation,
        consequencePolicy: ActionConsequencePolicy.destructive,
      ),
    ],
  );

  @override
  List<AppControlPageAction> get appControlActions => _appControlActions;

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    if (!_mounted ||
        !_target.isMemoryLedgerPageReady ||
        actionId != setFilterAction) {
      return _pageNotReady();
    }
    if (arguments.length != 1 || !arguments.containsKey('filter')) {
      return const AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'set_filter requires exactly one bounded filter.',
      );
    }
    final filter = MemoryLedgerFilter.fromSemanticId(
      arguments['filter']?.toString() ?? '',
    );
    if (filter == null) {
      return const AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.invalidState,
        message: 'The requested Memory Ledger filter is invalid.',
      );
    }

    final stepped = await _uiCoordinator
        .runStep<AgentUiControlResult<Map<String, Object?>>>(
          lease: lease,
          stepId: _filterStepId,
          command: (context) async {
            context.checkpoint();
            executionContext.checkpoint();
            if (!_mounted ||
                !_target.isMemoryLedgerPageReady ||
                !_target.applyMemoryLedgerFilter(filter)) {
              return _pageNotReady();
            }
            return AgentUiControlResult<Map<String, Object?>>.success(
              <String, Object?>{'filter': filter.semanticId},
            );
          },
        );
    if (!stepped.isSuccess) {
      return stepped.asFailure<Map<String, Object?>>();
    }
    return stepped.value ??
        const AgentUiControlResult<Map<String, Object?>>.failure(
          AgentUiControlResultStatus.executionFailed,
          message: 'The Memory Ledger filter returned no result.',
        );
  }

  bool canApplyVisibleMemoryAction({
    required MemoryGovernanceAction action,
    required int episodeId,
    required int expectedHeadEpisodeId,
    required int expectedRevision,
    required String expectedMemory,
  }) =>
      _mounted &&
      _target.isMemoryLedgerPageReady &&
      _target.canApplyVisibleMemoryAction(
        action: action,
        episodeId: episodeId,
        expectedHeadEpisodeId: expectedHeadEpisodeId,
        expectedRevision: expectedRevision,
        expectedMemory: expectedMemory,
      );

  void requestRefresh() {
    if (_mounted && _target.isMemoryLedgerPageReady) {
      _target.requestMemoryLedgerRefresh();
    }
  }

  void detach() => _mounted = false;

  static AgentUiControlResult<Map<String, Object?>> _pageNotReady() =>
      const AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'The Memory Ledger page is not ready.',
      );
}

AppControlPageAction _governanceAction({
  required String id,
  required String description,
  required ActionRisk risk,
  required ActionConsequencePolicy consequencePolicy,
  bool includesExactText = false,
}) {
  final properties = <String, Object?>{
    'episodeId': _positiveSafeIntegerSchema,
    'expectedHeadEpisodeId': _positiveSafeIntegerSchema,
    'expectedRevision': _positiveSafeIntegerSchema,
    'expectedMemory': const <String, Object?>{
      'type': 'string',
      'minLength': 1,
      'maxLength': 32768,
      'pattern': r'^\S(?:[\s\S]*\S)?$',
    },
    if (includesExactText)
      'exactText': const <String, Object?>{
        'type': 'string',
        'minLength': 1,
        'maxLength': 4096,
        'pattern': r'^\S(?:[\s\S]*\S)?$',
      },
  };
  final required = <String>[
    'episodeId',
    'expectedHeadEpisodeId',
    'expectedRevision',
    'expectedMemory',
    if (includesExactText) 'exactText',
  ];
  return AppControlPageAction(
    id: id,
    description: description,
    argumentsSchema: <String, Object?>{
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    },
    resultSchema: const <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'status': <String, Object?>{'const': 'applied'},
        'action': <String, Object?>{
          'type': 'string',
          'enum': <String>['accept', 'edit', 'reject', 'delete', 'restore'],
        },
        'episodeId': _positiveSafeIntegerSchema,
        'revision': _positiveSafeIntegerSchema,
        'reviewState': <String, Object?>{
          'type': 'string',
          'enum': <String>['pending', 'accepted', 'rejected', 'tombstoned'],
        },
      },
      'required': <String>[
        'status',
        'action',
        'episodeId',
        'revision',
        'reviewState',
      ],
      'additionalProperties': false,
    },
    risk: risk,
    consequencePolicy: consequencePolicy,
    approvalTarget: MemoryLedgerPageAdapter.semanticTarget,
    approvalPresentation: AppControlApprovalPresentationSpec(
      title: 'Confirm this memory change?',
      description:
          'Maaso will append one governed revision to the visible memory.',
      targetLabel: 'Memory Ledger',
      consequenceLabel:
          'This may change what the Agent can recall in future replies.',
      exactTextArgumentKey: includesExactText ? 'exactText' : null,
      argumentFields: const <AppControlApprovalArgumentSpec>[
        AppControlApprovalArgumentSpec(
          argumentKey: 'episodeId',
          label: 'Visible episode',
        ),
        AppControlApprovalArgumentSpec(
          argumentKey: 'expectedHeadEpisodeId',
          label: 'Expected lineage head',
        ),
        AppControlApprovalArgumentSpec(
          argumentKey: 'expectedRevision',
          label: 'Expected revision',
        ),
        AppControlApprovalArgumentSpec(
          argumentKey: 'expectedMemory',
          label: 'Visible memory',
          maxDisplayRunes: 32768,
        ),
      ],
    ),
  );
}

const Map<String, Object?> _positiveSafeIntegerSchema = <String, Object?>{
  'type': 'integer',
  'minimum': 1,
  'maximum': 9007199254740991,
};
