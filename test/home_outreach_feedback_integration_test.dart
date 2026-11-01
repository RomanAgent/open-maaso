import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/agent_initiated_response.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_boot_controller.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  test(
    'Home normal reply records a durable response for pending outreach',
    () async {
      final harness = await _HomeFeedbackHarness.create('normal');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground('home-normal');
      harness.moveClockPastWallTime();
      harness.registerPureChatRuntime();
      final controller = harness.track(HomeController());

      controller.inputController.text = '我在，刚刚看到你的消息了';
      await controller.send();
      await harness.collector.waitForIdle();

      expect(controller.latestBubble.value, '收到，这是普通回复。');
      expect(
        (await harness.collector.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );

      final restored = await harness.restartCollector();
      expect(
        (await restored.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );
      expect(
        restored.state.value.outcomes[OutreachFeedbackOutcome.responded],
        1,
      );
    },
  );

  test(
    'Home boot-handled reply still records a durable outreach response',
    () async {
      final harness = await _HomeFeedbackHarness.create('boot');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground('home-boot');
      harness.moveClockPastWallTime();
      harness.registerPureChatRuntime();
      final boot = appServices.put(
        AgentBootController(fallbackStop: () async {}),
      );
      boot.awaitingName.value = true;
      final controller = harness.track(HomeController());

      controller.inputController.text = 'Maaso';
      await controller.send();
      await harness.collector.waitForIdle();

      expect(controller.latestBubble.value, isNull);
      expect(
        (await harness.collector.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );

      final restored = await harness.restartCollector();
      expect(
        (await restored.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );
      expect(
        restored.state.value.outcomes[OutreachFeedbackOutcome.responded],
        1,
      );
    },
  );

  test(
    'Home committed proactive bubble dismissal persists exact outreach',
    () async {
      final harness = await _HomeFeedbackHarness.create('dismiss');
      addTearDown(harness.close);
      final runtime = harness.runtime = _CommittedResponseRuntime();
      final registry = _FixedRuntimeRegistry(runtime);
      harness.registry = registry;
      appServices.put<AgentRuntimeRegistry>(registry);
      appServices.put<AgentCoreController>(
        _ReadyAgentCoreController(runtime.profile),
      );
      appServices.put(AgentTaskJobStore());
      final controller = appServices.put(HomeController());
      await runtime.committedListenerAttached.future.timeout(
        const Duration(seconds: 2),
      );
      final delivered = await harness.deliverForeground('home-dismiss');
      harness.moveClockPastWallTime();

      runtime.emitCommitted(
        AgentInitiatedResponse(
          outreachId: delivered.outreachId,
          sourceEventId: delivered.sourceEventId,
          topicKey: delivered.topicKey,
          text: '要不要休息一下？',
          committedAt: delivered.committedAt!,
        ),
      );
      await pumpEventQueue();
      expect(controller.latestBubble.value, '要不要休息一下？');

      controller.dismissLatestReply();
      expect(controller.latestBubble.value, isNull);
      await harness.collector.waitForIdle();
      expect(
        (await harness.collector.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.dismissed,
      );

      final restored = await harness.restartCollector();
      expect(
        (await restored.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.dismissed,
      );
      expect(
        restored.state.value.outcomes[OutreachFeedbackOutcome.dismissed],
        1,
      );
    },
  );

  test('ordinary bubble replacement clears old outreach provenance', () async {
    final harness = await _HomeFeedbackHarness.create('replace');
    addTearDown(harness.close);
    final runtime = harness.runtime = _CommittedResponseRuntime();
    final registry = _FixedRuntimeRegistry(runtime);
    harness.registry = registry;
    appServices.put<AgentRuntimeRegistry>(registry);
    appServices.put<AgentCoreController>(
      _ReadyAgentCoreController(runtime.profile),
    );
    appServices.put(AgentTaskJobStore());
    final controller = appServices.put(HomeController());
    await runtime.committedListenerAttached.future.timeout(
      const Duration(seconds: 2),
    );
    final delivered = await harness.deliverForeground('home-replace');
    harness.moveClockPastWallTime();
    runtime.emitCommitted(
      AgentInitiatedResponse(
        outreachId: delivered.outreachId,
        sourceEventId: delivered.sourceEventId,
        topicKey: delivered.topicKey,
        text: '要不要休息一下？',
        committedAt: delivered.committedAt!,
      ),
    );
    await pumpEventQueue();
    expect(controller.latestBubble.value, '要不要休息一下？');

    runtime.emitLegacy('这是另一条普通消息。');
    await pumpEventQueue();
    expect(controller.latestBubble.value, '这是另一条普通消息。');
    controller.dismissLatestReply();
    await harness.collector.waitForIdle();
    expect(controller.latestBubble.value, isNull);
    expect(
      (await harness.collector.get(delivered.outreachId))?.outcome,
      isNull,
    );
    final restored = await harness.restartCollector();
    expect((await restored.get(delivered.outreachId))?.outcome, isNull);
  });

  test('Home does not attach an unregistered proactive runtime', () async {
    final harness = await _HomeFeedbackHarness.create('stale');
    addTearDown(harness.close);
    final runtime = harness.runtime = _CommittedResponseRuntime();
    final registry = _FixedRuntimeRegistry(runtime, registeredRuntime: false);
    harness.registry = registry;
    appServices.put<AgentRuntimeRegistry>(registry);
    appServices.put<AgentCoreController>(
      _ReadyAgentCoreController(runtime.profile),
    );
    appServices.put(AgentTaskJobStore());
    final controller = appServices.put(HomeController());
    await registry.attached.future;
    await pumpEventQueue();
    expect(runtime.committedListenerAttached.isCompleted, isFalse);
    final delivered = await harness.deliverForeground('home-stale');
    runtime.emitCommitted(
      AgentInitiatedResponse(
        outreachId: delivered.outreachId,
        sourceEventId: delivered.sourceEventId,
        topicKey: delivered.topicKey,
        text: '这条属于未注册的运行时。',
        committedAt: delivered.committedAt!,
      ),
    );
    await pumpEventQueue();
    expect(controller.latestBubble.value, isNull);
  });
}

final class _HomeFeedbackHarness {
  _HomeFeedbackHarness({
    required this.database,
    required this.flags,
    required this.ledger,
    required this.collector,
    required this.clock,
  }) : _collectors = <OutreachFeedbackCollector>[collector];

  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactiveOutreachLedger ledger;
  OutreachFeedbackCollector collector;
  final _MutableClock clock;
  final List<OutreachFeedbackCollector> _collectors;
  final List<HomeController> _controllers = <HomeController>[];
  AgentRuntimeRegistry? registry;
  _CommittedResponseRuntime? runtime;
  var _sequence = 0;

  static var _databaseSequence = 0;

  static Future<_HomeFeedbackHarness> create(String label) async {
    final clock = _MutableClock(
      DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
    );
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'home-outreach-feedback-$label-${_databaseSequence++}.db',
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: clock.call,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: clock.call().add(const Duration(days: 1)),
    );
    final ledger = ProactiveOutreachLedger(accountDatabase: database);
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: clock.call,
    ).init();
    appServices.put<DBService>(database);
    appServices.put<ProactiveOutreachLedger>(ledger);
    appServices.put<MaasoFeatureFlagService>(flags);
    appServices.put<OutreachFeedbackCollector>(collector);
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    return _HomeFeedbackHarness(
      database: database,
      flags: flags,
      ledger: ledger,
      collector: collector,
      clock: clock,
    );
  }

  T track<T extends HomeController>(T controller) {
    _controllers.add(controller);
    return controller;
  }

  void registerPureChatRuntime() {
    final activeRegistry = AgentRuntimeRegistry();
    registry = activeRegistry;
    appServices.put<AgentRuntimeRegistry>(activeRegistry);
    final mode = appServices.put(MaasoAgentModeService());
    mode.pipelineMode.value = AgentPipelineMode.volcRealtimeAudio;
    appServices.put<LLMProxyService>(_StaticLlmProxyService());
  }

  void moveClockPastWallTime() {
    clock.value = DateTime.now().toUtc().add(const Duration(minutes: 1));
  }

  Future<OutreachRecord> deliverForeground(String source) async {
    final sequence = ++_sequence;
    final reservation = await ledger.reserve(
      sourceEventId: '$source:$sequence',
      topicKey: 'quietPresence',
      now: clock.call(),
    );
    expect(reservation, isNotNull);
    final idempotencyKey = 'proactive:${reservation!.outreachId}';
    await ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'home-feedback-$source-$sequence',
      visibleMessageJson: ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: 'private proactive body',
        timestamp: clock.call(),
        turnOrigin: ChatMessageTurnOrigins.proactivePresence,
        idempotencyKey: idempotencyKey,
        outreachId: reservation.outreachId,
      ).toJson(),
      visibleMessageIdempotencyKey: idempotencyKey,
      now: clock.call(),
    );
    final delivered = await ledger.markDelivered(
      reservation,
      now: clock.call(),
    );
    expect(
      await collector.recordDelivered(delivered),
      OutreachFeedbackMutationResult.recorded,
    );
    return delivered;
  }

  Future<OutreachFeedbackCollector> restartCollector() async {
    await collector.deactivateAndDrain();
    collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: clock.call,
    ).init();
    _collectors.add(collector);
    return collector;
  }

  Future<void> close() async {
    for (final controller in _controllers) {
      controller.closeLifecycle();
    }
    await appServices.delete<HomeController>(force: true);
    await registry?.shutdown();
    await runtime?.retireAndDrain();
    for (final collector in _collectors.reversed) {
      await collector.deactivateAndDrain();
    }
    await flags.deactivateAndDrain();
    await database.close();
    await appServices.reset();
  }
}

