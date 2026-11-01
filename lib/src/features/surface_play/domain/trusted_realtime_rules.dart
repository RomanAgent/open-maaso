import 'surface_play_protocol.dart';
import 'trusted_turn_rules.dart';

/// One registered integer-only cooperative simulation. No wall clock, async
/// work, environment randomness, storage or authored JavaScript runs here.
final class TrustedRealtimeRules implements TrustedPlayRules {
  TrustedRealtimeRules(this.protocol) {
    if (protocol.rulesId != 'cooperative-dodge.v1' || !protocol.isRealtime) {
      throw const FormatException('unregistered_realtime_rules');
    }
  }
  final SurfacePlayProtocol protocol;
  static const seats = ['player1', 'player2'];
  static const policies = ['left', 'right', 'idle', 'collect', 'dodge'];
  static const maximumObjects = 16;
  static const roundTicks = 1800, windowTicks = 150, checkpointTicks = 30;
  String windowId(Map<String, Object?> state) =>
      'window-${(state['simTick']! as int) ~/ windowTicks}';
  int windowEnd(Map<String, Object?> state) =>
      (((state['simTick']! as int) ~/ windowTicks + 1) * windowTicks).clamp(
        0,
        roundTicks,
      );
  Map<String, Object?> _freeze(Map<String, Object?> value) =>
      playObject(playSnapshot(value, maximumBytes: 16384));
  Map<String, Object?> _input(int tick) => {
    'policy': 'idle',
    'expiresAtTick': tick,
    'windowId': 'window-${tick ~/ windowTicks}',
  };
  @override
  Map<String, Object?> initial({required int seed}) {
    playInteger(seed, min: 1, max: 0xffffffff);
    return _freeze({
      'stateSchema': 1,
      'simTick': 0,
      'rngState': seed,
      'phase': 'ready',
      'result': '',
      'endReason': '',
      'teamLives': 6,
      'nextObjectId': 1,
      'players': [
        for (var i = 0; i < 2; i++)
          {
            'seatId': seats[i],
            'x': i == 0 ? 250 : 750,
            'y': 900,
            'score': 0,
            'invulnerableTicks': 0,
          },
      ],
      'objects': <Object?>[],
      'inputs': {for (final seat in seats) seat: _input(0)},
    });
  }

  @override
  void validateState(Map<String, Object?> state) {
    playKeys(state, {
      'stateSchema',
      'simTick',
      'rngState',
      'phase',
      'result',
      'endReason',
      'teamLives',
      'nextObjectId',
      'players',
      'objects',
      'inputs',
    });
    if (state['stateSchema'] != 1 ||
        !const {'ready', 'playing', 'ended'}.contains(state['phase'])) {
      throw const FormatException('invalid_realtime_state');
    }
    final tick = playInteger(state['simTick'], max: roundTicks);
    playInteger(state['rngState'], min: 1, max: 0xffffffff);
    playInteger(state['teamLives'], max: 6);
    final nextId = playInteger(state['nextObjectId'], min: 1, max: 121);
    if (state['phase'] == 'ready' && tick != 0 ||
        state['phase'] == 'ended' &&
            (!const {'won', 'lost'}.contains(state['result']) ||
                !const {
                  'goal',
                  'lives',
                  'time',
                }.contains(state['endReason'])) ||
        state['phase'] != 'ended' &&
            (state['result'] != '' || state['endReason'] != '')) {
      throw const FormatException('invalid_realtime_phase');
    }
    final players = state['players'], objects = state['objects'];
    if (players is! List ||
        players.length != 2 ||
        objects is! List ||
        objects.length > maximumObjects) {
      throw const FormatException('invalid_realtime_entities');
    }
    for (var i = 0; i < 2; i++) {
      final p = playObject(players[i]);
      playKeys(p, {'seatId', 'x', 'y', 'score', 'invulnerableTicks'});
      if (p['seatId'] != seats[i] || p['y'] != 900) {
        throw const FormatException('invalid_realtime_player');
      }
      playInteger(p['x'], min: 80, max: 920);
      playInteger(p['score'], max: 30);
      playInteger(p['invulnerableTicks'], max: 30);
    }
    final ids = <int>{};
    for (final value in objects) {
      final o = playObject(value);
      playKeys(o, {'id', 'kind', 'ownerSeatId', 'x', 'y'});
      final id = playInteger(o['id'], min: 1, max: nextId - 1);
      if (!ids.add(id) ||
          !const {'hazard', 'star'}.contains(o['kind']) ||
          (o['kind'] == 'hazard'
              ? o['ownerSeatId'] != null
              : !seats.contains(o['ownerSeatId']))) {
        throw const FormatException('invalid_realtime_object');
      }
      playInteger(o['x'], min: 0, max: 1000);
      playInteger(o['y'], min: -30, max: 1000);
    }
    final inputs = playObject(state['inputs']);
    playKeys(inputs, seats.toSet());
    for (final seat in seats) {
      final input = playObject(inputs[seat]);
      playKeys(input, {'policy', 'expiresAtTick', 'windowId'});
      if (!policies.contains(input['policy']) ||
          input['windowId'] != windowId(state)) {
        throw const FormatException('invalid_realtime_input');
      }
      final until = playInteger(input['expiresAtTick'], max: roundTicks);
      if (input['policy'] != 'idle' &&
          (until <= tick ||
              until > windowEnd(state) ||
              state['phase'] != 'playing')) {
        throw const FormatException('invalid_realtime_input_expiry');
      }
    }
  }

