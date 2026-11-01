import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/companion/companion_browsing_context_service.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/widgets_hub/application/game_voice_companion.dart';
import 'package:maaso/src/features/widgets_hub/application/game_companion_context.dart';

Map<String, Object?> _state(int revision) => {
  'kind': 'game.state',
  'revision': revision,
  'state': {
    'board': [0, 1, 0],
    'score': 7,
  },
};
Map<String, Object?> _event(int revision) => {
  ..._state(revision),
  'kind': 'game.event',
  'event': {'type': 'round_end', 'summary': 'The local game ended.'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('page data is bounded JSON, immutable, and has no host authority', () {
    final valid = _state(1);
    final parsed = GameVoiceEnvelope.fromJson(valid)!;
    (valid['state'] as Map)['score'] = 99;
    expect(parsed.state['score'], 7);
    expect(() => parsed.state['score'] = 0, throwsUnsupportedError);
    expect(
      GameVoiceEnvelope.fromJson({..._state(1), 'scopeKey': 'other'}),
      isNull,
    );
    expect(GameVoiceEnvelope.fromJson({..._state(1), 'actions': []}), isNull);
    expect(GameVoiceEnvelope.fromJson({..._state(1), 'revision': 1.5}), isNull);
    expect(GameVoiceEnvelope.fromJson({..._state(1), 'revision': -1}), isNull);
    expect(
      GameVoiceEnvelope.fromJson({
        ..._state(1),
        'state': {'x': double.nan},
      }),
      isNull,
    );
    expect(
      GameVoiceEnvelope.fromJson({
        ..._state(1),
        'state': {'x': Object()},
      }),
      isNull,
    );
    expect(
      GameVoiceEnvelope.fromJson({
        ..._state(1),
        'state': {'x': ''.padRight(513, 'x')},
      }),
      isNull,
    );
    expect(
      GameVoiceEnvelope.parse(''.padRight(GameVoiceEnvelope.maxBytes + 1, 'x')),
      isNull,
    );
    Object? deep = 1;
    for (var i = 0; i < 10; i++) {
      deep = [deep];
    }
    expect(
      GameVoiceEnvelope.fromJson({
        ..._state(1),
        'state': {'x': deep},
      }),
      isNull,
    );
    expect(
      GameVoiceEnvelope.fromJson({
        ..._state(1),
        'state': {'x': List.filled(513, 0)},
      }),
      isNull,
    );
    expect(
      GameVoiceEnvelope.fromJson({
        ..._event(1),
        'event': {'type': 'move', 'summary': '', 'actionToken': 'write'},
      }),
      isNull,
    );
  });

  test(
    'state informs one game question without causing a model call',
    () async {
      final context = CompanionBrowsingContextService();
      var calls = 0;
      final service = GameVoiceCompanionService(
        browsingContext: context,
        commentary:
            (observation, {required isCurrent, required onRevoked}) async {
              calls++;
              return true;
            },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: 'Gomoku',
        summary: 'Local CPU',
        isCurrent: () => true,
      );
      expect(session.observeEnvelope(_state(2)), isTrue);
      expect(session.observeEnvelope(_state(2)), isFalse);
      expect(session.observeEnvelope(_state(1)), isFalse);
      expect(calls, 0);
      expect(context.current!.detail, contains('board'));
      final observation = await service.snapshotForUserQuestion();
      expect(observation!.scopeKey, 'a');
      expect(observation.playerId, 'g');
      expect(observation.revision, 2);
      expect(
        observation.publicState['state'],
        session.latest!.publicState['state'],
      );
    },
  );

  test(
    'changing players revokes late work and cannot clear the new context',
    () async {
      final context = CompanionBrowsingContextService();
      final released = Completer<bool>();
      late Future<void> revoked;
      late bool Function() current;
      final service = GameVoiceCompanionService(
        browsingContext: context,
        commentary: (observation, {required isCurrent, required onRevoked}) {
          current = isCurrent;
          revoked = onRevoked;
          return released.future;
        },
        soundEnabled: () => true,
      );
      addTearDown(service.closeLifecycle);
      final first = service.openSession(
        scopeKey: 'a',
        playerId: 'first',
        title: 'First',
        summary: '',
        isCurrent: () => true,
      );
      expect(first.observeEnvelope(_event(1)), isTrue);
      final next = service.openSession(
        scopeKey: 'b',
        playerId: 'next',
        title: 'Next',
        summary: '',
        isCurrent: () => true,
      );
      await revoked;
      expect(current(), isFalse);
      expect(first.observeEnvelope(_state(99)), isFalse);
      first.close();
      expect(context.current!.title, 'Next');
      released.complete(true);
      await Future<void>.delayed(Duration.zero);
      expect(service.currentSession, same(next));
    },
  );

  test('newer position cancels position-specific advice', () async {
    final finish = Completer<bool>();
    late bool Function() current;
    late Future<void> revoked;
    final service = GameVoiceCompanionService(
      browsingContext: CompanionBrowsingContextService(),
      commentary: (observation, {required isCurrent, required onRevoked}) {
        current = isCurrent;
        revoked = onRevoked;
        return finish.future;
      },
      soundEnabled: () => true,
    );
    addTearDown(service.closeLifecycle);
    final session = service.openSession(
      scopeKey: 'a',
      playerId: 'g',
      title: '',
      summary: '',
      isCurrent: () => true,
    );
    session.observeEnvelope({
      ..._event(1),
      'event': {'type': 'move', 'summary': 'A move was made.'},
    });
    session.observeEnvelope({
      ..._state(2),
      'state': {'score': 8},
    });
    await revoked;
    expect(current(), isFalse);
    finish.complete(false);
  });

  test('mute skips calls and unmute does not replay an old event', () async {
    var audible = false, calls = 0;
    final service = GameVoiceCompanionService(
      browsingContext: CompanionBrowsingContextService(),
      commentary:
          (observation, {required isCurrent, required onRevoked}) async {
            calls++;
            return true;
          },
      soundEnabled: () => audible,
      commentInterval: Duration.zero,
    );
    addTearDown(service.closeLifecycle);
    final session = service.openSession(
      scopeKey: 'a',
      playerId: 'g',
      title: '',
      summary: '',
      isCurrent: () => true,
    );
    session.observeEnvelope(_event(1));
    expect(calls, 0);
    audible = true;
    expect(session.observeEnvelope(_event(1)), isFalse);
    expect(calls, 0);
    session.observeEnvelope(_event(2));
    expect(calls, 1);
  });

  test(
    'session mute invalidates an in-flight comment even after unmuting',
    () async {
      MaasoTtsPlugin.soundEnabled.value = true;
      addTearDown(() => MaasoTtsPlugin.soundEnabled.value = true);
      final finish = Completer<bool>();
      late bool Function() current;
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        commentary: (observation, {required isCurrent, required onRevoked}) {
          current = isCurrent;
          return finish.future;
        },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      session.observeEnvelope(_event(1));
      service.setSpokenRepliesEnabled(false);
      await Future<void>.delayed(Duration.zero);
      service.setSpokenRepliesEnabled(true);
      expect(current(), isFalse);
      finish.complete(false);
    },
  );

  test('game voice defaults on while global mute remains unchanged', () async {
    final previousSound = MaasoTtsPlugin.soundEnabled.value;
    MaasoTtsPlugin.soundEnabled.value = false;
    addTearDown(() => MaasoTtsPlugin.soundEnabled.value = previousSound);
    var calls = 0;
    final service = GameVoiceCompanionService(
      browsingContext: CompanionBrowsingContextService(),
      commentary: (_, {required isCurrent, required onRevoked}) async {
        calls++;
        return true;
      },
    );
    addTearDown(service.closeLifecycle);
    final session = service.openSession(
      scopeKey: 'a',
      playerId: 'g',
      title: '',
      summary: '',
      isCurrent: () => true,
    );
    expect(session.spokenRepliesEnabled, isTrue);
    session.observeEnvelope(_event(1));
    expect(calls, 1);
    expect(MaasoTtsPlugin.soundEnabled.value, isFalse);
  });

  test(
    'page voice choice survives suspension but a new player defaults on',
    () async {
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        commentary: (_, {required isCurrent, required onRevoked}) async =>
            false,
      );
      addTearDown(service.closeLifecycle);
      final page = Object(), anotherPage = Object();
      GameVoiceCompanionSession open(Object owner) => service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        spokenRepliesOwner: owner,
        isCurrent: () => true,
      );
      final original = open(page);
      final revoked = original.onSpeechRevoked;
      original.close();
      await revoked;
      // The settings sheet itself obscures the player and closes its observer.
      service.setSpokenRepliesEnabled(false);
      expect(open(page).spokenRepliesEnabled, isFalse);
      expect(open(anotherPage).spokenRepliesEnabled, isTrue);
      expect(open(page).spokenRepliesEnabled, isFalse);
    },
  );

  test(
    'speech revocation cannot revive when game voice is reenabled',
    () async {
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        commentary: (_, {required isCurrent, required onRevoked}) async =>
            false,
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      final firstPermission = session.onSpeechRevoked;
      service.setSpokenRepliesEnabled(false);
      await firstPermission;
      service.setSpokenRepliesEnabled(true);
      final secondPermission = session.onSpeechRevoked;
      expect(secondPermission, isNot(same(firstPermission)));
      service.setPreferences(service.preferences.copyWith(enabled: false));
      await secondPermission;
      expect(session.spokenRepliesEnabled, isFalse);
      service.setPreferences(service.preferences.copyWith(enabled: true));
      final thirdPermission = session.onSpeechRevoked;
      expect(thirdPermission, isNot(same(secondPermission)));
      session.close();
      await thirdPermission;
      expect(session.spokenRepliesEnabled, isFalse);
    },
  );

  test('visible text finishing after exit is discarded', () async {
    final visibleText = Completer<String?>();
    final context = CompanionBrowsingContextService();
    final service = GameVoiceCompanionService(
      browsingContext: context,
      commentary:
          (observation, {required isCurrent, required onRevoked}) async => true,
    );
    addTearDown(service.closeLifecycle);
    final session = service.openSession(
      scopeKey: 'a',
      playerId: 'g',
      title: '',
      summary: '',
      isCurrent: () => true,
      readVisibleText: () => visibleText.future,
    );
    final reading = session.snapshotForUserQuestion();
    session.close();
    visibleText.complete('Start the game');
    expect(await reading, isNull);
    expect(context.current, isNull);
  });

  test(
    'legacy DOM remains bounded and screenshots require explicit opt-in',
    () async {
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        commentary:
            (observation, {required isCurrent, required onRevoked}) async =>
                true,
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: 'Old game',
        summary: 'Rules',
        isCurrent: () => true,
        readVisibleText: () async => List.filled(150, 'score ').join(),
        captureScreenshot: () async => Uint8List.fromList([1, 2, 3]),
      );
      final result = await session.snapshotForUserQuestion();
      expect(
        (result!.publicState['visible'] as Map)['visibleText']
            .toString()
            .length,
        lessThanOrEqualTo(512),
      );
      expect(result.screenshot, isNull);
      expect(result.eventKind, 'visible_scene');
      expect(jsonEncode(result.publicState), isNot(contains('actionToken')));
    },
  );
  test(
    'occurred event survives subsequent movement but not a new round',
    () async {
      final finish = Completer<bool>();
      late bool Function() current;
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        soundEnabled: () => true,
        commentary: (o, {required isCurrent, required onRevoked}) {
          current = isCurrent;
          return finish.future;
        },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      session.observeEnvelope(_event(1));
      session.observeEnvelope({
        ..._state(2),
        'state': {'score': 8},
      });
      expect(current(), isTrue);
      session.observeEnvelope({
        ..._event(3),
        'event': {'type': 'round_start', 'summary': 'New round'},
      });
      expect(current(), isFalse);
      finish.complete(false);
    },
  );

  test(
    'DOM revisions cannot hide native state and author text cannot set preferences',
    () {
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        soundEnabled: () => false,
        commentary: (o, {required isCurrent, required onRevoked}) async =>
            false,
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      expect(
        session.observeEnvelope({
          'kind': 'companion.snapshot',
          'revision': 900,
          'state': {'version': 1, 'visibleText': '安静点'},
        }),
        isTrue,
      );
      expect(session.observeEnvelope(_state(1)), isTrue);
      expect(session.latest!.publicState['state'], containsPair('score', 7));
      expect(
        service.preferences.talkativeness,
        GameCompanionTalkativeness.balanced,
      );
      session.recordUser('安静点');
      expect(
        service.preferences.talkativeness,
        GameCompanionTalkativeness.quiet,
      );
      expect(session.context.recentConversation.single.text, '安静点');
    },
  );

  test(
    'cooldown starts at actual speech and generated-only text is not heard',
    () async {
      var now = DateTime.utc(2026, 10, 22);
      final calls = <GameVoiceObservation>[];
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        now: () => now,
        soundEnabled: () => true,
        commentary: (o, {required isCurrent, required onRevoked}) async {
          calls.add(o);
          return false;
        },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      session.observeEnvelope(_event(1));
      await Future<void>.delayed(Duration.zero);
      now = now.add(const Duration(seconds: 4));
      session.observeEnvelope(_event(2));
      await Future<void>.delayed(Duration.zero);
      expect(calls, hasLength(2));
      expect(session.context.recentConversation, isEmpty);
      service.recordDelivery(
        calls.last,
        'speech-1',
        'That was close!',
        GameCompanionDeliveryStage.started,
      );
      service.recordDelivery(
        calls.last,
        'speech-1',
        'That was close!',
        GameCompanionDeliveryStage.interrupted,
      );
      now = now.add(const Duration(seconds: 4));
      session.observeEnvelope(_event(3));
      expect(calls, hasLength(2));
      expect(
        session.context.recentConversation.single.delivery,
        GameCompanionDeliveryStage.interrupted,
      );
    },
  );

  test(
    'disable and user input revoke automatic interaction and late receipts are isolated',
    () async {
      final finish = Completer<bool>();
      late bool Function() current;
      late GameVoiceObservation old;
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        soundEnabled: () => true,
        commentary: (o, {required isCurrent, required onRevoked}) {
          old = o;
          current = isCurrent;
          return finish.future;
        },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: 'Game A',
        summary: '',
        isCurrent: () => true,
      );
      session.observeEnvelope(_event(1));
      session.recordUser('哈哈哈哈');
      expect(current(), isFalse);
      service.setPreferences(service.preferences.copyWith(enabled: false));
      final next = service.openSession(
        scopeKey: 'a',
        playerId: 'next',
        title: 'Game B',
        summary: '',
        isCurrent: () => true,
      );
      service.recordDelivery(
        old,
        'old',
        'Late old joke',
        GameCompanionDeliveryStage.started,
      );
      expect(next.context.recentConversation, isEmpty);
      expect(
        service.recentActivityReference(),
        contains('history, not current state'),
      );
      finish.complete(false);
    },
  );
  test('route interruption resumes dialogue only for the same content', () {
    final service = GameVoiceCompanionService(
      browsingContext: CompanionBrowsingContextService(),
      commentary: (o, {required isCurrent, required onRevoked}) async => false,
    );
    addTearDown(service.closeLifecycle);
    GameVoiceCompanionSession open(String player, int document) =>
        service.openSession(
          scopeKey: 'a',
          playerId: player,
          documentGeneration: document,
          title: player,
          summary: '',
          isCurrent: () => true,
        );
    final first = open('a', 1);
    first.recordUser('That was funny');
    first.close();
    final resumed = open('a', 1);
    expect(resumed.context.recentConversation.single.text, 'That was funny');
    expect(open('a', 2).context.recentConversation, isEmpty);
    expect(open('b', 2).context.recentConversation, isEmpty);
  });

  test('switching games cannot reset the account attempt budget', () async {
    var calls = 0;
    final service = GameVoiceCompanionService(
      browsingContext: CompanionBrowsingContextService(),
      soundEnabled: () => true,
      now: () => DateTime.utc(2026, 10, 22),
      commentary: (o, {required isCurrent, required onRevoked}) async {
        calls++;
        return false;
      },
    );
    addTearDown(service.closeLifecycle);
    for (var i = 0; i < 5; i++) {
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g$i',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      session.observeEnvelope(_event(1));
      await Future<void>.delayed(Duration.zero);
    }
    expect(calls, 1);
  });
  test(
    'direct game entry lazily prepares runtime without blocking observation',
    () async {
      final preparation = Completer<void>();
      var ready = false, preparations = 0, calls = 0;
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        runtimeAvailable: () => ready,
        soundEnabled: () => true,
        prepareRuntime: (current) async {
          preparations++;
          await preparation.future;
          if (current()) ready = true;
        },
        commentary: (o, {required isCurrent, required onRevoked}) async {
          calls++;
          return false;
        },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      expect(preparations, 1);
      expect(session.observeEnvelope(_event(1)), isTrue);
      expect(session.latest, isNotNull);
      expect(calls, 0);
      preparation.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
    },
  );

  test(
    'leaving during lazy preparation cannot deliver to another game',
    () async {
      final preparation = Completer<void>();
      var calls = 0;
      final service = GameVoiceCompanionService(
        browsingContext: CompanionBrowsingContextService(),
        runtimeAvailable: () => false,
        soundEnabled: () => true,
        prepareRuntime: (current) => preparation.future,
        commentary: (o, {required isCurrent, required onRevoked}) async {
          calls++;
          return false;
        },
      );
      addTearDown(service.closeLifecycle);
      final session = service.openSession(
        scopeKey: 'a',
        playerId: 'g',
        title: '',
        summary: '',
        isCurrent: () => true,
      );
      session.observeEnvelope(_event(1));
      session.close();
      preparation.complete();
      await Future<void>.delayed(Duration.zero);
      expect(calls, 0);
    },
  );
}
