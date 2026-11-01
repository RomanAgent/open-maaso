import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_host.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/action_definition.dart';
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
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
  });

  tearDown(appServices.reset);

  test(
    'structured allowOnce executes and records the complete audit lifecycle',
    () async {
      final harness = _ApprovalHarness.create();
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      final prompt = await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      final result = await execution;
      final response = _structuredResponse(result);

      expect(result.ok, isTrue);
      expect(response['status'], 'ok');
      expect(response['accepted'], isTrue);
      expect(harness.totalHandlerCalls, 1);
      expect(harness.host.calls, 1);
      expect(prompt.actionId, 'app_control.widgets_hub.commit_post');
      expect(prompt.presentation.title, 'Publish exact post');
      expect(prompt.presentation.targetLabel, 'Public feed');
      expect(prompt.presentation.exactText, 'safe');
      expect(
        <String>[
          prompt.actionId,
          prompt.fingerprint,
          prompt.presentation.title,
          prompt.presentation.description,
          prompt.presentation.targetLabel,
          prompt.presentation.consequenceLabel,
          prompt.presentation.exactText!,
        ].join('|'),
        isNot(contains('feed-public')),
      );

      final entries = harness.auditEntries;
      expect(entries.map((entry) => entry.stage), <ActionAuditStage>[
        ActionAuditStage.asked,
        ActionAuditStage.decided,
        ActionAuditStage.executed,
        ActionAuditStage.result,
      ]);
      expect(entries.map((entry) => entry.outcome), <ActionAuditOutcome>[
        ActionAuditOutcome.proposed,
        ActionAuditOutcome.allowed,
        ActionAuditOutcome.started,
        ActionAuditOutcome.succeeded,
      ]);
      expect(entries.map((entry) => entry.auditId).toSet(), hasLength(1));
      expect(
        entries.every(
          (entry) => RegExp(r'^[0-9a-f]{64}$').hasMatch(entry.target),
        ),
        isTrue,
      );
      expect(
        entries.every((entry) => !entry.target.contains('feed-public')),
        isTrue,
      );
      expect(response['auditId'], entries.first.auditId);
      expect(harness.commandExecutor.capturedContext?.isCurrent, isFalse);
    },
  );

  test(
    'direct AppControl invocation cannot borrow injected approval services',
    () async {
      final harness = _ApprovalHarness.create();
      addTearDown(harness.dispose);

      final response = await harness.executeDirect();

      expect(response, <String, Object?>{
        'status': 'error',
        'error': 'approval_unavailable',
      });
      expect(harness.host.calls, 0);
      expect(harness.auditEntries, isEmpty);
      expect(harness.totalHandlerCalls, 0);
    },
  );

  test('consequential action without a Host executor fails closed', () async {
    final harness = _ApprovalHarness.create(provideHostCommandExecutor: false);
    addTearDown(harness.dispose);

    final response = _structuredResponse(await harness.executeStructured());

    expect(response['error'], 'approval_required');
    expect(harness.host.calls, 0);
    expect(harness.auditEntries, isEmpty);
    expect(harness.totalHandlerCalls, 0);
    expect(harness.adapters.single.executeCalls, 0);
  });

  for (final decision in <ActionApprovalDecision>[
    ActionApprovalDecision.reject,
    ActionApprovalDecision.cancel,
  ]) {
    test('$decision does not execute the approved page action', () async {
      final harness = _ApprovalHarness.create();
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(decision);
      final response = _structuredResponse(await execution);

      expect(
        response['error'],
        decision == ActionApprovalDecision.reject
            ? 'approval_rejected'
            : 'approval_cancelled',
      );
      expect(harness.totalHandlerCalls, 0);
      expect(
        harness.auditEntries.map((entry) => entry.stage),
        <ActionAuditStage>[ActionAuditStage.asked, ActionAuditStage.decided],
      );
    });
  }

  test(
    'account switch immediately dismisses the old approval prompt',
    () async {
      final harness = _ApprovalHarness.create();
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      expect(harness.host.promptVisible, isTrue);
      await harness.switchAccount();
      await harness.host.dismissed;
      _expectRevokedStructuredResult(await execution, harness);

      expect(harness.host.promptVisible, isFalse);
      expect(harness.host.cancellationReason, 'approval.stale');
      expect(harness.totalHandlerCalls, 0);
      expect(harness.auditEntries.last.stage, ActionAuditStage.decided);
      expect(harness.auditEntries.last.outcome, ActionAuditOutcome.cancelled);
    },
  );

  test(
    'Host grant invalidation dismisses approval and prevents execution',
    () async {
      final harness = _ApprovalHarness.create();
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.registry.invalidate();
      await harness.host.dismissed;
      _expectRevokedStructuredResult(await execution, harness);

      expect(harness.host.promptVisible, isFalse);
      expect(harness.totalHandlerCalls, 0);
    },
  );

  test(
    'adapter replacement during approval prevents TOCTOU execution',
    () async {
      final harness = _ApprovalHarness.create();
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.replaceAdapter();
      await harness.host.dismissed;
      final response = _structuredResponse(await execution);

      expect(response['error'], 'approval_stale');
      expect(harness.totalHandlerCalls, 0);
    },
  );

  test('a Host that never decides is cancelled at the approval TTL', () async {
    final harness = _ApprovalHarness.create(
      approvalTtl: const Duration(milliseconds: 25),
    );
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    await harness.host.dismissed;
    final response = _structuredResponse(await execution);

    expect(response['error'], 'approval_unavailable');
    expect(harness.host.cancellationReason, 'approval.timeout');
    expect(harness.host.promptVisible, isFalse);
    expect(harness.totalHandlerCalls, 0);
  });

  test(
    'account switch during async preparation blocks the commit point',
    () async {
      final gate = Completer<void>();
      final harness = _ApprovalHarness.create(preparationGate: gate);
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      await harness.commandExecutor.preparationStarted.future;
      await harness.switchAccount();
      gate.complete();
      _expectRevokedStructuredResult(await execution, harness);

      expect(harness.totalHandlerCalls, 0);
      expect(harness.auditEntries.last.stage, ActionAuditStage.result);
      expect(harness.auditEntries.last.code, 'execution.fence_rejected');
      expect(
        harness.auditEntries.where(
          (entry) => entry.stage == ActionAuditStage.executed,
        ),
        isEmpty,
      );
    },
  );

  test(
    'grant revocation during async preparation blocks the commit point',
    () async {
      final gate = Completer<void>();
      final harness = _ApprovalHarness.create(preparationGate: gate);
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      await harness.commandExecutor.preparationStarted.future;
      harness.registry.invalidate();
      gate.complete();
      _expectRevokedStructuredResult(await execution, harness);

      expect(harness.totalHandlerCalls, 0);
      expect(harness.auditEntries.last.stage, ActionAuditStage.result);
      expect(harness.auditEntries.last.code, 'execution.fence_rejected');
    },
  );

  test('consequential handlers that skip commit fail closed', () async {
    final harness = _ApprovalHarness.create(skipCommit: true);
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    harness.host.decide(ActionApprovalDecision.allowOnce);
    final response = _structuredResponse(await execution);

    expect(response['error'], 'execution_fence_missing');
    expect(harness.totalHandlerCalls, 0);
  });

  test('page result cannot override Host response or audit linkage', () async {
    final harness = _ApprovalHarness.create(
      handlerResult: const <String, Object?>{
        'accepted': true,
        'status': 'spoofed',
        'page': 'spoofed',
        'route': '/spoofed',
        'auditId': 'spoofed',
      },
      allowAdditionalResultProperties: true,
    );
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    harness.host.decide(ActionApprovalDecision.allowOnce);
    final response = _structuredResponse(await execution);

    expect(response['status'], 'ok');
    expect(response['page'], 'widgets_hub');
    expect(response['route'], '/widgets-hub');
    expect(response['auditId'], harness.auditEntries.first.auditId);
  });

  test('same-path query drift invalidates the exact approved route', () async {
    final harness = _ApprovalHarness.create();
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    harness.navigation.setCurrentRoute('/settings');
    await harness.host.dismissed;
    final response = _structuredResponse(await execution);

    expect(response['error'], 'approval_stale');
    expect(harness.totalHandlerCalls, 0);
  });

  test('approval expires monotonically during async preparation', () async {
    final gate = Completer<void>();
    var monotonicNow = Duration.zero;
    final harness = _ApprovalHarness.create(
      approvalTtl: const Duration(milliseconds: 50),
      monotonicNow: () => monotonicNow,
      preparationGate: gate,
    );
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    harness.host.decide(ActionApprovalDecision.allowOnce);
    await harness.commandExecutor.preparationStarted.future;
    monotonicNow = const Duration(milliseconds: 50);
    gate.complete();
    final response = _structuredResponse(await execution);

    expect(response['error'], 'approval_stale');
    expect(harness.totalHandlerCalls, 0);
    expect(
      harness.auditEntries.where(
        (entry) => entry.stage == ActionAuditStage.executed,
      ),
      isEmpty,
    );
  });

  test(
    'consequential page adapter cannot run a real async-function escape',
    () async {
      final harness = _ApprovalHarness.create(adapterAsyncEscape: true);
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      final response = _structuredResponse(await execution);

      expect(response['status'], 'ok');
      expect(harness.totalHandlerCalls, 1);
      expect(harness.adapters.single.executeCalls, 0);
      expect(harness.adapters.single.asyncEscapeEffects, 0);
      await Future<void>.delayed(Duration.zero);
      expect(harness.adapters.single.asyncEscapeEffects, 0);
    },
  );

  test(
    'a write followed by a lost receipt is never reported retry-safe',
    () async {
      final harness = _ApprovalHarness.create(throwAfterCommitWrite: true);
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      final response = _structuredResponse(await execution);

      expect(harness.totalHandlerCalls, 1);
      expect(response['error'], 'execution_result_unknown');
      expect(response['auditId'], harness.auditEntries.first.auditId);
      expect(
        harness.auditEntries
            .where((entry) => entry.stage == ActionAuditStage.result)
            .single
            .code,
        'execution.result_unknown',
      );
    },
  );

  test(
    'a Host failure result after commit is reported as an unknown outcome',
    () async {
      final harness = _ApprovalHarness.create(returnFailureAfterCommit: true);
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      final response = _structuredResponse(await execution);

      expect(harness.totalHandlerCalls, 1);
      expect(response['error'], 'execution_result_unknown');
      expect(response['auditId'], harness.auditEntries.first.auditId);
      expect(
        harness.auditEntries.where(
          (entry) => entry.stage == ActionAuditStage.executed,
        ),
        hasLength(1),
      );
      expect(
        harness.auditEntries.where(
          (entry) => entry.stage == ActionAuditStage.result,
        ),
        hasLength(1),
      );
      expect(harness.auditEntries.last.code, 'execution.result_unknown');
    },
  );

  test(
    'post-commit audit failure still returns the established audit id',
    () async {
      var resultClockUnavailable = false;
      final harness = _ApprovalHarness.create(
        throwAfterCommitWrite: true,
        onHostCommit: () => resultClockUnavailable = true,
        now: () {
          if (resultClockUnavailable) {
            throw StateError('result audit clock unavailable');
          }
          return DateTime.utc(2026, 8, 28, 8);
        },
      );
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      final response = _structuredResponse(await execution);

      expect(response['error'], 'execution_result_unknown');
      expect(response['auditId'], harness.auditEntries.first.auditId);
      expect(
        harness.auditEntries.map((entry) => entry.stage),
        <ActionAuditStage>[
          ActionAuditStage.asked,
          ActionAuditStage.decided,
          ActionAuditStage.executed,
        ],
      );
    },
  );

  test(
    'invalid post-commit result is reported as an unknown outcome',
    () async {
      final harness = _ApprovalHarness.create(
        handlerResult: const <String, Object?>{'accepted': false},
      );
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      harness.host.decide(ActionApprovalDecision.allowOnce);
      final response = _structuredResponse(await execution);

      expect(harness.totalHandlerCalls, 1);
      expect(response['error'], 'execution_result_unknown');
      expect(response['auditId'], harness.auditEntries.first.auditId);
    },
  );

  test('replacement account waits for the visible prompt to dismiss', () async {
    final dismissalGate = Completer<void>();
    final harness = _ApprovalHarness.create(dismissalGate: dismissalGate);
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    final switchFuture = harness.switchAccount();
    await Future<void>.delayed(Duration.zero);

    expect(harness.host.promptVisible, isTrue);
    expect(harness.scopes.activeMount, isNull);
    expect(
      () => harness.scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'account-b'),
      ),
      throwsA(isA<AccountStorageScopeBoundaryPendingException>()),
    );

    dismissalGate.complete();
    await switchFuture;
    _expectRevokedStructuredResult(await execution, harness);
    expect(harness.mount.scope.accountUuid, 'account-b');
  });

  test(
    'partial Host presentation is emergency-cleared before release',
    () async {
      final harness = _ApprovalHarness.create(presentThrowsAfterShowing: true);
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      final response = _structuredResponse(await execution);

      expect(response['error'], 'approval_unavailable');
      expect(harness.host.emergencyClearCalls, 1);
      expect(harness.host.promptVisible, isFalse);
      await harness.switchAccount();
      expect(harness.mount.scope.accountUuid, 'account-b');
    },
  );

  test('failed double-dismiss quarantines mount until Host recovery', () async {
    final harness = _ApprovalHarness.create(
      sessionDismissThrows: true,
      emergencyClearFailureSequence: const <bool>[true],
    );
    addTearDown(harness.dispose);

    final execution = harness.executeStructured();
    await harness.host.nextPrompt;
    harness.scopes.unmount(harness.mount);
    _expectRevokedStructuredResult(await execution, harness);

    expect(harness.host.promptVisible, isTrue);
    expect(
      () => harness.scopes.mount(
        AccountStorageScope(environmentKey: 'test', accountUuid: 'account-b'),
      ),
      throwsA(isA<AccountStorageScopeBoundaryPendingException>()),
    );

    harness.host.recoverPrompt();
    await harness.scopes.whenBoundaryReleased;
    harness.mount = harness.scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'account-b'),
    );
    expect(harness.mount.scope.accountUuid, 'account-b');
  });

  test(
    'a successful emergency clear is never undone by a later error',
    () async {
      final harness = _ApprovalHarness.create(
        decisionGetterThrows: true,
        sessionDismissThrows: true,
        emergencyClearFailureSequence: const <bool>[false, true],
      );
      addTearDown(harness.dispose);

      final execution = harness.executeStructured();
      await harness.host.nextPrompt;
      final response = _structuredResponse(await execution);

      expect(response['error'], 'approval_unavailable');
      expect(harness.host.emergencyClearCalls, 2);
      expect(harness.host.promptVisible, isFalse);
      await harness.switchAccount();
      expect(harness.mount.scope.accountUuid, 'account-b');
    },
  );

  test('approval presentation rejects every undisclosed argument', () {
    final presentation = AppControlApprovalPresentationSpec(
      title: 'Publish exact post',
      description: 'Publish this exact text.',
      targetLabel: 'Public feed',
      consequenceLabel: 'This creates a public write.',
      exactTextArgumentKey: 'topic',
    );

    expect(
      presentation.resolve(
        arguments: const <String, Object?>{
          'topic': 'safe',
          'hidden': 'changes the consequence',
        },
        consequencePolicy: ActionConsequencePolicy.exactTextCommit,
      ),
      isNull,
    );
  });
}

