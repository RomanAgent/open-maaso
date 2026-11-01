import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  test('concurrent reservations hold one account generation lease', () async {
    final harness = await _Harness.create('outreach-one-lease.db');
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);

    final reservations = await Future.wait(<Future<OutreachReservation?>>[
      harness.ledger.reserve(
        sourceEventId: 'presence:quiet:1',
        topicKey: 'quietPresence',
        now: now,
      ),
      harness.ledger.reserve(
        sourceEventId: 'presence:affect:1',
        topicKey: 'recentAffect',
        now: now,
      ),
    ]);

    expect(reservations.whereType<OutreachReservation>(), hasLength(1));
    expect(await harness.ledger.recent(), hasLength(1));
  });

  test('same source retries reuse only an active reservation', () async {
    final harness = await _Harness.create('outreach-source-idempotency.db');
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);

    final first = await harness.ledger.reserve(
      sourceEventId: 'presence:event:42',
      topicKey: 'environmentObservation',
      now: now,
    );
    final retry = await harness.ledger.reserve(
      sourceEventId: 'presence:event:42',
      topicKey: 'environmentObservation',
      now: now.add(const Duration(seconds: 5)),
    );

    expect(first, isNotNull);
    expect(retry, isNotNull);
    expect(retry!.outreachId, first!.outreachId);
    expect(retry.reservationToken, first.reservationToken);
    expect(retry.reused, isTrue);

    await harness.ledger.commitAccepted(
      first,
      normalizedFingerprint: 'sha256:one',
      now: now.add(const Duration(seconds: 10)),
    );

    expect(
      await harness.ledger.reserve(
        sourceEventId: 'presence:event:42',
        topicKey: 'environmentObservation',
        now: now.add(const Duration(seconds: 11)),
      ),
      isNull,
    );
    expect(await harness.ledger.recent(), hasLength(1));
  });

  test(
    'blank source ids remain anonymous instead of globally idempotent',
    () async {
      final harness = await _Harness.create('outreach-anonymous-source.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);

      final first = (await harness.ledger.reserve(
        sourceEventId: '  ',
        topicKey: 'quietPresence',
        now: now,
      ))!;
      await harness.ledger.abandon(
        first,
        now: now.add(const Duration(seconds: 1)),
      );
      final second = await harness.ledger.reserve(
        sourceEventId: '',
        topicKey: 'timeOfDay',
        now: now.add(const Duration(seconds: 2)),
      );

      expect(second, isNotNull);
      expect(second!.outreachId, isNot(first.outreachId));
      expect(await harness.ledger.recent(), hasLength(2));
    },
  );

  test('accepted commit atomically appends one visible chat message', () async {
    final harness = await _Harness.create('outreach-visible-message.db');
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);
    final reservation = (await harness.ledger.reserve(
      sourceEventId: 'presence:quiet:7',
      topicKey: 'quietPresence',
      evidenceKey: 'quiet:morning',
      now: now,
    ))!;
    await harness.ledger.markGenerating(reservation, now: now);
    var hookCalls = 0;
    final message = <String, Object?>{
      'sessionId': 'self',
      'senderId': 'agent',
      'receiverId': 'self',
      'content': '早上好。',
      'timestamp': now.toIso8601String(),
      'isUserMessage': false,
    };

    final committed = await harness.ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'sha256:morning',
      nearDuplicateFeatures: const <String>{'zh:早上', 'zh:上好'},
      visibleMessageJson: message,
      visibleMessageIdempotencyKey: 'proactive:quiet:7',
      onFirstCommit: (_, _) => hookCalls++,
      now: now.add(const Duration(seconds: 2)),
    );
    final repeated = await harness.ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'sha256:morning',
      nearDuplicateFeatures: const <String>{'ignored:on:retry'},
      visibleMessageJson: message,
      visibleMessageIdempotencyKey: 'proactive:quiet:7',
      onFirstCommit: (_, _) => hookCalls++,
      now: now.add(const Duration(seconds: 3)),
    );

    expect(committed.state, OutreachState.committed);
    expect(committed.visibleMessageRecordId, isNotNull);
    expect(repeated.visibleMessageRecordId, committed.visibleMessageRecordId);
    expect(hookCalls, 1);
    final rows = await harness.chatMessages.find(harness.database.raw);
    expect(rows, hasLength(1));
    expect(rows.single.value['idempotencyKey'], 'proactive:quiet:7');
    expect(rows.single.value['outreachId'], reservation.outreachId);

    final delivered = await harness.ledger.markDelivered(
      reservation,
      now: now.add(const Duration(seconds: 4)),
    );
    expect(delivered.state, OutreachState.delivered);
    expect(
      (await harness.ledger.markDelivered(reservation)).state,
      OutreachState.delivered,
    );
  });

  test(
    'a committed outreach rejects a different visible message key',
    () async {
      final harness = await _Harness.create('outreach-visible-key-binding.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final reservation = (await harness.ledger.reserve(
        topicKey: 'quietPresence',
        now: now,
      ))!;
      final message = <String, Object?>{
        'sessionId': 'self',
        'senderId': 'agent',
        'receiverId': 'self',
        'content': '只应该保存一次。',
        'timestamp': now.toIso8601String(),
        'isUserMessage': false,
      };
      final committed = await harness.ledger.commitAccepted(
        reservation,
        normalizedFingerprint: 'sha256:bound-key',
        visibleMessageJson: message,
        visibleMessageIdempotencyKey: 'proactive:bound:first',
        now: now.add(const Duration(seconds: 1)),
      );

      await expectLater(
        harness.ledger.commitAccepted(
          reservation,
          normalizedFingerprint: 'sha256:bound-key',
          visibleMessageJson: message,
          visibleMessageIdempotencyKey: 'proactive:bound:second',
          now: now.add(const Duration(seconds: 2)),
        ),
        throwsStateError,
      );

      final rows = await harness.chatMessages.find(harness.database.raw);
      final stored = await harness.ledger.get(reservation.outreachId);
      expect(rows, hasLength(1));
      expect(rows.single.value['idempotencyKey'], 'proactive:bound:first');
      expect(stored!.visibleMessageIdempotencyKey, 'proactive:bound:first');
      expect(stored.visibleMessageRecordId, committed.visibleMessageRecordId);
    },
  );

  for (final existingOutreachId in <String?>[null, 'another-outreach']) {
    final label = existingOutreachId == null ? 'missing' : 'foreign';
    test(
      'a $label outreachId chat row cannot be claimed by a commit',
      () async {
        final harness = await _Harness.create(
          'outreach-visible-collision-$label.db',
        );
        addTearDown(harness.close);
        final now = DateTime.utc(2026, 8, 26, 8);
        final collision = <String, Object?>{
          'sessionId': 'self',
          'senderId': 'agent',
          'receiverId': 'self',
          'content': 'existing row',
          'timestamp': now.toIso8601String(),
          'isUserMessage': false,
          'idempotencyKey': 'proactive:collision:$label',
          'outreachId': ?existingOutreachId,
        };
        await harness.chatMessages.add(harness.database.raw, collision);
        final reservation = (await harness.ledger.reserve(
          topicKey: 'quietPresence',
          now: now,
        ))!;
        await harness.ledger.markGenerating(reservation, now: now);

        await expectLater(
          harness.ledger.commitAccepted(
            reservation,
            normalizedFingerprint: 'sha256:collision:$label',
            visibleMessageJson: <String, Object?>{
              'sessionId': 'self',
              'senderId': 'agent',
              'receiverId': 'self',
              'content': 'new row',
              'timestamp': now.toIso8601String(),
              'isUserMessage': false,
            },
            visibleMessageIdempotencyKey: 'proactive:collision:$label',
            now: now.add(const Duration(seconds: 1)),
          ),
          throwsStateError,
        );

        final rows = await harness.chatMessages.find(harness.database.raw);
        final stored = await harness.ledger.get(reservation.outreachId);
        expect(rows, hasLength(1));
        expect(rows.single.value['content'], 'existing row');
        expect(stored!.state, OutreachState.generating);
        expect(stored.committedAt, isNull);
        expect(stored.visibleMessageRecordId, isNull);
      },
    );
  }

  test(
    'same commit stays at-most-once after database close and reopen',
    () async {
      const path = 'outreach-reopen-idempotency.db';
      final first = await _Harness.create(path);
      addTearDown(first.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final reservation = (await first.ledger.reserve(
        sourceEventId: 'presence:reopen:1',
        topicKey: 'quietPresence',
        now: now,
      ))!;
      final message = <String, Object?>{
        'sessionId': 'self',
        'senderId': 'agent',
        'receiverId': 'self',
        'content': '重启后也只能有一条。',
        'timestamp': now.toIso8601String(),
        'isUserMessage': false,
      };
      final committed = await first.ledger.commitAccepted(
        reservation,
        normalizedFingerprint: 'sha256:reopen',
        visibleMessageJson: message,
        visibleMessageIdempotencyKey: 'proactive:reopen:1',
        now: now.add(const Duration(seconds: 1)),
      );
      await first.close();

      final reopened = await _Harness.create(path);
      addTearDown(reopened.close);
      var replayHooks = 0;
      final repeated = await reopened.ledger.commitAccepted(
        reservation,
        normalizedFingerprint: 'sha256:reopen',
        visibleMessageJson: message,
        visibleMessageIdempotencyKey: 'proactive:reopen:1',
        onFirstCommit: (_, _) => replayHooks++,
        now: now.add(const Duration(minutes: 5)),
      );

      final rows = await reopened.chatMessages.find(reopened.database.raw);
      expect(rows, hasLength(1));
      expect(repeated.visibleMessageRecordId, committed.visibleMessageRecordId);
      expect(replayHooks, 0);
    },
  );

  test(
    'failed commit hook rolls back ledger and visible message together',
    () async {
      final harness = await _Harness.create('outreach-commit-rollback.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final reservation = (await harness.ledger.reserve(
        topicKey: 'quietPresence',
        now: now,
      ))!;
      await harness.ledger.markGenerating(reservation, now: now);

      await expectLater(
        harness.ledger.commitAccepted(
          reservation,
          normalizedFingerprint: 'sha256:rollback',
          visibleMessageJson: <String, Object?>{
            'sessionId': 'self',
            'content': 'should roll back',
          },
          visibleMessageIdempotencyKey: 'proactive:rollback',
          onFirstCommit: (_, _) => throw StateError('simulated crash'),
          now: now.add(const Duration(seconds: 1)),
        ),
        throwsStateError,
      );

      expect(
        (await harness.ledger.get(reservation.outreachId))!.state,
        OutreachState.generating,
      );
      expect(await harness.chatMessages.count(harness.database.raw), 0);
    },
  );

  test(
    'recovery abandons expired generation but never replays commit',
    () async {
      final harness = await _Harness.create('outreach-recovery.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final expired = (await harness.ledger.reserve(
        topicKey: 'quietPresence',
        leaseDuration: const Duration(minutes: 1),
        now: now,
      ))!;
      await harness.ledger.markGenerating(expired, now: now);

      final recovered = await harness.ledger.recover(
        now: now.add(const Duration(minutes: 2)),
      );
      expect(recovered, hasLength(1));
      expect(recovered.single.state, OutreachState.abandoned);
      expect(recovered.single.terminalReason, 'lease_expired');

      final committed = (await harness.ledger.reserve(
        topicKey: 'timeOfDay',
        leaseDuration: const Duration(minutes: 1),
        now: now.add(const Duration(minutes: 3)),
      ))!;
      await harness.ledger.commitAccepted(
        committed,
        normalizedFingerprint: 'sha256:committed',
        now: now.add(const Duration(minutes: 3)),
      );
      expect(
        await harness.ledger.recover(now: now.add(const Duration(hours: 1))),
        isEmpty,
      );
      expect(
        (await harness.ledger.get(committed.outreachId))!.state,
        OutreachState.committed,
      );
    },
  );

  test('an expired commit fails after durably abandoning its lease', () async {
    final harness = await _Harness.create('outreach-expired-commit.db');
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);
    final reservation = (await harness.ledger.reserve(
      topicKey: 'quietPresence',
      leaseDuration: const Duration(minutes: 1),
      now: now,
    ))!;

    await expectLater(
      harness.ledger.commitAccepted(
        reservation,
        normalizedFingerprint: 'sha256:too-late',
        now: now.add(const Duration(minutes: 2)),
      ),
      throwsStateError,
    );

    final stored = await harness.ledger.get(reservation.outreachId);
    expect(stored!.state, OutreachState.abandoned);
    expect(stored.terminalReason, 'lease_expired');
  });

  test(
    'an expired generating retry fails after durably abandoning its lease',
    () async {
      final harness = await _Harness.create('outreach-expired-generating.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final reservation = (await harness.ledger.reserve(
        topicKey: 'quietPresence',
        leaseDuration: const Duration(minutes: 1),
        now: now,
      ))!;
      await harness.ledger.markGenerating(reservation, now: now);

      await expectLater(
        harness.ledger.markGenerating(
          reservation,
          now: now.add(const Duration(minutes: 2)),
        ),
        throwsStateError,
      );

      final stored = await harness.ledger.get(reservation.outreachId);
      expect(stored!.state, OutreachState.abandoned);
      expect(stored.terminalReason, 'lease_expired');
    },
  );

  test('a committed outreach cannot be rewritten as suppressed', () async {
    final harness = await _Harness.create('outreach-terminal-state.db');
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);
    final reservation = (await harness.ledger.reserve(
      topicKey: 'quietPresence',
      now: now,
    ))!;
    await harness.ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'sha256:committed',
      now: now.add(const Duration(seconds: 1)),
    );

    await expectLater(
      harness.ledger.suppress(
        outreachId: reservation.outreachId,
        reservationToken: reservation.reservationToken,
        reason: 'too_late',
        now: now.add(const Duration(seconds: 2)),
      ),
      throwsStateError,
    );
    expect(
      (await harness.ledger.get(reservation.outreachId))!.state,
      OutreachState.committed,
    );
  });

  test('scheduled OS expiry is budgeted as assumed delivery', () async {
    final harness = await _Harness.create('outreach-os-schedule.db');
    addTearDown(harness.close);
    final day = DateTime.utc(2026, 8, 26);
    final scheduled = await harness.ledger.scheduleOs(
      sourceEventId: 'os:morning:2026-08-26',
      topicKey: 'timeOfDay',
      evidenceKey: 'morning:2026-08-26',
      scheduledFor: day.add(const Duration(hours: 9)),
      expiresAt: day.add(const Duration(hours: 10)),
      now: day.add(const Duration(hours: 8)),
    );
    final duplicate = await harness.ledger.scheduleOs(
      sourceEventId: 'os:morning:2026-08-26',
      topicKey: 'timeOfDay',
      evidenceKey: 'morning:2026-08-26',
      scheduledFor: day.add(const Duration(hours: 9)),
      expiresAt: day.add(const Duration(hours: 10)),
      now: day.add(const Duration(hours: 8)),
    );

    expect(duplicate.outreachId, scheduled.outreachId);
    expect(
      (await harness.ledger.recover(
        now: day.add(const Duration(hours: 11)),
      )).single.state,
      OutreachState.assumedDelivered,
    );
    final stats = await harness.ledger.summarize(
      from: day,
      until: day.add(const Duration(days: 1)),
    );
    expect(stats.osScheduled, 1);
    expect(stats.foregroundCommitted, 0);
    expect(stats.totalBudgeted, 1);
    expect(stats.lastDeliveredAt, day.add(const Duration(hours: 11)));
  });

  test(
    'active OS lookup recovers, filters, sorts, and returns an immutable list',
    () async {
      final harness = await _Harness.create('outreach-active-os.db');
      addTearDown(harness.close);
      final day = DateTime.utc(2026, 8, 26);
      final late = await harness.ledger.scheduleOs(
        sourceEventId: 'os:active:late',
        deliveryId: 'delivery:active:late',
        topicKey: 'presence.time.afternoon',
        scheduledFor: day.add(const Duration(hours: 13)),
        expiresAt: day.add(const Duration(hours: 14)),
        now: day.add(const Duration(hours: 8)),
      );
      final elapsed = await harness.ledger.scheduleOs(
        sourceEventId: 'os:active:elapsed',
        deliveryId: 'delivery:active:elapsed',
        topicKey: 'presence.time.morning',
        scheduledFor: day.add(const Duration(hours: 9)),
        expiresAt: day.add(const Duration(hours: 9, minutes: 30)),
        now: day.add(const Duration(hours: 8)),
      );
      final early = await harness.ledger.scheduleOs(
        sourceEventId: 'os:active:early',
        deliveryId: 'delivery:active:early',
        topicKey: 'presence.time.midday',
        scheduledFor: day.add(const Duration(hours: 11)),
        expiresAt: day.add(const Duration(hours: 12)),
        now: day.add(const Duration(hours: 8)),
      );
      final cancelled = await harness.ledger.scheduleOs(
        sourceEventId: 'os:active:cancelled',
        deliveryId: 'delivery:active:cancelled',
        topicKey: 'presence.time.noon',
        scheduledFor: day.add(const Duration(hours: 12)),
        expiresAt: day.add(const Duration(hours: 13)),
        now: day.add(const Duration(hours: 8)),
      );
      await harness.ledger.cancelScheduledOsByDeliveryId(
        cancelled.deliveryId!,
        now: day.add(const Duration(hours: 8, minutes: 1)),
      );

      final active = await harness.ledger.activeScheduledOs(
        recoverThrough: day.add(const Duration(hours: 10)),
      );

      expect(active.map((record) => record.outreachId), <String>[
        early.outreachId,
        late.outreachId,
      ]);
      expect(
        (await harness.ledger.get(elapsed.outreachId))?.state,
        OutreachState.assumedDelivered,
      );
      expect(() => active.add(late), throwsUnsupportedError);
    },
  );

  test(
    'OS notification interaction atomically grants one matching runtime turn',
    () async {
      final harness = await _Harness.create('outreach-os-interaction.db');
      addTearDown(harness.close);
      final day = DateTime.utc(2026, 8, 26);
      const sourceEventId = 'os:v3:test.account-a:morning:1787725200000';
      const deliveryId = 'proactive:v3:test.account-a:morning:1787725200000';
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: sourceEventId,
        deliveryId: deliveryId,
        topicKey: 'presence.time.morning',
        scheduledFor: day.add(const Duration(hours: 9)),
        expiresAt: day.add(const Duration(hours: 10)),
        now: day.add(const Duration(hours: 8)),
      );

      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: deliveryId,
          sourceEventId: sourceEventId,
          now: day.add(const Duration(hours: 8)),
        ),
        isFalse,
      );
      expect(
        await harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: deliveryId,
          sourceEventId: 'os:v3:test.account-b:morning:1787725200000',
          now: day.add(const Duration(hours: 9)),
        ),
        isFalse,
      );

      final concurrent = await Future.wait(<Future<bool>>[
        harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: deliveryId,
          sourceEventId: sourceEventId,
          now: day.add(const Duration(hours: 9)),
        ),
        harness.ledger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: deliveryId,
          sourceEventId: sourceEventId,
          now: day.add(const Duration(hours: 9)),
        ),
      ]);

      expect(concurrent.where((claimed) => claimed), hasLength(1));
      final stored = await harness.ledger.get(scheduled.outreachId);
      expect(stored?.state, OutreachState.scheduledOs);
      expect(
        stored?.notificationInteractionClaimedAt,
        day.add(const Duration(hours: 9)),
      );

      final restartedLedger = ProactiveOutreachLedger(
        accountDatabase: harness.database,
      );
      expect(
        await restartedLedger.claimOsNotificationInteraction(
          outreachId: scheduled.outreachId,
          deliveryId: deliveryId,
          sourceEventId: sourceEventId,
          now: day.add(const Duration(hours: 9, minutes: 1)),
        ),
        isFalse,
      );
    },
  );

  test(
    'OS schedule and foreground reservation share one atomic daily budget',
    () async {
      final harness = await _Harness.create('outreach-shared-budget.db');
      addTearDown(harness.close);
      final day = DateTime(2026, 8, 26);
      final scheduled = await harness.ledger.tryScheduleOs(
        sourceEventId: 'os:evening:2026-08-26',
        deliveryId: 'proactive:evening:2026-08-26',
        topicKey: 'presence.time.evening',
        evidenceKey: 'evening:2026-08-26',
        scheduledFor: day.add(const Duration(hours: 20)),
        expiresAt: day.add(const Duration(hours: 22)),
        dailyBudgetLimit: 1,
        now: day.add(const Duration(hours: 8)),
      );
      final replay = await harness.ledger.tryScheduleOs(
        sourceEventId: 'os:evening:2026-08-26',
        deliveryId: 'proactive:evening:2026-08-26',
        topicKey: 'presence.time.evening',
        evidenceKey: 'evening:2026-08-26',
        scheduledFor: day.add(const Duration(hours: 20)),
        expiresAt: day.add(const Duration(hours: 22)),
        dailyBudgetLimit: 1,
        now: day.add(const Duration(hours: 8, minutes: 1)),
      );

      expect(scheduled, isNotNull);
      expect(scheduled!.deliveryId, 'proactive:evening:2026-08-26');
      expect(replay?.outreachId, scheduled.outreachId);
      expect(
        await harness.ledger.reserve(
          topicKey: 'presence.quiet',
          dailyBudgetLimit: 1,
          now: day.add(const Duration(hours: 9)),
        ),
        isNull,
      );

      final cancelled = await harness.ledger.cancelScheduledOsByDeliveryId(
        scheduled.deliveryId!,
        now: day.add(const Duration(hours: 10)),
      );
      expect(cancelled.single.state, OutreachState.cancelled);
      expect(
        await harness.ledger.reserve(
          topicKey: 'presence.quiet',
          dailyBudgetLimit: 1,
          now: day.add(const Duration(hours: 10, minutes: 1)),
        ),
        isNotNull,
      );
    },
  );

  test('active foreground reservation blocks an OS budget race', () async {
    final harness = await _Harness.create('outreach-active-budget.db');
    addTearDown(harness.close);
    final day = DateTime(2026, 8, 26);
    final foreground = await harness.ledger.reserve(
      sourceEventId: 'presence:quiet:budget-race',
      topicKey: 'presence.quiet',
      dailyBudgetLimit: 1,
      now: day.add(const Duration(hours: 8)),
    );

    expect(foreground, isNotNull);
    expect(
      await harness.ledger.tryScheduleOs(
        sourceEventId: 'os:evening:budget-race',
        deliveryId: 'proactive:evening:budget-race',
        topicKey: 'presence.time.evening',
        scheduledFor: day.add(const Duration(hours: 20)),
        expiresAt: day.add(const Duration(hours: 22)),
        dailyBudgetLimit: 1,
        now: day.add(const Duration(hours: 8, minutes: 1)),
      ),
      isNull,
    );

    await harness.ledger.abandon(
      foreground!,
      now: day.add(const Duration(hours: 8, minutes: 2)),
    );
    expect(
      await harness.ledger.tryScheduleOs(
        sourceEventId: 'os:evening:budget-race',
        deliveryId: 'proactive:evening:budget-race',
        topicKey: 'presence.time.evening',
        scheduledFor: day.add(const Duration(hours: 20)),
        expiresAt: day.add(const Duration(hours: 22)),
        dailyBudgetLimit: 1,
        now: day.add(const Duration(hours: 8, minutes: 3)),
      ),
      isNotNull,
    );
  });

  test('commit rechecks the shared budget inside its transaction', () async {
    final harness = await _Harness.create('outreach-commit-budget-race.db');
    addTearDown(harness.close);
    final day = DateTime(2026, 8, 26);
    final foreground = (await harness.ledger.reserve(
      topicKey: 'presence.quiet',
      now: day.add(const Duration(hours: 8)),
    ))!;
    await harness.ledger.scheduleOs(
      sourceEventId: 'os:evening:late-race',
      deliveryId: 'proactive:evening:late-race',
      topicKey: 'presence.time.evening',
      scheduledFor: day.add(const Duration(hours: 20)),
      expiresAt: day.add(const Duration(hours: 22)),
      now: day.add(const Duration(hours: 8, minutes: 1)),
    );

    await expectLater(
      harness.ledger.commitAccepted(
        foreground,
        normalizedFingerprint: 'sha256:budget-race',
        dailyBudgetLimit: 1,
        now: day.add(const Duration(hours: 8, minutes: 1, seconds: 30)),
      ),
      throwsA(isA<OutreachDailyBudgetExceeded>()),
    );
    expect(
      (await harness.ledger.get(foreground.outreachId))!.state,
      OutreachState.candidateReserved,
    );
  });

  test('topic, evidence, and daily budget queries share one ledger', () async {
    final harness = await _Harness.create('outreach-policy-queries.db');
    addTearDown(harness.close);
    final day = DateTime.utc(2026, 8, 26);
    final reservation = (await harness.ledger.reserve(
      sourceEventId: 'presence:milestone:1',
      topicKey: 'relationshipMilestone',
      evidenceKey: 'milestone:first-week',
      now: day.add(const Duration(hours: 9)),
    ))!;
    await harness.ledger.markGenerating(
      reservation,
      now: day.add(const Duration(hours: 9)),
    );
    await harness.ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'sha256:first-week',
      now: day.add(const Duration(hours: 9, minutes: 1)),
    );
    await harness.ledger.scheduleOs(
      topicKey: 'timeOfDay',
      scheduledFor: day.add(const Duration(hours: 18)),
      expiresAt: day.add(const Duration(hours: 19)),
      now: day.add(const Duration(hours: 10)),
    );

    expect(
      await harness.ledger.wasTopicUsedSince('relationshipMilestone', day),
      isTrue,
    );
    expect(
      await harness.ledger.hasEvidenceBeenUsed('milestone:first-week'),
      isTrue,
    );
    final stats = await harness.ledger.summarize(
      from: day,
      until: day.add(const Duration(days: 1)),
    );
    expect(stats.foregroundCommitted, 1);
    expect(stats.osScheduled, 1);
    expect(stats.totalBudgeted, 2);
    expect(stats.lastAttemptAt, day.add(const Duration(hours: 9)));
    expect(
      stats.lastCommittedAt,
      day.add(const Duration(hours: 9, minutes: 1)),
    );
  });

  test(
    'retention prunes full rows but preserves chat and uniqueness markers',
    () async {
      final harness = await _Harness.create('outreach-retention.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);

      for (var index = 0; index < 40; index++) {
        final at = now.add(Duration(seconds: index * 2));
        final reservation = (await harness.ledger.reserve(
          sourceEventId: 'retention-source-$index',
          topicKey: 'retention-topic-$index',
          evidenceKey: 'retention-evidence-$index',
          now: at,
        ))!;
        await harness.ledger.commitAccepted(
          reservation,
          normalizedFingerprint: 'sha256:retention-$index',
          visibleMessageJson: <String, Object?>{
            'sessionId': 'self',
            'senderId': 'agent',
            'receiverId': 'self',
            'content': 'retention-$index',
            'timestamp': at.toIso8601String(),
            'isUserMessage': false,
          },
          visibleMessageIdempotencyKey: 'retention-message-$index',
          now: at.add(const Duration(seconds: 1)),
        );
      }

      await harness.ledger.recover(now: now.add(const Duration(days: 1)));

      expect(await harness.ledger.recent(limit: 100), hasLength(32));
      expect(await harness.chatMessages.count(harness.database.raw), 40);
      expect(
        await harness.ledger.findBySourceEventId('retention-source-0'),
        isNull,
      );
      expect(
        await harness.ledger.hasSourceEventBeenConsumed('retention-source-0'),
        isTrue,
      );
      expect(
        await harness.ledger.hasEvidenceBeenUsed('retention-evidence-0'),
        isTrue,
      );
      expect(
        await harness.ledger.reserve(
          sourceEventId: 'retention-source-0',
          topicKey: 'replayed-topic',
          evidenceKey: 'retention-evidence-0',
          now: now.add(const Duration(days: 1, seconds: 1)),
        ),
        isNull,
      );
    },
  );

  test(
    'retention never removes a live lease or future OS occurrence',
    () async {
      const retention = OutreachLedgerRetention(
        historyCount: 0,
        historyAge: Duration.zero,
        diagnosticCount: 0,
        diagnosticAge: Duration.zero,
      );
      final harness = await _Harness.create(
        'outreach-retention-protected.db',
        retention: retention,
      );
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final active = await harness.ledger.reserve(
        sourceEventId: 'retention-active',
        topicKey: 'active',
        leaseDuration: const Duration(days: 60),
        now: now,
      );
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: 'retention-future-os',
        deliveryId: 'proactive:future-os',
        topicKey: 'future-os',
        scheduledFor: now.add(const Duration(days: 40)),
        expiresAt: now.add(const Duration(days: 41)),
        now: now,
      );

      await harness.ledger.recover(now: now.add(const Duration(days: 30)));

      expect(await harness.ledger.get(active!.outreachId), isNotNull);
      expect(await harness.ledger.get(scheduled.outreachId), isNotNull);
      expect(await harness.ledger.recent(limit: 10), hasLength(2));
    },
  );

  test('retention never releases the current day shared budget', () async {
    const retention = OutreachLedgerRetention(
      historyCount: 0,
      historyAge: Duration.zero,
      diagnosticCount: 0,
      diagnosticAge: Duration.zero,
    );
    final harness = await _Harness.create(
      'outreach-retention-budget.db',
      retention: retention,
    );
    addTearDown(harness.close);
    final now = DateTime(2026, 8, 26, 0, 30);
    final first = (await harness.ledger.reserve(
      sourceEventId: 'retention-budget:first',
      topicKey: 'retention-budget:first',
      dailyBudgetLimit: 1,
      now: now,
    ))!;
    await harness.ledger.commitAccepted(
      first,
      normalizedFingerprint: 'sha256:retention-budget-first',
      dailyBudgetLimit: 1,
      now: now.add(const Duration(seconds: 1)),
    );

    expect(
      await harness.ledger.reserve(
        sourceEventId: 'retention-budget:blocked',
        topicKey: 'retention-budget:blocked',
        dailyBudgetLimit: 1,
        now: DateTime(2026, 8, 26, 23, 30),
      ),
      isNull,
    );
    expect(await harness.ledger.recent(limit: 10), hasLength(1));

    expect(
      await harness.ledger.reserve(
        sourceEventId: 'retention-budget:next-day',
        topicKey: 'retention-budget:next-day',
        dailyBudgetLimit: 1,
        now: DateTime(2026, 8, 27, 0, 30),
      ),
      isNotNull,
    );
  });

  test('retention preserves assumed OS occupancy for its budget day', () async {
    const retention = OutreachLedgerRetention(
      historyCount: 0,
      historyAge: Duration.zero,
      diagnosticCount: 0,
      diagnosticAge: Duration.zero,
    );
    final harness = await _Harness.create(
      'outreach-retention-os-budget.db',
      retention: retention,
    );
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);
    final scheduled = await harness.ledger.tryScheduleOs(
      sourceEventId: 'retention-os-budget:first',
      deliveryId: 'proactive:retention-os-budget:first',
      topicKey: 'presence.time.morning',
      scheduledFor: now.add(const Duration(minutes: 1)),
      expiresAt: now.add(const Duration(minutes: 2)),
      dailyBudgetLimit: 1,
      now: now,
    );
    await harness.ledger.markAssumedDelivered(
      outreachId: scheduled!.outreachId,
      now: now.add(const Duration(minutes: 2)),
    );

    expect(
      await harness.ledger.reserve(
        sourceEventId: 'retention-os-budget:blocked',
        topicKey: 'retention-os-budget:blocked',
        dailyBudgetLimit: 1,
        now: now.add(const Duration(minutes: 3)),
      ),
      isNull,
    );
    expect(await harness.ledger.recent(limit: 10), hasLength(1));
  });

  test(
    'negative foreground terminals keep source exactly-once after prune',
    () async {
      const retention = OutreachLedgerRetention(
        historyCount: 0,
        historyAge: Duration.zero,
        diagnosticCount: 0,
        diagnosticAge: Duration.zero,
      );
      final harness = await _Harness.create(
        'outreach-negative-source-markers.db',
        retention: retention,
      );
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final abandoned = (await harness.ledger.reserve(
        sourceEventId: 'negative-source:abandoned',
        topicKey: 'negative-source:abandoned',
        now: now,
      ))!;
      await harness.ledger.abandon(
        abandoned,
        now: now.add(const Duration(seconds: 1)),
      );
      final suppressed = (await harness.ledger.reserve(
        sourceEventId: 'negative-source:suppressed',
        topicKey: 'negative-source:suppressed',
        now: now.add(const Duration(seconds: 2)),
      ))!;
      await harness.ledger.suppress(
        outreachId: suppressed.outreachId,
        reservationToken: suppressed.reservationToken,
        reason: 'test_suppression',
        now: now.add(const Duration(seconds: 3)),
      );
      final cancelled = (await harness.ledger.reserve(
        sourceEventId: 'negative-source:cancelled',
        topicKey: 'negative-source:cancelled',
        now: now.add(const Duration(seconds: 4)),
      ))!;
      await harness.ledger.cancel(
        outreachId: cancelled.outreachId,
        reservationToken: cancelled.reservationToken,
        now: now.add(const Duration(seconds: 5)),
      );

      await harness.ledger.recover(now: now.add(const Duration(days: 1)));

      for (final suffix in <String>['abandoned', 'suppressed', 'cancelled']) {
        final source = 'negative-source:$suffix';
        expect(await harness.ledger.findBySourceEventId(source), isNull);
        expect(await harness.ledger.hasSourceEventBeenConsumed(source), isTrue);
        expect(
          await harness.ledger.reserve(
            sourceEventId: source,
            topicKey: 'replay:$suffix',
            now: now.add(const Duration(days: 1, minutes: 1)),
          ),
          isNull,
        );
      }
    },
  );

  test(
    'cancelled OS replay cannot reclaim evidence consumed elsewhere',
    () async {
      final harness = await _Harness.create('outreach-os-evidence-replay.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final scheduledFor = now.add(const Duration(hours: 1));
      final expiresAt = scheduledFor.add(const Duration(hours: 1));
      final scheduled = await harness.ledger.tryScheduleOs(
        sourceEventId: 'os-replay:source',
        deliveryId: 'proactive:os-replay',
        topicKey: 'presence.time.morning',
        evidenceKey: 'shared:evidence',
        scheduledFor: scheduledFor,
        expiresAt: expiresAt,
        dailyBudgetLimit: 3,
        now: now,
      );
      await harness.ledger.cancelScheduledOsByDeliveryId(
        'proactive:os-replay',
        now: now.add(const Duration(minutes: 1)),
      );
      final foreground = (await harness.ledger.reserve(
        sourceEventId: 'foreground:evidence-consumer',
        topicKey: 'relationship.changed',
        evidenceKey: 'shared:evidence',
        now: now.add(const Duration(minutes: 2)),
      ))!;
      await harness.ledger.commitAccepted(
        foreground,
        normalizedFingerprint: 'sha256:shared-evidence-consumer',
        now: now.add(const Duration(minutes: 3)),
      );

      expect(
        await harness.ledger.tryScheduleOs(
          sourceEventId: 'os-replay:source',
          deliveryId: 'proactive:os-replay',
          topicKey: 'presence.time.morning',
          evidenceKey: 'shared:evidence',
          scheduledFor: scheduledFor,
          expiresAt: expiresAt,
          dailyBudgetLimit: 3,
          now: now.add(const Duration(minutes: 4)),
        ),
        isNull,
      );
      expect(
        (await harness.ledger.get(scheduled!.outreachId))!.state,
        OutreachState.cancelled,
      );
    },
  );

  test('a newly assumed old schedule remains fresh policy history', () async {
    const retention = OutreachLedgerRetention(
      historyCount: 32,
      historyAge: Duration(days: 30),
    );
    final harness = await _Harness.create(
      'outreach-history-occurrence-time.db',
      retention: retention,
    );
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 26, 8);
    final createdAt = now.subtract(const Duration(days: 31));
    final scheduledFor = now.add(const Duration(minutes: 1));
    final scheduled = await harness.ledger.scheduleOs(
      sourceEventId: 'old-created:fresh-occurrence',
      deliveryId: 'proactive:old-created:fresh-occurrence',
      topicKey: 'presence.time.morning',
      scheduledFor: scheduledFor,
      expiresAt: now.add(const Duration(minutes: 2)),
      now: createdAt,
    );

    await harness.ledger.recover(now: now.add(const Duration(minutes: 2)));

    final history = await harness.ledger.policyHistory(
      limit: 10,
      since: now.subtract(const Duration(days: 30)),
      until: now.add(const Duration(minutes: 3)),
    );
    expect(history.map((record) => record.outreachId), <String>[
      scheduled.outreachId,
    ]);
    expect(history.single.state, OutreachState.assumedDelivered);
  });

  test('OS scheduling rejects a target that is already in the past', () async {
    final harness = await _Harness.create('outreach-past-schedule.db');
    addTearDown(harness.close);
    final now = DateTime.utc(2026, 8, 27, 0, 5);

    await expectLater(
      harness.ledger.tryScheduleOs(
        sourceEventId: 'past-schedule:source',
        deliveryId: 'proactive:past-schedule',
        topicKey: 'presence.time.evening',
        scheduledFor: now.subtract(const Duration(minutes: 10)),
        expiresAt: now.add(const Duration(minutes: 20)),
        dailyBudgetLimit: 1,
        now: now,
      ),
      throwsArgumentError,
    );
  });

  test(
    'compact uniqueness markers remain durable after full rows prune',
    () async {
      const retention = OutreachLedgerRetention(
        historyCount: 0,
        historyAge: Duration.zero,
        diagnosticCount: 0,
        diagnosticAge: Duration.zero,
      );
      final harness = await _Harness.create(
        'outreach-marker-retention.db',
        retention: retention,
      );
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      for (var index = 0; index < 6; index++) {
        final at = now.add(Duration(seconds: index * 2));
        final reservation = (await harness.ledger.reserve(
          sourceEventId: 'bounded-marker-$index',
          topicKey: 'marker-$index',
          now: at,
        ))!;
        await harness.ledger.commitAccepted(
          reservation,
          normalizedFingerprint: 'sha256:marker-$index',
          now: at.add(const Duration(seconds: 1)),
        );
      }

      await harness.ledger.recover(now: now.add(const Duration(days: 730)));

      expect(
        await harness.ledger.hasSourceEventBeenConsumed('bounded-marker-0'),
        isTrue,
      );
      expect(
        await harness.ledger.hasSourceEventBeenConsumed('bounded-marker-5'),
        isTrue,
      );
    },
  );

  test(
    'assumed delivery cannot be recorded before the target window',
    () async {
      final harness = await _Harness.create('outreach-early-assumed.db');
      addTearDown(harness.close);
      final now = DateTime.utc(2026, 8, 26, 8);
      final scheduled = await harness.ledger.scheduleOs(
        sourceEventId: 'os:early-assumed',
        deliveryId: 'proactive:early-assumed',
        topicKey: 'presence.time.morning',
        scheduledFor: now.add(const Duration(hours: 1)),
        expiresAt: now.add(const Duration(hours: 2)),
        now: now,
      );

      await expectLater(
        harness.ledger.markAssumedDelivered(
          outreachId: scheduled.outreachId,
          now: now.add(const Duration(minutes: 30)),
        ),
        throwsStateError,
      );
      expect(
        (await harness.ledger.get(scheduled.outreachId))!.state,
        OutreachState.scheduledOs,
      );
    },
  );

  test('separate account databases cannot observe each other', () async {
    final first = await _Harness.create('outreach-account-a.db');
    final second = await _Harness.create('outreach-account-b.db');
    addTearDown(first.close);
    addTearDown(second.close);
    final now = DateTime.utc(2026, 8, 26, 8);

    final reservation = (await first.ledger.reserve(
      sourceEventId: 'same-source',
      topicKey: 'quietPresence',
      now: now,
    ))!;

    expect(await first.ledger.get(reservation.outreachId), isNotNull);
    expect(await second.ledger.get(reservation.outreachId), isNull);
    expect(await second.ledger.findBySourceEventId('same-source'), isNull);
  });
}

final class _Harness {
  _Harness(
    this.database, {
    OutreachLedgerRetention retention = const OutreachLedgerRetention(),
  }) : ledger = ProactiveOutreachLedger(
         accountDatabase: database,
         retention: retention,
       );

  final DBService database;
  final ProactiveOutreachLedger ledger;
  final StoreRef<int, Map<String, Object?>> chatMessages = intMapStoreFactory
      .store('chat_messages');

  static Future<_Harness> create(
    String path, {
    OutreachLedgerRetention retention = const OutreachLedgerRetention(),
  }) async {
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    return _Harness(database, retention: retention);
  }

  Future<void> close() => database.close();
}
