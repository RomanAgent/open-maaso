import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test(
    'a repeated source candidate never starts a second generation',
    () async {
      final harness = await _Harness.create('coordinator-duplicate-source.db');
      addTearDown(harness.close);
      final now = DateTime(2026, 8, 26, 10);

      final first = await harness.coordinator.prepare(
        sourceEventId: 'presence:quiet:2026-08-26T10:00',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: now,
      );
      final inFlightRetry = await harness.coordinator.prepare(
        sourceEventId: 'presence:quiet:2026-08-26T10:00',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: now.add(const Duration(seconds: 1)),
      );

      expect(first.shouldGenerate, isTrue);
      expect(
        inFlightRetry.status,
        ProactivePreparationStatus.duplicateInFlight,
      );
      final committed = await harness.coordinator.commitDraft(
        attempt: first.attempt!,
        draft: '窗边的光落下来，安静陪你一会儿。',
        visibleMessageJson: _message('窗边的光落下来，安静陪你一会儿。', now),
        idempotencyKey: 'proactive:quiet:10:00',
        now: now.add(const Duration(seconds: 2)),
      );
      expect(committed.isAccepted, isTrue);

      final committedRetry = await harness.coordinator.prepare(
        sourceEventId: 'presence:quiet:2026-08-26T10:00',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: now.add(const Duration(minutes: 1)),
      );
      expect(committedRetry.shouldGenerate, isFalse);
      expect(committedRetry.status, ProactivePreparationStatus.silenced);
      expect(
        committedRetry.decision?.reason,
        ProactiveSilenceReason.waitingForReply,
      );
    },
  );

  test('a near-duplicate draft is suppressed before visible commit', () async {
    final harness = await _Harness.create('coordinator-near-duplicate.db');
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    const previous = '三天了，时间悄悄溜走，却留下一点暖意。';
    const repeated = '三天了，时间悄悄流走，却留下一点暖意。';

    final first = await harness.coordinator.prepare(
      sourceEventId: 'presence:quiet:first',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      now: now,
    );
    await harness.coordinator.commitDraft(
      attempt: first.attempt!,
      draft: previous,
      visibleMessageJson: _message(previous, now),
      idempotencyKey: 'proactive:first',
      now: now.add(const Duration(seconds: 1)),
    );
    final second = await harness.coordinator.prepare(
      sourceEventId: 'presence:time:second',
      lastUserActivityAt: now.add(const Duration(seconds: 30)),
      candidates: const <ProactiveTopicCandidate>[
        ProactiveTopicCandidate(
          kind: ProactiveTopicKind.timeOfDay,
          topicKey: 'time-of-day',
        ),
      ],
      now: now.add(const Duration(minutes: 1)),
    );

    expect(second.shouldGenerate, isTrue);
    final rejected = await harness.coordinator.commitDraft(
      attempt: second.attempt!,
      draft: repeated,
      visibleMessageJson: _message(repeated, now),
      idempotencyKey: 'proactive:second',
      now: now.add(const Duration(minutes: 1, seconds: 1)),
    );

    expect(rejected.isAccepted, isFalse);
    expect(rejected.decision.reason, ProactiveSilenceReason.nearDuplicateText);
    expect(rejected.record.state, OutreachState.suppressed);
    expect(await harness.chatMessages.count(harness.database.raw), 1);
    expect(
      await harness.coordinator.readHistory(
        now: now.add(const Duration(minutes: 1, seconds: 1)),
      ),
      hasLength(1),
    );
  });

  test('an accepted draft atomically binds one visible message', () async {
    final harness = await _Harness.create('coordinator-atomic-message.db');
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    const reply = '雨停了，窗外的空气看起来很清爽。';
    final preparation = await harness.coordinator.prepare(
      sourceEventId: 'presence:weather:cleared',
      candidates: const <ProactiveTopicCandidate>[
        ProactiveTopicCandidate(
          kind: ProactiveTopicKind.environmentObservation,
          topicKey: 'weather-cleared',
        ),
      ],
      now: now,
    );
    final message = _message(reply, now);

    final first = await harness.coordinator.commitDraft(
      attempt: preparation.attempt!,
      draft: reply,
      visibleMessageJson: message,
      idempotencyKey: 'proactive:weather:cleared',
      now: now.add(const Duration(seconds: 1)),
    );
    final retry = await harness.coordinator.commitDraft(
      attempt: preparation.attempt!,
      draft: reply,
      visibleMessageJson: message,
      idempotencyKey: 'proactive:weather:cleared',
      now: now.add(const Duration(seconds: 2)),
    );

    expect(first.isAccepted, isTrue);
    expect(retry.isAccepted, isTrue);
    expect(first.signature?.fingerprint, retry.signature?.fingerprint);
    expect(first.record.visibleMessageRecordId, isNotNull);
    expect(
      retry.record.visibleMessageRecordId,
      first.record.visibleMessageRecordId,
    );
    final rows = await harness.chatMessages.find(harness.database.raw);
    expect(rows, hasLength(1));
    expect(rows.single.value['outreachId'], preparation.attempt!.outreachId);
    expect(rows.single.value['idempotencyKey'], 'proactive:weather:cleared');

    final delivered = await harness.coordinator.markDelivered(
      preparation.attempt!,
      now: now.add(const Duration(seconds: 3)),
    );
    expect(delivered.state, OutreachState.delivered);
  });

  test(
    'hard gate change at transaction boundary rolls back visible commit',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'coordinator-hard-gate-transaction.db',
      );
      addTearDown(database.close);
      final policy = _CloseGateAfterDraftPolicy();
      final ledger = ProactiveOutreachLedger(accountDatabase: database);
      final coordinator = ProactiveOutreachCoordinator(
        policy: policy,
        ledger: ledger,
        accountKey: 'account:hard-gate-transaction',
      );
      final messages = intMapStoreFactory.store('chat_messages');
      final now = DateTime(2026, 8, 26, 10);
      final preparation = await coordinator.prepare(
        sourceEventId: 'presence:hard-gate-transaction',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: now,
      );
      expect(preparation.shouldGenerate, isTrue);
      policy.closeAfterNextDraft = true;

      final commit = await coordinator.commitDraft(
        attempt: preparation.attempt!,
        draft: '这条消息必须在静音切换后回滚。',
        visibleMessageJson: _message('这条消息必须在静音切换后回滚。', now),
        idempotencyKey: 'proactive:hard-gate-transaction',
        now: now.add(const Duration(seconds: 1)),
      );

      expect(commit.isAccepted, isFalse);
      expect(
        commit.decision.reason,
        ProactiveSilenceReason.dailyBudgetExhausted,
      );
      expect(commit.record.state, OutreachState.suppressed);
      expect(await messages.count(database.raw), 0);
      expect(await coordinator.readHistory(now: now), isEmpty);
    },
  );

  test(
    'quiet-hours crossing at transaction boundary rolls back visible commit',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'coordinator-quiet-boundary-transaction.db',
      );
      addTearDown(database.close);
      final clock = _MutableCoordinatorClock(DateTime(2026, 8, 26, 21, 59));
      final policy = _AdvanceClockAfterDraftPolicy(
        advance: () => clock.now = DateTime(2026, 8, 26, 22),
      );
      final ledger = ProactiveOutreachLedger(
        accountDatabase: database,
        clock: clock.call,
      );
      final coordinator = ProactiveOutreachCoordinator(
        policy: policy,
        ledger: ledger,
        accountKey: 'account:quiet-boundary-transaction',
        clock: clock.call,
      );
      final messages = intMapStoreFactory.store('chat_messages');
      final preparation = await coordinator.prepare(
        sourceEventId: 'presence:quiet-boundary-transaction',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: clock.call(),
      );
      expect(preparation.shouldGenerate, isTrue);
      policy.advanceAfterNextDraft = true;

      final commit = await coordinator.commitDraft(
        attempt: preparation.attempt!,
        draft: '跨入静默时段后不能出现。',
        visibleMessageJson: _message('跨入静默时段后不能出现。', clock.call()),
        idempotencyKey: 'proactive:quiet-boundary-transaction',
        now: clock.call(),
      );

      expect(commit.isAccepted, isFalse);
      expect(commit.decision.reason, ProactiveSilenceReason.quietHours);
      expect(commit.record.state, OutreachState.suppressed);
      expect(clock.now.hour, 22);
      expect(await messages.count(database.raw), 0);
    },
  );

  test('OS schedules and foreground commits share the daily budget', () async {
    final harness = await _Harness.create(
      'coordinator-shared-budget.db',
      config: _config(foregroundDailyLimit: 1),
    );
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    await harness.ledger.scheduleOs(
      sourceEventId: 'os:evening:2026-08-26',
      topicKey: 'evening-check-in',
      scheduledFor: now.add(const Duration(hours: 8)),
      expiresAt: now.add(const Duration(hours: 9)),
      now: now,
    );

    final preparation = await harness.coordinator.prepare(
      sourceEventId: 'presence:quiet:after-os-reservation',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      now: now.add(const Duration(minutes: 1)),
    );

    expect(preparation.shouldGenerate, isFalse);
    expect(preparation.status, ProactivePreparationStatus.silenced);
    expect(
      preparation.decision?.reason,
      ProactiveSilenceReason.waitingForReply,
    );
  });

  test(
    'OS reservation uses the lower policy and requested daily limit',
    () async {
      final policyLimited = await _Harness.create(
        'coordinator-os-policy-limit.db',
        config: _config(foregroundDailyLimit: 1),
      );
      final preferenceLimited = await _Harness.create(
        'coordinator-os-preference-limit.db',
        config: _config(foregroundDailyLimit: 3),
      );
      addTearDown(policyLimited.close);
      addTearDown(preferenceLimited.close);
      final now = DateTime(2026, 8, 26, 10);

      final policyFirst = await policyLimited.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:policy-limit:first',
        deliveryId: 'delivery:policy-limit:first',
        topicKey: 'presence.time.morning',
        scheduledFor: now.add(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        requestedDailyBudgetLimit: 3,
        now: now,
      );
      final policySecond = await policyLimited.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:policy-limit:second',
        deliveryId: 'delivery:policy-limit:second',
        topicKey: 'presence.time.midday',
        scheduledFor: now.add(const Duration(hours: 2)),
        expiresAt: now.add(const Duration(hours: 3)),
        requestedDailyBudgetLimit: 3,
        now: now,
      );
      final preferenceFirst = await preferenceLimited.coordinator
          .scheduleOsOccurrence(
            sourceEventId: 'os:preference-limit:first',
            deliveryId: 'delivery:preference-limit:first',
            topicKey: 'presence.time.morning',
            scheduledFor: now.add(const Duration(hours: 1)),
            expiresAt: now.add(const Duration(hours: 2)),
            requestedDailyBudgetLimit: 1,
            now: now,
          );
      final preferenceSecond = await preferenceLimited.coordinator
          .scheduleOsOccurrence(
            sourceEventId: 'os:preference-limit:second',
            deliveryId: 'delivery:preference-limit:second',
            topicKey: 'presence.time.midday',
            scheduledFor: now.add(const Duration(hours: 2)),
            expiresAt: now.add(const Duration(hours: 3)),
            requestedDailyBudgetLimit: 1,
            now: now,
          );

      expect(policyFirst?.state, OutreachState.scheduledOs);
      expect(policySecond, isNull);
      expect(preferenceFirst?.state, OutreachState.scheduledOs);
      expect(preferenceSecond, isNull);
    },
  );

  test(
    'confirmed platform cancellation releases the shared budget slot',
    () async {
      final harness = await _Harness.create(
        'coordinator-os-cancellation.db',
        config: _config(foregroundDailyLimit: 1),
      );
      addTearDown(harness.close);
      final now = DateTime(2026, 8, 26, 10);
      final scheduled = await harness.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:cancel:first',
        deliveryId: 'delivery:cancel:first',
        topicKey: 'presence.time.morning',
        scheduledFor: now.add(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        requestedDailyBudgetLimit: 1,
        now: now,
      );

      final cancelled = await harness.coordinator.confirmOsDeliveryCancelled(
        deliveryId: 'delivery:cancel:first',
        reason: 'platform_confirmed_cancelled',
        now: now.add(const Duration(minutes: 1)),
      );
      final replacement = await harness.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:cancel:replacement',
        deliveryId: 'delivery:cancel:replacement',
        topicKey: 'presence.time.midday',
        scheduledFor: now.add(const Duration(hours: 2)),
        expiresAt: now.add(const Duration(hours: 3)),
        requestedDailyBudgetLimit: 1,
        now: now.add(const Duration(minutes: 1)),
      );

      expect(cancelled, hasLength(1));
      expect(cancelled.single.outreachId, scheduled!.outreachId);
      expect(cancelled.single.state, OutreachState.cancelled);
      expect(cancelled.single.terminalReason, 'platform_confirmed_cancelled');
      expect(replacement?.state, OutreachState.scheduledOs);
    },
  );

  test('OS recovery and lookup expose the durable lifecycle record', () async {
    final harness = await _Harness.create('coordinator-os-recovery.db');
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    final scheduled = await harness.coordinator.scheduleOsOccurrence(
      sourceEventId: 'os:recover:morning',
      deliveryId: 'delivery:recover:morning',
      topicKey: 'presence.time.morning',
      evidenceKey: 'evidence:recover:morning',
      scheduledFor: now.add(const Duration(hours: 1)),
      expiresAt: now.add(const Duration(hours: 2)),
      requestedDailyBudgetLimit: 3,
      now: now,
    );

    final recovered = await harness.coordinator.recoverOutreach(
      now: now.add(const Duration(hours: 3)),
    );
    final stored = await harness.coordinator.getOutreach(scheduled!.outreachId);
    final claimed = await harness.coordinator.claimOsNotificationInteraction(
      outreachId: scheduled.outreachId,
      deliveryId: 'delivery:recover:morning',
      sourceEventId: 'os:recover:morning',
      now: now.add(const Duration(hours: 3)),
    );
    final duplicate = await harness.coordinator.claimOsNotificationInteraction(
      outreachId: scheduled.outreachId,
      deliveryId: 'delivery:recover:morning',
      sourceEventId: 'os:recover:morning',
      now: now.add(const Duration(hours: 3, minutes: 1)),
    );

    expect(
      recovered.where((record) => record.outreachId == scheduled.outreachId),
      hasLength(1),
    );
    expect(stored?.state, OutreachState.assumedDelivered);
    expect(stored?.deliveryId, 'delivery:recover:morning');
    expect(claimed, isTrue);
    expect(duplicate, isFalse);
  });

  test(
    'OS coordinator holds one future contact until a human returns',
    () async {
      final harness = await _Harness.create('coordinator-active-os.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final late = await harness.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:coordinator:late',
        deliveryId: 'delivery:coordinator:late',
        topicKey: 'presence.time.afternoon',
        scheduledFor: now.add(const Duration(hours: 5)),
        expiresAt: now.add(const Duration(hours: 6)),
        requestedDailyBudgetLimit: 3,
        now: now,
      );
      final early = await harness.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:coordinator:early',
        deliveryId: 'delivery:coordinator:early',
        topicKey: 'presence.time.morning',
        scheduledFor: now.add(const Duration(hours: 2)),
        expiresAt: now.add(const Duration(hours: 3)),
        requestedDailyBudgetLimit: 3,
        now: now,
      );

      final active = await harness.coordinator.activeScheduledOs(
        recoverThrough: now.add(const Duration(minutes: 1)),
      );

      expect(active.map((record) => record.outreachId), <String>[
        late!.outreachId,
      ]);
      expect(early, isNull);
      expect(() => active.clear(), throwsUnsupportedError);
    },
  );

  test('OS coordinator rejects invalid budget and identifiers', () async {
    final harness = await _Harness.create('coordinator-os-validation.db');
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);

    expect(
      () => harness.coordinator.scheduleOsOccurrence(
        sourceEventId: 'os:invalid-budget',
        deliveryId: 'delivery:invalid-budget',
        topicKey: 'presence.time.morning',
        scheduledFor: now.add(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        requestedDailyBudgetLimit: -1,
        now: now,
      ),
      throwsArgumentError,
    );
    expect(
      () => harness.coordinator.confirmOsDeliveryCancelled(deliveryId: ' '),
      throwsArgumentError,
    );
    expect(
      () => harness.coordinator.claimOsNotificationInteraction(
        outreachId: ' ',
        deliveryId: 'delivery',
        sourceEventId: 'source',
      ),
      throwsArgumentError,
    );
    expect(() => harness.coordinator.getOutreach(''), throwsArgumentError);
  });

  test(
    'a late OS budget race suppresses the buffered foreground draft',
    () async {
      final harness = await _Harness.create(
        'coordinator-late-os-budget-race.db',
        config: _config(foregroundDailyLimit: 1),
      );
      addTearDown(harness.close);
      final now = DateTime(2026, 8, 26, 10);
      final preparation = await harness.coordinator.prepare(
        sourceEventId: 'presence:quiet:late-budget-race',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: now,
      );
      expect(preparation.shouldGenerate, isTrue);

      // Simulate a legacy/out-of-band scheduler that did not participate in the
      // reservation budget. commitDraft must still close the final race inside
      // the ledger transaction before a visible message is written.
      await harness.ledger.scheduleOs(
        sourceEventId: 'os:legacy:late-budget-race',
        topicKey: 'presence.time.evening',
        scheduledFor: now.add(const Duration(hours: 8)),
        expiresAt: now.add(const Duration(hours: 10)),
        now: now.add(const Duration(seconds: 1)),
      );

      final rejected = await harness.coordinator.commitDraft(
        attempt: preparation.attempt!,
        draft: '我安静地在这里陪你一会儿。',
        visibleMessageJson: _message('我安静地在这里陪你一会儿。', now),
        idempotencyKey: 'proactive:late-budget-race',
        now: now.add(const Duration(seconds: 2)),
      );

      expect(rejected.isAccepted, isFalse);
      expect(
        rejected.decision.reason,
        ProactiveSilenceReason.dailyBudgetExhausted,
      );
      expect(rejected.record.state, OutreachState.suppressed);
      expect(await harness.chatMessages.count(harness.database.raw), 0);
    },
  );

  test(
    'a queued OS contact reserves the next outreach across channels',
    () async {
      final harness = await _Harness.create(
        'coordinator-future-schedule.db',
        config: _config(
          foregroundDailyLimit: 4,
          minimumGlobalGap: const Duration(hours: 6),
          genericTopicCooldown: const Duration(days: 1),
        ),
      );
      addTearDown(harness.close);
      final now = DateTime(2026, 8, 26, 10);
      await harness.ledger.scheduleOs(
        sourceEventId: 'os:shared-topic:future',
        topicKey: 'shared-topic',
        evidenceKey: 'future-observation',
        scheduledFor: now.add(const Duration(hours: 4)),
        expiresAt: now.add(const Duration(hours: 5)),
        now: now,
      );

      final preparation = await harness.coordinator.prepare(
        sourceEventId: 'presence:shared-topic:now',
        candidates: const <ProactiveTopicCandidate>[
          ProactiveTopicCandidate(
            kind: ProactiveTopicKind.environmentObservation,
            topicKey: 'shared-topic',
            evidenceKey: 'current-observation',
          ),
        ],
        now: now.add(const Duration(minutes: 1)),
      );

      expect(preparation.shouldGenerate, isFalse);
      expect(
        preparation.decision?.reason,
        ProactiveSilenceReason.waitingForReply,
      );
    },
  );

  test('future OS schedules cannot crowd spoken policy history out', () async {
    final harness = await _Harness.create(
      'coordinator-future-history-crowd-out.db',
    );
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    final spoken = (await harness.ledger.reserve(
      sourceEventId: 'spoken-before-future-schedules',
      topicKey: 'spoken-topic',
      now: now,
    ))!;
    await harness.ledger.commitAccepted(
      spoken,
      normalizedFingerprint: 'sha256:spoken-before-future-schedules',
      now: now.add(const Duration(seconds: 1)),
    );
    for (var index = 0; index < 70; index++) {
      final target = now.add(Duration(days: 2, minutes: index));
      await harness.ledger.scheduleOs(
        sourceEventId: 'future-schedule:$index',
        deliveryId: 'proactive:future-schedule:$index',
        topicKey: 'future-topic:$index',
        scheduledFor: target,
        expiresAt: target.add(const Duration(hours: 1)),
        now: now.add(const Duration(seconds: 2)),
      );
    }

    final history = await harness.coordinator.readHistory(
      now: now.add(const Duration(days: 1, minutes: 1)),
    );

    expect(history, hasLength(1));
    expect(history.single.topicKey, 'spoken-topic');
    expect(
      history.single.normalizedTextHash,
      'sha256:spoken-before-future-schedules',
    );
  });

  test('jitter key is stable per account and local date', () async {
    final first = await _Harness.create(
      'coordinator-jitter-a.db',
      accountKey: 'account:a',
    );
    final second = await _Harness.create(
      'coordinator-jitter-b.db',
      accountKey: 'account:b',
    );
    addTearDown(first.close);
    addTearDown(second.close);
    final morning = DateTime(2026, 8, 26, 8);
    final evening = DateTime(2026, 8, 26, 21);

    final firstMorning = first.coordinator.deterministicJitterKeyFor(morning);
    expect(first.coordinator.deterministicJitterKeyFor(evening), firstMorning);
    expect(firstMorning, 'account:a:2026-08-26');
    expect(
      second.coordinator.deterministicJitterKeyFor(morning),
      isNot(firstMorning),
    );
  });

  test(
    'candidate evidence source is preserved while generic source is bound',
    () async {
      final harness = await _Harness.create('coordinator-mixed-sources.db');
      addTearDown(harness.close);
      final now = DateTime(2026, 8, 26, 10);
      const candidates = <ProactiveTopicCandidate>[
        ProactiveTopicCandidate(
          kind: ProactiveTopicKind.relationshipMilestone,
          topicKey: 'relationship.milestone.goal',
          sourceEventId: 'relationship-milestone:stable-evidence',
          evidenceKey: 'relationship-milestone:stable-evidence',
          priority: 100,
        ),
        ProactiveTopicCandidate(
          kind: ProactiveTopicKind.quietPresence,
          topicKey: 'presence.quiet',
          priority: 10,
        ),
      ];

      final first = await harness.coordinator.prepare(
        sourceEventId: 'presence-handoff:first',
        candidates: candidates,
        now: now,
      );

      expect(first.shouldGenerate, isTrue);
      expect(
        first.attempt!.sourceEventId,
        'relationship-milestone:stable-evidence',
      );
      await harness.coordinator.commitDraft(
        attempt: first.attempt!,
        draft: '那件一起完成的小事，我还记得。',
        visibleMessageJson: _message('那件一起完成的小事，我还记得。', now),
        idempotencyKey: 'proactive:mixed:first',
        now: now.add(const Duration(seconds: 1)),
      );

      final second = await harness.coordinator.prepare(
        sourceEventId: 'presence-handoff:second',
        lastUserActivityAt: now.add(const Duration(milliseconds: 1500)),
        candidates: candidates,
        now: now.add(const Duration(seconds: 2)),
      );

      expect(second.shouldGenerate, isTrue);
      expect(second.attempt!.candidate.topicKey, 'presence.quiet');
      expect(second.attempt!.sourceEventId, 'presence-handoff:second');
      await harness.coordinator.abandon(second.attempt!, now: now);
    },
  );

  test('pruned evidence markers rotate selection to a fresh topic', () async {
    final harness = await _Harness.create(
      'coordinator-pruned-evidence.db',
      retention: const OutreachLedgerRetention(
        historyCount: 0,
        historyAge: Duration.zero,
      ),
    );
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    const candidates = <ProactiveTopicCandidate>[
      ProactiveTopicCandidate(
        kind: ProactiveTopicKind.relationshipMilestone,
        topicKey: 'relationship.milestone.pruned',
        sourceEventId: 'relationship-milestone:pruned',
        evidenceKey: 'relationship-milestone:pruned',
        priority: 100,
      ),
      ProactiveTopicCandidate(
        kind: ProactiveTopicKind.quietPresence,
        topicKey: 'presence.quiet.after-prune',
        priority: 10,
      ),
    ];
    final first = await harness.coordinator.prepare(
      sourceEventId: 'presence-handoff:pruned:first',
      candidates: candidates,
      now: now,
    );
    await harness.coordinator.commitDraft(
      attempt: first.attempt!,
      draft: '那件重要的小事，我还记得。',
      visibleMessageJson: _message('那件重要的小事，我还记得。', now),
      idempotencyKey: 'proactive:pruned:first',
      now: now.add(const Duration(seconds: 1)),
    );
    final nextDay = now.add(const Duration(days: 1));
    await harness.ledger.recover(now: nextDay);
    expect(await harness.ledger.recent(limit: 10), isEmpty);

    final next = await harness.coordinator.prepare(
      sourceEventId: 'presence-handoff:pruned:next',
      lastUserActivityAt: nextDay,
      candidates: candidates,
      now: nextDay.add(const Duration(minutes: 1)),
    );

    expect(next.shouldGenerate, isTrue);
    expect(next.attempt!.candidate.topicKey, 'presence.quiet.after-prune');
    await harness.coordinator.abandon(
      next.attempt!,
      now: nextDay.add(const Duration(minutes: 1)),
    );
  });

  test('concurrent preparations expose only one generation lease', () async {
    final harness = await _Harness.create('coordinator-concurrent-lease.db');
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);

    final results = await Future.wait(<Future<ProactivePreparation>>[
      harness.coordinator.prepare(
        sourceEventId: 'presence:concurrent:a',
        candidates: const <ProactiveTopicCandidate>[_quietCandidate],
        now: now,
      ),
      harness.coordinator.prepare(
        sourceEventId: 'presence:concurrent:b',
        candidates: const <ProactiveTopicCandidate>[
          ProactiveTopicCandidate(
            kind: ProactiveTopicKind.timeOfDay,
            topicKey: 'time-of-day',
          ),
        ],
        now: now,
      ),
    ]);

    expect(results.where((result) => result.shouldGenerate), hasLength(1));
    expect(
      results.where(
        (result) =>
            result.status == ProactivePreparationStatus.leaseUnavailable,
      ),
      hasLength(1),
    );
  });

  test('abandon releases the lease without consuming topic history', () async {
    final harness = await _Harness.create(
      'coordinator-abandon.db',
      config: _config(genericTopicCooldown: const Duration(days: 1)),
    );
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 10);
    final first = await harness.coordinator.prepare(
      sourceEventId: 'presence:abandon:first',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      now: now,
    );

    final abandoned = await harness.coordinator.abandon(
      first.attempt!,
      reason: 'model_unavailable',
      now: now.add(const Duration(seconds: 1)),
    );
    final next = await harness.coordinator.prepare(
      sourceEventId: 'presence:abandon:second',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      now: now.add(const Duration(seconds: 2)),
    );

    expect(abandoned.state, OutreachState.abandoned);
    expect(abandoned.terminalReason, 'model_unavailable');
    expect(next.shouldGenerate, isTrue);
    expect(await harness.coordinator.readHistory(), isEmpty);
  });

  test('prepare honors quiet hours, activity gap, and hard expiry', () async {
    final quietHarness = await _Harness.create(
      'coordinator-quiet.db',
      config: const ProactivePolicyConfig(
        quietStartMinutes: 23 * 60,
        quietEndMinutes: 7 * 60,
        maximumDeterministicJitter: Duration.zero,
      ),
    );
    final activityHarness = await _Harness.create(
      'coordinator-activity.db',
      config: _config(minimumGlobalGap: const Duration(minutes: 20)),
    );
    addTearDown(quietHarness.close);
    addTearDown(activityHarness.close);
    final late = DateTime(2026, 8, 26, 23, 30);
    final now = DateTime(2026, 8, 26, 10);

    final quiet = await quietHarness.coordinator.prepare(
      sourceEventId: 'presence:quiet-hours',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      now: late,
    );
    final active = await activityHarness.coordinator.prepare(
      sourceEventId: 'presence:recent-activity',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      lastUserActivityAt: now.subtract(const Duration(minutes: 5)),
      now: now,
    );
    final expired = await activityHarness.coordinator.prepare(
      sourceEventId: 'presence:expired',
      candidates: const <ProactiveTopicCandidate>[_quietCandidate],
      expiresAt: now,
      now: now,
    );

    expect(quiet.decision?.reason, ProactiveSilenceReason.quietHours);
    expect(active.decision?.reason, ProactiveSilenceReason.globalGap);
    expect(expired.status, ProactivePreparationStatus.expired);
  });
}