void _expectRevokedStructuredResult(
  AgentActionExecutionResult result,
  _ApprovalHarness harness,
) {
  // The invocation fence discards old-account/grant observations even when
  // AppControl has already recorded its internal cancellation audit.
  expect(result.ok, isFalse);
  expect(result.observations, isEmpty);
  expect(result.errors, <String>[
    'skill.call: ${const SkillNotGrantedException('AppControl')}',
  ]);
  expect(harness.totalHandlerCalls, 0);
  expect(
    harness.adapters.map((adapter) => adapter.executeCalls),
    everyElement(0),
  );
  expect(harness.auditEntries, isNotEmpty);
  expect(
    harness.auditEntries.where(
      (entry) => entry.stage == ActionAuditStage.executed,
    ),
    isEmpty,
  );
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

final class _ApprovalHarness {
  _ApprovalHarness._({
    required this.scopes,
    required this.mount,
    required this.coordinator,
    required this.uiControl,
    required this.navigation,
    required this.host,
    required this.auditLog,
    required this.auditScope,
    required this.pageAction,
    required this.commandExecutor,
    required this.skill,
    required this.registry,
    required this.executor,
    required this.tool,
    required this.adapters,
    required this.registrations,
  });

  factory _ApprovalHarness.create({
    Duration approvalTtl = const Duration(seconds: 45),
    Completer<void>? preparationGate,
    bool skipCommit = false,
    Map<String, Object?> handlerResult = const <String, Object?>{
      'accepted': true,
    },
    bool allowAdditionalResultProperties = false,
    Duration Function()? monotonicNow,
    Completer<void>? dismissalGate,
    bool sessionDismissThrows = false,
    int emergencyClearFailures = 0,
    bool decisionGetterThrows = false,
    bool presentThrowsAfterShowing = false,
    bool throwAfterCommitWrite = false,
    bool returnFailureAfterCommit = false,
    bool adapterAsyncEscape = false,
    bool provideHostCommandExecutor = true,
    DateTime Function()? now,
    VoidCallback? onHostCommit,
    List<bool> emergencyClearFailureSequence = const <bool>[],
  }) {
    final scopes = appServices.put(AccountStorageScopeService());
    final mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'account-a'),
    );
    final coordinator = AgentUiControlCoordinator();
    final uiControl = AgentUiControlService(coordinator: coordinator);
    final host = _PendingApprovalHost(
      dismissalGate: dismissalGate,
      sessionDismissThrows: sessionDismissThrows,
      emergencyClearFailures: emergencyClearFailures,
      decisionGetterThrows: decisionGetterThrows,
      presentThrowsAfterShowing: presentThrowsAfterShowing,
      emergencyClearFailureSequence: emergencyClearFailureSequence,
    );
    final auditLog = ActionAuditLog();
    final pageAction = _approvalAction(
      allowAdditionalResultProperties: allowAdditionalResultProperties,
    );
    final commandExecutor = _ApprovalHostCommandExecutor(
      handlerResult: handlerResult,
      preparationGate: preparationGate,
      skipCommit: skipCommit,
      throwAfterCommitWrite: throwAfterCommitWrite,
      returnFailureAfterCommit: returnFailureAfterCommit,
      onCommit: onHostCommit,
    );
    final adapters = <_ApprovalPageAdapter>[
      _ApprovalPageAdapter(pageAction, attemptAsyncEscape: adapterAsyncEscape),
    ];
    final registrations =
        <PageAgentAdapterRegistration<_ApprovalPageAdapter>>[];
    late final _ApprovalNavigation navigation;
    navigation = _ApprovalNavigation(
      onPush: (_) {
        registrations.add(uiControl.adapters.register(adapters.last));
      },
    );
    final skill = AppControlSkill(
      navigation: navigation,
      uiControl: uiControl,
      approvalService: ActionApprovalService(),
      approvalHost: host,
      auditLog: auditLog,
      hostCommandExecutor: provideHostCommandExecutor ? commandExecutor : null,
      now: now ?? () => DateTime.utc(2026, 8, 28, 8),
      monotonicNow: monotonicNow,
      approvalTtl: approvalTtl,
      routeReadinessBarrier: () async {},
      routeReadinessTimeout: const Duration(milliseconds: 200),
    );
    final registry = LazyHostSkillRegistry(
      agentId: 'self',
      specs: <SkillSpec>[
        SkillSpec(
          id: 'app_control_test',
          name: 'AppControl test',
          description: skill.description,
          icon: Icons.touch_app_rounded,
          color: Colors.blue,
          category: SkillCategory.core,
          isCore: true,
          factory: (_) => skill,
          hostRouting: HostSkillRoutingManifest(
            skillName: skill.skillName,
            summary: skill.description,
            methods: skill.methods.keys,
            nativeMethods: skill.nativeToolSchemas.keys,
            terms: const <String>['app control'],
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
    final activatedSkill = grant.activatedSkills.single as AppControlSkill;
    final manager = SkillManager()..registerSkill(activatedSkill);
    final tool = SkillManager.nativeToolName(activatedSkill, 'execute');
    final executor = AgentActionExecutor(
      agentId: 'self',
      skillManager: manager,
      locale: AppLocale.en,
      executableHostGrant: grant,
    );
    return _ApprovalHarness._(
      scopes: scopes,
      mount: mount,
      coordinator: coordinator,
      uiControl: uiControl,
      navigation: navigation,
      host: host,
      auditLog: auditLog,
      auditScope: ActionAuditScope(
        accountScope: mount.scope.storageNamespace,
        agentId: 'self',
        runtimeGeneration: mount.generation,
      ),
      pageAction: pageAction,
      commandExecutor: commandExecutor,
      skill: activatedSkill,
      registry: registry,
      executor: executor,
      tool: tool,
      adapters: adapters,
      registrations: registrations,
    );
  }

  final AccountStorageScopeService scopes;
  AccountStorageScopeMount mount;
  final AgentUiControlCoordinator coordinator;
  final AgentUiControlService uiControl;
  final _ApprovalNavigation navigation;
  final _PendingApprovalHost host;
  final ActionAuditLog auditLog;
  final ActionAuditScope auditScope;
  final AppControlPageAction pageAction;
  final _ApprovalHostCommandExecutor commandExecutor;
  final AppControlSkill skill;
  final LazyHostSkillRegistry registry;
  final AgentActionExecutor executor;
  final String tool;
  final List<_ApprovalPageAdapter> adapters;
  final List<PageAgentAdapterRegistration<_ApprovalPageAdapter>> registrations;

  int get totalHandlerCalls => commandExecutor.handlerCalls;

  List<ActionAuditEntry> get auditEntries =>
      auditLog.query(scope: auditScope, limit: 100);

  Future<AgentActionExecutionResult> executeStructured() => executor.execute(
    AgentActionEnvelope(
      reply: '',
      actions: <AgentAction>[
        AgentAction(
          type: 'skill.call',
          data: <String, Object?>{'tool': tool, 'args': _payload()},
        ),
      ],
    ),
  );

  Future<Map<String, Object?>> executeDirect() async {
    final raw = await skill.methods['execute']!(<Object>[
      jsonEncode(_payload()),
    ]);
    return Map<String, Object?>.from(jsonDecode(raw as String) as Map);
  }

  Future<void> switchAccount() async {
    scopes.unmount(mount);
    await scopes.whenBoundaryReleased;
    mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'account-b'),
    );
  }

  void replaceAdapter() {
    final replacement = _ApprovalPageAdapter(pageAction);
    adapters.add(replacement);
    registrations.add(uiControl.adapters.register(replacement));
  }

  Future<void> dispose() async {
    for (final registration in registrations.reversed) {
      registration.unregister();
    }
    registry.invalidate();
    await coordinator.dispose();
  }

  static Map<String, Object?> _payload() => const <String, Object?>{
    'page': 'widgets_hub',
    'action': 'commit_post',
    'arguments': <String, Object?>{'topic': 'safe'},
  };
}

AppControlPageAction _approvalAction({
  bool allowAdditionalResultProperties = false,
}) => AppControlPageAction(
  id: 'commit_post',
  description: 'Commit one exact post.',
  argumentsSchema: const <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'topic': <String, Object?>{
        'type': 'string',
        'minLength': 1,
        'maxLength': 32,
      },
    },
    'required': <String>['topic'],
    'additionalProperties': false,
  },
  resultSchema: <String, Object?>{
    'type': 'object',
    'properties': <String, Object?>{
      'accepted': <String, Object?>{'const': true},
    },
    'required': <String>['accepted'],
    'additionalProperties': allowAdditionalResultProperties,
  },
  risk: ActionRisk.externalWrite,
  consequencePolicy: ActionConsequencePolicy.exactTextCommit,
  approvalTarget: 'feed-public',
  approvalPresentation: AppControlApprovalPresentationSpec(
    title: 'Publish exact post',
    description: 'Publish this exact text to the selected public feed.',
    targetLabel: 'Public feed',
    consequenceLabel: 'This creates a public external write.',
    exactTextArgumentKey: 'topic',
  ),
);