  @override
  Map<String, Object?> view(Map<String, Object?> state, String seatId) {
    if (!surfacePlayRoles.contains(seatId)) {
      throw const PlayRuleViolation('INVALID_SEAT');
    }
    validateState(state);
    return _freeze({
      'arena': {'width': 1000, 'height': 1000},
      'tickHz': 30,
      'simTick': state['simTick'],
      'remainingTicks': roundTicks - (state['simTick']! as int),
      'phase': state['phase'],
      'turnId': windowId(state),
      'windowEndTick': windowEnd(state),
      'targetPerRole': 3,
      'teamLives': state['teamLives'],
      'teamWon': state['result'] == 'won',
      'endReason': state['endReason'],
      'players': state['players'],
      'objects': state['objects'],
      'ownInput': seatId == 'spectator'
          ? null
          : playObject(state['inputs'])[seatId],
    });
  }

  @override
  List<Map<String, Object?>> legalActions(
    Map<String, Object?> state,
    String seatId,
  ) {
    if (!surfacePlayRoles.contains(seatId)) {
      throw const PlayRuleViolation('INVALID_SEAT');
    }
    validateState(state);
    if (seatId == 'spectator' || state['phase'] == 'ended') return const [];
    if (state['phase'] == 'ready') {
      return seatId == 'player1'
          ? [
              {'actionId': 'game.start', 'args': <String, Object?>{}},
            ]
          : const [];
    }
    return List.unmodifiable([
      for (final policy in policies)
        _freeze({
          'actionId': 'game.input',
          'args': {
            'policy': policy,
            'windowId': windowId(state),
            'validThroughTick': windowEnd(state),
            'durationTicks': policy == 'idle'
                ? 1
                : const {'left', 'right'}.contains(policy)
                ? 5
                : 150,
          },
        }),
    ]);
  }

