import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_companion_call_ledger.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:sembast/sembast_memory.dart';

class TickTimer implements Timer {
  TickTimer(this.callback);
  final void Function(Timer) callback;
  bool active = true;
  int count = 0;
  @override
  bool get isActive => active;
  @override
  int get tick => count;
  @override
  void cancel() => active = false;
  void fire() {
    if (active) {
      count++;
      callback(this);
    }
  }
}

class ControlledPersistence implements SurfacePlayPersistence {
  ControlledPersistence(this.inner);
  final SurfacePlayPersistence inner;
  int writes = 0;
  bool fail = false, loseAck = false;
  Duration commitDelay = Duration.zero;
  Completer<void>? entered, release;
  bool holdAfter = false;
  @override
  Future<String?> latestMatchId({
    required String projectId,
    required String revisionId,
  }) => inner.latestMatchId(projectId: projectId, revisionId: revisionId);
  @override
  Future<Map<String, Object?>?> load(String id) => inner.load(id);
  @override
  Future<void> commit({
    required String matchId,
    required int? expectedCommitRevision,
    required Map<String, Object?> next,
    required bool Function() isAuthorized,
  }) async {
    if (!holdAfter && release != null) {
      entered!.complete();
      await release!.future;
      release = null;
    }
    if (fail) throw StateError('injected_disk_failure');
    if (commitDelay != Duration.zero) await Future<void>.delayed(commitDelay);
    await inner.commit(
      matchId: matchId,
      expectedCommitRevision: expectedCommitRevision,
      next: next,
      isAuthorized: isAuthorized,
    );
    writes++;
    if (holdAfter && release != null) {
      entered!.complete();
      await release!.future;
      release = null;
    }
    if (loseAck) {
      loseAck = false;
      throw StateError('injected_lost_ack');
    }
  }

  void hold({bool after = false}) {
    holdAfter = after;
    entered = Completer<void>();
    release = Completer<void>();
  }
}

