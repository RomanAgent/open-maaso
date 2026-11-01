import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/account_device_lease_coordinator.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/memory_governance_store.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/proactive_companion_policy.dart';
import 'package:maaso/src/core/services/proactive_outreach_coordinator.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/features/relationship/presentation/proactive_conversation_controls.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => appServices.reset());
  tearDown(() => appServices.reset());

  test(
    'new account is off; explicit agreement round trips scope and expiry',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      expect(h.prefs.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(h.prefs.effectiveSnapshot.osOutreachAllowed, isFalse);
      expect(h.prefs.effectiveSnapshot.dailyBudget, 1);
      await h.enable();
      final restored = ProactivePreferenceSnapshot.fromStorageJson(
        h.prefs.effectiveSnapshot.toStorageJson(),
        generation: 2,
      );
      expect(restored.allowsTopic('presence.quiet', h.now), isTrue);
      expect(
        restored.allowsTopic(
          'presence.quiet',
          h.now.add(const Duration(days: 7)),
        ),
        isFalse,
      );
      await h.prefs.setContactScope(ProactiveConversationScope.openTopics);
      expect(
        h.prefs.effectiveSnapshot.allowsTopic('presence.quiet', h.now),
        isFalse,
      );
    },
  );

  test('v1 migration preserves restrictions but does not invent consent', () {
    final row =
        const ProactivePreferenceSnapshot.defaults(
            generation: 1,
          ).toStorageJson()
          ..removeWhere(
            (key, _) => {
              'consentRecorded',
              'needsConsentReview',
              'contactScope',
              'authorizedUntil',
              'authorizationOwnerKey',
              'agreementChangedAt',
              'lastUserReturnAt',
              'topics',
            }.contains(key),
          )
          ..['schemaVersion'] = 1
          ..['foregroundEnabled'] = true
          ..['osOutreachEnabled'] = true
          ..['hardMuted'] = true
          ..['dailyBudget'] = 2;
    final restored = ProactivePreferenceSnapshot.fromStorageJson(
      row,
      generation: 2,
    );
    expect(restored.hardMuted, isTrue);
    expect(restored.dailyBudget, 2);
    expect(restored.quietStartMinutes, 22 * 60);
    expect(restored.needsConsentReview, isTrue);
    expect(restored.consentRecorded, isFalse);
    expect(restored.foregroundEnabled, isFalse);
    expect(restored.osOutreachEnabled, isFalse);
  });

  test(
    'only a persisted direct user request creates a one-time topic',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.prefs.observeCurrentTurn();
      expect(h.prefs.effectiveSnapshot.topics, isEmpty);
      for (final text in [
        '他说明天15点问我面试结果',
        '不要明天15点问我面试结果',
        '“明天15点问我面试结果”',
        '明天面试结束后问我',
        '明天25点问我面试结果',
      ]) {
        await h.say(text);
      }
      expect(h.prefs.effectiveSnapshot.topics, isEmpty);
      await h.say('明天15点问我面试结果', user: false);
      expect(h.prefs.effectiveSnapshot.topics, isEmpty);
      final id = await h.say('明天15点问我面试结果');
      final topic = h.prefs.effectiveSnapshot.topics.single;
      expect(topic.source.sourceId, 'chat_message:$id');
      expect(topic.agentId, 'agent-a');
      expect(h.prefs.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(
        h.prefs.effectiveSnapshot.allowsTopic(topic.topicKey, h.now),
        isFalse,
      );
      expect(
        h.prefs.effectiveSnapshot.allowsTopic(topic.topicKey, topic.dueAt),
        isTrue,
      );
      expect(
        h.prefs.effectiveSnapshot.allowsTopic(topic.topicKey, topic.expiresAt),
        isFalse,
      );
      expect(ProactiveConversationTopic.fromJson(topic.toJson()).id, topic.id);
    },
  );

  test(
    'completion, explicit closure, expiry and deleted source revoke only their topic',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final id = await h.say('明天15点问我面试结果');
      await h.say('明天16点问我论文进展');
      await h.say('面试通过了');
      expect(
        h.prefs.effectiveSnapshot.topics.first.status,
        ProactiveTopicStatus.completed,
      );
      expect(
        h.prefs.effectiveSnapshot.topics.last.status,
        ProactiveTopicStatus.open,
      );
      await MemoryGovernanceStores.chatMessages.record(id).delete(h.db.raw);
      await h.prefs.refreshContactSources();
      expect(
        h.prefs.effectiveSnapshot.topics.last.status,
        ProactiveTopicStatus.open,
      );
      final second = h.prefs.effectiveSnapshot.topics.last;
      h.now = second.expiresAt;
      await h.prefs.refreshContactSources();
      expect(
        h.prefs.effectiveSnapshot.topics.last.status,
        ProactiveTopicStatus.revoked,
      );
      expect(
        h.prefs.effectiveSnapshot.topics.first.status,
        ProactiveTopicStatus.completed,
      );
    },
  );

  test('source deletion or edit after generation prevents commit', () async {
    final h = await _Harness.open();
    addTearDown(h.close);
    final id = await h.say('明天15点问我面试结果');
    final topic = h.prefs.effectiveSnapshot.topics.single;
    h.now = topic.dueAt;
    final attempt = await h.prepare(
      topic.topicKey,
      source: 'conversation-followup:${topic.id}',
    );
    expect(attempt.shouldGenerate, isTrue);
    await MemoryGovernanceStores.chatMessages.record(id).delete(h.db.raw);
    final result = await h.commit(attempt.attempt!);
    expect(result.isAccepted, isFalse);
    expect(await h.messages(), 0);
    expect(
      h.prefs.effectiveSnapshot.topics.single.status,
      ProactiveTopicStatus.revoked,
    );
  });

  test(
    'queued source deletion is checked inside the visible-message transaction',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final id = await h.say('明天15点问我面试结果');
      final topic = h.prefs.effectiveSnapshot.topics.single;
      h.now = topic.dueAt;
      final attempt = (await h.prepare(topic.topicKey)).attempt!;
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = h.prefs.runWithStableSnapshot((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      final committing = h.commit(attempt);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await MemoryGovernanceStores.chatMessages.record(id).delete(h.db.raw);
      release.complete();
      await blocker;
      expect((await committing).isAccepted, isFalse);
      expect(await h.messages(), 0);
    },
  );

  test(
    'English contact requests stay direct and use explicit local clock time',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      for (final input in [
        'He said tomorrow at 15:00 ask me about the interview',
        'Do not tomorrow at 15:00 ask me about the interview',
        'Tomorrow after the interview ask me about it',
      ]) {
        await h.say(input);
      }
      expect(h.prefs.effectiveSnapshot.topics, isEmpty);
      await h.say('Tomorrow at 15:00 ask me about the interview');
      expect(h.prefs.effectiveSnapshot.topics.single.label, 'the interview');
    },
  );

  test(
    'ordinary generation captures consent version and exact owner guard',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.enable();
      final prepared = await h.prepare('presence.quiet');
      await h.prefs.setContactScope(ProactiveConversationScope.openTopics);
      expect((await h.commit(prepared.attempt!)).isAccepted, isFalse);
      await h.prefs.setContactScope(ProactiveConversationScope.everyday);
      final second = (await h.prepare(
        'fresh-topic',
        source: 'second',
      )).attempt!;
      final revoked = ProactiveOutreachAttempt(
        candidate: second.candidate,
        reservation: second.reservation,
        preparedAt: second.preparedAt,
        respectQuietHours: second.respectQuietHours,
        authorizationRevision: second.authorizationRevision,
        authorizationGeneration: second.authorizationGeneration,
        executionGuard: () => false,
      );
      expect((await h.commit(revoked)).isAccepted, isFalse);
      expect(await h.messages(), 0);
    },
  );

  test(
    'expiry crossed during generation and quiet hours prevent submission',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.enable();
      await h.prefs.setAuthorizationExpiry(
        h.now.add(const Duration(minutes: 1)),
      );
      final attempt = (await h.prepare('presence.quiet')).attempt!;
      h.now = h.now.add(const Duration(minutes: 1));
      expect((await h.commit(attempt)).isAccepted, isFalse);
      await h.prefs.setAuthorizationExpiry(null);
      await h.prefs.setQuietHours(start: 0, end: 23 * 60);
      expect(
        (await h.prepare('quiet-period', source: 'quiet')).shouldGenerate,
        isFalse,
      );
    },
  );

  test(
    'unanswered survives topic change, retention pruning and restart until user return',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.enable();
      await h.prefs.setAuthorizationExpiry(null);
      final first = (await h.prepare('presence.quiet')).attempt!;
      expect((await h.commit(first)).isAccepted, isTrue);
      h.now = h.now.add(const Duration(days: 100));
      await h.ledger.recover(now: h.now);
      final restarted = ProactiveOutreachCoordinator(
        policy: ProactivePreferencePolicyAdapter(h.prefs),
        ledger: h.ledger,
        accountKey: 'account-a',
        clock: () => h.now,
        preferences: h.prefs,
      );
      expect(await restarted.hasUnansweredOutreach(now: h.now), isTrue);
      expect(
        (await restarted.prepare(
          sourceEventId: 'new-topic',
          candidates: const [
            ProactiveTopicCandidate(
              kind: ProactiveTopicKind.quietPresence,
              topicKey: 'different',
            ),
          ],
          now: h.now,
        )).decision?.reason,
        ProactiveSilenceReason.waitingForReply,
      );
      await h.say('我回来了');
      expect(await restarted.hasUnansweredOutreach(now: h.now), isFalse);
    },
  );

  test(
    'new one-time request after mute does not restore ordinary authorization',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.enable();
      await h.prefs.setHardMuted(true);
      await h.say('明天15点问我面试结果');
      expect(h.prefs.effectiveSnapshot.hardMuted, isFalse);
      expect(h.prefs.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(h.prefs.effectiveSnapshot.osOutreachAllowed, isFalse);
      expect(
        h.prefs.effectiveSnapshot.topics.single.status,
        ProactiveTopicStatus.open,
      );
      await h.prefs.setContactAgreement(
        enabled: false,
        scope: ProactiveConversationScope.openTopics,
      );
      expect(
        h.prefs.effectiveSnapshot.topics.single.status,
        ProactiveTopicStatus.revoked,
      );
    },
  );

  test(
    'owner epoch transfer revokes old agreement and one-time sources',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      final owner = _Owner();
      appServices.put<AccountDeviceLeaseCoordinator>(owner);
      await h.enable();
      await h.say('明天15点问我面试结果');
      expect(h.prefs.effectiveSnapshot.authorizationOwnerKey, 'lease-1:1');
      owner.epoch = 2;
      await h.prefs.refreshContactSources();
      expect(h.prefs.effectiveSnapshot.foregroundAllowed, isFalse);
      expect(h.prefs.effectiveSnapshot.needsConsentReview, isTrue);
      expect(
        h.prefs.effectiveSnapshot.topics.single.status,
        ProactiveTopicStatus.revoked,
      );
      await h.enable();
      expect(h.prefs.effectiveSnapshot.authorizationOwnerKey, 'lease-2:2');
      expect(h.prefs.effectiveSnapshot.foregroundAllowed, isTrue);
      expect(
        h.prefs.effectiveSnapshot.topics.single.status,
        ProactiveTopicStatus.revoked,
      );
    },
  );

  test(
    'ambiguous follow-up never claims scheduling and closure supersedes it',
    () async {
      final h = await _Harness.open();
      addTearDown(h.close);
      await h.say('明天面试结束后问我');
      expect(h.observation, ProactiveContactObservation.needsTime);
      expect(
        h.observation.replyGuidance,
        contains('No check-in has been scheduled'),
      );
      await h.say('下午三点');
      expect(h.observation, ProactiveContactObservation.needsTime);
      expect(h.prefs.effectiveSnapshot.topics, isEmpty);
      await h.say('明天15点问我面试结果');
      expect(h.observation, ProactiveContactObservation.scheduled);
      await h.say('面试通过了');
      expect(h.observation, ProactiveContactObservation.closed);
      await h.say('不用问面试结果了');
      expect(h.observation, ProactiveContactObservation.cancelled);
    },
  );

  testWidgets(
    'settings expose real opt-in, scope, budget and expiry controls',
    (tester) async {
      final h = (await tester.runAsync(_Harness.open))!;
      addTearDown(() => tester.runAsync(h.close));
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: ProactiveConversationControls()),
          ),
        ),
      );
      expect(find.text('Start a conversation with me'), findsOneWidget);
      expect(find.text('Contact scope'), findsOneWidget);
      expect(find.text('Daily limit'), findsOneWidget);
      expect(find.text('Authorization expires'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch).first);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(h.prefs.effectiveSnapshot.consentRecorded, isTrue);
      expect(h.prefs.effectiveSnapshot.foregroundEnabled, isTrue);
      await tester.runAsync(() async {
        await tester.tap(find.byType(Switch).first);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pumpAndSettle();
      expect(h.prefs.effectiveSnapshot.hardMuted, isTrue);
    },
  );
}

