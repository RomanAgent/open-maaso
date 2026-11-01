import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/llamadart_llm_backend.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/persona_chat_loop.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_tts'),
          (_) async => 1,
        );
  });

  tearDown(() async {
    await appServices.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null);
  });

  for (final locale in [AppLocale.zh, AppLocale.en]) {
    final userText = locale == AppLocale.zh
        ? '你现在是什么模型'
        : 'What model are you using?';

    group(locale.name, () {
      for (final isPrivate in [false, true]) {
        test('persona keeps the configured name in $isPrivate chat', () {
          for (final name in ['林夏', 'Renamed Mira']) {
            final messages = PersonaChatLoop.buildMessages(
              userText: userText,
              currentUserText: userText,
              turnPlan: const AgentTurnPlan(
                route: AgentTurnRoute.chitchat,
                mood: 'attentive',
                confidence: 0.8,
              ),
              profile: _profile(name),
              locale: locale,
              conversationStyle: ConversationStyleSnapshot(
                isPrivate: isPrivate,
              ),
            );

            _expectNamedIdentity(messages.first.content, locale, name);
            expect(
              messages.first.content,
              anyOf(contains('plain text'), contains('纯文本')),
            );
            expect(messages.first.content, contains('<body_intent>'));
            expect(messages.last.content, userText);
          }
        });
      }

      test('local fallback keeps the supplied name and emotion protocol', () {
        final prompt = LlamadartLLMBackend.buildChatSystemPromptForTest(
          agentName: '  林夏  ',
          locale: locale,
        );

        _expectNamedIdentity(prompt, locale, '林夏');
        expect(prompt, contains('neutral, calm, happy, sad, angry'));
        expect(
          prompt,
          contains(locale == AppLocale.zh ? '[happy] 嗨' : '[happy]'),
        );
      });

      test('missing name asks naturally without assigning a new name', () {
        final localPrompt = LlamadartLLMBackend.buildChatSystemPromptForTest(
          agentName: ' ',
          locale: locale,
        );
        expect(
          localPrompt,
          contains(locale == AppLocale.zh ? '尚未命名' : 'not yet named'),
        );
        expect(
          localPrompt,
          contains(
            locale == AppLocale.zh ? '不自行另起名字' : 'instead of inventing one',
          ),
        );
        final personaMessages = PersonaChatLoop.buildMessages(
          userText: userText,
          turnPlan: const AgentTurnPlan(
            route: AgentTurnRoute.chitchat,
            mood: 'attentive',
            confidence: 0.8,
          ),
          profile: _profile(''),
          locale: locale,
        );
        expect(
          personaMessages.first.content,
          contains(
            locale == AppLocale.zh ? '不自行另起名字' : 'instead of inventing one',
          ),
        );
      });

      test(
        'structured cloud request retains name, honesty and JSON protocol',
        () async {
          appServices.put(SecureStorageService());
          appServices.put(AgentTaskJobStore());
          appServices.put(MaasoAgentModeService()).pipelineMode.value =
              AgentPipelineMode.directCloud;
          final llm = _IdentityRecordingLlm();
          final runtime = AgentRuntime(
            agentId: 'self',
            profile: _profile('林夏'),
            llmClient: llm,
          );
          addTearDown(runtime.dispose);
          await runtime.init(enabledSkillIds: const <String>{});

          final result = await AgentPromptCatalog.runWithLocale(
            locale,
            () => runtime.chat(userText, const <Message>[]),
          );

          expect(result.isSuccess, isTrue);
          final prompt = llm.messages
              .where((message) => message.role == 'system')
              .map((message) => message.content)
              .join('\n');
          _expectNamedIdentity(prompt, locale, '林夏');
          expect(prompt, contains('"reply"'));
          expect(prompt, contains('"actions"'));
        },
      );
    });
  }
}

void _expectNamedIdentity(String prompt, AppLocale locale, String name) {
  expect(prompt, contains(name));
  expect(prompt, contains(locale == AppLocale.zh ? '第一人称' : 'first person'));
  expect(
    prompt,
    contains(locale == AppLocale.zh ? '日常自我介绍' : 'everyday introduction'),
  );
  expect(
    prompt,
    contains(locale == AppLocale.zh ? '不知道具体模型就说不知道' : 'model name is unknown'),
  );
  expect(
    prompt,
    contains(locale == AppLocale.zh ? '不猜型号' : 'without guessing'),
  );
  expect(
    prompt,
    contains(
      locale == AppLocale.zh ? '不编造现实中的身体' : 'Do not invent a real-world',
    ),
  );
  for (final oldIdentity in [
    '你是应用中的数字角色',
    '生活在这个应用里的数字角色',
    '生活在这个应用里的数字朋友',
    'You are a digital character',
    'a digital character in this app',
    'a digital friend living in this app',
  ]) {
    expect(prompt, isNot(contains(oldIdentity)));
  }
}

AgentProfile _profile(String name) => AgentProfile(
  nickname: name,
  avatar: '',
  bio: '',
  personalityTraits: const <String>['warm', 'curious'],
  catchphrase: '',
);

final class _IdentityRecordingLlm extends LLMClient {
  List<Message> messages = const <Message>[];

  @override
  Duration get defaultTimeout => const Duration(seconds: 1);

  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    this.messages = List<Message>.of(messages);
    return '{"reply":"林夏","actions":[]}';
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async => '{}';
}
