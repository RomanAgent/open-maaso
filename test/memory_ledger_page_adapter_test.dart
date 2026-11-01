import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_controller.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_host_command_executor.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_page_adapter.dart';
import 'package:maaso/src/features/memory/presentation/memory_ledger_page_adapter_scope.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'declares one safe filter and five approval-gated governance actions',
    () {
      final coordinator = AgentUiControlCoordinator();
      addTearDown(coordinator.dispose);
      final adapter = MemoryLedgerPageAdapter(
        uiCoordinator: coordinator,
        target: _FakeLedgerTarget(),
      );

      expect(adapter.appControlActions.map((action) => action.id), <String>[
        MemoryLedgerPageAdapter.setFilterAction,
        MemoryLedgerPageAdapter.acceptMemoryAction,
        MemoryLedgerPageAdapter.editMemoryAction,
        MemoryLedgerPageAdapter.rejectMemoryAction,
        MemoryLedgerPageAdapter.deleteMemoryAction,
        MemoryLedgerPageAdapter.restoreMemoryAction,
      ]);

      final filter = adapter.actionById(
        MemoryLedgerPageAdapter.setFilterAction,
      )!;
      expect(filter.risk, ActionRisk.readOnly);
      expect(filter.consequencePolicy, ActionConsequencePolicy.reversible);
      expect(filter.requiresApproval, isFalse);
      expect(filter.argumentsSchema['additionalProperties'], isFalse);

      for (final action in adapter.appControlActions.skip(1)) {
        expect(action.requiresApproval, isTrue, reason: action.id);
        expect(action.approvalPresentation, isNotNull, reason: action.id);
        expect(action.argumentsSchema['additionalProperties'], isFalse);
        expect(action.resultSchema['additionalProperties'], isFalse);
      }

      final accept = adapter.actionById(
        MemoryLedgerPageAdapter.acceptMemoryAction,
      )!;
      final acceptProperties = accept.argumentsSchema['properties'] as Map;
      expect(acceptProperties.keys, <String>[
        'episodeId',
        'expectedHeadEpisodeId',
        'expectedRevision',
        'expectedMemory',
      ]);
      expect(
        accept.resolveApprovalPresentation(const <String, Object?>{
          'episodeId': 13,
          'expectedHeadEpisodeId': 13,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
        }),
        isNotNull,
      );

      final edit = adapter.actionById(
        MemoryLedgerPageAdapter.editMemoryAction,
      )!;
      final editProperties = edit.argumentsSchema['properties'] as Map;
      expect(editProperties.keys, <String>[
        'episodeId',
        'expectedHeadEpisodeId',
        'expectedRevision',
        'expectedMemory',
        'exactText',
      ]);
      expect(
        edit.resolveApprovalPresentation(const <String, Object?>{
          'episodeId': 13,
          'expectedHeadEpisodeId': 13,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
          'exactText': '用户更喜欢焙火乌龙茶',
        }),
        isNotNull,
      );
    },
  );

  test('uses one typed eligibility matrix for visible governance actions', () {
    final cases =
        <
          ({
            bool isHead,
            EpisodeReviewState reviewState,
            EpisodeSourceType sourceType,
            List<MemoryGovernanceAction> expected,
          })
        >[
          (
            isHead: true,
            reviewState: EpisodeReviewState.pending,
            sourceType: EpisodeSourceType.runtimeUnknown,
            expected: const <MemoryGovernanceAction>[
              MemoryGovernanceAction.accept,
              MemoryGovernanceAction.edit,
              MemoryGovernanceAction.reject,
            ],
          ),
          (
            isHead: true,
            reviewState: EpisodeReviewState.accepted,
            sourceType: EpisodeSourceType.legacyUnknown,
            expected: const <MemoryGovernanceAction>[
              MemoryGovernanceAction.accept,
              MemoryGovernanceAction.edit,
              MemoryGovernanceAction.delete,
            ],
          ),
          (
            isHead: true,
            reviewState: EpisodeReviewState.accepted,
            sourceType: EpisodeSourceType.runtimeUnknown,
            expected: const <MemoryGovernanceAction>[
              MemoryGovernanceAction.edit,
              MemoryGovernanceAction.delete,
            ],
          ),
          (
            isHead: true,
            reviewState: EpisodeReviewState.rejected,
            sourceType: EpisodeSourceType.runtimeUnknown,
            expected: const <MemoryGovernanceAction>[
              MemoryGovernanceAction.restore,
            ],
          ),
          (
            isHead: true,
            reviewState: EpisodeReviewState.tombstoned,
            sourceType: EpisodeSourceType.runtimeUnknown,
            expected: const <MemoryGovernanceAction>[
              MemoryGovernanceAction.restore,
            ],
          ),
          (
            isHead: false,
            reviewState: EpisodeReviewState.pending,
            sourceType: EpisodeSourceType.runtimeUnknown,
            expected: const <MemoryGovernanceAction>[],
          ),
        ];

    for (final testCase in cases) {
      final actions = MemoryLedgerActionEligibility.actionsFor(
        isHead: testCase.isHead,
        reviewState: testCase.reviewState,
        sourceType: testCase.sourceType,
      );
      expect(actions, testCase.expected, reason: '$testCase');
      for (final action in MemoryGovernanceAction.values) {
        expect(
          MemoryLedgerActionEligibility.allows(
            action: action,
            isHead: testCase.isHead,
            reviewState: testCase.reviewState,
            sourceType: testCase.sourceType,
          ),
          testCase.expected.contains(action),
          reason: '$testCase / ${action.name}',
        );
      }
    }
  });

  test('set_filter changes only the visible page filter', () async {
    final coordinator = AgentUiControlCoordinator();
    addTearDown(coordinator.dispose);
    final target = _FakeLedgerTarget();
    final registry = PageAgentAdapterRegistry(coordinator: coordinator);
    registry.register(
      MemoryLedgerPageAdapter(uiCoordinator: coordinator, target: target),
    );
    final lease = coordinator
        .begin(
          sessionId: 'ledger-filter',
          purpose: 'show pending memory',
          targetRoute: '/memory-ledger',
        )
        .value!;
    final resolved = registry.resolve<MemoryLedgerPageAdapter>(
      route: '/memory-ledger',
      lease: lease,
    );

    final result = await resolved.value!.executeAppControlAction(
      lease: lease,
      actionId: MemoryLedgerPageAdapter.setFilterAction,
      arguments: const <String, Object?>{'filter': 'needs_review'},
      executionContext: AppControlActionExecutionContext.host(
        requiresCommit: false,
        authorityIsCurrent: () => true,
        staleCode: 'ui_control_stale',
      ),
    );

    expect(result.isSuccess, isTrue);
    expect(result.value, const <String, Object?>{'filter': 'needs_review'});
    expect(target.filter, MemoryLedgerFilter.needsReview);
    expect(target.governanceCalls, 0);
  });

  test('wrong route and takeover prevent page operations', () async {
    final coordinator = AgentUiControlCoordinator();
    addTearDown(coordinator.dispose);
    final target = _FakeLedgerTarget();
    final registry = PageAgentAdapterRegistry(coordinator: coordinator);
    final adapter = MemoryLedgerPageAdapter(
      uiCoordinator: coordinator,
      target: target,
    );
    registry.register(adapter);
    final wrongRoute = coordinator
        .begin(
          sessionId: 'ledger-wrong-route',
          purpose: 'filter memory',
          targetRoute: '/settings',
        )
        .value!;

    expect(
      registry
          .resolve<MemoryLedgerPageAdapter>(
            route: '/memory-ledger',
            lease: wrongRoute,
          )
          .status,
      AgentUiControlResultStatus.pageNotReady,
    );
    expect(coordinator.pauseForUserActivity(reason: 'pointer_down'), isTrue);

    final paused = await adapter.executeAppControlAction(
      lease: wrongRoute,
      actionId: MemoryLedgerPageAdapter.setFilterAction,
      arguments: const <String, Object?>{'filter': 'accepted'},
      executionContext: AppControlActionExecutionContext.host(
        requiresCommit: false,
        authorityIsCurrent: () => true,
        staleCode: 'ui_control_stale',
      ),
    );
    expect(paused.status, AgentUiControlResultStatus.pausedByUser);
    expect(target.filter, MemoryLedgerFilter.all);
  });

  testWidgets('route scope registers and unregisters the exact adapter', (
    tester,
  ) async {
    final coordinator = AgentUiControlCoordinator();
    final uiControl = AgentUiControlService(coordinator: coordinator);
    final target = _FakeLedgerTarget();
    final host = MemoryLedgerHostCommandExecutor(gateway: _ScopeGateway());

    await tester.pumpWidget(
      MaterialApp(
        home: MemoryLedgerPageAdapterScope(
          uiControl: uiControl,
          hostCommandExecutor: host,
          target: target,
          child: const SizedBox.shrink(),
        ),
      ),
    );
    expect(uiControl.adapters.length, 1);
    expect(host.supports(_visibleCommand()), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(uiControl.adapters.length, 0);
    expect(host.supports(_visibleCommand()), isFalse);

    host.closeLifecycle();
    await coordinator.dispose();
  });
}

