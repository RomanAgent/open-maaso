import 'surface_play_protocol.dart';

final class PlayRuleViolation implements Exception {
  const PlayRuleViolation(this.code);
  final String code;
  @override
  String toString() => code;
}

final class PlayRuleEvent {
  PlayRuleEvent(this.type, List<String> audience, Map<String, Object?> payload)
    : audience = List.unmodifiable(audience),
      payload = Map<String, Object?>.unmodifiable(
        playObject(playSnapshot(payload)),
      );
  final String type;
  final List<String> audience;
  final Map<String, Object?> payload;
}

final class PlayRuleTransition {
  PlayRuleTransition(Map<String, Object?> state, List<PlayRuleEvent> events)
    : state = Map<String, Object?>.unmodifiable(
        playObject(playSnapshot(state)),
      ),
      events = List.unmodifiable(events);
  final Map<String, Object?> state;
  final List<PlayRuleEvent> events;
}

abstract interface class TrustedPlayRules {
  Map<String, Object?> initial({required int seed});
  void validateState(Map<String, Object?> state);
  Map<String, Object?> view(Map<String, Object?> state, String seatId);
  List<Map<String, Object?>> legalActions(
    Map<String, Object?> state,
    String seatId,
  );
  PlayRuleTransition reduce(
    Map<String, Object?> state,
    String seatId,
    String action,
    Map<String, Object?> args,
  );
}

/// Host-owned integer-only rules. Generated JavaScript never receives this
/// object or its complete state. Both human and Agent moves use [reduce].
final class TrustedTurnRules implements TrustedPlayRules {
  TrustedTurnRules(this.protocol) {
    if (!protocol.isTrustedGame) {
      throw const FormatException('trusted_game_required');
    }
  }
  final SurfacePlayProtocol protocol;
  String get id => protocol.rulesId!;

  @override
  Map<String, Object?> initial({required int seed}) {
    playInteger(seed, min: 1, max: 0xffffffff);
    switch (id) {
      case 'gomoku.v1':
        final size = protocol.rulesConfig['boardSize']! as int;
        return _frozen({
          'board': List.filled(size * size, 0),
          'nextPlayer': 1,
          'moves': 0,
          'winner': 0,
          'finished': false,
        });
      case 'cooperative-switches.v1':
        return _frozen({'mask': 0, 'moves': 0, 'finished': false});
      case 'private-cards.v1':
        var rng = seed;
        int random(int maximum) {
          rng ^= (rng << 13) & 0xffffffff;
          rng ^= rng >>> 17;
          rng ^= (rng << 5) & 0xffffffff;
          rng &= 0xffffffff;
          return rng % maximum;
        }
        List<int> hand() {
          final cards = [0, 1, 2];
          for (var i = 2; i > 0; i--) {
            final j = random(i + 1);
            final v = cards[i];
            cards[i] = cards[j];
            cards[j] = v;
          }
          return cards;
        }
        final hands = [hand(), hand()];
        return _frozen({
          'hands': hands,
          'choices': [-1, -1],
          'rngState': rng,
          'finished': false,
          'winner': 0,
        });
      default:
        throw const FormatException('unregistered_play_rules');
    }
  }

  @override
  Map<String, Object?> view(Map<String, Object?> state, String seatId) {
    _seat(seatId);
    validateState(state);
    switch (id) {
      case 'gomoku.v1':
        return _frozen({
          'boardSize': protocol.rulesConfig['boardSize'],
          'winLength': protocol.rulesConfig['winLength'],
          'board': state['board'],
          'activeSeat': state['finished'] == true
              ? null
              : 'player${state['nextPlayer']}',
          'phase': state['finished'] == true ? 'ended' : 'playing',
          'turnId': 'move-${state['moves']}',
          'winner': state['winner'],
        });
      case 'cooperative-switches.v1':
        final count = protocol.rulesConfig['switchesPerRole']! as int;
        final role = _player(seatId);
        return _frozen({
          'switches': List.generate(
            count * 2,
            (i) => ((state['mask']! as int) & (1 << i)) != 0,
          ),
          'goalMask': protocol.rulesConfig['goalMask'],
          'ownedSwitches': role == 0
              ? []
              : List.generate(count, (i) => (role - 1) * count + i),
          'phase': state['finished'] == true ? 'ended' : 'playing',
          'turnId': 'move-${state['moves']}',
          'teamWon': state['finished'],
        });
      case 'private-cards.v1':
        final role = _player(seatId), ended = state['finished'] == true;
        final hands = (state['hands']! as List)
            .map((v) => List<int>.from(v as List))
            .toList();
        final choices = List<int>.from(state['choices']! as List);
        final ownChoice = role == 0 ? null : choices[role - 1];
        return _frozen({
          'hand': role == 0 ? null : hands[role - 1],
          'chosenCard': ownChoice == null || ownChoice < 0 ? null : ownChoice,
          'phase': ended
              ? 'ended'
              : ownChoice != null && ownChoice >= 0
              ? 'waiting'
              : 'choosing',
          'turnId': ended ? 'result-1' : 'choice-1',
          if (ended)
            'reveal': {
              'player1': hands[0][choices[0]],
              'player2': hands[1][choices[1]],
              'winner': state['winner'],
            },
        });
      default:
        throw const FormatException('unregistered_play_rules');
    }
  }

