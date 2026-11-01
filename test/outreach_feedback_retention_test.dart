import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/contact_timing_engine.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'age compaction survives restart and repeated reconcile without double count',
    () async {
      final harness = await _RetentionHarness.create(
        'feedback-retention-age.db',
        policy: const OutreachFeedbackRetentionPolicy(
          maxResolvedEntries: 8,
          maxResolvedAge: Duration(hours: 1),
          ignoredCorrectionGrace: Duration(minutes: 10),
          maxMuteMarkers: 8,
          maxMuteAge: Duration(days: 1),
        ),
      );
      addTearDown(harness.close);
      final responded = await harness.deliverAndRespond(
        source: 'age-private-source-sentinel',
      );
      final expectedMetrics = _learningMetrics(harness.collector.state.value);

      harness.clock.advance(const Duration(hours: 2));
      await harness.collector.reconcile(now: harness.clock.now);

      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(await harness.collector.get(responded.outreachId), isNull);
      expect(_learningMetrics(harness.collector.state.value), expectedMetrics);

      await harness.collector.reconcile(now: harness.clock.now);
      await harness.collector.reconcile(now: harness.clock.now);
      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(_learningMetrics(harness.collector.state.value), expectedMetrics);

      final restored = await harness.restartCollector();
      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(_learningMetrics(restored.state.value), expectedMetrics);
    },
  );

  test(
    'count compaction bounds raw resolved rows and preserves totals',
    () async {
      final harness = await _RetentionHarness.create(
        'feedback-retention-count.db',
        policy: const OutreachFeedbackRetentionPolicy(
          maxResolvedEntries: 2,
          maxResolvedAge: Duration(days: 30),
          ignoredCorrectionGrace: Duration(minutes: 10),
          maxMuteMarkers: 8,
          maxMuteAge: Duration(days: 30),
        ),
      );
      addTearDown(harness.close);

      for (var index = 0; index < 5; index += 1) {
        await harness.deliverAndRespond(source: 'count-source-$index');
      }

      expect(await _feedbackStore.count(harness.database.raw), 2);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.delivered],
        5,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.responded],
        5,
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome
            .responded],
        5,
      );
      expect(harness.collector.state.value.posteriorSamples, 5);
      expect(await _compactedStore.count(harness.database.raw), 3);

      final before = _learningMetrics(harness.collector.state.value);
      await harness.collector.reconcile(now: harness.clock.now);
      expect(await _feedbackStore.count(harness.database.raw), 2);
      expect(await _compactedStore.count(harness.database.raw), 3);
      expect(_learningMetrics(harness.collector.state.value), before);
    },
  );

  test(
    'pending outreach is never compacted to satisfy resolved row limit',
    () async {
      final harness = await _RetentionHarness.create(
        'feedback-retention-pending.db',
        policy: const OutreachFeedbackRetentionPolicy(
          maxResolvedEntries: 1,
          maxResolvedAge: Duration(days: 30),
          ignoredCorrectionGrace: Duration(minutes: 10),
          maxMuteMarkers: 8,
          maxMuteAge: Duration(days: 30),
        ),
      );
      addTearDown(harness.close);

      await harness.deliverAndRespond(source: 'resolved-one');
      await harness.deliverAndRespond(source: 'resolved-two');
      final pending = await harness.deliver(source: 'pending-private-sentinel');

      expect(await harness.collector.get(pending.outreachId), isNotNull);
      expect(harness.collector.state.value.pending, 1);
      expect(await _feedbackStore.count(harness.database.raw), 2);
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome
            .responded],
        2,
      );
    },
  );

  test(
    'cancelled unclaimed OS retracts its compacted rollup exactly',
    () async {
      final harness = await _RetentionHarness.create(
        'feedback-retention-os-cancel.db',
        policy: const OutreachFeedbackRetentionPolicy(
          maxResolvedEntries: 0,
          maxResolvedAge: Duration(days: 30),
          ignoredCorrectionGrace: Duration(minutes: 10),
          maxMuteMarkers: 8,
          maxMuteAge: Duration(days: 30),
        ),
      );
      addTearDown(harness.close);
      const deliveryId = 'proactive:v3:retention:cancelled-os';
      final scheduledFor = harness.clock.now.add(const Duration(minutes: 1));
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: 'os:v3:retention:cancelled-os',
        deliveryId: deliveryId,
        topicKey: 'presence.time.morning',
        scheduledFor: scheduledFor,
        expiresAt: scheduledFor.add(const Duration(minutes: 1)),
        now: harness.clock.now,
      );

      harness.clock.advance(const Duration(minutes: 22));
      await harness.collector.reconcile(now: harness.clock.now);

      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(await _compactedStore.count(harness.database.raw), 1);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.delivered],
        1,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.ignored],
        1,
      );
      expect(
        (await _compactedStore.find(
          harness.database.raw,
        )).single.value['outcome'],
        OutreachFeedbackOutcome.ignored.name,
      );

      await harness.ledger.cancelScheduledOsByDeliveryId(
        deliveryId,
        now: harness.clock.now,
      );
      await harness.collector.reconcile(now: harness.clock.now);

      expect(await harness.collector.get(scheduled.outreachId), isNull);
      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(await _compactedStore.count(harness.database.raw), 0);
      expect(harness.collector.state.value.posteriorSamples, 0);
      expect(harness.collector.posterior.availableMass, 1);
      expect(harness.collector.posterior.unavailableMass, 4);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.delivered],
        isNull,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.ignored],
        isNull,
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome.ignored],
        isNull,
      );
      expect(
        harness.collector.state.value.channelDeliveries[OutreachChannel
            .osNotification],
        isNull,
      );

      final rollup = (await _metadataStore
          .record('rollup')
          .get(harness.database.raw))!;
      expect((rollup['events'] as Map)['delivered'], 0);
      expect((rollup['events'] as Map)['ignored'], 0);
      expect((rollup['outcomes'] as Map)['ignored'], 0);
      expect((rollup['channelDeliveries'] as Map)['osNotification'], 0);
    },
  );

  test(
    'durable pre-deadline response corrects a compacted foreground ignore once',
    () async {
      final harness = await _RetentionHarness.create(
        'feedback-retention-late-response.db',
        policy: const OutreachFeedbackRetentionPolicy(
          maxResolvedEntries: 0,
          maxResolvedAge: Duration(days: 30),
          ignoredCorrectionGrace: Duration(minutes: 10),
          maxMuteMarkers: 8,
          maxMuteAge: Duration(days: 30),
        ),
      );
      addTearDown(harness.close);
      final delivered = await harness.deliver(source: 'late-durable-response');
      final responseAt = delivered.deliveredAt!.add(const Duration(minutes: 5));

      harness.clock.advance(const Duration(minutes: 20));
      await harness.collector.reconcile(now: harness.clock.now);
      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(await _compactedStore.count(harness.database.raw), 1);
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome.ignored],
        1,
      );
      expect(
        (await _compactedStore.find(
          harness.database.raw,
        )).single.value['outcome'],
        OutreachFeedbackOutcome.ignored.name,
      );

      final responseRecordId = await harness.persistUserMessage(at: responseAt);
      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: responseRecordId,
        ),
        OutreachFeedbackMutationResult.recorded,
      );

      expect(await _feedbackStore.count(harness.database.raw), 0);
      expect(await _compactedStore.count(harness.database.raw), 1);
      expect(
        (await _compactedStore.find(
          harness.database.raw,
        )).single.value['outcome'],
        OutreachFeedbackOutcome.responded.name,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.delivered],
        1,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.responded],
        1,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.ignored],
        1,
        reason: 'The inferred signal remains historical event evidence.',
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome
            .responded],
        1,
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome.ignored],
        isNull,
      );
      expect(harness.collector.state.value.posteriorSamples, 1);
      expect(harness.collector.posterior.availableMass, 2);
      expect(harness.collector.posterior.unavailableMass, 4);

      await harness.collector.reconcile(now: harness.clock.now);
      expect(await _compactedStore.count(harness.database.raw), 1);
      expect(harness.collector.state.value.posteriorSamples, 1);
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome
            .responded],
        1,
      );
    },
  );

  test('mute marker compaction remains bounded and restart-stable', () async {
    final harness = await _RetentionHarness.create(
      'feedback-retention-mutes.db',
      policy: const OutreachFeedbackRetentionPolicy(
        maxResolvedEntries: 8,
        maxResolvedAge: Duration(days: 30),
        ignoredCorrectionGrace: Duration(minutes: 10),
        maxMuteMarkers: 2,
        maxMuteAge: Duration(days: 30),
      ),
    );
    addTearDown(harness.close);

    var revision = 1;
    for (var index = 0; index < 4; index += 1) {
      expect(
        await harness.collector.recordMuted(
          preferenceRevision: revision++,
          at: harness.clock.now,
        ),
        OutreachFeedbackMutationResult.recorded,
      );
      harness.clock.advance(const Duration(minutes: 1));
      expect(
        await harness.collector.recordUnmuted(
          preferenceRevision: revision++,
          at: harness.clock.now,
        ),
        OutreachFeedbackMutationResult.recorded,
      );
      harness.clock.advance(const Duration(minutes: 1));
    }

    expect(await _muteStore.count(harness.database.raw), 2);
    expect(
      harness.collector.state.value.events[OutreachFeedbackSignal.muted],
      4,
    );
    expect(
      harness.collector.state.value.outcomes[OutreachFeedbackOutcome.muted],
      4,
    );

    final before = _learningMetrics(harness.collector.state.value);
    final restored = await harness.restartCollector();
    expect(await _muteStore.count(harness.database.raw), 2);
    expect(_learningMetrics(restored.state.value), before);
  });

  test(
    'rollup and compacted markers are private and corruption fails closed',
    () async {
      final harness = await _RetentionHarness.create(
        'feedback-retention-private.db',
        policy: const OutreachFeedbackRetentionPolicy(
          maxResolvedEntries: 1,
          maxResolvedAge: Duration(days: 30),
          ignoredCorrectionGrace: Duration(minutes: 10),
          maxMuteMarkers: 8,
          maxMuteAge: Duration(days: 30),
        ),
      );
      addTearDown(harness.close);
      final first = await harness.deliverAndRespond(
        source: 'rollup-private-source-sentinel',
        body: 'rollup-private-body-sentinel',
      );
      await harness.deliverAndRespond(source: 'rollup-second-source');

      final rollup = await _metadataStore
          .record('rollup')
          .get(harness.database.raw);
      expect(rollup, isNotNull);
      final storedRollup = rollup!;
      expect(
        storedRollup.keys,
        unorderedEquals(<String>[
          'schemaVersion',
          'events',
          'outcomes',
          'channelDeliveries',
          'responseLatencyBuckets',
        ]),
      );
      final compacted = await _compactedStore.find(harness.database.raw);
      expect(compacted, hasLength(1));
      expect(compacted.single.key, isNot(first.outreachId));
      expect(compacted.single.key, hasLength(64));
      expect(
        compacted.single.value.keys,
        unorderedEquals(<String>[
          'schemaVersion',
          'eventMask',
          'outcome',
          'channel',
          'responseLatencyBucket',
        ]),
      );

      final encoded = <Object?>[
        storedRollup,
        compacted.single.key,
        compacted.single.value,
      ].join('|').toLowerCase();
      for (final forbidden in <String>[
        first.outreachId.toLowerCase(),
        'rollup-private-source-sentinel',
        'rollup-private-body-sentinel',
        harness.clock.initial.toIso8601String().toLowerCase(),
        'content',
        'prompt',
        'reply',
        'account',
        'locale',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }

      await harness.collector.deactivateAndDrain();
      await _metadataStore.record('rollup').put(harness.database.raw, {
        ...storedRollup,
        'schemaVersion': 999,
      });
      final degraded = await harness.restartCollector();
      expect(degraded.isCollecting, isFalse);
      expect(degraded.posterior, same(ContactAvailabilityBelief.conservative));
      expect(degraded.state.value.storageErrors, 1);
      expect(
        await degraded.recordUserResponse(messageRecordId: 1),
        OutreachFeedbackMutationResult.disabled,
      );
    },
  );
}

