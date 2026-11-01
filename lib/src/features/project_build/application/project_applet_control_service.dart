import 'dart:async';
import 'dart:math';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';

import '../data/project_applet_action_journal.dart';
import '../data/project_build_v2_repository.dart';
import '../domain/project_bundle_v2.dart';
import '../domain/project_json_canonicalizer.dart';

/// Implemented only by the native visible bundle host, never by page JSON.
abstract interface class ProjectAppletControlHost {
  String get controlScopeKey;
  String get controlAgentId;
  String get controlProjectId;
  String get controlRevisionId;
  String get controlCandidateDigest;
  String get controlSessionId;
  String get controlTitle;
  String get controlAgentDocument;
  SurfacePlayProtocol get controlProtocol;
  bool get controlIsCurrent;
  bool get controlIsVisible;
  bool get controlIsReady;
  bool get canRetainControlReceipts;
  Future<Map<String, Object?>> controlInfo();
  Future<Map<String, Object?>> inspectApplet();
  Future<void> dispatchApplet(
    Map<String, Object?> command,
    String callbackToken,
  );
  Future<Map<String, Object?>?> lookupAppletReceipt(String requestId);
  void fenceAppletDocument();
  Future<void> restoreAppletDocument();
}

/// Non-serializable capability created solely by the native user-control UI.
/// A matching collection of strings is not a grant.
final class ProjectAppletGrant {
  ProjectAppletGrant._(
    this._authority,
    this._host,
    this.agentId,
    this.sessionId,
    this.controlEpoch,
    this.purpose,
    this.expiresAt,
    this._isValid,
    this._lifetime,
    this._maximumActions,
    this._maximumObservations,
  );
  final Object _authority;
  final ProjectAppletControlHost _host;
  final String agentId, sessionId, purpose;
  final int controlEpoch;
  final DateTime expiresAt;
  final bool Function() _isValid;
  final Duration _lifetime;
  final int _maximumActions, _maximumObservations;
  final _elapsed = Stopwatch()..start();
  final _revoked = Completer<String>();
  int _actions = 0, _observations = 0, _receiptQueries = 0;
  bool _live = true;
  String get projectId => _host.controlProjectId;
  String get revisionId => _host.controlRevisionId;
  String get candidateDigest => _host.controlCandidateDigest;
  bool get isCurrent => _live && _elapsed.elapsed < _lifetime && _isValid();
  int get remainingActions => max(0, _maximumActions - _actions);
  Future<String> get onRevoked => _revoked.future;
}

final class _AppletCall {
  _AppletCall(
    this.grant,
    this.requestId,
    this.actionId,
    this.identity,
    this.callbackToken,
    this.expectedVersion,
  );
  final ProjectAppletGrant grant;
  final String requestId, actionId, identity, callbackToken;
  final int expectedVersion;
  final result = Completer<Map<String, Object?>>();
}

final class _AppletAdmission {
  _AppletAdmission(this.requestId, this.identity, this.future);
  final String requestId, identity;
  final Future<Map<String, Object?>> future;
}

