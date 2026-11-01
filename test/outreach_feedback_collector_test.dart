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
    'durable response updates posterior, latency metrics, and private storage',
    () async {
      final harness = await _Harness.create('feedback-responded.db');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(
        source: 'private-source-sentinel',
        topic: 'private-topic-sentinel',
      );

      expect(
        await harness.collector.recordDelivered(delivered),
        OutreachFeedbackMutationResult.recorded,
      );
      harness.clock.advance(const Duration(minutes: 4));
      final messageRecordId = await harness.persistUserMessage();
      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.recorded,
      );

      final entry = await harness.collector.get(delivered.outreachId);
      expect(entry, isNotNull);
      expect(entry!.outcome, OutreachFeedbackOutcome.responded);
      expect(entry.responseLatency, const Duration(minutes: 4));
      expect(
        harness
            .collector
            .state
            .value
            .responseLatencyBuckets[OutreachResponseLatencyBucket
            .under5Minutes],
        1,
      );
      expect(harness.collector.posterior.availableMass, 2);
      expect(harness.collector.posterior.unavailableMass, 4);
      expect(harness.collector.state.value.posteriorSamples, 1);

      final records = await _feedbackStore.find(harness.database.raw);
      expect(records, hasLength(1));
      expect(records.single.key, isNot(delivered.outreachId));
      final encoded = records.single.value.toString().toLowerCase();
      for (final forbidden in <String>[
        delivered.outreachId.toLowerCase(),
        'private-source-sentinel',
        'private-topic-sentinel',
        'body',
        'content',
        'prompt',
        'reply',
        'account',
        'locale',
      ]) {
        expect(encoded, isNot(contains(forbidden)));
      }
    },
  );

  test(
    'OS response requires an exact claimed open and is idempotent',
    () async {
      final harness = await _Harness.create('feedback-opened.db');
      addTearDown(harness.close);
      final scheduledFor = harness.clock.now.add(const Duration(hours: 1));
      const source = 'os:v3:test:morning:1';
      const delivery = 'proactive:v3:test:morning:1';
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: source,
        deliveryId: delivery,
        topicKey: 'presence.time.morning',
        scheduledFor: scheduledFor,
        expiresAt: scheduledFor.add(const Duration(hours: 1)),
        now: harness.clock.now,
      );

      final earlyMessageRecordId = await harness.persistUserMessage(
        at: harness.clock.now.add(const Duration(minutes: 1)),
      );
      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: earlyMessageRecordId,
        ),
        OutreachFeedbackMutationResult.noEligibleOutreach,
      );

      harness.clock.set(scheduledFor);
      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: delivery,
          sourceEventId: source,
          now: harness.clock.now,
        ),
        isTrue,
      );
      expect(
        await harness.collector.recordOpened(outreachId: scheduled.outreachId),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        await harness.collector.recordOpened(outreachId: scheduled.outreachId),
        OutreachFeedbackMutationResult.duplicate,
      );

      harness.clock.advance(const Duration(minutes: 3));
      final responseRecordId = await harness.persistUserMessage();
      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: responseRecordId,
        ),
        OutreachFeedbackMutationResult.recorded,
      );
      final entry = await harness.collector.get(scheduled.outreachId);
      expect(entry?.openedAt, scheduledFor);
      expect(entry?.outcome, OutreachFeedbackOutcome.responded);
      expect(entry?.responseLatency, const Duration(minutes: 3));
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.opened],
        1,
      );
    },
  );

  test(
    'exact foreground chat anchor wins among multiple pending outreach rows',
    () async {
      final harness = await _Harness.create('feedback-ambiguous.db');
      addTearDown(harness.close);
      final first = await harness.deliverForeground(source: 'foreground:one');
      await harness.collector.recordDelivered(first);
      harness.clock.advance(const Duration(minutes: 2));
      final second = await harness.deliverForeground(source: 'foreground:two');
      await harness.collector.recordDelivered(second);

      harness.clock.advance(const Duration(minutes: 1));
      final messageRecordId = await harness.persistUserMessage();
      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.recorded,
      );
      expect((await harness.collector.get(first.outreachId))?.outcome, isNull);
      expect(
        (await harness.collector.get(second.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );
      expect(harness.collector.state.value.unattributedResponses, 0);
    },
  );

  test(
    'intervening ordinary agent row prevents foreground response attribution',
    () async {
      final harness = await _Harness.create('feedback-adjacency-break.db');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(
        source: 'adjacency-break',
      );
      await harness.collector.recordDelivered(delivered);
      harness.clock.advance(const Duration(minutes: 1));
      await harness.persistAgentMessage();
      await harness.persistUserMessage();

      await harness.collector.deactivateAndDrain();
      final restored = await OutreachFeedbackCollector(
        accountDatabase: harness.database,
        ledger: harness.ledger,
        featureFlags: harness.flags,
        clock: () => harness.clock.now,
      ).init();
      addTearDown(restored.deactivateAndDrain);

      expect((await restored.get(delivered.outreachId))?.outcome, isNull);
      expect(restored.state.value.unattributedResponses, 1);
      expect(restored.posterior.availableMass, 1);
      expect(restored.posterior.unavailableMass, 4);
    },
  );

  test(
    'corrupt matched foreground anchor cannot fall back to an opened OS row',
    () async {
      final harness = await _Harness.create('feedback-corrupt-anchor.db');
      addTearDown(harness.close);
      const source = 'os:v3:test:corrupt-anchor';
      const delivery = 'proactive:v3:test:corrupt-anchor';
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: source,
        deliveryId: delivery,
        topicKey: 'presence.time.morning',
        scheduledFor: harness.clock.now,
        expiresAt: harness.clock.now.add(const Duration(hours: 1)),
        now: harness.clock.now,
      );
      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: delivery,
          sourceEventId: source,
          now: harness.clock.now,
        ),
        isTrue,
      );
      await harness.collector.recordOpened(outreachId: scheduled.outreachId);
      final foreground = await harness.deliverForeground(
        source: 'corrupt-anchor',
      );
      await harness.collector.recordDelivered(foreground);

      final visibleRecordId = foreground.visibleMessageRecordId!;
      final visible = await _chatMessageStore
          .record(visibleRecordId)
          .get(harness.database.raw);
      await _chatMessageStore.record(visibleRecordId).put(
        harness.database.raw,
        <String, Object?>{...visible!, 'idempotencyKey': 'corrupt'},
      );
      harness.clock.advance(const Duration(minutes: 1));
      final messageRecordId = await harness.persistUserMessage();

      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.noEligibleOutreach,
      );
      expect(
        (await harness.collector.get(foreground.outreachId))?.outcome,
        isNull,
      );
      expect(
        (await harness.collector.get(scheduled.outreachId))?.outcome,
        isNull,
      );
      expect(harness.collector.state.value.unattributedResponses, 0);
    },
  );

  test(
    'durable human row is replayed when the delivery hook arrives later',
    () async {
      final harness = await _Harness.create(
        'feedback-delayed-delivery-hook.db',
      );
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(
        source: 'delayed-delivery-hook',
      );
      harness.clock.advance(const Duration(minutes: 1));
      await harness.persistUserMessage();

      expect(
        await harness.collector.recordDelivered(delivered),
        OutreachFeedbackMutationResult.recorded,
      );
      final entry = await harness.collector.get(delivered.outreachId);
      expect(entry?.outcome, OutreachFeedbackOutcome.responded);
      expect(entry?.responseLatency, const Duration(minutes: 1));
    },
  );

  test(
    'offsetless human timestamp is rejected instead of timezone replay',
    () async {
      final harness = await _Harness.create('feedback-offsetless-time.db');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(
        source: 'offsetless-time',
      );
      await harness.collector.recordDelivered(delivered);
      harness.clock.advance(const Duration(minutes: 1));
      final messageRecordId = await harness.database.saveChatMessage(
        ChatMessage(
          sessionId: 'self',
          senderId: 'user',
          receiverId: 'self',
          content: 'not-visible-to-feedback',
          timestamp: harness.clock.now.toLocal(),
          isUserMessage: true,
          turnOrigin: ChatMessageTurnOrigins.user,
        ),
      );

      // Normal message serialization always emits UTC. Seed the malformed
      // persisted field directly to exercise rejection of offsetless history.
      final persisted = await _chatMessageStore
          .record(messageRecordId)
          .get(harness.database.raw);
      final offsetlessTimestamp = harness.clock.now.toLocal().toIso8601String();
      expect(offsetlessTimestamp.endsWith('Z'), isFalse);
      await _chatMessageStore.record(messageRecordId).put(
        harness.database.raw,
        <String, Object?>{...persisted!, 'timestamp': offsetlessTimestamp},
      );

      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.rejected,
      );
      expect(
        (await harness.collector.get(delivered.outreachId))?.outcome,
        isNull,
      );
    },
  );

  test(
    'committed foreground anchor blocks OS fallback until delivery finalizes',
    () async {
      final harness = await _Harness.create(
        'feedback-committed-response-race.db',
      );
      addTearDown(harness.close);
      const osSource = 'os:v3:test:committed-race';
      const osDelivery = 'proactive:v3:test:committed-race';
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: osSource,
        deliveryId: osDelivery,
        topicKey: 'presence.time.morning',
        scheduledFor: harness.clock.now,
        expiresAt: harness.clock.now.add(const Duration(hours: 1)),
        now: harness.clock.now,
      );
      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: osDelivery,
          sourceEventId: osSource,
          now: harness.clock.now,
        ),
        isTrue,
      );
      await harness.collector.recordOpened(outreachId: scheduled.outreachId);

      final foreground = await harness.commitForeground(
        source: 'committed-response-race',
      );
      harness.clock.advance(const Duration(minutes: 1));
      final messageRecordId = await harness.persistUserMessage();
      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.noEligibleOutreach,
      );
      expect(
        (await harness.collector.get(scheduled.outreachId))?.outcome,
        isNull,
        reason: 'The exact foreground predecessor must block OS fallback.',
      );

      final delivered = await harness.ledger.markDelivered(
        foreground.reservation,
        now: harness.clock.now,
      );
      await harness.collector.recordDelivered(delivered);
      expect(
        (await harness.collector.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );
      expect(
        (await harness.collector.get(scheduled.outreachId))?.outcome,
        isNull,
      );
      expect(harness.collector.state.value.unattributedResponses, 0);
    },
  );

  test(
    'ignored and explicit dismissed outcomes replay bounded evidence',
    () async {
      final ignoredHarness = await _Harness.create('feedback-ignored.db');
      addTearDown(ignoredHarness.close);
      final ignored = await ignoredHarness.deliverForeground(
        source: 'foreground:ignored',
      );
      await ignoredHarness.collector.recordDelivered(ignored);
      ignoredHarness.clock.advance(const Duration(hours: 2, seconds: 1));
      await ignoredHarness.collector.reconcile(now: ignoredHarness.clock.now);

      expect(
        (await ignoredHarness.collector.get(ignored.outreachId))?.outcome,
        OutreachFeedbackOutcome.ignored,
      );
      expect(ignoredHarness.collector.posterior.availableMass, 1);
      expect(ignoredHarness.collector.posterior.unavailableMass, 5.25);

      final lateMessageRecordId = await ignoredHarness.persistUserMessage(
        at: ignored.deliveredAt!.add(const Duration(hours: 1, minutes: 59)),
      );
      expect(
        await ignoredHarness.collector.recordUserResponse(
          messageRecordId: lateMessageRecordId,
        ),
        OutreachFeedbackMutationResult.recorded,
        reason: 'A durable pre-deadline reply may arrive after timer replay.',
      );
      expect(
        (await ignoredHarness.collector.get(ignored.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );
      expect(ignoredHarness.collector.posterior.availableMass, 2);
      expect(ignoredHarness.collector.posterior.unavailableMass, 4);

      final dismissedHarness = await _Harness.create('feedback-dismissed.db');
      addTearDown(dismissedHarness.close);
      final dismissed = await dismissedHarness.deliverForeground(
        source: 'foreground:dismissed',
      );
      await dismissedHarness.collector.recordDelivered(dismissed);
      dismissedHarness.clock.advance(const Duration(minutes: 1));
      expect(
        await dismissedHarness.collector.recordDismissed(
          outreachId: dismissed.outreachId,
          at: dismissedHarness.clock.now,
        ),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(dismissedHarness.collector.posterior.availableMass, 1);
      expect(dismissedHarness.collector.posterior.unavailableMass, 6);
    },
  );

  test(
    'durable mute state counts transitions, not unrelated revisions',
    () async {
      final harness = await _Harness.create('feedback-muted.db');
      addTearDown(harness.close);

      expect(
        await harness.collector.recordMuted(preferenceRevision: 7),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        await harness.collector.recordMuted(preferenceRevision: 8),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        await harness.collector.recordMuted(preferenceRevision: 8),
        OutreachFeedbackMutationResult.duplicate,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        1,
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome.muted],
        1,
      );
      expect(harness.collector.posterior.availableMass, 1);
      expect(harness.collector.posterior.unavailableMass, 4);

      final rows = await _muteStore.find(harness.database.raw);
      expect(rows, hasLength(1));
      expect(rows.single.key, isNot('7'));
      expect(rows.single.key, hasLength(64));

      expect(
        await harness.collector.recordUnmuted(preferenceRevision: 9),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        await harness.collector.recordMuted(preferenceRevision: 10),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        2,
      );
      expect(await _muteStore.count(harness.database.raw), 2);
      expect(harness.collector.posterior.availableMass, 1);
      expect(harness.collector.posterior.unavailableMass, 4);
    },
  );

  test(
    'responded and account mute remain distinct availability and preference facts',
    () async {
      final harness = await _Harness.create('feedback-response-and-mute.db');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(
        source: 'response-and-mute',
      );
      await harness.collector.recordDelivered(delivered);
      final messageRecordId = await harness.persistUserMessage();

      expect(
        await harness.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        await harness.collector.recordMuted(preferenceRevision: 8),
        OutreachFeedbackMutationResult.recorded,
      );

      expect(harness.collector.posterior.availableMass, 2);
      expect(harness.collector.posterior.unavailableMass, 4);
      expect(harness.collector.state.value.posteriorSamples, 1);
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome
            .responded],
        1,
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome.muted],
        1,
      );
    },
  );

  test('mute baseline stays current while shadow rollout is off', () async {
    final harness = await _Harness.create('feedback-muted-rollout-off.db');
    addTearDown(harness.close);

    expect(
      await harness.collector.recordMuted(preferenceRevision: 7),
      OutreachFeedbackMutationResult.recorded,
    );
    await harness.flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.off,
      revision: 2,
      expiresAt: harness.clock.now.add(const Duration(days: 30)),
    );
    await harness.collector.waitForIdle();
    expect(
      await harness.collector.recordUnmuted(preferenceRevision: 8),
      OutreachFeedbackMutationResult.disabled,
    );

    await harness.flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 3,
      expiresAt: harness.clock.now.add(const Duration(days: 30)),
    );
    expect(
      await harness.collector.recordMuted(preferenceRevision: 9),
      OutreachFeedbackMutationResult.recorded,
    );

    expect(
      harness.collector.state.value.events[OutreachFeedbackSignal.muted],
      2,
    );
    expect(await _muteStore.count(harness.database.raw), 2);
  });

  test(
    'off-admitted mute cannot become shadow evidence while queued',
    () async {
      final harness = await _Harness.create('feedback-mute-admission-race.db');
      addTearDown(harness.close);

      harness.flags.setRuntimeMaximum(
        MaasoFeatureFlag.proactiveDrive,
        FeatureRolloutMode.off,
      );
      await harness.collector.waitForIdle();

      final admittedWhileOff = harness.collector.recordMuted(
        preferenceRevision: 7,
      );
      harness.flags.setRuntimeMaximum(
        MaasoFeatureFlag.proactiveDrive,
        FeatureRolloutMode.shadow,
      );
      expect(await admittedWhileOff, OutreachFeedbackMutationResult.disabled);
      await harness.collector.waitForIdle();
      expect(await _muteStore.count(harness.database.raw), 0);

      expect(
        await harness.collector.recordUnmuted(preferenceRevision: 8),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        await harness.collector.recordMuted(preferenceRevision: 9),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(await _muteStore.count(harness.database.raw), 1);
    },
  );

  test(
    'assignment expiry clears pending feedback without a flag event',
    () async {
      final harness = await _Harness.create('feedback-rollout-expiry.db');
      addTearDown(harness.close);
      await harness.flags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.shadow,
        revision: 2,
        expiresAt: harness.clock.now.add(const Duration(milliseconds: 100)),
      );
      await harness.collector.waitForIdle();
      final delivered = await harness.deliverForeground(
        source: 'rollout-expiry',
      );
      await harness.collector.recordDelivered(delivered);
      expect(await harness.collector.get(delivered.outreachId), isNotNull);

      harness.clock.advance(const Duration(milliseconds: 150));
      await Future<void>.delayed(const Duration(milliseconds: 180));
      await harness.collector.waitForIdle();

      expect(harness.collector.isCollecting, isFalse);
      expect(await harness.collector.get(delivered.outreachId), isNull);
      expect(
        harness.collector.posterior,
        ContactAvailabilityBelief.conservative,
      );
    },
  );

  test('mute persists an exact-deadline ignore across restart', () async {
    final harness = await _Harness.create('feedback-mute-deadline.db');
    addTearDown(harness.close);
    final delivered = await harness.deliverForeground(source: 'mute-deadline');
    await harness.collector.recordDelivered(delivered);
    harness.clock.advance(const Duration(hours: 2));

    await harness.collector.recordMuted(preferenceRevision: 9);
    expect(
      (await harness.collector.get(delivered.outreachId))?.outcome,
      OutreachFeedbackOutcome.ignored,
    );

    await harness.collector.deactivateAndDrain();
    final restored = await OutreachFeedbackCollector(
      accountDatabase: harness.database,
      ledger: harness.ledger,
      featureFlags: harness.flags,
      clock: () => harness.clock.now,
    ).init();
    addTearDown(restored.deactivateAndDrain);
    expect(
      (await restored.get(delivered.outreachId))?.outcome,
      OutreachFeedbackOutcome.ignored,
    );
  });

  test(
    'restart restores facts while disabled and retired collectors fail closed',
    () async {
      final harness = await _Harness.create('feedback-restore.db');
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(source: 'restore:one');
      await harness.collector.recordDelivered(delivered);
      harness.clock.advance(const Duration(minutes: 1));
      final messageRecordId = await harness.persistUserMessage();
      await harness.collector.recordUserResponse(
        messageRecordId: messageRecordId,
      );
      await harness.collector.deactivateAndDrain();

      final restored = await OutreachFeedbackCollector(
        accountDatabase: harness.database,
        ledger: harness.ledger,
        featureFlags: harness.flags,
        clock: () => harness.clock.now,
      ).init();
      addTearDown(restored.deactivateAndDrain);
      expect(restored.posterior.availableMass, 2);
      expect(restored.state.value.posteriorSamples, 1);

      await restored.deactivateAndDrain();
      expect(restored.posterior, same(ContactAvailabilityBelief.conservative));
      expect(
        await restored.recordUserResponse(messageRecordId: messageRecordId),
        OutreachFeedbackMutationResult.retired,
      );
    },
  );

  test('restart replays a durable user message after a crash gap', () async {
    final harness = await _Harness.create('feedback-response-replay.db');
    addTearDown(harness.close);
    final delivered = await harness.deliverForeground(source: 'replay-gap');
    await harness.collector.recordDelivered(delivered);
    harness.clock.advance(const Duration(minutes: 2));
    await harness.persistUserMessage();

    await harness.collector.deactivateAndDrain();
    final restored = await OutreachFeedbackCollector(
      accountDatabase: harness.database,
      ledger: harness.ledger,
      featureFlags: harness.flags,
      clock: () => harness.clock.now,
    ).init();
    addTearDown(restored.deactivateAndDrain);

    final entry = await restored.get(delivered.outreachId);
    expect(entry?.outcome, OutreachFeedbackOutcome.responded);
    expect(entry?.responseLatency, const Duration(minutes: 2));
  });

  test(
    'first activation does not backfill retained historical ledger rows',
    () async {
      final harness = await _Harness.create(
        'feedback-activation-watermark.db',
        initializeCollector: false,
      );
      addTearDown(harness.close);
      final oldDelivery = await harness.deliverForeground(
        source: 'before-flag',
      );
      harness.clock.advance(const Duration(days: 1));

      await harness.collector.init();

      expect(await harness.collector.get(oldDelivery.outreachId), isNull);
      expect(harness.collector.state.value.posteriorSamples, 0);
    },
  );

  test('off-to-shadow rollout starts a fresh attribution epoch', () async {
    final harness = await _Harness.create('feedback-rollout-epoch.db');
    addTearDown(harness.close);
    final oldPending = await harness.deliverForeground(source: 'before-off');
    await harness.collector.recordDelivered(oldPending);

    harness.clock.advance(const Duration(minutes: 1));
    await harness.flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.off,
      revision: 2,
      expiresAt: harness.clock.now.add(const Duration(days: 30)),
    );
    await harness.collector.waitForIdle();
    expect(await harness.collector.get(oldPending.outreachId), isNull);

    harness.clock.advance(const Duration(minutes: 1));
    final whileOff = await harness.deliverForeground(source: 'while-off');
    expect(
      await harness.collector.recordDelivered(whileOff),
      OutreachFeedbackMutationResult.disabled,
    );
    harness.clock.advance(const Duration(minutes: 1));
    await harness.persistUserMessage();

    harness.clock.advance(const Duration(minutes: 1));
    await harness.flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 3,
      expiresAt: harness.clock.now.add(const Duration(days: 30)),
    );
    harness.clock.advance(const Duration(minutes: 1));
    final afterEnable = await harness.deliverForeground(source: 'after-enable');
    await harness.collector.recordDelivered(afterEnable);
    harness.clock.advance(const Duration(minutes: 1));
    final responseRecordId = await harness.persistUserMessage();
    await harness.collector.recordUserResponse(
      messageRecordId: responseRecordId,
    );

    expect(await harness.collector.get(whileOff.outreachId), isNull);
    expect(
      (await harness.collector.get(afterEnable.outreachId))?.outcome,
      OutreachFeedbackOutcome.responded,
    );
    expect(harness.collector.state.value.posteriorSamples, 1);
    expect(harness.collector.posterior.availableMass, 2);
    expect(harness.collector.posterior.unavailableMass, 4);
  });

  test(
    'shadow-enforce transitions preserve pending attribution across restart',
    () async {
      final harness = await _Harness.create(
        'feedback-observation-mode-transition.db',
      );
      addTearDown(harness.close);
      final delivered = await harness.deliverForeground(
        source: 'before-enforce',
      );
      await harness.collector.recordDelivered(delivered);

      await harness.flags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.enforce,
        revision: 2,
        expiresAt: harness.clock.now.add(const Duration(days: 30)),
      );
      await harness.collector.waitForIdle();
      expect(harness.collector.state.value.pending, 1);
      expect(await harness.collector.get(delivered.outreachId), isNotNull);

      await harness.collector.deactivateAndDrain();
      final restored = await OutreachFeedbackCollector(
        accountDatabase: harness.database,
        ledger: harness.ledger,
        featureFlags: harness.flags,
        clock: () => harness.clock.now,
      ).init();
      addTearDown(restored.deactivateAndDrain);
      expect(restored.state.value.pending, 1);

      await harness.flags.assign(
        flag: MaasoFeatureFlag.proactiveDrive,
        mode: FeatureRolloutMode.shadow,
        revision: 3,
        expiresAt: harness.clock.now.add(const Duration(days: 30)),
      );
      await restored.waitForIdle();
      harness.clock.advance(const Duration(minutes: 1));
      final responseRecordId = await harness.persistUserMessage();
      expect(
        await restored.recordUserResponse(messageRecordId: responseRecordId),
        OutreachFeedbackMutationResult.recorded,
      );

      expect(
        (await restored.get(delivered.outreachId))?.outcome,
        OutreachFeedbackOutcome.responded,
      );
      expect(restored.state.value.posteriorSamples, 1);
      expect(restored.posterior.availableMass, 2);
      expect(restored.posterior.unavailableMass, 4);
    },
  );

  test('offline revision gap starts a fresh attribution epoch', () async {
    final harness = await _Harness.create('feedback-offline-rollout-gap.db');
    addTearDown(harness.close);
    final delivered = await harness.deliverForeground(
      source: 'before-offline-gap',
    );
    await harness.collector.recordDelivered(delivered);
    harness.clock.advance(const Duration(minutes: 1));
    await harness.collector.deactivateAndDrain();

    await harness.flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.off,
      revision: 2,
      expiresAt: harness.clock.now.add(const Duration(days: 30)),
    );
    await harness.flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.enforce,
      revision: 3,
      expiresAt: harness.clock.now.add(const Duration(days: 30)),
    );

    final restored = await OutreachFeedbackCollector(
      accountDatabase: harness.database,
      ledger: harness.ledger,
      featureFlags: harness.flags,
      clock: () => harness.clock.now,
    ).init();
    addTearDown(restored.deactivateAndDrain);

    expect(restored.state.value.pending, 0);
    expect(await restored.get(delivered.outreachId), isNull);
    expect(restored.state.value.posteriorSamples, 0);
    expect(restored.posterior.availableMass, 1);
    expect(restored.posterior.unavailableMass, 4);
  });

  test('delayed delivery callback settles against the current clock', () async {
    final harness = await _Harness.create('feedback-delayed-delivery.db');
    addTearDown(harness.close);
    final delivered = await harness.deliverForeground(source: 'delayed-hook');
    harness.clock.advance(const Duration(hours: 2));

    expect(
      await harness.collector.recordDelivered(delivered),
      OutreachFeedbackMutationResult.recorded,
    );
    expect(
      (await harness.collector.get(delivered.outreachId))?.outcome,
      OutreachFeedbackOutcome.ignored,
    );
  });

  test(
    'proportional mass bounding preserves a long-run mixed posterior',
    () async {
      final harness = await _Harness.create(
        'feedback-posterior-scaling.db',
        initializeCollector: false,
      );
      addTearDown(harness.close);
      for (var index = 0; index < 160; index++) {
        final deliveredAt = harness.clock.now.add(Duration(minutes: index));
        final responded = index < 80;
        final entry = OutreachFeedbackEntry(
          outreachId: (index + 1).toRadixString(16).padLeft(64, '0'),
          channel: OutreachChannel.foreground,
          deliveredAt: deliveredAt,
          respondedAt: responded ? deliveredAt : null,
          dismissedAt: responded ? null : deliveredAt,
        );
        await _feedbackStore
            .record(entry.outreachId)
            .put(harness.database.raw, entry.toStorageJson());
      }

      await harness.collector.init();

      expect(harness.collector.state.value.posteriorSamples, 160);
      expect(harness.collector.posterior.unavailableMass, 64);
      expect(
        harness.collector.posterior.probability.value,
        closeTo(81 / 245, 1e-9),
      );
    },
  );

  test(
    'expired OS delivery is projected without mutating production ledger',
    () async {
      final harness = await _Harness.create('feedback-read-only-ledger.db');
      addTearDown(harness.close);
      final scheduledFor = harness.clock.now.add(const Duration(minutes: 5));
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: 'os:v3:test:read-only',
        deliveryId: 'proactive:v3:test:read-only',
        topicKey: 'presence.time.morning',
        scheduledFor: scheduledFor,
        expiresAt: scheduledFor.add(const Duration(minutes: 5)),
        now: harness.clock.now,
      );
      harness.clock.advance(const Duration(minutes: 20));

      await harness.collector.reconcile(now: harness.clock.now);

      expect(
        (await harness.ledger.get(scheduled.outreachId))?.state,
        OutreachState.scheduledOs,
      );
      final projected = await harness.collector.get(scheduled.outreachId);
      expect(projected?.deliveredAt, scheduled.expiresAt);
      expect(projected?.outcome, isNull);

      harness.clock.set(scheduled.expiresAt!.add(const Duration(hours: 2)));
      await harness.collector.reconcile(now: harness.clock.now);
      expect(
        (await harness.collector.get(scheduled.outreachId))?.outcome,
        OutreachFeedbackOutcome.ignored,
      );
      expect(
        (await harness.ledger.get(scheduled.outreachId))?.state,
        OutreachState.scheduledOs,
      );
    },
  );

  test(
    'cancelling an unclaimed OS occurrence retracts inferred feedback',
    () async {
      final harness = await _Harness.create('feedback-os-cancel-retract.db');
      addTearDown(harness.close);
      const delivery = 'proactive:v3:test:cancel-retract';
      final scheduledFor = harness.clock.now.add(const Duration(minutes: 1));
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: 'os:v3:test:cancel-retract',
        deliveryId: delivery,
        topicKey: 'presence.time.morning',
        scheduledFor: scheduledFor,
        expiresAt: scheduledFor.add(const Duration(minutes: 1)),
        now: harness.clock.now,
      );
      harness.clock.set(scheduled.expiresAt!.add(const Duration(hours: 2)));
      await harness.collector.reconcile(now: harness.clock.now);
      expect(
        (await harness.collector.get(scheduled.outreachId))?.outcome,
        OutreachFeedbackOutcome.ignored,
      );

      await harness.ledger.cancelScheduledOsByDeliveryId(
        delivery,
        now: harness.clock.now,
      );
      await harness.collector.reconcile(now: harness.clock.now);

      expect(await harness.collector.get(scheduled.outreachId), isNull);
      expect(harness.collector.posterior.availableMass, 1);
      expect(harness.collector.posterior.unavailableMass, 4);
    },
  );

  test('claimed OS feedback survives a later platform cancellation', () async {
    final harness = await _Harness.create('feedback-os-claim-cancel.db');
    addTearDown(harness.close);
    const source = 'os:v3:test:claim-cancel';
    const delivery = 'proactive:v3:test:claim-cancel';
    final scheduledFor = harness.clock.now.add(const Duration(minutes: 1));
    final scheduled = await harness.ledger.scheduleOs(
      sourceEventId: source,
      deliveryId: delivery,
      topicKey: 'presence.time.morning',
      scheduledFor: scheduledFor,
      expiresAt: scheduledFor.add(const Duration(hours: 1)),
      now: harness.clock.now,
    );
    harness.clock.set(scheduledFor);
    expect(
      await harness.ledger.claimOsNotificationInteraction(
        outreachId: scheduled.outreachId,
        deliveryId: delivery,
        sourceEventId: source,
        now: harness.clock.now,
      ),
      isTrue,
    );
    await harness.collector.recordOpened(outreachId: scheduled.outreachId);
    harness.clock.advance(const Duration(minutes: 2));
    final messageRecordId = await harness.persistUserMessage();
    await harness.collector.recordUserResponse(
      messageRecordId: messageRecordId,
    );

    await harness.ledger.cancelScheduledOsByDeliveryId(
      delivery,
      now: harness.clock.now,
    );
    await harness.collector.reconcile(now: harness.clock.now);

    final entry = await harness.collector.get(scheduled.outreachId);
    expect(entry?.openedAt, scheduledFor);
    expect(entry?.outcome, OutreachFeedbackOutcome.responded);
  });

  test('OS ledger-change nudge arms the live expiry timer', () async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'feedback-live-os-timer.db',
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
      responseWindow: const Duration(minutes: 1),
    ).init();
    addTearDown(() async {
      await collector.deactivateAndDrain();
      await flags.deactivateAndDrain();
      await database.close();
    });

    final now = DateTime.now().toUtc();
    final expiresAt = now.add(const Duration(milliseconds: 120));
    final scheduled = await ledger.scheduleOs(
      sourceEventId: 'os:v3:test:live-timer',
      deliveryId: 'proactive:v3:test:live-timer',
      topicKey: 'presence.time.morning',
      scheduledFor: now.add(const Duration(milliseconds: 40)),
      expiresAt: expiresAt,
      now: now,
    );

    // This is the same best-effort reconcile invoked by the scheduler's
    // account-bound ledger-change callback after native scheduling succeeds.
    await collector.reconcile();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    await collector.waitForIdle();

    final projected = await collector.get(scheduled.outreachId);
    expect(projected, isNotNull);
    expect(projected?.deliveredAt, expiresAt);
    expect(projected?.outcome, isNull);
  });

  test(
    'late OS open uses open-to-response latency and survives restart',
    () async {
      final harness = await _Harness.create('feedback-late-os-open.db');
      addTearDown(harness.close);
      final scheduledFor = harness.clock.now.add(const Duration(minutes: 1));
      const source = 'os:v3:test:late-open';
      const delivery = 'proactive:v3:test:late-open';
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: source,
        deliveryId: delivery,
        topicKey: 'presence.time.morning',
        scheduledFor: scheduledFor,
        expiresAt: scheduledFor.add(const Duration(minutes: 1)),
        now: harness.clock.now,
      );
      harness.clock.set(scheduledFor.add(const Duration(days: 8)));
      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: delivery,
          sourceEventId: source,
          now: harness.clock.now,
        ),
        isTrue,
      );
      await harness.collector.recordOpened(outreachId: scheduled.outreachId);
      harness.clock.advance(const Duration(minutes: 3));
      final messageRecordId = await harness.persistUserMessage();
      await harness.collector.recordUserResponse(
        messageRecordId: messageRecordId,
      );

      expect(
        (await harness.collector.get(scheduled.outreachId))?.responseLatency,
        const Duration(minutes: 3),
      );
      await harness.collector.deactivateAndDrain();
      final restored = await OutreachFeedbackCollector(
        accountDatabase: harness.database,
        ledger: harness.ledger,
        featureFlags: harness.flags,
        clock: () => harness.clock.now,
      ).init();
      addTearDown(restored.deactivateAndDrain);
      expect(
        (await restored.get(scheduled.outreachId))?.responseLatency,
        const Duration(minutes: 3),
      );
    },
  );

  test(
    'corrupt feedback row degrades to conservative and rejects writes',
    () async {
      final harness = await _Harness.create(
        'feedback-corrupt.db',
        initializeCollector: false,
      );
      addTearDown(harness.close);
      await _feedbackStore.record('invalid-key').put(harness.database.raw, {
        'schemaVersion': 1,
        'unexpected': true,
      });

      final collector = await OutreachFeedbackCollector(
        accountDatabase: harness.database,
        ledger: harness.ledger,
        featureFlags: harness.flags,
        clock: () => harness.clock.now,
      ).init();
      addTearDown(collector.deactivateAndDrain);

      expect(collector.posterior, same(ContactAvailabilityBelief.conservative));
      expect(
        await collector.recordUserResponse(messageRecordId: 1),
        OutreachFeedbackMutationResult.disabled,
      );
      expect(collector.state.value.storageErrors, 1);
    },
  );
}