const ProactiveTopicCandidate _quietCandidate = ProactiveTopicCandidate(
  kind: ProactiveTopicKind.quietPresence,
  topicKey: 'quiet-presence',
);

ProactivePolicyConfig _config({
  int foregroundDailyLimit = 10,
  Duration minimumGlobalGap = Duration.zero,
  Duration genericTopicCooldown = Duration.zero,
}) => ProactivePolicyConfig(
  foregroundDailyLimit: foregroundDailyLimit,
  minimumGlobalGap: minimumGlobalGap,
  maximumDeterministicJitter: Duration.zero,
  genericTopicCooldown: genericTopicCooldown,
  quietStartMinutes: 0,
  quietEndMinutes: 0,
);

Map<String, Object?> _message(String content, DateTime timestamp) =>
    <String, Object?>{
      'sessionId': 'self',
      'senderId': 'agent',
      'receiverId': 'self',
      'content': content,
      'timestamp': timestamp.toUtc().toIso8601String(),
      'isUserMessage': false,
      'turnOrigin': 'proactivePresence',
    };

final class _Harness {
  _Harness({
    required this.database,
    required this.ledger,
    required this.coordinator,
  });

  final DBService database;
  final ProactiveOutreachLedger ledger;
  final ProactiveOutreachCoordinator coordinator;
  final StoreRef<int, Map<String, Object?>> chatMessages = intMapStoreFactory
      .store('chat_messages');