/// This service has no model or network client. The existing single-turn lane
/// consumes its capabilities; declaring a skill never grants page access.
final class ProjectAppletControlService extends AppService {
  ProjectAppletControlService({
    required this.scopeKey,
    required this.appletScopeKey,
    required this.journal,
    required bool Function() isCurrent,
    required bool Function() isForeground,
    this.grantLifetime = const Duration(minutes: 3),
    this.maximumActions = 16,
    this.maximumObservations = 64,
    this.commandTimeout = const Duration(seconds: 8),
  }) : _isCurrent = isCurrent,
       _isForeground = isForeground {
    if (scopeKey.isEmpty ||
        appletScopeKey.isEmpty ||
        maximumActions < 1 ||
        maximumActions > 32 ||
        maximumObservations < 1 ||
        maximumObservations > 128 ||
        commandTimeout <= Duration.zero ||
        commandTimeout > const Duration(seconds: 30) ||
        grantLifetime <= Duration.zero ||
        grantLifetime > const Duration(minutes: 5)) {
      throw ArgumentError('applet_control_configuration');
    }
  }
  final String scopeKey, appletScopeKey;
  final ProjectAppletActionJournal journal;
  final bool Function() _isCurrent, _isForeground;
  final Duration grantLifetime, commandTimeout;
  final int maximumActions, maximumObservations;
  final _hosts = <ProjectAppletControlHost>{};
  final Object _authority = Object();
  final _observations = <String, Map<String, Object?>>{};
  final _calls = <String, _AppletCall>{};
  final _pending = <Future<void>>{};
  final _retired = Completer<void>();
  final _changes = StreamController<void>.broadcast(sync: true);
  final _grants = StreamController<ProjectAppletGrant>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  Stream<ProjectAppletGrant> get onGranted => _grants.stream;
  ProjectAppletGrant? _active;
  Timer? _expiry;
  bool _sealed = false, _grantBusy = false, _changeScheduled = false;
  _AppletAdmission? _admission;
  int _epoch = 0;
  static const _json = ProjectJsonCanonicalizer(
    maxBytes: 64 * 1024,
    maxDepth: 16,
    maxNodes: 4096,
  );
  static const _receiptJson = ProjectJsonCanonicalizer(
    maxBytes: 96 * 1024,
    maxDepth: 20,
    maxNodes: 8192,
  );
  bool get _current => !_sealed && _isCurrent();
  Future<T> _operation<T>(Future<T> Function() run) {
    final work = Future<T>.sync(run);
    _track(work.then<void>((_) {}));
    return work;
  }

  Future<T> _hostResult<T>(Future<T> work, [ProjectAppletGrant? grant]) =>
      Future.any<T>([
        work.timeout(commandTimeout),
        _retired.future.then<T>(
          (_) => throw StateError('applet_control_revoked'),
        ),
        if (grant != null)
          grant.onRevoked.then<T>(
            (_) => throw StateError('applet_control_revoked'),
          ),
      ]);
  String _random() => List.generate(
    24,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Map<String, Object?> _freeze(Map<String, Object?> value) =>
      _json.parse(_json.canonicalize(value))! as Map<String, Object?>;
  void _changed() {
    if (_sealed || _changeScheduled) return;
    _changeScheduled = true;
    scheduleMicrotask(() {
      _changeScheduled = false;
      if (!_sealed) _changes.add(null);
    });
  }

  void registerHost(ProjectAppletControlHost host) {
    if (!_current || host.controlScopeKey != scopeKey) {
      throw StateError('applet_control_scope');
    }
    _hosts.add(host);
    _changed();
  }

  void unregisterHost(ProjectAppletControlHost host) {
    _hosts.remove(host);
    if (identical(_active?._host, host)) {
      _revoke(_active!, 'closed', restore: false);
    }
    _changed();
  }

  void contextChanged() {
    final grant = _active;
    if (grant != null && !grant.isCurrent) {
      _revoke(
        grant,
        !_current
            ? 'scope_changed'
            : !_isForeground()
            ? 'background'
            : 'view_hidden',
      );
    }
    _changed();
  }

  bool _eligible(ProjectAppletControlHost host) =>
      _current &&
      _isForeground() &&
      _hosts.contains(host) &&
      host.controlScopeKey == scopeKey &&
      host.controlProtocol.projectKind == 'applet' &&
      !host.controlProtocol.isTrustedGame &&
      host.controlIsCurrent &&
      host.controlIsVisible &&
      host.controlIsReady;

  ProjectAppletGrant? currentGrant(String agentId) {
    final grant = _active;
    if (grant != null && !grant.isCurrent) {
      _revoke(grant, 'expired_or_revoked');
      return null;
    }
    return grant != null && grant.agentId == agentId && grant.isCurrent
        ? grant
        : null;
  }

  Map<String, Object?> statusForAgent(String agentId) {
    final grant = currentGrant(agentId);
    final candidates = _hosts.where(
      (host) => host.controlAgentId == agentId && _eligible(host),
    );
    return {
      'status': grant == null ? 'native_grant_required' : 'granted',
      'available': candidates.isNotEmpty,
      'remainingActions': grant?.remainingActions ?? 0,
      if (grant != null) 'projectId': grant.projectId,
    };
  }

  /// Native UI only. ProjectControl's model-facing schema must not expose it.
  Future<ProjectAppletGrant> grantFromNative(
    ProjectAppletControlHost host, {
    String purpose = '',
  }) => _operation(() => _grantFromNative(host, purpose));

  Future<ProjectAppletGrant> _grantFromNative(
    ProjectAppletControlHost host,
    String purpose,
  ) async {
    if (_grantBusy || !_eligible(host)) {
      throw StateError('applet_control_unavailable');
    }
    if (purpose.runes.length > 800 ||
        RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F]').hasMatch(purpose)) {
      throw ArgumentError('applet_control_purpose');
    }
    _grantBusy = true;
    _changed();
    try {
      final session = host.controlSessionId;
      final info = await _hostResult(host.controlInfo());
      if (!_eligible(host) ||
          host.controlSessionId != session ||
          info['controlProtocolVersion'] != 1 ||
          info['ready'] != true ||
          info['projectKind'] != 'applet') {
        throw StateError('applet_control_unsupported');
      }
      if (_active != null) throw StateError('applet_control_already_granted');
      final epoch = ++_epoch;
      late ProjectAppletGrant grant;
      grant = ProjectAppletGrant._(
        _authority,
        host,
        host.controlAgentId,
        session,
        epoch,
        purpose,
        DateTime.now().toUtc().add(grantLifetime),
        () =>
            identical(_active, grant) &&
            _eligible(host) &&
            host.controlSessionId == session &&
            epoch == _epoch,
        grantLifetime,
        maximumActions,
        maximumObservations,
      );
      _active = grant;
      _expiry = Timer(grantLifetime, () => _revoke(grant, 'expired'));
      _grants.add(grant);
      _changed();
      return grant;
    } finally {
      _grantBusy = false;
      _changed();
    }
  }

