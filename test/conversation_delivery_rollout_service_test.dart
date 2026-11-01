import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_delivery_rollout_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_utterance.dart';
import 'package:maaso/src/features/agent/data/models/execution_result.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final now = DateTime.utc(2026, 9, 4, 8);

  setUp(resetAppProviderContainerForTest);
  tearDown(resetAppProviderContainerForTest);

  test(
    'normal native build admits independent bubbles without a dart define',
    () async {
      expect(defaultConversationDeliveryMode, ConversationDeliveryMode.speech);
      final flags = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        clock: () => now,
      ).init();
      final rollout = ConversationDeliveryRolloutService(
        featureFlags: flags,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.ios,
        ),
        clock: () => now,
      );
      addTearDown(rollout.closeLifecycle);
      expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.speech);
      final database = await _database('conversation-default-speech.db');
      final controller = ConversationTurnController(
        agentId: 'self',
        deliveryAdmission: () {
          final snapshot = rollout.currentSnapshot();
          return ConversationDeliveryAdmission(
            mode: snapshot.mode,
            isCurrent: () => rollout.isCurrent(snapshot),
          );
        },
        isAvailable: () => true,
        stopOutput: () async {},
        briefPause: Duration.zero,
        runChat: (context, _) async {
          expect(context.deliveryMode, ConversationDeliveryMode.speech);
          await context.deliver([
            ConversationUtteranceDraft(
              text: '今天先休息。明天再看也来得及。',
              after: ConversationAfter.continueReply,
            ),
            ConversationUtteranceDraft(text: '嘿嘿'),
          ]);
          return ExecutionResult.success(context.deliveredText);
        },
      );
      addTearDown(controller.retireAndDrain);

      final result = await controller
          .submit('今天有点累', database: database, respondImmediately: true)
          .done;
      expect(result.execution.isSuccess, isTrue);
      expect(result.publishedMessages.map((message) => message.content), [
        '今天先休息。明天再看也来得及。',
        '嘿嘿',
      ]);
      expect(result.publishedMessages.map((message) => message.sequence), [
        0,
        1,
      ]);
    },
    skip: const bool.hasEnvironment('MAASO_CONVERSATION_DELIVERY'),
  );

  test(
    'explicit legacy compile define cannot be promoted by account rollout',
    () async {
      expect(defaultConversationDeliveryMode, ConversationDeliveryMode.legacy);
      final flags = await _flags(now);
      await _assign(flags, FeatureRolloutMode.enforce, now: now, revision: 1);
      final rollout = ConversationDeliveryRolloutService(
        featureFlags: flags,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.ios,
        ),
        clock: () => now,
      );
      addTearDown(rollout.closeLifecycle);
      expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
    },
    skip:
        const String.fromEnvironment('MAASO_CONVERSATION_DELIVERY') != 'legacy',
  );

  test('default platform allowlist keeps web on legacy delivery', () async {
    final flags = await _flags(now);
    final rollout = ConversationDeliveryRolloutService(
      featureFlags: flags,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.web,
      ),
      clock: () => now,
    );
    addTearDown(rollout.closeLifecycle);
    expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
  });

  test(
    'unassigned default is revoked by runtime cap, disableAll and retirement',
    () async {
      for (final revoke in [
        'runtimeOff',
        'runtimeShadow',
        'disableAll',
        'retire',
      ]) {
        final flags = await MaasoFeatureFlagService(
          store: _MemoryFeatureFlagStore(),
          clock: () => now,
        ).init();
        final rollout = ConversationDeliveryRolloutService(
          featureFlags: flags,
          compileMaximum: ConversationDeliveryMode.speech,
          platformCapabilities: const AppPlatformCapabilities.forPlatform(
            AppHostPlatform.ios,
          ),
          clock: () => now,
        );
        final admitted = rollout.currentSnapshot();
        expect(admitted.mode, ConversationDeliveryMode.speech);
        switch (revoke) {
          case 'runtimeOff':
            flags.setRuntimeMaximum(
              MaasoFeatureFlag.naturalConversation,
              FeatureRolloutMode.off,
            );
          case 'runtimeShadow':
            flags.setRuntimeMaximum(
              MaasoFeatureFlag.naturalConversation,
              FeatureRolloutMode.shadow,
            );
          case 'disableAll':
            flags.disableAll();
          case 'retire':
            await flags.deactivateAndDrain();
        }
        expect(
          rollout.currentSnapshot().mode,
          ConversationDeliveryMode.legacy,
          reason: revoke,
        );
        expect(rollout.isCurrent(admitted), isFalse, reason: revoke);
        rollout.closeLifecycle();
        flags.closeLifecycle();
      }
    },
  );

  test(
    'failed cache read cannot enable unassigned semantic delivery',
    () async {
      final flags = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore()..failReads = true,
        clock: () => now,
      ).init();
      final rollout = ConversationDeliveryRolloutService(
        featureFlags: flags,
        compileMaximum: ConversationDeliveryMode.speech,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.ios,
        ),
        clock: () => now,
      );
      addTearDown(rollout.closeLifecycle);
      expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
    },
  );

  test(
    'explicit legacy maximum remains legacy even when an account is enforced',
    () async {
      final flags = await _flags(now);
      await _assign(flags, FeatureRolloutMode.enforce, now: now, revision: 1);
      final rollout = ConversationDeliveryRolloutService(
        featureFlags: flags,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.ios,
        ),
        compileMaximum: ConversationDeliveryMode.legacy,
        clock: () => now,
      );
      addTearDown(rollout.closeLifecycle);

      expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
    },
  );

  test(
    'explicit internal speech build works before an assignment exists',
    () async {
      final flags = await _flags(now);
      final rollout = ConversationDeliveryRolloutService(
        featureFlags: flags,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.macos,
        ),
        compileMaximum: ConversationDeliveryMode.speech,
        clock: () => now,
      );
      addTearDown(rollout.closeLifecycle);

      final snapshot = rollout.currentSnapshot();
      expect(snapshot.mode, ConversationDeliveryMode.speech);
      expect(snapshot.assignmentRevision, isNull);
      expect(snapshot.observationEnabled, isFalse);
    },
  );

  test('closed rollout fails closed for internal builds', () async {
    final flags = await _flags(now);
    final rollout = ConversationDeliveryRolloutService(
      featureFlags: flags,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.macos,
      ),
      compileMaximum: ConversationDeliveryMode.speech,
      clock: () => now,
    );

    expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.speech);
    rollout.closeLifecycle();
    expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
  });

  test(
    'account assignment can shadow, enforce, and immediately revoke',
    () async {
      final flags = await _flags(now);
      final rollout = ConversationDeliveryRolloutService(
        featureFlags: flags,
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.android,
        ),
        compileMaximum: ConversationDeliveryMode.speech,
        clock: () => now,
      );
      addTearDown(rollout.closeLifecycle);
      final changes = <ConversationDeliveryRolloutSnapshot>[];
      final subscription = rollout.changes.listen(changes.add);
      addTearDown(subscription.cancel);

      await _assign(flags, FeatureRolloutMode.shadow, now: now, revision: 1);
      final shadow = rollout.currentSnapshot();
      expect(shadow.mode, ConversationDeliveryMode.legacy);
      expect(shadow.observationEnabled, isTrue);

      await _assign(flags, FeatureRolloutMode.enforce, now: now, revision: 2);
      final admitted = rollout.currentSnapshot();
      expect(admitted.mode, ConversationDeliveryMode.speech);
      expect(rollout.isCurrent(admitted), isTrue);

      flags.setRuntimeMaximum(
        MaasoFeatureFlag.naturalConversation,
        FeatureRolloutMode.off,
      );
      expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
      expect(rollout.isCurrent(admitted), isFalse);
      expect(
        changes.map((item) => item.mode),
        containsAllInOrder([
          ConversationDeliveryMode.legacy,
          ConversationDeliveryMode.speech,
          ConversationDeliveryMode.legacy,
        ]),
      );
    },
  );

  test('assignment expiry actively revokes an admitted rollout', () async {
    var clock = now;
    final timers = _ManualTimerFactory();
    final flags = await _flagsWithClock(() => clock);
    final rollout = ConversationDeliveryRolloutService(
      featureFlags: flags,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.ios,
      ),
      compileMaximum: ConversationDeliveryMode.speech,
      clock: () => clock,
      timerFactory: timers.create,
    );
    addTearDown(rollout.closeLifecycle);
    final changes = <ConversationDeliveryRolloutSnapshot>[];
    final subscription = rollout.changes.listen(changes.add);
    addTearDown(subscription.cancel);

    await flags.assign(
      flag: MaasoFeatureFlag.naturalConversation,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    final admitted = rollout.currentSnapshot();
    expect(admitted.mode, ConversationDeliveryMode.speech);
    expect(timers.active.delay, const Duration(minutes: 5));

    clock = now.add(const Duration(minutes: 4, seconds: 59));
    timers.active.fire();
    expect(timers.active.delay, const Duration(seconds: 1));
    expect(changes.last.mode, ConversationDeliveryMode.speech);

    clock = now.add(const Duration(minutes: 5));
    timers.active.fire();
    expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
    expect(rollout.isCurrent(admitted), isFalse);
    expect(changes.last.mode, ConversationDeliveryMode.legacy);
  });

  test('new assignment replaces the previous expiry timer', () async {
    var clock = now;
    final timers = _ManualTimerFactory();
    final flags = await _flagsWithClock(() => clock);
    final rollout = ConversationDeliveryRolloutService(
      featureFlags: flags,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.android,
      ),
      compileMaximum: ConversationDeliveryMode.text,
      clock: () => clock,
      timerFactory: timers.create,
    );
    addTearDown(rollout.closeLifecycle);

    await flags.assign(
      flag: MaasoFeatureFlag.naturalConversation,
      mode: FeatureRolloutMode.enforce,
      revision: 1,
      expiresAt: now.add(const Duration(minutes: 5)),
    );
    final firstTimer = timers.active;
    await flags.assign(
      flag: MaasoFeatureFlag.naturalConversation,
      mode: FeatureRolloutMode.enforce,
      revision: 2,
      expiresAt: now.add(const Duration(minutes: 10)),
    );

    expect(firstTimer.isActive, isFalse);
    expect(timers.active.delay, const Duration(minutes: 10));
  });

  test('platform allowlist is a hard upper bound', () async {
    final flags = await _flags(now);
    await _assign(flags, FeatureRolloutMode.enforce, now: now, revision: 1);
    final rollout = ConversationDeliveryRolloutService(
      featureFlags: flags,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.windows,
      ),
      compileMaximum: ConversationDeliveryMode.speech,
      enabledPlatforms: const <AppHostPlatform>{AppHostPlatform.ios},
      clock: () => now,
    );
    addTearDown(rollout.closeLifecycle);

    expect(rollout.currentSnapshot().mode, ConversationDeliveryMode.legacy);
    expect(rollout.currentSnapshot().observationEnabled, isFalse);
  });

  test(
    'platform parser ignores unknown values and never widens an empty list',
    () {
      expect(
        ConversationDeliveryRolloutService.parseEnabledPlatforms(
          'ios,ANDROID,unknown,ios',
        ),
        <AppHostPlatform>{AppHostPlatform.ios, AppHostPlatform.android},
      );
      expect(
        ConversationDeliveryRolloutService.parseEnabledPlatforms('unknown'),
        isEmpty,
      );
    },
  );

  test('turn controller freezes delivery mode at admission', () async {
    final database = await _database('conversation-rollout-snapshot.db');
    var mode = ConversationDeliveryMode.text;
    final entered = Completer<void>();
    final release = Completer<void>();
    late ConversationDeliveryMode observed;
    final controller = ConversationTurnController(
      agentId: 'self',
      deliveryMode: () => mode,
      isAvailable: () => true,
      stopOutput: () async {},
      runChat: (context, _) async {
        observed = context.deliveryMode;
        entered.complete();
        await release.future;
        return ExecutionResult.success('ok');
      },
    );
    addTearDown(controller.retireAndDrain);

    final handle = controller.submit('hello', database: database);
    await entered.future;
    mode = ConversationDeliveryMode.speech;
    release.complete();
    await handle.done;

    expect(observed, ConversationDeliveryMode.text);
  });

  test('revoked mode cannot race through controller admission', () async {
    final database = await _database('conversation-rollout-revoked.db');
    final controller = ConversationTurnController(
      agentId: 'self',
      deliveryMode: () => ConversationDeliveryMode.legacy,
      isAvailable: () => true,
      stopOutput: () async {},
      runChat: (_, _) async => ExecutionResult.success('unreachable'),
    );
    addTearDown(controller.retireAndDrain);

    expect(
      () => controller.submit('hello', database: database),
      throwsStateError,
    );
  });

  test(
    'stale enabled authority cannot race through controller admission',
    () async {
      final database = await _database('conversation-rollout-stale.db');
      final controller = ConversationTurnController(
        agentId: 'self',
        deliveryAdmission: () => ConversationDeliveryAdmission(
          mode: ConversationDeliveryMode.speech,
          isCurrent: () => false,
        ),
        isAvailable: () => true,
        stopOutput: () async {},
        runChat: (_, _) async => ExecutionResult.success('unreachable'),
      );
      addTearDown(controller.retireAndDrain);

      expect(
        () => controller.submit('hello', database: database),
        throwsStateError,
      );
    },
  );
}

