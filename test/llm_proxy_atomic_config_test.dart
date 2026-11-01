import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test('direct-cloud proxy ignores legacy split keys', () async {
    final storage = _MemorySecureStorage()
      ..values.addAll(<String, String>{
        GlobalConstant.keyLlmApiKey: 'legacy-secret',
        GlobalConstant.keyLlmBaseUrl: 'https://legacy.example.test/v1',
        GlobalConstant.keyLlmModel: 'legacy-model',
        GlobalConstant.keyLlmCloudEnabled: 'true',
      });
    appServices.put<SecureStorageService>(storage);
    final mode = appServices.put(MaasoAgentModeService());
    await mode.setPipelineMode(AgentPipelineMode.directCloud);
    final proxy = LLMProxyService();

    expect(await proxy.ensureClient(), isNull);

    const config = LLMDirectCloudConfig(
      apiKey: 'committed-secret',
      baseUrl: 'https://committed.example.test/v1',
      model: 'committed-model',
      enabled: true,
    );
    await storage.write(LLMDirectCloudConfig.storageKey, config.encode());
    final client = await proxy.ensureClient();

    expect(client, isA<LLMClient>());
    // The transport still receives one atomically committed configuration;
    // its returned account-bound wrapper additionally requires user consent.
    final provider = proxy.cachedClientForTesting! as OpenAIProvider;
    expect(provider.apiKey, 'committed-secret');
    expect(provider.baseUrl, 'https://committed.example.test/v1');
    expect(provider.model, 'committed-model');
    await expectLater(client!.chat([]), throwsA(isA<Exception>()));
    await proxy.deactivateAccountAndDrain();
  });
}

final class _MemorySecureStorage extends SecureStorageService {
  final Map<String, String> values = <String, String>{};

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