  static Future<_Harness> create(
    String path, {
    ProactivePolicyConfig config = const ProactivePolicyConfig(
      foregroundDailyLimit: 10,
      minimumGlobalGap: Duration.zero,
      maximumDeterministicJitter: Duration.zero,
      genericTopicCooldown: Duration.zero,
      quietStartMinutes: 0,
      quietEndMinutes: 0,
    ),
    String accountKey = 'account:test',
    OutreachLedgerRetention retention = const OutreachLedgerRetention(),
  }) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    var id = 0;
    final ledger = ProactiveOutreachLedger(
      accountDatabase: database,
      idFactory: () => 'coordinator-${id++}',
      retention: retention,
    );
    final coordinator = ProactiveOutreachCoordinator(
      policy: ProactiveCompanionPolicy(config: config),
      ledger: ledger,
      accountKey: accountKey,
    );
    return _Harness(
      database: database,
      ledger: ledger,
      coordinator: coordinator,
    );
  }

  Future<void> close() => database.close();
}

final class _CloseGateAfterDraftPolicy extends ProactiveCompanionPolicy {
  _CloseGateAfterDraftPolicy()
    : _config = const ProactivePolicyConfig(
        foregroundDailyLimit: 3,
        minimumGlobalGap: Duration.zero,
        maximumDeterministicJitter: Duration.zero,
        genericTopicCooldown: Duration.zero,
        quietStartMinutes: 0,
        quietEndMinutes: 0,
      );

