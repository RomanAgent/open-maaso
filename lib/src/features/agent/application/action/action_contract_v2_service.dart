import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';

import 'action_audit_log.dart';
import 'action_contract_legacy_adapter.dart';
import 'action_contract_v2_audit_store.dart';
import 'action_definition.dart';
import 'action_json_snapshot.dart';
import 'action_schema_validator.dart';
import 'agent_action_envelope.dart';
import 'production_action_definition_catalog.dart';
import 'tool_outcome.dart';

/// Exact account and call identity supplied by an existing execution owner.
final class ActionContractInvocationScope {
  const ActionContractInvocationScope({
    required this.accountScope,
    required this.accountGeneration,
    required this.agentId,
    required this.callId,
  });

  final String accountScope;
  final int accountGeneration;
  final String agentId;
  final String callId;
}

/// One model-authored or host-derived action proposed for whole-batch admission.
///
/// Host-generated fallback or auto-reaction work is still represented as an
/// explicit call (normally on [ActionContractChannel.synthetic]); the service
/// never manufactures an implicit side effect.
final class ActionContractCall {
  const ActionContractCall({
    required this.actionId,
    required this.arguments,
    this.target,
    this.channel,
    this.expectedDefinition,
  });

  final String actionId;
  final Object? arguments;
  final String? target;
  final ActionContractChannel? channel;

  /// Exact metadata object resolved by the existing host owner.
  ///
  /// Enforce mode requires this to be identical to the catalog entry. The
  /// object is host-only and is never serialized into model-visible JSON.
  final ProductionActionDefinition? expectedDefinition;
}

/// Immutable request description used for admission and final revalidation.
final class ActionContractEnvelopeRequest {
  ActionContractEnvelopeRequest({
    required this.invocation,
    required this.scope,
    required this.channel,
    required List<ActionContractCall> actions,
  }) : actions = _boundedActionCalls(actions);

  final ActionContractInvocationScope invocation;
  final AgentActionScope scope;
  final ActionContractChannel channel;
  final List<ActionContractCall> actions;
}

/// Stable, value-redacting observation emitted by the V2 foundation.
final class ActionContractDiagnostic {
  const ActionContractDiagnostic({required this.code, this.actionIndex});

  final String code;
  final int? actionIndex;
}

/// Opaque admission returned by [ActionContractV2Service.prepare].
///
/// There is no public ticket constructor and an admission can be consumed only
/// by the service instance that issued it.
final class ActionContractAdmission {
  ActionContractAdmission._({
    required ActionContractV2Service owner,
    required this.mode,
    required this.admitted,
    required List<ActionContractDiagnostic> diagnostics,
    required _AdmissionRecord? record,
  }) : _owner = owner,
       diagnostics = List<ActionContractDiagnostic>.unmodifiable(diagnostics),
       _record = record;

  final ActionContractV2Service _owner;
  final _AdmissionRecord? _record;
  final FeatureRolloutMode mode;
  final bool admitted;
  final List<ActionContractDiagnostic> diagnostics;
  bool _consumed = false;

  bool get isEnforced => mode == FeatureRolloutMode.enforce;
}

enum ActionContractExecutionStatus { legacy, enforced, rejected }

/// Result of consuming one opaque admission.
final class ActionContractExecutionResult {
  const ActionContractExecutionResult._({
    required this.status,
    this.legacyOutput,
    this.outcome,
  });

  factory ActionContractExecutionResult.legacy(Object? output) =>
      ActionContractExecutionResult._(
        status: ActionContractExecutionStatus.legacy,
        legacyOutput: output,
      );

  factory ActionContractExecutionResult.enforced(ToolOutcome outcome) =>
      ActionContractExecutionResult._(
        status: ActionContractExecutionStatus.enforced,
        outcome: outcome,
      );

  factory ActionContractExecutionResult.rejected(ToolOutcome outcome) =>
      ActionContractExecutionResult._(
        status: ActionContractExecutionStatus.rejected,
        outcome: outcome,
      );

  final ActionContractExecutionStatus status;
  final Object? legacyOutput;
  final ToolOutcome? outcome;

  Object? get outputForCaller => status == ActionContractExecutionStatus.legacy
      ? legacyOutput
      : outcome?.toJsonString();
}

/// Content-safe audit request emitted before or after a V2 execution.
final class ActionContractAuditRecord {
  const ActionContractAuditRecord({
    required this.stage,
    required this.invocation,
    required this.actionIndex,
    required this.channel,
    required this.definition,
    required this.arguments,
    required this.target,
    required this.outcome,
    required this.code,
    required this.occurredAt,
  });

  final ActionAuditStage stage;
  final ActionContractInvocationScope invocation;
  final int actionIndex;
  final ActionContractChannel channel;
  final ActionDefinition definition;
  final Object? arguments;
  final String target;
  final ActionAuditOutcome outcome;
  final String code;
  final DateTime occurredAt;
}

abstract interface class ActionContractV2AuditSink {
  FutureOr<String?> record(ActionContractAuditRecord record);
}

/// Adapter for the existing privacy-preserving, bounded action audit log.
final class ActionAuditLogContractV2Sink implements ActionContractV2AuditSink {
  const ActionAuditLogContractV2Sink(
    this.log, {
    ActionContractV2AuditPersistence? persistence,
  }) : _persistence = persistence;

  final ActionAuditLog log;
  final ActionContractV2AuditPersistence? _persistence;

  @override
  FutureOr<String> record(ActionContractAuditRecord record) {
    final entry = log.append(
      stage: record.stage,
      accountScope: record.invocation.accountScope,
      agentId: record.invocation.agentId,
      runtimeGeneration: record.invocation.accountGeneration,
      callId: record.invocation.callId,
      actionId: record.definition.id,
      // ActionAuditLog intentionally derives one stable audit id from its
      // identity binding. Adding index/channel to the digested payload keeps
      // every lifecycle stage continuous while making duplicate actions in
      // one envelope distinct. Raw values are still never retained.
      arguments: <String, Object?>{
        'contract': <String, Object?>{
          'version': 2,
          'actionIndex': record.actionIndex,
          'channel': record.channel.name,
        },
        'payload': record.arguments,
      },
      target: record.target,
      risk: record.definition.risk,
      consequencePolicy: record.definition.consequencePolicy,
      outcome: record.outcome,
      code: record.code,
      occurredAt: record.occurredAt,
    );
    final persistence = _persistence;
    if (persistence == null) return entry.auditId;
    return persistence.append(entry).then((_) => entry.auditId);
  }
}

