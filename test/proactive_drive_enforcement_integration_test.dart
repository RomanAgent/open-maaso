import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_drive_rollout_service.dart';
import 'package:maaso/src/core/services/proactive_drive_shadow_service.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
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
            return <Map<String, String>>[
              <String, String>{
                'name': 'test-local-voice',
                'locale': 'zh-CN',
                'network_required': '0',
                'features': '',
              },
            ];
          case 'speak':
            ttsSpeakCalls++;
            return 1;
          case 'setLanguage':
          case 'setVoice':
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

  setUp(() {
    resetAppProviderContainerForTest();
    ttsSpeakCalls = 0;
  });
  tearDown(resetAppProviderContainerForTest);

  test(
    'enforce hold stops before reserve, model, message, and speech',
    () async {
      final harness = await _Harness.create(contactPolicy: (_) => false);
      addTearDown(harness.dispose);

      expect(
        harness.presence.evaluateTick().kind,
        PresenceIntentKind.spokenThought,
      );
      await _waitUntil(
        () =>
            harness.shadow.state.value.gateOutcomes[ProactiveDriveGateOutcome
                .hold] ==
            1,
      );

      expect(harness.llm.chatCalls, 0);
      expect(ttsSpeakCalls, 0);
      expect(await harness.database.getMessages('self'), isEmpty);
      expect(await harness.ledger.recent(), isEmpty);
      expect(harness.presence.state.value.lastSpokenThoughtAt, isNull);
      expect(harness.shadow.state.value.samples, 0);
      expect(harness.shadow.state.value.evaluations, 1);
      expect(harness.shadow.state.value.comparisons, isEmpty);
    },
  );

  test(
    'enforce contact filters one candidate then preserves legacy transaction',
    () async {
      final harness = await _Harness.create(contactPolicy: (_) => true);
      addTearDown(harness.dispose);
      final response = harness.runtime.onCommittedProactiveResponse.first
          .timeout(const Duration(seconds: 5));

      expect(
        harness.presence.evaluateTick().kind,
        PresenceIntentKind.spokenThought,
      );
      expect((await response).text, '灰度联系已通过旧事务。');
      await _waitUntil(
        () =>
            harness.shadow.state.value.gateOutcomes[ProactiveDriveGateOutcome
                .contact] ==
            1,
      );

      expect(harness.llm.chatCalls, 1);
      expect(ttsSpeakCalls, 1);
      expect(await harness.database.getMessages('self'), hasLength(1));
      final records = await harness.ledger.recent();
      expect(records, hasLength(1));
      expect(records.single.state, OutreachState.delivered);
      expect(
        harness
            .shadow
            .state
            .value
            .candidateBuckets[ProactiveShadowCandidateBucket.one],
        1,
      );
      expect(harness.shadow.state.value.evaluations, 1);
      expect(harness.shadow.state.value.comparisons, isEmpty);
    },
  );

  test(
    'drive contact cannot bypass the legacy daily budget hard gate',
    () async {
      final harness = await _Harness.create(
        contactPolicy: (_) => true,
        dailyLimit: 0,
      );
      addTearDown(harness.dispose);

      expect(
        harness.presence.evaluateTick().kind,
        PresenceIntentKind.spokenThought,
      );
      await _waitUntil(
        () =>
            harness.shadow.state.value.gateOutcomes[ProactiveDriveGateOutcome
                .contact] ==
            1,
      );

      expect(harness.llm.chatCalls, 0);
      expect(ttsSpeakCalls, 0);
      expect(await harness.database.getMessages('self'), isEmpty);
      expect(await harness.ledger.recent(), isEmpty);
      expect(
        harness.shadow.state.value.outcomes[ProactivePreparationStatus
            .silenced],
        1,
      );
    },
  );

  test('cold posterior stays on the complete legacy path', () async {
    final harness = await _Harness.create(
      contactPolicy: (_) => false,
      minimumPosteriorSamples: 5,
    );
    addTearDown(harness.dispose);
    final response = harness.runtime.onCommittedProactiveResponse.first.timeout(
      const Duration(seconds: 5),
    );

    harness.presence.evaluateTick();
    expect((await response).text, '灰度联系已通过旧事务。');
    await _waitUntil(() => harness.shadow.state.value.evaluations == 1);

    expect(harness.llm.chatCalls, 1);
    expect(await harness.ledger.recent(), hasLength(1));
    expect(harness.shadow.state.value.gateOutcomes, isEmpty);
    expect(harness.shadow.state.value.comparisons.values.single, 1);
  });

  test(
    'kill switch inside scoring invalidates admission and restores legacy',
    () async {
      late ProactiveDriveRolloutService rollout;
      final harness = await _Harness.create(
        rolloutBuilder: (flags) {
          rollout = ProactiveDriveRolloutService(
            featureFlags: flags,
            accountScopeDigest: 'rollback-before-linearization',
            compileEnforceMaximumBasisPoints: 10000,
            initialEnforceBasisPoints: 10000,
            minimumPosteriorSamples: 0,
            contactPolicy: (_) {
              rollout.disableEnforcement();
              return false;
            },
          );
          return rollout;
        },
      );
      addTearDown(harness.dispose);
      final response = harness.runtime.onCommittedProactiveResponse.first
          .timeout(const Duration(seconds: 5));

      harness.presence.evaluateTick();
      expect((await response).text, '灰度联系已通过旧事务。');

      expect(rollout.effectiveMode(), FeatureRolloutMode.shadow);
      expect(harness.llm.chatCalls, 1);
      expect(await harness.ledger.recent(), hasLength(1));
      expect(harness.shadow.state.value.gateOutcomes, isEmpty);
    },
  );

  test(
    'kill after coordinator invocation does not rewrite the admitted turn',
    () async {
      final policy = _GatedPolicy();
      final harness = await _Harness.create(
        contactPolicy: (_) => true,
        policy: policy,
      );
      addTearDown(harness.dispose);
      final response = harness.runtime.onCommittedProactiveResponse.first
          .timeout(const Duration(seconds: 5));

      harness.presence.evaluateTick();
      await policy.entered.future.timeout(const Duration(seconds: 5));
      harness.rollout.disableEnforcement();
      policy.release.complete();

      expect((await response).text, '灰度联系已通过旧事务。');
      expect(harness.rollout.effectiveMode(), FeatureRolloutMode.shadow);
      expect(harness.llm.chatCalls, 1);
      expect(await harness.ledger.recent(), hasLength(1));
    },
  );
}

