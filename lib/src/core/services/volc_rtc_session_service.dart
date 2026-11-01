import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/realtime_action_cursor_store.dart';
import 'package:maaso/src/core/services/realtime_action_stream_service.dart';
import 'package:maaso/src/core/services/realtime_session_client.dart';

typedef RealtimeSessionCreator =
    Future<RealtimeSession> Function({
      required String agentId,
      required String requestId,
      AccountDeviceLeaseRequestAuthority? authority,
      String? userId,
      AppLocale? locale,
      int resumeAfterSequence,
    });

typedef RealtimeActionConnector =
    Future<void> Function(
      RealtimeSession session, {
      AccountDeviceLeaseRequestAuthority? authority,
      String agentId,
      AppLocale? locale,
    });

typedef RealtimeActionDisconnect = Future<void> Function();
typedef RealtimeAuthorityProvider =
    AccountDeviceLeaseRequestAuthority Function();
typedef RealtimeActionCursorReader =
    Future<int> Function(RealtimeSession session);
typedef RealtimeRequestIdGenerator = String Function();
typedef RealtimeAuthorityFailureHandler = void Function(Object error);

class VolcRtcJoinConfig {
  const VolcRtcJoinConfig({
    required this.appId,
    required this.roomId,
    required this.userId,
    required this.token,
    this.agentUserId,
  });

  final String appId;
  final String roomId;
  final String userId;
  final String token;
  final String? agentUserId;
}

class VolcRtcTerminalEvent {
  const VolcRtcTerminalEvent({required this.roomId, required this.reason});

  final String roomId;
  final String reason;
}

abstract interface class VolcRtcNativeAdapter {
  Stream<VolcRtcTerminalEvent> get terminalEvents;
  Future<void> join(VolcRtcJoinConfig config);
  Future<void> leave();
  Future<void> dispose();
}

class VolcRtcSessionService {
  VolcRtcSessionService({
    required RealtimeSessionClient sessionClient,
    required RealtimeActionStreamService actionStreamService,
    required VolcRtcNativeAdapter rtcAdapter,
    RealtimeAuthorityProvider? authorityProvider,
    RealtimeActionCursorStore? cursorStore,
    RealtimeRequestIdGenerator? requestIdGenerator,
    RealtimeAuthorityFailureHandler? onAuthorityFailure,
    Future<void> Function()? beforeCloudUse,
    Stream<Object?>? privacyRevocations,
  }) : this.raw(
         createSession: sessionClient.createSession,
         rtcAdapter: rtcAdapter,
         connectActions: actionStreamService.connect,
         disconnectActions: actionStreamService.disconnect,
         authorityProvider: authorityProvider,
         readCursor: cursorStore == null
             ? null
             : (session) => cursorStore.read(_cursorKey(session)),
         requestIdGenerator: requestIdGenerator,
         onAuthorityFailure: onAuthorityFailure,
         beforeCloudUse: beforeCloudUse,
         privacyRevocations: privacyRevocations,
       );

  VolcRtcSessionService.raw({
    required RealtimeSessionCreator createSession,
    required VolcRtcNativeAdapter rtcAdapter,
    required RealtimeActionConnector connectActions,
    required RealtimeActionDisconnect disconnectActions,
    RealtimeAuthorityProvider? authorityProvider,
    RealtimeActionCursorReader? readCursor,
    RealtimeRequestIdGenerator? requestIdGenerator,
    RealtimeAuthorityFailureHandler? onAuthorityFailure,
    Future<void> Function()? beforeCloudUse,
    Stream<Object?>? privacyRevocations,
  }) : _createSession = createSession,
       _rtcAdapter = rtcAdapter,
       _connectActions = connectActions,
       _disconnectActions = disconnectActions,
       _authorityProvider = authorityProvider,
       _readCursor = readCursor,
       _requestIdGenerator = requestIdGenerator ?? _newRealtimeRequestId,
       _onAuthorityFailure = onAuthorityFailure,
       _beforeCloudUse = beforeCloudUse {
    _rtcTerminalSubscription = rtcAdapter.terminalEvents.listen(
      _handleRtcTerminal,
    );
    _privacySubscription = privacyRevocations?.listen((_) {
      error.value = 'privacy_changed';
      unawaited(leave().catchError((Object _) {}));
    });
  }

