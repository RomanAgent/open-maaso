import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_host.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_envelope.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/host_skill_routing_manifest.dart';
import 'package:maaso/src/features/agent/application/skill_routing/lazy_host_skill_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_route_decision.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_host_command_router.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_controller.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_host_command_executor.dart';
import 'package:maaso/src/features/memory/application/memory_ledger_page_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
  });

  tearDown(appServices.reset);

  for (final testCase in _ledgerApprovalCases) {
    group(testCase.pageActionId, () {
      test('reject performs zero reviews', () async {
        final harness = _LedgerApprovalHarness.create();
        addTearDown(harness.dispose);

        final execution = harness.executeStructured(testCase);
        final prompt = await harness.host.nextPrompt;
        _expectPrompt(prompt, testCase);
        harness.host.decide(ActionApprovalDecision.reject);
        final response = _structuredResponse(await execution);

        expect(response['error'], 'approval_rejected');
        expect(harness.gateway.commands, isEmpty);
        expect(harness.target.visibilityChecks, greaterThan(0));
        expect(harness.target.refreshCalls, 0);
        expect(
          harness.auditEntries.where(
            (entry) => entry.stage == ActionAuditStage.executed,
          ),
          isEmpty,
        );
      });

      test('no decision performs zero reviews', () async {
        final harness = _LedgerApprovalHarness.create(
          approvalTtl: const Duration(milliseconds: 25),
        );
        addTearDown(harness.dispose);

        final execution = harness.executeStructured(testCase);
        final prompt = await harness.host.nextPrompt;
        _expectPrompt(prompt, testCase);
        await harness.host.dismissed;
        final response = _structuredResponse(await execution);

        expect(response['error'], 'approval_unavailable');
        expect(harness.host.cancellationReason, 'approval.timeout');
        expect(harness.gateway.commands, isEmpty);
        expect(harness.target.visibilityChecks, greaterThan(0));
        expect(harness.target.refreshCalls, 0);
        expect(
          harness.auditEntries.where(
            (entry) => entry.stage == ActionAuditStage.executed,
          ),
          isEmpty,
        );
      });

      test('user takeover performs zero reviews', () async {
        final harness = _LedgerApprovalHarness.create();
        addTearDown(harness.dispose);

        final execution = harness.executeStructured(testCase);
        final prompt = await harness.host.nextPrompt;
        _expectPrompt(prompt, testCase);
        expect(
          harness.coordinator.pauseForUserActivity(
            reason: 'memory_ledger_user_input',
          ),
          isTrue,
        );
        await harness.host.dismissed;
        final response = _structuredResponse(await execution);

        expect(response['error'], 'approval_stale');
        expect(harness.gateway.commands, isEmpty);
        expect(harness.target.visibilityChecks, greaterThan(0));
        expect(harness.target.refreshCalls, 0);
        expect(
          harness.auditEntries.where(
            (entry) => entry.stage == ActionAuditStage.executed,
          ),
          isEmpty,
        );
      });

      test('allow once performs exactly one typed CAS review', () async {
        final harness = _LedgerApprovalHarness.create();
        addTearDown(harness.dispose);

        final execution = harness.executeStructured(testCase);
        final prompt = await harness.host.nextPrompt;
        _expectPrompt(prompt, testCase);
        harness.host.decide(ActionApprovalDecision.allowOnce);
        final response = _structuredResponse(await execution);

        expect(response['status'], 'ok');
        expect(response['page'], 'memory_ledger');
        expect(response['route'], '/memory-ledger');
        expect(response['action'], testCase.pageActionId);
        expect(harness.gateway.commands, hasLength(1));
        final command = harness.gateway.commands.single;
        expect(command.action, testCase.action);
        expect(command.targetEpisodeId, 13);
        expect(command.expectedHeadEpisodeId, 13);
        expect(command.expectedRevision, 3);
        expect(command.edit?.what, testCase.exactText);
        expect(harness.target.visibilityChecks, greaterThan(0));
        expect(harness.target.refreshCalls, 1);
      });
    });
  }

  test('long canonical Master memory remains visible in approval', () async {
    final longMemory = jsonEncode(<String, Object?>{
      'schemaVersion': 1,
      'name': null,
      'pronouns': null,
      'age': null,
      'notes': List<String>.filled(3000, '\\').join(),
    });
    expect(longMemory.runes.length, greaterThan(4096));
    final harness = _LedgerApprovalHarness.create(expectedMemory: longMemory);
    addTearDown(harness.dispose);
    final testCase = _LedgerApprovalCase(
      pageActionId: MemoryLedgerPageAdapter.acceptMemoryAction,
      action: MemoryGovernanceAction.accept,
      arguments: <String, Object?>{
        'episodeId': 13,
        'expectedHeadEpisodeId': 13,
        'expectedRevision': 3,
        'expectedMemory': longMemory,
      },
    );

    final execution = harness.executeStructured(testCase);
    final prompt = await harness.host.nextPrompt;
    expect(prompt.presentation.argumentFields.last.value, longMemory);
    harness.host.decide(ActionApprovalDecision.allowOnce);
    final response = _structuredResponse(await execution);

    expect(response['status'], 'ok');
    expect(harness.gateway.commands, hasLength(1));
  });
}