AppControlHostCommand _visibleCommand() => AppControlHostCommand.host(
  actionId: MemoryLedgerHostCommandExecutor.acceptCommandActionId,
  pageActionId: MemoryLedgerPageAdapter.acceptMemoryAction,
  targetRoute: '/memory-ledger',
  target: '/memory-ledger#accept_memory:memory:ledger',
  arguments: const <String, Object?>{
    'episodeId': 13,
    'expectedHeadEpisodeId': 13,
    'expectedRevision': 3,
    'expectedMemory': 'User prefers roasted oolong tea.',
  },
);

final class _FakeLedgerTarget implements MemoryLedgerPageTarget {
  MemoryLedgerFilter filter = MemoryLedgerFilter.all;
  int governanceCalls = 0;

  @override
  bool get isMemoryLedgerPageReady => true;

  @override
  MemoryLedgerFilter get memoryLedgerFilter => filter;

  @override
  bool applyMemoryLedgerFilter(MemoryLedgerFilter next) {
    filter = next;
    return true;
  }

  @override
  bool canApplyVisibleMemoryAction({
    required MemoryGovernanceAction action,
    required int episodeId,
    required int expectedHeadEpisodeId,
    required int expectedRevision,
    required String expectedMemory,
  }) =>
      episodeId == 13 &&
      expectedHeadEpisodeId == 13 &&
      expectedRevision == 3 &&
      expectedMemory == 'User prefers roasted oolong tea.';

  @override
  void requestMemoryLedgerRefresh() {}
}

final class _ScopeGateway implements MemoryLedgerReviewGateway {
  final Object _token = Object();

  @override
  Object get authorityToken => _token;

  @override
  bool get isAvailable => true;

  @override
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) =>
      throw UnsupportedError('scope lifecycle test does not execute writes');
}
