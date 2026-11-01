import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_protocol.dart';
import 'package:maaso/src/features/surface_play/domain/surface_play_frame.dart';
import 'package:maaso/src/features/surface_play/domain/trusted_realtime_rules.dart';
import 'package:maaso/src/features/surface_play/domain/trusted_turn_rules.dart';
import 'package:maaso/src/features/surface_play/application/surface_play_realtime_clock.dart';

SurfacePlayProtocol protocol() => SurfacePlayProtocol.trustedGame(
  projectId: 'pb_project_00000000-0000-0000-0000-000000000001',
  revisionId: 'pb_revision_00000000-0000-0000-0000-000000000002',
  rulesId: 'cooperative-dodge.v1',
  config: cooperativeDodgeConfig,
);
Map<String, Object?> setPolicy(
  TrustedRealtimeRules rules,
  Map<String, Object?> state,
  String seat,
  String policy,
) {
  final action = rules
      .legalActions(state, seat)
      .singleWhere((a) => playObject(a['args'])['policy'] == policy);
  return rules
      .reduce(
        state,
        seat,
        action['actionId']! as String,
        playObject(action['args']),
      )
      .state;
}

class ManualTimer implements Timer {
  ManualTimer(this.callback);
  final void Function(Timer) callback;
  bool active = true;
  int count = 0;
  void fire() {
    if (active) {
      count++;
      callback(this);
    }
  }

  @override
  bool get isActive => active;
  @override
  int get tick => count;
  @override
  void cancel() {
    active = false;
  }
}