void _expectPrompt(ActionApprovalPrompt prompt, _LedgerApprovalCase testCase) {
  expect(prompt.actionId, 'app_control.memory_ledger.${testCase.pageActionId}');
  expect(prompt.presentation.targetLabel, 'Memory Ledger');
  expect(
    prompt.presentation.argumentFields.map((field) => field.value),
    <String>['13', '13', '3', 'User prefers roasted oolong tea.'],
  );
  expect(prompt.presentation.exactText, testCase.exactText);
}

Map<String, Object?> _structuredResponse(AgentActionExecutionResult result) {
  expect(result.observations, hasLength(1));
  final observation = result.observations.single;
  final marker = observation.indexOf('=> ');
  expect(marker, greaterThanOrEqualTo(0));
  return Map<String, Object?>.from(
    jsonDecode(observation.substring(marker + 3)) as Map,
  );
}

final class _LedgerApprovalHarness {
  _LedgerApprovalHarness._({
    required this.scopes,
    required this.mount,
    required this.coordinator,
    required this.uiControl,
    required this.host,
    required this.auditLog,
    required this.auditScope,
    required this.target,
    required this.gateway,
    required this.ledgerExecutor,
    required this.adapter,
    required this.registry,
    required this.executor,
    required this.tool,
    required this.pageRegistration,
    required this.hostRegistration,
  });

