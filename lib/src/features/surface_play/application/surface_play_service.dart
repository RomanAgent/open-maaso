import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:uuid/uuid.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';

import '../data/surface_play_store.dart';
import '../data/surface_companion_call_ledger.dart';
import '../domain/surface_play_agent_document.dart';
import '../domain/surface_play_budget.dart';
import '../domain/surface_play_messages.dart';
import '../domain/surface_play_protocol.dart';
import '../domain/trusted_turn_rules.dart';
import '../domain/trusted_realtime_rules.dart';
import '../domain/surface_play_frame.dart';
import 'surface_play_realtime_clock.dart';

final class SurfacePlayGrant {
  SurfacePlayGrant._(
    this._authority, {
    required this.scopeKey,
    required this.agentId,
    required this.sessionId,
    required this.matchId,
    required this.revisionId,
    required this.seatId,
    required this.mode,
    required this.matchEpoch,
    required this.seatControlEpoch,
    required this.expiresAt,
    required this.actor,
    required bool readOnly,
  }) : _readOnly = readOnly;
  final Object _authority;
  final bool _readOnly;
  final String scopeKey,
      agentId,
      sessionId,
      matchId,
      revisionId,
      seatId,
      mode,
      actor;
  final int matchEpoch, seatControlEpoch;
  final DateTime expiresAt;
}

/// The caller supplies an account mount and the exact visible presentation
/// fence. The default Agent-control authorizer refuses all control requests.
final class SurfacePlayService extends AppService {
  SurfacePlayService({
    required this.scopeKey,
    String? projectBuildScopeKey,
    required SurfacePlayPersistence persistence,
    required bool Function() isCurrent,
    Future<bool> Function(String sessionId, String seatId)?
    authorizeAgentControl,
    DateTime Function()? now,
    String Function()? nonce,
    int Function()? seed,
    Timer Function(Duration, void Function(Timer))? scheduleSimulationTick,
    SurfaceCompanionCallLedger? companionCalls,
  }) : projectBuildScopeKey = projectBuildScopeKey ?? scopeKey,
       _persistence = persistence,
       _isCurrent = isCurrent,
       _authorize = authorizeAgentControl ?? ((_, _) async => false),
       _now = now ?? DateTime.now,
       _nonce = nonce ?? const Uuid().v4,
       _seed = seed ?? (() => Random.secure().nextInt(0xffffffff) + 1),
       _scheduleSimulationTick = scheduleSimulationTick,
       _companionCalls =
           companionCalls ??
           (persistence is SurfaceCompanionCallLedgerOwner
               ? (persistence as SurfaceCompanionCallLedgerOwner).callLedger
               : null) {
    if (_companionCalls != null &&
        _companionCalls.scopeKey != this.projectBuildScopeKey) {
      throw ArgumentError('invalid_companion_budget_scope');
    }
  }
  final String scopeKey;
  final String projectBuildScopeKey;
  final Set<String> _deletedProjects = {};
  final SurfacePlayPersistence _persistence;
  final SurfaceCompanionCallLedger? _companionCalls;
  final bool Function() _isCurrent;
  final Future<bool> Function(String, String) _authorize;
  final DateTime Function() _now;
  final String Function() _nonce;
  final int Function() _seed;
  final Timer Function(Duration, void Function(Timer))? _scheduleSimulationTick;
  SurfacePlaySession? _active;
  bool _closed = false;
  SurfacePlaySession? get activeSession => _active;

  Future<SurfacePlaySession> openSession({
    required SurfacePlayProtocol protocol,
    required String sessionId,
    String? matchId,
    bool newMatch = false,
    required String agentId,
    required String contentManifestId,
    required String protocolJson,
    required String agentDocument,
    required bool Function() isPresentationCurrent,
  }) async {
    if (_closed || !_isCurrent() || !isPresentationCurrent()) {
      throw StateError('PLAY_SCOPE_CHANGED');
    }
    if (_deletedProjects.contains(protocol.projectId)) {
      throw StateError('PLAY_PROJECT_DELETED');
    }
    if (!protocol.isTrustedGame) {
      throw StateError('PLAY_RULESET_NOT_REGISTERED');
    }
    if (playCanonicalJson(jsonDecode(protocolJson)) !=
        playCanonicalJson(protocol.toJson())) {
      throw const FormatException('play_protocol_bytes_mismatch');
    }
    validateSurfacePlayAgentDocument(
      agentDocument,
      protocol: protocol,
      contentManifestId: contentManifestId,
      protocolSha256: surfaceProtocolDigest(protocolJson),
    );
    playIdentifier(sessionId);
    playIdentifier(agentId);
    if (newMatch && matchId != null) {
      throw ArgumentError('new_match_cannot_resume_id');
    }
    final resolvedMatchId =
        matchId ??
        (newMatch
            ? null
            : await _persistence.latestMatchId(
                projectId: protocol.projectId,
                revisionId: protocol.revisionId,
              )) ??
        _nonce();
    playIdentifier(resolvedMatchId);
    if (_closed || !_isCurrent() || !isPresentationCurrent()) {
      throw StateError('PLAY_SCOPE_CHANGED');
    }
    await _active?.close();
    final session = SurfacePlaySession._(
      protocol: protocol,
      sessionId: sessionId,
      matchId: resolvedMatchId,
      scopeKey: scopeKey,
      agentId: agentId,
      companionCalls: _companionCalls,
      contentManifestId: contentManifestId,
      agentDocument: agentDocument,
      persistence: _persistence,
      isCurrent: () =>
          !_closed &&
          _isCurrent() &&
          isPresentationCurrent() &&
          !_deletedProjects.contains(protocol.projectId),
      authorize: _authorize,
      now: _now,
      nonce: _nonce,
      scheduleSimulationTick: _scheduleSimulationTick,
    );
    await session._open(seed: _seed());
    if (_closed || !_isCurrent() || !isPresentationCurrent()) {
      await session.close();
      throw StateError('PLAY_SCOPE_CHANGED');
    }
    _active = session;
    return session;
  }

