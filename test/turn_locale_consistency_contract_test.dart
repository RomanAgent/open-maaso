import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_model_action_planner.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

class _MemorySecureStorageService extends SecureStorageService {
  @override
  Future<String?> read(String key) async => null;
}

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    appServices.put<SecureStorageService>(_MemorySecureStorageService());
  });

  tearDown(appServices.reset);

  test('Home injects one captured locale into the local action planner', () {
    final source = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains('final turnLocale = AgentPromptCatalog.currentLocale;'),
    );
    expect(
      source,
      contains('Future<void> runPureChat() => _sendPureChatOnly('),
    );
    expect(source, contains('locale: turnLocale,'));
    expect(source, contains('required AppLocale locale'));
    expect(source, contains('localeProvider: () => locale'));
  });

  test(
    'local planner keeps fallback language across an async completion',
    () async {
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      final planner = LocalModelActionPlanner(
        complete: (_) async {
          locale.locale.value = AppLocale.en;
          return 'not-json';
        },
      );

      final action = await planner.next(
        const LocalAgentTurn(
          userText: '继续',
          step: 1,
          candidates: [],
          observations: [],
        ),
      );

      expect(action.type, LocalAgentActionType.ask);
      expect(action.question, '我需要再确认一下。');
    },
  );

  test(
    'local planner keeps the captured locale across multiple steps',
    () async {
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      final turnLocale = AgentPromptCatalog.currentLocale;
      final prompts = <String>[];
      final planner = LocalModelActionPlanner(
        localeProvider: () => turnLocale,
        complete: (messages) async {
          prompts.add(messages.first.content);
          return '{"type":"finish","text":"ok"}';
        },
      );

      await planner.next(
        const LocalAgentTurn(
          userText: '继续',
          step: 1,
          candidates: [],
          observations: [],
        ),
      );
      locale.locale.value = AppLocale.en;
      await planner.next(
        const LocalAgentTurn(
          userText: 'continue',
          step: 2,
          candidates: [],
          observations: [],
        ),
      );

      expect(prompts, hasLength(2));
      expect(prompts.every((prompt) => prompt.contains('手机本地任务智能体')), isTrue);
      expect(
        prompts.every((prompt) => !prompt.contains('You are a phone-local')),
        isTrue,
      );
    },
  );

  test(
    'system locale is resolved before entering an async locale Zone',
    () async {
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;

      final resolved = await AgentPromptCatalog.runWithLocale(
        AppLocale.system,
        () async {
          await Future<void>.delayed(Duration.zero);
          locale.locale.value = AppLocale.en;
          return AgentPromptCatalog.currentLocale;
        },
      );

      expect(resolved, AppLocale.zh);
    },
  );

  test(
    'local runtime keeps handler results in the captured turn locale',
    () async {
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      final manager = SkillManager()..registerSkill(_LocalizedTestSkill());
      final runtime = LocalAgentRuntime(
        skillManager: manager,
        manifests: const <LocalSkillManifest>[
          LocalSkillManifest(
            id: 'localized_test',
            skillName: 'LocalizedTest',
            method: 'run',
            summary: 'test',
            tags: <String>['test'],
            argsSchema: <String, dynamic>{'type': 'object'},
          ),
        ],
        planner: _SwitchingCallPlanner(locale),
      );

      final result = await runtime.run(
        '测试',
        preferredSkillIds: const <String>['localized_test'],
        locale: AppLocale.zh,
      );
      final output = result.observations.single.output;

      expect(output, contains('只要数值答案很重要'));
      expect(output, isNot(contains('Evaluate a math expression')));
      expect(locale.locale.value, AppLocale.en);
    },
  );

  test(
    'direct chat keeps its system and error locale after an await',
    () async {
      final locale = appServices.put(LocaleConfigService());
      locale.locale.value = AppLocale.zh;
      final client = _RecordingLlmClient();
      final proxy = _SwitchingLlmProxyService(
        client: client,
        switchLocale: () => locale.locale.value = AppLocale.en,
      );

      final reply = await proxy.chat('你好', locale: AppLocale.zh);

      expect(reply, 'ok');
      expect(client.messages.single.first.content, contains('可靠的助手'));
      expect(client.messages.single.first.content, isNot(contains('reliable')));

      client.error = StateError('secret provider detail');
      final error = await proxy.chat('再试一次', locale: AppLocale.zh);
      expect(error, '刚才没有连接上模型，请稍后再试。');
      expect(error, isNot(contains('secret provider detail')));
    },
  );
}

class _SwitchingLlmProxyService extends LLMProxyService {
  _SwitchingLlmProxyService({required this.client, required this.switchLocale});

  final LLMClient client;
  final void Function() switchLocale;

  @override
  Future<LLMClient?> ensureClient() async {
    await Future<void>.delayed(Duration.zero);
    switchLocale();
    return client;
  }
}

class _RecordingLlmClient extends LLMClient {
  final List<List<Message>> messages = <List<Message>>[];
  Object? error;

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    this.messages.add(List<Message>.from(messages));
    final currentError = error;
    if (currentError != null) throw currentError;
    return 'ok';
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
}

class _SwitchingCallPlanner implements LocalAgentPlanner {
  _SwitchingCallPlanner(this.locale);

  final LocaleConfigService locale;

  @override
  Future<LocalAgentAction> next(LocalAgentTurn turn) async {
    if (turn.step == 1) {
      locale.locale.value = AppLocale.en;
      return LocalAgentAction.call('localized_test', const <String, dynamic>{});
    }
    return LocalAgentAction.finish('done');
  }
}

class _LocalizedTestSkill extends AgentSkill {
  @override
  String get skillName => 'LocalizedTest';

  @override
  String get description => 'test';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods =>
      <String, dynamic Function(List<dynamic>)>{
        'run': (_) async {
          await Future<void>.delayed(Duration.zero);
          return jsonEncode(<String, Object?>{
            'message': AgentPromptCatalog.text('skill.Calc.description'),
          });
        },
      };
}
