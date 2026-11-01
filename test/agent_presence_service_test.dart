import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_protection.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/models/milestone.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/vad_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  tearDown(appServices.reset);

  testWidgets(
    'busy starting during ambient gaze prevents subsequent body writes',
    (tester) async {
      var busy = false;
      final runtime = _PresenceRuntime();
      final gaze = _PausedPresenceGaze();
      final presence = AgentPresenceService(
        runtimeBusy: () => busy,
        avatarBehaviorDirector: AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
          gazeIntentHandler: gaze,
          emitEmotion: (_) {},
        ),
      );
      presence.observeUserTurn('hello');
      await tester.pump();
      expect(gaze.started.isCompleted, isTrue);
      busy = true;
      gaze.resume.complete();
      await tester.pump();
      expect(runtime.bodyWrites, 0);
      expect(presence.state.value.lastSilentMotionAt, isNull);
      busy = false;
      presence.evaluateTick();
      await tester.pump();
      expect(runtime.bodyWrites, greaterThan(0));
      expect(presence.state.value.lastSilentMotionAt, isNotNull);
    },
  );

  testWidgets(
    'hung ambient expires and late gaze completion cannot resume it',
    (tester) async {
      final runtime = _PresenceRuntime();
      final gaze = _PausedPresenceGaze();
      final presence = AgentPresenceService(
        avatarBehaviorDirector: AvatarBehaviorDirector(
          runtimeProvider: () => runtime,
          gazeIntentHandler: gaze,
          emitEmotion: (_) {},
        ),
      );
      presence.observeUserTurn('hello');
      await tester.pump();
      await tester.pump(AvatarBehaviorProtection.maximumDuration);
      gaze.resume.complete();
      await tester.pump();
      expect(runtime.bodyWrites, 0);
      expect(presence.state.value.lastSilentMotionAt, isNull);
      presence.evaluateTick();
      await tester.pump();
      expect(runtime.bodyWrites, greaterThan(0));
    },
  );

  test(
    'typing bursts preserve the current expression and only update state',
    () async {
      final clock = _FakeClock(DateTime(2026, 9, 2, 12));
      appServices.put(AvatarBehaviorProtection(now: clock.call));
      final emotions = <AvatarEmotionIntent>[];
      final director = AvatarBehaviorDirector(emitEmotion: emotions.add);
      final presence = AgentPresenceService(
        now: clock.call,
        avatarBehaviorDirector: director,
      );
      await director.applyAct(
        const AvatarAct(mood: 'excited', durationMs: 2400),
      );

      for (var i = 0; i < 30; i++) {
        presence.observeInputActivity(PresenceInputActivityKind.typing);
        presence.evaluateTick();
        clock.advance(const Duration(milliseconds: 50));
      }
      await Future<void>.delayed(Duration.zero);
      expect(presence.state.value.conversationArousal, greaterThan(0.6));
      expect(presence.state.value.lastInputActivityAt, isNotNull);
      expect(emotions.map((event) => event.label), ['excited']);
      expect(presence.state.value.lastSilentMotionAt, isNull);

      clock.advance(const Duration(seconds: 1));
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      expect(emotions.map((event) => event.label), ['excited', 'calm']);
      expect(presence.state.value.lastSilentMotionAt, isNotNull);
    },
  );

  test(
    'busy and speaking states block ambience and recover without consuming cooldown',
    () async {
      final clock = _FakeClock(DateTime(2026, 9, 2, 12));
      var busy = true;
      final director = _RecordingPresenceDirector();
      final presence = appServices.put(
        AgentPresenceService(
          now: clock.call,
          runtimeBusy: () => busy,
          avatarBehaviorDirector: director,
        ),
      );
      presence.observeUserTurn('hello');
      presence.evaluateTick();
      expect(director.applyCount, 0);
      expect(presence.state.value.lastSilentMotionAt, isNull);
      busy = false;

      EventBus().fire(SpeakingStatusEvent(true, agentId: 'self'));
      await Future<void>.delayed(Duration.zero);
      presence.evaluateTick();
      expect(director.applyCount, 0);
      EventBus().fire(SpeakingStatusEvent(false, agentId: 'peer'));
      await Future<void>.delayed(Duration.zero);
      presence.evaluateTick();
      expect(director.applyCount, 0);

      EventBus().fire(SpeakingStatusEvent(false, agentId: 'self'));
      EventBus().fire(UserSpeakingStartedEvent());
      await Future<void>.delayed(Duration.zero);
      presence.evaluateTick();
      expect(director.applyCount, 0);
      EventBus().fire(
        UserSpeakingEndedEvent(
          duration: const Duration(seconds: 1),
          samples: Float32List(1),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      expect(director.applyCount, 1);
      expect(director.lastAmbient, isTrue);
    },
  );

  test(
    'all silent entry points share cooldown and ambient actions never renew protection',
    () async {
      final clock = _FakeClock(DateTime(2026, 9, 2, 12));
      final protection = appServices.put(
        AvatarBehaviorProtection(now: clock.call),
      );
      final emotions = <AvatarEmotionIntent>[];
      final presence = AgentPresenceService(
        now: clock.call,
        avatarBehaviorDirector: AvatarBehaviorDirector(
          emitEmotion: emotions.add,
        ),
      );
      presence.observeUserTurn('hello');
      await Future<void>.delayed(Duration.zero);
      expect(emotions, hasLength(1));
      expect(protection.isProtected('self'), isFalse);
      presence.observeUserTurn('another turn');
      presence.observeSystemStatus(SystemStatusEvent('user_emotion_happy'));
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      expect(emotions, hasLength(1));

      clock.advance(const Duration(seconds: 18));
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      expect(emotions, hasLength(2));
      expect(protection.isProtected('self'), isFalse);
    },
  );

  test(
    'failed silent motion may retry and does not leave the pending gate closed',
    () async {
      final director = _RecordingPresenceDirector()..succeeds = false;
      final presence = AgentPresenceService(avatarBehaviorDirector: director);
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      expect(director.applyCount, 1);
      expect(presence.state.value.lastSilentMotionAt, isNull);
      director.succeeds = true;
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      expect(director.applyCount, 2);
      expect(presence.state.value.lastSilentMotionAt, isNotNull);
    },
  );

  test('presence state serializes and restores continuity fields', () {
    final now = DateTime(2026, 7, 2, 15);
    final original = AgentPresenceState(
      mode: AgentPresenceMode.daydreaming,
      energy: 0.62,
      conversationArousal: 0.34,
      moodBias: AgentPresenceMoodBias.curious,
      attention: AgentPresenceAttention.self,
      lastUserInteractionAt: now.subtract(const Duration(minutes: 9)),
      recentUserTurnCount: 4,
      averageUserReplyGapSeconds: 18.5,
      lastInputActivityAt: now.subtract(const Duration(minutes: 7)),
      lastSpokenThoughtAt: now.subtract(const Duration(minutes: 6)),
      lastSilentMotionAt: now.subtract(const Duration(seconds: 22)),
      lastModeChangedAt: now.subtract(const Duration(minutes: 10)),
      lastSignalAt: now.subtract(const Duration(minutes: 5)),
      lastUserAffect: 'happy',
      lastInnerThoughtAt: now.subtract(const Duration(minutes: 3)),
      lastInnerThoughtSeed: 'remember the little win from yesterday',
      lastInnerThoughtSummary: 'quietly replaying a small shared win',
      lastInnerThoughtSeedKey: 'app.presence.seed.relationship',
      lastInnerThoughtSeedParams: const <String, Object?>{
        'hint': 'remember the little win from yesterday',
      },
    );

    final restored = AgentPresenceState.fromJson(
      original.toJson(),
      fallbackNow: now,
    );

    expect(restored.mode, original.mode);
    expect(restored.energy, original.energy);
    expect(restored.conversationArousal, original.conversationArousal);
    expect(restored.moodBias, original.moodBias);
    expect(restored.attention, original.attention);
    expect(restored.lastUserInteractionAt, original.lastUserInteractionAt);
    expect(restored.recentUserTurnCount, original.recentUserTurnCount);
    expect(
      restored.averageUserReplyGapSeconds,
      original.averageUserReplyGapSeconds,
    );
    expect(restored.lastInputActivityAt, original.lastInputActivityAt);
    expect(restored.lastSpokenThoughtAt, original.lastSpokenThoughtAt);
    expect(restored.lastSilentMotionAt, original.lastSilentMotionAt);
    expect(restored.lastModeChangedAt, original.lastModeChangedAt);
    expect(restored.lastSignalAt, original.lastSignalAt);
    expect(restored.lastUserAffect, original.lastUserAffect);
    expect(restored.lastInnerThoughtAt, original.lastInnerThoughtAt);
    expect(restored.lastInnerThoughtSeed, original.lastInnerThoughtSeed);
    expect(restored.lastInnerThoughtSummary, original.lastInnerThoughtSummary);
    expect(restored.lastInnerThoughtSeedKey, original.lastInnerThoughtSeedKey);
    expect(
      restored.lastInnerThoughtSeedParams,
      original.lastInnerThoughtSeedParams,
    );
  });

  test('db persists a single presence snapshot per agent', () async {
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'presence_snapshot_test.db',
    );
    await db.saveAgentPresenceState('self', {
      'mode': AgentPresenceMode.companion.name,
      'energy': 0.81,
      'conversationArousal': 0.72,
      'moodBias': AgentPresenceMoodBias.happy.name,
      'attention': AgentPresenceAttention.user.name,
      'lastModeChangedAt': DateTime(2026, 7, 2, 15).millisecondsSinceEpoch,
      'lastSignalAt': DateTime(2026, 7, 2, 15, 1).millisecondsSinceEpoch,
    });
    await db.saveAgentPresenceState('self', {
      'mode': AgentPresenceMode.daydreaming.name,
      'energy': 0.66,
      'conversationArousal': 0.2,
      'moodBias': AgentPresenceMoodBias.curious.name,
      'attention': AgentPresenceAttention.self.name,
      'lastModeChangedAt': DateTime(2026, 7, 2, 16).millisecondsSinceEpoch,
      'lastSignalAt': DateTime(2026, 7, 2, 16, 1).millisecondsSinceEpoch,
    });

    final snapshot = await db.getAgentPresenceState('self');

    expect(snapshot, isNotNull);
    expect(snapshot!['mode'], AgentPresenceMode.daydreaming.name);
    expect(snapshot['energy'], 0.66);
    expect(snapshot['attention'], AgentPresenceAttention.self.name);
  });

  test('service restores and persists presence snapshots', () async {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final saves = <Map<String, Object?>>[];
    final presence = AgentPresenceService(
      now: clock.call,
      loadSnapshot: () async => {
        'mode': AgentPresenceMode.daydreaming.name,
        'energy': 0.58,
        'conversationArousal': 0.22,
        'moodBias': AgentPresenceMoodBias.curious.name,
        'attention': AgentPresenceAttention.self.name,
        'lastModeChangedAt': clock
            .call()
            .subtract(const Duration(minutes: 5))
            .millisecondsSinceEpoch,
        'lastSignalAt': clock
            .call()
            .subtract(const Duration(minutes: 4))
            .millisecondsSinceEpoch,
        'lastInnerThoughtAt': clock
            .call()
            .subtract(const Duration(minutes: 3))
            .millisecondsSinceEpoch,
        'lastInnerThoughtSeed': 'thinking about the shared project',
        'lastInnerThoughtSummary': 'quietly thinking about the shared project',
      },
      saveSnapshot: (snapshot) async => saves.add(Map.of(snapshot)),
    );

    await presence.restore();
    expect(presence.state.value.mode, AgentPresenceMode.daydreaming);
    expect(
      presence.state.value.lastInnerThoughtSeed,
      'thinking about the shared project',
    );
    expect(
      presence.state.value.lastInnerThoughtSummary,
      'quietly thinking about the shared project',
    );

    presence.observeInputActivity(PresenceInputActivityKind.typing);
    await Future<void>.delayed(Duration.zero);

    expect(saves, isNotEmpty);
    expect(saves.last['mode'], AgentPresenceMode.companion.name);
    expect(saves.last['attention'], AgentPresenceAttention.user.name);
  });

  test('sleep hour moves presence toward half rest', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 23, 30));
    final presence = AgentPresenceService(now: clock.call);

    final intent = presence.evaluateTick();

    expect(presence.state.value.mode, AgentPresenceMode.halfRest);
    expect(presence.state.value.attention, AgentPresenceAttention.resting);
    expect(intent.kind, PresenceIntentKind.restShift);
  });

  test(
    'sustained quiet night enters sleep and an actual user turn wakes it',
    () {
      final clock = _FakeClock(DateTime(2026, 7, 2, 23, 30));
      final presence = AgentPresenceService(now: clock.call);
      presence.evaluateTick();
      clock.advance(const Duration(minutes: 9));
      presence.evaluateTick();
      expect(presence.state.value.mode, AgentPresenceMode.sleeping);
      clock.advance(const Duration(minutes: 9));
      presence.evaluateTick();
      expect(presence.state.value.mode, AgentPresenceMode.sleeping);
      presence.observeUserTurn('醒醒，聊一下');
      expect(presence.state.value.mode, isNot(AgentPresenceMode.sleeping));
    },
  );

  test('half rest applies a soft listening avatar act', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 23, 30));
    final director = _RecordingPresenceDirector();
    final presence = AgentPresenceService(
      now: clock.call,
      avatarBehaviorDirector: director,
    );

    final intent = presence.evaluateTick();

    expect(intent.kind, PresenceIntentKind.restShift);
    expect(director.lastReaction, isNull);
    expect(director.lastAct?.gesture, 'listen');
    expect(director.lastAct?.gaze, 'down');
    expect(director.lastAct?.style, 'soft');
    expect(director.lastAct?.intensity, lessThan(0.45));
  });

  test('normal message during half rest does not fully wake the agent', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 23, 45));
    final presence = AgentPresenceService(now: clock.call);
    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.halfRest,
      attention: AgentPresenceAttention.resting,
      energy: 0.28,
    );

    final intent = presence.observeUserTurn('还在吗');

    expect(presence.state.value.mode, AgentPresenceMode.tired);
    expect(presence.state.value.attention, AgentPresenceAttention.user);
    expect(intent.kind, PresenceIntentKind.silentMotion);
    expect(intent.requiresWake, isFalse);
  });

  test('explicit wake phrase moves half-resting agent to companion', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 23, 45));
    final presence = AgentPresenceService(now: clock.call);
    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.halfRest,
      attention: AgentPresenceAttention.resting,
      energy: 0.2,
    );

    final intent = presence.observeUserTurn('醒醒，陪我一下');

    expect(presence.state.value.mode, AgentPresenceMode.companion);
    expect(presence.state.value.energy, greaterThan(0.2));
    expect(intent.kind, PresenceIntentKind.wakeShift);
  });

  test('fast user messages raise conversation arousal', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(now: clock.call);

    presence.observeUserTurn('第一句');
    clock.advance(const Duration(seconds: 12));
    presence.observeUserTurn('第二句');
    clock.advance(const Duration(seconds: 14));
    presence.observeUserTurn('第三句');

    expect(presence.state.value.mode, AgentPresenceMode.companion);
    expect(presence.state.value.conversationArousal, greaterThanOrEqualTo(0.7));
    expect(presence.state.value.recentUserTurnCount, 3);
    expect(presence.state.value.averageUserReplyGapSeconds, lessThan(20));
  });

  test('repeated input activity raises attention without speech', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(now: clock.call);

    final intent = presence.observeInputActivity(PresenceInputActivityKind.tap);
    clock.advance(const Duration(seconds: 3));
    presence.observeInputActivity(PresenceInputActivityKind.focus);

    expect(presence.state.value.attention, AgentPresenceAttention.user);
    expect(presence.state.value.conversationArousal, greaterThan(0));
    expect(intent.kind, PresenceIntentKind.silentMotion);
    expect(presence.nextProactivePrompt(), isNull);
  });

  test('typing updates attention without immediately moving the avatar', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final director = _RecordingPresenceDirector();
    final presence = AgentPresenceService(
      now: clock.call,
      avatarBehaviorDirector: director,
    );

    final intent = presence.observeInputActivity(
      PresenceInputActivityKind.typing,
    );

    expect(intent.kind, PresenceIntentKind.silentMotion);
    expect(director.lastReaction, isNull);
    expect(director.lastAct, isNull);
    expect(presence.state.value.attention, AgentPresenceAttention.user);
  });

  test(
    'voice utterance completion contributes to active conversation state',
    () {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(now: clock.call);

      presence.observeInputActivity(PresenceInputActivityKind.voiceModeEntry);
      clock.advance(const Duration(seconds: 6));
      presence.observeInputActivity(
        PresenceInputActivityKind.voiceUtteranceEnded,
      );
      clock.advance(const Duration(seconds: 8));
      presence.observeInputActivity(
        PresenceInputActivityKind.voiceUtteranceEnded,
      );

      expect(presence.state.value.mode, AgentPresenceMode.companion);
      expect(presence.state.value.conversationArousal, greaterThan(0.45));
    },
  );

  test('conversation arousal decays after quiet time', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(now: clock.call);

    presence.observeUserTurn('第一句');
    clock.advance(const Duration(seconds: 8));
    presence.observeUserTurn('第二句');
    final active = presence.state.value.conversationArousal;

    clock.advance(const Duration(minutes: 12));
    presence.evaluateTick();

    expect(presence.state.value.conversationArousal, lessThan(active));
    expect(presence.state.value.mode, AgentPresenceMode.daydreaming);
  });

  test(
    'quiet ticks keep daydreaming internal without moving the avatar',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final config = appServices.put(AgentBehaviorConfig());
      config.presenceStrongAnthropomorphic.value = false;
      final director = _RecordingPresenceDirector();
      final presence = AgentPresenceService(
        now: clock.call,
        avatarBehaviorDirector: director,
      );
      presence.state.value = presence.state.value.copyWith(
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 9),
        ),
      );

      for (var i = 0; i < 4; i++) {
        final intent = presence.evaluateTick();
        await Future<void>.delayed(Duration.zero);
        expect(intent.kind, PresenceIntentKind.none);
        expect(presence.state.value.mode, AgentPresenceMode.daydreaming);
        expect(director.applyCount, 0);
        clock.advance(config.presenceTick);
      }

      expect(presence.state.value.lastSilentMotionAt, isNull);
      expect(presence.state.value.lastInnerThoughtAt, isNotNull);
      expect(presence.state.value.lastInnerThoughtSummary, isNotEmpty);
      expect(presence.nextProactiveHandoff(), isNull);
    },
  );

  test(
    'restored daydreaming stays still and resumes listening on a user turn',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final config = appServices.put(AgentBehaviorConfig());
      config.presenceStrongAnthropomorphic.value = false;
      final director = _RecordingPresenceDirector();
      final lastMotion = clock.call().subtract(const Duration(minutes: 1));
      final restoredState = AgentPresenceState.initial(clock.call()).copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSilentMotionAt: lastMotion,
      );
      final presence = AgentPresenceService(
        now: clock.call,
        avatarBehaviorDirector: director,
        loadSnapshot: () async => restoredState.toJson(),
      );
      await presence.restore();

      for (var i = 0; i < 4; i++) {
        expect(presence.evaluateTick().kind, PresenceIntentKind.none);
        await Future<void>.delayed(Duration.zero);
        clock.advance(config.presenceTick);
      }
      expect(director.applyCount, 0);
      expect(presence.state.value.lastSilentMotionAt, lastMotion);

      final intent = presence.observeUserTurn('今天过得怎么样');
      await Future<void>.delayed(Duration.zero);
      expect(intent.kind, PresenceIntentKind.silentMotion);
      expect(presence.state.value.mode, AgentPresenceMode.companion);
      expect(director.applyCount, 1);
      expect(director.lastAct?.gesture, 'listen');
      expect(director.lastAct?.gaze, 'user');
    },
  );

  test('daydreaming stays still while the runtime is busy', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final director = _RecordingPresenceDirector();
    final presence = AgentPresenceService(
      now: clock.call,
      runtimeBusy: () => true,
      avatarBehaviorDirector: director,
    );
    presence.state.value = presence.state.value.copyWith(
      lastUserInteractionAt: clock.call().subtract(const Duration(minutes: 20)),
      lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
    );

    final intent = presence.evaluateTick();

    expect(presence.state.value.mode, AgentPresenceMode.daydreaming);
    expect(intent.kind, PresenceIntentKind.none);
    expect(director.lastReaction, isNull);
    expect(director.lastAct, isNull);
  });

  test('daydreaming tick emits a presence spoken thought event', () async {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final director = _RecordingPresenceDirector();
    final presence = AgentPresenceService(
      now: clock.call,
      runtimeBusy: () => false,
      avatarBehaviorDirector: director,
    );
    final events = <SystemStatusEvent>[];
    final sub = EventBus()
        .on<SystemStatusEvent>()
        .where((event) => event.triggerType == 'presence_spoken_thought')
        .listen(events.add);
    addTearDown(sub.cancel);

    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.daydreaming,
      attention: AgentPresenceAttention.self,
      energy: 0.76,
      lastUserInteractionAt: clock.call().subtract(const Duration(minutes: 20)),
      lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
    );

    final intent = presence.evaluateTick();
    await Future<void>.delayed(Duration.zero);

    expect(intent.kind, PresenceIntentKind.spokenThought);
    expect(events, hasLength(1));
    expect(events.single.payload, isA<Map>());
    expect(events.single.payload['textSeed'], isNull);
    expect(events.single.payload['textSeedKey'], 'app.presence.seed.present');
    expect(director.applyCount, 0);
    expect(presence.state.value.lastSilentMotionAt, isNull);
  });

  test(
    'spoken cooldown records inner thought without proactive event',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
        relationshipThoughtSeed: () => "remember the user's workshop plan",
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
        lastSpokenThoughtAt: clock.call().subtract(const Duration(seconds: 20)),
        lastSilentMotionAt: clock.call(),
      );

      final intent = presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);

      expect(intent.kind, PresenceIntentKind.none);
      expect(events, isEmpty);
      expect(presence.nextProactivePrompt(), isNull);
      expect(presence.state.value.lastInnerThoughtAt, clock.call());
      expect(
        presence.state.value.lastInnerThoughtSeed,
        contains('workshop plan'),
      );
      expect(
        presence.state.value.lastInnerThoughtSummary,
        contains('daydreaming'),
      );
    },
  );

  test(
    'proactive prompt selects one candidate without repeating inner thought',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
        relationshipThoughtSeed: () => 'remember fixing the projector together',
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      final intent = presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);

      expect(intent.kind, PresenceIntentKind.spokenThought);
      expect(intent.textSeed, contains('present in the space'));
      expect(events.single.payload['textSeed'], isNull);
      expect(events.single.payload['textSeedKey'], 'app.presence.seed.present');
      expect(events.single.payload['textSeedParams'], isNull);
      expect(events.single.payload['handoffType'], 'presenceProactive');
      expect(events.single.payload['reason'], 'quiet_daydream');
      expect(events.single.payload['cooldownKey'], isNotEmpty);
      expect(events.single.payload['innerThoughtSummary'], isNull);
      expect(events.single.payload['prompt'], isNull);
      expect(
        presence.state.value.lastInnerThoughtSeed,
        contains('fixing the projector'),
      );

      final handoff = presence.nextProactiveHandoff();
      expect(handoff, isNotNull);
      expect(handoff!.reason, 'quiet_daydream');
      expect(handoff.textSeedFor(), contains('present in the space'));
      expect(handoff.regenerateInnerThoughtSummary, isFalse);
      expect(handoff.prompt, contains('one brief natural line'));
      expect(handoff.prompt, isNot(contains('fixing the projector together')));
      expect(
        presence.state.value.lastInnerThoughtSeed,
        contains('fixing the projector together'),
      );
      expect(presence.nextProactiveHandoff(), isNull);
    },
  );

  test(
    'built-in queued seed rerenders entirely in the consuming locale',
    () async {
      appServices.put<SecureStorageService>(_MemorySecureStorageService());
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      final intent = presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);

      expect(intent.textSeed, contains('陪伴在这个空间'));
      expect(events, hasLength(1));
      final payload = events.single.payload as Map;
      expect(payload['textSeed'], isNull);
      expect(payload['textSeedKey'], 'app.presence.seed.present');
      expect(
        presence.state.value.lastInnerThoughtSeedKey,
        'app.presence.seed.present',
      );

      locale.locale.value = AppLocale.en;
      final handoff = presence.consumeProactiveHandoff(payload);
      final prompt = handoff!.promptFor(locale: AppLocale.en);

      expect(prompt, contains('Presence cue'));
      expect(prompt, contains('present in the space'));
      expect(prompt, isNot(contains('陪伴在这个空间')));
      expect(prompt, isNot(contains('内在想法')));
    },
  );

  test(
    'presence proactive handoff is consumed only once while fresh',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
        relationshipThoughtSeed: () => 'remember the quiet launch moment',
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      final intent = presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);

      expect(intent.kind, PresenceIntentKind.spokenThought);
      expect(events, hasLength(1));

      final handoff = presence.consumeProactiveHandoff(events.single.payload);

      expect(handoff, isNotNull);
      expect(handoff!.textSeedFor(), contains('present in the space'));
      expect(presence.consumeProactiveHandoff(events.single.payload), isNull);
      expect(presence.nextProactiveHandoff(), isNull);
    },
  );

  test(
    'input activity invalidates a queued presence proactive handoff',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
        relationshipThoughtSeed: () => 'remember the user returning to chat',
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      clock.advance(const Duration(seconds: 2));
      presence.observeInputActivity(PresenceInputActivityKind.typing);

      expect(events, hasLength(1));
      expect(presence.consumeProactiveHandoff(events.single.payload), isNull);
      expect(presence.nextProactiveHandoff(), isNull);
    },
  );

  test(
    'stale presence proactive handoff expires before runtime consumes it',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
        relationshipThoughtSeed: () => 'remember an old quiet thought',
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      clock.advance(const Duration(seconds: 16));

      expect(events, hasLength(1));
      expect(presence.consumeProactiveHandoff(events.single.payload), isNull);
      expect(presence.nextProactiveHandoff(), isNull);
    },
  );

  test('presence proactive handoff payload round-trips', () {
    final createdAt = DateTime(2026, 7, 2, 15, 30);
    final handoff = PresenceProactiveHandoff(
      textSeed: 'The agent is thinking about a shared repair.',
      reason: 'quiet_daydream',
      mode: AgentPresenceMode.daydreaming.name,
      mood: AgentPresenceMoodBias.curious.name,
      attention: AgentPresenceAttention.self.name,
      arousal: 0.18,
      cooldownKey: 'daydreaming:curious',
      innerThoughtSummary: 'daydreaming/curious: shared repair',
      createdAt: createdAt,
    );

    final restored = PresenceProactiveHandoff.fromPayload(handoff.toPayload());

    expect(restored.textSeed, handoff.textSeed);
    expect(restored.reason, handoff.reason);
    expect(restored.mode, handoff.mode);
    expect(restored.mood, handoff.mood);
    expect(restored.attention, handoff.attention);
    expect(restored.arousal, handoff.arousal);
    expect(restored.cooldownKey, handoff.cooldownKey);
    expect(restored.innerThoughtSummary, handoff.innerThoughtSummary);
    expect(restored.createdAt, handoff.createdAt);
    expect(restored.prompt, contains('Presence cue'));
    expect(restored.prompt, contains('shared repair'));
    expect(restored.prompt, isNot(contains('daydreaming/curious')));
  });

  test('legacy proactive payload gains a compatible quiet candidate', () {
    final createdAt = DateTime(2026, 7, 2, 15, 30);
    final restored = PresenceProactiveHandoff.fromPayload(<String, Object?>{
      'handoffType': 'presenceProactive',
      'textSeedKey': 'app.presence.seed.present',
      'reason': 'quiet_daydream',
      'mode': 'daydreaming',
      'mood': 'calm',
      'attention': 'self',
      'arousal': 0.1,
      'cooldownKey': 'daydreaming:calm',
      'innerThoughtSummary': 'legacy summary that must not be repeated',
      'createdAt': createdAt.millisecondsSinceEpoch,
    });

    expect(restored.candidates, hasLength(1));
    expect(
      restored.candidates.single.topic.kind,
      ProactiveTopicKind.quietPresence,
    );
    expect(restored.candidates.single.topic.topicKey, 'presence.quiet');
    expect(restored.textSeedFor(), contains('present in the space'));
    expect(restored.prompt, isNot(contains('legacy summary')));
  });

  test(
    'typed proactive candidates round-trip with localized seed metadata',
    () {
      const milestoneTitle = 'fixed the balcony projector';
      final handoff = PresenceProactiveHandoff(
        textSeed: '',
        textSeedKey: 'app.presence.seed.relationship',
        textSeedParams: const <String, Object?>{
          'relationshipMoment': milestoneTitle,
        },
        candidates: const <PresenceProactiveCandidate>[
          PresenceProactiveCandidate(
            topic: ProactiveTopicCandidate(
              kind: ProactiveTopicKind.relationshipMilestone,
              topicKey: 'relationship.milestone.goal_done',
              sourceEventId: 'relationship-milestone:abc123',
              evidenceKey: 'relationship-milestone:abc123',
              textSeed: 'app.presence.seed.relationship',
              priority: 100,
            ),
            textSeedKey: 'app.presence.seed.relationship',
            textSeedParams: <String, Object?>{
              'relationshipMoment': milestoneTitle,
            },
          ),
          PresenceProactiveCandidate(
            topic: ProactiveTopicCandidate(
              kind: ProactiveTopicKind.quietPresence,
              topicKey: 'presence.quiet',
              textSeed: 'app.presence.seed.present',
              priority: 10,
            ),
            textSeedKey: 'app.presence.seed.present',
          ),
        ],
        reason: 'quiet_daydream',
        mode: 'daydreaming',
        mood: 'curious',
        attention: 'self',
        arousal: 0.18,
        cooldownKey: 'daydreaming:curious',
        innerThoughtSummary: '',
        createdAt: DateTime(2026, 7, 2, 15, 30),
      );

      final payload = handoff.toPayload();
      final restored = PresenceProactiveHandoff.fromPayload(payload);

      expect(restored.candidates, hasLength(2));
      expect(
        restored.candidates.first.identity,
        handoff.candidates.first.identity,
      );
      expect(
        restored.candidates.first.textSeedParams['relationshipMoment'],
        milestoneTitle,
      );
      expect(
        restored.promptForCandidate(restored.candidates.first),
        contains(milestoneTitle),
      );
      expect(
        restored.promptForCandidate(restored.candidates.last),
        isNot(contains(milestoneTitle)),
      );
      expect(
        restored.promptForSelected(
          const ProactiveTopicCandidate(
            kind: ProactiveTopicKind.quietPresence,
            topicKey: 'presence.quiet',
            sourceEventId: 'presence-handoff:bound-at-runtime',
            textSeed: 'app.presence.seed.present',
            priority: 10,
          ),
        ),
        contains('present in the space'),
      );
      expect(
        restored.resolveCandidate(
          const ProactiveTopicCandidate(
            kind: ProactiveTopicKind.relationshipMilestone,
            topicKey: 'relationship.milestone.goal_done',
            sourceEventId: 'relationship-milestone:wrong',
            evidenceKey: 'relationship-milestone:abc123',
            textSeed: 'app.presence.seed.relationship',
            priority: 100,
          ),
        ),
        isNull,
      );
      final serializedCandidate =
          (payload['candidates'] as List).first as Map<String, Object?>;
      expect(
        serializedCandidate['textSeedKey'],
        'app.presence.seed.relationship',
      );
      expect(serializedCandidate['textSeedParams'], <String, Object?>{
        'relationshipMoment': milestoneTitle,
      });
    },
  );

  test(
    'malformed candidate payload is tolerated without breaking legacy data',
    () {
      final restored = PresenceProactiveHandoff.fromPayload(<String, Object?>{
        'handoffType': 'presenceProactive',
        'textSeed': 'stay nearby',
        'reason': 'legacy',
        'arousal': '0.25',
        'createdAt': '2026-07-02T15:30:00.000',
        'candidates': <Object?>[
          null,
          'not-a-map',
          <String, Object?>{
            'kind': 'future_kind',
            'priority': '7',
            'textSeed': 'safe fallback',
          },
        ],
      });

      expect(restored.candidates, hasLength(1));
      expect(
        restored.candidates.single.topic.kind,
        ProactiveTopicKind.quietPresence,
      );
      expect(restored.candidates.single.topic.priority, 7);
      expect(restored.textSeedFor(), 'safe fallback');
      expect(restored.arousal, 0.25);
    },
  );

  test(
    'emit does not advance spoken cooldown until commit is acknowledged',
    () {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );
      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      presence.evaluateTick();
      final handoff = presence.nextProactiveHandoff()!;

      expect(presence.state.value.lastSpokenThoughtAt, isNull);
      clock.advance(const Duration(seconds: 30));
      expect(presence.canCommitProactiveHandoff(handoff), isTrue);
      expect(presence.acknowledgeProactiveCommitted(handoff), isTrue);
      expect(presence.state.value.lastSpokenThoughtAt, clock.call());
    },
  );

  test('user input after handoff makes a generated proactive draft stale', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(
      now: clock.call,
      runtimeBusy: () => false,
    );
    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.daydreaming,
      attention: AgentPresenceAttention.self,
      lastUserInteractionAt: clock.call().subtract(const Duration(minutes: 20)),
      lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
    );

    presence.evaluateTick();
    final handoff = presence.nextProactiveHandoff()!;
    clock.advance(const Duration(seconds: 1));
    presence.observeInputActivity(PresenceInputActivityKind.typing);

    expect(presence.canCommitProactiveHandoff(handoff), isFalse);
    expect(presence.acknowledgeProactiveCommitted(handoff), isFalse);
    expect(presence.state.value.lastSpokenThoughtAt, isNull);
  });

  test(
    'effective stage identity is stable and ignores historical milestones',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final relationship = appServices.put(RelationshipService());
      relationship.state.value = RelationshipState(
        firstMetAt: DateTime(2026, 6, 1),
        stage: RelationshipStage.friend,
        currentStreak: 99,
      );
      relationship.milestones.assignAll(<Milestone>[
        Milestone(
          id: 42,
          when: DateTime(2026, 7, 1, 9),
          type: 'goal_done',
          title: 'finished a private shared goal',
          note: 'private detail',
        ),
      ]);
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );
      final events = <SystemStatusEvent>[];
      final sub = EventBus()
          .on<SystemStatusEvent>()
          .where((event) => event.triggerType == 'presence_spoken_thought')
          .listen(events.add);
      addTearDown(sub.cancel);
      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);
      presence.nextProactiveHandoff();
      clock.advance(const Duration(seconds: 1));
      presence.evaluateTick();
      await Future<void>.delayed(Duration.zero);

      expect(events, hasLength(2));
      final first = PresenceProactiveHandoff.fromPayload(events.first.payload);
      final second = PresenceProactiveHandoff.fromPayload(events.last.payload);
      for (final index in <int>[0, 1]) {
        expect(
          second.candidates[index].topic.sourceEventId,
          first.candidates[index].topic.sourceEventId,
        );
        expect(
          second.candidates[index].topic.evidenceKey,
          first.candidates[index].topic.evidenceKey,
        );
      }
      expect(
        first.topicCandidates.map((candidate) => candidate.kind),
        isNot(contains(ProactiveTopicKind.relationshipMilestone)),
      );
      expect(
        first.toPayload().toString(),
        isNot(contains('private shared goal')),
      );
      expect(first.toPayload().toString(), isNot(contains('private detail')));
      final firstPayload = events.first.payload as Map;
      final milestonePayload =
          (firstPayload['candidates'] as List).first as Map;
      expect(
        milestonePayload['sourceEventId'],
        isNot(contains('finished a private shared goal')),
      );
      expect(
        milestonePayload['evidenceKey'],
        isNot(contains('finished a private shared goal')),
      );
      expect(
        milestonePayload['sourceEventId'],
        isNot(contains('private detail')),
      );
      expect(
        milestonePayload['evidenceKey'],
        isNot(contains('private detail')),
      );
    },
  );

  test(
    'proactive candidates use effective stage without legacy milestones or counters',
    () async {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final relationship = appServices.put(RelationshipService());
      relationship.state.value = RelationshipState(
        firstMetAt: DateTime(2026, 6, 1),
        stage: RelationshipStage.friend,
        currentStreak: 3,
      );
      relationship.milestones.assignAll([
        Milestone(
          when: DateTime(2026, 7, 1),
          type: 'goal_done',
          title: 'fixed the living-room projector',
          note: 'the user stayed with the agent through the setup',
          pinned: true,
        ),
      ]);
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );

      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.76,
        lastUserAffect: 'happy',
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastInputActivityAt: clock.call().subtract(const Duration(minutes: 2)),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      final intent = presence.evaluateTick();
      final handoff = presence.nextProactiveHandoff();

      expect(intent.kind, PresenceIntentKind.spokenThought);
      expect(
        intent.textSeed,
        isNot(contains('fixed the living-room projector')),
      );
      expect(handoff, isNotNull);
      final legacyIdentities = handoff!.candidates
          .map((candidate) => candidate.identity)
          .toList(growable: false);
      final payloadBeforeProjection = handoff.toPayload();
      final driveInput = presence.proactiveDriveInputFor(handoff);
      expect(
        handoff.topicCandidates.map((candidate) => candidate.kind),
        equals(<ProactiveTopicKind>[
          ProactiveTopicKind.relationshipStage,
          ProactiveTopicKind.recentAffect,
          ProactiveTopicKind.timeOfDay,
          ProactiveTopicKind.environmentObservation,
          ProactiveTopicKind.quietPresence,
        ]),
      );
      expect(
        driveInput.candidates.map((candidate) => candidate.kind),
        equals(<TypedProactiveCandidateKind>[
          TypedProactiveCandidateKind.relationshipStage,
          TypedProactiveCandidateKind.recentAffect,
          TypedProactiveCandidateKind.timeOfDay,
          TypedProactiveCandidateKind.environmentObservation,
          TypedProactiveCandidateKind.quietPresence,
        ]),
      );
      expect(
        driveInput.candidates.map((candidate) => candidate.originalIndex),
        equals(<int>[0, 1, 2, 3, 4]),
      );
      expect(driveInput.elapsedSinceUserActivity, const Duration(minutes: 2));
      final boundedSignals = <UnitSignal>[
        driveInput.signals.interactionSilence,
        driveInput.signals.energy,
        driveInput.signals.engagement,
        driveInput.signals.positiveAffect,
        driveInput.signals.negativeAffect,
        driveInput.signals.activation,
        driveInput.signals.selfFocus,
        driveInput.signals.defensiveRestraint,
        driveInput.signals.resting,
        driveInput.signals.attendingUser,
        for (final candidate in driveInput.candidates) ...<UnitSignal>[
          candidate.signals.salience,
          candidate.signals.userBenefit,
          candidate.signals.resolutionPotential,
        ],
      ];
      for (final signal in boundedSignals) {
        expect(signal.value, inInclusiveRange(0.0, 1.0));
      }
      expect(
        handoff.candidates.map((candidate) => candidate.identity),
        legacyIdentities,
      );
      expect(handoff.toPayload(), payloadBeforeProjection);
      expect(() => driveInput.candidates.clear(), throwsUnsupportedError);
      presence.state.value = presence.state.value.copyWith(
        lastInputActivityAt: clock.call().add(const Duration(minutes: 1)),
      );
      expect(
        presence.proactiveDriveInputFor(handoff).elapsedSinceUserActivity,
        Duration.zero,
      );
      expect(handoff.candidates.first.textSeedParams, <String, Object?>{
        'relationshipStage': 'new',
      });
      final payload = handoff.toPayload().toString();
      expect(payload, isNot(contains('relationshipStreak')));
      expect(payload, isNot(contains('daysKnown')));
      expect(payload, isNot(contains('currentStreak')));
    },
  );

  test(
    'policy revision cancels queued and generated relationship handoffs',
    () {
      final clock = _FakeClock(DateTime(2026, 7, 2, 15));
      final relationship = appServices.put(RelationshipService());
      relationship.state.value = RelationshipState(
        firstMetAt: DateTime(2026, 6, 1),
      );
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );
      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 20),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );
      presence.evaluateTick();
      final generated = presence.nextProactiveHandoff()!;
      expect(presence.canCommitProactiveHandoff(generated), isTrue);
      clock.advance(const Duration(seconds: 1));
      presence.evaluateTick();
      relationship.updateConversationPolicy(
        ConversationPolicy.fromFacts(const [], policyVersion: 1),
      );
      expect(presence.nextProactiveHandoff(), isNull);
      expect(presence.canCommitProactiveHandoff(generated), isFalse);
      expect(presence.acknowledgeProactiveCommitted(generated), isFalse);
    },
  );

  test('prompt context allows one follow-up only for active conversation', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(now: clock.call);

    presence.observeUserTurn('第一句');
    clock.advance(const Duration(seconds: 10));
    presence.observeUserTurn('第二句');
    clock.advance(const Duration(seconds: 10));
    presence.observeUserTurn('第三句');

    final context = presence.conversationPromptContext();

    expect(context, contains('Presence conversation state'));
    expect(context, contains('Conversation arousal: high'));
    expect(context, contains('You may ask one concise follow-up'));
    expect(context, isNot(contains('ask multiple questions')));
  });

  test('sleepy user emotion suppresses follow-up pressure', () {
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(now: clock.call);

    presence.observeUserTurn('第一句');
    clock.advance(const Duration(seconds: 10));
    presence.observeUserTurn('第二句');
    presence.observeSystemStatus(
      SystemStatusEvent('user_emotion_sleepy', payload: {'transition': true}),
    );

    final context = presence.conversationPromptContext();

    expect(presence.state.value.moodBias, AgentPresenceMoodBias.sleepy);
    expect(context, contains('avoid pushing more questions'));
  });

  test('registered config changes active thresholds and cooldowns', () {
    final cfg = appServices.put(AgentBehaviorConfig());
    cfg.setParam('presenceActiveTurnThreshold', 2);
    cfg.setParam('presenceFollowUpCooldown', 300);
    final clock = _FakeClock(DateTime(2026, 7, 2, 15));
    final presence = AgentPresenceService(now: clock.call);

    presence.observeUserTurn('第一句');
    clock.advance(const Duration(seconds: 8));
    presence.observeUserTurn('第二句');

    expect(presence.state.value.conversationArousal, greaterThanOrEqualTo(0.7));
    expect(presence.conversationPromptContext(), contains('follow-up'));
    presence.markFollowUpAsked();
    expect(
      presence.conversationPromptContext(),
      contains('Do not ask a follow-up this turn'),
    );
  });
}