  Future<void> purgeDeletedProject(
    ProjectBuildV2DeletionProof proof, {
    required String expectedProjectBuildScopeKey,
  }) async {
    void guard() {
      if (_closed ||
          !_isCurrent() ||
          !proof.isScopeCurrent ||
          proof.scopeKey != projectBuildScopeKey ||
          expectedProjectBuildScopeKey != projectBuildScopeKey) {
        throw StateError('PLAY_SCOPE_CHANGED');
      }
    }

    guard();
    final store = _persistence;
    if (store is! SurfacePlayProjectDeletionPersistence) {
      throw StateError('PLAY_DELETE_PERSISTENCE_REQUIRED');
    }
    _deletedProjects.add(proof.projectId);
    final active = _active;
    if (active?.protocol.projectId == proof.projectId) {
      await active!.close();
      if (identical(_active, active)) _active = null;
    }
    guard();
    await (store as SurfacePlayProjectDeletionPersistence).purgeDeletedProject(
      proof,
      expectedProjectBuildScopeKey: expectedProjectBuildScopeKey,
    );
    guard();
  }

  Future<void> deactivateAndDrain() async {
    _closed = true;
    await _active?.close();
    _active = null;
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}

final class _ObservationAuthority {
  _ObservationAuthority(
    this.seat,
    this.decisionRevision,
    this.turnId,
    this.matchEpoch,
    this.seatEpoch,
    this.expiresAt,
    this.actions,
  );
  final String seat, turnId;
  final int decisionRevision, matchEpoch, seatEpoch;
  final DateTime expiresAt;
  final Map<String, Map<String, Object?>> actions;
}

/// One host owns the serialized commit lane. Full state and RNG are private;
/// only role projections and role-specific event cursors leave this class.
final class SurfacePlaySession {
  SurfacePlaySession._({
    required this.protocol,
    required this.sessionId,
    required this.matchId,
    required this.scopeKey,
    required this.agentId,
    required this.contentManifestId,
    required this.agentDocument,
    required SurfaceCompanionCallLedger? companionCalls,
    required SurfacePlayPersistence persistence,
    required bool Function() isCurrent,
    required Future<bool> Function(String, String) authorize,
    required DateTime Function() now,
    required String Function() nonce,
    Timer Function(Duration, void Function(Timer))? scheduleSimulationTick,
  }) : _store = persistence,
       _companionCalls = companionCalls,
       _isCurrent = isCurrent,
       _authorize = authorize,
       _now = now,
       _nonce = nonce,
       _rules = protocol.isRealtime
           ? TrustedRealtimeRules(protocol)
           : TrustedTurnRules(protocol) {
    if (protocol.isRealtime) {
      _realtimeClock = SurfacePlayRealtimeClock(
        onTick: () => _serial(_advanceRealtimeTick),
        canTick: () =>
            this.isCurrent &&
            _record != null &&
            !isPaused &&
            _state['phase'] == 'playing',
        onError: (_, _) => _haltRealtimeForStorage(),
        schedulePeriodic: scheduleSimulationTick,
      );
    }
  }
  final SurfacePlayProtocol protocol;
  final String sessionId,
      matchId,
      scopeKey,
      agentId,
      contentManifestId,
      agentDocument;
  final SurfacePlayPersistence _store;
  final SurfaceCompanionCallLedger? _companionCalls;
  final bool Function() _isCurrent;
  final Future<bool> Function(String, String) _authorize;
  final DateTime Function() _now;
  final String Function() _nonce;
  final TrustedPlayRules _rules;
  TrustedRealtimeRules? get _realtimeRules =>
      _rules is TrustedRealtimeRules ? _rules : null;
  SurfacePlayRealtimeClock? _realtimeClock;
  final _frames = StreamController<SurfacePlayFrame>.broadcast(sync: true);
  final Map<String, SurfacePlayGrant> _inputGrants = {};
  int _frameSequence = 0, _durableTick = 0;
  bool _storagePaused = false;
  Map<String, Object?>? _pendingRealtimeWrite;
  bool get isRealtime => protocol.isRealtime;
  String get pauseReason => _storagePaused
      ? 'checkpoint_unconfirmed'
      : isPaused
      ? 'paused'
      : '';
  SurfacePlayFrame? currentFrameHuman({String seatId = 'player1'}) {
    _guard();
    if (!{'player1', 'player2'}.contains(seatId)) {
      throw StateError('INVALID_SEAT');
    }
    return isRealtime ? _frameForSeat(seatId) : null;
  }

  Stream<SurfacePlayFrame> framesForHumanSeat(String seatId) {
    if (!{'player1', 'player2'}.contains(seatId)) {
      throw StateError('INVALID_SEAT');
    }
    if (!isRealtime) return const Stream.empty();
    return _frames.stream.where((f) => isCurrent && f.seatId == seatId);
  }

  SurfacePlayFrame? frameFor(SurfacePlayGrant grant) {
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    return isRealtime ? _frameForSeat(grant.seatId) : null;
  }

  Stream<SurfacePlayFrame> framesFor(SurfacePlayGrant grant) {
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    if (!isRealtime) return const Stream.empty();
    return _frames.stream.where(
      (f) => grantIsCurrent(grant) && f.seatId == grant.seatId,
    );
  }

  SurfacePlayFrame _frameForSeat(String seat) => SurfacePlayFrame({
    'protocolVersion': 2,
    'projectId': protocol.projectId,
    'revisionId': protocol.revisionId,
    'sessionId': sessionId,
    'matchId': matchId,
    'matchEpoch': _matchEpoch,
    'seatId': seat,
    'frameSequence': _frameSequence,
    'simTick': _state['simTick'],
    'decisionRevision': _decisionRevision(seat),
    'windowId': _realtimeRules!.windowId(_state),
    'phase': isPaused ? 'paused' : _state['phase'],
    'allowedView': _rules.view(_state, seat),
  });
  void _publishFrame() {
    if (!isRealtime || _record == null || !isCurrent || _frames.isClosed) {
      return;
    }
    _frameSequence++;
    for (final seat in surfacePlayRoles) {
      if (!isCurrent || _frames.isClosed) break;
      _frames.add(_frameForSeat(seat));
    }
  }

