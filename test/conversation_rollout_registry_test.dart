import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_delivery_rollout_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DBService database;
  late _ControlledLlm llm;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    final mode = appServices.put(MaasoAgentModeService());
    mode.pipelineMode.value = AgentPipelineMode.proxyDefault;
    appServices.put(AgentTaskJobStore());
    appServices.put(ShortTermMemory());
    database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'conversation-rollout-registry.db',
    );
    llm = _ControlledLlm();
    appServices.put<LLMProxyService>(_ControlledLlmProxyService(llm));
  });

  tearDown(() async {
    llm.close();
    await appServices.reset();
    await database.close();
    await databaseFactoryMemory.deleteDatabase(
      'conversation-rollout-registry.db',
    );
  });

  test(
    'assignment expiry cancels the active natural-conversation turn',
    () async {
      var now = DateTime.utc(2026, 9, 4, 8);
      final flags = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.naturalConversation: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      ).init();
      appServices.put<MaasoFeatureFlagService>(flags);
      await flags.assign(
        flag: MaasoFeatureFlag.naturalConversation,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      final timers = _ManualTimerFactory();
      final rollout = appServices.put(
        ConversationDeliveryRolloutService(
          featureFlags: flags,
          compileMaximum: ConversationDeliveryMode.text,
          enabledPlatforms: const <AppHostPlatform>{AppHostPlatform.macos},
          platformCapabilities: const AppPlatformCapabilities.forPlatform(
            AppHostPlatform.macos,
          ),
          clock: () => now,
          timerFactory: timers.create,
        ),
      );
      final registry = appServices.put(
        AgentRuntimeRegistry(conversationRollout: rollout),
      );
      final runtime = await registry.ensure(_profile());
      expect(runtime.usesConversationTurns, isTrue);

      final handle = runtime.submitConversation('你觉得这样对吗', database: database);
      await _waitUntil(() => llm.calls == 1);

      now = now.add(const Duration(minutes: 5));
      timers.active.fire();

      final result = await handle.done.timeout(const Duration(seconds: 2));
      expect(result.cancelled, isTrue);
      expect(runtime.usesConversationTurns, isFalse);
      expect(
        (await database.getMessages('self')).map((message) => message.content),
        <String>['你觉得这样对吗'],
      );
      expect(
        () => runtime.submitConversation('再说一句', database: database),
        throwsStateError,
      );
    },
  );

  test('closing rollout cancels an active natural-conversation turn', () async {
    final now = DateTime.utc(2026, 9, 4, 8);
    final flags = await MaasoFeatureFlagService(
      store: _MemoryFeatureFlagStore(),
      compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
        MaasoFeatureFlag.naturalConversation: FeatureRolloutMode.enforce,
      },
      clock: () => now,
    ).init();
    appServices.put<MaasoFeatureFlagService>(flags);
    final rollout = appServices.put(
      ConversationDeliveryRolloutService(
        featureFlags: flags,
        compileMaximum: ConversationDeliveryMode.text,
        enabledPlatforms: const <AppHostPlatform>{AppHostPlatform.macos},
        platformCapabilities: const AppPlatformCapabilities.forPlatform(
          AppHostPlatform.macos,
        ),
        clock: () => now,
      ),
    );
    final registry = appServices.put(
      AgentRuntimeRegistry(conversationRollout: rollout),
    );
    final runtime = await registry.ensure(_profile());

    final handle = runtime.submitConversation('先等等', database: database);
    await _waitUntil(() => llm.calls == 1);
    rollout.closeLifecycle();

    final result = await handle.done.timeout(const Duration(seconds: 2));
    expect(result.cancelled, isTrue);
    expect(runtime.usesConversationTurns, isFalse);
  });

  test(
    'a newer enforce revision revokes a turn admitted by the old revision',
    () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      final flags = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.naturalConversation: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      ).init();
      appServices.put<MaasoFeatureFlagService>(flags);
      await flags.assign(
        flag: MaasoFeatureFlag.naturalConversation,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      final rollout = appServices.put(
        ConversationDeliveryRolloutService(
          featureFlags: flags,
          compileMaximum: ConversationDeliveryMode.text,
          enabledPlatforms: const <AppHostPlatform>{AppHostPlatform.macos},
          platformCapabilities: const AppPlatformCapabilities.forPlatform(
            AppHostPlatform.macos,
          ),
          clock: () => now,
        ),
      );
      final registry = appServices.put(
        AgentRuntimeRegistry(conversationRollout: rollout),
      );
      final runtime = await registry.ensure(_profile());
      final handle = runtime.submitConversation('旧授权里的问题', database: database);
      await _waitUntil(() => llm.calls == 1);

      await flags.assign(
        flag: MaasoFeatureFlag.naturalConversation,
        mode: FeatureRolloutMode.enforce,
        revision: 2,
        expiresAt: now.add(const Duration(minutes: 10)),
      );

      final result = await handle.done.timeout(const Duration(seconds: 2));
      expect(result.cancelled, isTrue);
      expect(runtime.usesConversationTurns, isTrue);
      expect(
        (await database.getMessages('self')).map((message) => message.content),
        <String>['旧授权里的问题'],
      );
    },
  );

  test(
    'an unrelated feature assignment does not revoke the active turn',
    () async {
      final now = DateTime.utc(2026, 9, 4, 8);
      final flags = await MaasoFeatureFlagService(
        store: _MemoryFeatureFlagStore(),
        compileMaximums: const <MaasoFeatureFlag, FeatureRolloutMode>{
          MaasoFeatureFlag.naturalConversation: FeatureRolloutMode.enforce,
          MaasoFeatureFlag.voiceProsody: FeatureRolloutMode.enforce,
        },
        clock: () => now,
      ).init();
      appServices.put<MaasoFeatureFlagService>(flags);
      await flags.assign(
        flag: MaasoFeatureFlag.naturalConversation,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      final rollout = appServices.put(
        ConversationDeliveryRolloutService(
          featureFlags: flags,
          compileMaximum: ConversationDeliveryMode.text,
          enabledPlatforms: const <AppHostPlatform>{AppHostPlatform.macos},
          platformCapabilities: const AppPlatformCapabilities.forPlatform(
            AppHostPlatform.macos,
          ),
          clock: () => now,
        ),
      );
      final registry = appServices.put(
        AgentRuntimeRegistry(conversationRollout: rollout),
      );
      final runtime = await registry.ensure(_profile());
      final handle = runtime.submitConversation(
        '不要被无关开关打断',
        database: database,
      );
      await _waitUntil(() => llm.calls == 1);

      await flags.assign(
        flag: MaasoFeatureFlag.voiceProsody,
        mode: FeatureRolloutMode.enforce,
        revision: 1,
        expiresAt: now.add(const Duration(minutes: 5)),
      );
      await Future<void>.delayed(Duration.zero);

      expect(handle.isCancelled, isFalse);
      await handle.cancel();
      expect((await handle.done).cancelled, isTrue);
    },
  );
}