  factory _LedgerApprovalHarness.create({
    Duration approvalTtl = const Duration(seconds: 45),
    String expectedMemory = 'User prefers roasted oolong tea.',
  }) {
    final scopes = appServices.put(AccountStorageScopeService());
    final mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'ledger-a'),
    );
    final coordinator = AgentUiControlCoordinator();
    final uiControl = AgentUiControlService(coordinator: coordinator);
    final host = _LedgerApprovalHost();
    final auditLog = ActionAuditLog();
    final auditScope = ActionAuditScope(
      accountScope: mount.scope.storageNamespace,
      agentId: 'self',
      runtimeGeneration: mount.generation,
    );
    final target = _LedgerTarget(expectedMemory);
    final gateway = _LedgerGateway();
    final ledgerExecutor = MemoryLedgerHostCommandExecutor(gateway: gateway);
    final adapter = MemoryLedgerPageAdapter(
      uiCoordinator: coordinator,
      target: target,
    );
    PageAgentAdapterRegistration<MemoryLedgerPageAdapter>? pageRegistration;
    MemoryLedgerHostCommandRegistration? hostRegistration;
    final navigation = _LedgerNavigation(
      onPush: (route) {
        if (route != '/memory-ledger') return;
        pageRegistration ??= uiControl.adapters.register(adapter);
        hostRegistration ??= ledgerExecutor.attachVisibleAdapter(adapter);
      },
    );
    final hostRouter = AppControlHostCommandRouter(
      <AppControlHostCommandExecutor>[ledgerExecutor],
    );
    final skill = AppControlSkill(
      navigation: navigation,
      uiControl: uiControl,
      approvalService: ActionApprovalService(),
      approvalHost: host,
      auditLog: auditLog,
      hostCommandExecutor: hostRouter,
      now: () => DateTime.utc(2026, 8, 30, 12),
      approvalTtl: approvalTtl,
      routeReadinessBarrier: () async {},
      routeReadinessTimeout: const Duration(milliseconds: 200),
    );
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: <SkillSpec>[
        SkillSpec(
          id: 'memory_ledger_app_control_test',
          name: 'Memory Ledger AppControl test',
          description: skill.description,
          icon: Icons.fact_check_outlined,
          color: Colors.blue,
          category: SkillCategory.core,
          isCore: true,
          factory: (_) => skill,
          hostRouting: HostSkillRoutingManifest(
            skillName: skill.skillName,
            summary: skill.description,
            methods: skill.methods.keys,
            nativeMethods: skill.nativeToolSchemas.keys,
            terms: const <String>['memory ledger'],
          ),
        ),
      ],
    );
    final descriptor = registry.descriptorFor(skill.skillName)!;
    final grant = registry.issueGrant(
      TurnSkillGrant.bounded(
        rankedDescriptors: <SkillDescriptor>[descriptor],
        maxSkills: 1,
        promptBudget: 2048,
      ),
    );
    final activated = grant.activatedSkills.single as AppControlSkill;
    final manager = SkillManager()..registerSkill(activated);
    final tool = SkillManager.nativeToolName(activated, 'execute');
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: grant,
    );
    return _LedgerApprovalHarness._(
      scopes: scopes,
      mount: mount,
      coordinator: coordinator,
      uiControl: uiControl,
      host: host,
      auditLog: auditLog,
      auditScope: auditScope,
      target: target,
      gateway: gateway,
      ledgerExecutor: ledgerExecutor,
      adapter: adapter,
      registry: registry,
      executor: executor,
      tool: tool,
      pageRegistration: () => pageRegistration,
      hostRegistration: () => hostRegistration,
    );
  }

  final AccountStorageScopeService scopes;
  final AccountStorageScopeMount mount;
  final AgentUiControlCoordinator coordinator;
  final AgentUiControlService uiControl;
  final _LedgerApprovalHost host;
  final ActionAuditLog auditLog;
  final ActionAuditScope auditScope;
  final _LedgerTarget target;
  final _LedgerGateway gateway;
  final MemoryLedgerHostCommandExecutor ledgerExecutor;
  final MemoryLedgerPageAdapter adapter;
  final LazyHostSkillRegistry registry;
  final AgentActionExecutor executor;
  final String tool;
  final PageAgentAdapterRegistration<MemoryLedgerPageAdapter>? Function()
  pageRegistration;
  final MemoryLedgerHostCommandRegistration? Function() hostRegistration;

  List<ActionAuditEntry> get auditEntries =>
      auditLog.query(scope: auditScope, limit: 100);

  Future<AgentActionExecutionResult> executeStructured(
    _LedgerApprovalCase testCase,
  ) => executor.execute(
    AgentActionEnvelope(
      reply: '',
      actions: <AgentAction>[
        AgentAction(
          type: 'skill.call',
          data: <String, Object?>{
            'tool': tool,
            'args': <String, Object?>{
              'page': 'memory_ledger',
              'action': testCase.pageActionId,
              'arguments': testCase.arguments,
            },
          },
        ),
      ],
    ),
  );

  Future<void> dispose() async {
    hostRegistration()?.unregister();
    adapter.detach();
    pageRegistration()?.unregister();
    registry.invalidate();
    ledgerExecutor.closeLifecycle();
    scopes.unmount(mount);
    await coordinator.dispose();
  }
}

final class _LedgerNavigation extends AppNavigation {
  _LedgerNavigation({required this.onPush});

  final void Function(String route) onPush;
  final Completer<Object?> _pendingPush = Completer<Object?>();
  String _currentRoute = '/home';

  @override
  bool get isConfigured => true;

  @override
  String get currentRoute => _currentRoute;

  @override
  Future<T?> push<T extends Object?>(String route, {Object? extra}) {
    _currentRoute = route;
    onPush(route);
    return _pendingPush.future.then<T?>((value) => value as T?);
  }
}

final class _LedgerApprovalHost
    implements ActionApprovalHost, ActionApprovalSession {
  final Completer<ActionApprovalPrompt> _prompt =
      Completer<ActionApprovalPrompt>();
  final Completer<ActionApprovalDecision> _decision =
      Completer<ActionApprovalDecision>();
  final Completer<void> _dismissed = Completer<void>();
  bool _visible = false;
  String? cancellationReason;

  Future<ActionApprovalPrompt> get nextPrompt => _prompt.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () => throw TimeoutException('approval prompt was not shown'),
  );

  Future<void> get dismissed => _dismissed.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () => throw TimeoutException('approval was not dismissed'),
  );

  void decide(ActionApprovalDecision decision) {
    _visible = false;
    if (!_decision.isCompleted) _decision.complete(decision);
    if (!_dismissed.isCompleted) _dismissed.complete();
  }

  @override
  Future<ActionApprovalDecision> get decision => _decision.future;

  @override
  Future<void> get whenAllDismissed =>
      _visible ? _dismissed.future : Future<void>.value();

  @override
  ActionApprovalSession present(ActionApprovalPrompt prompt) {
    _visible = true;
    if (!_prompt.isCompleted) _prompt.complete(prompt);
    return this;
  }

  @override
  Future<void> dismiss(ActionApprovalCancellationReason reason) async {
    cancellationReason = reason.code;
    _clear();
  }

  @override
  Future<void> dismissAll(ActionApprovalCancellationReason reason) async {
    cancellationReason = reason.code;
    _clear();
  }

  void _clear() {
    _visible = false;
    if (!_dismissed.isCompleted) _dismissed.complete();
    if (!_decision.isCompleted) {
      _decision.complete(ActionApprovalDecision.cancel);
    }
  }
}