typedef _RolloutBuilder =
    ProactiveDriveRolloutService Function(MaasoFeatureFlagService flags);

final class _Harness {
  _Harness._({
    required this.database,
    required this.ledger,
    required this.presence,
    required this.flags,
    required this.rollout,
    required this.shadow,
    required this.llm,
    required this.runtime,
  });

  static int _serial = 0;

  final DBService database;
  final ProactiveOutreachLedger ledger;
  final AgentPresenceService presence;
  final MaasoFeatureFlagService flags;
  final ProactiveDriveRolloutService rollout;
  final ProactiveDriveShadowService shadow;
  final _ReplyLlm llm;
  final AgentRuntime runtime;

  static Future<_Harness> create({
    ProactiveDriveContactPolicy? contactPolicy,
    int minimumPosteriorSamples = 0,
    int dailyLimit = 3,
    ProactiveCompanionPolicy? policy,
    _RolloutBuilder? rolloutBuilder,
  }) async {
    final serial = _serial++;
    // AgentRuntime stamps the final commit with the real UTC clock. Keep the
    // deterministic policy clock close enough that the two-minute reservation
    // cannot be recovered as expired before that final linearization point.
    final now = DateTime.now().toUtc();
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'proactive-drive-enforcement-$serial.db',
    );
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      clock: () => now,
      idFactory: () => 'drive-enforcement-$serial',
    );
    final coordinator = ProactiveOutreachCoordinator(
      policy:
          policy ??
          ProactiveCompanionPolicy(
            config: ProactivePolicyConfig(
              foregroundDailyLimit: dailyLimit,
              minimumGlobalGap: Duration.zero,
              maximumDeterministicJitter: Duration.zero,
              genericTopicCooldown: Duration.zero,
              quietStartMinutes: 0,
              quietEndMinutes: 0,
            ),
          ),
      ledger: ledger,
      accountKey: 'account:drive-enforcement-$serial',
      clock: () => now,
    );
    final presence = AgentPresenceService(
      now: () => now,
      runtimeBusy: () => false,
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: now.add(const Duration(hours: 1)),
    );
    final rollout =
        rolloutBuilder?.call(flags) ??
        ProactiveDriveRolloutService(
          featureFlags: flags,
          accountScopeDigest: 'drive-enforcement-account-$serial',
          compileEnforceMaximumBasisPoints: 10000,
          initialEnforceBasisPoints: 10000,
          minimumPosteriorSamples: minimumPosteriorSamples,
          contactPolicy: contactPolicy,
        );
    final shadow = ProactiveDriveShadowService(featureFlags: flags);
    final llm = _ReplyLlm();

    appServices.put<DBService>(database);
    appServices.put<MaasoFeatureFlagService>(flags);
    appServices.put<ProactiveDriveRolloutService>(rollout);
    appServices.put<ProactiveDriveShadowService>(shadow);
    appServices.put<ProactiveOutreachLedger>(ledger);
    appServices.put<ProactiveOutreachCoordinator>(coordinator);
    appServices.put<AgentPresenceService>(presence);
    // These tests exercise drive admission and durable outreach, not night
    // resting. Keep the reservation clock near Runtime's real UTC commit and
    // explicitly disable the independent wall-hour rest gate for this fixture.
    final behavior = appServices.put(AgentBehaviorConfig());
    behavior.presenceNightQuietStartHour.value = 0;
    behavior.presenceNightQuietEndHour.value = 0;
    appServices.put(AgentTaskJobStore());
    final runtime = AgentRuntime(
      agentId: 'self',
      profile: _profile(),
      llmClient: llm,
    );
    await runtime.init(enabledSkillIds: const <String>{});
    presence.state.value = presence.state.value.copyWith(
      mode: AgentPresenceMode.daydreaming,
      attention: AgentPresenceAttention.self,
      energy: 0.8,
      lastUserInteractionAt: now.subtract(const Duration(hours: 2)),
      lastSignalAt: now.subtract(const Duration(minutes: 10)),
    );
    return _Harness._(
      database: database,
      ledger: ledger,
      presence: presence,
      flags: flags,
      rollout: rollout,
      shadow: shadow,
      llm: llm,
      runtime: runtime,
    );
  }

  Future<void> dispose() async {
    await runtime.retireAndDrain();
    await database.close();
    await appServices.reset();
  }
}

final class _GatedPolicy extends ProactiveCompanionPolicy {
  _GatedPolicy()
    : super(
        config: const ProactivePolicyConfig(
          foregroundDailyLimit: 3,
          minimumGlobalGap: Duration.zero,
          maximumDeterministicJitter: Duration.zero,
          genericTopicCooldown: Duration.zero,
          quietStartMinutes: 0,
          quietEndMinutes: 0,
        ),
      );

  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<T> runWithStableConfig<T>(
    Future<T> Function(ProactivePolicyConfig config) operation,
  ) async {
    if (!entered.isCompleted) {
      entered.complete();
      await release.future;
    }
    return super.runWithStableConfig(operation);
  }
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Hiyori',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

final class _ReplyLlm implements LLMClient {
  int chatCalls = 0;

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    chatCalls++;
    return jsonEncode(<String, Object?>{
      'reply': '灰度联系已通过旧事务。',
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
  bool Function() predicate, {
  Duration timeout = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('condition not reached', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