void main() {
  test(
    'registered realtime contract is exact and legacy turn schema unchanged',
    () {
      final p = protocol();
      expect(p.isRealtime, isTrue);
      expect(SurfacePlayProtocol.fromJson(p.toJson()).toJson(), p.toJson());
      expect(
        () => SurfacePlayProtocol.trustedGame(
          projectId: p.projectId,
          revisionId: p.revisionId,
          rulesId: p.rulesId!,
          config: {...cooperativeDodgeConfig, 'tickHz': 60},
        ),
        throwsFormatException,
      );
      expect(
        () => SurfacePlayProtocol.fromJson({
          ...p.toJson(),
          'capabilities': {
            'turnBased': true,
            'realtime': false,
            'checkpoint': true,
          },
        }),
        throwsFormatException,
      );
      final old = SurfacePlayProtocol.trustedGame(
        projectId: 'p',
        revisionId: 'r',
        rulesId: 'gomoku.v1',
        config: {'boardSize': 5, 'winLength': 3},
      );
      expect(old.isRealtime, isFalse);
      expect(TrustedTurnRules(old).initial(seed: 1)['moves'], 0);
      if (Platform.environment['EXPORT_REALTIME_FIXTURE'] == '1') {
        File(
          'tool/fixtures/surface_play_realtime_protocol_v2.json',
        ).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(p.toJson())}\n',
        );
      }
    },
  );
  test(
    'RNG is never projected and role-scoped frames cannot mutate authority',
    () {
      final rules = TrustedRealtimeRules(protocol()),
          a = rules.initial(seed: 1),
          b = rules.initial(seed: 0xffffffff);
      for (final seat in surfacePlayRoles) {
        expect(rules.view(a, seat), rules.view(b, seat));
        expect(rules.legalActions(a, seat), rules.legalActions(b, seat));
        final frame = SurfacePlayFrame({
          'protocolVersion': 2,
          'projectId': 'p',
          'revisionId': 'r',
          'sessionId': 's',
          'matchId': 'm',
          'matchEpoch': 1,
          'seatId': seat,
          'frameSequence': 0,
          'simTick': 0,
          'decisionRevision': 0,
          'windowId': 'window-0',
          'phase': 'ready',
          'allowedView': rules.view(a, seat),
        });
        expect(jsonEncode(frame.toJson()), isNot(contains('rngState')));
        expect(
          jsonEncode(frame.toJson()).length,
          lessThan(SurfacePlayFrame.maximumBytes),
        );
        expect(() => frame.toJson()['simTick'] = 99, throwsUnsupportedError);
      }
    },
  );
  test(
    'human and Agent inputs share bounds, expire and clear immediately on missing authority',
    () {
      final rules = TrustedRealtimeRules(protocol());
      var state = rules
          .reduce(rules.initial(seed: 17), 'player1', 'game.start', {})
          .state;
      state = setPolicy(rules, state, 'player1', 'left');
      final input = playObject(playObject(state['inputs'])['player1']);
      expect(input['expiresAtTick'], 5);
      for (var i = 0; i < 5; i++) {
        state = rules
            .step(state, authorizedSeats: {'player1', 'player2'})
            .state;
      }
      expect(playObject((state['players']! as List).first)['x'], 125);
      expect(
        playObject(playObject(state['inputs'])['player1'])['policy'],
        'idle',
      );
      state = setPolicy(rules, state, 'player1', 'right');
      state = rules.step(state, authorizedSeats: {}).state;
      expect(playObject((state['players']! as List).first)['x'], 125);
      expect(
        playObject(playObject(state['inputs'])['player1'])['policy'],
        'idle',
      );
      final old = rules.legalActions(state, 'player2').first;
      while ((state['simTick']! as int) < 150 && state['phase'] == 'playing') {
        state = rules.step(state, authorizedSeats: {}).state;
      }
      expect(
        () => rules.reduce(
          state,
          'player2',
          old['actionId']! as String,
          playObject(old['args']),
        ),
        throwsA(isA<PlayRuleViolation>()),
      );
    },
  );
  test(
    'both role-owned goals are real and end atomically with no continuing input',
    () {
      final rules = TrustedRealtimeRules(protocol());
      final base = rules
          .reduce(rules.initial(seed: 17), 'player1', 'game.start', {})
          .state;
      final players = (base['players']! as List)
          .map((p) => {...playObject(p), 'score': 2})
          .toList();
      final state = {
        ...base,
        'players': players,
        'nextObjectId': 3,
        'objects': [
          {
            'id': 1,
            'kind': 'star',
            'ownerSeatId': 'player1',
            'x': 250,
            'y': 890,
          },
          {
            'id': 2,
            'kind': 'star',
            'ownerSeatId': 'player2',
            'x': 750,
            'y': 890,
          },
        ],
      };
      final result = rules.step(state, authorizedSeats: {'player1', 'player2'});
      expect(result.state['result'], 'won');
      expect(
        result.events.where((e) => e.type == 'item.collected'),
        hasLength(2),
      );
      expect(result.events.last.type, 'game.ended');
      expect(rules.legalActions(result.state, 'player1'), isEmpty);
      expect(
        playObject(
          result.state['inputs'],
        ).values.every((v) => playObject(v)['policy'] == 'idle'),
        isTrue,
      );
    },
  );
  test(
    'fixed seed action trace and checkpoint replay are exactly deterministic',
    () {
      final rules = TrustedRealtimeRules(protocol());
      Map<String, Object?> simulate(int seed) {
        var state = rules
            .reduce(rules.initial(seed: seed), 'player1', 'game.start', {})
            .state;
        for (var tick = 0; tick < 1800 && state['phase'] == 'playing'; tick++) {
          if ((state['simTick']! as int) % 150 == 0) {
            for (final seat in ['player1', 'player2']) {
              state = setPolicy(rules, state, seat, 'collect');
            }
          }
          state = rules
              .step(state, authorizedSeats: {'player1', 'player2'})
              .state;
          expect((state['objects']! as List).length, lessThanOrEqualTo(16));
          for (final role in surfacePlayRoles) {
            expect(
              utf8.encode(jsonEncode(rules.view(state, role))).length,
              lessThan(8192),
            );
          }
        }
        return state;
      }

      for (final seed in [1, 17, 12345, 0xffffffff]) {
        expect(simulate(seed), simulate(seed));
      }
      final end = simulate(17);
      expect(end['phase'], 'ended');
      expect(end['result'], 'won');
    },
  );
  test(
    'clock has one in-flight tick and never catches up background wall time',
    () async {
      final timers = <ManualTimer>[];
      var visible = true, calls = 0;
      final pending = Completer<void>();
      final clock = SurfacePlayRealtimeClock(
        onTick: () {
          calls++;
          return calls == 1 ? pending.future : Future.value();
        },
        canTick: () => visible,
        onError: (_, _) => fail('unexpected'),
        schedulePeriodic: (_, callback) {
          final timer = ManualTimer(callback);
          timers.add(timer);
          return timer;
        },
      );
      clock.start();
      final first = timers.single;
      first.fire();
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 900; i++) {
        first.fire();
      }
      expect(calls, 1);
      expect(clock.ticksSkipped, 900);
      visible = false;
      clock.stopNow();
      pending.complete();
      await Future<void>.delayed(Duration.zero);
      for (var i = 0; i < 1800; i++) {
        first.fire();
      }
      expect(calls, 1);
      visible = true;
      clock.start();
      timers.last.fire();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 2);
      await clock.close();
      expect(timers.every((t) => !t.isActive), isTrue);
    },
  );
}