Future<MaasoFeatureFlagService> _flags(DateTime now) => MaasoFeatureFlagService(
  store: _MemoryFeatureFlagStore(),
  compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
    MaasoFeatureFlag.naturalConversation: FeatureRolloutMode.enforce,
  },
  clock: () => now,
).init();

Future<MaasoFeatureFlagService> _flagsWithClock(DateTime Function() clock) =>
    MaasoFeatureFlagService(
      store: _MemoryFeatureFlagStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.naturalConversation: FeatureRolloutMode.enforce,
      },
      clock: clock,
    ).init();

Future<void> _assign(
  MaasoFeatureFlagService flags,
  FeatureRolloutMode mode, {
  required DateTime now,
  required int revision,
}) => flags.assign(
  flag: MaasoFeatureFlag.naturalConversation,
  mode: mode,
  revision: revision,
  expiresAt: now.add(const Duration(hours: 1)),
);

Future<DBService> _database(String path) async {
  final database = await DBService().init(
    factory: databaseFactoryMemory,
    path: path,
  );
  addTearDown(() async {
    await database.close();
    await databaseFactoryMemory.deleteDatabase(path);
  });
  return database;
}

final class _MemoryFeatureFlagStore implements MaasoFeatureFlagAssignmentStore {
  bool failReads = false;
  final Map<String, Map<String, Object?>> _rows =
      <String, Map<String, Object?>>{};

  @override
  Future<List<Map<String, Object?>>> readAll() async {
    if (failReads) throw StateError('injected_read_failure');
    return _rows.values.map(Map<String, Object?>.from).toList(growable: false);
  }

  @override
  Future<void> write(MaasoFeatureFlagAssignment assignment) async {
    _rows[assignment.flag.key] = assignment.toJson();
  }
}

final class _ManualTimerFactory {
  final List<_ManualTimer> timers = <_ManualTimer>[];

  _ManualTimer get active => timers.lastWhere((timer) => timer.isActive);

  Timer create(Duration delay, void Function() callback) {
    final timer = _ManualTimer(delay, callback);
    timers.add(timer);
    return timer;
  }
}

final class _ManualTimer implements Timer {
  _ManualTimer(this.delay, this._callback);

  final Duration delay;
  final void Function() _callback;
  bool _active = true;

  void fire() {
    if (!_active) return;
    _active = false;
    _callback();
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _active ? 0 : 1;
}