/// Account-owned Action Contract V2 admission and compatibility foundation.
///
/// The service reads only the `action_contract_v2` mode/generation. It never
/// mutates feature assignments and never calls `ActionDefinition.handler`.
final class ActionContractV2Service extends AppService {
  ActionContractV2Service({
    required MaasoFeatureFlagService featureFlags,
    required ProductionActionDefinitionCatalog catalog,
    required ActionContractV2AuditSink audit,
    required String accountScope,
    required int accountGeneration,
    required bool Function() mountIsCurrent,
    Set<ActionEnforcementEligibility> enforcedEligibilities = const {
      ActionEnforcementEligibility.readOnly,
    },
    Set<String> enforcedReversibleLocalActionIds = const <String>{},
    DateTime Function()? clock,
    Duration Function()? monotonicNow,
    Duration ticketTtl = const Duration(minutes: 2),
    Duration invocationRetention = const Duration(minutes: 10),
    Duration auditDeadline = const Duration(seconds: 2),
    Duration readOnlyCallbackDeadline = const Duration(seconds: 30),
    this.maximumPendingTickets = 128,
    this.maximumInvocationRecords = 512,
    this.maximumActiveEnforcedOperations = 64,
    this.maximumDiagnostics = 256,
    this.maximumActions = 64,
    this.maximumEnvelopeNodes = 4096,
    this.maximumEnvelopeDepth = 64,
    this.maximumStringRunes = 16384,
  }) : _featureFlags = featureFlags,
       _catalog = catalog,
       _audit = audit,
       _accountScope = accountScope.trim(),
       _accountGeneration = accountGeneration,
       _mountIsCurrent = mountIsCurrent,
       _enforcedEligibilities = Set<ActionEnforcementEligibility>.unmodifiable(
         enforcedEligibilities,
       ),
       _enforcedReversibleLocalActionIds = Set<String>.unmodifiable(
         enforcedReversibleLocalActionIds,
       ),
       _clock = clock ?? DateTime.now,
       _monotonicNow = monotonicNow ?? _defaultMonotonicNow,
       _ticketTtl = ticketTtl,
       _invocationRetention = invocationRetention,
       _auditDeadline = auditDeadline,
       _readOnlyCallbackDeadline = readOnlyCallbackDeadline {
    if (_accountScope.isEmpty ||
        _accountScope.runes.length > 512 ||
        accountGeneration < 0 ||
        ticketTtl <= Duration.zero ||
        ticketTtl > const Duration(minutes: 5) ||
        invocationRetention < ticketTtl ||
        invocationRetention > const Duration(hours: 24) ||
        auditDeadline <= Duration.zero ||
        auditDeadline >= ticketTtl ||
        readOnlyCallbackDeadline <= Duration.zero ||
        readOnlyCallbackDeadline > const Duration(minutes: 5) ||
        maximumPendingTickets < 1 ||
        maximumPendingTickets > 4096 ||
        maximumInvocationRecords < maximumPendingTickets ||
        maximumInvocationRecords > 16384 ||
        maximumActiveEnforcedOperations < 1 ||
        maximumActiveEnforcedOperations > 4096 ||
        maximumDiagnostics < 1 ||
        maximumDiagnostics > 16384 ||
        maximumActions < 1 ||
        maximumActions > 1024 ||
        maximumEnvelopeNodes < 16 ||
        maximumEnvelopeNodes > 65536 ||
        maximumEnvelopeDepth < 1 ||
        maximumEnvelopeDepth > 128 ||
        maximumStringRunes < 1 ||
        maximumStringRunes > 65536 ||
        _enforcedReversibleLocalActionIds.any(
          (id) =>
              id.isEmpty ||
              id.length > 128 ||
              !RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(id),
        ) ||
        _enforcedEligibilities.contains(
          ActionEnforcementEligibility.domainAuthorized,
        ) ||
        _enforcedEligibilities.contains(
          ActionEnforcementEligibility.unsupported,
        )) {
      throw ArgumentError('invalid_action_contract_v2_configuration');
    }
  }

  final MaasoFeatureFlagService _featureFlags;
  final ProductionActionDefinitionCatalog _catalog;
  final ActionContractV2AuditSink _audit;
  final String _accountScope;
  final int _accountGeneration;
  final bool Function() _mountIsCurrent;
  final Set<ActionEnforcementEligibility> _enforcedEligibilities;

  /// Host-selected exceptions for exact reversible local operations. This does
  /// not grant an action, widen its scopes, or admit a different risk class.
  final Set<String> _enforcedReversibleLocalActionIds;
  final DateTime Function() _clock;
  final Duration Function() _monotonicNow;
  final Duration _ticketTtl;
  final Duration _invocationRetention;
  final Duration _auditDeadline;
  final Duration _readOnlyCallbackDeadline;

  final int maximumPendingTickets;
  final int maximumInvocationRecords;
  final int maximumActiveEnforcedOperations;
  final int maximumDiagnostics;
  final int maximumActions;
  final int maximumEnvelopeNodes;
  final int maximumEnvelopeDepth;
  final int maximumStringRunes;

  static const ActionSchemaValidator _schemaValidator = ActionSchemaValidator();
  final LinkedHashMap<String, _TicketSlot> _pendingTickets =
      LinkedHashMap<String, _TicketSlot>();
  final LinkedHashMap<_SemanticInvocationKey, _SemanticInvocationRecord>
  _semanticInvocations =
      LinkedHashMap<_SemanticInvocationKey, _SemanticInvocationRecord>();
  final ListQueue<ActionContractDiagnostic> _diagnostics =
      ListQueue<ActionContractDiagnostic>();
  final Set<Future<void>> _activeOperations = <Future<void>>{};
  Completer<void>? _drainCompleter;
  Future<void>? _drainFuture;
  int _activeEnforcedOperations = 0;
  bool _sealed = false;

  bool get isSealed => _sealed;
  int get pendingTicketCount => _pendingTickets.length;
  int get semanticInvocationCount => _semanticInvocations.length;
  int get activeOperationCount => _activeOperations.length;
  int get activeEnforcedOperationCount => _activeEnforcedOperations;
  List<ActionContractDiagnostic> get recentDiagnostics =>
      List<ActionContractDiagnostic>.unmodifiable(_diagnostics);

  /// Creates the account-owned invocation identity used by every channel.
  ///
  /// Semantic reservation happens later in [prepare], once the immutable
  /// envelope fingerprint exists. Returning `null` is the fixed fail-closed
  /// result for a stale mount, sealed service, or invalid host identifier.
  ActionContractInvocationScope? issueInvocation({
    required String agentId,
    required String callId,
  }) {
    if (_sealed ||
        !_safeIdentifier(agentId, 256) ||
        !_safeIdentifier(callId, 256)) {
      return null;
    }
    try {
      if (!_mountIsCurrent()) return null;
    } on Object {
      return null;
    }
    return ActionContractInvocationScope(
      accountScope: _accountScope,
      accountGeneration: _accountGeneration,
      agentId: agentId.trim(),
      callId: callId.trim(),
    );
  }

  Future<ActionContractAdmission> prepare(
    ActionContractEnvelopeRequest request,
  ) {
    final authority = _readAuthority();
    if (_sealed || !_requestScopeIsCurrent(request) || authority == null) {
      return Future<ActionContractAdmission>.value(
        _rejected(
          authority?.mode ?? FeatureRolloutMode.enforce,
          const <ActionContractDiagnostic>[
            ActionContractDiagnostic(code: 'authority_stale'),
          ],
        ),
      );
    }
    if (authority.mode != FeatureRolloutMode.enforce) {
      return Future<ActionContractAdmission>.value(
        _prepareCompatibility(request, authority),
      );
    }
    if (!_acquireEnforcedOperation()) {
      const diagnostic = ActionContractDiagnostic(
        code: 'active_operation_capacity_exhausted',
      );
      _retainDiagnostics(const <ActionContractDiagnostic>[diagnostic]);
      return Future<ActionContractAdmission>.value(
        _rejected(authority.mode, const <ActionContractDiagnostic>[diagnostic]),
      );
    }
    return _trackAcquired(
      () => _prepareEnforced(request, authority),
      enforced: true,
    );
  }

  ActionContractAdmission _prepareCompatibility(
    ActionContractEnvelopeRequest request,
    _AuthoritySnapshot authority,
  ) {
    var resolved = const _ResolvedEnvelope.empty();
    if (authority.mode == FeatureRolloutMode.shadow) {
      try {
        resolved = _resolve(request);
        _retainDiagnostics(resolved.diagnostics);
        _scheduleShadowAudit(
          invocation: request.invocation,
          resolved: resolved,
          stage: ActionAuditStage.decided,
          outcome: ActionAuditOutcome.proposed,
          code: 'v2.shadow_observed',
        );
      } on Object {
        const diagnostic = ActionContractDiagnostic(code: 'invalid_envelope');
        _retainDiagnostics(const <ActionContractDiagnostic>[diagnostic]);
      }
    }
    final record = _AdmissionRecord(
      mode: authority.mode,
      authorityGeneration: authority.generation,
      accountScope: _accountScope,
      accountGeneration: _accountGeneration,
      agentId: request.invocation.agentId.trim(),
      callId: request.invocation.callId.trim(),
      requestFingerprint: resolved.fingerprint,
      resolvedActions: resolved.actions,
      auditIds: const <String?>[],
      deadline: null,
      nonce: null,
      adapter: ActionContractLegacyAdapter(),
      semanticInvocation: null,
    );
    return ActionContractAdmission._(
      owner: this,
      mode: authority.mode,
      admitted: true,
      diagnostics: resolved.diagnostics,
      record: record,
    );
  }

