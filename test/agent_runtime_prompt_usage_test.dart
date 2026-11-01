import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/metered_llm_http_client.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/skill_usage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skill_routing/prompt_skill_snapshot.dart';
import 'package:maaso/src/features/agent/application/skill_routing/skill_descriptor.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<SkillSpec> catalog;
  var serial = 0;
  final entry = PromptSkillEntry(
    source: PromptSkillSource.marketplace,
    descriptor: SkillDescriptor(
      id: 'marketplace:alpha-ritual',
      summary: 'Use the alpha ritual helper.',
      terms: const ['alpha ritual'],
      positiveExamples: const ['please use alpha ritual'],
      promptCost: 120,
    ),
    promptFragment: 'PRIVATE_ALPHA_PROMPT_FRAGMENT',
    contentRevision: 'one',
  );
  final snapshot = PromptSkillSnapshot.fromEntries([entry]);

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    appServices.put(SecureStorageService());
    appServices.put(AgentTaskJobStore());
    appServices.put(MaasoAgentModeService()).pipelineMode.value =
        AgentPipelineMode.directCloud;
    catalog = List<SkillSpec>.from(SkillCatalog.all);
    SkillCatalog.all.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });
  tearDown(() async {
    SkillCatalog.all.addAll(catalog);
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  Future<SkillUsageService> usage(String owner, {bool replace = false}) async {
    final database = await databaseFactoryMemory.openDatabase(
      'runtime-prompt-${++serial}',
    );
    final service = await SkillUsageService(
      database: database,
      accountScopeDigest: AccountStorageScope(
        environmentKey: 'test',
        accountUuid: owner,
      ).accountDigest,
      isCurrent: () => true,
    ).init(observeLifecycle: false);
    addTearDown(() async {
      await service.shutdown();
      await database.close();
    });
    return appServices.put<SkillUsageService>(
      service,
      overrideAbstract: replace,
    );
  }

  Future<AgentRuntime> runtime(_HttpLlm llm) async {
    final result = AgentRuntime(
      agentId: 'self',
      profile: AgentProfile(
        nickname: 'Maaso',
        avatar: '',
        bio: 'test',
        personalityTraits: const ['warm'],
        catchphrase: 'ok',
      ),
      llmClient: llm,
    );
    addTearDown(result.dispose);
    await result.reloadPromptSkillSnapshot(snapshot);
    return result;
  }

  test(
    'the first uninitialized natural turn counts selected dispatched prompt only',
    () async {
      final service = await usage('owner-a');
      final llm = _HttpLlm();
      addTearDown(llm.close);
      final agent = await runtime(llm);
      final result = await agent.chat('please use alpha ritual', const []);
      expect(result.isSuccess, isTrue);
      await service.whenSettled;
      expect(
        llm.dispatchedSystemTexts.join('\n'),
        contains(entry.promptFragment),
      );
      expect(
        service.forSkill(promptSkillUsageKey(entry.descriptor.id)!).started,
        1,
      );
      expect(identical(agent.skillManager.pinnedUsageService, service), isTrue);
      await agent.chat('hello there', const []);
      await service.whenSettled;
      expect(
        service.forSkill(promptSkillUsageKey(entry.descriptor.id)!).started,
        1,
      );
    },
  );

  test(
    'an old uninitialized runtime cannot borrow replacement account usage',
    () async {
      final old = await usage('owner-a');
      final llm = _HttpLlm();
      addTearDown(llm.close);
      final oldRuntime = await runtime(llm);
      old.retire();
      final next = await usage('owner-b', replace: true);
      await oldRuntime.chat('please use alpha ritual', const []);
      await next.whenSettled;
      expect(next.entries.value, isEmpty);
      expect(
        identical(oldRuntime.skillManager.pinnedUsageService, old),
        isTrue,
      );
      final current = await runtime(llm);
      await current.chat('please use alpha ritual', const []);
      await next.whenSettled;
      expect(
        next.forSkill(promptSkillUsageKey(entry.descriptor.id)!).started,
        1,
      );
    },
  );

  test(
    'autonomous follow-up is not a natural human prompt application',
    () async {
      final service = await usage('owner-a');
      final llm = _HttpLlm();
      addTearDown(llm.close);
      final agent = await runtime(llm);
      await agent.chat(
        'please use alpha ritual',
        const [],
        origin: TurnOrigin.followUp,
      );
      await service.whenSettled;
      expect(service.entries.value, isEmpty);
    },
  );
  test(
    'a runtime created without usage cannot bind a later account service',
    () async {
      final llm = _HttpLlm();
      addTearDown(llm.close);
      final oldRuntime = await runtime(llm);
      final next = await usage('new-owner');
      await oldRuntime.chat('please use alpha ritual', const []);
      await next.whenSettled;
      expect(next.entries.value, isEmpty);
      expect(oldRuntime.skillManager.pinnedUsageService, isNull);
    },
  );
}

final class _HttpLlm extends LLMClient {
  _HttpLlm() {
    client = MeteredLlmHttpClient(
      inner: MockClient((request) async {
        final payload = jsonDecode(request.body) as Map;
        for (final message in payload['messages'] as List) {
          if (message['role'] == 'system') {
            dispatchedSystemTexts.add(message['content'] as String);
          }
        }
        return http.Response('{"reply":"ok","actions":[]}', 200);
      }),
      record:
          ({
            required requestId,
            required dispatchedAt,
            required usage,
          }) async {},
    );
  }
  late final http.Client client;
  final List<String> dispatchedSystemTexts = [];
  @override
  Duration get defaultTimeout => const Duration(seconds: 2);
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async =>
      (await client.post(
        Uri.parse('https://model.example/chat'),
        body: jsonEncode({
          'messages': messages.map((m) => m.toJson()).toList(),
        }),
      )).body;
  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
  void close() => client.close();
}