final class _PendingApprovalHost
    implements ActionApprovalHost, ActionApprovalSession {
  _PendingApprovalHost({
    this.dismissalGate,
    this.sessionDismissThrows = false,
    this.emergencyClearFailures = 0,
    this.decisionGetterThrows = false,
    this.presentThrowsAfterShowing = false,
    List<bool> emergencyClearFailureSequence = const <bool>[],
  }) : _emergencyClearFailureSequence = List<bool>.of(
         emergencyClearFailureSequence,
       );

  final Completer<void>? dismissalGate;
  final bool sessionDismissThrows;
  int emergencyClearFailures;
  final bool decisionGetterThrows;
  final bool presentThrowsAfterShowing;
  final List<bool> _emergencyClearFailureSequence;
  final Completer<ActionApprovalPrompt> _prompt =
      Completer<ActionApprovalPrompt>();
  final Completer<ActionApprovalDecision> _decision =
      Completer<ActionApprovalDecision>();
  final Completer<void> _dismissed = Completer<void>();
  int calls = 0;
  int dismissCalls = 0;
  int emergencyClearCalls = 0;
  bool promptVisible = false;
  String? cancellationReason;

  @override
  Future<void> get whenAllDismissed =>
      promptVisible ? _dismissed.future : Future<void>.value();

  @override
  Future<ActionApprovalDecision> get decision {
    if (decisionGetterThrows) {
      throw StateError('decision getter unavailable');
    }
    return _decision.future;
  }

  Future<ActionApprovalPrompt> get nextPrompt => _prompt.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () => throw TimeoutException('approval prompt was not shown'),
  );

  Future<void> get dismissed => _dismissed.future.timeout(
    const Duration(seconds: 2),
    onTimeout: () =>
        throw TimeoutException('approval prompt was not dismissed'),
  );

  void decide(ActionApprovalDecision decision) {
    promptVisible = false;
    if (!_decision.isCompleted) _decision.complete(decision);
    if (!_dismissed.isCompleted) _dismissed.complete();
  }

  @override
  ActionApprovalSession present(ActionApprovalPrompt prompt) {
    calls += 1;
    promptVisible = true;
    if (!_prompt.isCompleted) _prompt.complete(prompt);
    if (presentThrowsAfterShowing) {
      throw StateError('present failed after showing');
    }
    return this;
  }

  @override
  Future<void> dismiss(ActionApprovalCancellationReason reason) async {
    dismissCalls += 1;
    cancellationReason = reason.code;
    if (sessionDismissThrows) throw StateError('session dismiss failed');
    await dismissalGate?.future;
    _clearPrompt();
  }

  @override
  Future<void> dismissAll(ActionApprovalCancellationReason reason) async {
    emergencyClearCalls += 1;
    cancellationReason = reason.code;
    final sequencedFailure = _emergencyClearFailureSequence.isNotEmpty
        ? _emergencyClearFailureSequence.removeAt(0)
        : false;
    final countedFailure = emergencyClearFailures > 0;
    if (countedFailure) {
      emergencyClearFailures -= 1;
    }
    if (sequencedFailure || countedFailure) {
      throw StateError('emergency clear failed');
    }
    await dismissalGate?.future;
    _clearPrompt();
  }

  void _clearPrompt() {
    promptVisible = false;
    if (!_dismissed.isCompleted) _dismissed.complete();
    if (!_decision.isCompleted) {
      _decision.complete(ActionApprovalDecision.cancel);
    }
  }

  void recoverPrompt() => _clearPrompt();
}

