import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_profile.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/maaso_thin_proxy_llm_client.dart';
import 'package:maaso/src/core/services/short_term_memory.dart';
import 'package:maaso/src/features/agent/application/action/agent_action_executor.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/persona/persona_chat_loop.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'HTTP categories only trust allowlisted codes and never retain prose',
    () {
      for (final entry in <(int, String, HostedLLMFailureKind)>[
        (429, 'MEMBERSHIP_QUOTA_EXHAUSTED', HostedLLMFailureKind.quota),
        (429, 'OTHER_RATE_LIMIT', HostedLLMFailureKind.rateLimited),
        (401, 'UNAUTHORIZED', HostedLLMFailureKind.authentication),
        (400, 'MODEL_CONTEXT_LIMIT', HostedLLMFailureKind.contextLimit),
        (403, 'PRIVACY_CONSENT_REQUIRED', HostedLLMFailureKind.consent),
        (503, 'MEMBERSHIP_QUOTA_EXHAUSTED', HostedLLMFailureKind.unavailable),
        (503, 'unexpected-private-code', HostedLLMFailureKind.unavailable),
      ]) {
        final error = HostedLLMFailure.fromHttp(
          entry.$1,
          jsonEncode({
            'code': entry.$2,
            'message': 'private provider details and credentials',
          }),
        );
        expect(error.kind, entry.$3);
        expect(error.toString(), isNot(contains('private')));
        expect(error.userMessage(AppLocale.zh), isNot(contains('private')));
        expect(error.userMessage(AppLocale.en), isNot(contains('private')));
        expect(
          HostedLLMFailure.fromRuntimeReason(error.runtimeReason)?.kind,
          entry.$3,
        );
      }
      expect(HostedLLMFailure.fromRuntimeReason('server says quota'), isNull);
    },
  );

  test(
    'real HTTP quota rejection exits persona without structured fallback',
    () async {
      var requests = 0;
      final client = _quotaClient(() => requests++);
      final loop = PersonaChatLoop(
        agentId: 'self',
        llmClient: client,
        profileProvider: _profile,
        localeProvider: () => AppLocale.zh,
        openSpeechSession: () async => null,
        fallbackSpeak: (_) => fail('Rejected model output must not be spoken'),
      );
      final result = await loop.run(
        userText: '你好',
        turnPlan: const AgentTurnPlan(
          route: AgentTurnRoute.chitchat,
          mood: 'attentive',
          confidence: 1,
        ),
      );
      await loop.drained;
      expect(
        result,
        isNotNull,
        reason: 'null requests a second model dispatch',
      );
      expect(result!.isSuccess, isFalse);
      final error = HostedLLMFailure.fromRuntimeReason(result.stderr)!;
      expect(error.kind, HostedLLMFailureKind.quota);
      expect(error.userMessage(AppLocale.zh), contains('额度已用完'));
      expect(
        error.userMessage(AppLocale.en),
        contains('allowance is exhausted'),
      );
      expect(requests, 1);
    },
  );

  test(
    'structured runtime preserves HTTP admission failure without executing actions',
    () async {
      var requests = 0;
      var executed = false;
      final result = await debugStructuredActionProcess(
        llmClient: _quotaClient(() => requests++),
        profile: _profile(),
        instruction: 'synthetic task',
        systemPrompt: 'Return one JSON envelope.',
        executor: AgentActionExecutor(
          agentId: 'self',
          skillManager: SkillManager(),
          locale: AppLocale.en,
        ),
        locale: AppLocale.en,
        beforeExecute: (_) async {
          executed = true;
          return true;
        },
      );
      expect(result.isSuccess, isFalse);
      expect(
        HostedLLMFailure.fromRuntimeReason(result.stderr)?.kind,
        HostedLLMFailureKind.quota,
      );
      expect(executed, isFalse);
      expect(requests, 1);
    },
  );

  test(
    'natural conversation preserves quota failure and publishes no fake reply',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('flutter_tts'),
            (call) async => switch (call.method) {
              'getLanguages' => <String>['zh-CN'],
              'getVoices' => <Object>[],
              _ => 1,
            },
          );
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(const MethodChannel('flutter_tts'), null),
      );
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'hosted-quota',
      );
      addTearDown(database.close);
      appServices.put(AgentTaskJobStore());
      appServices.put(ShortTermMemory());
      var requests = 0;
      final runtime = AgentRuntime(
        agentId: 'self',
        profile: _profile(),
        llmClient: _quotaClient(() => requests++),
        conversationDeliveryMode: ConversationDeliveryMode.text,
        prepareTtsForNewTurn: (_) async {},
      );
      await runtime.init(enabledSkillIds: const {});
      addTearDown(runtime.retireAndDrain);
      final result = await runtime
          .submitConversation('你好', database: database)
          .done;
      expect(result.execution.isSuccess, isFalse);
      expect(
        HostedLLMFailure.fromRuntimeReason(result.execution.stderr)?.kind,
        HostedLLMFailureKind.quota,
      );
      expect(result.publishedMessages, isEmpty);
      expect(
        (await database.getMessages('self')).where((m) => !m.isUserMessage),
        isEmpty,
      );
      expect(requests, 1);
    },
  );

  test(
    'in-stream provider failure is sanitized for direct chat callers',
    () async {
      final client = MaasoThinProxyLLMClient(
        baseUri: Uri.parse('https://api.example.test'),
        model: 'synthetic',
        accessTokenProvider: () async => 'synthetic-token',
        httpClient: MockClient(
          (_) async => http.Response(
            'event: error\ndata: "private upstream credential error"\n\n',
            200,
          ),
        ),
      );
      await expectLater(
        client.chat([Message.user('hello')]),
        throwsA(
          isA<HostedLLMFailure>().having(
            (e) => e.kind,
            'kind',
            HostedLLMFailureKind.unavailable,
          ),
        ),
      );
    },
  );
}

MaasoThinProxyLLMClient _quotaClient(
  void Function() onRequest,
) => MaasoThinProxyLLMClient(
  baseUri: Uri.parse('https://api.example.test'),
  model: 'doubao-seed-evolving',
  accessTokenProvider: () async => 'synthetic-token',
  httpClient: MockClient((_) async {
    onRequest();
    return http.Response(
      '{"code":"MEMBERSHIP_QUOTA_EXHAUSTED","message":"private server details"}',
      429,
    );
  }),
);

AgentProfile _profile() => AgentProfile(
  nickname: 'Tina',
  avatar: '',
  bio: 'test',
  personalityTraits: const ['warm'],
  catchphrase: 'ok',
);
