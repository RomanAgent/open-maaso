import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/streaming_audio_sink.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'U2A durable user message resolves pending outreach and survives restart',
    () async {
      final harness = await _OutreachProducerHarness.create(
        'feedback-producer-u2a.db',
      );
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground('u2a-response');

      appServices.put<DBService>(harness.database);
      appServices.put<OutreachFeedbackCollector>(harness.collector);
      appServices.put(AgentRuntimeRegistry());
      final controller = U2aChatController();
      addTearDown(controller.onClose);

      controller.inputController.text = 'I am here';
      await controller.sendMessage();
      await harness.collector.waitForIdle();

      final userMessage = (await harness.database.getMessages(
        'self',
      )).singleWhere((message) => message.isUserMessage);
      expect(userMessage.turnOrigin, ChatMessageTurnOrigins.user);
      expect(userMessage.timestamp.isUtc, isTrue);
      await _expectResponded(harness.collector, delivered.outreachId);

      final restored = await harness.restartCollector();
      await _expectResponded(restored, delivered.outreachId);
    },
  );

  test('Companion Voice durable user message resolves pending outreach and '
      'survives restart', () async {
    final harness = await _OutreachProducerHarness.create(
      'feedback-producer-voice.db',
    );
    addTearDown(harness.close);
    final delivered = await harness.deliverForeground('voice-response');
    final runtime = _ImmediateVoiceRuntime();
    addTearDown(runtime.dispose);

    appServices.put<OutreachFeedbackCollector>(harness.collector);
    final controller = CompanionVoiceSessionController(
      database: harness.database,
      runtimeRegistry: _FixedRuntimeRegistry(runtime),
    );
    addTearDown(controller.dispose);
    controller.activate();

    controller.inputController.text = 'I am answering by voice';
    await controller.sendVoiceMessage();
    await harness.collector.waitForIdle();

    final userMessage = (await harness.database.getMessages(
      'self',
    )).singleWhere((message) => message.isUserMessage);
    expect(userMessage.turnOrigin, ChatMessageTurnOrigins.voice);
    expect(userMessage.timestamp.isUtc, isTrue);
    await _expectResponded(harness.collector, delivered.outreachId);

    final restored = await harness.restartCollector();
    await _expectResponded(restored, delivered.outreachId);
  });
}

Future<void> _expectResponded(
  OutreachFeedbackCollector collector,
  String outreachId,
) async {
  expect(collector.state.value.posteriorSamples, 1);
  expect(collector.posterior.availableMass, 2);
  expect(collector.posterior.unavailableMass, 4);
  expect(collector.state.value.outcomes[OutreachFeedbackOutcome.responded], 1);
  expect(
    await collector.get(outreachId),
    isA<OutreachFeedbackEntry>().having(
      (entry) => entry.outcome,
      'outcome',
      OutreachFeedbackOutcome.responded,
    ),
  );
}

final class _OutreachProducerHarness {
  _OutreachProducerHarness({
    required this.database,
    required this.flags,
    required this.ledger,
    required this.collector,
  });

  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactiveOutreachLedger ledger;
  OutreachFeedbackCollector collector;
  var _sequence = 0;

  static Future<_OutreachProducerHarness> create(String path) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: DateTime.now().toUtc().add(const Duration(days: 1)),
    );
    final ledger = ProactiveOutreachLedger(accountDatabase: database);
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
    ).init();
    return _OutreachProducerHarness(
      database: database,
      flags: flags,
      ledger: ledger,
      collector: collector,
    );
  }

  Future<OutreachRecord> deliverForeground(String source) async {
    final sequence = ++_sequence;
    final now = DateTime.now().toUtc();
    final reservation = (await ledger.reserve(
      sourceEventId: '$source:$sequence',
      topicKey: 'quietPresence',
      now: now,
    ))!;
    final idempotencyKey = 'proactive:${reservation.outreachId}';
    await ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'producer-fingerprint-$sequence',
      visibleMessageJson: ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: 'proactive-visible-message',
        timestamp: now,
        turnOrigin: ChatMessageTurnOrigins.proactivePresence,
        idempotencyKey: idempotencyKey,
        outreachId: reservation.outreachId,
      ).toJson(),
      visibleMessageIdempotencyKey: idempotencyKey,
      now: now,
    );
    final delivered = await ledger.markDelivered(reservation, now: now);
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
    ).init();
    return collector;
  }

  Future<void> close() async {
    await collector.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await database.close();
  }
}

final class _FixedRuntimeRegistry extends AgentRuntimeRegistry {
  _FixedRuntimeRegistry(this.runtime);

  final AgentRuntime runtime;

  @override
  AgentRuntime? get(String agentId) => runtime;
}

final class _ImmediateVoiceRuntime extends AgentRuntime {
  _ImmediateVoiceRuntime()
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

  @override
  Stream<String> get onLocalReplyDelta => const Stream<String>.empty();

  @override
  Future<ExecutionResult> chat(
    String text,
    List<Message> history, {
    TurnOrigin origin = TurnOrigin.user,
    String? currentUserText,
    StreamingAudioSink? liveAudioSink,
    String? expectedAppletScopeKey,
  }) async => ExecutionResult.success('voice reply');
}

final class _UnusedLlmClient implements LLMClient {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
