import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:sembast/sembast_memory.dart';

class _ControlledStore implements SurfacePlayPersistence {
  _ControlledStore(this.delegate);
  final SurfacePlayPersistence delegate;
  Completer<void>? beforeCommit;
  Completer<void>? entered;
  bool loseAck = false;
  bool failWrite = false;
  @override
  Future<String?> latestMatchId({
    required String projectId,
    required String revisionId,
  }) => delegate.latestMatchId(projectId: projectId, revisionId: revisionId);
  @override
  Future<Map<String, Object?>?> load(String matchId) => delegate.load(matchId);
  @override
  Future<void> commit({
    required String matchId,
    required int? expectedCommitRevision,
    required Map<String, Object?> next,
    required bool Function() isAuthorized,
  }) async {
    if (entered?.isCompleted == false) entered!.complete();
    await beforeCommit?.future;
    if (failWrite) throw StateError('injected_disk_failure');
    await delegate.commit(
      matchId: matchId,
      expectedCommitRevision: expectedCommitRevision,
      next: next,
      isAuthorized: isAuthorized,
    );
    if (loseAck) {
      loseAck = false;
      throw StateError('injected_lost_ack');
    }
  }
}

class _Harness {
  late DBService db;
  late _ControlledStore store;
  late SurfacePlayService service;
  late SurfacePlaySession session;
  late SurfacePlayProtocol protocol;
  bool current = true;
  bool allowed = true;
  int nonce = 0;
  DateTime now = DateTime.utc(2026, 9, 28);
  Future<void> open(String rules, {String hostSession = 'session-1'}) async {
    protocol = SurfacePlayProtocol.trustedGame(
      projectId: 'project-test',
      revisionId: 'revision-1',
      rulesId: rules,
      config: switch (rules) {
        'gomoku.v1' => {'boardSize': 5, 'winLength': 3},
        'cooperative-switches.v1' => {'switchesPerRole': 2, 'goalMask': 15},
        _ => {'cardsPerRole': 3},
      },
    );
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'play-${DateTime.now().microsecondsSinceEpoch}',
    );
    store = _ControlledStore(
      SurfacePlayStore(
        database: db,
        scopeKey: 'test|owner',
        isCurrent: () => current,
      ),
    );
    service = SurfacePlayService(
      scopeKey: 'test|owner',
      persistence: store,
      isCurrent: () => current,
      authorizeAgentControl: (_, _) async => allowed,
      now: () => now,
      nonce: () => 'nonce-${nonce++}',
      seed: () => 17,
    );
    await reopen(hostSession);
  }

  Future<void> reopen(String id) async {
    final json = jsonEncode(protocol.toJson());
    session = await service.openSession(
      protocol: protocol,
      sessionId: id,
      matchId: 'match-1',
      agentId: 'self',
      contentManifestId: 'content-1',
      protocolJson: json,
      agentDocument: buildSurfacePlayAgentDocument(
        protocol: protocol,
        contentManifestId: 'content-1',
        protocolSha256: surfaceProtocolDigest(json),
      ),
      isPresentationCurrent: () => current,
    );
  }

  Future<SurfacePlayReceipt> human(
    String seat,
    Map<String, Object?> args, {
    String? requestId,
  }) {
    final observation = session.observeHuman(seatId: seat);
    final legal = observation.legalActions.firstWhere(
      (a) => playCanonicalJson(a['args']) == playCanonicalJson(args),
    );
    return session.submitHuman(
      observation.commandFor(
        legal,
        requestId: requestId ?? 'request-${nonce++}',
      ),
      seatId: seat,
    );
  }

  Future<void> close() async {
    await service.deactivateAndDrain();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'shared bounded schema fixtures and verified protocol are immutable',
    () {
      final fixture = playObject(
        jsonDecode(
          File('tool/fixtures/surface_play_schema_v2.json').readAsStringSync(),
        ),
      );
      for (final value in fixture['valid']! as List) {
        validateBoundedAgentSchema(playObject(playObject(value)['schema']));
      }
      for (final value in fixture['invalid']! as List) {
        expect(
          () => validateBoundedAgentSchema(
            playObject(playObject(value)['schema']),
          ),
          throwsFormatException,
          reason: playObject(value)['name']! as String,
        );
      }
      final protocol = SurfacePlayProtocol.trustedGame(
        projectId: 'project-test',
        revisionId: 'revision-1',
        rulesId: 'gomoku.v1',
        config: {'boardSize': 15, 'winLength': 5},
      );
      final parsed = SurfacePlayProtocol.fromJson(protocol.toJson());
      expect(
        () => parsed.toJson()['projectKind'] = 'applet',
        throwsUnsupportedError,
      );
      expect(
        () => (parsed.toJson()['play']! as Map)['rulesId'] = 'unsafe',
        throwsUnsupportedError,
      );
      final changed = playObject(jsonDecode(jsonEncode(protocol.toJson())));
      (changed['capabilities']! as Map)['realtime'] = true;
      expect(
        () => SurfacePlayProtocol.fromJson(changed),
        throwsFormatException,
      );
    },
  );

  test(
    'both players use one real reducer through a complete gomoku game',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      final grant = await h.session.grantAgentControl();
      Future<SurfacePlayReceipt> agent(Map<String, Object?> args) async {
        final view = h.session.observe(grant);
        final legal = view.legalActions.firstWhere(
          (a) => playCanonicalJson(a['args']) == playCanonicalJson(args),
        );
        return h.session.submit(
          grant,
          view.commandFor(legal, requestId: 'request-${h.nonce++}'),
        );
      }

      expect(
        (await h.human('player1', {'x': 0, 'y': 0})).status,
        SurfacePlayReceiptStatus.applied,
      );
      expect(
        (await agent({'x': 0, 'y': 1})).status,
        SurfacePlayReceiptStatus.applied,
      );
      await h.human('player1', {'x': 1, 'y': 0});
      await agent({'x': 1, 'y': 1});
      await h.human('player1', {'x': 2, 'y': 0});
      final view = h.session.observe(grant);
      expect(view.allowedView['winner'], 1);
      expect(view.allowedView['phase'], 'ended');
      expect(view.legalActions, isEmpty);
    },
  );

  test(
    'private move changes no opposing view, cursor, hash or legal action state',
    () async {
      final h = _Harness();
      await h.open('private-cards.v1');
      addTearDown(h.close);
      final grant = await h.session.grantAgentControl();
      final seen = <SurfacePlayViewEvent>[];
      final sub = h.session.eventsFor(grant).listen(seen.add);
      addTearDown(sub.cancel);
      final before = h.session.observe(grant);
      final first = h.session.observeHuman();
      final agentCommand = before.commandFor(
        before.legalActions.first,
        requestId: 'agent-choice',
      );
      await h.session.submitHuman(
        first.commandFor(first.legalActions.first, requestId: 'human-choice'),
      );
      final after = h.session.observe(grant);
      Map<String, Object?> stable(SurfacePlayObservation o) => {...o.toJson()}
        ..remove('observationId')
        ..remove('legalActions');
      expect(stable(after), stable(before));
      expect(seen, isEmpty);
      expect(after.toJson().toString(), isNot(contains('rngState')));
      expect(after.allowedView.containsKey('hands'), isFalse);
      expect(
        after.legalActions.map((a) => a['args']),
        before.legalActions.map((a) => a['args']),
      );
      // A legitimately unchanged role decision remains valid across an unseen
      // private action; the internal global CAS must not leak that action.
      final receipt = await h.session.submit(grant, agentCommand);
      expect(receipt.status, SurfacePlayReceiptStatus.applied);
      expect(h.session.observe(grant).allowedView['phase'], 'ended');
      expect(seen.map((e) => e.viewSequence), orderedEquals([2, 3]));
    },
  );

  test(
    'cooperation requires both owned switch groups and is reversible before goal',
    () async {
      final h = _Harness();
      await h.open('cooperative-switches.v1');
      addTearDown(h.close);
      final human = h.session.observeHuman();
      final wrong = SurfacePlayCommand.fromJson({
        ...human
            .commandFor(human.legalActions.first, requestId: 'foreign-switch')
            .toJson(),
        'args': {'switch': 2},
      });
      expect((await h.session.submitHuman(wrong)).errorCode, 'ILLEGAL_ACTION');
      await h.human('player1', {'switch': 0});
      await h.human('player1', {'switch': 0});
      expect(h.session.observeHuman().allowedView['switches'], [
        false,
        false,
        false,
        false,
      ]);
      await h.human('player1', {'switch': 0});
      await h.human('player1', {'switch': 1});
      expect(h.session.observeHuman().allowedView['teamWon'], isFalse);
      await h.human('player2', {'switch': 2});
      await h.human('player2', {'switch': 3});
      expect(h.session.observeHuman().allowedView['teamWon'], isTrue);
    },
  );

  test(
    'same key replays durable receipt and different payload cannot reuse it',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      final view = h.session.observeHuman();
      final command = view.commandFor(
        view.legalActions.first,
        requestId: 'one-move',
      );
      final first = await h.session.submitHuman(command);
      final second = await h.session.submitHuman(command);
      expect(first.status, SurfacePlayReceiptStatus.applied);
      expect(second.status, SurfacePlayReceiptStatus.duplicate);
      expect(second.afterRevision, first.afterRevision);
      final changed = SurfacePlayCommand.fromJson({
        ...command.toJson(),
        'args': {'x': 1, 'y': 0},
      });
      expect(
        (await h.session.submitHuman(changed)).errorCode,
        'IDEMPOTENCY_CONFLICT',
      );
      expect(
        (h.session.observeHuman().allowedView['board']! as List).where(
          (v) => v != 0,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'lost commit acknowledgement resolves original receipt without a second move',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      h.store.loseAck = true;
      final receipt = await h.human('player1', {'x': 0, 'y': 0});
      expect(receipt.status, SurfacePlayReceiptStatus.applied);
      expect(
        (h.session.observeHuman().allowedView['board']! as List).where(
          (v) => v != 0,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'takeover during pending persistence blocks that seat but not the other seat',
    () async {
      final h = _Harness();
      await h.open('cooperative-switches.v1');
      addTearDown(h.close);
      final human = h.session.observeHuman();
      final grant = await h.session.grantAgentControl();
      final agent = h.session.observe(grant);
      final gate = Completer<void>();
      h.store.beforeCommit = gate;
      h.store.entered = Completer<void>();
      final submitting = h.session.submit(
        grant,
        agent.commandFor(agent.legalActions.first, requestId: 'revoked-move'),
      );
      await h.store.entered!.future;
      final takeover = h.session.takeOverSeat('player2');
      expect(h.session.grantIsCurrent(grant), isFalse);
      gate.complete();
      final result = await submitting;
      await takeover;
      h.store.beforeCommit = null;
      expect(result.errorCode, 'GRANT_REVOKED');
      expect(h.session.observeHuman().allowedView['switches'], [
        false,
        false,
        false,
        false,
      ]);
      expect(
        (await h.session.submitHuman(
          human.commandFor(
            human.legalActions.first,
            requestId: 'still-valid-human',
          ),
        )).status,
        SurfacePlayReceiptStatus.applied,
      );
    },
  );

  test(
    'restore keeps committed rules and receipts while revoking prior session grants',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      final grant = await h.session.grantAgentControl();
      final observation = h.session.observeHuman();
      final command = observation.commandFor(
        observation.legalActions.first,
        requestId: 'before-restart',
      );
      await h.session.submitHuman(command);
      final old = h.session;
      await h.reopen('session-2');
      expect(old.grantIsCurrent(grant), isFalse);
      expect(h.session.grantIsCurrent(grant), isFalse);
      expect(
        (await h.session.submitHuman(command)).status,
        SurfacePlayReceiptStatus.duplicate,
      );
      expect(h.session.observeHuman().allowedView['board'], [
        1,
        ...List.filled(24, 0),
      ]);
    },
  );

  test(
    'uncommitted storage failure publishes no move and scope retirement is fenced',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      final events = <SurfacePlayViewEvent>[];
      final sub = h.session.onHumanViewEvent.listen(events.add);
      addTearDown(sub.cancel);
      h.store.failWrite = true;
      final receipt = await h.human('player1', {'x': 0, 'y': 0});
      expect(receipt.status, SurfacePlayReceiptStatus.pending);
      expect(events, isEmpty);
      expect(h.session.observeHuman().allowedView['board'], List.filled(25, 0));
      h.store.failWrite = false;
      h.current = false;
      expect(() => h.session.observeHuman(), throwsStateError);
    },
  );

  test(
    'doc binding cannot grant control and default authorization refuses Agent',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      h.allowed = false;
      await expectLater(h.session.grantAgentControl(), throwsStateError);
      expect(h.session.observeHuman().legalActions, isNotEmpty);
      final doc = buildSurfacePlayAgentDocument(
        protocol: h.protocol,
        contentManifestId: 'content-1',
        protocolSha256: surfaceProtocolDigest(jsonEncode(h.protocol.toJson())),
      );
      expect(
        () => validateSurfacePlayAgentDocument(
          doc,
          protocol: h.protocol,
          contentManifestId: 'another-content',
          protocolSha256: surfaceProtocolDigest(
            jsonEncode(h.protocol.toJson()),
          ),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'human still sees their seat after delegation but cannot bypass its controller',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      final before = h.session.observeHuman();
      final grant = await h.session.grantAgentControl(seatId: 'player1');
      expect(h.session.observeHuman().allowedView['board'], List.filled(25, 0));
      expect(h.session.observeHuman().legalActions, isEmpty);
      final stale = before.commandFor(
        before.legalActions.first,
        requestId: 'stolen-human-control',
      );
      expect((await h.session.submitHuman(stale)).errorCode, 'GRANT_REVOKED');
      expect(h.session.observe(grant).legalActions, isNotEmpty);
      await h.session.takeOverSeat('player1');
      expect(h.session.observeHuman().legalActions, isNotEmpty);
    },
  );
  test(
    'takeover while Agent grant is persisting cannot issue a surviving grant',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      final gate = Completer<void>();
      h.store.beforeCommit = gate;
      h.store.entered = Completer<void>();
      final assigning = h.session.grantAgentControl();
      final refused = expectLater(assigning, throwsStateError);
      await h.store.entered!.future;
      final takeover = h.session.takeOverSeat('player2');
      gate.complete();
      await refused;
      await takeover;
      h.store.beforeCommit = null;
      expect((await h.store.load('match-1'))!['controllers'], {
        'player1': 'human',
        'player2': 'human',
        'spectator': 'observer',
      });
    },
  );
  test(
    'latest match index resumes committed play and new match preserves the previous game',
    () async {
      final h = _Harness();
      await h.open('gomoku.v1');
      addTearDown(h.close);
      await h.human('player1', {'x': 0, 'y': 0});
      final protocolJson = jsonEncode(h.protocol.toJson());
      final doc = buildSurfacePlayAgentDocument(
        protocol: h.protocol,
        contentManifestId: 'content-1',
        protocolSha256: surfaceProtocolDigest(protocolJson),
      );
      Future<SurfacePlaySession> open(String sessionId, {bool fresh = false}) =>
          h.service.openSession(
            protocol: h.protocol,
            sessionId: sessionId,
            newMatch: fresh,
            agentId: 'self',
            contentManifestId: 'content-1',
            protocolJson: protocolJson,
            agentDocument: doc,
            isPresentationCurrent: () => true,
          );
      final restored = await open('session-2');
      expect(restored.matchId, 'match-1');
      expect(restored.observeHuman().allowedView['board'], [
        1,
        ...List.filled(24, 0),
      ]);
      final fresh = await open('session-3', fresh: true);
      expect(fresh.matchId, isNot('match-1'));
      expect(fresh.observeHuman().allowedView['board'], List.filled(25, 0));
      expect(
        await h.store.latestMatchId(
          projectId: h.protocol.projectId,
          revisionId: h.protocol.revisionId,
        ),
        fresh.matchId,
      );
      expect((await h.store.load('match-1'))!['rulesState'], isNotNull);
    },
  );
}
