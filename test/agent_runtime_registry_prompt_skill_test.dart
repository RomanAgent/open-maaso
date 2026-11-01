import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/learned_skill_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_catalog_service.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues(const <String, Object>{});
  });

  tearDown(appServices.reset);

  test(
    'ensure skips installed loader then hot snapshot affects the next turn',
    () async {
      final cards = Completer<List<InstalledSkillCard>>();
      var loadCalls = 0;
      appServices.put<SecureStorageService>(_MemorySecureStorageService());
      appServices.put(AgentTaskJobStore());
      final mode = appServices.put(MaasoAgentModeService());
      await mode.setPipelineMode(AgentPipelineMode.directCloud);
      final llm = _RecordingLlm();
      appServices.put<LLMProxyService>(_RecordingLlmProxyService(llm));
      final learned = appServices.put(LearnedSkillService());
      final catalog = appServices.put(
        PromptSkillCatalogService(
          learnedSkills: learned,
          loadInstalled: (_) {
            loadCalls++;
            return cards.future;
          },
        ),
      );
      final registry = appServices.put(AgentRuntimeRegistry());

      final runtime = await registry
          .ensure(
            AgentProfile(
              nickname: 'Hiyori',
              avatar: '',
              bio: 'test agent',
              personalityTraits: const <String>['warm'],
              catchphrase: 'ok',
            ),
          )
          .timeout(const Duration(seconds: 2));

      expect(runtime.agentId, 'self');
      expect(loadCalls, 0);
      expect(cards.isCompleted, isFalse);

      await _waitFor(() => loadCalls == 1);
      cards.complete(<InstalledSkillCard>[
        _card(marker: 'HOT_SWAP_ALPHA_INSTRUCTION'),
      ]);
      await _waitFor(() => catalog.snapshotForAgent('self').entries.isNotEmpty);

      final result = await runtime.chat('please use alpha ritual', const []);

      expect(result.isSuccess, isTrue);
      expect(
        llm.calls
            .expand((call) => call)
            .where((message) => message.role == 'system'),
        contains(
          predicate<Message>(
            (message) => message.content.contains('HOT_SWAP_ALPHA_INSTRUCTION'),
          ),
        ),
      );
    },
  );
}

Future<void> _waitFor(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 2));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition timed out');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

InstalledSkillCard _card({required String marker}) => InstalledSkillCard(
  agentId: 'self',
  mastery: MasteryBucket.newSkill,
  skill: MarketplaceSkill(
    skillVersionId: 1,
    submissionId: 1,
    skillKey: 'alpha-ritual',
    title: 'Alpha ritual',
    summary: 'Use the alpha ritual helper.',
    coverAssetUrl: '',
    publisherId: 'author',
    versionName: '1.0.0',
    permissions: const <String>{},
    category: SkillCategory.reasoning,
    instruction: marker,
    examples: const <String>['please use alpha ritual'],
    manifestDigest: 'digest',
    isFree: true,
  ),
);

class _RecordingLlmProxyService extends LLMProxyService {
  _RecordingLlmProxyService(this.client);

  final LLMClient client;

  @override
  Future<LLMClient?> ensureClient() async => client;
}

class _RecordingLlm implements LLMClient {
  final List<List<Message>> calls = <List<Message>>[];

  @override
  Duration get defaultTimeout => const Duration(seconds: 2);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    calls.add(List<Message>.unmodifiable(messages));
    return '{"reply":"Done.","actions":[{"type":"creation.intent","mode":"none"}]}';
  }

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
    yield LLMStreamEvent(
      event: 'reply.delta',
      data: jsonEncode(<String, Object?>{
        'delta': await chat(messages, timeout: timeout),
      }),
    );
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
