import 'dart:async';
import 'dart:convert';

import 'package:flutter/scheduler.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_host.dart';
import 'package:maaso/src/features/agent/application/action/action_approval_service.dart';
import 'package:maaso/src/features/agent/application/action/action_audit_log.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/action/action_json_snapshot.dart';
import 'package:maaso/src/features/agent/application/action/action_schema_validator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

/// Navigates the owner app and invokes only actions declared by the mounted
/// destination page.
class AppControlSkill extends AgentSkill {
  static const ActionSchemaValidator _schemaValidator = ActionSchemaValidator();
  static const Duration _approvalFencePollInterval = Duration(milliseconds: 8);

  AppControlSkill({
    this.agentId = 'self',
    AppNavigation? navigation,
    AgentUiControlService? uiControl,
    ActionApprovalService? approvalService,
    ActionApprovalHost? approvalHost,
    ActionAuditLog? auditLog,
    AppControlHostCommandExecutor? hostCommandExecutor,
    DateTime Function()? now,
    Duration Function()? monotonicNow,
    Duration approvalTtl = const Duration(seconds: 45),
    Future<void> Function()? routeReadinessBarrier,
    Duration routeReadinessTimeout = const Duration(seconds: 2),
    AppCapabilitySnapshotService? capabilitySnapshotService,
  }) : _navigationOverride = navigation,
       _uiControlOverride = uiControl,
       _approvalServiceOverride = approvalService,
       _approvalHostOverride = approvalHost,
       _auditLogOverride = auditLog,
       _hostCommandExecutorOverride = hostCommandExecutor,
       _now = now ?? DateTime.now,
       _monotonicNow =
           monotonicNow ?? (() => _appControlApprovalMonotonicClock.elapsed),
       _approvalTtl = approvalTtl,
       _routeReadinessBarrier =
           routeReadinessBarrier ?? _defaultRouteReadinessBarrier,
       _routeReadinessTimeout = routeReadinessTimeout,
       _capabilitySnapshotServiceOverride = capabilitySnapshotService,
       assert(approvalTtl > Duration.zero),
       assert(approvalTtl <= const Duration(minutes: 5));

  final String agentId;
  final AppNavigation? _navigationOverride;
  final AgentUiControlService? _uiControlOverride;
  final ActionApprovalService? _approvalServiceOverride;
  final ActionApprovalHost? _approvalHostOverride;
  final ActionAuditLog? _auditLogOverride;
  final AppControlHostCommandExecutor? _hostCommandExecutorOverride;
  final DateTime Function() _now;
  final Duration Function() _monotonicNow;
  final Duration _approvalTtl;
  final Future<void> Function() _routeReadinessBarrier;
  final Duration _routeReadinessTimeout;
  final AppCapabilitySnapshotService? _capabilitySnapshotServiceOverride;
  int _nextSession = 0;

  late final AppCapabilitySnapshotService? _capabilitySnapshotService =
      _readCapabilitySnapshotService();
  AppCapabilitySnapshotLease? _cachedCapabilityLease;

  AppNavigation get _navigation => _navigationOverride ?? appNavigation;
  AgentUiControlService get _uiControl =>
      _uiControlOverride ?? appServices.find<AgentUiControlService>();
  ActionApprovalService? get _approvalService =>
      _approvalServiceOverride ??
      appServices.maybeFind<ActionApprovalService>();
  ActionApprovalHost? get _approvalHost =>
      _approvalHostOverride ?? appServices.maybeFind<ActionApprovalHost>();
  ActionAuditLog? get _auditLog =>
      _auditLogOverride ?? appServices.maybeFind<ActionAuditLog>();

  AppCapabilitySnapshotService? _readCapabilitySnapshotService() {
    try {
      return _capabilitySnapshotServiceOverride ??
          appServices.maybeFind<AppCapabilitySnapshotService>();
    } catch (_) {
      return _capabilitySnapshotServiceOverride;
    }
  }

  AppCapabilitySnapshotLease? _freshCapabilityLease() {
    final service = _capabilitySnapshotService;
    if (service == null) return null;
    final existing = _cachedCapabilityLease;
    if (existing != null && service.isCurrent(existing)) return existing;
    try {
      return _cachedCapabilityLease = service.acquireLease(<AppCapabilityKey>[
        AppCapabilityKey.skill('app_control'),
      ], requireVisible: true).lease;
    } catch (_) {
      return _cachedCapabilityLease = null;
    }
  }

  bool _capabilityLeaseIsCurrent(AppCapabilitySnapshotLease? lease) {
    final service = _capabilitySnapshotService;
    if (service == null) return true;
    return lease != null && service.isCurrent(lease);
  }

  List<AppDestination> get _availableDestinations {
    final service = _capabilitySnapshotService;
    if (service == null) return AppRouteCatalog.destinations;
    final lease = _freshCapabilityLease();
    if (lease == null || !service.isCurrent(lease)) {
      return const <AppDestination>[];
    }
    return AppRouteCatalog.destinations
        .where(
          (destination) => lease.snapshot.allows(
            AppCapabilityKey.route(destination.id),
            requireVisible: true,
          ),
        )
        .toList(growable: false);
  }

  AppControlHostCommandExecutor? _readHostCommandExecutor() {
    try {
      return _hostCommandExecutorOverride ??
          appServices.maybeFind<AppControlHostCommandExecutor>();
    } catch (_) {
      return null;
    }
  }