  @override
  PlayRuleTransition reduce(
    Map<String, Object?> previous,
    String seatId,
    String action,
    Map<String, Object?> args,
  ) {
    validateState(previous);
    if (!seats.contains(seatId) ||
        !protocol.allowsAction(seatId, action, args)) {
      throw const PlayRuleViolation('ILLEGAL_ACTION');
    }
    final state = Map<String, Object?>.from(previous);
    if (action == 'game.start') {
      if (seatId != 'player1' || state['phase'] != 'ready') {
        throw const PlayRuleViolation('ILLEGAL_ACTION');
      }
      state['phase'] = 'playing';
      return PlayRuleTransition(state, [
        PlayRuleEvent('game.started', surfacePlayRoles, {
          'windowId': windowId(state),
        }),
      ]);
    }
    if (state['phase'] != 'playing') {
      throw const PlayRuleViolation('MATCH_NOT_ACTIVE');
    }
    final tick = state['simTick']! as int,
        until = args['validThroughTick']! as int;
    if (args['windowId'] != windowId(state) ||
        until != windowEnd(state) ||
        tick >= until) {
      throw const PlayRuleViolation('WINDOW_EXPIRED');
    }
    final expires = (tick + (args['durationTicks']! as int)).clamp(0, until);
    final inputs = playObject(previous['inputs']);
    inputs[seatId] = {
      'policy': args['policy'],
      'expiresAtTick': expires,
      'windowId': windowId(state),
    };
    state['inputs'] = inputs;
    return PlayRuleTransition(state, [
      PlayRuleEvent(
        'input.accepted',
        [seatId],
        {
          'policy': args['policy'],
          'appliedAtTick': tick,
          'expiresAtTick': expires,
        },
      ),
    ]);
  }

  Map<String, Object?> clearInputs(
    Map<String, Object?> previous, {
    Set<String>? onlySeats,
  }) {
    final state = Map<String, Object?>.from(previous),
        inputs = playObject(previous['inputs']);
    for (final seat in onlySeats ?? seats.toSet()) {
      inputs[seat] = _input(previous['simTick']! as int);
    }
    state['inputs'] = inputs;
    return _freeze(state);
  }