  void _clearRealtimeInputs({Set<String>? seats}) {
    final rules = _realtimeRules;
    if (rules == null || _record == null) return;
    if (seats == null) {
      _inputGrants.clear();
    } else {
      for (final seat in seats) {
        _inputGrants.remove(seat);
      }
    }
    _record = {
      ..._record!,
      'rulesState': rules.clearInputs(_state, onlySeats: seats),
    };
  }

  void _haltRealtimeForStorage() {
    if (!isRealtime || !isCurrent) return;
    _storagePaused = true;
    _realtimeClock?.stopNow();
    _clearRealtimeInputs();
    _notifyAuthorityChanged();
    _publishFrame();
  }

  final Object _grantAuthority = Object();
  final Map<String, _ObservationAuthority> _observations = {};
  final StreamController<SurfacePlayViewEvent> _events =
      StreamController.broadcast(sync: true);
  final _authorityChanges = StreamController<void>.broadcast(sync: true);
  Stream<void> get onAuthorityChanged => _authorityChanges.stream;
  void _notifyAuthorityChanged() {
    if (!_authorityChanges.isClosed) _authorityChanges.add(null);
  }

  final Map<String, int> _seatEpochs = {
    for (final role in surfacePlayRoles) role: 1,
  };
  Future<void> _tail = Future.value();
  Map<String, Object?>? _record;
  bool _closed = false;
  bool _pauseRequested = false;
  int _matchEpoch = 1;
  Stream<SurfacePlayViewEvent> get onHumanViewEvent =>
      _events.stream.where((event) => isCurrent && event.seatId == 'player1');

  Stream<SurfacePlayViewEvent> humanEventsForSeat(String hostSeatId) {
    if (!{'player1', 'player2'}.contains(hostSeatId)) {
      throw StateError('INVALID_SEAT');
    }
    return _events.stream.where(
      (event) => isCurrent && event.seatId == hostSeatId,
    );
  }

  Stream<SurfacePlayViewEvent> eventsFor(SurfacePlayGrant grant) {
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    return _events.stream.where(
      (event) => grantIsCurrent(grant) && event.seatId == grant.seatId,
    );
  }

  bool get isCurrent => !_closed && _isCurrent();
  bool get isPaused =>
      _storagePaused || _pauseRequested || _record?['paused'] == true;
  String get mode => protocol.modes.first;
  int _counter(String group, String role) =>
      playObject(_record![group])[role]! as int;
  Map<String, Object?> get _state => playObject(_record!['rulesState']);
  int _decisionRevision(String seat) =>
      _counter(isRealtime ? 'decisionRevisions' : 'viewRevisions', seat);

  /// Aggregate native diagnostics only. No seat view, action/observation token,
  /// identity, seed, document, hidden choice or rules state leaves this read.
  Map<String, Object?> readDiagnostics() {
    _guard();
    const unknown = <String, Object?>{
      'status': 'unknown',
      'phase': null,
      'matchEpoch': null,
      'decisionRevision': null,
      'acceptedActionReceiptCount': null,
    };
    final record = _record;
    if (record == null || _pendingRealtimeWrite != null) return unknown;
    try {
      final receipts = playObject(record['receipts']);
      if (receipts.length > 4096) return unknown;
      final phase = isPaused
          ? 'paused'
          : _rules.view(_state, 'spectator')['phase'];
      if (phase is! String) return unknown;
      var accepted = 0;
      for (final raw in receipts.values) {
        final status = playObject(raw)['status'];
        if (!SurfacePlayReceiptStatus.values.any(
          (value) => value.name == status,
        )) {
          return unknown;
        }
        if (status == SurfacePlayReceiptStatus.applied.name) accepted++;
      }
      return Map<String, Object?>.unmodifiable({
        'status': 'available',
        'phase': phase,
        'matchEpoch': _matchEpoch,
        'decisionRevision': _decisionRevision('player2'),
        'acceptedActionReceiptCount': accepted,
      });
    } catch (_) {
      return unknown;
    }
  }

  /// Uses this session's immutable Agent identity. Missing/uncertain ledger
  /// evidence is unknown, never a fabricated zero or a monetary receipt.
  Future<Map<String, Object?>> readModelCallUsage() async {
    _guard();
    final ledger = _companionCalls;
    if (ledger == null) return SurfaceCompanionCallLedger.unknownUsage;
    final result = await ledger.readUsageForAgent(agentId);
    _guard();
    return result;
  }

  /// Revokes only this session's opaque Agent grant. Revocation must also work
  /// while a route/account fence is already false; inactive mounts never write.
  Future<void> revokeAgentGrant(SurfacePlayGrant grant) {
    if (!identical(grant._authority, _grantAuthority) ||
        grant.scopeKey != scopeKey ||
        grant.agentId != agentId ||
        grant.sessionId != sessionId ||
        grant.matchId != matchId ||
        grant.revisionId != protocol.revisionId ||
        grant.actor != 'agent' ||
        !surfacePlayRoles.contains(grant.seatId)) {
      throw StateError('GRANT_REVOKED');
    }
    if (_closed ||
        grant.matchEpoch != _matchEpoch ||
        grant.seatControlEpoch != _seatEpochs[grant.seatId] ||
        !_now().isBefore(grant.expiresAt)) {
      return Future<void>.value();
    }
    final seat = grant.seatId;
    _seatEpochs[seat] = _seatEpochs[seat]! + 1;
    _clearRealtimeInputs(seats: {seat});
    _publishFrame();
    _notifyAuthorityChanged();
    if (!isCurrent) return Future<void>.value();
    return _serial(() async {
      final next = _copy(_record)
        ..['seatEpochs'] = Map<String, int>.from(_seatEpochs);
      if (seat != 'spectator') {
        (next['controllers']! as Map)[seat] = 'human';
        _advanceViews(
          next,
          _state,
          [
            PlayRuleEvent('control.changed', [seat], {'controller': 'human'}),
          ],
          null,
          force: {seat},
        );
      }
      await _commit(next, () => isCurrent);
    });
  }