  @override
  List<Map<String, Object?>> legalActions(
    Map<String, Object?> state,
    String seatId,
  ) {
    _seat(seatId);
    validateState(state);
    final role = _player(seatId);
    if (role == 0 || state['finished'] == true) return const [];
    final actions = <Map<String, Object?>>[];
    void add(String id, Map<String, Object?> args) =>
        actions.add(_frozen({'actionId': id, 'args': args}));
    switch (id) {
      case 'gomoku.v1':
        if (state['nextPlayer'] != role) return const [];
        final size = protocol.rulesConfig['boardSize']! as int;
        final board = state['board']! as List;
        for (var i = 0; i < board.length; i++) {
          if (board[i] == 0) add('game.place', {'x': i % size, 'y': i ~/ size});
        }
      case 'cooperative-switches.v1':
        final count = protocol.rulesConfig['switchesPerRole']! as int;
        for (var i = 0; i < count; i++) {
          add('game.toggle', {'switch': (role - 1) * count + i});
        }
      case 'private-cards.v1':
        if ((state['choices']! as List)[role - 1] != -1) return const [];
        for (var i = 0; i < 3; i++) {
          add('game.choose', {'card': i});
        }
    }
    return List.unmodifiable(actions);
  }

  @override
  PlayRuleTransition reduce(
    Map<String, Object?> previous,
    String seatId,
    String action,
    Map<String, Object?> args,
  ) {
    validateState(previous);
    _seat(seatId);
    if (!protocol.allowsAction(seatId, action, args)) {
      throw const PlayRuleViolation('ILLEGAL_ACTION');
    }
    if (previous['finished'] == true) {
      throw const PlayRuleViolation('MATCH_ENDED');
    }
    final role = _player(seatId);
    if (role == 0) throw const PlayRuleViolation('GRANT_REVOKED');
    final state = Map<String, Object?>.from(previous);
    final events = <PlayRuleEvent>[];
    switch (id) {
      case 'gomoku.v1':
        if (previous['nextPlayer'] != role) {
          throw const PlayRuleViolation('NOT_YOUR_TURN');
        }
        final size = protocol.rulesConfig['boardSize']! as int;
        final board = List<int>.from(previous['board']! as List);
        final x = args['x']! as int,
            y = args['y']! as int,
            index = y * size + x;
        if (board[index] != 0) throw const PlayRuleViolation('ILLEGAL_ACTION');
        board[index] = role;
        final won = _hasLine(
          board,
          size,
          protocol.rulesConfig['winLength']! as int,
          role,
        );
        final moves = (previous['moves']! as int) + 1;
        state.addAll({
          'board': board,
          'moves': moves,
          'nextPlayer': 3 - role,
          'winner': won ? role : 0,
          'finished': won || moves == board.length,
        });
        events.add(
          PlayRuleEvent('move.accepted', surfacePlayRoles, {
            'seatId': seatId,
            'x': x,
            'y': y,
          }),
        );
        events.add(
          PlayRuleEvent(
            state['finished'] == true ? 'game.ended' : 'turn.changed',
            surfacePlayRoles,
            state['finished'] == true
                ? {'winner': state['winner']}
                : {'seatId': 'player${3 - role}'},
          ),
        );
      case 'cooperative-switches.v1':
        final count = protocol.rulesConfig['switchesPerRole']! as int,
            index = args['switch']! as int;
        if (index < count * (role - 1) || index >= count * role) {
          throw const PlayRuleViolation('ILLEGAL_ACTION');
        }
        final mask = (previous['mask']! as int) ^ (1 << index);
        final won = mask == protocol.rulesConfig['goalMask'];
        state.addAll({
          'mask': mask,
          'moves': (previous['moves']! as int) + 1,
          'finished': won,
        });
        events.add(
          PlayRuleEvent('switch.toggled', surfacePlayRoles, {
            'seatId': seatId,
            'switch': index,
            'enabled': (mask & (1 << index)) != 0,
          }),
        );
        if (won) {
          events.add(
            PlayRuleEvent('game.ended', surfacePlayRoles, {'winner': 'team'}),
          );
        }
      case 'private-cards.v1':
        final choices = List<int>.from(previous['choices']! as List);
        if (choices[role - 1] != -1) {
          throw const PlayRuleViolation('ILLEGAL_ACTION');
        }
        choices[role - 1] = args['card']! as int;
        state['choices'] = choices;
        events.add(
          PlayRuleEvent('card.selected', [seatId], {'card': args['card']}),
        );
        if (choices.every((v) => v >= 0)) {
          final hands = previous['hands']! as List;
          final a = (hands[0] as List)[choices[0]]! as int,
              b = (hands[1] as List)[choices[1]]! as int;
          final winner = a == b
              ? 0
              : (a - b + 3) % 3 == 1
              ? 1
              : 2;
          state.addAll({'finished': true, 'winner': winner});
          events.add(
            PlayRuleEvent('game.ended', surfacePlayRoles, {
              'player1': a,
              'player2': b,
              'winner': winner,
            }),
          );
        }
    }
    validateState(state);
    return PlayRuleTransition(state, events);
  }