  Future<ActionContractAdmission> _prepareEnforced(
    ActionContractEnvelopeRequest request,
    _AuthoritySnapshot authority,
  ) async {
    final resolved = _resolve(request);
    _retainDiagnostics(resolved.diagnostics);

    // Reservation is intentionally before this method's first await. A second
    // prepare for the same semantic call therefore cannot race the audit write.
    _pruneExpiredTickets();
    final reservation = _reserveSemanticInvocation(request, resolved);
    if (!reservation.isReserved) {
      final diagnostic = ActionContractDiagnostic(code: reservation.code);
      _retainDiagnostics(<ActionContractDiagnostic>[diagnostic]);
      return _rejected(authority.mode, <ActionContractDiagnostic>[
        ...resolved.diagnostics,
        diagnostic,
      ]);
    }
    final semantic = reservation.record!;
    if (resolved.diagnostics.isNotEmpty) {
      _finishSemanticInvocation(semantic, _SemanticInvocationState.rejected);
      return _rejected(authority.mode, resolved.diagnostics);
    }

    if (_pendingTickets.length >= maximumPendingTickets) {
      const diagnostic = ActionContractDiagnostic(
        code: 'ticket_capacity_exhausted',
      );
      _retainDiagnostics(const <ActionContractDiagnostic>[diagnostic]);
      _finishSemanticInvocation(semantic, _SemanticInvocationState.rejected);
      return _rejected(authority.mode, const <ActionContractDiagnostic>[
        diagnostic,
      ]);
    }
    final nonce = _newNonce();
    if (nonce == null) {
      _finishSemanticInvocation(semantic, _SemanticInvocationState.rejected);
      return _rejected(authority.mode, const <ActionContractDiagnostic>[
        ActionContractDiagnostic(code: 'ticket_unavailable'),
      ]);
    }
    final deadline = _monotonicNow() + _ticketTtl;
    final slot = _TicketSlot(deadline: deadline, semanticInvocation: semantic);
    _pendingTickets[nonce] = slot;

    final auditIds = await _recordDecisionAudits(request, resolved);
    if (auditIds == null) {
      _pendingTickets.remove(nonce);
      _finishSemanticInvocation(semantic, _SemanticInvocationState.rejected);
      const diagnostic = ActionContractDiagnostic(code: 'audit_unavailable');
      _retainDiagnostics(const <ActionContractDiagnostic>[diagnostic]);
      return _rejected(authority.mode, const <ActionContractDiagnostic>[
        diagnostic,
      ]);
    }

    if (!_enforcedPreparationIsCurrent(
      request: request,
      authority: authority,
      resolved: resolved,
      semantic: semantic,
    )) {
      _pendingTickets.remove(nonce);
      _finishSemanticInvocation(semantic, _SemanticInvocationState.rejected);
      return _rejected(authority.mode, const <ActionContractDiagnostic>[
        ActionContractDiagnostic(code: 'authority_stale'),
      ]);
    }

    final record = _AdmissionRecord(
      mode: authority.mode,
      authorityGeneration: authority.generation,
      accountScope: _accountScope,
      accountGeneration: _accountGeneration,
      agentId: request.invocation.agentId.trim(),
      callId: request.invocation.callId.trim(),
      requestFingerprint: resolved.fingerprint,
      resolvedActions: resolved.actions,
      auditIds: List<String?>.unmodifiable(auditIds),
      deadline: deadline,
      nonce: nonce,
      adapter: ActionContractLegacyAdapter(),
      semanticInvocation: semantic,
    );
    slot.record = record;
    semantic.state = _SemanticInvocationState.admitted;
    return ActionContractAdmission._(
      owner: this,
      mode: authority.mode,
      admitted: true,
      diagnostics: resolved.diagnostics,
      record: record,
    );
  }