int sequence = 0;

class _Harness {
  _Harness(this.db);
  final DBService db;
  DateTime now = DateTime(2026, 9, 16, 12);
  late ProactivePreferenceService prefs;
  ProactiveContactObservation observation = ProactiveContactObservation.none;
  late MemoryWriteCoordinator writer;
  late ProactiveOutreachLedger ledger;
  late ProactiveOutreachCoordinator coordinator;
  static Future<_Harness> open() async {
    final h = _Harness(
      await DBService().init(
        factory: databaseFactoryMemory,
        path: 'proactive-agreement-${sequence++}',
      ),
    );
    h.writer = appServices.put(
      MemoryWriteCoordinator(
        database: h.db.raw,
        accountScopeDigest: 'a' * 64,
        clock: () => h.now,
      ),
    );
    h.prefs = appServices.put(
      await ProactivePreferenceService(
        store: SembastProactivePreferenceStore(
          h.db,
          accountScopeDigest: 'a' * 64,
        ),
        accountScopeDigest: 'a' * 64,
        generation: 1,
        clock: () => h.now,
      ).init(),
    );
    h.ledger = ProactiveOutreachLedger(
      accountDatabase: h.db,
      clock: () => h.now,
      retention: const OutreachLedgerRetention(
        historyAge: Duration.zero,
        historyCount: 0,
      ),
    );
    h.coordinator = ProactiveOutreachCoordinator(
      policy: ProactivePreferencePolicyAdapter(h.prefs),
      ledger: h.ledger,
      accountKey: 'account-a',
      clock: () => h.now,
      preferences: h.prefs,
    );
    return h;
  }

