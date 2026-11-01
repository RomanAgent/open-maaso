import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/agent_production_metrics_service.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
    final mode = appServices.put(MaasoAgentModeService());
    mode.pipelineMode.value = AgentPipelineMode.directCloud;
  });

  tearDown(appServices.reset);

  test('ensure records one created and one reused runtime', () async {
    appServices.put<LLMProxyService>(_TestLlmProxyService());
    final metrics = appServices.put(AgentProductionMetricsService());
    final registry = appServices.put(AgentRuntimeRegistry());

    final created = await registry.ensure(_profile());
    final reused = await registry.ensure(_profile(nickname: 'Updated'));

    expect(identical(created, reused), isTrue);
    final snapshot = metrics.snapshot();
    expect(snapshot.runtimeEnsure.count, 2);
    expect(
      snapshot.runtimeEnsureOutcomeCounts[AgentRuntimeEnsureOutcome.created],
      1,
    );
    expect(
      snapshot.runtimeEnsureOutcomeCounts[AgentRuntimeEnsureOutcome.reused],
      1,
    );
    expect(
      snapshot.runtimeEnsureOutcomeCounts[AgentRuntimeEnsureOutcome.error],
      0,
    );
  });

  test('ensure records an error before rethrowing', () async {
    appServices.put<LLMProxyService>(_ThrowingLlmProxyService());
    final metrics = appServices.put(AgentProductionMetricsService());
    final registry = appServices.put(AgentRuntimeRegistry());

    await expectLater(registry.ensure(_profile()), throwsStateError);

    final snapshot = metrics.snapshot();
    expect(snapshot.runtimeEnsure.count, 1);
    expect(
      snapshot.runtimeEnsureOutcomeCounts[AgentRuntimeEnsureOutcome.error],
      1,
    );
  });
}

AgentProfile _profile({String nickname = 'Hiyori'}) => AgentProfile(
  nickname: nickname,
  avatar: '',
  bio: 'test agent',
  personalityTraits: const <String>['warm'],
  catchphrase: 'ok',
);

class _TestLlmProxyService extends LLMProxyService {
  final LLMClient _client = _TestLlm();

  @override
  Future<LLMClient?> ensureClient() async => _client;
}

class _ThrowingLlmProxyService extends LLMProxyService {
  @override
  Future<LLMClient?> ensureClient() async => throw StateError('probe_failed');
}

class _TestLlm implements LLMClient {
  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      '{"reply":"ok","actions":[]}';

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) => throw UnsupportedError('not used');

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';

  @override
  Stream<String> streamChat(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield await chat(messages, timeout: timeout);
  }

  @override
  Stream<LLMStreamEvent> streamChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    yield const LLMStreamEvent(event: 'reply.delta', data: '{"delta":"ok"}');
  }
}

class _MemorySecureStorageService extends SecureStorageService {
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
