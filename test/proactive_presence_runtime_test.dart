import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_drive_shadow_service.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/agent_initiated_response.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  var ttsSpeakCalls = 0;

  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('flutter_tts'), (
        call,
      ) async {
        switch (call.method) {
          case 'getLanguages':
            return <String>['en-US'];
          case 'getVoices':
            return <Object>[];
          case 'speak':
            ttsSpeakCalls++;
            return 1;
          case 'setLanguage':
          case 'setSpeechRate':
          case 'setVolume':
          case 'setPitch':
          case 'awaitSpeakCompletion':
          case 'stop':
            return 1;
          default:
            return null;
        }
      });

  setUp(() => ttsSpeakCalls = 0);

  for (final observationFails in <bool>[false, true]) {
    test('presence commits once with shadow observation '
        '${observationFails ? 'failure' : 'success'}', () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'proactive-presence-runtime-$observationFails.db',
      );
      final ledger = ProactiveOutreachLedger(
        accountDatabase: database,
        idFactory: () => 'presence-runtime-outreach',
      );
      final coordinator = ProactiveOutreachCoordinator(
        policy: const ProactiveCompanionPolicy(
          config: ProactivePolicyConfig(
            foregroundDailyLimit: 3,
            minimumGlobalGap: Duration.zero,
            maximumDeterministicJitter: Duration.zero,
            genericTopicCooldown: Duration.zero,
            quietStartMinutes: 0,
            quietEndMinutes: 0,
          ),
        ),
        ledger: ledger,
        accountKey: 'account:presence-runtime',
      );
      final clock = _MutableClock(DateTime(2026, 8, 26, 15));
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );
      final featureFlags = await MaasoFeatureFlagService(
        store: SembastMaasoFeatureFlagAssignmentStore(database),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
        },
        clock: clock.call,
      ).init();
      await featureFlags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.shadow,
        revision: 1,
        expiresAt: clock.call().add(const Duration(hours: 1)),
      );
      final driveShadow = ProactiveDriveShadowService(
        featureFlags: featureFlags,
        observationHook: observationFails
            ? () => throw StateError('injected_shadow_observation_failure')
            : null,
      );
      final feedback = await OutreachFeedbackCollector(
        accountDatabase: database,
        ledger: ledger,
        featureFlags: featureFlags,
        clock: clock.call,
      ).init();
      appServices.put<DBService>(database);
      appServices.put<MaasoFeatureFlagService>(featureFlags);
      appServices.put<ProactiveDriveShadowService>(driveShadow);
      appServices.put<OutreachFeedbackCollector>(feedback);
      appServices.put<ProactiveOutreachLedger>(ledger);
      appServices.put<ProactiveOutreachCoordinator>(coordinator);
      appServices.put<AgentPresenceService>(presence);
      final llm = _StructuredReplyLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      final legacy = <String>[];
      final legacySub = runtime.onProactiveResponse.listen(legacy.add);

      addTearDown(() async {
        await legacySub.cancel();
        await runtime.retireAndDrain();
        await feedback.deactivateAndDrain();
        await database.close();
        appServices.reset();
      });
      await runtime.init(enabledSkillIds: const <String>{});
      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.8,
        lastUserInteractionAt: clock.call().subtract(
          const Duration(minutes: 30),
        ),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      final responseFuture = runtime.onCommittedProactiveResponse.first.timeout(
        const Duration(seconds: 5),
      );
      final intent = presence.evaluateTick();
      final response = await responseFuture;
      await Future<void>.delayed(Duration.zero);
      if (!observationFails) {
        await _waitUntil(
          () async =>
              driveShadow.state.value.samples == 1 &&
              driveShadow.state.value.evaluations == 1,
        );
      }

      expect(intent.kind, PresenceIntentKind.spokenThought);
      expect(response.text, '窗边安静下来，我也在这里陪你。');
      expect(response.outreachId, 'outreach-presence-runtime-outreach');
      expect(legacy, isEmpty);
      expect(llm.chatCalls, 1);

      final messages = await database.getMessages('self');
      expect(messages, hasLength(1));
      expect(messages.single.content, response.text);
      expect(
        messages.single.turnOrigin,
        ChatMessageTurnOrigins.proactivePresence,
      );
      expect(messages.single.outreachId, response.outreachId);
      expect(
        messages.single.idempotencyKey,
        'proactive:${response.outreachId}',
      );
      expect(messages.single.content, isNot(startsWith('🌱 ')));

      final records = await ledger.recent();
      expect(records, hasLength(1));
      expect(records.single.state, OutreachState.delivered);
      await feedback.waitForIdle();
      expect(
        (await feedback.get(response.outreachId))?.deliveredAt,
        records.single.deliveredAt,
      );
      expect(feedback.state.value.pending, 1);
      expect(feedback.state.value.events[OutreachFeedbackSignal.delivered], 1);
      await feedback.deactivateAndDrain();
      final restoredFeedback = await OutreachFeedbackCollector(
        accountDatabase: database,
        ledger: ledger,
        featureFlags: featureFlags,
        clock: clock.call,
      ).init();
      expect(restoredFeedback.state.value.pending, 1);
      expect(
        restoredFeedback.state.value.events[OutreachFeedbackSignal.delivered],
        1,
      );
      expect(
        (await restoredFeedback.get(response.outreachId))?.deliveredAt,
        records.single.deliveredAt,
      );
      expect(restoredFeedback.posterior.availableMass, 1);
      expect(restoredFeedback.posterior.unavailableMass, 4);
      await restoredFeedback.deactivateAndDrain();
      expect(presence.state.value.lastSpokenThoughtAt, isNotNull);
      expect(driveShadow.state.value.samples, observationFails ? 0 : 1);
      expect(driveShadow.state.value.errors, 0);
      expect(driveShadow.state.value.scoringErrors, 0);
      if (!observationFails) {
        expect(driveShadow.state.value.evaluations, 1);
        expect(
          driveShadow.state.value.comparisons.values.fold(
            0,
            (total, count) => total + count,
          ),
          1,
        );
        expect(
          driveShadow.state.value.selectedKinds.values.fold(
            0,
            (total, count) => total + count,
          ),
          1,
        );
        expect(
          driveShadow.state.value.outcomes[ProactivePreparationStatus.ready],
          1,
        );
      } else {
        expect(driveShadow.state.value.evaluations, 0);
      }
    });
  }

  test('legacy hard gate stays silent even when shadow scoring runs', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'proactive-presence-shadow-hard-gate.db',
    );
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      idFactory: () => 'shadow-hard-gate-outreach',
    );
    final clock = _MutableClock(DateTime(2026, 8, 26, 15));
    final coordinator = ProactiveOutreachCoordinator(
      policy: const ProactiveCompanionPolicy(
        config: ProactivePolicyConfig(
          foregroundDailyLimit: 0,
          minimumGlobalGap: Duration.zero,
          maximumDeterministicJitter: Duration.zero,
          genericTopicCooldown: Duration.zero,
          quietStartMinutes: 0,
          quietEndMinutes: 0,
        ),
      ),
      ledger: ledger,
      accountKey: 'account:shadow-hard-gate',
      clock: clock.call,
    );
    final presence = AgentPresenceService(
      now: clock.call,
      runtimeBusy: () => false,
    );
    final featureFlags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: clock.call,
    ).init();
    await featureFlags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: clock.call().add(const Duration(hours: 1)),
    );
    final driveShadow = ProactiveDriveShadowService(featureFlags: featureFlags);
    appServices.put<DBService>(database);
    appServices.put<MaasoFeatureFlagService>(featureFlags);
    appServices.put<ProactiveDriveShadowService>(driveShadow);
    appServices.put<ProactiveOutreachLedger>(ledger);
    appServices.put<ProactiveOutreachCoordinator>(coordinator);
    appServices.put<AgentPresenceService>(presence);
    final llm = _StructuredReplyLlm();
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: llm,
    );
    final committed = <AgentInitiatedResponse>[];
    final committedSub = runtime.onCommittedProactiveResponse.listen(
      committed.add,
    );
    addTearDown(() async {
      await committedSub.cancel();
      await runtime.retireAndDrain();
      await database.close();
      appServices.reset();
    });
    await runtime.init(enabledSkillIds: const <String>{});
    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.daydreaming,
      attention: AgentPresenceAttention.self,
      energy: 0.8,
      lastUserInteractionAt: clock.call().subtract(const Duration(minutes: 30)),
      lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
    );

    final intent = presence.evaluateTick();
    await _waitUntil(
      () async =>
          driveShadow.state.value.samples == 1 &&
          driveShadow.state.value.evaluations == 1,
    );

    expect(intent.kind, PresenceIntentKind.spokenThought);
    expect(
      driveShadow.state.value.outcomes[ProactivePreparationStatus.silenced],
      1,
    );
    expect(
      driveShadow.state.value.comparisons.values.fold(
        0,
        (total, count) => total + count,
      ),
      1,
    );
    expect(llm.chatCalls, 0);
    expect(ttsSpeakCalls, 0);
    expect(committed, isEmpty);
    expect(await database.getMessages('self'), isEmpty);
    expect(await ledger.recent(), isEmpty);
    expect(presence.state.value.lastSpokenThoughtAt, isNull);
  });

  for (final scenario in <({String name, String draft})>[
    (name: 'single Han character', draft: '好'),
    (name: 'single Latin character', draft: 'A'),
    (name: 'emoji only', draft: '🙂'),
    (name: 'single punctuation mark', draft: '。'),
  ]) {
    test(
      'presence rejects ${scenario.name} before the visible commit',
      () async {
        final database = await DBService().init(
          factory: databaseFactoryMemory,
          path: 'proactive-presence-unpresentable-${scenario.name}.db',
        );
        final ledger = ProactiveOutreachLedger(
          accountDatabase: database,
          idFactory: () => 'presence-unpresentable-${scenario.name}',
        );
        final clock = _MutableClock(DateTime(2026, 8, 26, 15));
        final coordinator = ProactiveOutreachCoordinator(
          policy: const ProactiveCompanionPolicy(
            config: ProactivePolicyConfig(
              foregroundDailyLimit: 3,
              minimumGlobalGap: Duration.zero,
              maximumDeterministicJitter: Duration.zero,
              genericTopicCooldown: Duration.zero,
              quietStartMinutes: 0,
              quietEndMinutes: 0,
            ),
          ),
          ledger: ledger,
          accountKey: 'account:presence-unpresentable',
          clock: clock.call,
        );
        final presence = AgentPresenceService(
          now: clock.call,
          runtimeBusy: () => false,
        );
        appServices.put<DBService>(database);
        appServices.put<ProactiveOutreachLedger>(ledger);
        appServices.put<ProactiveOutreachCoordinator>(coordinator);
        appServices.put<AgentPresenceService>(presence);
        final runtime = AgentRuntime(
          agentId: 'self',
          profile: _profile(),
          llmClient: _StructuredReplyLlm(reply: scenario.draft),
        );
        final committed = <AgentInitiatedResponse>[];
        final committedSub = runtime.onCommittedProactiveResponse.listen(
          committed.add,
        );
        addTearDown(() async {
          await committedSub.cancel();
          await runtime.retireAndDrain();
          await database.close();
          appServices.reset();
        });
        await runtime.init(enabledSkillIds: const <String>{});
        presence.state.value = presence.state.value.copyWith(
          mode: AgentPresenceMode.daydreaming,
          attention: AgentPresenceAttention.self,
          energy: 0.8,
          lastUserInteractionAt: clock.call().subtract(
            const Duration(minutes: 30),
          ),
          lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
        );

        expect(presence.evaluateTick().kind, PresenceIntentKind.spokenThought);
        await _waitUntil(() async {
          final records = await ledger.recent();
          return records.length == 1 &&
              records.single.state == OutreachState.abandoned;
        });

        expect(committed, isEmpty);
        expect(ttsSpeakCalls, 0);
        expect(await database.getMessages('self'), isEmpty);
        final records = await ledger.recent();
        expect(records.single.terminalReason, 'generation_not_committed');
        expect(presence.state.value.lastSpokenThoughtAt, isNull);
      },
    );
  }

  for (final scenario in <({String name, bool retire})>[
    (name: 'user cancellation', retire: false),
    (name: 'runtime retirement', retire: true),
  ]) {
    test(
      'commit-to-TTS ${scenario.name} preserves committed-undelivered evidence',
      () async {
        final database = await DBService().init(
          factory: databaseFactoryMemory,
          path: 'proactive-presence-committed-${scenario.retire}.db',
        );
        final ledger = ProactiveOutreachLedger(
          accountDatabase: database,
          idFactory: () => 'presence-committed-${scenario.retire}',
        );
        final clock = _MutableClock(DateTime(2026, 8, 26, 15));
        final coordinator = ProactiveOutreachCoordinator(
          policy: const ProactiveCompanionPolicy(
            config: ProactivePolicyConfig(
              foregroundDailyLimit: 3,
              minimumGlobalGap: Duration.zero,
              maximumDeterministicJitter: Duration.zero,
              genericTopicCooldown: Duration.zero,
              quietStartMinutes: 0,
              quietEndMinutes: 0,
            ),
          ),
          ledger: ledger,
          accountKey: 'account:presence-committed',
        );
        final presence = AgentPresenceService(
          now: clock.call,
          runtimeBusy: () => false,
        );
        appServices.put<DBService>(database);
        appServices.put<ProactiveOutreachLedger>(ledger);
        appServices.put<ProactiveOutreachCoordinator>(coordinator);
        appServices.put<AgentPresenceService>(presence);
        final prepareStarted = Completer<void>();
        final releasePrepare = Completer<void>();
        final prepareReturned = Completer<void>();
        final runtime = AgentRuntime(
          agentId: 'self',
          profile: _profile(),
          llmClient: _StructuredReplyLlm(),
          prepareTtsForNewTurn: (_) async {
            prepareStarted.complete();
            await releasePrepare.future;
            prepareReturned.complete();
          },
        );
        final committed = <AgentInitiatedResponse>[];
        final committedSub = runtime.onCommittedProactiveResponse.listen(
          committed.add,
        );
        addTearDown(() async {
          await committedSub.cancel();
          await runtime.retireAndDrain();
          await database.close();
          appServices.reset();
        });
        await runtime.init(enabledSkillIds: const <String>{});
        presence.state.value = presence.state.value.copyWith(
          mode: AgentPresenceMode.daydreaming,
          attention: AgentPresenceAttention.self,
          energy: 0.8,
          lastUserInteractionAt: clock.call().subtract(
            const Duration(minutes: 30),
          ),
          lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
        );

        presence.evaluateTick();
        await prepareStarted.future.timeout(const Duration(seconds: 5));
        expect((await ledger.recent()).single.state, OutreachState.committed);
        expect(await database.getMessages('self'), hasLength(1));

        if (scenario.retire) {
          var drainCompleted = false;
          final drain = runtime.retireAndDrain().whenComplete(
            () => drainCompleted = true,
          );
          await Future<void>.delayed(Duration.zero);
          expect(drainCompleted, isFalse);
          releasePrepare.complete();
          await drain.timeout(const Duration(seconds: 5));
        } else {
          runtime.cancelCurrent();
          releasePrepare.complete();
          await prepareReturned.future.timeout(const Duration(seconds: 5));
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }

        expect(committed, isEmpty);
        expect(ttsSpeakCalls, 0);
        final records = await ledger.recent();
        expect(records, hasLength(1));
        expect(records.single.state, OutreachState.committed);
        expect(records.single.deliveredAt, isNull);
        expect(records.single.terminalReason, isNull);
        expect(await database.getMessages('self'), hasLength(1));
        expect(presence.state.value.lastSpokenThoughtAt, isNull);
        if (!scenario.retire) {
          await runtime.retireAndDrain().timeout(const Duration(seconds: 5));
        }
      },
    );
  }

  test(
    'duplicate proactive notification taps claim once before generation',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'proactive-notification-interaction-runtime.db',
      );
      final ledger = ProactiveOutreachLedger(
        accountDatabase: database,
        idFactory: () => 'notification-interaction-runtime',
      );
      final coordinator = ProactiveOutreachCoordinator(
        policy: const ProactiveCompanionPolicy(
          config: ProactivePolicyConfig(
            foregroundDailyLimit: 3,
            minimumGlobalGap: Duration.zero,
            maximumDeterministicJitter: Duration.zero,
            genericTopicCooldown: Duration.zero,
            quietStartMinutes: 0,
            quietEndMinutes: 0,
          ),
        ),
        ledger: ledger,
        accountKey: 'account:notification-interaction-runtime',
      );
      final now = DateTime.now();
      const deliveryId =
          'proactive:v3:test.account-a:morning:notification-runtime';
      const sourceEventId = 'os:v3:test.account-a:morning:notification-runtime';
      final scheduled = await coordinator.scheduleOsOccurrence(
        sourceEventId: sourceEventId,
        deliveryId: deliveryId,
        topicKey: 'presence.time.morning',
        scheduledFor: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        requestedDailyBudgetLimit: 3,
        now: now.subtract(const Duration(minutes: 2)),
      );
      final featureFlags = await MaasoFeatureFlagService(
        store: SembastMaasoFeatureFlagAssignmentStore(database),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
        },
        clock: () => now,
      ).init();
      await featureFlags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.shadow,
        revision: 1,
        expiresAt: now.add(const Duration(hours: 1)),
      );
      final feedback = await OutreachFeedbackCollector(
        accountDatabase: database,
        ledger: ledger,
        featureFlags: featureFlags,
        clock: () => now,
      ).init();
      appServices.put<DBService>(database);
      appServices.put<MaasoFeatureFlagService>(featureFlags);
      appServices.put<OutreachFeedbackCollector>(feedback);
      appServices.put<ProactiveOutreachLedger>(ledger);
      appServices.put<ProactiveOutreachCoordinator>(coordinator);
      final llm = _StructuredReplyLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(() async {
        await runtime.retireAndDrain();
        await feedback.deactivateAndDrain();
        await database.close();
        appServices.reset();
      });
      await runtime.init(enabledSkillIds: const <String>{});
      final event = SystemStatusEvent(
        'notification_opened',
        payload: <String, Object?>{
          'deliveryId': deliveryId,
          'kind': 'morning_greeting',
          'prompt': '简短自然地回应这次早安互动。',
          'source': 'notification_interaction',
          'outreachId': scheduled!.outreachId,
          'sourceEventId': sourceEventId,
        },
      );
      final response = runtime.onProactiveResponse.first.timeout(
        const Duration(seconds: 5),
      );

      EventBus().fire(event);
      EventBus().fire(event);

      expect(await response, '窗边安静下来，我也在这里陪你。');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(llm.chatCalls, 1);
      expect(
        (await ledger.get(
          scheduled.outreachId,
        ))?.notificationInteractionClaimedAt,
        isNotNull,
      );
      await feedback.waitForIdle();
      expect((await feedback.get(scheduled.outreachId))?.openedAt, isNotNull);

      EventBus().fire(event);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(llm.chatCalls, 1);

      await feedback.deactivateAndDrain();
      final restoredFeedback = await OutreachFeedbackCollector(
        accountDatabase: database,
        ledger: ledger,
        featureFlags: featureFlags,
        clock: () => now,
      ).init();
      expect(
        restoredFeedback.state.value.events[OutreachFeedbackSignal.opened],
        1,
      );
      expect(
        (await restoredFeedback.get(scheduled.outreachId))?.openedAt,
        isNotNull,
      );
      await restoredFeedback.deactivateAndDrain();
    },
  );

  test(
    'hard mute during foreground generation blocks commit event and TTS',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'proactive-presence-hard-mute.db',
      );
      final preferences = await ProactivePreferenceService(
        store: SembastProactivePreferenceStore(
          database,
          accountScopeDigest: 'a' * 64,
        ),
        accountScopeDigest:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
        generation: 1,
      ).init();
      await preferences.setContactAgreement(
        enabled: true,
        scope: ProactiveConversationScope.everyday,
      );
      final ledger = ProactiveOutreachLedger(
        accountDatabase: database,
        idFactory: () => 'presence-hard-mute',
      );
      final clock = _MutableClock(DateTime(2026, 8, 26, 15));
      final coordinator = ProactiveOutreachCoordinator(
        policy: ProactivePreferencePolicyAdapter(preferences),
        ledger: ledger,
        accountKey: 'account:presence-hard-mute',
        clock: clock.call,
      );
      final presence = AgentPresenceService(
        now: clock.call,
        runtimeBusy: () => false,
      );
      appServices.put<DBService>(database);
      appServices.put<ProactivePreferenceService>(preferences);
      appServices.put<ProactiveOutreachLedger>(ledger);
      appServices.put<ProactiveOutreachCoordinator>(coordinator);
      appServices.put<AgentPresenceService>(presence);
      appServices.put(AgentTaskJobStore());
      final llm = _DeferredFirstReplyLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      final committed = <AgentInitiatedResponse>[];
      final committedSub = runtime.onCommittedProactiveResponse.listen(
        committed.add,
      );
      addTearDown(() async {
        await committedSub.cancel();
        await runtime.retireAndDrain();
        await database.close();
        appServices.reset();
      });
      await runtime.init(enabledSkillIds: const <String>{});
      presence.state.value = presence.state.value.copyWith(
        mode: AgentPresenceMode.daydreaming,
        attention: AgentPresenceAttention.self,
        energy: 0.8,
        lastUserInteractionAt: clock.call().subtract(const Duration(hours: 2)),
        lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
      );

      presence.evaluateTick();
      await llm.firstRequestStarted.future.timeout(const Duration(seconds: 5));
      await preferences.setHardMuted(true);
      llm.firstReply.complete('{"reply":"这条主动消息不应出现。","actions":[]}');
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(llm.chatCalls, 1);
      expect(committed, isEmpty);
      expect(ttsSpeakCalls, 0);
      expect(await database.getMessages('self'), isEmpty);
      final records = await ledger.recent();
      expect(records, hasLength(1));
      expect(records.single.state, OutreachState.abandoned);
      expect(presence.state.value.lastSpokenThoughtAt, isNull);
    },
  );

  test(
    'notification claim waiting on storage never preempts a newer user turn',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'proactive-notification-user-race.db',
      );
      final ledger = ProactiveOutreachLedger(
        accountDatabase: database,
        idFactory: () => 'notification-user-race',
      );
      final coordinator = ProactiveOutreachCoordinator(
        policy: const ProactiveCompanionPolicy(
          config: ProactivePolicyConfig(
            foregroundDailyLimit: 3,
            minimumGlobalGap: Duration.zero,
            maximumDeterministicJitter: Duration.zero,
            genericTopicCooldown: Duration.zero,
            quietStartMinutes: 0,
            quietEndMinutes: 0,
          ),
        ),
        ledger: ledger,
        accountKey: 'account:notification-user-race',
      );
      final now = DateTime.now();
      const deliveryId = 'proactive:v3:test.account-a:morning:user-race';
      const sourceEventId = 'os:v3:test.account-a:morning:user-race';
      final scheduled = await coordinator.scheduleOsOccurrence(
        sourceEventId: sourceEventId,
        deliveryId: deliveryId,
        topicKey: 'presence.time.morning',
        scheduledFor: now.subtract(const Duration(minutes: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        requestedDailyBudgetLimit: 3,
        now: now.subtract(const Duration(minutes: 2)),
      );
      appServices.put<ProactiveOutreachCoordinator>(coordinator);
      appServices.put(AgentTaskJobStore());
      final llm = _DeferredUserThenNotificationLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(() async {
        await runtime.retireAndDrain();
        await database.close();
        appServices.reset();
      });
      await runtime.init(enabledSkillIds: const <String>{});

      final transactionStarted = Completer<void>();
      final releaseTransaction = Completer<void>();
      final storageBlock = database.raw.transaction((_) async {
        transactionStarted.complete();
        await releaseTransaction.future;
      });
      await transactionStarted.future;

      final event = SystemStatusEvent(
        'notification_opened',
        payload: <String, Object?>{
          'deliveryId': deliveryId,
          'kind': 'morning_greeting',
          'prompt': '简短自然地回应这次早安互动。',
          'source': 'notification_interaction',
          'outreachId': scheduled!.outreachId,
          'sourceEventId': sourceEventId,
        },
      );
      final notificationResponse = runtime.onProactiveResponse.first.timeout(
        const Duration(seconds: 5),
      );
      EventBus().fire(event);
      await Future<void>.delayed(Duration.zero);

      final userTurn = runtime.chat('先听我说', const <Message>[]);
      await llm.firstRequestStarted.future.timeout(const Duration(seconds: 5));
      releaseTransaction.complete();
      await storageBlock;
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(llm.chatCalls, 1);
      expect(runtime.turn.isProcessing, isTrue);
      expect(
        (await ledger.get(
          scheduled.outreachId,
        ))?.notificationInteractionClaimedAt,
        isNotNull,
      );

      llm.userReply.complete('{"reply":"用户回合完成。","actions":[]}');
      final userResult = await userTurn.timeout(const Duration(seconds: 5));
      expect(userResult.isSuccess, isTrue);
      expect(userResult.stdout, '用户回合完成。');
      expect(await notificationResponse, '通知回合完成。');
      expect(llm.chatCalls, 2);
    },
  );

  test('cancelled presence drains before a newer user turn starts', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'proactive-presence-preemption.db',
    );
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      idFactory: () => 'presence-preemption',
    );
    final coordinator = ProactiveOutreachCoordinator(
      policy: const ProactiveCompanionPolicy(
        config: ProactivePolicyConfig(
          foregroundDailyLimit: 3,
          minimumGlobalGap: Duration.zero,
          maximumDeterministicJitter: Duration.zero,
          genericTopicCooldown: Duration.zero,
          quietStartMinutes: 0,
          quietEndMinutes: 0,
        ),
      ),
      ledger: ledger,
      accountKey: 'account:presence-preemption',
    );
    final clock = _MutableClock(DateTime(2026, 8, 26, 15));
    final presence = AgentPresenceService(
      now: clock.call,
      runtimeBusy: () => false,
    );
    appServices.put<DBService>(database);
    appServices.put<ProactiveOutreachLedger>(ledger);
    appServices.put<ProactiveOutreachCoordinator>(coordinator);
    appServices.put<AgentPresenceService>(presence);
    appServices.put(AgentTaskJobStore());
    final llm = _DeferredFirstReplyLlm();
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: llm,
    );
    final committed = <Object>[];
    final committedSub = runtime.onCommittedProactiveResponse.listen(
      committed.add,
    );

    addTearDown(() async {
      await committedSub.cancel();
      await runtime.retireAndDrain();
      await database.close();
      appServices.reset();
    });
    await runtime.init(enabledSkillIds: const <String>{});
    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.daydreaming,
      attention: AgentPresenceAttention.self,
      energy: 0.8,
      lastUserInteractionAt: clock.call().subtract(const Duration(minutes: 30)),
      lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
    );

    presence.evaluateTick();
    await llm.firstRequestStarted.future.timeout(const Duration(seconds: 5));
    runtime.cancelCurrent();
    expect(runtime.turn.isProcessing, isFalse);

    final userTurn = runtime.chat('现在先听我说', const <Message>[]);
    final result = await userTurn.timeout(const Duration(seconds: 5));
    expect(llm.chatCalls, 2);

    llm.firstReply.complete('{"reply":"这条旧主动消息不能出现。","actions":[]}');
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(result.isSuccess, isTrue);
    expect(result.stdout, '我在听。');
    expect(committed, isEmpty);
    expect(await database.getMessages('self'), isEmpty);
    final records = await ledger.recent();
    expect(records, hasLength(1));
    expect(records.single.state, OutreachState.abandoned);
    expect(records.single.terminalReason, 'user_preempted');
    expect(presence.state.value.lastSpokenThoughtAt, isNull);
    expect(runtime.turn.isProcessing, isFalse);
  });

  test(
    'cancelled user turn releases immediately and cannot reset its successor',
    () async {
      appServices.put(AgentTaskJobStore());
      final llm = _DeferredFirstReplyLlm();
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: llm,
      );
      addTearDown(() async {
        await runtime.retireAndDrain();
        appServices.reset();
      });
      await runtime.init(enabledSkillIds: const <String>{});

      final cancelledTurn = runtime.chat('先处理这条慢请求', const <Message>[]);
      await llm.firstRequestStarted.future.timeout(const Duration(seconds: 5));

      runtime.cancelCurrent();
      expect(runtime.turn.isProcessing, isFalse);

      final successor = await runtime
          .chat('现在回答这一条', const <Message>[])
          .timeout(const Duration(seconds: 5));
      expect(successor.isSuccess, isTrue);
      expect(successor.stdout, '我在听。');
      expect(runtime.turn.isProcessing, isFalse);

      llm.firstReply.complete('{"reply":"迟到的旧回答。","actions":[]}');
      await cancelledTurn.timeout(const Duration(seconds: 5));
      expect(runtime.turn.isProcessing, isFalse);
      expect(llm.chatCalls, 2);
    },
  );

  test('retiring runtime rejects a late presence event', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'proactive-presence-retirement.db',
    );
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      idFactory: () => 'presence-retirement',
    );
    final coordinator = ProactiveOutreachCoordinator(
      policy: const ProactiveCompanionPolicy(
        config: ProactivePolicyConfig(
          foregroundDailyLimit: 3,
          minimumGlobalGap: Duration.zero,
          maximumDeterministicJitter: Duration.zero,
          genericTopicCooldown: Duration.zero,
          quietStartMinutes: 0,
          quietEndMinutes: 0,
        ),
      ),
      ledger: ledger,
      accountKey: 'account:presence-retirement',
    );
    final clock = _MutableClock(DateTime(2026, 8, 26, 15));
    final presence = AgentPresenceService(
      now: clock.call,
      runtimeBusy: () => false,
    );
    appServices.put<DBService>(database);
    appServices.put<ProactiveOutreachLedger>(ledger);
    appServices.put<ProactiveOutreachCoordinator>(coordinator);
    appServices.put<AgentPresenceService>(presence);
    appServices.put(AgentTaskJobStore());
    final llm = _DeferredFirstReplyLlm();
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: llm,
    );
    addTearDown(() async {
      await runtime.retireAndDrain();
      await database.close();
      appServices.reset();
    });
    await runtime.init(enabledSkillIds: const <String>{});

    final activeTurn = runtime.chat('保持一个进行中的请求', const <Message>[]);
    await llm.firstRequestStarted.future.timeout(const Duration(seconds: 5));
    final retirement = runtime.retireAndDrain();

    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.daydreaming,
      attention: AgentPresenceAttention.self,
      energy: 0.8,
      lastUserInteractionAt: clock.call().subtract(const Duration(minutes: 30)),
      lastSignalAt: clock.call().subtract(const Duration(minutes: 10)),
    );
    expect(presence.evaluateTick().kind, PresenceIntentKind.spokenThought);
    await Future<void>.delayed(Duration.zero);

    expect(await ledger.recent(), isEmpty);
    expect(llm.chatCalls, 1);
    expect(runtime.turn.isProcessing, isFalse);

    llm.firstReply.complete('{"reply":"退役后的旧回答。","actions":[]}');
    await activeTurn.timeout(const Duration(seconds: 5));
    await retirement.timeout(const Duration(seconds: 5));
    expect(await ledger.recent(), isEmpty);
  });
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