class Harness {
  late DBService db;
  late ControlledPersistence store;
  late SurfacePlayService service;
  late SurfacePlaySession session;
  TickTimer? timer;
  int nonce = 0;
  bool current = true;
  DateTime now = DateTime.utc(2026, 10, 1);
  final protocol = SurfacePlayProtocol.trustedGame(
    projectId: 'project',
    revisionId: 'revision',
    rulesId: 'cooperative-dodge.v1',
    config: cooperativeDodgeConfig,
  );
  Future<void> open() async {
    db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'realtime-${DateTime.now().microsecondsSinceEpoch}',
    );
    store = ControlledPersistence(
      SurfacePlayStore(
        database: db,
        scopeKey: 'scope',
        isCurrent: () => current,
      ),
    );
    service = SurfacePlayService(
      scopeKey: 'scope',
      persistence: store,
      companionCalls: SurfaceCompanionCallLedger(
        database: db,
        scopeKey: 'scope',
        isCurrent: () => current,
        now: () => now,
      ),
      isCurrent: () => current,
      authorizeAgentControl: (_, _) async => true,
      now: () => now,
      seed: () => 17,
      nonce: () => 'nonce-${nonce++}',
      scheduleSimulationTick: (_, callback) => timer = TickTimer(callback),
    );
    await reopen('session');
  }

  Future<void> reopen(String id) async {
    final raw = jsonEncode(protocol.toJson());
    session = await service.openSession(
      protocol: protocol,
      sessionId: id,
      matchId: 'match',
      agentId: 'self',
      contentManifestId: 'content',
      protocolJson: raw,
      agentDocument: buildSurfacePlayAgentDocument(
        protocol: protocol,
        contentManifestId: 'content',
        protocolSha256: surfaceProtocolDigest(raw),
      ),
      isPresentationCurrent: () => current,
    );
  }

  Future<SurfacePlayReceipt> human(String? policy) async {
    final view = session.observeHuman();
    final action = view.legalActions.firstWhere(
      (a) => policy == null
          ? a['actionId'] == 'game.start'
          : playObject(a['args'])['policy'] == policy,
    );
    return session.submitHuman(
      view.commandFor(action, requestId: 'human-${nonce++}'),
    );
  }

  Future<void> tick([int count = 1]) async {
    for (var i = 0; i < count; i++) {
      final before = tickNow;
      final shouldAdvance =
          timer!.isActive &&
          !session.isPaused &&
          session.currentFrameHuman()!.phase == 'playing';
      timer!.fire();
      if (shouldAdvance) {
        await until(
          () => tickNow > before || !timer!.isActive || session.isPaused,
          reason:
              'A logical step must finish before the next manual timer callback',
        );
        if (!session.isPaused) expect(tickNow, before + 1);
      }
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> until(bool Function() condition, {String? reason}) async {
    for (var i = 0; i < 100 && !condition(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    expect(
      condition(),
      isTrue,
      reason:
          reason ??
          'tick=$tickNow phase=${session.currentFrameHuman()!.phase} timerActive=${timer?.isActive}',
    );
  }

  int get tickNow => session.currentFrameHuman()!.simTick;
  Future<Map<String, Object?>> saved() async => (await store.load('match'))!;
  Future<void> close() async {
    await service.deactivateAndDrain();
    await db.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'readonly frames do not manufacture reliable events or per-frame writes',
    () async {
      final h = Harness();
      await h.open();
      addTearDown(h.close);
      await h.human(null);
      final before = await h.saved(), writes = h.store.writes;
      final initial = h.session.observeHuman();
      final frames = <Map<String, Object?>>[];
      final sub = h.session
          .framesForHumanSeat('player1')
          .listen((f) => frames.add(f.toJson()));
      addTearDown(sub.cancel);
      await h.tick(29);
      expect(h.tickNow, 29);
      expect(h.store.writes, writes);
      expect(
        h.session.observeHuman().toJson()['viewSequence'],
        initial.toJson()['viewSequence'],
      );
      await h.tick();
      await h.until(() => h.tickNow == 30);
      expect(h.store.writes, writes + 1);
      expect(frames.length, 30);
      expect(
        frames.every(
          (f) =>
              !f.containsKey('legalActions') &&
              !jsonEncode(f).contains('rngState'),
        ),
        isTrue,
      );
      expect((await h.saved())['viewSequences'], before['viewSequences']);
    },
  );
  test(
    'input expiration and old-window actions are decided by host ticks',
    () async {
      final h = Harness();
      await h.open();
      addTearDown(h.close);
      await h.human(null);
      await h.human('right');
      final old = h.session.observeHuman();
      final candidate = old.legalActions.firstWhere(
        (a) => playObject(a['args'])['policy'] == 'collect',
      );
      final command = old.commandFor(candidate, requestId: 'expired-window');
      await h.tick(6);
      expect(
        playObject(
          (h.session.currentFrameHuman()!.allowedView['players'] as List).first,
        )['x'],
        375,
      );
      expect(
        playObject(
          h.session.currentFrameHuman()!.allowedView['ownInput'],
        )['policy'],
        'idle',
      );
      await h.tick(144);
      expect(h.tickNow, 150);
      final receipt = await h.session.submitHuman(command);
      expect(receipt.status, SurfacePlayReceiptStatus.rejected);
    },
  );
  test(
    'receipt query cannot rewind newer live frames; restart is paused at durable checkpoint',
    () async {
      final h = Harness();
      await h.open();
      addTearDown(h.close);
      final start = await h.human(null);
      await h.human('collect');
      await h.tick(65);
      final live = h.tickNow;
      expect(live, 65);
      final savedTick =
          playObject((await h.saved())['rulesState'])['simTick'] as int;
      expect(live - savedTick, inInclusiveRange(0, 29));
      expect(await h.session.receiptHuman(start.requestId), isNotNull);
      expect(h.tickNow, live);
      await h.reopen('new-session');
      expect(h.tickNow, savedTick);
      expect(h.session.isPaused, isTrue);
      expect(
        playObject(
          h.session.currentFrameHuman()!.allowedView['ownInput'],
        )['policy'],
        'idle',
      );
      final old = h.timer;
      h.now = h.now.add(const Duration(hours: 2));
      for (var i = 0; i < 100; i++) {
        old?.fire();
      }
      await Future<void>.delayed(Duration.zero);
      expect(h.tickNow, savedTick);
      await h.session.resume();
      await h.tick();
      expect(h.tickNow, savedTick + 1);
    },
  );
  test(
    'precommit takeover drops old checkpoint without pausing the other player',
    () async {
      final h = Harness();
      await h.open();
      addTearDown(h.close);
      await h.human(null);
      await h.tick(29);
      final grant = await h.session.grantAgentControl();
      await h.tick(29);
      h.store.hold();
      h.timer!.fire();
      await h.store.entered!.future;
      final takeover = h.session.takeOverSeat('player2');
      h.store.release!.complete();
      await takeover;
      expect(h.session.grantIsCurrent(grant), isFalse);
      expect(h.session.isPaused, isFalse);
      expect(h.session.pauseReason, '');
      await h.tick();
      expect(h.tickNow, greaterThanOrEqualTo(58));
    },
  );
  test(
    'failed checkpoint stops ticks until explicit storage recovery and resume',
    () async {
      final h = Harness();
      await h.open();
      addTearDown(h.close);
      await h.human(null);
      await h.tick(29);
      h.store.fail = true;
      h.timer!.fire();
      await h.until(() => h.session.isPaused);
      final before = h.tickNow;
      await h.tick(100);
      expect(h.tickNow, before);
      expect(h.session.pauseReason, 'checkpoint_unconfirmed');
      h.store.fail = false;
      await h.session.resume();
      expect(h.session.isPaused, isFalse);
      await h.tick();
      expect(h.tickNow, before + 1);
    },
  );
  for (final operation in ['pause', 'takeover']) {
    test(
      '$operation after committed checkpoint lost ACK preserves CAS and revocation',
      () async {
        final h = Harness();
        await h.open();
        addTearDown(h.close);
        await h.human(null);
        await h.tick(29);
        h.store.hold(after: true);
        h.store.loseAck = true;
        h.timer!.fire();
        await h.store.entered!.future;
        final revoke = operation == 'pause'
            ? h.session.pause()
            : h.session.takeOverSeat('player2');
        final epoch = h.session.currentFrameHuman()!.matchEpoch;
        h.store.release!.complete();
        await revoke;
        expect(h.tickNow, 30);
        expect(h.session.currentFrameHuman()!.matchEpoch, epoch);
        if (operation == 'pause') {
          expect(h.session.currentFrameHuman()!.phase, 'paused');
          await h.session.resume();
        } else {
          expect(h.session.isPaused, isFalse);
        }
        await h.tick();
        expect(h.tickNow, 31);
      },
    );
  }
}