  /// Native visibility loss fences in memory before any asynchronous work.
  /// Returning to the foreground requires the ordinary explicit resume path.
  Future<void> suspendForVisibilityLoss() {
    if (_closed || _pauseRequested) return Future<void>.value();
    _pauseRequested = true;
    _matchEpoch++;
    _realtimeClock?.stopNow();
    _clearRealtimeInputs();
    _publishFrame();
    _notifyAuthorityChanged();
    if (!isCurrent) return Future<void>.value();
    return _serial(() async {
      final next = _copy(_record)
        ..['paused'] = true
        ..['matchEpoch'] = _matchEpoch;
      _advanceViews(
        next,
        _state,
        [PlayRuleEvent('match.paused', surfacePlayRoles, {})],
        null,
        force: surfacePlayRoles.toSet(),
      );
      await _commit(next, () => isCurrent);
    });
  }

  Map<String, Object?> _copy(Object? value) =>
      playObject(jsonDecode(jsonEncode(value)));
  void _guard() {
    if (!isCurrent) throw StateError('PLAY_SCOPE_CHANGED');
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final previous = _tail;
    final work = () async {
      await previous;
      _guard();
      if (isRealtime && _record != null && _pendingRealtimeWrite != null) {
        await _reconcileRealtimeWrite();
      }
      return action();
    }();
    _tail = work.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return work;
  }

  Future<void> _open({required int seed}) async {
    _guard();
    final old = await _store.load(matchId);
    _guard();
    final now = _now().toUtc().toIso8601String();
    if (old == null) {
      final record = <String, Object?>{
        'schemaVersion': 2,
        'budgetLedgerVersion': 1,
        'agentId': agentId,
        'scopeKey': scopeKey,
        'matchId': matchId,
        'sessionId': sessionId,
        'projectId': protocol.projectId,
        'revisionId': protocol.revisionId,
        'contentManifestId': contentManifestId,
        'protocol': protocol.toJson(),
        'commitRevision': 0,
        'stateRevision': 0,
        'matchEpoch': 1,
        'seatEpochs': Map<String, int>.from(_seatEpochs),
        'paused': false,
        'controllers': {
          'player1': 'human',
          'player2': 'human',
          'spectator': 'observer',
        },
        'rulesState': _rules.initial(seed: seed),
        'viewRevisions': {for (final r in surfacePlayRoles) r: 0},
        if (isRealtime)
          'decisionRevisions': {for (final r in surfacePlayRoles) r: 0},
        'viewSequences': {for (final r in surfacePlayRoles) r: 0},
        'viewEvents': {for (final r in surfacePlayRoles) r: <Object?>[]},
        'receipts': <String, Object?>{},
        'createdAt': now,
        'updatedAt': now,
      };
      await _store.commit(
        matchId: matchId,
        expectedCommitRevision: null,
        next: record,
        isAuthorized: () => isCurrent,
      );
      _record = _copy(record);
      if (isRealtime) {
        _durableTick = _state['simTick']! as int;
        _publishFrame();
      }
      return;
    }
    if (old['scopeKey'] != scopeKey ||
        old['projectId'] != protocol.projectId ||
        old['revisionId'] != protocol.revisionId ||
        old['contentManifestId'] != contentManifestId ||
        playCanonicalJson(old['protocol']) !=
            playCanonicalJson(protocol.toJson())) {
      throw const FormatException('PLAY_RESTORED_VERSION_MISMATCH');
    }
    _rules.validateState(playObject(old['rulesState']));
    _record = _copy(old);
    _matchEpoch = playInteger(old['matchEpoch']) + 1;
    for (final role in surfacePlayRoles) {
      _seatEpochs[role] = playInteger(playObject(old['seatEpochs'])[role]) + 1;
    }
    final next = _copy(old)
      ..['sessionId'] = sessionId
      ..['matchEpoch'] = _matchEpoch
      ..['seatEpochs'] = Map<String, int>.from(_seatEpochs)
      ..['paused'] = isRealtime
      ..['controllers'] = {
        'player1': 'human',
        'player2': 'human',
        'spectator': 'observer',
      };
    if (isRealtime) {
      next['rulesState'] = _realtimeRules!.clearInputs(_state);
    }
    _advanceViews(
      next,
      _state,
      [PlayRuleEvent('match.restored', surfacePlayRoles, {})],
      null,
      force: surfacePlayRoles.toSet(),
    );
    await _commit(next, () => isCurrent);
  }

  Future<SurfacePlayGrant> grantAgentControl({
    String seatId = 'player2',
    Duration ttl = const Duration(minutes: 15),
  }) async {
    _guard();
    if (!surfacePlayRoles.contains(seatId) ||
        ttl <= Duration.zero ||
        ttl > const Duration(minutes: 30)) {
      throw StateError('INVALID_SEAT');
    }
    final epoch = _matchEpoch, seatEpoch = _seatEpochs[seatId];
    var issuedSeatEpoch = seatEpoch!;
    final permitted = await _authorize(sessionId, seatId);
    _guard();
    if (!permitted ||
        isPaused ||
        epoch != _matchEpoch ||
        seatEpoch != _seatEpochs[seatId]) {
      throw StateError('GRANT_REVOKED');
    }
    if (seatId != 'spectator') {
      await _serial(() async {
        if (isPaused ||
            epoch != _matchEpoch ||
            seatEpoch != _seatEpochs[seatId]) {
          throw StateError('GRANT_REVOKED');
        }
        _seatEpochs[seatId] = _seatEpochs[seatId]! + 1;
        issuedSeatEpoch = _seatEpochs[seatId]!;
        _notifyAuthorityChanged();
        final next = _copy(_record)
          ..['seatEpochs'] = Map<String, int>.from(_seatEpochs);
        playObject(next['controllers']);
        (next['controllers']! as Map)[seatId] = 'agent';
        _advanceViews(
          next,
          _state,
          [
            PlayRuleEvent('control.changed', [seatId], {'controller': 'agent'}),
          ],
          null,
          force: {seatId},
        );
        await _commit(
          next,
          () =>
              isCurrent &&
              !isPaused &&
              epoch == _matchEpoch &&
              issuedSeatEpoch == _seatEpochs[seatId],
        );
      });
    }
    if (!isCurrent ||
        isPaused ||
        epoch != _matchEpoch ||
        issuedSeatEpoch != _seatEpochs[seatId]) {
      throw StateError('GRANT_REVOKED');
    }
    return _grant(seatId, 'agent', ttl);
  }