  final RealtimeSessionCreator _createSession;
  final VolcRtcNativeAdapter _rtcAdapter;
  final RealtimeActionConnector _connectActions;
  final RealtimeActionDisconnect _disconnectActions;
  final RealtimeAuthorityProvider? _authorityProvider;
  final RealtimeActionCursorReader? _readCursor;
  final RealtimeRequestIdGenerator _requestIdGenerator;
  final RealtimeAuthorityFailureHandler? _onAuthorityFailure;
  late final StreamSubscription<VolcRtcTerminalEvent> _rtcTerminalSubscription;
  final Future<void> Function()? _beforeCloudUse;
  StreamSubscription<Object?>? _privacySubscription;

  final Set<Future<void>> _inFlightOperations = <Future<void>>{};
  Future<void>? _shutdownFuture;
  Future<RealtimeSession>? _joinOperation;
  Future<void>? _leaveOperation;
  _PendingRealtimeSessionCreate? _pendingCreate;
  int _joinGeneration = 0;
  bool _retiring = false;
  bool _cleanupRequired = false;

  final RxBool isJoined = false.obs;
  final Rxn<RealtimeSession> currentSession = Rxn<RealtimeSession>();
  final RxnString error = RxnString();

  Future<RealtimeSession> joinAgent({String agentId = 'self', String? userId}) {
    _requireActive();
    if (_joinOperation != null ||
        _leaveOperation != null ||
        _cleanupRequired ||
        isJoined.value) {
      return Future<RealtimeSession>.error(
        StateError('A realtime session join is already active.'),
      );
    }
    final generation = ++_joinGeneration;
    late final Future<RealtimeSession> operation;
    operation =
        _joinAgent(
          agentId: agentId,
          userId: userId,
          generation: generation,
        ).whenComplete(() {
          if (identical(_joinOperation, operation)) _joinOperation = null;
        });
    _joinOperation = operation;
    return _trackOperation(operation);
  }