  Future<void> enable() => prefs.setContactAgreement(
    enabled: true,
    scope: ProactiveConversationScope.everyday,
    expiresAt: now.add(const Duration(days: 7)),
  );
  Future<int> say(String text, {bool user = true}) async {
    now = now.add(const Duration(seconds: 1));
    final id = await MemoryGovernanceStores.chatMessages.add(
      db.raw,
      ChatMessage(
        sessionId: 'private',
        senderId: user ? 'user' : 'agent-a',
        receiverId: user ? 'agent-a' : 'user',
        content: text,
        timestamp: now,
        isUserMessage: user,
        turnOrigin: ChatMessageTurnOrigins.user,
        deliveryStatus: 'published',
      ).toJson(),
    );
    observation = await writer.runWithPersistedChatSource(
      messageRecordId: id,
      sessionId: 'private',
      agentId: 'agent-a',
      operation: prefs.observeCurrentTurn,
    );
    return id;
  }

  Future<ProactivePreparation> prepare(
    String key, {
    String source = 'source',
  }) => coordinator.prepare(
    sourceEventId: source,
    candidates: [
      ProactiveTopicCandidate(
        kind: ProactiveTopicKind.environmentObservation,
        topicKey: key,
      ),
    ],
    now: now,
  );
  Future<ProactiveDraftCommit> commit(ProactiveOutreachAttempt attempt) =>
      coordinator.commitDraft(
        attempt: attempt,
        draft: '刚才约好的话题，有空聊两句？',
        visibleMessageJson: ChatMessage(
          sessionId: 'private',
          senderId: 'agent-a',
          receiverId: 'user',
          content: '刚才约好的话题，有空聊两句？',
          timestamp: now,
          isUserMessage: false,
        ).toJson(),
        idempotencyKey: attempt.outreachId,
        now: now,
      );
  Future<int> messages() async =>
      (await MemoryGovernanceStores.chatMessages.find(
        db.raw,
      )).where((row) => row.value['isUserMessage'] == false).length;
  Future<void> close() async {
    await prefs.deactivateAndDrain();
    await writer.deactivateAndDrain();
    await db.close();
  }
}

class _Owner implements AccountDeviceLeaseCoordinator {
  int epoch = 1;
  @override
  bool get canAdmitMutations => true;
  @override
  AccountDeviceLeaseReceipt get currentReceipt => AccountDeviceLeaseReceipt(
    agentId: 'agent-a',
    leaseId: 'lease-$epoch',
    epoch: epoch,
    installationId: 'installation',
    runtimeInstanceId: 'runtime',
    presenceSessionId: 'presence',
    expiresAt: DateTime(2099),
    remainingTtl: const Duration(minutes: 2),
    renewAfter: const Duration(seconds: 30),
    holder: AccountDeviceLeaseHolder(
      installationId: 'installation',
      runtimeInstanceId: 'runtime',
      presenceSessionId: 'presence',
      deviceLabel: 'test',
      platform: 'test',
      lastSeenAt: DateTime(2026),
    ),
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