  SurfacePlayGrant _grant(
    String seat,
    String actor,
    Duration ttl, {
    bool readOnly = false,
  }) {
    if (!surfacePlayRoles.contains(seat)) throw StateError('INVALID_SEAT');
    return SurfacePlayGrant._(
      _grantAuthority,
      scopeKey: scopeKey,
      agentId: agentId,
      sessionId: sessionId,
      matchId: matchId,
      revisionId: protocol.revisionId,
      seatId: seat,
      mode: seat == 'spectator' ? 'spectate' : mode,
      matchEpoch: _matchEpoch,
      seatControlEpoch: _seatEpochs[seat]!,
      expiresAt: _now().add(ttl),
      actor: actor,
      readOnly: readOnly || seat == 'spectator',
    );
  }

  bool grantIsCurrent(SurfacePlayGrant grant) =>
      isCurrent &&
      identical(grant._authority, _grantAuthority) &&
      grant.scopeKey == scopeKey &&
      grant.agentId == agentId &&
      grant.sessionId == sessionId &&
      grant.matchId == matchId &&
      grant.revisionId == protocol.revisionId &&
      grant.matchEpoch == _matchEpoch &&
      grant.seatControlEpoch == _seatEpochs[grant.seatId] &&
      _now().isBefore(grant.expiresAt) &&
      (grant._readOnly ||
          playObject(_record!['controllers'])[grant.seatId] == grant.actor);

  SurfacePlayObservation observeHuman({String seatId = 'player1'}) {
    _guard();
    if (!surfacePlayRoles.contains(seatId) || seatId == 'spectator') {
      throw StateError('INVALID_SEAT');
    }
    return observe(
      _grant(
        seatId,
        'human',
        const Duration(minutes: 1),
        readOnly: playObject(_record!['controllers'])[seatId] != 'human',
      ),
    );
  }

  SurfacePlayObservation observe(SurfacePlayGrant grant) {
    _guard();
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    final seat = grant.seatId, view = _rules.view(_state, seat), id = _nonce();
    final candidates = <Map<String, Object?>>[],
        tokens = <String, Map<String, Object?>>{};
    if (!isPaused && !grant._readOnly) {
      for (final action in _rules.legalActions(_state, seat)) {
        final token = _nonce();
        tokens[token] = action;
        candidates.add({...action, 'actionToken': token});
      }
    }
    final turnId = view['turnId']! as String,
        revision = _decisionRevision(seat);
    _observations[id] = _ObservationAuthority(
      seat,
      revision,
      turnId,
      _matchEpoch,
      _seatEpochs[seat]!,
      _now().add(const Duration(minutes: 1)),
      tokens,
    );
    while (_observations.length > 96) {
      _observations.remove(_observations.keys.first);
    }
    return SurfacePlayObservation({
      'protocolVersion': 2,
      'projectId': protocol.projectId,
      'revisionId': protocol.revisionId,
      'observationId': id,
      'sessionId': sessionId,
      'matchId': matchId,
      'matchEpoch': _matchEpoch,
      'seatControlEpoch': _seatEpochs[seat],
      'seatId': seat,
      'mode': grant.mode,
      'viewRevision': _counter('viewRevisions', seat),
      'decisionRevision': revision,
      'viewSequence': _counter('viewSequences', seat),
      'phase': isPaused ? 'paused' : view['phase'],
      'turnId': turnId,
      'allowedView': view,
      'legalActions': candidates,
    });
  }

  Future<SurfacePlayReceipt> submitHuman(
    SurfacePlayCommand command, {
    String seatId = 'player1',
  }) => submit(_grant(seatId, 'human', const Duration(minutes: 1)), command);

  Future<SurfacePlayReceipt> submit(
    SurfacePlayGrant grant,
    SurfacePlayCommand command,
  ) => _serial(() async {
    final hash = sha256
        .convert(utf8.encode(playCanonicalJson(command.toJson())))
        .toString();
    SurfacePlayReceipt denied(String code) => SurfacePlayReceipt(
      requestId: command.requestId,
      commandHash: hash,
      status: SurfacePlayReceiptStatus.rejected,
      beforeRevision: 0,
      afterRevision: 0,
      committedViewSequence: 0,
      errorCode: code,
    );
    if (!grantIsCurrent(grant) || grant._readOnly) {
      return denied('GRANT_REVOKED');
    }
    final seat = grant.seatId, key = '$seat:${command.requestId}';
    final receipts = playObject(_record!['receipts']);
    if (receipts[key] != null) {
      final previous = SurfacePlayReceipt.fromJson(playObject(receipts[key]));
      return previous.commandHash == hash
          ? previous.duplicate()
          : denied('IDEMPOTENCY_CONFLICT');
    }
    if (receipts.length >= 4096) return denied('RATE_LIMITED');
    if (isPaused) return denied('PAUSED');
    final observation = _observations[command.observationId];
    if (observation == null ||
        observation.seat != seat ||
        !_now().isBefore(observation.expiresAt) ||
        observation.matchEpoch != _matchEpoch ||
        observation.seatEpoch != _seatEpochs[seat] ||
        observation.decisionRevision != _decisionRevision(seat) ||
        command.expectedDecisionRevision != observation.decisionRevision ||
        command.expectedTurnId != observation.turnId) {
      return denied('STALE_OBSERVATION');
    }
    final legal = observation.actions[command.actionToken];
    if (legal == null ||
        legal['actionId'] != command.actionId ||
        playCanonicalJson(legal['args']) != playCanonicalJson(command.args)) {
      return denied('ILLEGAL_ACTION');
    }
    PlayRuleTransition transition;
    try {
      transition = _rules.reduce(_state, seat, command.actionId, command.args);
    } on PlayRuleViolation catch (error) {
      return denied(error.code);
    }
    final before = _decisionRevision(seat), next = _copy(_record);
    next['rulesState'] = transition.state;
    next['stateRevision'] = (_record!['stateRevision']! as int) + 1;
    _advanceViews(next, transition.state, transition.events, command.requestId);
    final receipt = SurfacePlayReceipt(
      requestId: command.requestId,
      commandHash: hash,
      status: SurfacePlayReceiptStatus.applied,
      beforeRevision: before,
      afterRevision:
          playObject(
                next[isRealtime ? 'decisionRevisions' : 'viewRevisions'],
              )[seat]!
              as int,
      committedViewSequence: playObject(next['viewSequences'])[seat]! as int,
    );
    (next['receipts']! as Map)[key] = receipt.toJson();
    if (isRealtime && command.actionId == 'game.input') {
      _inputGrants[seat] = grant;
    }
    bool guard() => grantIsCurrent(grant) && !isPaused;
    try {
      await _commit(next, guard);
      return receipt;
    } catch (_) {
      if (!grantIsCurrent(grant)) return denied('GRANT_REVOKED');
      // A lost acknowledgement cannot cause a second reduce/commit. Resolve
      // only from the durable receipt, otherwise keep the outcome unknown.
      try {
        final stored = await _store.load(matchId);
        _guard();
        if (stored != null &&
            stored['sessionId'] == sessionId &&
            stored['matchEpoch'] == _matchEpoch) {
          final accepted = playObject(stored['receipts'])[key];
          if (accepted != null) {
            final original = SurfacePlayReceipt.fromJson(playObject(accepted));
            if (original.commandHash == hash) {
              _adopt(stored);
              return original;
            }
          }
        }
      } catch (_) {}
      return SurfacePlayReceipt(
        requestId: command.requestId,
        commandHash: hash,
        status: SurfacePlayReceiptStatus.pending,
        beforeRevision: before,
        afterRevision: before,
        committedViewSequence: _counter('viewSequences', seat),
        errorCode: 'PERSISTENCE_UNCERTAIN',
      );
    }
  });