final StoreRef<String, Map<String, Object?>> _feedbackStore =
    StoreRef<String, Map<String, Object?>>(
      OutreachFeedbackCollector.storageName,
    );
final StoreRef<String, Map<String, Object?>> _muteStore =
    StoreRef<String, Map<String, Object?>>('outreach_feedback_mutes.v1');
final StoreRef<String, Map<String, Object?>> _metadataStore =
    StoreRef<String, Map<String, Object?>>(
      OutreachFeedbackCollector.metadataStorageName,
    );
final StoreRef<String, Map<String, Object?>> _compactedStore =
    StoreRef<String, Map<String, Object?>>(
      OutreachFeedbackCollector.compactedStorageName,
    );

Map<String, Object?> _learningMetrics(OutreachFeedbackSnapshot snapshot) =>
    <String, Object?>{
      'events': snapshot.events,
      'outcomes': snapshot.outcomes,
      'channelDeliveries': snapshot.channelDeliveries,
      'responseLatencyBuckets': snapshot.responseLatencyBuckets,
      'posteriorAvailableMass': snapshot.posterior.availableMass,
      'posteriorUnavailableMass': snapshot.posterior.unavailableMass,
      'posteriorSamples': snapshot.posteriorSamples,
      'pending': snapshot.pending,
    };