final class _MutableClock {
  _MutableClock(this.value);

  DateTime value;

  DateTime call() => value;
}

final class _MemorySecureStorageService extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;

  @override
  Future<bool> write(String key, String? value) async => true;
}

final class _StaticLlmProxyService extends LLMProxyService {
  @override
  Future<String> chat(
    String prompt, {
    AppLocale? locale,
    List<Map<String, String>>? history,
  }) async => '收到，这是普通回复。';
}

final class _ReadyAgentCoreController extends AgentCoreController {
  _ReadyAgentCoreController(this._profile);

  final AgentProfile _profile;

  @override
  // Test double keeps the profile stable instead of starting the production
  // controller's asynchronous bootstrap.
  // ignore: must_call_super
  void onInit() {
    profile.value = _profile;
    isInitialized.value = true;
  }
}

final class _FixedRuntimeRegistry extends AgentRuntimeRegistry {
  _FixedRuntimeRegistry(this.runtime, {this.registeredRuntime = true});

  final AgentRuntime runtime;
  final bool registeredRuntime;
  final Completer<void> attached = Completer<void>();

  @override
  AgentRuntime? get(String agentId) =>
      registeredRuntime && canHostExecution && agentId == runtime.agentId
      ? runtime
      : null;

  @override
  Future<AgentRuntime> ensure(AgentProfile profile) async {
    if (!attached.isCompleted) attached.complete();
    return runtime;
  }
}

