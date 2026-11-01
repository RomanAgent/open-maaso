import 'dart:async';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/security/action_schema_validator.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

import 'app_invocation_catalog.dart';
import 'app_invocation_compatibility.dart';
import 'app_invocation_descriptor.dart';
import 'app_invocation_draft_snapshot.dart';
import 'app_invocation_execution_contract.dart';
import 'app_invocation_runtime_registry.dart';
import 'app_invocation_store.dart';

/// The native adapter factory is injected by the account owner. No model name,
/// source document or serialized ID can instantiate one of these hosts.
typedef AppInvocationHostFactory =
    Future<AppInvocationBackend> Function(AppInvocationHostRequest request);

final class AppInvocationHostRequest {
  const AppInvocationHostRequest({
    required this.run,
    required this.descriptor,
    required this.pinnedSource,
    required this.inputImages,
    required this.isCurrent,
    required this.isOwnerCurrent,
  });
  final AppInvocationRunRecord run;
  final AppInvocationDescriptor descriptor;
  final AppInvocationPinnedSource pinnedSource;
  final List<AppInvocationInputImage> inputImages;
  final bool Function() isCurrent;

  /// Account/source ownership survives the completed turn, but grants do not.
  /// A retained result view may use this only to decide when to dispose itself.
  final bool Function() isOwnerCurrent;
}

final class AppInvocationBackendResult {
  const AppInvocationBackendResult({
    required this.status,
    required this.stateVersion,
    this.result,
    this.outputs = const [],
    this.errorCode,
  });
  final AppInvocationActionStatus status;
  final int stateVersion;
  final Object? result;
  final List<AppInvocationProducedImage> outputs;
  final String? errorCode;
}

abstract interface class AppInvocationBackend {
  bool get isCurrent;
  bool get isVisible;
  bool get requiresVisibleHost;
  bool get supportsGameAuthority;
  AppInvocationRuntimeProtocol get protocol;
  Set<AppInvocationIsolationBoundary> get verifiedBoundaries;
  Future<Map<String, Object?>> describe();
  Future<AppInvocationBackendResult> invoke(
    String actionId,
    Map<String, Object?> arguments, {
    required String requestId,
    required String observationId,
    required int expectedStateVersion,
    required List<AppInvocationInputImage> inputImages,
  });
  Future<AppInvocationBackendResult?> receipt(String requestId);

  /// Synchronous revocation precedes asynchronous platform disposal.
  void fence();
  Future<void> close();
}

/// An optional visible result can outlive a completed invocation. The session
/// revokes its grant and fences native commands before asking for this handoff.
/// The backend must keep only user interaction alive; [AppInvocationBackend.close]
/// must still destroy the view on owner retirement or the next invocation.
abstract interface class AppInvocationUserVisibleResultBackend {
  Future<void> releaseCompletedViewToUser();
}

/// A native host records explicit network/effect consent separately from
/// isolation evidence. Author code and source metadata cannot set this value.
abstract interface class AppInvocationExternalEffectsConsentBackend {
  bool get externalEffectsAllowedByUser;
}

/// Native-only authorization must be checked again after a human confirmation
/// wait. Hosts must not call this from their own [AppInvocationBackend.isCurrent]
/// getter, since grant validity itself includes that host lifecycle check.
abstract interface class AppInvocationActionAuthorizationBackend {
  void bindInvocationAuthorization(bool Function() isAuthorized);
}

/// Non-serializable native authority bound to one prepared source and turn.
final class AppInvocationGrant {
  AppInvocationGrant._(this.authority, this.isValid, Iterable<String> actions)
    : allowedActions = Set.unmodifiable(actions);
  final Object authority;
  final bool Function() isValid;
  final Set<String> allowedActions;
  final Stopwatch _elapsed = Stopwatch()..start();
  bool _live = true;
  bool get isCurrent =>
      _live && _elapsed.elapsed < const Duration(minutes: 3) && isValid();
}

final class AppInvocationExecutionService extends AppService {
  AppInvocationExecutionService({
    required this.store,
    required bool Function() isCurrent,
    AppInvocationHostFactory? openHost,
  }) : _isCurrent = isCurrent,
       _openHost = openHost;
  final AppInvocationStore store;
  final bool Function() _isCurrent;
  final AppInvocationHostFactory? _openHost;
  final Object _authority = Object();
  final Set<AppInvocationSession> _sessions = {};
  final Set<Future<void>> _closing = {};
  bool _retired = false;
  bool _preparing = false;
  Future<void>? _preparationTail;
  Future<void>? _draining;
  bool get isCurrent => !_retired && store.isCurrent && _isCurrent();