  /// Reserve before dispatch. Unknown provider outcomes keep their durable
  /// slot; only an explicit not-dispatched result may release it.
  Future<bool> reserveModelCall(
    SurfacePlayGrant grant,
    String invocationId,
    SurfacePlayCallBudget budget,
  ) async =>
      (await reserveModelCallDetailed(grant, invocationId, budget)).isReserved;

  Future<SurfacePlayCallReservation> reserveModelCallDetailed(
    SurfacePlayGrant grant,
    String invocationId,
    SurfacePlayCallBudget budget, {
    String? requestDigest,
  }) => _serial(() async {
    budget.validate();
    playIdentifier(invocationId);
    final ledger = _companionCalls;
    if (ledger == null || !grantIsCurrent(grant) || isPaused) {
      return SurfacePlayCallReservation.unavailable;
    }
    final digest =
        requestDigest ??
        surfaceProtocolDigest(
          playCanonicalJson({
            'sessionId': sessionId,
            'matchId': matchId,
            'invocationId': invocationId,
            'seatId': grant.seatId,
            'matchEpoch': grant.matchEpoch,
            'seatEpoch': grant.seatControlEpoch,
          }),
        );
    final reservation = await ledger.reserve(
      agentId: agentId,
      invocationId: invocationId,
      requestDigest: digest,
      budget: budget,
      isAuthorized: () => grantIsCurrent(grant) && !isPaused,
    );
    if (!reservation.isReserved) return reservation;
    // The global receipt is already durable. This journal is local audit only;
    // failure cannot authorize provider dispatch or refund an unknown call.
    try {
      final calls = List<Object?>.from(
        _record!['modelCalls'] as List? ?? const [],
      );
      calls.add({
        'invocationId': invocationId,
        'requestDigest': digest,
        'agentId': agentId,
        'seatId': grant.seatId,
        'at': _now().toUtc().toIso8601String(),
        'outcome': 'reserved',
      });
      while (calls.length > 1024) {
        calls.removeAt(0);
      }
      final next = _copy(_record)
        ..['budgetLedgerVersion'] = 1
        ..['modelCalls'] = calls;
      await _commit(next, () => grantIsCurrent(grant) && !isPaused);
      return reservation;
    } catch (_) {
      // This method has not returned permission to the driver, so no provider
      // dispatch can have happened on this reservation.
      try {
        await ledger.settle(
          agentId: agentId,
          invocationId: invocationId,
          requestDigest: digest,
          outcome: SurfaceCompanionCallOutcome.notDispatched,
        );
      } catch (_) {}
      rethrow;
    }
  });

  Future<void> settleModelCall(
    String invocationId, {
    required String outcome,
  }) => _serial(() async {
    final typed = switch (outcome) {
      'completed' => SurfaceCompanionCallOutcome.completed,
      'unknown' => SurfaceCompanionCallOutcome.unknown,
      'not_dispatched' => SurfaceCompanionCallOutcome.notDispatched,
      _ => throw ArgumentError('invalid_play_model_outcome'),
    };
    final calls = List<Object?>.from(
      _record!['modelCalls'] as List? ?? const [],
    );
    final index = calls.indexWhere(
      (raw) => playObject(raw)['invocationId'] == invocationId,
    );
    if (index < 0) return;
    final previous = playObject(calls[index]);
    if (previous['outcome'] != 'reserved') return;
    final digest = previous['requestDigest'];
    if (digest is! String || _companionCalls == null) return;
    await _companionCalls.settle(
      agentId: previous['agentId'] as String? ?? agentId,
      invocationId: invocationId,
      requestDigest: digest,
      outcome: typed,
    );
    if (outcome == 'not_dispatched') {
      calls.removeAt(index);
    } else {
      calls[index] = {...previous, 'outcome': outcome};
    }
    final next = _copy(_record)..['modelCalls'] = calls;
    await _commit(next, () => isCurrent);
  });