  Future<RealtimeSession> _joinAgent({
    required String agentId,
    String? userId,
    required int generation,
  }) async {
    _requireCurrentJoin(generation);
    final requestedLocale = AgentPromptCatalog.currentLocale;
    final authority = _authorityProvider?.call();
    authority?.requireCurrent();
    if (authority != null && authority.agentId != agentId) {
      throw StateError('Realtime authority does not match the requested agent');
    }

    final pending = _pendingFor(
      agentId: agentId,
      userId: userId,
      locale: requestedLocale,
      authority: authority,
    );
    final sessionLocale = pending.locale;
    error.value = null;
    var rtcJoinStarted = false;
    var actionConnectStarted = false;
    try {
      var resumeAfterSequence = 0;
      final priorSession = pending.session;
      if (priorSession != null && authority != null) {
        final reader = _readCursor;
        if (reader == null) {
          throw StateError('Fenced realtime session has no cursor reader');
        }
        resumeAfterSequence = await reader(priorSession);
        _requireCurrentJoin(generation);
        authority.requireCurrent();
      }

      await _beforeCloudUse?.call();
      _requireCurrentJoin(generation);
      final session = await _createSession(
        agentId: pending.agentId,
        requestId: pending.requestId,
        authority: authority,
        userId: pending.userId,
        locale: sessionLocale,
        resumeAfterSequence: resumeAfterSequence,
      );
      _requireCurrentJoin(generation);
      authority?.requireCurrent();
      _validateSession(session, authority, priorSession);
      if (authority == null) {
        if (identical(_pendingCreate, pending)) _pendingCreate = null;
      } else {
        pending.session = session;
      }

      final config = VolcRtcJoinConfig(
        appId: _required(session.rtcAppId, 'rtcAppId'),
        roomId: _required(session.roomId, 'roomId'),
        userId: _required(session.userId, 'userId'),
        token: _required(session.rtcToken, 'rtcToken'),
        agentUserId: session.agentUserId,
      );
      authority?.requireCurrent();
      await _beforeCloudUse?.call();
      _requireCurrentJoin(generation);
      rtcJoinStarted = true;
      _cleanupRequired = true;
      await _rtcAdapter.join(config);
      _requireCurrentJoin(generation);
      authority?.requireCurrent();

      actionConnectStarted = true;
      await _connectActions(
        session,
        authority: authority,
        agentId: pending.agentId,
        locale: sessionLocale,
      );
      _requireCurrentJoin(generation);
      authority?.requireCurrent();
      currentSession.value = session;
      isJoined.value = true;
      return session;
    } catch (exception) {
      _fenceIfAuthorityFailed(exception, authority);
      try {
        await _retireSessionResources(
          disconnectActions: actionConnectStarted,
          leaveRtc: rtcJoinStarted,
        );
        _cleanupRequired = false;
      } catch (cleanupError, cleanupStackTrace) {
        currentSession.value = null;
        isJoined.value = false;
        error.value = 'Realtime session is unavailable.';
        Error.throwWithStackTrace(
          StateError(
            'Realtime join failed and cleanup is incomplete: '
            '$exception; cleanup: $cleanupError',
          ),
          cleanupStackTrace,
        );
      }
      currentSession.value = null;
      isJoined.value = false;
      error.value = 'Realtime session is unavailable.';
      rethrow;
    }
  }

  Future<void> leave() {
    _requireActive();
    return _beginLeave();
  }

  Future<void> _beginLeave() {
    _joinGeneration++;
    final pending = _leaveOperation;
    if (pending != null) return pending;

    final joining = _joinOperation;
    final earlyCleanup = _cleanupOutcome(
      _retireSessionResources(disconnectActions: true, leaveRtc: true),
    );
    late final Future<void> leaving;
    leaving = _leaveAfterJoin(joining, earlyCleanup).whenComplete(() {
      if (identical(_leaveOperation, leaving)) _leaveOperation = null;
    });
    _leaveOperation = leaving;
    return _trackOperation(leaving);
  }