final class _ApprovalNavigation extends AppNavigation {
  _ApprovalNavigation({required this.onPush});

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

  void setCurrentRoute(String route) => _currentRoute = route;
}

final class _ApprovalPageAdapter implements AppControlPageAdapter {
  _ApprovalPageAdapter(this.action, {this.attemptAsyncEscape = false});

  final AppControlPageAction action;
  final bool attemptAsyncEscape;
  int executeCalls = 0;
  int asyncEscapeEffects = 0;

  @override
  String get route => '/widgets-hub';

  @override
  List<AppControlPageAction> get appControlActions => <AppControlPageAction>[
    action,
  ];

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> executeAppControlAction({
    required AgentUiControlLease lease,
    required String actionId,
    required Map<String, Object?> arguments,
    required AppControlActionExecutionContext executionContext,
  }) async {
    executeCalls += 1;
    if (attemptAsyncEscape) {
      unawaited(() async {
        asyncEscapeEffects += 1;
        await Future<void>.delayed(Duration.zero);
        asyncEscapeEffects += 1000;
      }());
    }
    return const AgentUiControlResult<Map<String, Object?>>.success(
      <String, Object?>{'adapterShouldNeverExecute': true},
    );
  }
}

final class _ApprovalHostCommandExecutor
    implements AppControlHostCommandExecutor {
  _ApprovalHostCommandExecutor({
    this.handlerResult = const <String, Object?>{'accepted': true},
    this.preparationGate,
    this.skipCommit = false,
    this.throwAfterCommitWrite = false,
    this.returnFailureAfterCommit = false,
    this.onCommit,
  });

  final Map<String, Object?> handlerResult;
  final Completer<void>? preparationGate;
  final bool skipCommit;
  final bool throwAfterCommitWrite;
  final bool returnFailureAfterCommit;
  final VoidCallback? onCommit;
  final Completer<void> preparationStarted = Completer<void>();
  int handlerCalls = 0;
  ActionInvocationContext? capturedContext;

  @override
  bool supports(AppControlHostCommand command) =>
      command.actionId == 'app_control.widgets_hub.commit_post' &&
      command.pageActionId == 'commit_post' &&
      command.targetRoute == '/widgets-hub' &&
      command.target == '/widgets-hub#commit_post:feed-public' &&
      command.arguments['topic'] is String;

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> execute({
    required AppControlHostCommand command,
    required AppControlActionExecutionContext executionContext,
  }) async {
    capturedContext = ActionInvocationContext.current;
    if (!supports(command)) {
      return const AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.executionFailed,
        message: 'unsupported Host command',
      );
    }
    final gate = preparationGate;
    if (gate != null) {
      if (!preparationStarted.isCompleted) preparationStarted.complete();
      await executionContext.guardedAwait(gate.future);
    }
    if (skipCommit) {
      return AgentUiControlResult<Map<String, Object?>>.success(handlerResult);
    }
    executionContext.beginHostCommit();
    handlerCalls += 1;
    onCommit?.call();
    if (throwAfterCommitWrite) {
      throw StateError('write completed but receipt failed');
    }
    if (returnFailureAfterCommit) {
      return const AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.executionFailed,
        message: 'write receipt unavailable',
      );
    }
    return AgentUiControlResult<Map<String, Object?>>.success(handlerResult);
  }
}