  bool observationIsCurrent(
    SurfacePlayGrant grant,
    SurfacePlayObservation observation,
  ) {
    final authority = _observations[observation.observationId];
    return grantIsCurrent(grant) &&
        !isPaused &&
        authority != null &&
        authority.seat == grant.seatId &&
        authority.matchEpoch == _matchEpoch &&
        authority.seatEpoch == _seatEpochs[grant.seatId] &&
        authority.decisionRevision == _decisionRevision(grant.seatId) &&
        _now().isBefore(authority.expiresAt);
  }

  Future<SurfacePlayReceipt?> receipt(
    SurfacePlayGrant grant,
    String requestId,
  ) => _serial(() async {
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    playIdentifier(requestId);
    final stored = await _store.load(matchId);
    _guard();
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    if (stored == null ||
        stored['sessionId'] != sessionId ||
        stored['matchEpoch'] != _matchEpoch) {
      throw StateError('STALE_SESSION');
    }
    if (!isRealtime ||
        playInteger(stored['commitRevision']) >
            playInteger(_record!['commitRevision'])) {
      _adopt(stored);
    }
    final raw = playObject(stored['receipts'])['${grant.seatId}:$requestId'];
    return raw == null ? null : SurfacePlayReceipt.fromJson(playObject(raw));
  });

  Future<SurfacePlayReceipt?> receiptHuman(
    String requestId, {
    String seatId = 'player1',
  }) => receipt(
    _grant(seatId, 'human', const Duration(minutes: 1), readOnly: true),
    requestId,
  );

  List<SurfacePlayViewEvent> eventsSince(
    SurfacePlayGrant grant,
    int afterViewSequence,
  ) {
    if (!grantIsCurrent(grant)) throw StateError('GRANT_REVOKED');
    playInteger(afterViewSequence);
    final events = (playObject(_record!['viewEvents'])[grant.seatId]! as List)
        .map((e) => SurfacePlayViewEvent(playObject(e)))
        .toList();
    final last = _counter('viewSequences', grant.seatId);
    if (afterViewSequence > last ||
        (events.isNotEmpty &&
            afterViewSequence < events.first.viewSequence - 1)) {
      throw StateError('VIEW_CURSOR_EXPIRED');
    }
    return List.unmodifiable(
      events.where((e) => e.viewSequence > afterViewSequence),
    );
  }

  /// Revocation is synchronous before any awaited persistence. A proposal that
  /// has not committed must recheck this epoch inside its transaction.
  Future<void> takeOverSeat(String seatId) {
    _guard();
    if (!{'player1', 'player2'}.contains(seatId)) {
      throw StateError('INVALID_SEAT');
    }
    _seatEpochs[seatId] = _seatEpochs[seatId]! + 1;
    _clearRealtimeInputs(seats: {seatId});
    _publishFrame();
    _notifyAuthorityChanged();
    return _serial(() async {
      final next = _copy(_record)
        ..['seatEpochs'] = Map<String, int>.from(_seatEpochs);
      (next['controllers']! as Map)[seatId] = 'human';
      _advanceViews(
        next,
        _state,
        [
          PlayRuleEvent('control.changed', [seatId], {'controller': 'human'}),
        ],
        null,
        force: {seatId},
      );
      await _commit(next, () => isCurrent);
    });
  }

  Future<void> pause() {
    _guard();
    _pauseRequested = true;
    _matchEpoch++;
    _realtimeClock?.stopNow();
    _clearRealtimeInputs();
    _publishFrame();
    _notifyAuthorityChanged();
    return _serial(() async {
      final next = _copy(_record)
        ..['paused'] = true
        ..['matchEpoch'] = _matchEpoch;
      _advanceViews(
        next,
        _state,
        [PlayRuleEvent('match.paused', surfacePlayRoles, {})],
        null,
        force: surfacePlayRoles.toSet(),
      );
      await _commit(next, () => isCurrent);
    });
  }

  Future<void> resume() => _serial(() async {
    _clearRealtimeInputs();
    _storagePaused = false;
    _matchEpoch++;
    _notifyAuthorityChanged();
    final resumingEpoch = _matchEpoch;
    final next = _copy(_record)
      ..['paused'] = false
      ..['matchEpoch'] = _matchEpoch;
    _advanceViews(
      next,
      _state,
      [PlayRuleEvent('match.resumed', surfacePlayRoles, {})],
      null,
      force: surfacePlayRoles.toSet(),
    );
    await _commit(next, () => isCurrent && _matchEpoch == resumingEpoch);
    _pauseRequested = false;
    _publishFrame();
    _realtimeClock?.start();
  });

  void _advanceViews(
    Map<String, Object?> next,
    Map<String, Object?> state,
    List<PlayRuleEvent> facts,
    String? requestId, {
    Set<String> force = const {},
  }) {
    final oldState = _state;
    for (final role in surfacePlayRoles) {
      final changed =
          force.contains(role) ||
          playCanonicalJson(_rules.view(oldState, role)) !=
              playCanonicalJson(_rules.view(state, role));
      if (changed) {
        (next['viewRevisions']! as Map)[role] =
            _counter('viewRevisions', role) + 1;
      }
      if (isRealtime) {
        final oldView = _rules.view(oldState, role),
            newView = _rules.view(state, role);
        final decisionChanged =
            force.contains(role) ||
            oldView['phase'] != newView['phase'] ||
            oldView['turnId'] != newView['turnId'] ||
            facts.any(
              (f) => f.type == 'input.accepted' && f.audience.contains(role),
            );
        (next['decisionRevisions']! as Map)[role] =
            _decisionRevision(role) + (decisionChanged ? 1 : 0);
      }
      var sequence = _counter('viewSequences', role);
      final journal = List<Object?>.from(
        playObject(next['viewEvents'])[role]! as List,
      );
      for (final fact in facts.where((e) => e.audience.contains(role))) {
        sequence++;
        journal.add({
          'seatId': role,
          'viewSequence': sequence,
          'eventId': _nonce(),
          'type': fact.type,
          'decisionRevision': playObject(
            next[isRealtime ? 'decisionRevisions' : 'viewRevisions'],
          )[role],
          'causedByRequestId': requestId,
          'payload': fact.payload,
        });
      }
      while (journal.length > 1024) {
        journal.removeAt(0);
      }
      (next['viewSequences']! as Map)[role] = sequence;
      (next['viewEvents']! as Map)[role] = journal;
    }
  }