  Future<ActionContractExecutionResult> execute({
    required ActionContractAdmission admission,
    required ActionContractEnvelopeRequest currentRequest,
    required ActionContractLegacyCallback legacyCallback,
  }) {
    if (!identical(admission._owner, this) || admission._consumed) {
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('ticket_invalid'),
      );
    }
    admission._consumed = true;
    final record = admission._record;
    if (!admission.admitted || record == null) {
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('contract_rejected'),
      );
    }
    if (record.mode != FeatureRolloutMode.enforce) {
      if (!_compatibilityRecordIsCurrent(record, currentRequest)) {
        return Future<ActionContractExecutionResult>.value(
          _fixedRejection('ticket_stale'),
        );
      }
      return _trackAcquired(
        () => _executeCompatibility(record, legacyCallback),
        enforced: false,
      );
    }

    if (!_consumeEnforcedTicket(record)) {
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('ticket_stale'),
      );
    }
    final semantic = record.semanticInvocation!;
    if (_sealed ||
        !_semanticRecordIs(record, _SemanticInvocationState.admitted)) {
      _finishSemanticInvocation(semantic, _SemanticInvocationState.rejected);
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('ticket_stale'),
      );
    }
    if (!_acquireEnforcedOperation()) {
      _finishSemanticInvocation(semantic, _SemanticInvocationState.failed);
      return _trackAcquired(
        () => _finishWithoutExecution(
          record,
          code: 'active_operation_capacity_exhausted',
        ),
        enforced: false,
      );
    }
    semantic.state = _SemanticInvocationState.executing;
    return _trackAcquired(
      () => _executeEnforced(record, currentRequest, legacyCallback),
      enforced: true,
    );
  }

  /// Consumes an admission without invoking its legacy callback.
  ///
  /// Enforced invocations retain their semantic tombstone and emit a terminal
  /// cancellation audit under the original receipt identity.
  Future<ActionContractExecutionResult> abandon({
    required ActionContractAdmission admission,
    required ActionContractEnvelopeRequest currentRequest,
    String code = 'caller_cancelled',
  }) {
    if (!identical(admission._owner, this) || admission._consumed) {
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('ticket_invalid'),
      );
    }
    admission._consumed = true;
    final record = admission._record;
    if (!admission.admitted || record == null) {
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('contract_rejected'),
      );
    }
    if (record.mode != FeatureRolloutMode.enforce) {
      final safeCode = _sameInvocationIdentity(record, currentRequest)
          ? _safeOutcomeCode(code, fallback: 'caller_cancelled')
          : 'abandon_stale';
      if (record.mode == FeatureRolloutMode.shadow) {
        _scheduleShadowRecordAudit(
          record: record,
          stage: ActionAuditStage.result,
          outcome: ActionAuditOutcome.cancelled,
          code: safeCode,
        );
      }
      return Future<ActionContractExecutionResult>.value(
        ActionContractExecutionResult.rejected(
          ToolOutcome.failure(
            status: ToolOutcomeStatus.cancelled,
            code: safeCode,
          ),
        ),
      );
    }
    final current = _recordIsCurrent(
      record,
      currentRequest,
      semanticState: _SemanticInvocationState.admitted,
    );
    if (!_consumeEnforcedTicket(record)) {
      return Future<ActionContractExecutionResult>.value(
        _fixedRejection('ticket_stale'),
      );
    }
    final safeCode = current
        ? _safeOutcomeCode(code, fallback: 'caller_cancelled')
        : 'abandon_stale';
    _finishSemanticInvocation(
      record.semanticInvocation!,
      _SemanticInvocationState.abandoned,
    );
    return _trackAcquired(() async {
      final audited = await _recordLifecycleAudits(
        record,
        stage: ActionAuditStage.result,
        outcome: ActionAuditOutcome.cancelled,
        code: safeCode,
        requireContinuity: true,
      );
      if (!audited) return _fixedRejection('audit_unavailable');
      return ActionContractExecutionResult.rejected(
        ToolOutcome.failure(
          status: ToolOutcomeStatus.cancelled,
          code: safeCode,
          auditId: _firstAuditId(record),
        ),
      );
    }, enforced: false);
  }

  Future<ActionContractExecutionResult> _executeCompatibility(
    _AdmissionRecord record,
    ActionContractLegacyCallback callback,
  ) async {
    late final ActionContractLegacyResult legacy;
    try {
      legacy = await record.adapter.invokeOnce(callback);
    } catch (error, stackTrace) {
      if (record.mode == FeatureRolloutMode.shadow) {
        _scheduleShadowRecordAudit(
          record: record,
          stage: ActionAuditStage.result,
          outcome: ActionAuditOutcome.failed,
          code: 'v2.shadow_failed',
        );
      }
      Error.throwWithStackTrace(error, stackTrace);
    }
    if (record.mode == FeatureRolloutMode.shadow) {
      _observeLegacyOutputs(record, legacy.actionOutputs);
      _scheduleShadowRecordAudit(
        record: record,
        stage: ActionAuditStage.result,
        outcome: ActionAuditOutcome.succeeded,
        code: 'v2.shadow_completed',
      );
    }
    return ActionContractExecutionResult.legacy(legacy.callerOutput);
  }

  Future<ActionContractExecutionResult> _executeEnforced(
    _AdmissionRecord record,
    ActionContractEnvelopeRequest request,
    ActionContractLegacyCallback callback,
  ) async {
    if (!_recordIsCurrent(record, request)) {
      return _finishStaleExecution(record, 'ticket_stale');
    }
    if (record.resolvedActions.isEmpty) {
      final audited = await _recordLifecycleAudits(
        record,
        stage: ActionAuditStage.result,
        outcome: ActionAuditOutcome.succeeded,
        code: 'v2.noop_succeeded',
        requireContinuity: true,
      );
      _finishSemanticInvocation(
        record.semanticInvocation!,
        audited
            ? _SemanticInvocationState.succeeded
            : _SemanticInvocationState.failed,
      );
      if (!audited) return _fixedRejection('audit_unavailable');
      return ActionContractExecutionResult.enforced(
        ToolOutcome.ok(data: const <Object?>[]),
      );
    }

    final executionAudited = await _recordLifecycleAudits(
      record,
      stage: ActionAuditStage.executed,
      outcome: ActionAuditOutcome.started,
      code: 'v2.execution_started',
      requireContinuity: true,
    );
    if (!executionAudited) {
      _finishSemanticInvocation(
        record.semanticInvocation!,
        _SemanticInvocationState.failed,
      );
      return _fixedRejection('audit_unavailable');
    }
    if (!_recordIsCurrent(record, request)) {
      return _finishStaleExecution(record, 'ticket_stale');
    }

    late final ActionContractLegacyResult legacy;
    try {
      final pending = record.adapter.invokeOnce(callback);
      legacy = _allActionsReadOnly(record)
          ? await pending.timeout(_readOnlyCallbackDeadline)
          : await pending;
    } on TimeoutException {
      return _finishFailedExecution(
        record,
        status: ToolOutcomeStatus.unavailable,
        code: 'execution_timeout',
      );
    } on Object {
      return _finishFailedExecution(
        record,
        status: ToolOutcomeStatus.failed,
        code: 'execution_failed',
      );
    }

    if (!_recordIsCurrent(record, request)) {
      return _finishStaleExecution(record, 'stale_after_execution');
    }

    List<ToolOutcome>? outcomes;
    try {
      outcomes = _validatedOutcomes(record, legacy.actionOutputs);
    } on Object {
      outcomes = null;
    }
    if (outcomes == null) {
      return _finishFailedExecution(
        record,
        status: ToolOutcomeStatus.failed,
        code: 'invalid_tool_outcome',
      );
    }
    final succeeded = outcomes.every((outcome) => outcome.isOk);
    final terminalAuditAvailable = await _recordLifecycleAudits(
      record,
      stage: ActionAuditStage.result,
      outcome: succeeded
          ? ActionAuditOutcome.succeeded
          : ActionAuditOutcome.failed,
      code: succeeded ? 'v2.execution_succeeded' : 'v2.execution_failed',
      requireContinuity: true,
    );
    _finishSemanticInvocation(
      record.semanticInvocation!,
      terminalAuditAvailable && succeeded
          ? _SemanticInvocationState.succeeded
          : _SemanticInvocationState.failed,
    );
    if (!terminalAuditAvailable) {
      return _fixedRejection('audit_unavailable');
    }
    ToolOutcome? firstFailure;
    for (final outcome in outcomes) {
      if (!outcome.isOk) {
        firstFailure = outcome;
        break;
      }
    }
    if (firstFailure != null) {
      return ActionContractExecutionResult.enforced(
        ToolOutcome.failure(
          status: firstFailure.status,
          code: firstFailure.code,
          data: <Object?>[
            for (var index = 0; index < outcomes.length; index += 1)
              if (!outcomes[index].isOk)
                <String, Object?>{
                  'actionIndex': index,
                  'status': outcomes[index].status.wireName,
                  'code': outcomes[index].code,
                  'retryable': outcomes[index].retryable,
                },
          ],
          retryable: firstFailure.retryable,
          auditId: _firstAuditId(record),
        ),
      );
    }
    return ActionContractExecutionResult.enforced(
      ToolOutcome.ok(
        data: <Object?>[for (final outcome in outcomes) outcome.data],
        auditId: _firstAuditId(record),
      ),
    );
  }

  _ResolvedEnvelope _resolve(ActionContractEnvelopeRequest request) {
    final diagnostics = <ActionContractDiagnostic>[];
    if (!_validInvocation(request.invocation)) {
      diagnostics.add(const ActionContractDiagnostic(code: 'invalid_scope'));
    }
    if (request.actions.length > maximumActions) {
      diagnostics.add(const ActionContractDiagnostic(code: 'too_many_actions'));
    }
    final boundedActions = request.actions
        .take(maximumActions)
        .toList(growable: false);
    Object? snapshot;
    try {
      snapshot = snapshotActionJson(
        <String, Object?>{
          'accountScope': request.invocation.accountScope.trim(),
          'accountGeneration': request.invocation.accountGeneration,
          'agentId': request.invocation.agentId.trim(),
          'callId': request.invocation.callId.trim(),
          'scope': request.scope.name,
          'channel': request.channel.name,
          'actionCount': request.actions.length,
          'actions': <Object?>[
            for (final action in boundedActions)
              <String, Object?>{
                'actionId': action.actionId,
                'arguments': action.arguments,
                'target': action.target,
                'channel': action.channel?.name,
                'expectedDefinition': action.expectedDefinition == null
                    ? null
                    : _definitionFingerprint(action.expectedDefinition!),
              },
          ],
        },
        maxDepth: maximumEnvelopeDepth,
        maxNodes: maximumEnvelopeNodes,
        maxStringRunes: maximumStringRunes,
      );
    } on Object {
      diagnostics.add(const ActionContractDiagnostic(code: 'invalid_envelope'));
    }
    final actionSnapshots = snapshot is Map<String, Object?>
        ? snapshot['actions'] as List<Object?>? ?? const <Object?>[]
        : const <Object?>[];
    final resolvedActions = <_ResolvedAction>[];
    for (var index = 0; index < boundedActions.length; index += 1) {
      final raw = boundedActions[index];
      final actionSnapshot = index < actionSnapshots.length
          ? actionSnapshots[index]
          : null;
      final actionMap = actionSnapshot is Map<String, Object?>
          ? actionSnapshot
          : const <String, Object?>{};
      final candidateActionId = (actionMap['actionId'] ?? raw.actionId)
          .toString()
          .trim();
      final actionId = _validActionId(candidateActionId)
          ? candidateActionId
          : '';
      if (actionId.isEmpty) {
        diagnostics.add(
          ActionContractDiagnostic(
            code: 'invalid_action_id',
            actionIndex: index,
          ),
        );
      }
      final arguments = actionMap['arguments'];
      final channel = raw.channel ?? request.channel;
      final argumentsMap = arguments is Map<String, Object?>
          ? Map<String, dynamic>.from(arguments)
          : null;
      final production = _catalog.find(actionId);
      String target = 'action:${actionId.isEmpty ? "unknown" : actionId}';
      if (production == null) {
        diagnostics.add(
          ActionContractDiagnostic(
            code: 'definition_missing',
            actionIndex: index,
          ),
        );
      } else {
        if (_catalog.isConflicted(actionId)) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'definition_conflicted',
              actionIndex: index,
            ),
          );
        }
        if (raw.expectedDefinition == null) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'definition_identity_missing',
              actionIndex: index,
            ),
          );
        } else if (!identical(raw.expectedDefinition, production)) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'definition_identity_mismatch',
              actionIndex: index,
            ),
          );
        }
        final definition = production.definition;
        if (!definition.allowsScope(request.scope)) {
          diagnostics.add(
            ActionContractDiagnostic(code: 'scope_denied', actionIndex: index),
          );
        }
        if (!production.allowsChannel(channel)) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'channel_denied',
              actionIndex: index,
            ),
          );
        }
        if (argumentsMap == null) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'arguments_not_object',
              actionIndex: index,
            ),
          );
        } else {
          final input = _schemaValidator.validate(
            schema: definition.inputSchema,
            value: argumentsMap,
          );
          if (!input.isValid) {
            diagnostics.add(
              ActionContractDiagnostic(
                code: input.schemaValid
                    ? 'invalid_arguments'
                    : 'input_schema_invalid',
                actionIndex: index,
              ),
            );
          }
          try {
            target = definition.resolveTarget(argumentsMap) ?? target;
          } on Object {
            diagnostics.add(
              ActionContractDiagnostic(
                code: 'target_unavailable',
                actionIndex: index,
              ),
            );
          }
        }
        final outputSchema = definition.outputSchema;
        if (outputSchema == null) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'output_schema_missing',
              actionIndex: index,
            ),
          );
        } else if (!_schemaValidator
            .validate(schema: outputSchema, value: null)
            .schemaValid) {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'output_schema_invalid',
              actionIndex: index,
            ),
          );
        }
        final eligibilityCode = _eligibilityError(
          production,
          scope: request.scope,
          agentId: request.invocation.agentId,
          channel: channel,
        );
        if (eligibilityCode != null) {
          diagnostics.add(
            ActionContractDiagnostic(code: eligibilityCode, actionIndex: index),
          );
        }
      }
      if (!_validTarget(target)) {
        diagnostics.add(
          ActionContractDiagnostic(code: 'target_invalid', actionIndex: index),
        );
        target = 'action:invalid';
      }
      final suppliedTarget = actionMap['target']?.toString().trim();
      if (suppliedTarget != null &&
          suppliedTarget.isNotEmpty &&
          suppliedTarget != target) {
        diagnostics.add(
          ActionContractDiagnostic(code: 'target_mismatch', actionIndex: index),
        );
      }
      var definitionFingerprint = '';
      if (production != null) {
        try {
          definitionFingerprint = _definitionFingerprint(production);
        } on Object {
          diagnostics.add(
            ActionContractDiagnostic(
              code: 'definition_invalid',
              actionIndex: index,
            ),
          );
        }
      }
      resolvedActions.add(
        _ResolvedAction(
          actionId: actionId,
          arguments: arguments,
          target: target,
          channel: channel,
          expectedDefinition: raw.expectedDefinition,
          productionDefinition: production,
          definitionFingerprint: definitionFingerprint,
        ),
      );
    }
    final boundedDiagnostics = diagnostics.take(64).toList(growable: false);
    final fingerprint = _fingerprint(<String, Object?>{
      'request': snapshot,
      'resolved': <Object?>[
        for (final action in resolvedActions)
          <String, Object?>{
            'id': action.actionId,
            'target': action.target,
            'channel': action.channel.name,
            'definition': action.definitionFingerprint,
          },
      ],
    });
    return _ResolvedEnvelope(
      fingerprint: fingerprint,
      actions: List<_ResolvedAction>.unmodifiable(resolvedActions),
      diagnostics: List<ActionContractDiagnostic>.unmodifiable(
        boundedDiagnostics,
      ),
    );
  }

  String? _eligibilityError(
    ProductionActionDefinition production, {
    required AgentActionScope scope,
    required String agentId,
    required ActionContractChannel channel,
  }) {
    final definition = production.definition;
    return switch (production.enforcementEligibility) {
      ActionEnforcementEligibility.readOnly
          when definition.risk == ActionRisk.readOnly &&
              definition.consequencePolicy ==
                  ActionConsequencePolicy.reversible &&
              _enforcedEligibilities.contains(
                ActionEnforcementEligibility.readOnly,
              ) =>
        null,
      ActionEnforcementEligibility.reversibleLocal
          when definition.risk == ActionRisk.localMutation &&
              (definition.consequencePolicy ==
                      ActionConsequencePolicy.reversible ||
                  definition.consequencePolicy ==
                      ActionConsequencePolicy.prepareOnly) &&
              (_enforcedEligibilities.contains(
                    ActionEnforcementEligibility.reversibleLocal,
                  ) ||
                  _enforcedReversibleLocalActionIds.contains(definition.id)) =>
        null,
      ActionEnforcementEligibility.domainAuthorized =>
        'domain_authority_required',
      ActionEnforcementEligibility.unsupported => 'enforcement_unsupported',
      _ => 'enforcement_ineligible',
    };
  }

  _SemanticReservation _reserveSemanticInvocation(
    ActionContractEnvelopeRequest request,
    _ResolvedEnvelope resolved,
  ) {
    _pruneSemanticInvocations();
    final key = _SemanticInvocationKey(
      accountScope: _accountScope,
      accountGeneration: _accountGeneration,
      agentId: request.invocation.agentId.trim(),
      callId: request.invocation.callId.trim(),
    );
    final existing = _semanticInvocations[key];
    if (existing != null) {
      return _SemanticReservation.rejected(
        existing.fingerprint == resolved.fingerprint
            ? 'invocation_replayed'
            : 'invocation_conflict',
      );
    }
    if (_semanticInvocations.length >= maximumInvocationRecords) {
      return const _SemanticReservation.rejected(
        'invocation_capacity_exhausted',
      );
    }
    final record = _SemanticInvocationRecord(
      key: key,
      fingerprint: resolved.fingerprint,
      state: _SemanticInvocationState.preparing,
      retainUntil: _monotonicNow() + _invocationRetention,
    );
    _semanticInvocations[key] = record;
    return _SemanticReservation.reserved(record);
  }

  void _pruneSemanticInvocations() {
    final now = _monotonicNow();
    _semanticInvocations.removeWhere((_, record) {
      if (record.state == _SemanticInvocationState.preparing ||
          record.state == _SemanticInvocationState.admitted ||
          record.state == _SemanticInvocationState.executing) {
        return false;
      }
      return now >= record.retainUntil;
    });
  }

  void _finishSemanticInvocation(
    _SemanticInvocationRecord record,
    _SemanticInvocationState state,
  ) {
    if (!identical(_semanticInvocations[record.key], record)) return;
    record.state = state;
    record.retainUntil = _monotonicNow() + _invocationRetention;
  }

  bool _enforcedPreparationIsCurrent({
    required ActionContractEnvelopeRequest request,
    required _AuthoritySnapshot authority,
    required _ResolvedEnvelope resolved,
    required _SemanticInvocationRecord semantic,
  }) {
    if (_sealed ||
        semantic.state != _SemanticInvocationState.preparing ||
        !identical(_semanticInvocations[semantic.key], semantic) ||
        !_requestScopeIsCurrent(request)) {
      return false;
    }
    final current = _readAuthority();
    if (current == null ||
        current.mode != FeatureRolloutMode.enforce ||
        current.mode != authority.mode ||
        current.generation != authority.generation) {
      return false;
    }
    final after = _resolve(request);
    if (after.diagnostics.isNotEmpty ||
        after.fingerprint != resolved.fingerprint ||
        after.actions.length != resolved.actions.length) {
      return false;
    }
    return _sameResolvedActions(resolved.actions, after.actions);
  }

  bool _compatibilityRecordIsCurrent(
    _AdmissionRecord record,
    ActionContractEnvelopeRequest request,
  ) {
    if (_sealed || !_sameInvocationIdentity(record, request)) return false;
    try {
      if (!_mountIsCurrent()) return false;
    } on Object {
      return false;
    }
    // Compatibility observations may cross off<->shadow revisions without
    // affecting raw behavior. Crossing into enforce always requires a new,
    // fingerprinted semantic admission.
    final authority = _readAuthority();
    return authority == null || authority.mode != FeatureRolloutMode.enforce;
  }

  bool _sameInvocationIdentity(
    _AdmissionRecord record,
    ActionContractEnvelopeRequest request,
  ) =>
      request.invocation.accountScope.trim() == record.accountScope &&
      request.invocation.accountGeneration == record.accountGeneration &&
      request.invocation.agentId.trim() == record.agentId &&
      request.invocation.callId.trim() == record.callId;

  bool _consumeEnforcedTicket(_AdmissionRecord record) {
    final nonce = record.nonce;
    if (nonce == null) return false;
    final slot = _pendingTickets.remove(nonce);
    return slot != null && identical(slot.record, record);
  }

  bool _semanticRecordIs(
    _AdmissionRecord record,
    _SemanticInvocationState expected,
  ) {
    final semantic = record.semanticInvocation;
    return semantic != null &&
        semantic.state == expected &&
        identical(_semanticInvocations[semantic.key], semantic) &&
        semantic.fingerprint == record.requestFingerprint;
  }

  bool _sameResolvedActions(
    List<_ResolvedAction> before,
    List<_ResolvedAction> after,
  ) {
    if (before.length != after.length) return false;
    for (var index = 0; index < before.length; index += 1) {
      final left = before[index];
      final right = after[index];
      if (!identical(left.productionDefinition, right.productionDefinition) ||
          left.definitionFingerprint != right.definitionFingerprint ||
          left.target != right.target ||
          left.channel != right.channel ||
          !identical(left.expectedDefinition, right.expectedDefinition)) {
        return false;
      }
    }
    return true;
  }

  bool _recordIsCurrent(
    _AdmissionRecord record,
    ActionContractEnvelopeRequest request, {
    _SemanticInvocationState semanticState = _SemanticInvocationState.executing,
  }) {
    final deadline = record.deadline;
    if (_sealed ||
        deadline == null ||
        _monotonicNow() >= deadline ||
        !_requestScopeIsCurrent(request) ||
        record.accountScope != _accountScope ||
        record.accountGeneration != _accountGeneration ||
        !_semanticRecordIs(record, semanticState)) {
      return false;
    }
    final authority = _readAuthority();
    if (authority == null ||
        authority.mode != record.mode ||
        authority.generation != record.authorityGeneration) {
      return false;
    }
    final resolved = _resolve(request);
    if (resolved.diagnostics.isNotEmpty ||
        resolved.fingerprint != record.requestFingerprint) {
      return false;
    }
    return _sameResolvedActions(record.resolvedActions, resolved.actions);
  }

  bool _allActionsReadOnly(_AdmissionRecord record) =>
      record.resolvedActions.every(
        (action) =>
            action.productionDefinition?.enforcementEligibility ==
            ActionEnforcementEligibility.readOnly,
      );

  Future<ActionContractExecutionResult> _finishWithoutExecution(
    _AdmissionRecord record, {
    required String code,
  }) async {
    final audited = await _recordLifecycleAudits(
      record,
      stage: ActionAuditStage.result,
      outcome: ActionAuditOutcome.unavailable,
      code: code,
      requireContinuity: true,
    );
    if (!audited) return _fixedRejection('audit_unavailable');
    return ActionContractExecutionResult.rejected(
      ToolOutcome.failure(
        status: ToolOutcomeStatus.unavailable,
        code: code,
        auditId: _firstAuditId(record),
      ),
    );
  }

  Future<ActionContractExecutionResult> _finishStaleExecution(
    _AdmissionRecord record,
    String code,
  ) async {
    final audited = await _recordLifecycleAudits(
      record,
      stage: ActionAuditStage.result,
      outcome: ActionAuditOutcome.unavailable,
      code: code,
      requireContinuity: true,
    );
    _finishSemanticInvocation(
      record.semanticInvocation!,
      _SemanticInvocationState.failed,
    );
    if (!audited) return _fixedRejection('audit_unavailable');
    return ActionContractExecutionResult.enforced(
      ToolOutcome.failure(
        status: ToolOutcomeStatus.unavailable,
        code: code,
        auditId: _firstAuditId(record),
      ),
    );
  }

  Future<ActionContractExecutionResult> _finishFailedExecution(
    _AdmissionRecord record, {
    required ToolOutcomeStatus status,
    required String code,
  }) async {
    final audited = await _recordLifecycleAudits(
      record,
      stage: ActionAuditStage.result,
      outcome: ActionAuditOutcome.failed,
      code: code,
      requireContinuity: true,
    );
    _finishSemanticInvocation(
      record.semanticInvocation!,
      _SemanticInvocationState.failed,
    );
    if (!audited) return _fixedRejection('audit_unavailable');
    return ActionContractExecutionResult.enforced(
      ToolOutcome.failure(
        status: status,
        code: code,
        auditId: _firstAuditId(record),
      ),
    );
  }

  List<ToolOutcome>? _validatedOutcomes(
    _AdmissionRecord record,
    List<Object?> outputs,
  ) {
    if (outputs.length != record.resolvedActions.length) return null;
    final outcomes = <ToolOutcome>[];
    for (var index = 0; index < outputs.length; index += 1) {
      final action = record.resolvedActions[index];
      final definition = action.productionDefinition?.definition;
      final outputSchema = definition?.outputSchema;
      if (outputSchema == null) return null;
      final outcome = _snapshotAdaptedOutcome(
        record.adapter.adaptOutput(outputs[index]),
        record.adapter,
      );
      if (outcome == null) return null;
      // Failure outcomes carry no legacy payload and are already a complete
      // typed result. The definition output schema describes successful data.
      if (outcome.isOk &&
          !_schemaValidator
              .validate(schema: outputSchema, value: outcome.data)
              .isValid) {
        return null;
      }
      outcomes.add(outcome);
    }
    return List<ToolOutcome>.unmodifiable(outcomes);
  }

  ToolOutcome? _snapshotAdaptedOutcome(
    ToolOutcome outcome,
    ActionContractLegacyAdapter adapter,
  ) {
    try {
      final snapshot = snapshotActionJson(
        outcome.toJson(),
        maxDepth: maximumEnvelopeDepth,
        maxNodes: maximumEnvelopeNodes,
        maxStringRunes: maximumStringRunes,
      );
      return snapshot is Map<String, Object?>
          ? adapter.adaptOutput(snapshot)
          : null;
    } on Object {
      return null;
    }
  }

  void _observeLegacyOutputs(_AdmissionRecord record, List<Object?> outputs) {
    try {
      if (_validatedOutcomes(record, outputs) != null) return;
    } on Object {
      // Shadow observation is compatibility-only and may never replace the
      // existing callback's output or exception.
    }
    _retainDiagnostics(const <ActionContractDiagnostic>[
      ActionContractDiagnostic(code: 'invalid_tool_outcome'),
    ]);
  }

  Future<List<String?>?> _recordDecisionAudits(
    ActionContractEnvelopeRequest request,
    _ResolvedEnvelope resolved,
  ) async {
    final auditIds = <String?>[];
    final invocation = ActionContractInvocationScope(
      accountScope: _accountScope,
      accountGeneration: _accountGeneration,
      agentId: request.invocation.agentId.trim(),
      callId: request.invocation.callId.trim(),
    );
    for (var index = 0; index < resolved.actions.length; index += 1) {
      final action = resolved.actions[index];
      final definition = action.productionDefinition?.definition;
      if (definition == null) return null;
      final auditId = await _recordAudit(
        ActionContractAuditRecord(
          stage: ActionAuditStage.decided,
          invocation: invocation,
          actionIndex: index,
          channel: action.channel,
          definition: definition,
          arguments: action.arguments,
          target: action.target,
          outcome: ActionAuditOutcome.allowed,
          code: 'v2.enforce_admitted',
          occurredAt: _safeUtcNow(),
        ),
      );
      if (!_validAuditId(auditId)) return null;
      auditIds.add(auditId);
    }
    return List<String?>.unmodifiable(auditIds);
  }

  Future<bool> _recordLifecycleAudits(
    _AdmissionRecord record, {
    required ActionAuditStage stage,
    required ActionAuditOutcome outcome,
    required String code,
    required bool requireContinuity,
  }) async {
    if (record.resolvedActions.isEmpty) return true;
    if (record.auditIds.length != record.resolvedActions.length) return false;
    for (var index = 0; index < record.resolvedActions.length; index += 1) {
      final action = record.resolvedActions[index];
      final definition = action.productionDefinition?.definition;
      if (definition == null) return false;
      final auditId = await _recordAudit(
        ActionContractAuditRecord(
          stage: stage,
          invocation: ActionContractInvocationScope(
            accountScope: record.accountScope,
            accountGeneration: record.accountGeneration,
            agentId: record.agentId,
            callId: record.callId,
          ),
          actionIndex: index,
          channel: action.channel,
          definition: definition,
          arguments: action.arguments,
          target: action.target,
          outcome: outcome,
          code: code,
          occurredAt: _safeUtcNow(),
        ),
      );
      if (!_validAuditId(auditId) ||
          (requireContinuity && auditId != record.auditIds[index])) {
        return false;
      }
    }
    return true;
  }

  Future<String?> _recordAudit(ActionContractAuditRecord record) async {
    try {
      return await Future<String?>.sync(
        () => _audit.record(record),
      ).timeout(_auditDeadline);
    } on Object {
      return null;
    }
  }

  DateTime _safeUtcNow() {
    try {
      return _clock().toUtc();
    } on Object {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
  }

  void _scheduleShadowAudit({
    required ActionContractInvocationScope invocation,
    required _ResolvedEnvelope resolved,
    required ActionAuditStage stage,
    required ActionAuditOutcome outcome,
    required String code,
  }) {
    unawaited(
      _trackAcquired(
        () => _observeShadowAudit(
          invocation: invocation,
          resolved: resolved,
          stage: stage,
          outcome: outcome,
          code: code,
        ),
        enforced: false,
      ),
    );
  }

  Future<void> _observeShadowAudit({
    required ActionContractInvocationScope invocation,
    required _ResolvedEnvelope resolved,
    required ActionAuditStage stage,
    required ActionAuditOutcome outcome,
    required String code,
  }) async {
    var available = true;
    for (var index = 0; index < resolved.actions.length; index += 1) {
      final action = resolved.actions[index];
      final definition = action.productionDefinition?.definition;
      if (definition == null) continue;
      final auditId = await _recordAudit(
        ActionContractAuditRecord(
          stage: stage,
          invocation: invocation,
          actionIndex: index,
          channel: action.channel,
          definition: definition,
          arguments: action.arguments,
          target: action.target,
          outcome: outcome,
          code: code,
          occurredAt: _safeUtcNow(),
        ),
      );
      if (!_validAuditId(auditId)) available = false;
    }
    if (!available) {
      _retainDiagnostics(const <ActionContractDiagnostic>[
        ActionContractDiagnostic(code: 'audit_unavailable'),
      ]);
    }
  }

  void _scheduleShadowRecordAudit({
    required _AdmissionRecord record,
    required ActionAuditStage stage,
    required ActionAuditOutcome outcome,
    required String code,
  }) {
    _scheduleShadowAudit(
      invocation: ActionContractInvocationScope(
        accountScope: record.accountScope,
        accountGeneration: record.accountGeneration,
        agentId: record.agentId,
        callId: record.callId,
      ),
      resolved: _ResolvedEnvelope(
        fingerprint: record.requestFingerprint,
        actions: record.resolvedActions,
        diagnostics: const <ActionContractDiagnostic>[],
      ),
      stage: stage,
      outcome: outcome,
      code: code,
    );
  }

  String? _firstAuditId(_AdmissionRecord record) {
    for (final auditId in record.auditIds) {
      if (auditId != null && auditId.isNotEmpty) return auditId;
    }
    return null;
  }

  _AuthoritySnapshot? _readAuthority() {
    try {
      return _AuthoritySnapshot(
        mode: _featureFlags.effectiveMode(MaasoFeatureFlag.actionContractV2),
        generation: _featureFlags.authorityGeneration(
          MaasoFeatureFlag.actionContractV2,
        ),
      );
    } on Object {
      return null;
    }
  }

  bool _requestScopeIsCurrent(ActionContractEnvelopeRequest request) {
    try {
      return request.invocation.accountScope.trim() == _accountScope &&
          request.invocation.accountGeneration == _accountGeneration &&
          _mountIsCurrent();
    } on Object {
      return false;
    }
  }

  bool _validInvocation(ActionContractInvocationScope invocation) =>
      _safeIdentifier(invocation.accountScope, 512) &&
      invocation.accountGeneration >= 0 &&
      _safeIdentifier(invocation.agentId, 256) &&
      _safeIdentifier(invocation.callId, 256);

  void _retainDiagnostics(Iterable<ActionContractDiagnostic> diagnostics) {
    for (final diagnostic in diagnostics) {
      if (_diagnostics.length == maximumDiagnostics) {
        _diagnostics.removeFirst();
      }
      _diagnostics.addLast(diagnostic);
    }
  }

  void _pruneExpiredTickets() {
    final now = _monotonicNow();
    _pendingTickets.removeWhere((_, slot) {
      if (now < slot.deadline) return false;
      _finishSemanticInvocation(
        slot.semanticInvocation,
        _SemanticInvocationState.expired,
      );
      return true;
    });
    _pruneSemanticInvocations();
  }

  String? _newNonce() {
    try {
      final random = Random.secure();
      for (var attempt = 0; attempt < 4; attempt += 1) {
        final nonce = List<int>.generate(
          24,
          (_) => random.nextInt(256),
          growable: false,
        ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        if (!_pendingTickets.containsKey(nonce)) return nonce;
      }
    } on Object {
      return null;
    }
    return null;
  }

  bool _acquireEnforcedOperation() {
    if (_activeEnforcedOperations >= maximumActiveEnforcedOperations) {
      return false;
    }
    _activeEnforcedOperations += 1;
    return true;
  }

  Future<T> _trackAcquired<T>(
    Future<T> Function() operation, {
    required bool enforced,
  }) {
    final completion = Completer<void>();
    _activeOperations.add(completion.future);
    final future = Future<T>.sync(operation);
    void cleanup() {
      if (enforced && _activeEnforcedOperations > 0) {
        _activeEnforcedOperations -= 1;
      }
      if (!completion.isCompleted) completion.complete();
      _activeOperations.remove(completion.future);
      if (_activeOperations.isEmpty) {
        final drain = _drainCompleter;
        if (drain != null && !drain.isCompleted) drain.complete();
      }
    }

    unawaited(
      future.then<void>(
        (_) => cleanup(),
        onError: (Object _, StackTrace stackTrace) => cleanup(),
      ),
    );
    return future;
  }

  /// Stops admission synchronously. Already-running operations remain tracked.
  void seal() {
    if (_sealed) return;
    _sealed = true;
    for (final slot in _pendingTickets.values) {
      _finishSemanticInvocation(
        slot.semanticInvocation,
        _SemanticInvocationState.rejected,
      );
    }
    _pendingTickets.clear();
  }

  Future<void> sealAndDrain() {
    seal();
    final existing = _drainFuture;
    if (existing != null) return existing;
    if (_activeOperations.isEmpty) {
      return _drainFuture = Future<void>.value();
    }
    final drain = Completer<void>();
    _drainCompleter = drain;
    return _drainFuture = drain.future;
  }

  Future<void> deactivateAndDrain() => sealAndDrain();

  @override
  void onClose() {
    seal();
    super.onClose();
  }

  ActionContractAdmission _rejected(
    FeatureRolloutMode mode,
    List<ActionContractDiagnostic> diagnostics,
  ) => ActionContractAdmission._(
    owner: this,
    mode: mode,
    admitted: false,
    diagnostics: diagnostics,
    record: null,
  );

  ActionContractExecutionResult _fixedRejection(String code) =>
      ActionContractExecutionResult.rejected(
        ToolOutcome.failure(status: ToolOutcomeStatus.unavailable, code: code),
      );

  String _definitionFingerprint(ProductionActionDefinition production) {
    final definition = production.definition;
    return _fingerprint(<String, Object?>{
      'id': definition.id,
      'input': snapshotActionJson(definition.inputSchema),
      'output': snapshotActionJson(definition.outputSchema),
      'scopes': definition.scopes.map((scope) => scope.name).toList()..sort(),
      'risk': definition.risk.name,
      'consequence': definition.consequencePolicy.name,
      'channels': production.channels.map((channel) => channel.name).toList()
        ..sort(),
      'eligibility': production.enforcementEligibility.name,
    });
  }
}

final class _AdmissionRecord {
  _AdmissionRecord({
    required this.mode,
    required this.authorityGeneration,
    required this.accountScope,
    required this.accountGeneration,
    required this.agentId,
    required this.callId,
    required this.requestFingerprint,
    required this.resolvedActions,
    required this.auditIds,
    required this.deadline,
    required this.nonce,
    required this.adapter,
    required this.semanticInvocation,
  });

  final FeatureRolloutMode mode;
  final int authorityGeneration;
  final String accountScope;
  final int accountGeneration;
  final String requestFingerprint;
  final List<_ResolvedAction> resolvedActions;
  final List<String?> auditIds;
  final Duration? deadline;
  final String? nonce;
  final ActionContractLegacyAdapter adapter;
  final _SemanticInvocationRecord? semanticInvocation;
  final String agentId;
  final String callId;
}

final class _ResolvedAction {
  const _ResolvedAction({
    required this.actionId,
    required this.arguments,
    required this.target,
    required this.channel,
    required this.expectedDefinition,
    required this.productionDefinition,
    required this.definitionFingerprint,
  });

  final String actionId;
  final Object? arguments;
  final String target;
  final ActionContractChannel channel;
  final ProductionActionDefinition? expectedDefinition;
  final ProductionActionDefinition? productionDefinition;
  final String definitionFingerprint;
}

final class _ResolvedEnvelope {
  const _ResolvedEnvelope({
    required this.fingerprint,
    required this.actions,
    required this.diagnostics,
  });

  const _ResolvedEnvelope.empty()
    : fingerprint = '',
      actions = const <_ResolvedAction>[],
      diagnostics = const <ActionContractDiagnostic>[];

  final String fingerprint;
  final List<_ResolvedAction> actions;
  final List<ActionContractDiagnostic> diagnostics;
}

final class _TicketSlot {
  _TicketSlot({required this.deadline, required this.semanticInvocation});

  final Duration deadline;
  final _SemanticInvocationRecord semanticInvocation;
  _AdmissionRecord? record;
}

enum _SemanticInvocationState {
  preparing,
  admitted,
  executing,
  succeeded,
  failed,
  rejected,
  abandoned,
  expired,
}

final class _SemanticInvocationKey {
  const _SemanticInvocationKey({
    required this.accountScope,
    required this.accountGeneration,
    required this.agentId,
    required this.callId,
  });

  final String accountScope;
  final int accountGeneration;
  final String agentId;
  final String callId;

  @override
  bool operator ==(Object other) =>
      other is _SemanticInvocationKey &&
      other.accountScope == accountScope &&
      other.accountGeneration == accountGeneration &&
      other.agentId == agentId &&
      other.callId == callId;

  @override
  int get hashCode =>
      Object.hash(accountScope, accountGeneration, agentId, callId);
}

final class _SemanticInvocationRecord {
  _SemanticInvocationRecord({
    required this.key,
    required this.fingerprint,
    required this.state,
    required this.retainUntil,
  });

  final _SemanticInvocationKey key;
  final String fingerprint;
  _SemanticInvocationState state;
  Duration retainUntil;
}

final class _SemanticReservation {
  const _SemanticReservation.reserved(this.record)
    : isReserved = true,
      code = '';

  const _SemanticReservation.rejected(this.code)
    : isReserved = false,
      record = null;

  final bool isReserved;
  final String code;
  final _SemanticInvocationRecord? record;
}

final class _AuthoritySnapshot {
  const _AuthoritySnapshot({required this.mode, required this.generation});

  final FeatureRolloutMode mode;
  final int generation;
}

bool _safeIdentifier(String raw, int maximumRunes) {
  final value = raw.trim();
  return value.isNotEmpty &&
      value.runes.length <= maximumRunes &&
      !RegExp('[\\u0000-\\u001f\\u007f-\\u009f]').hasMatch(value);
}

bool _validAuditId(String? raw) =>
    raw != null &&
    raw.isNotEmpty &&
    raw.length <= 128 &&
    RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(raw);

bool _validActionId(String raw) =>
    raw.isNotEmpty &&
    raw.length <= 128 &&
    RegExp(r'^[a-zA-Z0-9._:-]+$').hasMatch(raw);

bool _validTarget(String raw) =>
    raw.isNotEmpty &&
    raw.runes.length <= 1024 &&
    !RegExp('[\\u0000-\\u001f\\u007f-\\u009f]').hasMatch(raw);

List<ActionContractCall> _boundedActionCalls(List<ActionContractCall> actions) {
  if (actions.length > 1024) {
    throw ArgumentError.value(
      actions.length,
      'actions.length',
      'must not exceed 1024',
    );
  }
  return List<ActionContractCall>.unmodifiable(actions);
}

String _safeOutcomeCode(String raw, {required String fallback}) {
  final code = raw.trim().toLowerCase();
  return code.isNotEmpty &&
          code.length <= 64 &&
          RegExp(r'^[a-z0-9._-]+$').hasMatch(code)
      ? code
      : fallback;
}

String _fingerprint(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonicalJson(value)))).toString();

Object? _canonicalJson(Object? value) {
  if (value == null || value is bool || value is num || value is String) {
    return value;
  }
  if (value is List) {
    return <Object?>[for (final item in value) _canonicalJson(item)];
  }
  if (value is Map) {
    final keys = value.keys.cast<String>().toList(growable: false)..sort();
    return <String, Object?>{
      for (final key in keys) key: _canonicalJson(value[key]),
    };
  }
  throw const FormatException('action_contract_non_json');
}

final Stopwatch _actionContractMonotonicClock = Stopwatch()..start();

Duration _defaultMonotonicNow() => _actionContractMonotonicClock.elapsed;