  ProactivePolicyConfig _config;
  bool closeAfterNextDraft = false;

  @override
  ProactivePolicyConfig get config => _config;

  @override
  ProactiveNoveltyDecision evaluateDraft({
    required DateTime now,
    required ProactiveTopicCandidate candidate,
    required String draft,
    Iterable<ProactiveOutreachHistoryEntry> history = const [],
  }) {
    final decision = super.evaluateDraft(
      now: now,
      candidate: candidate,
      draft: draft,
      history: history,
    );
    if (closeAfterNextDraft) {
      closeAfterNextDraft = false;
      scheduleMicrotask(() {
        _config = const ProactivePolicyConfig(
          foregroundDailyLimit: 0,
          minimumGlobalGap: Duration.zero,
          maximumDeterministicJitter: Duration.zero,
          genericTopicCooldown: Duration.zero,
          quietStartMinutes: 0,
          quietEndMinutes: 0,
        );
      });
    }
    return decision;
  }
}

final class _MutableCoordinatorClock {
  _MutableCoordinatorClock(this.now);

  DateTime now;

  DateTime call() => now;
}

final class _AdvanceClockAfterDraftPolicy extends ProactiveCompanionPolicy {
  _AdvanceClockAfterDraftPolicy({required this.advance})
    : super(
        config: const ProactivePolicyConfig(
          foregroundDailyLimit: 3,
          minimumGlobalGap: Duration.zero,
          maximumDeterministicJitter: Duration.zero,
          genericTopicCooldown: Duration.zero,
          quietStartMinutes: 22 * 60,
          quietEndMinutes: 7 * 60,
        ),
      );

  final void Function() advance;
  bool advanceAfterNextDraft = false;

  @override
  ProactiveNoveltyDecision evaluateDraft({
    required DateTime now,
    required ProactiveTopicCandidate candidate,
    required String draft,
    Iterable<ProactiveOutreachHistoryEntry> history = const [],
  }) {
    final decision = super.evaluateDraft(
      now: now,
      candidate: candidate,
      draft: draft,
      history: history,
    );
    if (advanceAfterNextDraft) {
      advanceAfterNextDraft = false;
      scheduleMicrotask(advance);
    }
    return decision;
  }
}
