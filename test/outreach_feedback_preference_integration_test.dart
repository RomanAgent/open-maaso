import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_outreach_ledger.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/utils/sp_utils.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/skills/behavior_skill.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SpUtils.init();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'AgentSettingsController persists mute and unmute before feedback projection',
    () async {
      final harness = await _PreferenceFeedbackHarness.create(
        'feedback-settings-integration.db',
      );
      addTearDown(harness.close);
      _registerSettingsDependencies(harness.database);
      final controller = AgentSettingsController();

      await controller.setProactiveHardMuted(true);
      await harness.collector.waitForIdle();

      var durable = await harness.store.read();
      expect(durable?['hardMuted'], isTrue);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        1,
      );
      expect(
        harness.collector.state.value.outcomes[OutreachFeedbackOutcome.muted],
        1,
      );

      await controller.setProactiveHardMuted(false);
      await harness.collector.waitForIdle();

      durable = await harness.store.read();
      expect(durable?['hardMuted'], isFalse);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        1,
        reason: 'Unmuting updates the baseline without adding a mute outcome.',
      );

      await controller.setProactiveHardMuted(true);
      await harness.collector.waitForIdle();

      durable = await harness.store.read();
      expect(durable?['hardMuted'], isTrue);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        2,
        reason: 'A new false-to-true durable transition is a new mute fact.',
      );
    },
  );

  test(
    'BehaviorSkill records only after durable write and repeated mute is idempotent',
    () async {
      final harness = await _PreferenceFeedbackHarness.create(
        'feedback-behavior-integration.db',
      );
      addTearDown(harness.close);
      final handler = BehaviorSkill(
        agentId: 'agent-a',
      ).methods['setProactiveHardMuted']!;
      harness.store.gateNextWrite();

      final resultFuture = Future<dynamic>.sync(
        () => handler(<dynamic>[
          jsonEncode(<String, Object?>{'muted': true}),
        ]),
      );
      await harness.store.writeStarted.future;

      expect((await harness.store.read())?['hardMuted'], isFalse);
      expect(harness.preferences.effectiveSnapshot.hardMuted, isTrue);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted] ?? 0,
        0,
        reason: 'The collector hook must remain behind the durable write.',
      );

      harness.store.releaseWrite();
      expect(jsonDecode((await resultFuture).toString()), <String, Object?>{
        'status': 'ok',
        'hardMuted': true,
      });
      await harness.collector.waitForIdle();

      final firstDurable = await harness.store.read();
      expect(firstDurable?['hardMuted'], isTrue);
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        1,
      );

      expect(
        jsonDecode((await handler(<dynamic>[true])).toString()),
        <String, Object?>{'status': 'ok', 'hardMuted': true},
      );
      await harness.collector.waitForIdle();

      final repeatedDurable = await harness.store.read();
      expect(
        repeatedDurable?['revision'] as int,
        greaterThan(firstDurable?['revision'] as int),
        reason:
            'The repeated request still completes its durable preference write.',
      );
      expect(
        harness.collector.state.value.events[OutreachFeedbackSignal.muted],
        1,
        reason: 'An already-muted account must not create another mute fact.',
      );
    },
  );
}

void _registerSettingsDependencies(DBService database) {
  appServices.put<DBService>(database);
  appServices.put<AgentCoreController>(_IdleAgentCoreController());
  final secureStorage = appServices.put<SecureStorageService>(
    _MemorySecureStorageService(),
  );
  final environment = appServices.put(AppEnvironmentService());
  final auth = appServices.put(AuthSessionService());
  appServices.put(
    AccountSessionLifecycleService(
      auth: auth,
      environment: environment,
      mountRuntime: (_) async => const _NoopAccountRuntimeLease(),
    ),
  );
  appServices.put<LLMConfigController>(
    LLMConfigController(storage: secureStorage),
  );
  appServices.put(LocaleConfigService());
  appServices.put(MaasoAgentModeService());
  appServices.put(AvatarConfigService());
}

final class _PreferenceFeedbackHarness {
  const _PreferenceFeedbackHarness({
    required this.database,
    required this.flags,
    required this.store,
    required this.preferences,
    required this.collector,
  });

  final DBService database;
  final MaasoFeatureFlagService flags;
  final _GatedSembastPreferenceStore store;
  final ProactivePreferenceService preferences;
  final OutreachFeedbackCollector collector;

  static Future<_PreferenceFeedbackHarness> create(String path) async {
    final now = DateTime.utc(2026, 8, 29, 8);
    final database = await DBService().init(
      factory: databaseFactoryMemory,
      path: path,
    );
    final flags = await MaasoFeatureFlagService(
      store: SembastMaasoFeatureFlagAssignmentStore(database),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.proactiveDrive: FeatureRolloutMode.shadow,
      },
      clock: () => now,
    ).init();
    await flags.assign(
      flag: MaasoFeatureFlag.proactiveDrive,
      mode: FeatureRolloutMode.shadow,
      revision: 1,
      expiresAt: now.add(const Duration(days: 30)),
    );
    final store = _GatedSembastPreferenceStore(
      SembastProactivePreferenceStore(database, accountScopeDigest: 'a' * 64),
    );
    final preferences = await ProactivePreferenceService(
      store: store,
      accountScopeDigest: 'a' * 64,
      generation: 1,
    ).init();
    final ledger = ProactiveOutreachLedger(accountDatabase: database);
    final collector = await OutreachFeedbackCollector(
      accountDatabase: database,
      ledger: ledger,
      featureFlags: flags,
      clock: () => now,
    ).init();
    appServices.put<ProactivePreferenceService>(preferences);
    appServices.put<OutreachFeedbackCollector>(collector);
    return _PreferenceFeedbackHarness(
      database: database,
      flags: flags,
      store: store,
      preferences: preferences,
      collector: collector,
    );
  }

  Future<void> close() async {
    await collector.deactivateAndDrain();
    await preferences.deactivateAndDrain();
    await flags.deactivateAndDrain();
    await database.close();
  }
}

final class _GatedSembastPreferenceStore implements ProactivePreferenceStore {
  _GatedSembastPreferenceStore(this._delegate);

  final SembastProactivePreferenceStore _delegate;
  Completer<void>? _writeGate;
  Completer<void> writeStarted = Completer<void>();

  @override
  Future<Map<String, Object?>?> read() => _delegate.read();

  @override
  Future<void> write(ProactivePreferenceSnapshot snapshot) async {
    final gate = _writeGate;
    if (gate != null) {
      if (!writeStarted.isCompleted) writeStarted.complete();
      await gate.future;
      _writeGate = null;
    }
    await _delegate.write(snapshot);
  }

  void gateNextWrite() {
    _writeGate = Completer<void>();
    writeStarted = Completer<void>();
  }

  void releaseWrite() => _writeGate?.complete();
}

final class _IdleAgentCoreController extends AgentCoreController {
  @override
  // Test double isolates the settings method from profile bootstrap.
  // ignore: must_call_super
  void onInit() {}
}

final class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> _values = <String, String>{};

  @override
  Future<String?> readPlatformValue(String key) async => _values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      _values.remove(key);
    } else {
      _values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async => _values.remove(key) != null;
}

final class _NoopAccountRuntimeLease implements AccountRuntimeLease {
  const _NoopAccountRuntimeLease();

  @override
  Future<void> close() async {}
}
