import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

import 'privacy_service_test.dart' show PrivacyFake;

void main() {
  late _MemoryStorage storage;
  late PrivacyFake privacyGateway;
  late LLMProxyService proxy;
  late MaasoAgentModeService mode;
  final messages = [
    Message.system('Return a JSON game.'),
    Message.user('A game'),
  ];

  const initial = LLMDirectCloudConfig(
    apiKey: 'synthetic-private-key-a',
    baseUrl: 'https://provider-a.example.test/v1',
    model: 'synthetic-model-a',
    enabled: true,
  );
  const changed = LLMDirectCloudConfig(
    apiKey: 'synthetic-private-key-b',
    baseUrl: 'https://provider-b.example.test/v1',
    model: 'synthetic-model-b',
    enabled: true,
  );

  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
    storage = _MemoryStorage();
    appServices.put<SecureStorageService>(storage);
    mode = appServices.put(MaasoAgentModeService());
    await mode.setPipelineMode(AgentPipelineMode.directCloud);
    await storage.write(LLMDirectCloudConfig.storageKey, initial.encode());
    privacyGateway = PrivacyFake()
      ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
    appServices.put(PrivacyService(gateway: privacyGateway));
    proxy = LLMProxyService();
  });

  tearDown(() async {
    await proxy.deactivateAccountAndDrain();
    await appServices.reset();
  });

  final interrupted = throwsA(
    isA<LLMResponseIntegrityException>().having(
      (error) => error.runtimeReason,
      'fixed diagnostic',
      'generated_task_failure:interrupted',
    ),
  );
  http.Response result() => http.Response(
    jsonEncode({
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {'content': '{"js":"restart()"}'},
        },
      ],
    }),
    200,
  );

  test(
    'same task retains one model and fails instead of switching for repair',
    () async {
      var sends = 0;
      await http.runWithClient(
        () async {
          final client = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          expect(client, isA<StructuredOutputLLMClient>());
          expect(client.defaultTimeout, proxy.liveClient.defaultTimeout);
          expect(client.defaultTimeout, const Duration(seconds: 90));
          expect(
            await chatJsonObjectWithPrivacyAdmission(
              client,
              messages,
              onAdmitted: () {},
            ),
            '{"js":"restart()"}',
          );
          await storage.write(
            LLMDirectCloudConfig.storageKey,
            changed.encode(),
          );
          await expectLater(
            chatJsonObjectWithPrivacyAdmission(
              client,
              messages,
              onAdmitted: () {},
            ),
            interrupted,
          );
          expect(sends, 1);

          // Unrelated ordinary conversation continues using its live config.
          expect(await proxy.liveClient.chat(messages), '{"js":"restart()"}');
          expect(sends, 2);
        },
        () => MockClient((request) async {
          sends++;
          if (sends == 1) {
            expect(request.url.host, 'provider-a.example.test');
            expect(jsonDecode(request.body)['model'], 'synthetic-model-a');
            expect(jsonDecode(request.body)['response_format'], {
              'type': 'json_object',
            });
          } else {
            expect(request.url.host, 'provider-b.example.test');
            expect(jsonDecode(request.body)['model'], 'synthetic-model-b');
            expect(
              jsonDecode(request.body),
              isNot(contains('response_format')),
            );
          }
          return result();
        }),
      );
    },
  );

  test(
    'configuration changed during response wait cannot accept an old artifact',
    () async {
      final dispatched = Completer<void>();
      final release = Completer<http.Response>();
      var sends = 0;
      await http.runWithClient(
        () async {
          final client = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          final request = chatJsonObjectWithPrivacyAdmission(
            client,
            messages,
            onAdmitted: () {},
          );
          final rejected = expectLater(request, interrupted);
          await dispatched.future;
          await storage.write(
            LLMDirectCloudConfig.storageKey,
            changed.encode(),
          );
          release.complete(result());
          await rejected;
          expect(sends, 1);
        },
        () => MockClient((request) {
          sends++;
          dispatched.complete();
          return release.future;
        }),
      );
    },
  );

  test(
    'account drain blocks the pinned client before provider dispatch',
    () async {
      var sends = 0;
      await http.runWithClient(
        () async {
          final client = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          await proxy.deactivateAccountAndDrain();
          await expectLater(
            chatJsonObjectWithPrivacyAdmission(
              client,
              messages,
              onAdmitted: () {},
            ),
            interrupted,
          );
          expect(sends, 0);
        },
        () => MockClient((_) async {
          sends++;
          return result();
        }),
      );
    },
  );

  test(
    'pinned configuration does not freeze privacy account context',
    () async {
      var sends = 0;
      await http.runWithClient(
        () async {
          final client = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          privacyGateway.requestContextKey = 'test|another-account';
          await expectLater(
            chatJsonObjectWithPrivacyAdmission(
              client,
              messages,
              onAdmitted: () {},
            ),
            throwsA(isA<PrivacyException>()),
          );
          expect(sends, 0);
        },
        () => MockClient((_) async {
          sends++;
          return result();
        }),
      );
    },
  );

  test('pipeline mode changes interrupt the pinned generation', () async {
    var sends = 0;
    await http.runWithClient(
      () async {
        final client = await resolveStructuredOutputClientForTask(
          proxy.liveClient,
        );
        await mode.setPipelineMode(AgentPipelineMode.localFull);
        await expectLater(
          chatJsonObjectWithPrivacyAdmission(
            client,
            messages,
            onAdmitted: () {},
          ),
          interrupted,
        );
        expect(sends, 0);
      },
      () => MockClient((_) async {
        sends++;
        return result();
      }),
    );
  });
}

final class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}
