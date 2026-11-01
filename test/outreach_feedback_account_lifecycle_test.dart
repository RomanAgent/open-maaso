import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/account_runtime_producer_fence.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'producer fence preserves an admitted collector mutation and retire fails closed',
    () async {
      final accountA = await _AccountFeedbackHarness.create(
        'feedback-account-lifecycle-a.db',
      );
      addTearDown(accountA.close);

      final delivered = await accountA.deliverForeground(
        source: 'account-a-presence',
      );
      expect(
        await accountA.collector.recordDelivered(delivered),
        OutreachFeedbackMutationResult.recorded,
      );

      accountA.clock.advance(const Duration(minutes: 2));
      final releaseProducer = Completer<void>();
      late int messageRecordId;
      final admittedProducer = () async {
        await releaseProducer.future;
        messageRecordId = await accountA.persistUserMessage();
        return accountA.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        );
      }();

      final fenceController = AccountRuntimeProducerFenceController();
      final fence = fenceController.install(() async {
        await admittedProducer;
        await accountA.collector.reconcile(now: accountA.clock.now);
        await accountA.collector.deactivateAndDrain();
      });

      var drainCompleted = false;
      final drain = fence.fenceAndDrain().then((_) => drainCompleted = true);
      await Future<void>.delayed(Duration.zero);
      expect(drainCompleted, isFalse);

      releaseProducer.complete();
      expect(await admittedProducer, OutreachFeedbackMutationResult.recorded);
      await drain;
      await fence.complete();
      expect(drainCompleted, isTrue);
      expect(fenceController.hasActiveMount, isFalse);
      expect(
        await accountA.collector.recordMuted(preferenceRevision: 1),
        OutreachFeedbackMutationResult.retired,
      );
      expect(
        await accountA.collector.recordUserResponse(
          messageRecordId: messageRecordId,
        ),
        OutreachFeedbackMutationResult.retired,
      );

      final accountB = await _AccountFeedbackHarness.create(
        'feedback-account-lifecycle-b.db',
      );
      addTearDown(accountB.close);
      expect(await accountB.collector.get(delivered.outreachId), isNull);
      expect(accountB.collector.state.value.posteriorSamples, 0);
      expect(accountB.collector.state.value.pending, 0);

      await accountA.restartCollector();
      final restored = await accountA.collector.get(delivered.outreachId);
      expect(restored?.outcome, OutreachFeedbackOutcome.responded);
      expect(restored?.responseLatency, const Duration(minutes: 2));
      expect(accountA.collector.posterior.availableMass, 2);
      expect(accountA.collector.posterior.unavailableMass, 4);
      expect(accountA.collector.state.value.posteriorSamples, 1);
      expect(accountA.collector.state.value.pending, 0);

      expect(await accountB.collector.get(delivered.outreachId), isNull);
      expect(accountB.collector.state.value.posteriorSamples, 0);
      expect(
        accountB.collector.state.value.events[OutreachFeedbackSignal.muted] ??
            0,
        0,
      );
    },
  );

  test(
    'mute revision replay is idempotent per account and isolated across B',
    () async {
      final accountA = await _AccountFeedbackHarness.create(
        'feedback-account-mute-a.db',
      );
      addTearDown(accountA.close);

      expect(
        await accountA.collector.recordMuted(preferenceRevision: 7),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(_muteEvents(accountA.collector), 1);

      await accountA.restartCollector();
      expect(_muteEvents(accountA.collector), 1);
      expect(
        await accountA.collector.recordMuted(preferenceRevision: 7),
        OutreachFeedbackMutationResult.duplicate,
      );
      expect(_muteEvents(accountA.collector), 1);

      expect(
        await accountA.collector.recordUnmuted(preferenceRevision: 8),
        OutreachFeedbackMutationResult.recorded,
      );
      await accountA.restartCollector();
      expect(
        await accountA.collector.recordUnmuted(preferenceRevision: 8),
        OutreachFeedbackMutationResult.duplicate,
      );
      expect(_muteEvents(accountA.collector), 1);

      final accountB = await _AccountFeedbackHarness.create(
        'feedback-account-mute-b.db',
      );
      addTearDown(accountB.close);
      expect(_muteEvents(accountB.collector), 0);
      expect(
        await accountB.collector.recordMuted(preferenceRevision: 7),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(_muteEvents(accountB.collector), 1);
      expect(_muteEvents(accountA.collector), 1);
    },
  );

  test(
    'real account lifecycle keeps A services published until admitted feedback drains',
    () async {
      await appServices.reset();
      appServices.testMode = true;
      appServices.put<SecureStorageService>(_MemorySecureStorageService());
      final environment = appServices.put(AppEnvironmentService());
      await environment.init();
      final auth = appServices.put(_LifecycleAuthSessionService());
      final runtimes = <String, _LifecycleFeedbackRuntime>{};
      final accountBMountStarted = Completer<void>();
      final lifecycle = AccountSessionLifecycleService(
        auth: auth,
        environment: environment,
        mountRuntime: (mount) async {
          final accountUuid = mount.scope.accountUuid;
          if (accountUuid == 'account-b' && !accountBMountStarted.isCompleted) {
            accountBMountStarted.complete();
          }
          final runtime = await _LifecycleFeedbackRuntime.create(accountUuid);
          runtimes[accountUuid] = runtime;
          runtime.publish();
          return runtime;
        },
      );
      addTearDown(() async {
        try {
          await lifecycle.unmount();
        } finally {
          lifecycle.closeLifecycle();
          for (final runtime in runtimes.values) {
            await runtime.dispose();
          }
          await appServices.reset();
        }
      });

      expect(
        await lifecycle.authenticateAndMount(() async {
          auth.stage(_lifecycleSession('account-a'));
        }),
        isTrue,
      );
      final accountA = runtimes['account-a']!;
      final delivered = await accountA.deliverForeground(
        source: 'lifecycle-account-a',
      );
      accountA.trackedOutreachId = delivered.outreachId;
      expect(
        await accountA.collector.recordDelivered(delivered),
        OutreachFeedbackMutationResult.recorded,
      );
      expect(
        (await accountA.collector.get(delivered.outreachId))?.outcome,
        isNull,
      );
      expect(accountA.collector.state.value.pending, 1);
      accountA.clock.advance(const Duration(minutes: 3));

      final releaseProducer = Completer<void>();
      final messagePersisted = Completer<void>();
      final allowProducerToFinish = Completer<void>();
      addTearDown(() {
        if (!releaseProducer.isCompleted) releaseProducer.complete();
        if (!allowProducerToFinish.isCompleted) {
          allowProducerToFinish.complete();
        }
      });
      var producerUsedAccountA = false;
      final admittedProducer = accountA.registry.runAccountOperation(() async {
        await releaseProducer.future;
        final activeDatabase = appServices.find<DBService>();
        producerUsedAccountA = identical(activeDatabase, accountA.database);
        await activeDatabase.saveChatMessage(
          ChatMessage(
            sessionId: 'self',
            senderId: 'user',
            receiverId: 'self',
            content: 'durable A response before B mounts',
            timestamp: accountA.clock.now,
            isUserMessage: true,
            turnOrigin: ChatMessageTurnOrigins.user,
          ),
        );
        messagePersisted.complete();
        await allowProducerToFinish.future;
      });

      var switchCompleted = false;
      final switchToB = lifecycle
          .authenticateAndMount(() async {
            auth.stage(_lifecycleSession('account-b'));
          })
          .then((mounted) {
            switchCompleted = true;
            return mounted;
          });
      await Future<void>.delayed(Duration.zero);

      expect(accountBMountStarted.isCompleted, isFalse);
      expect(switchCompleted, isFalse);
      expect(accountA.registry.isRetiring, isTrue);

      releaseProducer.complete();
      await messagePersisted.future;
      expect(
        (await accountA.collector.get(delivered.outreachId))?.outcome,
        isNull,
      );
      expect(accountA.collector.state.value.pending, 1);
      expect(accountA.collector.state.value.posteriorSamples, 0);
      expect(accountBMountStarted.isCompleted, isFalse);
      expect(switchCompleted, isFalse);

      allowProducerToFinish.complete();
      await admittedProducer;
      expect(await switchToB, isTrue);
      expect(producerUsedAccountA, isTrue);
      expect(lifecycle.activeScope?.accountUuid, 'account-b');
      expect(accountBMountStarted.isCompleted, isTrue);
      expect(accountA.drainedOutcome, OutreachFeedbackOutcome.responded);
      expect(accountA.drainedPosteriorSamples, 1);
      expect(
        await accountA.collector.recordMuted(preferenceRevision: 1),
        OutreachFeedbackMutationResult.retired,
      );

      final accountB = runtimes['account-b']!;
      expect(await accountB.collector.get(delivered.outreachId), isNull);
      expect(accountB.collector.state.value.posteriorSamples, 0);
      expect(accountB.collector.state.value.pending, 0);

      var staleProducerRan = false;
      await accountA.registry.runAccountOperation(() async {
        staleProducerRan = true;
        await appServices.find<DBService>().saveChatMessage(
          ChatMessage(
            sessionId: 'self',
            senderId: 'user',
            receiverId: 'self',
            content: 'must never reach account B',
            timestamp: accountB.clock.now,
            isUserMessage: true,
            turnOrigin: ChatMessageTurnOrigins.user,
          ),
        );
      });
      expect(staleProducerRan, isFalse);
      expect(
        (await accountB.database.getMessages(
          'self',
        )).where((message) => message.isUserMessage),
        isEmpty,
      );
    },
  );

  test(
    'production feedback drain waits producer tails before reconcile and retire',
    () {
      final source = File('lib/main.dart').readAsStringSync();
      final feedbackStart = source.indexOf(
        "final outreachFeedbackDrain = barrier.run('outreach_feedback'",
      );
      final featureFlagStart = source.indexOf(
        "final featureFlagDrain = barrier.run('feature_flags'",
        feedbackStart,
      );
      expect(feedbackStart, greaterThanOrEqualTo(0));
      expect(featureFlagStart, greaterThan(feedbackStart));

      final feedbackDrain = source.substring(feedbackStart, featureFlagStart);
      final waitStart = feedbackDrain.indexOf('await Future.wait<void>');
      final waitEnd = feedbackDrain.indexOf(
        '], eagerError: false);',
        waitStart,
      );
      final reconcile = feedbackDrain.indexOf('await collector.reconcile(');
      final retire = feedbackDrain.indexOf(
        'await collector.deactivateAndDrain()',
      );
      expect(waitStart, greaterThanOrEqualTo(0));
      expect(waitEnd, greaterThan(waitStart));
      expect(reconcile, greaterThan(waitEnd));
      expect(retire, greaterThan(reconcile));

      final producerWait = feedbackDrain.substring(waitStart, waitEnd);
      for (final dependency in <String>[
        'runtimeDrain',
        'proactiveNotificationDrain',
        'proactivePreferenceDrain',
        'companionVoiceDrain',
      ]) {
        expect(
          producerWait,
          contains(dependency),
          reason: '$dependency must settle before the final feedback replay.',
        );
      }

      final featureFlagDrain = source.substring(
        featureFlagStart,
        source.indexOf(
          "final approvalHostDrain = barrier.run('action_approval_host'",
          featureFlagStart,
        ),
      );
      expect(
        featureFlagDrain.indexOf('await outreachFeedbackDrain'),
        lessThan(featureFlagDrain.indexOf('?.deactivateAndDrain()')),
        reason: 'Rollout admission must outlive feedback final replay.',
      );
    },
  );
}

int _muteEvents(OutreachFeedbackCollector collector) =>
    collector.state.value.events[OutreachFeedbackSignal.muted] ?? 0;

final class _MutableClock {
  _MutableClock(this.now);

  DateTime now;

  void advance(Duration duration) => now = now.add(duration);
}

final class _AccountFeedbackHarness {
  _AccountFeedbackHarness({
    required this.database,
    required this.flags,
    required this.ledger,
    required this.collector,
    required this.clock,
  });

  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactiveOutreachLedger ledger;
  OutreachFeedbackCollector collector;
  final _MutableClock clock;
  var _sequence = 0;

  static Future<_AccountFeedbackHarness> create(String path) async {
    final clock = _MutableClock(DateTime.utc(2026, 8, 29, 9));
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
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
      expiresAt: clock.now.add(const Duration(days: 30)),
    );
    final ledger = ProactiveOutreachLedger(accountDatabase: database);
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => clock.now,
    ).init();
    return _AccountFeedbackHarness(
      database: database,
      flags: flags,
      ledger: ledger,
      collector: collector,
      clock: clock,
    );
  }

  Future<OutreachRecord> deliverForeground({required String source}) async {
    final sequence = ++_sequence;
    final reservation = (await ledger.reserve(
      sourceEventId: '$source:$sequence',
      topicKey: 'quietPresence',
      now: clock.now,
    ))!;
    final idempotencyKey = 'proactive:${reservation.outreachId}';
    await ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'account-feedback-$sequence',
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
    return ledger.markDelivered(reservation, now: clock.now);
  }

  Future<int> persistUserMessage() => database.saveChatMessage(
    ChatMessage(
      sessionId: 'self',
      senderId: 'user',
      receiverId: 'self',
      content: 'not-visible-to-feedback',
      timestamp: clock.now,
      isUserMessage: true,
      turnOrigin: ChatMessageTurnOrigins.user,
    ),
  );

  Future<void> restartCollector() async {
    await collector.deactivateAndDrain();
    collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => clock.now,
    ).init();
  }

  Future<void> close() async {
    await collector.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await database.close();
  }
}

