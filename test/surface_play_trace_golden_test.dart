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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Dart trusted sessions match cross-runtime golden views and receipts',
    () async {
      final cases = <Map<String, Object?>>[];
      for (final rules in [
        'gomoku.v1',
        'cooperative-switches.v1',
        'private-cards.v1',
      ]) {
        final config = switch (rules) {
          'gomoku.v1' => {'boardSize': 5, 'winLength': 3},
          'cooperative-switches.v1' => {'switchesPerRole': 2, 'goalMask': 15},
          _ => {'cardsPerRole': 3},
        };
        final protocol = SurfacePlayProtocol.trustedGame(
          projectId: 'trace-project',
          revisionId: 'trace-revision',
          rulesId: rules,
          config: config,
        );
        final db = await DBService().init(
          factory: databaseFactoryMemory,
          path: 'trace-$rules',
        );
        final store = SurfacePlayStore(
          database: db,
          scopeKey: 'trace|owner',
          isCurrent: () => true,
        );
        var nonce = 0;
        final service = SurfacePlayService(
          scopeKey: 'trace|owner',
          persistence: store,
          isCurrent: () => true,
          authorizeAgentControl: (_, _) async => true,
          now: () => DateTime.utc(2026, 9, 28),
          nonce: () => 'trace-${nonce++}',
          seed: () => 17,
        );
        final protocolJson = jsonEncode(protocol.toJson());
        final session = await service.openSession(
          protocol: protocol,
          sessionId: 'trace-session',
          matchId: 'trace-match',
          agentId: 'self',
          contentManifestId: 'trace-content',
          protocolJson: protocolJson,
          agentDocument: buildSurfacePlayAgentDocument(
            protocol: protocol,
            contentManifestId: 'trace-content',
            protocolSha256: surfaceProtocolDigest(protocolJson),
          ),
          isPresentationCurrent: () => true,
        );
        final spectator = await session.grantAgentControl(seatId: 'spectator');
        Map<String, Object?> views() => {
          for (final role in surfacePlayRoles)
            role: _visible(
              role == 'spectator'
                  ? session.observe(spectator)
                  : session.observeHuman(seatId: role),
            ),
        };
        final initial = views();
        final actions = switch (rules) {
          'gomoku.v1' => [
            {
              'seatId': 'player1',
              'args': {'x': 0, 'y': 0},
            },
            {'seatId': 'player1', 'repeatOf': 'move-1'},
            {
              'seatId': 'player2',
              'args': {'x': 0, 'y': 1},
            },
            {
              'seatId': 'player1',
              'args': {'x': 1, 'y': 0},
            },
            {
              'seatId': 'player2',
              'args': {'x': 1, 'y': 1},
            },
            {
              'seatId': 'player1',
              'args': {'x': 2, 'y': 0},
            },
          ],
          'cooperative-switches.v1' => [
            {
              'seatId': 'player1',
              'args': {'switch': 0},
            },
            {
              'seatId': 'player1',
              'args': {'switch': 0},
            },
            {
              'seatId': 'player2',
              'args': {'switch': 2},
            },
            {
              'seatId': 'player1',
              'args': {'switch': 0},
            },
            {
              'seatId': 'player1',
              'args': {'switch': 1},
            },
            {
              'seatId': 'player2',
              'args': {'switch': 3},
            },
          ],
          _ => [
            {
              'seatId': 'player1',
              'args': {'card': 0},
            },
            {
              'seatId': 'player2',
              'args': {'card': 1},
            },
          ],
        };
        final steps = <Map<String, Object?>>[],
            commands = <String, SurfacePlayCommand>{};
        for (var index = 0; index < actions.length; index++) {
          final action = actions[index], seat = action['seatId']! as String;
          final repeat = action['repeatOf'] as String?;
          late SurfacePlayCommand command;
          if (repeat != null) {
            command = commands[repeat]!;
          } else {
            final view = session.observeHuman(seatId: seat);
            final candidate = view.legalActions.firstWhere(
              (a) =>
                  playCanonicalJson(a['args']) ==
                  playCanonicalJson(action['args']),
            );
            command = view.commandFor(
              candidate,
              requestId: 'move-${index + 1}',
            );
            commands[command.requestId] = command;
          }
          final receipt = await session.submitHuman(command, seatId: seat);
          final record = (await store.load('trace-match'))!;
          steps.add({
            'input': {
              ...action,
              'requestId': command.requestId,
              'actionId': command.actionId,
            },
            'receipt': {...receipt.toJson()}..remove('commandHash'),
            'views': views(),
            'events': {
              for (final role in surfacePlayRoles)
                role: [
                  for (final raw
                      in playObject(record['viewEvents'])[role]! as List)
                    {...playObject(raw)}..remove('eventId'),
                ],
            },
          });
        }
        cases.add({
          'rulesId': rules,
          'rulesConfig': config,
          'seed': 17,
          'initial': initial,
          'steps': steps,
        });
        await service.deactivateAndDrain();
        await db.close();
      }
      final actual = {
        'schemaVersion': 1,
        'scope':
            'trusted host rules and durable receipt conformance; not model behavior or visual QA',
        'cases': cases,
      };
      final file = File('tool/fixtures/surface_play_trace_v2.json');
      if (const bool.fromEnvironment('WRITE_SURFACE_PLAY_GOLDEN')) {
        await file.writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(actual)}\n',
        );
      }
      expect(actual, jsonDecode(file.readAsStringSync()));
    },
  );
}

Map<String, Object?> _visible(SurfacePlayObservation value) => {
  'seatId': value.seatId,
  'phase': value.toJson()['phase'],
  'turnId': value.turnId,
  'viewRevision': value.toJson()['viewRevision'],
  'decisionRevision': value.decisionRevision,
  'viewSequence': value.toJson()['viewSequence'],
  'allowedView': value.allowedView,
  'legalActions': [
    for (final action in value.legalActions)
      {'actionId': action['actionId'], 'args': action['args']},
  ],
};