final class _CommittedResponseRuntime extends AgentRuntime {
  _CommittedResponseRuntime()
    : super(
        agentId: 'self',
        profile: AgentProfile(
          nickname: 'Maaso',
          avatar: '',
          bio: '',
          personalityTraits: const <String>[],
          catchphrase: '',
        ),
        llmClient: _UnusedLlmClient(),
      );

  final Completer<void> committedListenerAttached = Completer<void>();
  late final StreamController<AgentInitiatedResponse> _responses =
      StreamController<AgentInitiatedResponse>.broadcast(
        onListen: () {
          if (!committedListenerAttached.isCompleted) {
            committedListenerAttached.complete();
          }
        },
      );
  final StreamController<String> _legacyResponses =
      StreamController<String>.broadcast();
  bool _responsesClosed = false;

  @override
  Stream<AgentInitiatedResponse> get onCommittedProactiveResponse =>
      _responses.stream;

  @override
  Stream<String> get onProactiveResponse => _legacyResponses.stream;

  void emitCommitted(AgentInitiatedResponse response) {
    _responses.add(response);
  }

  void emitLegacy(String text) {
    _legacyResponses.add(text);
  }

  @override
  Future<void> retireAndDrain() async {
    await super.retireAndDrain();
    if (_responsesClosed) return;
    _responsesClosed = true;
    await _responses.close();
    await _legacyResponses.close();
  }
}

final class _UnusedLlmClient implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