final class _LifecycleFeedbackRuntime implements AccountRuntimeLease {
  _LifecycleFeedbackRuntime({
    required this.accountUuid,
    required this.database,
    required this.flags,
    required this.ledger,
    required this.collector,
    required this.registry,
    required this.clock,
  });

  final String accountUuid;
  final DBService database;
  final MaasoFeatureFlagService flags;
  final ProactiveOutreachLedger ledger;
  final OutreachFeedbackCollector collector;
  final AgentRuntimeRegistry registry;
  final _MutableClock clock;
  String? trackedOutreachId;
  OutreachFeedbackOutcome? drainedOutcome;
  int drainedPosteriorSamples = 0;
  bool _closed = false;
  var _sequence = 0;

  static Future<_LifecycleFeedbackRuntime> create(String accountUuid) async {
    final clock = _MutableClock(DateTime.utc(2026, 8, 29, 12));
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'feedback-lifecycle-$accountUuid.db',
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
      expiresAt: clock.now.add(const Duration(days: 30)),
    );
    final ledger = ProactiveOutreachLedger(accountDatabase: database);
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => clock.now,
    ).init();
    return _LifecycleFeedbackRuntime(
      accountUuid: accountUuid,
      database: database,
      flags: flags,
      ledger: ledger,
      collector: collector,
      registry: AgentRuntimeRegistry(),
      clock: clock,
    );
  }

  void publish() {
    appServices.put<DBService>(database);
    appServices.put<MaasoFeatureFlagService>(flags);
    appServices.put<ProactiveOutreachLedger>(ledger);
    appServices.put<OutreachFeedbackCollector>(collector);
    appServices.put<AgentRuntimeRegistry>(registry);
  }

  Future<OutreachRecord> deliverForeground({required String source}) async {
    final sequence = ++_sequence;
    final reservation = (await ledger.reserve(
      sourceEventId: '$source:$sequence',
      topicKey: 'quietPresence',
      now: clock.now,
    ))!;
    final idempotencyKey = 'proactive:${reservation.outreachId}';
    await ledger.commitAccepted(
      reservation,
      normalizedFingerprint: 'lifecycle-$accountUuid-$sequence',
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
    return ledger.markDelivered(reservation, now: clock.now);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    await registry.shutdown();
    await collector.reconcile(now: clock.now);
    final outreachId = trackedOutreachId;
    if (outreachId != null) {
      drainedOutcome = (await collector.get(outreachId))?.outcome;
    }
    drainedPosteriorSamples = collector.state.value.posteriorSamples;
    await collector.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await appServices.delete<AgentRuntimeRegistry>(force: true);
    await appServices.delete<OutreachFeedbackCollector>(force: true);
    await appServices.delete<ProactiveOutreachLedger>(force: true);
    await appServices.delete<MaasoFeatureFlagService>(force: true);
    await database.close();
    await appServices.delete<DBService>(force: true);
    _closed = true;
  }

  Future<void> dispose() => close();
}