  void _guard(ProjectAppletGrant grant) {
    if (!identical(grant, _active) || !grant.isCurrent) {
      if (identical(grant, _active)) _revoke(grant, 'expired_or_revoked');
      throw StateError('applet_control_revoked');
    }
  }

  List<Map<String, Object?>> _actions(ProjectAppletGrant grant) => grant
      ._host
      .controlProtocol
      .actions
      .where(
        (action) =>
            action['effect'] == 'localAppState' &&
            (action['roles'] as List).contains('player2'),
      )
      .toList(growable: false);
  Map<String, Object?> describe(ProjectAppletGrant grant) {
    _guard(grant);
    return _freeze({
      'projectId': grant.projectId,
      'revisionId': grant.revisionId,
      'candidateDigest': grant.candidateDigest,
      'sessionId': grant.sessionId,
      'controlEpoch': grant.controlEpoch,
      'expiresAt': grant.expiresAt.toIso8601String(),
      'remainingActions': grant.remainingActions,
      'purpose': grant.purpose,
      'authority': {
        'origin': 'native_user',
        'role': 'player2',
        'effect': 'localAppState',
      },
      'projectDescription': {
        'untrusted': true,
        'title': grant._host.controlTitle,
        'agentMarkdown': String.fromCharCodes(
          grant._host.controlAgentDocument.runes.take(8000),
        ),
        'actions': _actions(grant),
      },
    });
  }

  Future<Map<String, Object?>> observe(ProjectAppletGrant grant) =>
      _operation(() => _observe(grant));

  Future<Map<String, Object?>> _observe(ProjectAppletGrant grant) async {
    _guard(grant);
    if (grant._observations >= grant._maximumObservations) {
      _revoke(grant, 'observation_budget');
      throw StateError('applet_observation_limit');
    }
    grant._observations++;
    final snapshot = _validateObservation(
      await _hostResult(grant._host.inspectApplet(), grant),
    );
    _guard(grant);
    final id = _random();
    _observations[id] = snapshot;
    while (_observations.length > 8) {
      _observations.remove(_observations.keys.first);
    }
    return _freeze({
      ...snapshot,
      'observationId': id,
      'untrusted': true,
      'sessionId': grant.sessionId,
      'controlEpoch': grant.controlEpoch,
      'projectId': grant.projectId,
      'candidateDigest': grant.candidateDigest,
    });
  }

