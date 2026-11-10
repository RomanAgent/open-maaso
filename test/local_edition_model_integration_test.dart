import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/agent_pipeline_runtime_service.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/direct_vendor_llm_client.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/services/sherpa_neural_tts.dart';
import 'package:maaso/src/core/services/system_tts_engine.dart';
import 'package:maaso/src/features/agent/data/bridge/tts_engine.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_response_integrity.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:maaso/src/features/settings/application/agent_settings_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/offline/offline_model_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    SharedPreferences.setMockInitialValues({});
    appServices.put<SecureStorageService>(_MemoryStorage());
  });
  tearDown(() async {
    TTSEngineRegistry.current = null;
    await appServices.reset();
  });

  test('mobile local edition cannot enter backend or RTC pipeline', () async {
    final mode = await MaasoAgentModeService(
      localEdition: true,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.ios,
      ),
    ).init();
    expect(mode.pipelineMode.value, AgentPipelineMode.directCloud);
    await mode.setPipelineMode(AgentPipelineMode.volcRealtimeAudio);
    expect(mode.pipelineMode.value, AgentPipelineMode.directCloud);
    final pipeline = await AgentPipelineRuntimeService(
      localEdition: true,
      platformCapabilities: const AppPlatformCapabilities.forPlatform(
        AppHostPlatform.ios,
      ),
    ).init();
    expect(TTSEngineRegistry.current, isA<SystemTtsEngine>());
    expect(appServices.isRegistered<SherpaNeuralTts>(), isFalse);
    expect(appServices.isRegistered<LocalLLMService>(), isFalse);
    expect(appServices.isRegistered<CloudLLMHealthService>(), isFalse);
    expect(pipeline.proxyTtsReady.value, isFalse);
    await pipeline.deactivateAccountAndDrain();
  });

  test(
    'local BYOK settings save and remount without background probes',
    () async {
      var probes = 0;
      appServices.put(
        CloudLLMHealthService(
          probe: (_, _, _) async {
            probes++;
            return const CloudLLMHealth(status: CloudLLMStatus.available);
          },
        ),
      );
      final scopes = AccountStorageScopeService();
      final mount = scopes.mount(
        AccountStorageScope(
          environmentKey: 'test',
          accountUuid: 'test-local-model-settings',
        ),
      );
      final settings = LLMConfigController(
        localEdition: true,
        storage: appServices.find<SecureStorageService>(),
        storageScopes: scopes,
      );
      await settings.activateAccount(mount);
      final session = settings.requireActiveAccountSession();
      await settings.saveConfig(
        '',
        'http://127.0.0.1:11434/v1',
        'fixture',
        session: session,
        enabled: true,
      );
      settings.activateCloudHealthForCurrentAccount(session: session);
      await Future<void>.delayed(Duration.zero);
      expect(settings.cloudUsable, isTrue);
      expect(settings.usesLocalEndpoint, isTrue);
      expect(probes, 0);
      expect(
        appServices.find<CloudLLMHealthService>().activeAccountSession,
        isNull,
      );
      await settings.deactivateAccountAndDrain();
    },
  );

  test('original provider panel covers 12 providers and native protocols', () {
    expect(AgentSettingsController.providerPresets, hasLength(12));
    for (final preset in AgentSettingsController.providerPresets) {
      if (preset.baseUrl.isEmpty) continue;
      final config = LLMDirectCloudConfig(
        apiKey: 'fixture-key',
        baseUrl: preset.baseUrl,
        model: preset.model,
        enabled: true,
      );
      final endpoint = directVendorConfig(config).endpoint;
      if (preset.name == 'Anthropic') {
        expect(endpoint.path, endsWith('/messages'));
      }
      if (preset.name == 'Gemini') {
        expect(endpoint.path, endsWith(':generateContent'));
      }
      if (!{'Anthropic', 'Gemini'}.contains(preset.name)) {
        expect(endpoint.path, endsWith('/chat/completions'));
      }
    }
  });

  test(
    'local client is opt-in and fences settings changes before dispatch',
    () async {
      final storage = appServices.find<SecureStorageService>();
      final proxy = LLMProxyService(localEdition: true);
      expect(await proxy.ensureClient(), isNull);
      const config = LLMDirectCloudConfig(
        apiKey: '',
        baseUrl: 'http://127.0.0.1:11434/v1',
        model: 'fixture',
        enabled: true,
      );
      await storage.write(LLMDirectCloudConfig.storageKey, config.encode());
      final client = await proxy.ensureClient();
      expect(client, isA<LLMClient>());
      await storage.delete(LLMDirectCloudConfig.storageKey);
      await expectLater(
        client!.chat([Message.user('Hello')]),
        throwsA(isA<PrivacyException>()),
      );
      await proxy.deactivateAccountAndDrain();
    },
  );

  test(
    'native Anthropic uses original role-preserving generation boundary',
    () async {
      var requests = 0;
      final transport = OfflineModelClient(
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1/messages');
          expect(request.headers['x-api-key'], 'fixture-key');
          final body = jsonDecode(request.body) as Map;
          expect(body['system'], 'Return one JSON object.');
          expect((body['messages'] as List).single['role'], 'user');
          return http.Response(
            jsonEncode({
              'stop_reason': 'end_turn',
              'content': [
                {'type': 'text', 'text': '{"reply":"ok","actions":[]}'},
              ],
            }),
            200,
          );
        }),
      );
      final client = DirectVendorLLMClient(
        config: const LLMDirectCloudConfig(
          apiKey: 'fixture-key',
          baseUrl: 'https://api.anthropic.com/v1',
          model: 'fixture',
          enabled: true,
        ),
        transport: transport,
      );
      addTearDown(client.close);
      final output = await client.chatJsonObject([
        Message.system('Return one JSON object.'),
        Message.user('Hello'),
      ]);
      expect(jsonDecode(output)['reply'], 'ok');
      await expectLater(
        client.chatJsonObject([
          Message.user('Hello'),
        ], onAdmitted: () => throw StateError('retired')),
        throwsStateError,
      );
      expect(requests, 1);
    },
  );

  test(
    'native Gemini rejects malformed structured output without retry',
    () async {
      var requests = 0;
      final transport = OfflineModelClient(
        client: MockClient((request) async {
          requests++;
          expect(request.url.path, '/v1beta/models/fixture:generateContent');
          expect(request.headers['x-goog-api-key'], 'fixture-key');
          return http.Response(
            jsonEncode({
              'candidates': [
                {
                  'finishReason': 'STOP',
                  'content': {
                    'parts': [
                      {'text': 'plain prose'},
                    ],
                  },
                },
              ],
            }),
            200,
          );
        }),
      );
      final client = DirectVendorLLMClient(
        config: const LLMDirectCloudConfig(
          apiKey: 'fixture-key',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          model: 'fixture',
          enabled: true,
        ),
        transport: transport,
      );
      addTearDown(client.close);
      await expectLater(
        client.chatJsonObject([Message.user('Hello')]),
        throwsA(isA<LLMResponseIntegrityException>()),
      );
      expect(requests, 1);
    },
  );
  test(
    'native provider safety and unterminated output never becomes source',
    () async {
      for (final fixture in <(String, Map<String, Object?>)>[
        (
          'anthropic',
          {
            'stop_reason': 'refusal',
            'content': [
              {'type': 'text', 'text': '{"reply":"prefix","actions":[]}'},
            ],
          },
        ),
        (
          'gemini',
          {
            'candidates': [
              {
                'finishReason': 'SAFETY',
                'content': {
                  'parts': [
                    {'text': '{"reply":"prefix","actions":[]}'},
                  ],
                },
              },
            ],
          },
        ),
        (
          'anthropic',
          {
            'content': [
              {'type': 'text', 'text': '{"reply":"prefix","actions":[]}'},
            ],
          },
        ),
      ]) {
        final provider = OfflineModelProvider.fromId(fixture.$1);
        final transport = OfflineModelClient(
          client: MockClient(
            (_) async => http.Response(jsonEncode(fixture.$2), 200),
          ),
        );
        final client = DirectVendorLLMClient(
          config: LLMDirectCloudConfig(
            apiKey: 'fixture-key',
            baseUrl: provider.baseUrl,
            model: 'fixture',
            enabled: true,
          ),
          transport: transport,
        );
        addTearDown(client.close);
        await expectLater(
          client.generateProjectSource([Message.user('Make a game')]),
          throwsA(
            isA<OfflineModelException>().having(
              (e) => e.code,
              'code',
              'invalid_response',
            ),
          ),
        );
      }
    },
  );
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