AgentProfile _profile() => AgentProfile(
  nickname: 'Tina',
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

Future<void> _waitUntil(bool Function() predicate) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!predicate()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('runtime condition');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

final class _ControlledLlmProxyService extends LLMProxyService {
  _ControlledLlmProxyService(this.client);

  final _ControlledLlm client;

  @override
  Future<LLMClient?> ensureClient() async => client;
}

final class _ControlledLlm implements LLMClient {
  final List<StreamController<LLMStreamEvent>> _streams =
      <StreamController<LLMStreamEvent>>[];
  int calls = 0;

  @override
  Duration get defaultTimeout => const Duration(seconds: 15);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected aggregate call');

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw StateError('unexpected tool call');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) =>
      throw StateError('unexpected route call');

  @override
  Stream<String> streamChat(List<Message> messages, {Duration? timeout}) =>
      throw StateError('unexpected text stream');

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) {
    calls++;
    final stream = StreamController<LLMStreamEvent>();
    _streams.add(stream);
    return stream.stream;
  }

  void close() {
    for (final stream in _streams) {
      if (!stream.isClosed) unawaited(stream.close());
    }
  }
}

final class _MemorySecureStorageService extends SecureStorageService {
  final Map<String, String> _values = <String, String>{};

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
  Future<String?> read(String key) async => _values[key];

  @override
  Future<bool> delete(String key) async => _values.remove(key) != null;
}

final class _MemoryFeatureFlagStore implements MaasoFeatureFlagAssignmentStore {
  final Map<String, Map<String, Object?>> _rows =
      <String, Map<String, Object?>>{};

  @override
  Future<List<Map<String, Object?>>> readAll() async =>
      _rows.values.map(Map<String, Object?>.from).toList(growable: false);

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