final StoreRef<String, Map<String, Object?>> _feedbackStore =
    StoreRef<String, Map<String, Object?>>(
      OutreachFeedbackCollector.storageName,
    );
final StoreRef<String, Map<String, Object?>> _muteStore =
    StoreRef<String, Map<String, Object?>>('outreach_feedback_mutes.v1');
final StoreRef<int, Map<String, Object?>> _chatMessageStore = intMapStoreFactory
    .store('chat_messages');

final class _MutableClock {
  _MutableClock(this.now);

  DateTime now;

  void advance(Duration duration) => now = now.add(duration);

  void set(DateTime value) => now = value;
}

final class _Harness {
  _Harness({
    required this.database,
    required this.flags,
    required this.ledger,
    required this.collector,
    required this.clock,
  });

  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactiveOutreachLedger ledger;
  final OutreachFeedbackCollector collector;
  final _MutableClock clock;
  var _sequence = 0;

  static Future<_Harness> create(
    String name, {
    bool initializeCollector = true,
  }) async {
    final clock = _MutableClock(DateTime.utc(2026, 8, 29, 8));
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: name,
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.enforce,
      },
      clock: () => clock.now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: clock.now.add(const Duration(days: 30)),
    );
    final ledger = ProactiveOutreachLedger(accountDatabase: database);
    final collector = initializeCollector
        ? await OutreachFeedbackCollector(
            accountDatabase: database,
            ledger: ledger,
            featureFlags: flags,
            clock: () => clock.now,
          ).init()
        : OutreachFeedbackCollector(
            accountDatabase: database,
            ledger: ledger,
            featureFlags: flags,
            clock: () => clock.now,
          );
    return _Harness(
      database: database,
      flags: flags,
      ledger: ledger,
      collector: collector,
      clock: clock,
    );
  }

  Future<OutreachRecord> deliverForeground({
    required String source,
    String topic = 'quietPresence',
  }) async {
    final committed = await commitForeground(source: source, topic: topic);
    return ledger.markDelivered(committed.reservation, now: clock.now);
  }

  Future<({OutreachRecord committed, OutreachReservation reservation})>
  commitForeground({
    required String source,
    String topic = 'quietPresence',
  }) async {
    final sequence = ++_sequence;
    final reservation = (await ledger.reserve(
      sourceEventId: '$source:$sequence',
      topicKey: topic,
      now: clock.now,
    ))!;
    final idempotencyKey = 'proactive:${reservation.outreachId}';
    final committed = await ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'feedback-fingerprint-$sequence',
      visibleMessageJson: ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: 'not-visible-to-feedback',
        timestamp: clock.now,
        turnOrigin: ChatMessageTurnOrigins.proactivePresence,
        idempotencyKey: idempotencyKey,
        outreachId: reservation.outreachId,
      ).toJson(),
      visibleMessageIdempotencyKey: idempotencyKey,
      now: clock.now,
    );
    return (committed: committed, reservation: reservation);
  }

  Future<int> persistAgentMessage({DateTime? at}) => database.saveChatMessage(
    ChatMessage(
      sessionId: 'self',
      senderId: 'self',
      receiverId: 'user',
      content: 'ordinary-agent-row',
      timestamp: (at ?? clock.now).toLocal(),
      turnOrigin: ChatMessageTurnOrigins.system,
    ),
  );

  Future<int> persistUserMessage({DateTime? at}) => database.saveChatMessage(
    ChatMessage(
      sessionId: 'self',
      senderId: 'user',
      receiverId: 'self',
      content: 'not-visible-to-feedback',
      timestamp: (at ?? clock.now).toUtc(),
      isUserMessage: true,
      turnOrigin: ChatMessageTurnOrigins.user,
    ),
  );

  Future<void> close() async {
    await collector.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await database.close();
  }
}