final class _LedgerTarget implements MemoryLedgerPageTarget {
  _LedgerTarget(this.expectedMemory);

  final String expectedMemory;
  int visibilityChecks = 0;
  int refreshCalls = 0;

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
  }) {
    visibilityChecks += 1;
    return episodeId == 13 &&
        expectedHeadEpisodeId == 13 &&
        expectedRevision == 3 &&
        expectedMemory == this.expectedMemory;
  }

  @override
  void requestMemoryLedgerRefresh() => refreshCalls += 1;
}

final class _LedgerGateway implements MemoryLedgerReviewGateway {
  final Object _authority = Object();
  final List<MemoryGovernanceCommand> commands = <MemoryGovernanceCommand>[];

  @override
  Object get authorityToken => _authority;

  @override
  bool get isAvailable => true;

  @override
  Future<MemoryGovernanceResult> review(MemoryGovernanceCommand command) async {
    commands.add(command);
    final reviewState = switch (command.action) {
      MemoryGovernanceAction.reject => EpisodeReviewState.rejected,
      MemoryGovernanceAction.delete => EpisodeReviewState.tombstoned,
      _ => EpisodeReviewState.accepted,
    };
    return MemoryGovernanceResult(
      status: MemoryGovernanceStatus.applied,
      action: command.action,
      previousEpisodeId: command.expectedHeadEpisodeId,
      episode: Episode(
        id: 14,
        when: DateTime.utc(2026, 8, 30),
        what: command.edit?.what ?? 'User prefers roasted oolong tea.',
        reviewState: reviewState,
        revision: 4,
        supersedesId: command.expectedHeadEpisodeId,
      ),
    );
  }
}

final class _LedgerApprovalCase {
  const _LedgerApprovalCase({
    required this.pageActionId,
    required this.action,
    required this.arguments,
    this.exactText,
  });

  final String pageActionId;
  final MemoryGovernanceAction action;
  final Map<String, Object?> arguments;
  final String? exactText;
}

const List<_LedgerApprovalCase> _ledgerApprovalCases = <_LedgerApprovalCase>[
  _LedgerApprovalCase(
    pageActionId: MemoryLedgerPageAdapter.acceptMemoryAction,
    action: MemoryGovernanceAction.accept,
    arguments: <String, Object?>{
      'episodeId': 13,
      'expectedHeadEpisodeId': 13,
      'expectedRevision': 3,
      'expectedMemory': 'User prefers roasted oolong tea.',
    },
  ),
  _LedgerApprovalCase(
    pageActionId: MemoryLedgerPageAdapter.editMemoryAction,
    action: MemoryGovernanceAction.edit,
    arguments: <String, Object?>{
      'episodeId': 13,
      'expectedHeadEpisodeId': 13,
      'expectedRevision': 3,
      'expectedMemory': 'User prefers roasted oolong tea.',
      'exactText': '用户更喜欢焙火乌龙茶',
    },
    exactText: '用户更喜欢焙火乌龙茶',
  ),
  _LedgerApprovalCase(
    pageActionId: MemoryLedgerPageAdapter.rejectMemoryAction,
    action: MemoryGovernanceAction.reject,
    arguments: <String, Object?>{
      'episodeId': 13,
      'expectedHeadEpisodeId': 13,
      'expectedRevision': 3,
      'expectedMemory': 'User prefers roasted oolong tea.',
    },
  ),
  _LedgerApprovalCase(
    pageActionId: MemoryLedgerPageAdapter.deleteMemoryAction,
    action: MemoryGovernanceAction.delete,
    arguments: <String, Object?>{
      'episodeId': 13,
      'expectedHeadEpisodeId': 13,
      'expectedRevision': 3,
      'expectedMemory': 'User prefers roasted oolong tea.',
    },
  ),
  _LedgerApprovalCase(
    pageActionId: MemoryLedgerPageAdapter.restoreMemoryAction,
    action: MemoryGovernanceAction.restore,
    arguments: <String, Object?>{
      'episodeId': 13,
      'expectedHeadEpisodeId': 13,
      'expectedRevision': 3,
      'expectedMemory': 'User prefers roasted oolong tea.',
    },
  ),
];