class _FakeClock {
  _FakeClock(this._now);

  DateTime _now;

  DateTime call() => _now;

  void advance(Duration duration) {
    _now = _now.add(duration);
  }
}

class _MemorySecureStorageService extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<bool> write(String key, String? value) async => true;
}

class _PausedPresenceGaze implements AvatarGazeIntentHandler {
  final started = Completer<void>();
  final resume = Completer<void>();

  @override
  Future<void> hold(AvatarGaze? gaze, {required Duration duration}) async {
    if (!started.isCompleted) {
      started.complete();
      await resume.future;
    }
  }
}

class _PresenceRuntime extends AvatarRuntime {
  @override
  final backendKind = AvatarBackendKind.unity;
  @override
  final isReady = true.obs;
  int bodyWrites = 0;

  @override
  Future<void> setHandIkTarget(
    String target, [
    Map<String, dynamic>? opts,
  ]) async {
    bodyWrites++;
  }

  @override
  Future<void> playPrimitive(String type, [Map<String, dynamic>? opts]) async {
    bodyWrites++;
  }

  @override
  Future<void> playMotion(String type, [Map<String, dynamic>? opts]) async {
    bodyWrites++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _RecordingPresenceDirector extends AvatarBehaviorDirector {
  AvatarAct? lastAct;
  AvatarReaction? lastReaction;
  int applyCount = 0;
  bool? lastAmbient;
  bool succeeds = true;

  @override
  Future<AvatarBehaviorResult> applyAct(
    AvatarAct act, {
    bool ambient = false,
    bool Function()? shouldContinue,
  }) async {
    applyCount += 1;
    lastAmbient = ambient;
    lastAct = act;
    return AvatarBehaviorResult(
      applied: succeeds,
      reason: 'recorded',
      mood: act.mood,
      primitive: act.gesture,
    );
  }

  @override
  Future<AvatarBehaviorResult> applyReaction(
    AvatarReaction reaction, {
    bool ambient = false,
    bool Function()? shouldContinue,
  }) async {
    applyCount += 1;
    lastAmbient = ambient;
    lastReaction = reaction;
    return AvatarBehaviorResult(
      applied: succeeds,
      reason: 'recorded',
      mood: reaction.mood,
      primitive: reaction.gesture,
    );
  }
}