  Future<void> _leaveAfterJoin(
    Future<RealtimeSession>? joining,
    Future<({Object? error, StackTrace? stackTrace})> earlyCleanup,
  ) async {
    if (joining != null) {
      try {
        await joining;
      } catch (_) {
        // A leave-invalidated join is expected to fail closed.
      }
      await earlyCleanup;
      await _leave();
      return;
    }
    final outcome = await earlyCleanup;
    final cleanupError = outcome.error;
    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError, outcome.stackTrace!);
    }
    _clearJoinedState();
  }

  Future<void> _leave() async {
    await _retireSessionResources(disconnectActions: true, leaveRtc: true);
    _clearJoinedState();
  }

  Future<void> _retireSessionResources({
    required bool disconnectActions,
    required bool leaveRtc,
  }) async {
    Future<({Object? error, StackTrace? stackTrace})> attempt(
      Future<void> Function() step,
    ) async {
      try {
        await step();
        return (error: null, stackTrace: null);
      } catch (error, stackTrace) {
        return (error: error, stackTrace: stackTrace);
      }
    }

    final operations = <Future<({Object? error, StackTrace? stackTrace})>>[];
    if (disconnectActions) operations.add(attempt(_disconnectActions));
    if (leaveRtc) operations.add(attempt(_rtcAdapter.leave));
    final results = await Future.wait(operations);
    for (final result in results) {
      final cleanupError = result.error;
      if (cleanupError != null) {
        Error.throwWithStackTrace(cleanupError, result.stackTrace!);
      }
    }
  }

  Future<({Object? error, StackTrace? stackTrace})> _cleanupOutcome(
    Future<void> operation,
  ) async {
    try {
      await operation;
      return (error: null, stackTrace: null);
    } catch (error, stackTrace) {
      return (error: error, stackTrace: stackTrace);
    }
  }

  void _clearJoinedState() {
    currentSession.value = null;
    isJoined.value = false;
    _cleanupRequired = false;
  }

  void _handleRtcTerminal(VolcRtcTerminalEvent event) {
    if (_retiring) return;
    final session = currentSession.value;
    if (session != null && session.roomId != event.roomId) return;
    if (session == null && _joinOperation == null) return;

    currentSession.value = null;
    isJoined.value = false;
    error.value = 'Realtime session ended: ${event.reason}';
    _cleanupRequired = true;
    final cleanup = _beginLeave();
    unawaited(cleanup.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }

  Future<void> shutdown() {
    _retiring = true;
    _joinGeneration++;
    final pending = _shutdownFuture;
    if (pending != null) return pending;

    final completer = Completer<void>();
    final attempt = completer.future;
    _shutdownFuture = attempt;
    final operation = _shutdownOnce();
    unawaited(
      operation.then<void>(
        (_) => completer.complete(),
        onError: (Object error, StackTrace stackTrace) {
          if (identical(_shutdownFuture, attempt)) {
            _shutdownFuture = null;
          }
          completer.completeError(error, stackTrace);
        },
      ),
    );
    return attempt;
  }

  Future<void> _shutdownOnce() async {
    await _privacySubscription?.cancel();
    _privacySubscription = null;
    final subscriptionCancellation = _rtcTerminalSubscription.cancel();
    final admittedLeave = _leaveOperation;
    final earlyCleanup = _cleanupOutcome(
      admittedLeave ??
          _retireSessionResources(disconnectActions: true, leaveRtc: true),
    );
    await subscriptionCancellation;
    while (_inFlightOperations.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_inFlightOperations));
    }
    await earlyCleanup;
    await _leave();
    await _rtcAdapter.dispose();
    _pendingCreate = null;
  }

  Future<void> dispose() => shutdown();

  _PendingRealtimeSessionCreate _pendingFor({
    required String agentId,
    required String? userId,
    required AppLocale locale,
    required AccountDeviceLeaseRequestAuthority? authority,
  }) {
    final normalizedAgentId = agentId.trim();
    final normalizedUserId = userId?.trim();
    final identity = authority == null
        ? null
        : _RealtimeAuthorityIdentity.from(authority);
    final existing = _pendingCreate;
    if (existing != null && existing.matches(normalizedAgentId, identity)) {
      if (normalizedUserId != existing.userId) {
        throw StateError(
          'The active realtime request cannot change its user binding.',
        );
      }
      return existing;
    }
    final pending = _PendingRealtimeSessionCreate(
      agentId: normalizedAgentId,
      userId: normalizedUserId,
      locale: locale,
      authorityIdentity: identity,
      requestId: _requestIdGenerator(),
    );
    _pendingCreate = pending;
    return pending;
  }

  void _fenceIfAuthorityFailed(
    Object exception,
    AccountDeviceLeaseRequestAuthority? authority,
  ) {
    if (authority == null) return;
    var failed =
        exception is RealtimeBackendException && exception.isAuthorityFailure;
    if (!failed) {
      try {
        authority.requireCurrent();
      } catch (_) {
        failed = true;
      }
    }
    if (!failed) return;
    _pendingCreate = null;
    try {
      _onAuthorityFailure?.call(exception);
    } catch (_) {
      // The caller's synchronous fence is best effort; this join still fails.
    }
  }

  Future<T> _trackOperation<T>(Future<T> operation) {
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _inFlightOperations.add(settled);
    unawaited(
      settled.then<void>((_) {
        _inFlightOperations.remove(settled);
      }),
    );
    return operation;
  }

  void _requireActive() {
    if (_retiring) {
      throw StateError('Volc RTC session service is retiring.');
    }
  }

  void _requireCurrentJoin(int generation) {
    _requireActive();
    if (generation != _joinGeneration) {
      throw StateError('The realtime session join was retired.');
    }
  }

  static void _validateSession(
    RealtimeSession session,
    AccountDeviceLeaseRequestAuthority? authority,
    RealtimeSession? prior,
  ) {
    if (authority == null) {
      if (session.isFenced ||
          session.leaseEpoch != 0 ||
          session.rtcGeneration != 0) {
        throw StateError('Legacy realtime response mixed authority metadata');
      }
    } else if (!session.isFenced ||
        session.leaseEpoch != authority.leaseEpoch) {
      throw StateError('Realtime response authority does not match the lease');
    }
    if (prior != null &&
        (session.sessionId != prior.sessionId ||
            session.locale != prior.locale ||
            session.rtcAppId != prior.rtcAppId ||
            session.leaseEpoch != prior.leaseEpoch ||
            session.rtcGeneration != prior.rtcGeneration ||
            session.roomId != prior.roomId ||
            session.userId != prior.userId ||
            session.agentUserId != prior.agentUserId ||
            session.taskId != prior.taskId ||
            session.actionStreamUri != prior.actionStreamUri)) {
      throw StateError('Realtime session replay changed its stable binding');
    }
  }

  static String _required(String value, String field) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw StateError('realtime session missing $field');
    }
    return trimmed;
  }

  static RealtimeActionCursorKey _cursorKey(RealtimeSession session) =>
      RealtimeActionCursorKey(
        sessionId: session.sessionId,
        leaseEpoch: session.leaseEpoch,
        rtcGeneration: session.rtcGeneration,
      );

  static String _newRealtimeRequestId() {
    final random = Random.secure();
    final bytes = List<int>.generate(18, (_) => random.nextInt(256));
    return 'rrs_${base64Url.encode(bytes).replaceAll('=', '')}';
  }
}