  Future<AppInvocationSession> prepare({
    required AppInvocationPinnedSource pinnedSource,
    required String turnId,
    required String sessionId,
    required String submissionToken,
    required String userText,
    required List<AppInvocationInputImage> inputImages,
    required bool Function() isCurrent,
    String agentId = 'self',
    void Function(AppInvocationRunRecord)? onAdmitted,
  }) async {
    final open = _openHost;
    if (!this.isCurrent ||
        !isCurrent() ||
        !pinnedSource.isCurrent ||
        pinnedSource.identity.scopeKey != store.scopeKey ||
        agentId.trim().isEmpty ||
        inputImages.length > appInvocationMaximumImages ||
        inputImages.map((image) => image.id).toSet().length !=
            inputImages.length) {
      throw StateError('invocation_prepare_unavailable');
    }
    // No fallback host: browser/profile/network isolation must be configured.
    if (open == null) throw StateError('invocation_host_unavailable');
    if (_preparing || _sessions.any((session) => session.isCurrent)) {
      throw StateError('invocation_lane_busy');
    }
    _preparing = true;
    final preparation = Completer<void>();
    _preparationTail = preparation.future;
    AppInvocationBackend? backend;
    bool current() => this.isCurrent && isCurrent() && pinnedSource.isCurrent;
    try {
      for (final previous in _sessions.toList()) {
        await previous.close();
      }
      if (!current()) throw StateError('invocation_prepare_retired');
      final surface = pinnedSource.surface;
      final bundle = pinnedSource.installedBundle;
      final descriptor = surface != null
          ? AppInvocationDescriptor.fromSurface(
              project: surface,
              identity: pinnedSource.identity,
            )
          : AppInvocationDescriptor.fromValidatedBundle(
              bundle: bundle!.bundle,
              scopeKey: store.scopeKey,
            );
      if (descriptor.contractDigest != pinnedSource.contractDigest ||
          descriptor.contractIssues.isNotEmpty ||
          descriptor.actions.isEmpty) {
        throw StateError('invocation_source_contract_unavailable');
      }
      final adapter = AppInvocationRuntimeRegistry.identityFor(
        descriptor.runtimeKind,
      );
      final inputs = List<AppInvocationInputImage>.unmodifiable(inputImages);
      final draftSnapshot = AppInvocationDraftSnapshot(
        scopeKey: store.scopeKey,
        text: userText,
        imageHandles: inputs.map((image) => image.toHandleJson()).toList(),
        sourceOrigin: pinnedSource.locator.origin.name,
        sourceId: pinnedSource.identity.sourceId,
        localWidgetId: pinnedSource.locator.localWidgetId,
        clientSurfaceId: pinnedSource.locator.clientSurfaceId,
        sourceType: pinnedSource.type.name,
        sourceTitle: pinnedSource.title,
        revisionId: pinnedSource.identity.revisionId,
        sourceDigest: pinnedSource.identity.sourceDigest,
        contractDigest: pinnedSource.contractDigest,
        adapterId: adapter.id,
        adapterVersion: adapter.version,
      );
      final run = await store.admit(
        submissionToken: submissionToken,
        turnId: turnId,
        sessionId: sessionId,
        descriptor: descriptor,
        adapterId: adapter.id,
        adapterVersion: adapter.version,
        inputDigest: draftSnapshot.inputDigest,
        draftSnapshot: draftSnapshot,
        canContinue: current,
      );
      if (!current()) throw StateError('invocation_prepare_retired');
      onAdmitted?.call(run);
      if (!current()) throw StateError('invocation_prepare_retired');
      if (run.value['processId'] != store.processId ||
          run.status != 'admitted') {
        throw StateError('invocation_requires_receipt_recovery');
      }
      backend = await open(
        AppInvocationHostRequest(
          run: run,
          descriptor: descriptor,
          pinnedSource: pinnedSource,
          inputImages: inputs,
          isCurrent: current,
          isOwnerCurrent: () => this.isCurrent && pinnedSource.isCurrent,
        ),
      );
      if (!current() || !backend.isCurrent) {
        throw StateError('invocation_host_retired');
      }
      final observed = await backend.describe();
      if (!current() || !backend.isCurrent) {
        throw StateError('invocation_host_retired');
      }
      final names = observed['actions'];
      if (names is! List || names.any((name) => name is! String)) {
        throw StateError('invocation_handshake_invalid');
      }
      final now = DateTime.now().toUtc();
      final compatibility = assessAppInvocationCompatibility(
        descriptor: descriptor,
        expectedAdapterId: adapter.id,
        expectedAdapterVersion: adapter.version,
        expectedSessionId: run.invocationId,
        now: now,
        runtimeEvidence: AppInvocationRuntimeEvidence(
          identity: descriptor.identity,
          contractDigest: descriptor.contractDigest,
          runtimeKind: descriptor.runtimeKind,
          protocol: backend.protocol,
          adapterId: adapter.id,
          adapterVersion: adapter.version,
          sessionId: run.invocationId,
          observedAt: now,
          expiresAt: now.add(const Duration(minutes: 3)),
          ready: observed['ready'] == true,
          implementedActionNames: names.cast<String>().toSet(),
          resultChannel: AppInvocationResultChannel.correlatedOutputs,
          requiresVisibleHost: backend.requiresVisibleHost,
          isVisible: backend.isVisible,
          supportsGameAuthority: backend.supportsGameAuthority,
          externalEffectsAllowedByUser:
              backend is AppInvocationExternalEffectsConsentBackend &&
              (backend as AppInvocationExternalEffectsConsentBackend)
                  .externalEffectsAllowedByUser,
        ),
        isolationEvidence: AppInvocationIsolationEvidence(
          identity: descriptor.identity,
          contractDigest: descriptor.contractDigest,
          adapterId: adapter.id,
          adapterVersion: adapter.version,
          sessionId: run.invocationId,
          observedAt: now,
          expiresAt: now.add(const Duration(minutes: 3)),
          verifiedBoundaries: backend.verifiedBoundaries,
        ),
      );
      if (compatibility.status != AppInvocationCompatibilityStatus.compatible) {
        throw StateError(
          'invocation_unverified:${compatibility.reasons.join(',')}',
        );
      }
      final ownedBackend = backend;
      final grant = AppInvocationGrant._(
        _authority,
        () =>
            current() &&
            ownedBackend.isCurrent &&
            (!ownedBackend.requiresVisibleHost || ownedBackend.isVisible),
        compatibility.actions.map((action) => action.name),
      );
      if (ownedBackend is AppInvocationActionAuthorizationBackend) {
        (ownedBackend as AppInvocationActionAuthorizationBackend)
            .bindInvocationAuthorization(() => grant.isCurrent);
      }
      final session = AppInvocationSession._(
        this,
        run,
        descriptor,
        inputs,
        ownedBackend,
        grant,
      );
      _sessions.add(session);
      backend = null; // The session now owns its platform resources.
      return session;
    } finally {
      _preparing = false;
      try {
        if (backend != null) {
          backend.fence();
          await backend.close();
        }
      } finally {
        preparation.complete();
        if (identical(_preparationTail, preparation.future)) {
          _preparationTail = null;
        }
      }
    }
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    for (final session in _sessions.toList()) {
      session._fence();
      final closing = session.close();
      _closing.add(closing);
      // Keep the original future for drain, including a platform close failure.
      unawaited(
        closing.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  }

  Future<void> deactivateAndDrain() {
    retire();
    return _draining ??= () async {
      await _preparationTail;
      await Future.wait(_closing.toList());
    }();
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}

final class AppInvocationSession {
  AppInvocationSession._(
    this._owner,
    this.run,
    this._descriptor,
    this._inputs,
    this._backend,
    this._grant,
  );
  final AppInvocationExecutionService _owner;
  final AppInvocationRunRecord run;
  final AppInvocationDescriptor _descriptor;
  final List<AppInvocationInputImage> _inputs;
  final AppInvocationBackend _backend;
  final AppInvocationGrant _grant;
  final Map<String, Future<AppInvocationActionReceipt>> _inFlight = {};
  final Map<String, String> _inFlightIdentities = {};
  final Set<Future<void>> _pendingState = {};
  Future<void>? _closing;
  bool _releasedToUser = false;
  String get invocationId => run.invocationId;
  bool get isCurrent =>
      _owner.isCurrent &&
      identical(_grant.authority, _owner._authority) &&
      _grant.isCurrent;
  void _guard() {
    if (!isCurrent) throw StateError('invocation_grant_revoked');
  }

  void _fence() {
    _grant._live = false;
    _backend.fence();
  }

  Future<Map<String, Object?>> describe() async {
    _guard();
    final snapshot = await _backend.describe();
    _guard();
    return {
      'invocationId': invocationId,
      'source': _descriptor.identity.toJson(),
      'contractDigest': _descriptor.contractDigest,
      'observationId': snapshot['observationId'],
      'stateVersion': snapshot['stateVersion'],
      'state': snapshot['state'],
      'actions': [
        for (final action in _descriptor.actions)
          if (_grant.allowedActions.contains(action.name))
            {'id': action.name, 'argumentsSchema': action.argumentsSchema},
      ],
      'inputImages': _inputs.map((image) => image.toHandleJson()).toList(),
      'imageHandleAnnotation': appInvocationImageHandleAnnotation,
      'sourceDocuments': {
        'untrusted': true,
        'documents': _descriptor.documents,
      },
    };
  }

  Future<AppInvocationActionReceipt> invoke(
    String actionId,
    Map<String, Object?> arguments, {
    required String requestId,
    required String observationId,
    required int expectedStateVersion,
  }) {
    _guard();
    final identity = const ProjectJsonCanonicalizer().canonicalize([
      actionId,
      arguments,
      observationId,
      expectedStateVersion,
    ]);
    final existing = _inFlight[requestId];
    if (existing != null) {
      if (_inFlightIdentities[requestId] != identity) {
        throw StateError('invocation_request_conflict');
      }
      return existing;
    }
    if (_inFlight.isNotEmpty) throw StateError('invocation_action_in_flight');
    final operation = _invoke(
      actionId,
      arguments,
      requestId,
      observationId,
      expectedStateVersion,
    );
    _inFlight[requestId] = operation;
    _inFlightIdentities[requestId] = identity;
    unawaited(
      operation
          .then<void>((_) {}, onError: (Object _, StackTrace _) {})
          .whenComplete(() {
            _inFlight.remove(requestId);
            _inFlightIdentities.remove(requestId);
          }),
    );
    return operation;
  }

  Future<AppInvocationActionReceipt> _invoke(
    String actionId,
    Map<String, Object?> args,
    String requestId,
    String observationId,
    int version,
  ) async {
    _guard();
    final actions = _descriptor.actions.where(
      (action) => action.name == actionId,
    );
    if (!_grant.allowedActions.contains(actionId) ||
        actions.length != 1 ||
        !const ActionSchemaValidator()
            .validate(schema: actions.single.argumentsSchema, value: args)
            .isValid) {
      throw StateError('invocation_action_not_declared');
    }
    final frozen =
        appInvocationResultJson.parse(
              appInvocationResultJson.canonicalize(args),
            )!
            as Map<String, Object?>;
    final boundInputs = _resolveInputs(actions.single.argumentsSchema, frozen);
    final first = await _owner.store.reserveAction(
      invocationId: invocationId,
      requestId: requestId,
      actionId: actionId,
      arguments: frozen,
      observationId: observationId,
      expectedStateVersion: version,
      canContinue: () => isCurrent,
    );
    _guard();
    if (!first) {
      final known = await receipt(requestId);
      if (known != null) return known;
      throw StateError('invocation_outcome_unknown');
    }
    AppInvocationBackendResult outcome;
    try {
      outcome = await _backend.invoke(
        actionId,
        frozen,
        requestId: requestId,
        observationId: observationId,
        expectedStateVersion: version,
        inputImages: boundInputs,
      );
    } on TimeoutException {
      outcome = AppInvocationBackendResult(
        status: AppInvocationActionStatus.outcomeUnknown,
        stateVersion: version,
        errorCode: 'runtime_timeout',
      );
    } catch (_) {
      outcome = AppInvocationBackendResult(
        status: AppInvocationActionStatus.outcomeUnknown,
        stateVersion: version,
        errorCode: 'runtime_transport_failed',
      );
    }
    _guard();
    final value = _receipt(actionId, requestId, outcome);
    await _owner.store.settle(value, canContinue: () => isCurrent);
    _guard();
    return value;
  }

  List<AppInvocationInputImage> _resolveInputs(
    Map<String, Object?> schema,
    Object? value,
  ) {
    final selected = <String>{};
    void visit(Map rule, Object? item) {
      if (rule[r'$comment'] == appInvocationImageHandleAnnotation) {
        if (rule['type'] != 'string' ||
            item is! String ||
            !_inputs.any((image) => image.id == item)) {
          throw StateError('invocation_input_handle_invalid');
        }
        selected.add(item);
      }
      if (rule['properties'] is Map && item is Map) {
        for (final entry in (rule['properties']! as Map).entries) {
          if (entry.value is Map && item.containsKey(entry.key)) {
            visit(entry.value as Map, item[entry.key]);
          }
        }
      }
      if (rule['items'] is Map && item is List) {
        for (final entry in item) {
          visit(rule['items']! as Map, entry);
        }
      }
    }

    visit(schema, value);
    return List.unmodifiable(
      _inputs.where((image) => selected.contains(image.id)),
    );
  }

  AppInvocationActionReceipt _receipt(
    String actionId,
    String requestId,
    AppInvocationBackendResult value,
  ) => AppInvocationActionReceipt(
    invocationId: invocationId,
    requestId: requestId,
    actionId: actionId,
    identity: _descriptor.identity,
    contractDigest: _descriptor.contractDigest,
    status: value.status,
    stateVersion: value.stateVersion,
    result: value.result,
    outputs: value.outputs,
    errorCode: value.errorCode,
  );

  Future<T> _trackState<T>(Future<T> work) {
    final settled = work.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pendingState.add(settled);
    unawaited(settled.whenComplete(() => _pendingState.remove(settled)));
    return work;
  }

  Future<AppInvocationActionReceipt?> receipt(String requestId) =>
      _trackState(_readReceipt(requestId));

  Future<AppInvocationActionReceipt?> _readReceipt(String requestId) async {
    _guard();
    final known = await _owner.store.readReceipt(
      invocationId,
      requestId: requestId,
    );
    _guard();
    if (known != null &&
        known.status != AppInvocationActionStatus.outcomeUnknown) {
      return known;
    }
    final action = await _owner.store.readAction(
      invocationId,
      requestId: requestId,
    );
    _guard();
    if (action == null) return null;
    final observed = await _backend.receipt(requestId);
    _guard();
    if (observed == null) return known;
    final value = _receipt(action['actionId']! as String, requestId, observed);
    await _owner.store.settle(value, canContinue: () => isCurrent);
    _guard();
    return value;
  }

  /// Called only after publishing a completed receipt. Keeps the configured
  /// browser visible without retaining any agent authority or occupying the
  /// invocation lane. The owner still tracks this session for full disposal.
  Future<bool> releaseCompletedViewToUser(
    AppInvocationActionReceipt receipt,
  ) async {
    _guard();
    final backend = _backend;
    if (backend is! AppInvocationUserVisibleResultBackend) return false;
    if (receipt.status != AppInvocationActionStatus.completed ||
        receipt.invocationId != invocationId ||
        !receipt.identity.matches(_descriptor.identity) ||
        receipt.contractDigest != _descriptor.contractDigest) {
      throw StateError('invocation_visible_result_unavailable');
    }
    final stored = await _owner.store.readReceipt(
      invocationId,
      requestId: receipt.requestId,
    );
    _guard();
    if (stored == null || stored.digest != receipt.digest) {
      throw StateError('invocation_visible_result_unavailable');
    }
    _fence();
    await (backend as AppInvocationUserVisibleResultBackend)
        .releaseCompletedViewToUser()
        .timeout(const Duration(seconds: 3));
    if (!_owner.isCurrent || _closing != null) {
      throw StateError('invocation_visible_result_retired');
    }
    _releasedToUser = true;
    return true;
  }

  bool get releasedToUser => _releasedToUser;

  /// Resource retirement does not rewrite a completed/unknown action outcome.
  Future<void> close() {
    _fence();
    return _closing ??= () async {
      try {
        await _backend.close();
      } finally {
        await Future.wait([
          ..._pendingState,
          ..._inFlight.values.toList().map(
            (operation) => operation.then<void>(
              (_) {},
              onError: (Object _, StackTrace _) {},
            ),
          ),
        ]);
        _owner._sessions.remove(this);
      }
    }();
  }

  Future<void> cancel() {
    _fence();
    final cancellation = _owner.store.isCurrent
        ? _trackState(_owner.store.cancel(invocationId))
        : Future<void>.value();
    return Future.wait<void>([close(), cancellation]).then((_) {});
  }
}