  /// Exactly one logical tick. The host passes only seats whose current grant
  /// and control epoch still authorize their previously committed input.
  PlayRuleTransition step(
    Map<String, Object?> previous, {
    required Set<String> authorizedSeats,
  }) {
    validateState(previous);
    if (previous['phase'] != 'playing') {
      return PlayRuleTransition(previous, const []);
    }
    final state = Map<String, Object?>.from(previous),
        inputs = playObject(previous['inputs']);
    final oldTick = previous['simTick']! as int, tick = oldTick + 1;
    final players = (previous['players']! as List).map(playObject).toList();
    final objects = (previous['objects']! as List).map(playObject).toList();
    final facts = <PlayRuleEvent>[];
    for (final p in players) {
      final seat = p['seatId']! as String, input = playObject(inputs[seat]);
      if (!authorizedSeats.contains(seat) ||
          oldTick >= (input['expiresAtTick']! as int)) {
        inputs[seat] = _input(oldTick);
      }
      final policy = playObject(inputs[seat])['policy'];
      var dx = 0;
      if (policy == 'left') dx = -25;
      if (policy == 'right') dx = 25;
      if (policy == 'collect' || policy == 'dodge') {
        final x = p['x']! as int,
            target = _target(p, objects, collect: policy == 'collect');
        dx = (target - x).clamp(-25, 25);
      }
      p['x'] = ((p['x']! as int) + dx).clamp(80, 920);
      p['invulnerableTicks'] = ((p['invulnerableTicks']! as int) - 1).clamp(
        0,
        30,
      );
    }
    final retained = <Map<String, Object?>>[];
    var lives = previous['teamLives']! as int;
    for (final object in objects) {
      object['y'] =
          (object['y']! as int) + (object['kind'] == 'hazard' ? 18 : 12);
      if ((object['y']! as int) > 1000) continue;
      var consumed = false;
      for (final player in players) {
        final dx = (object['x']! as int) - (player['x']! as int),
            dy = (object['y']! as int) - 900;
        if (dx * dx + dy * dy > 55 * 55) continue;
        final seat = player['seatId']! as String;
        if (object['kind'] == 'star' && object['ownerSeatId'] == seat) {
          player['score'] = (player['score']! as int) + 1;
          consumed = true;
          facts.add(
            PlayRuleEvent('item.collected', surfacePlayRoles, {
              'seatId': seat,
              'score': player['score'],
            }),
          );
          break;
        }
        if (object['kind'] == 'hazard') {
          consumed = true;
          if (player['invulnerableTicks'] == 0) {
            lives = (lives - 1).clamp(0, 6);
            player['invulnerableTicks'] = 30;
            facts.add(
              PlayRuleEvent('player.hit', surfacePlayRoles, {
                'seatId': seat,
                'teamLives': lives,
              }),
            );
          }
          break;
        }
      }
      if (!consumed) retained.add(object);
    }
    var rng = previous['rngState']! as int,
        nextId = previous['nextObjectId']! as int;
    int randomLane() {
      rng ^= (rng << 13) & 0xffffffff;
      rng ^= rng >>> 17;
      rng ^= (rng << 5) & 0xffffffff;
      rng &= 0xffffffff;
      return rng % 7;
    }

    void spawn(String kind, String? owner) {
      final x = (randomLane() + 1) * 125;
      if (retained.length < maximumObjects) {
        retained.add({
          'id': nextId++,
          'kind': kind,
          'ownerSeatId': owner,
          'x': x,
          'y': -30,
        });
      }
    }

    if (tick % 20 == 0) spawn('hazard', null);
    if (tick % 60 == 0) spawn('star', seats[(tick ~/ 60 - 1) % 2]);
    state.addAll({
      'simTick': tick,
      'rngState': rng,
      'nextObjectId': nextId,
      'players': players,
      'objects': retained,
      'teamLives': lives.clamp(0, 6),
    });
    for (final seat in seats) {
      final input = playObject(inputs[seat]);
      if (tick >= (input['expiresAtTick']! as int) || tick % windowTicks == 0) {
        inputs[seat] = _input(tick);
      }
    }
    state['inputs'] = inputs;
    if (lives <= 0 ||
        players.every((p) => (p['score']! as int) >= 3) ||
        tick >= roundTicks) {
      final won = lives > 0 && players.every((p) => (p['score']! as int) >= 3);
      state.addAll({
        'phase': 'ended',
        'result': won ? 'won' : 'lost',
        'endReason': lives <= 0
            ? 'lives'
            : won
            ? 'goal'
            : 'time',
      });
      for (final seat in seats) {
        inputs[seat] = _input(tick);
      }
      facts.add(
        PlayRuleEvent('game.ended', surfacePlayRoles, {
          'teamWon': won,
          'reason': state['endReason'],
          'scores': {
            for (final p in players) p['seatId']! as String: p['score'],
          },
        }),
      );
    } else if (tick % windowTicks == 0) {
      facts.add(
        PlayRuleEvent('decision.window_opened', surfacePlayRoles, {
          'windowId': windowId(state),
          'validThroughTick': windowEnd(state),
        }),
      );
    }
    validateState(state);
    return PlayRuleTransition(state, facts);
  }

  int _target(
    Map<String, Object?> player,
    List<Map<String, Object?>> objects, {
    required bool collect,
  }) {
    final x = player['x']! as int;
    final stars =
        objects
            .where(
              (o) =>
                  o['kind'] == 'star' &&
                  o['ownerSeatId'] == player['seatId'] &&
                  (o['y']! as int) < 945,
            )
            .toList()
          ..sort((a, b) => (b['y']! as int).compareTo(a['y']! as int));
    final desired = collect && stars.isNotEmpty ? stars.first['x']! as int : x;
    final dangers = objects
        .where(
          (o) =>
              o['kind'] == 'hazard' &&
              (o['y']! as int) > 665 &&
              (o['y']! as int) < 945,
        )
        .toList();
    bool safe(int lane) =>
        dangers.every((o) => (lane - (o['x']! as int)).abs() >= 90);
    if (safe(desired) && safe(x)) return desired;
    final preference = safe(x) ? desired : x;
    final lanes = [for (var i = 1; i <= 7; i++) i * 125]
      ..sort((a, b) {
        final distance = (a - preference).abs().compareTo(
          (b - preference).abs(),
        );
        return distance != 0 ? distance : a.compareTo(b);
      });
    return lanes.firstWhere(safe, orElse: () => x);
  }
}