final class _PendingRealtimeSessionCreate {
  _PendingRealtimeSessionCreate({
    required this.agentId,
    required this.userId,
    required this.locale,
    required this.authorityIdentity,
    required this.requestId,
  });

  final String agentId;
  final String? userId;
  final AppLocale locale;
  final _RealtimeAuthorityIdentity? authorityIdentity;
  final String requestId;
  RealtimeSession? session;

  bool matches(
    String candidateAgentId,
    _RealtimeAuthorityIdentity? candidate,
  ) => agentId == candidateAgentId && authorityIdentity == candidate;
}

final class _RealtimeAuthorityIdentity {
  const _RealtimeAuthorityIdentity({
    required this.agentId,
    required this.leaseId,
    required this.leaseEpoch,
    required this.runtimeInstanceId,
    required this.presenceSessionId,
  });

  factory _RealtimeAuthorityIdentity.from(
    AccountDeviceLeaseRequestAuthority authority,
  ) => _RealtimeAuthorityIdentity(
    agentId: authority.agentId,
    leaseId: authority.leaseId,
    leaseEpoch: authority.leaseEpoch,
    runtimeInstanceId: authority.runtimeInstanceId,
    presenceSessionId: authority.presenceSessionId,
  );

  final String agentId;
  final String leaseId;
  final int leaseEpoch;
  final String runtimeInstanceId;
  final String presenceSessionId;

  @override
  bool operator ==(Object other) =>
      other is _RealtimeAuthorityIdentity &&
      agentId == other.agentId &&
      leaseId == other.leaseId &&
      leaseEpoch == other.leaseEpoch &&
      runtimeInstanceId == other.runtimeInstanceId &&
      presenceSessionId == other.presenceSessionId;

  @override
  int get hashCode => Object.hash(
    agentId,
    leaseId,
    leaseEpoch,
    runtimeInstanceId,
    presenceSessionId,
  );
}