final class _RetentionClock {
  _RetentionClock(this.now) : initial = now;

  final DateTime initial;
  DateTime now;

  void advance(Duration duration) => now = now.add(duration);
}

final class _RetentionHarness {
  _RetentionHarness({
    required this.database,
    required this.flags,
    required this.ledger,
    required this.collector,
    required this.clock,
    required this.policy,
  });

  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactiveOutreachLedger ledger;
  OutreachFeedbackCollector collector;
  final _RetentionClock clock;
  final OutreachFeedbackRetentionPolicy policy;
  var _sequence = 0;

  static Future<_RetentionHarness> create(
    String name, {
    required OutreachFeedbackRetentionPolicy policy,
  }) async {
    final clock = _RetentionClock(DateTime.utc(2026, 8, 29, 8));
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: name,
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: () => clock.now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: clock.now.add(const Duration(days: 365)),
    );
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      clock: () => clock.now,
    );
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => clock.now,
      responseWindow: const Duration(minutes: 10),
      retentionPolicy: policy,
    ).init();
    return _RetentionHarness(
      database: database,
      flags: flags,
      ledger: ledger,
      collector: collector,
      clock: clock,
      policy: policy,
    );
  }

  Future<OutreachRecord> deliver({required String source, String? body}) async {
    final sequence = ++_sequence;
    final reservation = await ledger.reserve(
      sourceEventId: '$source:$sequence',
      topicKey: 'quietPresence',
      now: clock.now,
    );
    expect(reservation, isNotNull);
    final idempotencyKey = 'proactive:${reservation!.outreachId}';
    await ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'retention-fingerprint-$sequence',
      visibleMessageJson: ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: body ?? 'private-retention-body-$sequence',
        timestamp: clock.now,
        turnOrigin: ChatMessageTurnOrigins.proactivePresence,
        idempotencyKey: idempotencyKey,
        outreachId: reservation.outreachId,
      ).toJson(),
      visibleMessageIdempotencyKey: idempotencyKey,
      now: clock.now,
    );
    final delivered = await ledger.markDelivered(reservation, now: clock.now);
    expect(
      await collector.recordDelivered(delivered),
      OutreachFeedbackMutationResult.recorded,
    );
    return delivered;
  }

  Future<OutreachRecord> deliverAndRespond({
    required String source,
    String? body,
  }) async {
    final delivered = await deliver(source: source, body: body);
    clock.advance(const Duration(minutes: 1));
    final messageRecordId = await database.saveChatMessage(
      ChatMessage(
        sessionId: 'self',
        senderId: 'user',
        receiverId: 'self',
        content: 'private-user-response',
        timestamp: clock.now,
        isUserMessage: true,
        turnOrigin: ChatMessageTurnOrigins.user,
      ),
    );
    expect(
      await collector.recordUserResponse(messageRecordId: messageRecordId),
      OutreachFeedbackMutationResult.recorded,
    );
    clock.advance(const Duration(minutes: 1));
    return delivered;
  }

  Future<int> persistUserMessage({required DateTime at}) =>
      database.saveChatMessage(
        ChatMessage(
          sessionId: 'self',
          senderId: 'user',
          receiverId: 'self',
          content: 'private-late-user-response',
          timestamp: at.toUtc(),
          isUserMessage: true,
          turnOrigin: ChatMessageTurnOrigins.user,
        ),
      );

  Future<OutreachFeedbackCollector> restartCollector() async {
    await collector.deactivateAndDrain();
    collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => clock.now,
      responseWindow: const Duration(minutes: 10),
      retentionPolicy: policy,
    ).init();
    return collector;
  }

  Future<void> close() async {
    await collector.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await database.close();
  }
}