  Map<String, Object?> _validateObservation(Map<String, Object?> raw) {
    final snapshot = _freeze(raw);
    if (snapshot['ready'] != true ||
        snapshot['controlProtocolVersion'] != 1 ||
        snapshot['stateVersion'] is! int ||
        (snapshot['stateVersion']! as int) < 1 ||
        (snapshot['stateVersion']! as int) > 9007199254740991 ||
        snapshot['routeId'] is! String ||
        (snapshot['routeId']! as String).length > 96 ||
        snapshot['params'] is! Map ||
        !snapshot.containsKey('visibleState')) {
      throw StateError('applet_observation_invalid');
    }
    return snapshot;
  }

  void _requestId(String id) {
    if (!RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(id)) {
      throw ArgumentError('applet_request_id');
    }
  }

  Future<Map<String, Object?>> act(
    ProjectAppletGrant grant, {
    required String requestId,
    required String observationId,
    required String actionId,
    required Map<String, Object?> args,
    required int expectedStateVersion,
    bool Function()? canContinue,
    Future<void>? onInvalidated,
  }) => _operation(
    () => _act(
      grant,
      requestId: requestId,
      observationId: observationId,
      actionId: actionId,
      args: args,
      expectedStateVersion: expectedStateVersion,
      canContinue: canContinue,
      onInvalidated: onInvalidated,
    ),
  );

  Future<Map<String, Object?>> _act(
    ProjectAppletGrant grant, {
    required String requestId,
    required String observationId,
    required String actionId,
    required Map<String, Object?> args,
    required int expectedStateVersion,
    bool Function()? canContinue,
    Future<void>? onInvalidated,
  }) async {
    _guard(grant);
    _requestId(requestId);
    final normalized = _freeze(args);
    final identity = projectBundleV2JsonDigest({
      'sessionId': grant.sessionId,
      'controlEpoch': grant.controlEpoch,
      'candidateDigest': grant.candidateDigest,
      'requestId': requestId,
      'observationId': observationId,
      'actionId': actionId,
      'args': normalized,
      'expectedStateVersion': expectedStateVersion,
    });
    final active = _admission;
    if (active != null) {
      if (active.requestId != requestId) {
        throw StateError('applet_action_pending');
      }
      if (active.identity != identity) {
        throw StateError('applet_request_id_conflict');
      }
      return active.future;
    }
    final work = _performAct(
      grant,
      requestId,
      observationId,
      actionId,
      normalized,
      expectedStateVersion,
      identity,
      canContinue,
      onInvalidated,
    );
    final admission = _AppletAdmission(requestId, identity, work);
    _admission = admission;
    try {
      return await work;
    } finally {
      if (identical(_admission, admission)) _admission = null;
    }
  }