  @override
  String get skillName => 'AppControl';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Visibly navigate and operate safe actions declared by app pages. Use '
      'for opening settings, managing applets, and filling visible forms. '
      'Consequential actions still require owner approval.';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'execute': _execute,
        'listCapabilities': _listCapabilities,
      };

  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'execute': {
      'type': 'object',
      'properties': {
        'page': {
          'type': 'string',
          'enum': _availableDestinations
              .map((destination) => destination.id)
              .toList(growable: false),
          'description': 'Destination page id.',
        },
        'channel': {
          'type': 'string',
          'description': 'Optional section declared by the destination.',
        },
        'action': {
          'type': 'string',
          'description': 'Optional safe action declared by the visible page.',
        },
        'arguments': {
          'type': 'object',
          'description': 'Bounded arguments accepted by the declared action.',
        },
      },
      'required': const <String>['page'],
      'additionalProperties': false,
    },
    'listCapabilities': {'type': 'object', 'properties': const {}},
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'execute':
        'Open a catalog page and optionally execute one page-declared visible action. Returns guarded JSON status.',
    'listCapabilities':
        'List every catalog destination and explain the page-adapter action protocol.',
  };

  Future<String> _execute(List<dynamic> args) async {
    AgentUiControlService? activeUiControl;
    AgentUiControlLease? activeLease;
    final snapshotLease = _freshCapabilityLease();
    try {
      if (agentId != 'self') return _error('owner_only');
      if (!_capabilityLeaseIsCurrent(snapshotLease)) {
        return _capabilityError(
          'capability_stale',
          capabilityLease: snapshotLease,
        );
      }
      final payload = _decode(args);
      final page = payload['page']?.toString().trim() ?? '';
      final destination = AppRouteCatalog.destinations
          .where((candidate) => candidate.id == page)
          .firstOrNull;
      if (destination == null) return _error('unknown_page');
      if (!_capabilityAllowsDestination(destination, snapshotLease)) {
        return _capabilityError(
          'unavailable_page',
          capabilityLease: snapshotLease,
          requiredKeys: <AppCapabilityKey>[
            AppCapabilityKey.route(destination.id),
          ],
        );
      }

      final channel = payload['channel']?.toString().trim().toLowerCase();
      final variant = channel == null || channel.isEmpty
          ? null
          : destination.variant(channel);
      if (channel != null && channel.isNotEmpty && variant == null) {
        return _error('invalid_channel');
      }
      final action = payload['action']?.toString().trim() ?? '';
      final rawArguments = payload['arguments'];
      if (rawArguments != null && rawArguments is! Map) {
        return _error('invalid_arguments');
      }
      late final Map<String, Object?> arguments;
      try {
        final snapshot = snapshotActionJson(
          rawArguments == null
              ? const <String, Object?>{}
              : Map<String, Object?>.from(rawArguments as Map),
        );
        if (snapshot is! Map<String, Object?>) {
          return _error('invalid_arguments');
        }
        arguments = snapshot;
      } on ActionJsonSnapshotException {
        return _error('invalid_arguments');
      }
      final targetRoute = variant?.route ?? destination.route;

      late final AgentUiControlService uiControl;
      try {
        uiControl = _uiControl;
      } catch (_) {
        return _error('ui_control_unavailable');
      }
      activeUiControl = uiControl;
      final navigation = _navigation;
      if (!navigation.isConfigured) return _error('navigation_failed');

      final began = uiControl.coordinator.begin(
        sessionId: 'app-control-${++_nextSession}',
        purpose: action.isEmpty
            ? 'app_control.navigate'
            : 'app_control.$action',
        targetRoute: targetRoute,
      );
      if (!began.isSuccess) return _uiControlError(began);
      final lease = began.value!;
      activeLease = lease;

      if (!_capabilityAllowsDestination(destination, snapshotLease)) {
        return _failCapability(
          uiControl,
          lease,
          'capability_stale',
          capabilityLease: snapshotLease,
          requiredKeys: <AppCapabilityKey>[
            AppCapabilityKey.route(destination.id),
          ],
        );
      }

      Object? navigationFailure;
      try {
        final navigationFuture = navigation.push<void>(targetRoute);
        unawaited(
          navigationFuture.then<void>(
            (_) {},
            onError: (Object error, StackTrace _) {
              navigationFailure = error;
            },
          ),
        );
      } catch (error) {
        navigationFailure = error;
      }
      if (navigationFailure != null) {
        return _fail(uiControl, lease, 'navigation_failed');
      }

      final ready = await _waitForRoute(
        uiControl: uiControl,
        lease: lease,
        targetRoute: targetRoute,
        requireAdapter: action.isNotEmpty,
        navigationFailure: () => navigationFailure,
      );
      if (!ready.isSuccess) {
        return _fail(
          uiControl,
          lease,
          navigationFailure == null
              ? ready.reason ?? 'page_not_ready'
              : 'navigation_failed',
        );
      }
      if (!_capabilityAllowsDestination(destination, snapshotLease)) {
        return _failCapability(
          uiControl,
          lease,
          _capabilityLeaseIsCurrent(snapshotLease)
              ? 'unavailable_page'
              : 'capability_stale',
          capabilityLease: snapshotLease,
          requiredKeys: <AppCapabilityKey>[
            AppCapabilityKey.route(destination.id),
          ],
        );
      }

      Map<String, Object?> actionResult = const <String, Object?>{};
      String? auditId;
      if (action.isNotEmpty) {
        final adapter = ready.value!;
        final pageAction = adapter.actionById(action);
        if (pageAction == null) {
          return _fail(uiControl, lease, 'unknown_action');
        }
        if (!_capabilityAllowsPageAction(
          destination,
          pageAction,
          snapshotLease,
        )) {
          return _failCapability(
            uiControl,
            lease,
            _capabilityLeaseIsCurrent(snapshotLease)
                ? 'unavailable_action'
                : 'capability_stale',
            capabilityLease: snapshotLease,
            requiredKeys: <AppCapabilityKey>[
              AppCapabilityKey.route(destination.id),
              ...pageAction.requiredCapabilities,
            ],
          );
        }
        final argumentValidation = _schemaValidator.validate(
          schema: pageAction.argumentsSchema,
          value: arguments,
        );
        if (!argumentValidation.isValid) {
          return _fail(
            uiControl,
            lease,
            argumentValidation.schemaValid
                ? 'invalid_arguments'
                : 'host_schema_invalid',
          );
        }
        final resultSchemaPreflight = _schemaValidator.validate(
          schema: pageAction.resultSchema,
          value: const <String, Object?>{},
        );
        if (!resultSchemaPreflight.schemaValid) {
          return _fail(uiControl, lease, 'host_schema_invalid');
        }
        final requiresApproval =
            pageAction.risk.requiresApproval ||
            pageAction.consequencePolicy.requiresApproval;
        _ApprovedAppControlAction? approved;
        if (requiresApproval) {
          final commandExecutor = _readHostCommandExecutor();
          final command = _buildHostCommand(
            page: page,
            targetRoute: targetRoute,
            pageAction: pageAction,
            arguments: arguments,
          );
          if (commandExecutor == null || command == null) {
            return _fail(uiControl, lease, 'approval_required');
          }
          if (!_hostCommandExecutorIsCurrent(commandExecutor, command)) {
            return _fail(uiControl, lease, 'approval_unavailable');
          }
          final approval = await _requestPageActionApproval(
            uiControl: uiControl,
            lease: lease,
            adapter: adapter,
            targetRoute: targetRoute,
            pageAction: pageAction,
            arguments: arguments,
            commandExecutor: commandExecutor,
            command: command,
          );
          approved = approval.approved;
          if (approved == null) {
            return _fail(
              uiControl,
              lease,
              approval.error ?? 'approval_unavailable',
            );
          }
          if (!_revalidateApprovedPageAction(
            approved: approved,
            uiControl: uiControl,
            lease: lease,
            adapter: adapter,
            targetRoute: targetRoute,
            pageAction: pageAction,
            arguments: arguments,
          )) {
            final audited = _appendApprovedAudit(
              approved,
              stage: ActionAuditStage.result,
              outcome: ActionAuditOutcome.failed,
              code: 'approval.stale',
            );
            return _fail(
              uiControl,
              lease,
              audited ? 'approval_stale' : 'audit_unavailable',
            );
          }
        }
        final currentInvocation = ActionInvocationContext.current;
        final executionContext = AppControlActionExecutionContext.host(
          requiresCommit: approved != null,
          staleCode: approved == null ? 'execution_stale' : 'approval_stale',
          authorityIsCurrent: () =>
              _capabilityAllowsPageAction(
                destination,
                pageAction,
                snapshotLease,
              ) &&
              (approved == null
                  ? _revalidateCurrentPageAction(
                      invocation: currentInvocation,
                      uiControl: uiControl,
                      lease: lease,
                      adapter: adapter,
                      targetRoute: targetRoute,
                      pageAction: pageAction,
                      arguments: arguments,
                    )
                  : _revalidateApprovedPageAction(
                      approved: approved,
                      uiControl: uiControl,
                      lease: lease,
                      adapter: adapter,
                      targetRoute: targetRoute,
                      pageAction: pageAction,
                      arguments: arguments,
                    )),
          recordExecutionStarted: approved == null
              ? null
              : () => _appendApprovedAudit(
                  approved!,
                  stage: ActionAuditStage.executed,
                  outcome: ActionAuditOutcome.started,
                  code: 'execution.started',
                ),
        );
        String failOperation({
          required String preCommitError,
          required String preCommitAuditCode,
        }) {
          final approvedAction = approved;
          if (approvedAction == null) {
            return _fail(uiControl, lease, preCommitError);
          }
          final resultUnknown = executionContext.commitStarted;
          final audited = _appendApprovedAudit(
            approvedAction,
            stage: ActionAuditStage.result,
            outcome: ActionAuditOutcome.failed,
            code: resultUnknown
                ? 'execution.result_unknown'
                : preCommitAuditCode,
          );
          if (resultUnknown) {
            return _failExecutionResultUnknown(
              uiControl,
              lease,
              approvedAction.auditId,
            );
          }
          return _fail(
            uiControl,
            lease,
            audited ? preCommitError : 'execution_result_unknown',
          );
        }

        late final AgentUiControlResult<Map<String, Object?>> operated;
        try {
          final approvedAction = approved;
          if (approvedAction == null) {
            operated = await adapter.executeAppControlAction(
              lease: lease,
              actionId: action,
              arguments: arguments,
              executionContext: executionContext,
            );
          } else {
            operated = await executionContext.guardedCall(
              () => approvedAction.commandExecutor.execute(
                command: approvedAction.command,
                executionContext: executionContext,
              ),
            );
          }
        } on AppControlActionExecutionException catch (error) {
          return failOperation(
            preCommitError: error.code,
            preCommitAuditCode: 'execution.fence_rejected',
          );
        } catch (_) {
          return failOperation(
            preCommitError: 'execution_failed',
            preCommitAuditCode: 'execution.failed',
          );
        }
        if (!operated.isSuccess) {
          return failOperation(
            preCommitError: operated.reason ?? 'execution_failed',
            preCommitAuditCode: 'execution.failed',
          );
        }
        if (approved != null && !executionContext.commitStarted) {
          final audited = _appendApprovedAudit(
            approved,
            stage: ActionAuditStage.result,
            outcome: ActionAuditOutcome.failed,
            code: 'execution.commit_missing',
          );
          return _fail(
            uiControl,
            lease,
            audited ? 'execution_fence_missing' : 'execution_result_unknown',
          );
        }
        try {
          final snapshot = snapshotActionJson(
            operated.value ?? const <String, Object?>{},
          );
          if (snapshot is! Map<String, Object?>) {
            return failOperation(
              preCommitError: 'invalid_result',
              preCommitAuditCode: 'result.invalid',
            );
          }
          actionResult = snapshot;
        } on ActionJsonSnapshotException {
          return failOperation(
            preCommitError: 'invalid_result',
            preCommitAuditCode: 'result.invalid',
          );
        }
        final resultValidation = _schemaValidator.validate(
          schema: pageAction.resultSchema,
          value: actionResult,
        );
        if (!resultValidation.isValid) {
          return failOperation(
            preCommitError: resultValidation.schemaValid
                ? 'invalid_result'
                : 'host_schema_invalid',
            preCommitAuditCode: 'result.invalid',
          );
        }
        if (approved != null) {
          if (!_appendApprovedAudit(
            approved,
            stage: ActionAuditStage.result,
            outcome: ActionAuditOutcome.succeeded,
            code: 'ok',
          )) {
            return _failExecutionResultUnknown(
              uiControl,
              lease,
              approved.auditId,
            );
          }
          auditId = approved.auditId;
        }
      }

      if (!_capabilityLeaseIsCurrent(snapshotLease)) {
        return _failCapability(
          uiControl,
          lease,
          'capability_stale',
          capabilityLease: snapshotLease,
        );
      }
      final completed = uiControl.coordinator.complete(lease);
      if (!completed.isSuccess) {
        final completedAuditId = auditId;
        if (completedAuditId != null) {
          return _failExecutionResultUnknown(
            uiControl,
            lease,
            completedAuditId,
          );
        }
        return _uiControlError(completed);
      }
      return jsonEncode(<String, Object?>{
        ...actionResult,
        'status': 'ok',
        'page': page,
        'route': targetRoute,
        if (channel != null && channel.isNotEmpty) 'channel': channel,
        if (action.isNotEmpty) 'action': action,
        if (snapshotLease != null)
          'capabilityGeneration': snapshotLease.generation,
        'auditId': ?auditId,
      });
    } on FormatException {
      return _error('invalid_arguments');
    } catch (_) {
      final uiControl = activeUiControl;
      final lease = activeLease;
      if (uiControl != null && lease != null) {
        uiControl.coordinator.fail(lease, message: 'App control failed.');
      }
      return _error('execution_failed');
    }
  }

  Future<_AppControlApprovalGate> _requestPageActionApproval({
    required AgentUiControlService uiControl,
    required AgentUiControlLease lease,
    required AppControlPageAdapter adapter,
    required String targetRoute,
    required AppControlPageAction pageAction,
    required Map<String, Object?> arguments,
    required AppControlHostCommandExecutor commandExecutor,
    required AppControlHostCommand command,
  }) async {
    final approvalService = _approvalService;
    final approvalHost = _approvalHost;
    final auditLog = _auditLog;
    if (approvalService == null || approvalHost == null || auditLog == null) {
      return const _AppControlApprovalGate.denied('approval_required');
    }

    final invocation = ActionInvocationContext.current;
    if (invocation == null ||
        !invocation.matches(
          agentId: agentId,
          skillName: skillName,
          method: 'execute',
        ) ||
        !_approvalWaitFenceIsCurrent(
          invocation: invocation,
          uiControl: uiControl,
          lease: lease,
          adapter: adapter,
          targetRoute: targetRoute,
          pageAction: pageAction,
          arguments: arguments,
          commandExecutor: commandExecutor,
          command: command,
        )) {
      return const _AppControlApprovalGate.denied('approval_unavailable');
    }

    final presentation = pageAction.resolveApprovalPresentation(arguments);
    if (presentation == null) {
      return const _AppControlApprovalGate.denied('approval_unavailable');
    }
    final now = _readNow();
    final approvalStartedAt = _readMonotonicNow();
    if (now == null || approvalStartedAt == null) {
      return const _AppControlApprovalGate.denied('approval_unavailable');
    }
    final approvalDeadline = approvalStartedAt + _approvalTtl;
    final request = ActionApprovalRequest(
      accountScope: invocation.accountScope,
      agentId: invocation.agentId,
      runtimeGeneration: invocation.runtimeGeneration,
      callId: invocation.callId,
      actionId: command.actionId,
      arguments: command.arguments,
      target: command.target,
      expiresAt: now.add(_approvalTtl),
    );
    final asked = _appendAudit(
      auditLog: auditLog,
      request: request,
      pageAction: pageAction,
      stage: ActionAuditStage.asked,
      outcome: ActionAuditOutcome.proposed,
      code: 'approval.asked',
      occurredAt: now,
    );
    if (asked == null) {
      return const _AppControlApprovalGate.denied('audit_unavailable');
    }

    final pending = approvalService.requestConfirmation(
      request: request,
      now: now,
    );
    final fingerprint = pending.fingerprint;
    if (pending.outcome != ActionApprovalOutcome.confirmationRequired ||
        fingerprint == null) {
      final recorded = _appendAudit(
        auditLog: auditLog,
        request: request,
        pageAction: pageAction,
        stage: ActionAuditStage.decided,
        outcome: ActionAuditOutcome.unavailable,
        code: 'approval.unavailable',
        occurredAt: now,
      );
      return _AppControlApprovalGate.denied(
        recorded == null ? 'audit_unavailable' : 'approval_unavailable',
      );
    }

    final boundaryHold = invocation.acquireAccountBoundaryHold();
    if (boundaryHold == null) {
      approvalService.resolve(
        fingerprint: fingerprint,
        request: request,
        decision: ActionApprovalDecision.cancel,
        now: now,
      );
      final recorded = _appendAudit(
        auditLog: auditLog,
        request: request,
        pageAction: pageAction,
        stage: ActionAuditStage.decided,
        outcome: ActionAuditOutcome.unavailable,
        code: 'approval.unavailable',
        occurredAt: now,
      );
      return _AppControlApprovalGate.denied(
        recorded == null ? 'audit_unavailable' : 'approval_unavailable',
      );
    }

    final awaitingConsent = uiControl.coordinator.enterAwaitingConsent(lease);
    if (!awaitingConsent.isSuccess) {
      boundaryHold.release();
      approvalService.resolve(
        fingerprint: fingerprint,
        request: request,
        decision: ActionApprovalDecision.cancel,
        now: now,
      );
      final recorded = _appendAudit(
        auditLog: auditLog,
        request: request,
        pageAction: pageAction,
        stage: ActionAuditStage.decided,
        outcome: ActionAuditOutcome.unavailable,
        code: 'approval.unavailable',
        occurredAt: now,
      );
      return _AppControlApprovalGate.denied(
        recorded == null ? 'audit_unavailable' : 'approval_unavailable',
      );
    }

    final cancellation = Completer<ActionApprovalCancellationReason>.sync();
    var monitorActive = true;
    void cancel(ActionApprovalCancellationReason reason) {
      if (!cancellation.isCompleted) cancellation.complete(reason);
    }

    void cancelIfStale() {
      if (!monitorActive) return;
      if (!_approvalWaitFenceIsCurrent(
        invocation: invocation,
        uiControl: uiControl,
        lease: lease,
        adapter: adapter,
        targetRoute: targetRoute,
        pageAction: pageAction,
        arguments: arguments,
        commandExecutor: commandExecutor,
        command: command,
      )) {
        cancel(ActionApprovalCancellationReason.authorityStale);
      }
    }

    final leaseSubscription = uiControl.coordinator.changes.listen(
      (_) => cancelIfStale(),
      onDone: () => cancel(ActionApprovalCancellationReason.authorityStale),
    );
    unawaited(
      invocation.whenInvalidated.then((_) {
        if (monitorActive) {
          cancel(ActionApprovalCancellationReason.authorityStale);
        }
      }),
    );
    cancelIfStale();
    final fenceTimer = Timer.periodic(
      _approvalFencePollInterval,
      (_) => cancelIfStale(),
    );
    final expiryTimer = Timer(
      _approvalTtl,
      () => cancel(ActionApprovalCancellationReason.expired),
    );
    late _ApprovalHostOutcome hostOutcome;
    ActionApprovalSession? hostSession;
    var hostCleared = false;

    Future<bool> emergencyClearHost() async {
      try {
        await approvalHost.dismissAll(
          ActionApprovalCancellationReason.hostFailed,
        );
        return true;
      } catch (_) {
        return false;
      }
    }

    try {
      if (cancellation.isCompleted) {
        final reason = await cancellation.future;
        hostOutcome = _ApprovalHostOutcome.cancelled(reason.code);
        hostCleared = true;
      } else {
        try {
          hostSession = approvalHost.present(
            ActionApprovalPrompt(
              fingerprint: fingerprint,
              actionId: request.actionId,
              expiresAt: request.expiresAt,
              presentation: presentation,
              risk: pageAction.risk,
              consequencePolicy: pageAction.consequencePolicy,
            ),
          );
          final hostFuture = hostSession.decision.then<_ApprovalHostOutcome>(
            _ApprovalHostOutcome.decided,
            onError: (Object _, StackTrace _) =>
                const _ApprovalHostOutcome.cancelled(
                  'approval.host_unavailable',
                ),
          );
          final cancellationFuture = cancellation.future
              .then<_ApprovalHostOutcome>(
                (reason) => _ApprovalHostOutcome.cancelled(reason.code),
              );
          hostOutcome = await Future.any<_ApprovalHostOutcome>(
            <Future<_ApprovalHostOutcome>>[hostFuture, cancellationFuture],
          );
        } catch (_) {
          hostOutcome = const _ApprovalHostOutcome.cancelled(
            'approval.host_unavailable',
          );
          hostCleared = (await emergencyClearHost()) || hostCleared;
        }

        // Close the narrow race between a Host decision and every fence.
        cancelIfStale();
        final reason = cancellation.isCompleted
            ? await cancellation.future
            : hostOutcome.failureCode == null
            ? ActionApprovalCancellationReason.decisionSettled
            : ActionApprovalCancellationReason.hostFailed;
        final session = hostSession;
        if (session != null) {
          try {
            await session.dismiss(reason);
            hostCleared = true;
          } catch (_) {
            hostOutcome = const _ApprovalHostOutcome.cancelled(
              'approval.host_unavailable',
            );
            hostCleared = (await emergencyClearHost()) || hostCleared;
          }
        }
        cancelIfStale();
        if (cancellation.isCompleted) {
          final cancellationReason = await cancellation.future;
          hostOutcome = _ApprovalHostOutcome.cancelled(cancellationReason.code);
        }
      }
    } finally {
      monitorActive = false;
      fenceTimer.cancel();
      expiryTimer.cancel();
      try {
        await leaseSubscription.cancel();
      } finally {
        // A failed double-dismiss leaves the hold quarantined. Blocking a new
        // account mount is safer than exposing old-account exact text.
        if (hostCleared) {
          boundaryHold.release();
        } else {
          try {
            unawaited(
              approvalHost.whenAllDismissed.then<void>(
                (_) => boundaryHold.release(),
                onError: (Object _, StackTrace _) {},
              ),
            );
          } catch (_) {
            // Keep the hold quarantined when even the recovery signal cannot
            // be obtained. A process restart is then the only safe boundary.
          }
        }
      }
    }

    final decision = hostOutcome.decision;
    final hostFailureCode = hostOutcome.failureCode;
    final decidedAt = _readNow();
    final resolved = approvalService.resolve(
      fingerprint: fingerprint,
      request: request,
      decision: decision,
      // The exact expiry boundary both consumes and invalidates the pending
      // authority when the host clock becomes unavailable.
      now: decidedAt ?? request.expiresAt,
    );
    final uiConsentReady =
        decision != ActionApprovalDecision.allowOnce ||
        uiControl.coordinator.grantConsent(lease).isSuccess;
    final effectiveOutcome = resolved.isAllowedOnce && !uiConsentReady
        ? ActionApprovalOutcome.unavailable
        : resolved.outcome;
    final (auditOutcome, auditCode, error) = switch (effectiveOutcome) {
      ActionApprovalOutcome.allowedOnce => (
        ActionAuditOutcome.allowed,
        'approval.allowed',
        null,
      ),
      ActionApprovalOutcome.rejected => (
        ActionAuditOutcome.rejected,
        'approval.rejected',
        'approval_rejected',
      ),
      ActionApprovalOutcome.cancelled => (
        ActionAuditOutcome.cancelled,
        hostFailureCode ?? 'approval.cancelled',
        hostFailureCode == null
            ? 'approval_cancelled'
            : hostFailureCode == 'approval.stale'
            ? 'approval_stale'
            : 'approval_unavailable',
      ),
      ActionApprovalOutcome.unavailable ||
      ActionApprovalOutcome.confirmationRequired => (
        ActionAuditOutcome.unavailable,
        'approval.unavailable',
        'approval_unavailable',
      ),
    };
    final recorded = _appendAudit(
      auditLog: auditLog,
      request: request,
      pageAction: pageAction,
      stage: ActionAuditStage.decided,
      outcome: auditOutcome,
      code: auditCode,
      occurredAt: decidedAt ?? request.expiresAt,
    );
    if (recorded == null || recorded.auditId != asked.auditId) {
      return const _AppControlApprovalGate.denied('audit_unavailable');
    }
    if (!resolved.isAllowedOnce) {
      return _AppControlApprovalGate.denied(error ?? 'approval_unavailable');
    }
    return _AppControlApprovalGate.allowed(
      _ApprovedAppControlAction(
        invocation: invocation,
        request: request,
        pageAction: pageAction,
        auditLog: auditLog,
        auditId: asked.auditId,
        monotonicDeadline: approvalDeadline,
        commandExecutor: commandExecutor,
        command: command,
      ),
    );
  }

  bool _approvalWaitFenceIsCurrent({
    required ActionInvocationContext invocation,
    required AgentUiControlService uiControl,
    required AgentUiControlLease lease,
    required AppControlPageAdapter adapter,
    required String targetRoute,
    required AppControlPageAction pageAction,
    required Map<String, Object?> arguments,
    required AppControlHostCommandExecutor commandExecutor,
    required AppControlHostCommand command,
  }) {
    if (!identical(ActionInvocationContext.current, invocation) ||
        !invocation.isCurrent ||
        !uiControl.coordinator.checkLease(lease).isSuccess ||
        !_sameRoute(_navigation.currentRoute, targetRoute) ||
        !identical(command.arguments, arguments) ||
        command.pageActionId != pageAction.id ||
        command.targetRoute != targetRoute ||
        !_hostCommandExecutorIsCurrent(commandExecutor, command)) {
      return false;
    }
    final resolved = uiControl.adapters.resolve<AppControlPageAdapter>(
      route: targetRoute,
      lease: lease,
    );
    final argumentValidation = _schemaValidator.validate(
      schema: pageAction.argumentsSchema,
      value: arguments,
    );
    return resolved.isSuccess &&
        identical(resolved.value, adapter) &&
        identical(adapter.actionById(pageAction.id), pageAction) &&
        argumentValidation.isValid;
  }

  bool _revalidateCurrentPageAction({
    ActionInvocationContext? invocation,
    required AgentUiControlService uiControl,
    required AgentUiControlLease lease,
    required AppControlPageAdapter adapter,
    required String targetRoute,
    required AppControlPageAction pageAction,
    required Map<String, Object?> arguments,
  }) {
    if ((invocation != null &&
            (!identical(ActionInvocationContext.current, invocation) ||
                !invocation.isCurrent)) ||
        !uiControl.coordinator.checkLease(lease).isSuccess ||
        !_sameRoute(_navigation.currentRoute, targetRoute)) {
      return false;
    }
    final resolved = uiControl.adapters.resolve<AppControlPageAdapter>(
      route: targetRoute,
      lease: lease,
    );
    if (!resolved.isSuccess ||
        !identical(resolved.value, adapter) ||
        !identical(adapter.actionById(pageAction.id), pageAction)) {
      return false;
    }
    final argumentValidation = _schemaValidator.validate(
      schema: pageAction.argumentsSchema,
      value: arguments,
    );
    final resultSchemaPreflight = _schemaValidator.validate(
      schema: pageAction.resultSchema,
      value: const <String, Object?>{},
    );
    return argumentValidation.isValid && resultSchemaPreflight.schemaValid;
  }

  bool _revalidateApprovedPageAction({
    required _ApprovedAppControlAction approved,
    required AgentUiControlService uiControl,
    required AgentUiControlLease lease,
    required AppControlPageAdapter adapter,
    required String targetRoute,
    required AppControlPageAction pageAction,
    required Map<String, Object?> arguments,
  }) {
    final now = _readNow();
    final monotonicNow = _readMonotonicNow();
    if (now == null ||
        monotonicNow == null ||
        !now.isBefore(approved.request.expiresAt) ||
        monotonicNow >= approved.monotonicDeadline ||
        !identical(ActionInvocationContext.current, approved.invocation) ||
        !approved.invocation.isCurrent ||
        !identical(approved.pageAction, pageAction) ||
        !identical(approved.request.arguments, arguments) ||
        !identical(approved.command.arguments, arguments) ||
        approved.command.actionId != approved.request.actionId ||
        approved.command.pageActionId != pageAction.id ||
        approved.command.targetRoute != targetRoute ||
        approved.command.target != approved.request.target ||
        !_hostCommandExecutorIsCurrent(
          approved.commandExecutor,
          approved.command,
        ) ||
        !_revalidateCurrentPageAction(
          uiControl: uiControl,
          lease: lease,
          adapter: adapter,
          targetRoute: targetRoute,
          pageAction: pageAction,
          arguments: arguments,
        )) {
      return false;
    }
    final semanticTarget = pageAction.normalizedApprovalTarget;
    final target = semanticTarget == null
        ? null
        : _approvalTarget(
            targetRoute: targetRoute,
            actionId: pageAction.id,
            semanticTarget: semanticTarget,
          );
    return target == approved.request.target;
  }

  AppControlHostCommand? _buildHostCommand({
    required String page,
    required String targetRoute,
    required AppControlPageAction pageAction,
    required Map<String, Object?> arguments,
  }) {
    final semanticTarget = pageAction.normalizedApprovalTarget;
    final target = semanticTarget == null
        ? null
        : _approvalTarget(
            targetRoute: targetRoute,
            actionId: pageAction.id,
            semanticTarget: semanticTarget,
          );
    if (target == null) return null;
    return AppControlHostCommand.host(
      actionId: 'app_control.$page.${pageAction.id}',
      pageActionId: pageAction.id,
      targetRoute: targetRoute,
      target: target,
      arguments: arguments,
    );
  }

  bool _hostCommandExecutorIsCurrent(
    AppControlHostCommandExecutor executor,
    AppControlHostCommand command,
  ) {
    if (!identical(_readHostCommandExecutor(), executor)) return false;
    try {
      return executor.supports(command);
    } catch (_) {
      return false;
    }
  }

  ActionAuditEntry? _appendAudit({
    required ActionAuditLog auditLog,
    required ActionApprovalRequest request,
    required AppControlPageAction pageAction,
    required ActionAuditStage stage,
    required ActionAuditOutcome outcome,
    required String code,
    required DateTime occurredAt,
  }) {
    try {
      return auditLog.append(
        stage: stage,
        accountScope: request.accountScope,
        agentId: request.agentId,
        runtimeGeneration: request.runtimeGeneration,
        callId: request.callId,
        actionId: request.actionId,
        arguments: request.arguments,
        target: request.target,
        risk: pageAction.risk,
        consequencePolicy: pageAction.consequencePolicy,
        outcome: outcome,
        code: code,
        occurredAt: occurredAt,
      );
    } catch (_) {
      return null;
    }
  }

  bool _appendApprovedAudit(
    _ApprovedAppControlAction approved, {
    required ActionAuditStage stage,
    required ActionAuditOutcome outcome,
    required String code,
  }) {
    final now = _readNow();
    if (now == null) return false;
    final entry = _appendAudit(
      auditLog: approved.auditLog,
      request: approved.request,
      pageAction: approved.pageAction,
      stage: stage,
      outcome: outcome,
      code: code,
      occurredAt: now,
    );
    return entry?.auditId == approved.auditId;
  }

  DateTime? _readNow() {
    try {
      final value = _now().toUtc();
      return value.year >= 1970 && value.year <= 9999 ? value : null;
    } catch (_) {
      return null;
    }
  }

  Duration? _readMonotonicNow() {
    try {
      final value = _monotonicNow();
      return value.isNegative || value > const Duration(days: 36500)
          ? null
          : value;
    } catch (_) {
      return null;
    }
  }

  static String? _approvalTarget({
    required String targetRoute,
    required String actionId,
    required String semanticTarget,
  }) {
    final target = '$targetRoute#$actionId:$semanticTarget';
    if (target.runes.length > 1024 ||
        RegExp(r'[\x00-\x1F\x7F-\x9F]').hasMatch(target)) {
      return null;
    }
    return target;
  }

  String _listCapabilities(List<dynamic> _) => jsonEncode(<String, Object>{
    'pages': <Object>[
      for (final destination in _availableDestinations)
        <String, Object>{
          'id': destination.id,
          'route': destination.route,
          'variants': <Object>[
            for (final variant in destination.variants)
              <String, String>{'id': variant.id, 'route': variant.route},
          ],
        },
    ],
    if (_freshCapabilityLease() case final lease?)
      'capabilityGeneration': lease.generation,
    'pageActionProtocol':
        'Navigate first, then execute only an action declared by the mounted AppControlPageAdapter.',
  });

  bool _capabilityAllowsDestination(
    AppDestination destination,
    AppCapabilitySnapshotLease? lease,
  ) {
    final service = _capabilitySnapshotService;
    if (service == null) return true;
    return lease != null &&
        service.isCurrent(lease) &&
        lease.snapshot.allows(
          AppCapabilityKey.route(destination.id),
          requireVisible: true,
        );
  }

  bool _capabilityAllowsPageAction(
    AppDestination destination,
    AppControlPageAction action,
    AppCapabilitySnapshotLease? lease,
  ) {
    if (!_capabilityAllowsDestination(destination, lease)) return false;
    final service = _capabilitySnapshotService;
    if (service == null || action.requiredCapabilities.isEmpty) return true;
    return lease != null &&
        service.isCurrent(lease) &&
        lease.snapshot
            .rejected(action.requiredCapabilities, requireVisible: true)
            .isEmpty;
  }

  Future<AgentUiControlResult<AppControlPageAdapter>> _waitForRoute({
    required AgentUiControlService uiControl,
    required AgentUiControlLease lease,
    required String targetRoute,
    required bool requireAdapter,
    required Object? Function() navigationFailure,
  }) async {
    final deadline = DateTime.now().add(_routeReadinessTimeout);
    do {
      final leaseCheck = uiControl.coordinator.checkLease(lease);
      if (!leaseCheck.isSuccess) {
        return leaseCheck.asFailure<AppControlPageAdapter>();
      }
      if (navigationFailure() != null) {
        return const AgentUiControlResult<AppControlPageAdapter>.failure(
          AgentUiControlResultStatus.executionFailed,
          message: 'Navigation failed.',
        );
      }
      try {
        await _routeReadinessBarrier().timeout(_routeReadinessTimeout);
      } on TimeoutException {
        return const AgentUiControlResult<AppControlPageAdapter>.failure(
          AgentUiControlResultStatus.pageNotReady,
          message: 'The target route did not become ready.',
        );
      }
      if (_sameRoute(_navigation.currentRoute, targetRoute)) {
        if (!requireAdapter) {
          return AgentUiControlResult<AppControlPageAdapter>.success();
        }
        final resolved = uiControl.adapters.resolve<AppControlPageAdapter>(
          route: targetRoute,
          lease: lease,
        );
        if (resolved.isSuccess) return resolved;
        if (resolved.status != AgentUiControlResultStatus.pageNotReady) {
          return resolved;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    } while (DateTime.now().isBefore(deadline));
    return const AgentUiControlResult<AppControlPageAdapter>.failure(
      AgentUiControlResultStatus.pageNotReady,
      message: 'No AppControl page adapter became ready.',
    );
  }

  static Map<String, Object?> _decode(List<dynamic> args) {
    if (args.isEmpty) throw const FormatException('missing args');
    final raw = args.first;
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) throw const FormatException('expected object');
    return Map<String, Object?>.from(decoded);
  }

  static bool _sameRoute(String current, String target) {
    final currentUri = Uri.tryParse(current);
    final targetUri = Uri.tryParse(target);
    if (currentUri == null ||
        targetUri == null ||
        currentUri.path.isEmpty ||
        currentUri.path != targetUri.path ||
        currentUri.scheme != targetUri.scheme ||
        currentUri.userInfo != targetUri.userInfo ||
        currentUri.host != targetUri.host ||
        currentUri.port != targetUri.port ||
        currentUri.fragment != targetUri.fragment) {
      return false;
    }
    return _sameQueryParameters(
      currentUri.queryParametersAll,
      targetUri.queryParametersAll,
    );
  }

  static bool _sameQueryParameters(
    Map<String, List<String>> left,
    Map<String, List<String>> right,
  ) {
    if (left.length != right.length ||
        !left.keys.toSet().containsAll(right.keys)) {
      return false;
    }
    for (final key in left.keys) {
      final leftValues = List<String>.of(left[key]!)..sort();
      final rightValues = List<String>.of(right[key]!)..sort();
      if (leftValues.length != rightValues.length) return false;
      for (var index = 0; index < leftValues.length; index += 1) {
        if (leftValues[index] != rightValues[index]) return false;
      }
    }
    return true;
  }

  static Future<void> _defaultRouteReadinessBarrier() async {
    await SchedulerBinding.instance.endOfFrame;
  }

  String _failCapability(
    AgentUiControlService uiControl,
    AgentUiControlLease lease,
    String code, {
    required AppCapabilitySnapshotLease? capabilityLease,
    Iterable<AppCapabilityKey> requiredKeys = const <AppCapabilityKey>[],
  }) {
    uiControl.coordinator.fail(lease, message: code);
    return _capabilityError(
      code,
      capabilityLease: capabilityLease,
      requiredKeys: requiredKeys,
    );
  }

  String _capabilityError(
    String code, {
    required AppCapabilitySnapshotLease? capabilityLease,
    Iterable<AppCapabilityKey> requiredKeys = const <AppCapabilityKey>[],
  }) {
    final reasons = <String>{};
    if (!_capabilityLeaseIsCurrent(capabilityLease)) {
      reasons.add('capability_snapshot_stale');
    }
    if (capabilityLease != null) {
      for (final rejected
          in capabilityLease.snapshot
              .rejected(requiredKeys, requireVisible: true)
              .values) {
        reasons.addAll(rejected);
      }
    }
    final orderedReasons = reasons.toList(growable: false)..sort();
    return jsonEncode(<String, Object>{
      'status': 'error',
      'error': code,
      if (capabilityLease != null)
        'capabilityGeneration': capabilityLease.generation,
      if (orderedReasons.isNotEmpty) 'reasons': orderedReasons,
    });
  }

  static String _fail(
    AgentUiControlService uiControl,
    AgentUiControlLease lease,
    String code,
  ) {
    uiControl.coordinator.fail(lease, message: code);
    return _error(code);
  }

  static String _uiControlError(AgentUiControlResult<Object?> result) =>
      _error(result.reason ?? 'execution_failed');

  static String _failExecutionResultUnknown(
    AgentUiControlService uiControl,
    AgentUiControlLease lease,
    String auditId,
  ) {
    uiControl.coordinator.fail(lease, message: 'execution_result_unknown');
    return jsonEncode(<String, String>{
      'status': 'error',
      'error': 'execution_result_unknown',
      'auditId': auditId,
    });
  }

  static String _error(String code) =>
      jsonEncode(<String, String>{'status': 'error', 'error': code});
}

final class _AppControlApprovalGate {
  const _AppControlApprovalGate.allowed(this.approved) : error = null;

  const _AppControlApprovalGate.denied(this.error) : approved = null;

  final _ApprovedAppControlAction? approved;
  final String? error;
}

final class _ApprovedAppControlAction {
  const _ApprovedAppControlAction({
    required this.invocation,
    required this.request,
    required this.pageAction,
    required this.auditLog,
    required this.auditId,
    required this.monotonicDeadline,
    required this.commandExecutor,
    required this.command,
  });

  final ActionInvocationContext invocation;
  final ActionApprovalRequest request;
  final AppControlPageAction pageAction;
  final ActionAuditLog auditLog;
  final String auditId;
  final Duration monotonicDeadline;
  final AppControlHostCommandExecutor commandExecutor;
  final AppControlHostCommand command;
}

final Stopwatch _appControlApprovalMonotonicClock = Stopwatch()..start();

final class _ApprovalHostOutcome {
  const _ApprovalHostOutcome.decided(this.decision) : failureCode = null;

  const _ApprovalHostOutcome.cancelled(this.failureCode)
    : decision = ActionApprovalDecision.cancel;

  final ActionApprovalDecision decision;
  final String? failureCode;
}