final class _LifecycleAuthSessionService extends AuthSessionService {
  MaasoAuthCandidate? _candidate;
  var _operationEpoch = 0;

  @override
  MaasoAuthCandidate? get candidate => _candidate;

  void stage(MaasoAuthSession session) {
    _candidate = MaasoAuthCandidate(
      environment: appServices.find<AppEnvironmentService>().environment.value,
      session: session,
      operationEpoch: ++_operationEpoch,
      logoutFence: const AuthLogoutPendingSnapshot(
        pending: false,
        revision: 1,
        token: 'feedback-lifecycle-cleared',
      ),
    );
    this.session.value = null;
  }

  @override
  Future<void> publishCandidate([MaasoAuthCandidate? expected]) async {
    final current = _candidate;
    if (current == null ||
        (expected != null && !identical(current, expected))) {
      throw StateError('authentication candidate changed');
    }
    session.value = current.session;
  }

  @override
  Future<void> unpublishSession() async {
    session.value = null;
  }
}

final class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    return true;
  }
}

MaasoAuthSession _lifecycleSession(String accountUuid) => MaasoAuthSession(
  accountUuid: accountUuid,
  accessToken: 'access-$accountUuid',
  refreshToken: 'refresh-$accountUuid',
  expiresAt: DateTime.now().add(const Duration(hours: 2)),
);
