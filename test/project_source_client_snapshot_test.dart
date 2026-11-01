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
  late _Storage storage;
  late PrivacyFake privacy;
  late LLMProxyService proxy;
  const first = LLMDirectCloudConfig(
    apiKey: 'synthetic-a',
    baseUrl: 'https://provider-a.example.test/v1',
    model: 'model-a',
    enabled: true,
  );
  const second = LLMDirectCloudConfig(
    apiKey: 'synthetic-b',
    baseUrl: 'https://provider-b.example.test/v1',
    model: 'model-b',
    enabled: true,
  );
  final messages = [
    Message.system('Return JSON source.'),
    Message.user('Preserve all features.'),
  ];
  final interrupted = throwsA(
    isA<LLMResponseIntegrityException>().having(
      (error) => error.runtimeReason,
      'reason',
      'generated_task_failure:interrupted',
    ),
  );
  http.Response result() => http.Response(
    jsonEncode({
      'choices': [
        {
          'finish_reason': 'stop',
          'message': {'content': '{"append":"code","done":true}'},
        },
      ],
    }),
    200,
  );

  setUp(() async {
    appServices.testMode = true;
    await appServices.reset();
    storage = _Storage();
    appServices.put<SecureStorageService>(storage);
    final mode = appServices.put(MaasoAgentModeService());
    await mode.setPipelineMode(AgentPipelineMode.directCloud);
    await storage.write(LLMDirectCloudConfig.storageKey, first.encode());
    privacy = PrivacyFake()
      ..currentPolicy = PrivacyPublicPolicy.fromJson({'ready': false});
    appServices.put(PrivacyService(gateway: privacy));
    proxy = LLMProxyService();
  });
  tearDown(() async {
    await proxy.deactivateAccountAndDrain();
    await appServices.reset();
  });

  test(
    'source pin keeps one model and source caps never spill into ordinary chat',
    () async {
      var sent = 0;
      await http.runWithClient(
        () async {
          final pinned = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          expect(pinned, isA<ProjectSourceLLMClient>());
          final source = await generateProjectSourceWithPrivacyAdmission(
            pinned,
            messages,
            onAdmitted: () {},
          );
          expect(source.isComplete, isTrue);
          await storage.write(LLMDirectCloudConfig.storageKey, second.encode());
          await expectLater(
            generateProjectSourceWithPrivacyAdmission(
              pinned,
              messages,
              onAdmitted: () {},
            ),
            interrupted,
          );
          expect(sent, 1);
          await proxy.liveClient.chat(messages);
          expect(sent, 2);
        },
        () => MockClient((request) async {
          final body = jsonDecode(request.body);
          if (++sent == 1) {
            expect(request.url.host, 'provider-a.example.test');
            expect(body['model'], 'model-a');
            expect(body.containsKey('max_tokens'), isFalse);
          } else {
            expect(request.url.host, 'provider-b.example.test');
            expect(body['model'], 'model-b');
            expect(body['max_tokens'], 8192);
          }
          return result();
        }),
      );
    },
  );

  test(
    'account drain invalidates source before another HTTP request',
    () async {
      var sent = 0;
      await http.runWithClient(
        () async {
          final pinned = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          await proxy.deactivateAccountAndDrain();
          await expectLater(
            generateProjectSourceWithPrivacyAdmission(
              pinned,
              messages,
              onAdmitted: () {},
            ),
            interrupted,
          );
          expect(sent, 0);
        },
        () => MockClient((_) async {
          sent++;
          return result();
        }),
      );
    },
  );

  test(
    'source cancellation stays responsive while provider headers are pending',
    () async {
      var cancelled = false;
      final admitted = Completer<void>();
      final response = Completer<http.Response>();
      await http.runWithClient(() async {
        final pinned = await resolveStructuredOutputClientForTask(
          proxy.liveClient,
        );
        final source = generateProjectSourceWithPrivacyAdmission(
          pinned,
          messages,
          onAdmitted: () {
            admitted.complete();
          },
          shouldCancel: () => cancelled,
        );
        final rejected = expectLater(source, interrupted);
        await admitted.future;
        cancelled = true;
        await rejected.timeout(const Duration(seconds: 1));
        response.complete(result());
      }, () => MockClient((_) => response.future));
    },
  );

  test(
    'mounted privacy context change cancels an idle source stream',
    () async {
      final input = StreamController<List<int>>();
      final dispatched = Completer<void>();
      await http.runWithClient(
        () async {
          final pinned = await resolveStructuredOutputClientForTask(
            proxy.liveClient,
          );
          final source = generateProjectSourceWithPrivacyAdmission(
            pinned,
            messages,
            onAdmitted: () {},
          );
          final rejected = expectLater(source, interrupted);
          await dispatched.future;
          privacy.requestContextKey = 'test|new-account';
          await rejected.timeout(const Duration(seconds: 1));
          await input.close();
        },
        () => _StreamClient((_) {
          dispatched.complete();
          return http.StreamedResponse(
            input.stream,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        }),
      );
    },
  );
}

class _StreamClient extends http.BaseClient {
  _StreamClient(this.response);
  final http.StreamedResponse Function(http.BaseRequest) response;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      response(request);
}

class _Storage extends SecureStorageService {
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