  Future<Map<String, Object?>> _performAct(
    ProjectAppletGrant grant,
    String requestId,
    String observationId,
    String actionId,
    Map<String, Object?> normalized,
    int expectedStateVersion,
    String identity,
    bool Function()? canContinue,
    Future<void>? onInvalidated,
  ) async {
    var invalidated = false;
    _AppletCall? issued;
    bool invocationCurrent() {
      try {
        return !invalidated && (canContinue?.call() ?? true);
      } catch (_) {
        return false;
      }
    }

    void guard() {
      _guard(grant);
      if (!invocationCurrent()) throw StateError('applet_invocation_cancelled');
    }

    if (onInvalidated != null) {
      unawaited(
        onInvalidated.then<void>((_) {
          invalidated = true;
          final call = issued;
          if (call != null && identical(_calls[requestId], call)) {
            _revoke(grant, 'invocation_cancelled');
          }
        }),
      );
    }
    guard();
    final prior = await journal.read(
      grant.sessionId,
      requestId,
      canContinue: () => grant.isCurrent && invocationCurrent(),
    );
    guard();
    if (prior != null) {
      if (prior['identityDigest'] != identity) {
        throw StateError('applet_request_id_conflict');
      }
      return receipt(grant, requestId);
    }
    if (_calls.isNotEmpty) throw StateError('applet_action_pending');
    if (grant.remainingActions == 0) throw StateError('applet_action_limit');
    final observation = _observations[observationId];
    if (observation == null ||
        observation['stateVersion'] != expectedStateVersion) {
      throw StateError('applet_observation_stale');
    }
    if (!_actions(grant).any((entry) => entry['id'] == actionId) ||
        !grant._host.controlProtocol.allowsAction(
          'player2',
          actionId,
          normalized,
        )) {
      throw StateError('applet_action_not_allowed');
    }
    final reserved = await journal.reserve(
      projectId: grant.projectId,
      candidateDigest: grant.candidateDigest,
      sessionId: grant.sessionId,
      controlEpoch: grant.controlEpoch,
      requestId: requestId,
      actionId: actionId,
      identityDigest: identity,
      canContinue: () => grant.isCurrent && invocationCurrent(),
    );
    _guard(grant);
    if (!invocationCurrent()) {
      return journal.settle(grant.sessionId, requestId, identity, {
        'requestId': requestId,
        'actionId': actionId,
        'status': 'cancelled',
        'mayHaveApplied': false,
        'untrusted': true,
      }, canContinue: () => _current && grant._host.canRetainControlReceipts);
    }
    if (!reserved.created) return receipt(grant, requestId);
    grant._actions++;
    final call = _AppletCall(
      grant,
      requestId,
      actionId,
      identity,
      _random(),
      expectedStateVersion,
    );
    issued = call;
    _calls[requestId] = call;
    _changed();
    // Dispatch acknowledgements can be lost. Only a verified callback or a
    // read-only receipt query settles this journal entry; never resend it.
    unawaited(
      Future<void>.sync(
        () => grant._host.dispatchApplet({
          'requestId': requestId,
          'actionId': actionId,
          'args': normalized,
          'expectedStateVersion': expectedStateVersion,
          'expectedObservation': observation,
        }, call.callbackToken),
      ).catchError((Object _) {}),
    );
    return call.result.future.timeout(
      commandTimeout,
      onTimeout: () => _pendingReceipt(call),
    );
  }

  Map<String, Object?> _pendingReceipt(_AppletCall call) => {
    'requestId': call.requestId,
    'actionId': call.actionId,
    'status': 'pending',
    'mayHaveApplied': true,
    'untrusted': true,
  };
  Future<Map<String, Object?>> receipt(
    ProjectAppletGrant grant,
    String requestId,
  ) => _operation(() => _receipt(grant, requestId));

  Future<Map<String, Object?>> _receipt(
    ProjectAppletGrant grant,
    String requestId,
  ) async {
    void guardReceipt() {
      if (!_current ||
          !identical(grant._authority, _authority) ||
          grant._host.controlScopeKey != scopeKey ||
          !grant._host.canRetainControlReceipts) {
        throw StateError('applet_control_revoked');
      }
    }

    guardReceipt();
    _requestId(requestId);
    if (++grant._receiptQueries > 128) {
      throw StateError('applet_receipt_query_limit');
    }
    final row = await journal.read(
      grant.sessionId,
      requestId,
      canContinue: () => _current && grant._host.canRetainControlReceipts,
    );
    guardReceipt();
    if (row == null) {
      return {
        'requestId': requestId,
        'status': 'not_found',
        'retryPermitted': false,
      };
    }
    if (row['receipt'] is Map) {
      return Map<String, Object?>.from(row['receipt']! as Map);
    }
    final call = _calls[requestId];
    if (grant.isCurrent && call != null && identical(call.grant, grant)) {
      try {
        final found = await _hostResult(
          grant._host.lookupAppletReceipt(requestId),
          grant,
        );
        _guard(grant);
        if (found != null && found['status'] != 'pending') {
          return await _finish(call, found);
        }
      } catch (_) {
        _guard(grant);
      }
      return _pendingReceipt(call);
    }
    return {
      'requestId': requestId,
      'actionId': row['actionId'],
      'status': 'pending',
      'mayHaveApplied': true,
      'retryPermitted': false,
    };
  }

  Future<bool> acceptRuntimeResult(
    ProjectAppletControlHost host,
    String callbackToken,
    Map<String, Object?> raw,
  ) => _operation(() => _acceptRuntimeResult(host, callbackToken, raw));

