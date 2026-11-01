import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_service.dart';
import 'package:maaso/src/features/surface_play/data/surface_play_store.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_agent_document.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_messages.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:sembast/sembast_memory.dart';

class TraceTimer implements Timer {
  TraceTimer(this.callback);
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

Map<String, Object?> visible(SurfacePlayObservation value) => {
  'seatId': value.seatId,
  'phase': value.toJson()['phase'],
  'turnId': value.turnId,
  'viewRevision': value.toJson()['viewRevision'],
  'decisionRevision': value.decisionRevision,
  'viewSequence': value.toJson()['viewSequence'],
  'allowedView': value.allowedView,
  'legalActions': [
    for (final a in value.legalActions)
      {'actionId': a['actionId'], 'args': a['args']},
  ],
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'full fixed-seed realtime match has deterministic views, receipts and checkpoint trace',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'realtime-trace',
      );
      final store = SurfacePlayStore(
        database: db,
        scopeKey: 'trace|owner',
        isCurrent: () => true,
      );
      TraceTimer? timer;
      var nonce = 0;
      final service = SurfacePlayService(
        scopeKey: 'trace|owner',
        persistence: store,
        isCurrent: () => true,
        authorizeAgentControl: (_, _) async => true,
        now: () => DateTime.utc(2026, 10, 1),
        nonce: () => 'trace-${nonce++}',
        seed: () => 17,
        scheduleSimulationTick: (_, callback) => timer = TraceTimer(callback),
      );
      addTearDown(() async {
        await service.deactivateAndDrain();
        await db.close();
      });
      final protocol = SurfacePlayProtocol.trustedGame(
            projectId: 'trace-project',
            revisionId: 'trace-revision',
            rulesId: 'cooperative-dodge.v1',
            config: cooperativeDodgeConfig,
          ),
          raw = jsonEncode(
            SurfacePlayProtocol.trustedGame(
              projectId: 'trace-project',
              revisionId: 'trace-revision',
              rulesId: 'cooperative-dodge.v1',
              config: cooperativeDodgeConfig,
            ).toJson(),
          );
      final session = await service.openSession(
        protocol: protocol,
        sessionId: 'trace-session',
        matchId: 'trace-match',
        agentId: 'self',
        contentManifestId: 'trace-content',
        protocolJson: raw,
        agentDocument: buildSurfacePlayAgentDocument(
          protocol: protocol,
          contentManifestId: 'trace-content',
          protocolSha256: surfaceProtocolDigest(raw),
        ),
        isPresentationCurrent: () => true,
      );
      final spectator = await session.grantAgentControl(seatId: 'spectator');
      Map<String, Object?> views() => {
        for (final seat in surfacePlayRoles)
          seat: visible(
            seat == 'spectator'
                ? session.observe(spectator)
                : session.observeHuman(seatId: seat),
          ),
      };
      final initial = views(), steps = <Map<String, Object?>>[];
      final cursors = {for (final role in surfacePlayRoles) role: 0};
      Future<void> capture(
        Map<String, Object?> input,
        SurfacePlayReceipt? receipt,
      ) async {
        final saved = (await store.load('trace-match'))!;
        final events = <String, Object?>{};
        for (final seat in surfacePlayRoles) {
          final view = seat == 'spectator'
              ? session.observe(spectator)
              : session.observeHuman(seatId: seat);
          final list = (playObject(saved['viewEvents'])[seat] as List)
              .map((e) => playObject(e))
              .where((e) => (e['viewSequence'] as int) > cursors[seat]!)
              .map((e) => {...e}..remove('eventId'))
              .toList();
          events[seat] = list;
          cursors[seat] = view.toJson()['viewSequence'] as int;
        }
        steps.add({
          'input': input,
          if (receipt != null)
            'receipt': {...receipt.toJson()}..remove('commandHash'),
          'views': views(),
          'events': events,
          'checkpoint': {
            'simTick': playObject(saved['rulesState'])['simTick'],
            'commitRevision': saved['commitRevision'],
            'rulesSha256': sha256
                .convert(utf8.encode(playCanonicalJson(saved['rulesState'])))
                .toString(),
          },
        });
      }

      Future<void> command(String seat, String? policy) async {
        final view = session.observeHuman(seatId: seat),
            action = view.legalActions.firstWhere(
              (a) => policy == null
                  ? a['actionId'] == 'game.start'
                  : playObject(a['args'])['policy'] == policy,
            );
        final command = view.commandFor(
          action,
          requestId: 'request-${steps.length}',
        );
        final receipt = await session.submitHuman(command, seatId: seat);
        expect(receipt.status, SurfacePlayReceiptStatus.applied);
        await capture({
          'seatId': seat,
          'actionId': action['actionId'],
          'args': action['args'],
          'requestId': command.requestId,
        }, receipt);
      }

      await command('player1', null);
      while (session.currentFrameHuman()!.phase == 'playing') {
        await command('player1', 'collect');
        await command('player2', 'collect');
        var actual = 0;
        for (
          var i = 0;
          i < 150 && session.currentFrameHuman()!.phase == 'playing';
          i++
        ) {
          final before = session.currentFrameHuman()!.simTick;
          timer!.fire();
          for (
            var n = 0;
            n < 100 && session.currentFrameHuman()!.simTick == before;
            n++
          ) {
            await Future<void>.delayed(Duration.zero);
          }
          expect(session.currentFrameHuman()!.simTick, before + 1);
          actual++;
        }
        await capture({'advanceTicks': 150, 'actualTicks': actual}, null);
      }
      final finalFrame = session.currentFrameHuman()!;
      expect(finalFrame.allowedView['teamWon'], isTrue);
      final saved = (await store.load('trace-match'))!;
      expect(saved['commitRevision'] as int, lessThan(256));
      for (final role in surfacePlayRoles) {
        expect(
          (playObject(saved['viewEvents'])[role] as List).length,
          lessThanOrEqualTo(1024),
        );
      }
      final result = {
        'schemaVersion': 1,
        'scope':
            'Actual Dart trusted rules + Sembast checkpoint/receipt conformance. Fixed local test policies, not model or browser acceptance. Checkpoint hash is test evidence only, never a player observation.',
        'rulesId': 'cooperative-dodge.v1',
        'rulesConfig': cooperativeDodgeConfig,
        'seed': 17,
        'initial': initial,
        'steps': steps,
      };
      final file = File('tool/fixtures/surface_play_realtime_trace_v2.json');
      if (Platform.environment['EXPORT_REALTIME_TRACE'] == '1') {
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(result)}\n',
        );
      }
      expect(result, jsonDecode(await file.readAsString()));
    },
  );
}
