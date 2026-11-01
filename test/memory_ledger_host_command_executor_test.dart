import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_controller.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_host_command_executor.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_page_adapter.dart';

void main() {
  test('supports only exact commands for the mounted visible revision', () {
    final harness = _HostHarness();
    addTearDown(harness.dispose);

    expect(harness.executor.supports(_command()), isTrue);

    final mutations = <String, AppControlHostCommand>{
      'action id': _command(actionId: 'app_control.memory_ledger.set_filter'),
      'page action': _command(pageActionId: 'set_filter'),
      'route query': _command(targetRoute: '/memory-ledger?filter=all'),
      'target': _command(target: '/memory-ledger#accept_memory:memory:other'),
      'missing id': _command(
        arguments: const <String, Object?>{
          'expectedHeadEpisodeId': 13,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
        },
      ),
      'extra field': _command(
        arguments: const <String, Object?>{
          'episodeId': 13,
          'expectedHeadEpisodeId': 13,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
          'visibilityToken': 'must-not-cross-backend-boundary',
        },
      ),
      'mismatched head': _command(
        arguments: const <String, Object?>{
          'episodeId': 13,
          'expectedHeadEpisodeId': 14,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
        },
      ),
      'mismatched visible memory': _command(
        arguments: const <String, Object?>{
          'episodeId': 13,
          'expectedHeadEpisodeId': 13,
          'expectedRevision': 3,
          'expectedMemory': 'A different memory.',
        },
      ),
      'non-visible revision': _command(
        arguments: const <String, Object?>{
          'episodeId': 12,
          'expectedHeadEpisodeId': 12,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
        },
      ),
    };
    for (final mutation in mutations.entries) {
      expect(
        harness.executor.supports(mutation.value),
        isFalse,
        reason: mutation.key,
      );
    }
  });

  test('supports only actions exposed for the visible revision state', () {
    final harness = _HostHarness();
    addTearDown(harness.dispose);

    expect(harness.executor.supports(_command()), isTrue);
    expect(
      harness.executor.supports(
        _command(
          actionId: MemoryLedgerHostCommandExecutor.deleteCommandActionId,
          pageActionId: MemoryLedgerPageAdapter.deleteMemoryAction,
          target: '/memory-ledger#delete_memory:memory:ledger',
        ),
      ),
      isFalse,
      reason: 'delete is not a visible pending-memory control',
    );

    harness.target.reviewState = EpisodeReviewState.accepted;
    expect(harness.executor.supports(_command()), isFalse);
    expect(
      harness.executor.supports(
        _command(
          actionId: MemoryLedgerHostCommandExecutor.deleteCommandActionId,
          pageActionId: MemoryLedgerPageAdapter.deleteMemoryAction,
          target: '/memory-ledger#delete_memory:memory:ledger',
        ),
      ),
      isTrue,
    );

    harness.target.isHead = false;
    expect(
      harness.executor.supports(
        _command(
          actionId: MemoryLedgerHostCommandExecutor.deleteCommandActionId,
          pageActionId: MemoryLedgerPageAdapter.deleteMemoryAction,
          target: '/memory-ledger#delete_memory:memory:ledger',
        ),
      ),
      isFalse,
    );
  });

  test(
    'approved execution commits once and forwards typed CAS arguments',
    () async {
      final harness = _HostHarness();
      addTearDown(harness.dispose);
      var committed = 0;
      final context = AppControlActionExecutionContext.host(
        requiresCommit: true,
        authorityIsCurrent: () => true,
        staleCode: 'approval_stale',
        recordExecutionStarted: () {
          committed += 1;
          return true;
        },
      );

      final result = await harness.executor.execute(
        command: _command(),
        executionContext: context,
      );

      expect(result.isSuccess, isTrue);
      expect(result.value, <String, Object?>{
        'status': 'applied',
        'action': 'accept',
        'episodeId': 14,
        'revision': 4,
        'reviewState': 'accepted',
      });
      expect(committed, 1);
      expect(context.commitStarted, isTrue);
      expect(harness.gateway.commands, hasLength(1));
      final forwarded = harness.gateway.commands.single;
      expect(forwarded.action, MemoryGovernanceAction.accept);
      expect(forwarded.targetEpisodeId, 13);
      expect(forwarded.expectedHeadEpisodeId, 13);
      expect(forwarded.expectedRevision, 3);
      expect(forwarded.edit, isNull);
      expect(harness.target.refreshCalls, 1);
    },
  );

  test(
    'edit forwards only the bounded exact text after the Host fence',
    () async {
      final harness = _HostHarness();
      addTearDown(harness.dispose);
      final context = AppControlActionExecutionContext.host(
        requiresCommit: true,
        authorityIsCurrent: () => true,
        staleCode: 'approval_stale',
        recordExecutionStarted: () => true,
      );
      final command = _command(
        actionId: MemoryLedgerHostCommandExecutor.editCommandActionId,
        pageActionId: MemoryLedgerPageAdapter.editMemoryAction,
        target: '/memory-ledger#edit_memory:memory:ledger',
        arguments: const <String, Object?>{
          'episodeId': 13,
          'expectedHeadEpisodeId': 13,
          'expectedRevision': 3,
          'expectedMemory': 'User prefers roasted oolong tea.',
          'exactText': '用户更喜欢焙火乌龙茶',
        },
      );

      final result = await harness.executor.execute(
        command: command,
        executionContext: context,
      );

      expect(result.isSuccess, isTrue);
      expect(
        harness.gateway.commands.single.action,
        MemoryGovernanceAction.edit,
      );
      expect(harness.gateway.commands.single.edit?.what, '用户更喜欢焙火乌龙茶');
    },
  );

  test(
    'detach and authority drift fail closed with zero review calls',
    () async {
      final harness = _HostHarness();
      addTearDown(harness.dispose);
      expect(harness.registration.unregister(), isTrue);
      expect(harness.executor.supports(_command()), isFalse);

      final result = await harness.executor.execute(
        command: _command(),
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: true,
          authorityIsCurrent: () => true,
          staleCode: 'approval_stale',
          recordExecutionStarted: () => true,
        ),
      );

      expect(result.status, AgentUiControlResultStatus.pageNotReady);
      expect(harness.gateway.commands, isEmpty);
    },
  );

  test(
    'retired gateway and account authority drift fail before commit',
    () async {
      final retired = _HostHarness();
      addTearDown(retired.dispose);
      retired.gateway.available = false;
      var retiredCommits = 0;
      final retiredResult = await retired.executor.execute(
        command: _command(),
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: true,
          authorityIsCurrent: () => true,
          staleCode: 'approval_stale',
          recordExecutionStarted: () {
            retiredCommits += 1;
            return true;
          },
        ),
      );
      expect(retiredResult.status, AgentUiControlResultStatus.pageNotReady);
      expect(retired.gateway.commands, isEmpty);
      expect(retiredCommits, 0);

      final drifted = _HostHarness();
      addTearDown(drifted.dispose);
      var checks = 0;
      var driftedCommits = 0;
      final execution = drifted.executor.execute(
        command: _command(),
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: true,
          authorityIsCurrent: () {
            checks += 1;
            if (checks == 1) drifted.gateway.token = Object();
            return true;
          },
          staleCode: 'approval_stale',
          recordExecutionStarted: () {
            driftedCommits += 1;
            return true;
          },
        ),
      );
      await expectLater(
        execution,
        throwsA(
          isA<AppControlActionExecutionException>().having(
            (error) => error.code,
            'code',
            'approval_stale',
          ),
        ),
      );
      expect(drifted.gateway.commands, isEmpty);
      expect(driftedCommits, 0);
    },
  );
}