  Future<void> _commit(
    Map<String, Object?> next,
    bool Function() authorized,
  ) async {
    final previous = _record!['commitRevision']! as int;
    next['commitRevision'] = previous + 1;
    next['updatedAt'] = _now().toUtc().toIso8601String();
    try {
      await _store.commit(
        matchId: matchId,
        expectedCommitRevision: previous,
        next: next,
        isAuthorized: () => isCurrent && authorized(),
      );
    } catch (_) {
      if (isRealtime && !isCurrent) rethrow;
      if (isRealtime && isCurrent) {
        // Revoking an action does not undo a transaction that may already have
        // committed. Reconcile that exact proposal before a pause/takeover
        // writes a new CAS; adoption still clears every revoked input.
        _pendingRealtimeWrite = _copy(next);
        try {
          final saved = await _store.load(matchId);
          _guard();
          if (saved != null &&
              playCanonicalJson(saved) == playCanonicalJson(next)) {
            _pendingRealtimeWrite = null;
            _adopt(saved);
            return;
          }
          if (!authorized() &&
              saved != null &&
              saved['commitRevision'] == previous) {
            _pendingRealtimeWrite = null;
          }
        } catch (_) {}
        if (_pendingRealtimeWrite == null) rethrow;
        _haltRealtimeForStorage();
      }
      rethrow;
    }
    _guard();
    _adopt(next);
  }

  void _adopt(Map<String, Object?> next) {
    final previous = _record;
    _record = _copy(next);
    if (isRealtime) {
      _durableTick = _state['simTick']! as int;
      final revoked = TrustedRealtimeRules.seats
          .where(
            (seat) =>
                playObject(playObject(_record!['rulesState'])['inputs'])[seat]
                    is Map &&
                playObject(
                      playObject(
                        playObject(_record!['rulesState'])['inputs'],
                      )[seat],
                    )['policy'] !=
                    'idle' &&
                (_inputGrants[seat] == null ||
                    !grantIsCurrent(_inputGrants[seat]!)),
          )
          .toSet();
      if (isPaused || _record!['matchEpoch'] != _matchEpoch) {
        _clearRealtimeInputs();
      } else if (revoked.isNotEmpty) {
        _clearRealtimeInputs(seats: revoked);
      }
      _publishFrame();
      if (_state['phase'] == 'playing' && !isPaused) {
        _realtimeClock?.start();
      } else {
        _realtimeClock?.stopNow();
      }
    }
    if (previous == null || _events.isClosed) return;
    for (final role in surfacePlayRoles) {
      final after = playObject(previous['viewSequences'])[role]! as int;
      for (final raw in playObject(next['viewEvents'])[role]! as List) {
        final event = SurfacePlayViewEvent(playObject(raw));
        if (event.viewSequence > after) _events.add(event);
      }
    }
  }

  Future<void> _advanceRealtimeTick() async {
    final rules = _realtimeRules;
    if (rules == null ||
        !isCurrent ||
        isPaused ||
        _state['phase'] != 'playing') {
      return;
    }
    final authorized = _inputGrants.entries
        .where((e) => grantIsCurrent(e.value))
        .map((e) => e.key)
        .toSet();
    final transition = rules.step(_state, authorizedSeats: authorized);
    final next = Map<String, Object?>.from(_record!);
    next['rulesState'] = transition.state;
    next['stateRevision'] = playInteger(_record!['stateRevision']) + 1;
    next['viewRevisions'] = {
      for (final role in surfacePlayRoles)
        role: _counter('viewRevisions', role) + 1,
    };
    next['decisionRevisions'] = playObject(_record!['decisionRevisions']);
    if (transition.events.isNotEmpty) {
      // The reliable journal and score/end-state are invisible until commit.
      next['viewEvents'] = playObject(
        playSnapshot(_record!['viewEvents'], maximumBytes: 2 * 1024 * 1024),
      );
      next['viewSequences'] = playObject(_record!['viewSequences']);
      _advanceViews(next, transition.state, transition.events, null);
    }
    if (transition.events.isNotEmpty ||
        (transition.state['simTick']! as int) - _durableTick >=
            TrustedRealtimeRules.checkpointTicks) {
      final epoch = _matchEpoch, seats = Map<String, int>.from(_seatEpochs);
      try {
        await _commit(
          next,
          () =>
              !isPaused &&
              _matchEpoch == epoch &&
              seats.entries.every((e) => _seatEpochs[e.key] == e.value),
        );
      } on StateError catch (error) {
        if (!isCurrent || error.message == 'PLAY_COMMIT_REVOKED') return;
        rethrow;
      }
    } else {
      // Shallow outer copy: do not serialize the growing receipt journal at 30Hz.
      _record = next;
      _publishFrame();
    }
  }

  Future<void> _reconcileRealtimeWrite() async {
    final pending = _pendingRealtimeWrite;
    if (pending == null) return;
    final saved = await _store.load(matchId);
    _guard();
    if (saved == null || saved['sessionId'] != sessionId) {
      throw StateError('STALE_SESSION');
    }
    final committed = playInteger(saved['commitRevision']),
        current = playInteger(_record!['commitRevision']);
    if (playCanonicalJson(saved) == playCanonicalJson(pending)) {
      _pendingRealtimeWrite = null;
      // The recorded effect is adopted exactly once; expired control is not
      // replayed. Explicit resume obtains a new epoch and clears inputs again.
      _adopt(saved);
      return;
    }
    if (committed == current) {
      _pendingRealtimeWrite = null;
      return;
    }
    throw StateError('PLAY_CHECKPOINT_CONFLICT');
  }

  Future<void> close() async {
    _closed = true;
    _realtimeClock?.stopNow();
    _clearRealtimeInputs();
    _notifyAuthorityChanged();
    _observations.clear();
    await _tail;
    await _realtimeClock?.close();
    await _events.close();
    await _authorityChanges.close();
    await _frames.close();
  }
}