  @override
  void validateState(Map<String, Object?> state) {
    if (state['finished'] is! bool) {
      throw const FormatException('invalid_play_checkpoint');
    }
    switch (id) {
      case 'gomoku.v1':
        playKeys(state, {'board', 'moves', 'nextPlayer', 'winner', 'finished'});
        final size = protocol.rulesConfig['boardSize']! as int;
        final board = state['board'];
        if (board is! List ||
            board.length != size * size ||
            board.any((v) => v is! int || v < 0 || v > 2)) {
          throw const FormatException('invalid_play_board');
        }
        final one = board.where((v) => v == 1).length,
            two = board.where((v) => v == 2).length;
        if (one != two && one != two + 1 ||
            state['moves'] != one + two ||
            state['nextPlayer'] != (one == two ? 1 : 2)) {
          throw const FormatException('invalid_play_turn');
        }
        final winner = playInteger(state['winner'], max: 2);
        final line = protocol.rulesConfig['winLength']! as int;
        final wins = [
          _hasLine(List<int>.from(board), size, line, 1),
          _hasLine(List<int>.from(board), size, line, 2),
        ];
        if (wins[0] && wins[1] ||
            (winner == 0 ? wins.any((v) => v) : !wins[winner - 1]) ||
            state['finished'] != (winner != 0 || one + two == board.length)) {
          throw const FormatException('invalid_play_outcome');
        }
      case 'cooperative-switches.v1':
        playKeys(state, {'mask', 'moves', 'finished'});
        playInteger(
          state['mask'],
          max:
              (1 << ((protocol.rulesConfig['switchesPerRole']! as int) * 2)) -
              1,
        );
        playInteger(state['moves']);
        if (state['finished'] !=
            (state['mask'] == protocol.rulesConfig['goalMask'])) {
          throw const FormatException('invalid_play_outcome');
        }
      case 'private-cards.v1':
        playKeys(state, {'hands', 'choices', 'rngState', 'finished', 'winner'});
        final hands = state['hands'], choices = state['choices'];
        if (hands is! List ||
            hands.length != 2 ||
            hands.any(
              (hand) =>
                  hand is! List ||
                  hand.length != 3 ||
                  hand.any((v) => v is! int || v < 0 || v > 2) ||
                  hand.toSet().length != 3,
            ) ||
            choices is! List ||
            choices.length != 2 ||
            choices.any((v) => v is! int || v < -1 || v > 2)) {
          throw const FormatException('invalid_private_cards_checkpoint');
        }
        playInteger(state['rngState'], min: 1, max: 0xffffffff);
        playInteger(state['winner'], max: 2);
        if (state['finished'] != choices.every((v) => (v! as int) >= 0)) {
          throw const FormatException('invalid_play_outcome');
        }
    }
  }

  bool _hasLine(List<int> board, int size, int required, int player) {
    for (var y = 0; y < size; y++) {
      for (var x = 0; x < size; x++) {
        if (board[y * size + x] != player) continue;
        for (final d in const [
          [1, 0],
          [0, 1],
          [1, 1],
          [1, -1],
        ]) {
          var count = 0, dx = x, dy = y;
          while (dx >= 0 &&
              dx < size &&
              dy >= 0 &&
              dy < size &&
              board[dy * size + dx] == player) {
            count++;
            if (count >= required) return true;
            dx += d[0];
            dy += d[1];
          }
        }
      }
    }
    return false;
  }

  int _player(String seat) => seat == 'player1'
      ? 1
      : seat == 'player2'
      ? 2
      : 0;
  void _seat(String seat) {
    if (!surfacePlayRoles.contains(seat)) {
      throw const PlayRuleViolation('INVALID_SEAT');
    }
  }

  Map<String, Object?> _frozen(Map<String, Object?> value) =>
      Map<String, Object?>.unmodifiable(playObject(playSnapshot(value)));
}