  Future<bool> _acceptRuntimeResult(
    ProjectAppletControlHost host,
    String callbackToken,
    Map<String, Object?> raw,
  ) async {
    final id = raw['requestId'];
    final call = id is String ? _calls[id] : null;
    if (call == null ||
        !identical(call.grant._host, host) ||
        call.callbackToken != callbackToken ||
        !call.grant.isCurrent) {
      return false;
    }
    await _finish(call, raw);
    return true;
  }

  Future<Map<String, Object?>> _finish(
    _AppletCall call,
    Map<String, Object?> raw,
  ) async {
    if (raw['requestId'] != call.requestId ||
        raw['actionId'] != call.actionId ||
        !const {
          'applied',
          'failed',
          'rejected',
          'unknown',
        }.contains(raw['status'])) {
      throw StateError('applet_receipt_invalid');
    }
    if (const {'applied', 'failed'}.contains(raw['status']) &&
        (raw['stateVersion'] is! int ||
            (raw['stateVersion']! as int) <= call.expectedVersion ||
            (raw['stateVersion']! as int) > 9007199254740991)) {
      throw StateError('applet_receipt_invalid');
    }
    final value =
        _receiptJson.parse(
              _receiptJson.canonicalize({
                ...raw,
                'untrusted': true,
                'mayHaveApplied': raw['status'] != 'rejected',
              }),
            )!
            as Map<String, Object?>;
    final result = await journal.settle(
      call.grant.sessionId,
      call.requestId,
      call.identity,
      value,
      canContinue: () => _current && call.grant._host.canRetainControlReceipts,
    );
    if (!call.result.isCompleted) call.result.complete(result);
    if (identical(_calls[call.requestId], call)) _calls.remove(call.requestId);
    if (identical(_active, call.grant) && raw['status'] == 'unknown') {
      _revoke(call.grant, 'runtime_unknown');
    }
    _changed();
    return result;
  }

  Future<void> takeOverFromNative(ProjectAppletControlHost host) async {
    final grant = _active;
    if (grant != null && identical(grant._host, host)) {
      _revoke(grant, 'user_takeover');
    }
  }

  void _track(Future<void> future) {
    late Future<void> safe;
    safe = future
        .catchError((Object _) {})
        .whenComplete(() => _pending.remove(safe));
    _pending.add(safe);
  }

  void _revoke(ProjectAppletGrant grant, String reason, {bool restore = true}) {
    if (!grant._live) return;
    grant._live = false;
    _expiry?.cancel();
    if (identical(_active, grant)) {
      _active = null;
      _epoch++;
      _observations.clear();
    }
    if (!grant._revoked.isCompleted) grant._revoked.complete(reason);
    if (restore) grant._host.fenceAppletDocument();
    for (final call
        in _calls.values
            .where((entry) => identical(entry.grant, grant))
            .toList()) {
      final result = <String, Object?>{
        'requestId': call.requestId,
        'actionId': call.actionId,
        'status': 'interrupted',
        'mayHaveApplied': true,
        'error': reason,
        'untrusted': true,
      };
      _track(
        journal
            .settle(
              grant.sessionId,
              call.requestId,
              call.identity,
              result,
              canContinue: () =>
                  _current && grant._host.canRetainControlReceipts,
            )
            .then<void>((_) {}),
      );
      if (!call.result.isCompleted) call.result.complete(result);
      _calls.remove(call.requestId);
    }
    if (restore) _track(grant._host.restoreAppletDocument());
    _changed();
  }

  Future<void> purgeDeletedProject(ProjectBuildV2DeletionProof proof) async {
    if (!_current ||
        !proof.isScopeCurrent ||
        proof.scopeKey != journal.repositoryScopeKey) {
      throw StateError('applet_control_scope');
    }
    final grant = _active;
    if (grant?.projectId == proof.projectId) {
      _revoke(grant!, 'project_deleted', restore: false);
    }
    await journal.purgeDeletedProject(proof);
  }

  Future<void> deactivateAndDrain() async {
    if (_sealed) return;
    final grant = _active;
    if (grant != null) _revoke(grant, 'scope_changed', restore: false);
    _sealed = true;
    _retired.complete();
    _expiry?.cancel();
    _hosts.clear();
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
    await _changes.close();
    await _grants.close();
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}