AppControlHostCommand _command({
  String actionId = MemoryLedgerHostCommandExecutor.acceptCommandActionId,
  String pageActionId = MemoryLedgerPageAdapter.acceptMemoryAction,
  String targetRoute = '/memory-ledger',
  String? target,
  Map<String, Object?>? arguments,
}) => AppControlHostCommand.host(
  actionId: actionId,
  pageActionId: pageActionId,
  targetRoute: targetRoute,
  target:
      target ??
      '$targetRoute#$pageActionId:${MemoryLedgerPageAdapter.semanticTarget}',
  arguments:
      arguments ??
      const <String, Object?>{
        'episodeId': 13,
        'expectedHeadEpisodeId': 13,
        'expectedRevision': 3,
        'expectedMemory': 'User prefers roasted oolong tea.',
      },
);

final class _HostHarness {
  _HostHarness() {
    adapter = MemoryLedgerPageAdapter(
      uiCoordinator: coordinator,
      target: target,
    );
    executor = MemoryLedgerHostCommandExecutor(gateway: gateway);
    registration = executor.attachVisibleAdapter(adapter)!;
  }

  final AgentUiControlCoordinator coordinator = AgentUiControlCoordinator();
  final _FakeTarget target = _FakeTarget();
  final _FakeGateway gateway = _FakeGateway();
  late final MemoryLedgerPageAdapter adapter;
  late final MemoryLedgerHostCommandExecutor executor;
  late final MemoryLedgerHostCommandRegistration registration;

  void dispose() {
    registration.unregister();
    adapter.detach();
    executor.closeLifecycle();
    coordinator.dispose();
  }
}

final class _FakeTarget implements MemoryLedgerPageTarget {
  int refreshCalls = 0;
  bool isHead = true;
  EpisodeReviewState reviewState = EpisodeReviewState.pending;
  EpisodeSourceType sourceType = EpisodeSourceType.runtimeUnknown;

  @override
  bool get isMemoryLedgerPageReady => true;

  @override
  MemoryLedgerFilter get memoryLedgerFilter => MemoryLedgerFilter.all;

  @override
  bool applyMemoryLedgerFilter(MemoryLedgerFilter filter) => true;

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
      expectedMemory == 'User prefers roasted oolong tea.' &&
      MemoryLedgerActionEligibility.allows(
        action: action,
        isHead: isHead,
        reviewState: reviewState,
        sourceType: sourceType,
      );

  @override
  void requestMemoryLedgerRefresh() => refreshCalls += 1;
}

final class _FakeGateway implements MemoryLedgerReviewGateway {
  Object token = Object();
  final List<MemoryGovernanceCommand> commands = <MemoryGovernanceCommand>[];
  bool available = true;

  @override
  Object get authorityToken => token;

  @override
  bool get isAvailable => available;

  @override
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) async {
    commands.add(command);
    return MemoryGovernanceResult(
      status: MemoryGovernanceStatus.applied,
      action: command.action,
      previousEpisodeId: command.expectedHeadEpisodeId,
      episode: Episode(
        id: 14,
        when: DateTime.utc(2026, 8, 30),
        what: command.edit?.what ?? '用户喜欢乌龙茶',
        reviewState: EpisodeReviewState.accepted,
        revision: 4,
        supersedesId: command.expectedHeadEpisodeId,
      ),
    );
  }
}