final class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}

final class _StructuredReplyLlm implements LLMClient {
  _StructuredReplyLlm({this.reply = '窗边安静下来，我也在这里陪你。'});

  final String reply;
  int chatCalls = 0;

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    chatCalls += 1;
    return jsonEncode(<String, Object?>{
      'reply': reply,
      'actions': const <Object?>[],
    });
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream<String>.empty();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => const Stream<LLMStreamEvent>.empty();
}

Future<void> _waitUntil(
  Future<bool> Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!await predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

final class _DeferredFirstReplyLlm implements LLMClient {
  int chatCalls = 0;
  final firstRequestStarted = Completer<void>();
  final firstReply = Completer<String>();

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    chatCalls += 1;
    if (chatCalls == 1) {
      firstRequestStarted.complete();
      return firstReply.future;
    }
    return Future<String>.value('{"reply":"我在听。","actions":[]}');
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream<String>.empty();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => const Stream<LLMStreamEvent>.empty();
}

final class _DeferredUserThenNotificationLlm implements LLMClient {
  int chatCalls = 0;
  final firstRequestStarted = Completer<void>();
  final userReply = Completer<String>();

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) {
    chatCalls += 1;
    if (chatCalls == 1) {
      firstRequestStarted.complete();
      return userReply.future;
    }
    return Future<String>.value('{"reply":"通知回合完成。","actions":[]}');
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw UnsupportedError('not used');

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      const Stream<String>.empty();

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) => const Stream<LLMStreamEvent>.empty();
}
